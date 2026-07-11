`timescale 1ns / 1ps

module axi4lite_wrapper_uart #(

    parameter ADDR_WIDTH = 4   //register length

)(

    input logic clk,    
    input logic reset,
    
    //WRITE ADDRESS CHANNEL (AW)
    input logic [ADDR_WIDTH - 1:0] AWADDR,
    input logic AWVALID,
    output logic AWREADY,

    //WRITE DATA CHANNEL (W)
    input logic [31:0] WDATA, //32-bit standard AXI bus width, but for the UART we will only use 8 bits
    input logic WVALID,
    output logic WREADY,    

    //WRITE RESPONSE CHANNEL (B)
    output logic [1:0] BRESP,
    output logic BVALID,
    input logic BREADY,  

    //READ ADDRESS CHANNEL (AR)
    input logic [ADDR_WIDTH - 1:0] ARADDR,
    input logic ARVALID,
    output logic ARREADY,   

    //WRITE RESPONSE CHANNEL (B)
    output logic [31:0] RDATA, //32-bit standard AXI bus width 
    output logic [1:0] RRESP,
    output logic RVALID,
    input logic RREADY,  

    //UART I/O (outside world wires) 
    input logic rx,
    output logic tx

);

    //UART TX internal signals
    logic tx_start;
    logic [7:0] tx_byte;    
    logic tx_busy;
    
    //UART RX internal signals   
    logic [7:0] rx_byte;    
    logic done;

    //write and read registers
    
    //write
    localparam TX_DATA = 4'h0;
    
    //read
    localparam RX_DATA = 4'h4;
    localparam STATUS  = 4'h8;


    //STATES for the wrapper
    localparam IDLE = 0, WRITE = 1, WRITE_RESP = 2, READ = 3, READ_RESP = 4;
    
    logic [2:0] state, next_state;
    
    //signal to capture AWADDR during the IDLE->WRITE transition (to avoid if the AWADDR changed mid WRITE operation)
    logic [ADDR_WIDTH - 1:0] CAPTURED_AWADDR;
    //signal to capture WDATA during the IDLE->WRITE transition
    logic [7:0] CAPTURED_WDATA;
    //signal to capture ARADDR during the IDLE->WRITE transition
    logic [ADDR_WIDTH - 1:0] CAPTURED_ARADDR; 

    //CAPTURE_RX_BYTE captures the rx_byte when done is HIGH, because when done is HIGH, is the only moment were rx_byte is stable and correct.
    logic [7:0] CAPTURED_RX_BYTE;
    //CAPTURE_DONE captures when done is high and keeps it, because if we check status and done is over , we will not know if there is an unread byte waiting
    logic CAPTURED_DONE;
    
    //signal to store the previous done signal (to detect 01 in done)
    logic done_prev;
    logic done_rising; //as well to store the 01 detection of done
    logic overrun; //flag to detect when another byte or multiple ones arrived (but we only are going to read the oldest one)

    //FSM


    //sequential state logic
    always_ff @(posedge clk) begin
    
        if (reset)
            state <= IDLE;
        else
            state <= next_state;
            
    end   
  
  
    //WRITE logic
    
    //capture AWADDR and WDATA during the IDLE->WRITE transition
    always_ff @(posedge clk) begin
    
        if(reset) begin
        
            CAPTURED_AWADDR <= '0;                
            CAPTURED_WDATA <= 8'd0;
                    
        end else if(state == IDLE && AWVALID && WVALID) begin
        
            CAPTURED_AWADDR <= AWADDR;
            CAPTURED_WDATA <= WDATA [7:0];
            
        end
    end    


    //WRITE sequential logic
    always_ff @(posedge clk) begin    
  
        if(reset) begin
        
            tx_start <= 1'b0;
            tx_byte <= 8'd0;
            BVALID <= 1'b0;
            BRESP <= 2'b00;
        
        end else if (state == WRITE) begin
        
            if (CAPTURED_AWADDR == TX_DATA) begin
            
                tx_start <= 1'b1;
                tx_byte <= CAPTURED_WDATA;        
                BVALID <= 1'b1;
                BRESP <= 2'b00;
            
            end else begin
            
                tx_start <= 1'b0;    
                BVALID <= 1'b1;
                BRESP <= 2'b10;
                            
            end
         
        end else if (state == WRITE_RESP) begin
        
            tx_start <= 1'b0;
        
            if(BREADY) begin
        
                BVALID <= 1'b0;        
                BRESP <= 2'b00;            
    
            end
            
        end else begin
        
            tx_start <= 1'b0;
            tx_byte <= 8'd0;
            BVALID <= 1'b0;
            BRESP <= 2'b00;           
        
        end
    
    end
   
  
    //READ logic
    
    //capture ARADDR during the IDLE->READ transition
    always_ff @(posedge clk) begin
    
        if(reset) begin
        
            CAPTURED_ARADDR <= '0;                
                    
        end else if(state == IDLE && ARVALID) begin
        
            CAPTURED_ARADDR <= ARADDR;
            
        end
    end   
 
    //capture the done "01" raise
    always_ff @(posedge clk) begin
    
        if(reset)
            done_prev <= 1'b0;
        else
            done_prev <= done;

    end            
            
    assign done_rising = done & ~done_prev;

    //capture rx_byte when done is HIGH 
    always_ff @(posedge clk) begin
    
        if(reset) begin
        
            CAPTURED_RX_BYTE <= 8'd0;
            CAPTURED_DONE <= 1'd0;
            overrun <= 1'b0;                
                    
        end else if(done_rising && ~CAPTURED_DONE) begin
        
            CAPTURED_RX_BYTE <= rx_byte;
            CAPTURED_DONE <= 1'd1;
            
        end else if(done_rising && CAPTURED_DONE) begin
        
            overrun <= 1'b1;           
            
        end else if (state == READ_RESP && RREADY && CAPTURED_ARADDR == RX_DATA) begin
        
            CAPTURED_DONE <= 1'd0;
            overrun <= 1'b0;     
        
        end
        
    end       
    

    //READ sequential logic
    always_ff @(posedge clk) begin
    
        if (reset) begin
        
            RDATA <= 32'd0;
            RVALID <= 1'b0;
            RRESP <= 2'b00;         
        
        end else if (state == READ) begin
        
            if(CAPTURED_ARADDR == RX_DATA) begin
            
                RDATA <= {24'd0, CAPTURED_RX_BYTE};
                RVALID <= 1'b1;
                RRESP <= 2'b00;              
                 
            end else if(CAPTURED_ARADDR == STATUS) begin
            
                RDATA <= {29'd0, overrun, CAPTURED_DONE, tx_busy};        
                RVALID <= 1'b1;
                RRESP <= 2'b00;           
            
            end else begin
             
                RVALID <= 1'b1;
                RRESP <= 2'b10;              
          
            end
         
        end else if (state == READ_RESP) begin
        
            if(RREADY) begin
        
                RVALID <= 1'd0;
                RRESP <= 2'b00;
                
            end

        end else begin
        
            RVALID <= 1'b0;
            RRESP <= 2'b00;               

        end    
 
    end    

    
    //next state logic
    always_comb begin
    
        case(state)
        
            IDLE: next_state = (AWVALID & WVALID)? WRITE : (ARVALID)? READ : IDLE;
            WRITE: next_state = WRITE_RESP;    
            WRITE_RESP: next_state = BREADY? IDLE : WRITE_RESP;
            READ: next_state = READ_RESP;        
            READ_RESP: next_state = RREADY? IDLE : READ_RESP;    

            default: next_state = IDLE;
        endcase
    end


    //output logic
    
    //WRITE ready outputs
    assign AWREADY = state == IDLE;   
    assign  WREADY = state == IDLE;

    //READ ready outputs
    assign ARREADY = state == IDLE;
    
    
    // UART instantiations
    
        uart_tx DUT_TX (

        .clk(clk),
        .reset(reset),
        .tx_start(tx_start),
        .tx_byte(tx_byte),
        .tx_busy(tx_busy),
        .tx(tx)

    );

    uart_rx DUT_RX (

        .clk(clk),
        .reset(reset),
        .rx(rx),
        .rx_byte(rx_byte),
        .done(done)

    );

endmodule