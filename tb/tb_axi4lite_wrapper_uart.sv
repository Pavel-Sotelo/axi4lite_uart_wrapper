`timescale 1ns / 1ps


module tb_axi4lite_wrapper_uart();

    localparam ADDR_WIDTH = 4;
    localparam CLK_PERIOD = 10;

    logic clk, reset;
    
    //WRITE ADDRESS CHANNEL (AW)    
    logic [ADDR_WIDTH - 1:0] AWADDR;
    logic AWVALID;
    logic AWREADY;

    //WRITE DATA CHANNEL (W)
    logic [31:0] WDATA;
    logic WVALID;
    logic WREADY;    

    //WRITE RESPONSE CHANNEL (B)
    logic [1:0] BRESP;
    logic BVALID;
    logic BREADY;  

    //READ ADDRESS CHANNEL (AR)
    logic [ADDR_WIDTH - 1:0] ARADDR;
    logic ARVALID;
    logic ARREADY;   

    //WRITE RESPONSE CHANNEL (B)
    logic [31:0] RDATA;
    logic [1:0] RRESP;
    logic RVALID;
    logic RREADY;  

    //UART I/O (outside world wires) 
    logic rx;
    logic tx;


    axi4lite_wrapper_uart DUT (
    
        .clk(clk),
        .reset(reset),
        
        .AWADDR(AWADDR),    
        .AWVALID(AWVALID),  
        .AWREADY(AWREADY),
        
        .WDATA(WDATA),
        .WVALID(WVALID),
        .WREADY(WREADY),
        
        .BRESP(BRESP),
        .BVALID(BVALID),
        .BREADY(BREADY),
    
        .ARADDR(ARADDR),    
        .ARVALID(ARVALID),  
        .ARREADY(ARREADY),        
    
        .RDATA(RDATA),        
        .RRESP(RRESP),
        .RVALID(RVALID),
        .RREADY(RREADY),
        
        //NOTE: rx is fed by TX loopback, The rx reg below is intentionally unconnected in this loopback testbench
        .rx(tx),
        .tx(tx)    

    );


    //clock generation
    initial clk = 0;
    always #(CLK_PERIOD/2.0) clk = ~clk;
    

    //TASKS
    
    //check task
    task check (input string label, input logic [31:0] got, input [31:0] expected);
    
        if(got == expected)
            $display("PASS %s (time: %0t)", label, $time);
        else
            $display("FAIL %s - expected: %0d, got %0d (time: %0t)", label, expected, got, $time);    
    
    endtask
    
    
    //write task
    task axi_write;
    
        input logic [ADDR_WIDTH - 1:0] TASK_AWADDR;
        input logic [31:0] TASK_WDATA;
    
        begin
    
            AWADDR = TASK_AWADDR;    
            WDATA = TASK_WDATA;
            
            AWVALID = 1;
            WVALID  = 1;
            
            @(posedge clk);
            #1;
            
           check ("state is WRITE after AWVALID and WVALID", DUT.state, DUT.WRITE);
            
            AWVALID = 0;
            WVALID  = 0;           
            
            @(posedge clk);
            #1;
            
            check ("tx_start is HIGH after valid TX_DATA address", DUT.tx_start, 1);
            check ("tx_byte loaded WDATA succesfully", DUT.tx_byte, TASK_WDATA);
            check ("BVALID is HIGH after checked address", BVALID, 1);
            check ("BRESP is OKAY after valid address", BRESP, 2'b00);                    
            
            @(posedge clk);
            #1;
            
            check ("tx_start is LOW after WRITE state (only raises for 1 cycle)", DUT.tx_start, 0);
            
            //We will raise BREADY in the next clock cycle, not here, to check if WRITE_RESP stays for more than one cycle
            
            @(posedge clk);
            #1;
            
            BREADY = 1;
            
            check ("state is WRITE_RESP before WREADY reacts to the clock edge", DUT.state, DUT.WRITE_RESP);
                       
            @(posedge clk);
            #1;
            
            BREADY = 0;
            
            check ("state is IDLE after HANDSHAKE of BVALID and BREADY", DUT.state, DUT.IDLE);
            check ("BVALID is LOW after HANDSHAKE", BVALID, 0);
            check ("BRESP is reset to 00 after WRITE_RESP state", BRESP, 2'b00); 
       
        end
    
    endtask
    
    
    
    //read task
    task axi_read;
    
        input logic [ADDR_WIDTH - 1:0] TASK_ARADDR;
    
        begin
    
            ARADDR = TASK_ARADDR;    
            
            ARVALID = 1;
            
            @(posedge clk);
            #1;
            
           check ("state is READ after ARVALID and RVALID", DUT.state, DUT.READ);
            
            ARVALID = 0;        
            
            @(posedge clk);
            #1;

            check ("RVALID is HIGH after checked address", RVALID, 1);
            check ("RRESP is OKAY after valid address", RRESP, 2'b00);   

            @(posedge clk);
            #1;
            
            //We will raise RREADY in the next clock cycle, not here, to check if READ_RESP stays for more than one cycle
            
            @(posedge clk);
            #1;
            
            RREADY = 1;
            
            check ("state is READ_RESP before RREADY reacts to the clock edge", DUT.state, DUT.READ_RESP);
                       
            @(posedge clk);
            #1;
            
            RREADY = 0;
            
            check ("state is IDLE after HANDSHAKE of RVALID and RREADY", DUT.state, DUT.IDLE);
            check ("RVALID is LOW after HANDSHAKE", RVALID, 0);
            check ("RRESP is reset to 00 after READ_RESP state", RRESP, 2'b00); 
       
        end
    
    endtask    

    
    //SVA (SystemVerilog Assertions):
    
        //SVA 1: Check VALID and READY outputs on IDLE state
        
        property p_idle_outputs;
            @(posedge clk) disable iff (reset)
            (DUT.state == DUT.IDLE) |-> (AWREADY & WREADY & ~BVALID & ARREADY & ~RVALID);
        endproperty
    
    
        check_p_idle_outputs: assert property (p_idle_outputs)
            else $display ("SVA 1 failed - VALID/READY outputs are not correct in IDLE state (time: %0t)", $time);
            
        //SVA 2: Check if next state is WRITE after AWVALID and WBVALID, when current state is IDLE    
            
        property p_write_state;
            @(posedge clk) disable iff (reset)
            (DUT.state == DUT.IDLE & AWVALID & WVALID) |=> (DUT.state == DUT.WRITE);
        endproperty
            
        check_p_write_state: assert property (p_write_state)     
            else $display ("SVA 2 failed: state is not WRITE after AWVALID and WBVALID, when previous state as IDLE (time: %0t)", $time);
       
            
        //SVA 3: Check if next state is READ after ARVALID, when current state is IDLE     
            
        property p_read_state;
            @(posedge clk) disable iff (reset)
            (DUT.state == DUT.IDLE & ARVALID) |=> (DUT.state == DUT.READ);
        endproperty
            
        check_p_read_state: assert property (p_read_state)     
            else $display ("SVA 3 failed: state is not READ after ARVALID, when previous state as IDLE (time: %0t)", $time);
           
            
        //SVA 4: Check if BVALID is LOW after BREADY  
            
        property p_bvalid_low;
            @(posedge clk) disable iff (reset)
            (BREADY) |=> (BVALID == 1'b0);
        endproperty
            
        check_p_bvalid_low: assert property (p_bvalid_low)     
            else $display ("SVA 4 failed: BVALID is not LOW after BREADY on clock edge (time: %0t)", $time);
            
            
        //SVA 5: Check if RVALID is LOW after RREADY  
            
        property p_rvalid_low;
            @(posedge clk) disable iff (reset)
            (RREADY) |=> (RVALID == 1'b0);
        endproperty
            
        check_p_rvalid_low: assert property (p_rvalid_low)     
            else $display ("SVA 5 failed: RVALID is not LOW after RREADY on clock edge (time: %0t)", $time);
            
            
        //SVA 6: When read address is RX_DATA, check if CAPTURED_DONE is low after RREADY when state is READ_RESP  
            
        property p_captured_done_low;
            @(posedge clk) disable iff (reset)
            (DUT.state == DUT.READ_RESP && RREADY && DUT.CAPTURED_ARADDR == DUT.RX_DATA) |=> (DUT.CAPTURED_DONE == 1'b0);
        endproperty
            
        check_p_captured_done_low: assert property (p_captured_done_low)     
            else $display ("SVA 6 failed: When current state is READ_RESP and read address is RX_DATA, CAPTURED_DONE is not LOW after RREADY (time: %0t)", $time);                                            


        //SVA 7: overrun sets HIGH when a new byte arrives (done_rising) while one is already captured and unread (CAPTURED_DONE == 1)

        property p_overrun_set;
            @(posedge clk) disable iff (reset)
            (DUT.done_rising && DUT.CAPTURED_DONE) |=> (DUT.overrun == 1'b1);
        endproperty

        check_p_overrun_set: assert property (p_overrun_set)
            else $display ("SVA 7 failed: overrun did not set when a byte arrived while one was still unread (time: %0t)", $time);


        //SVA 8: oldest held,  when a byte is dropped (done_rising while CAPTURED_DONE == 1), the already captured byte must not change

        property p_oldest_held;
            @(posedge clk) disable iff (reset)
            (DUT.done_rising && DUT.CAPTURED_DONE) |=> $stable(DUT.CAPTURED_RX_BYTE);
        endproperty

        check_p_oldest_held: assert property (p_oldest_held)
            else $display ("SVA 8 failed: captured byte changed on overrun - not holding the oldest byte (time: %0t)", $time);

    //End of SVA's
   
    initial begin
    
        //initialize DUT inputs (to avoid don't cares)
        AWVALID = 0; WVALID = 0; BREADY = 0;
        ARVALID = 0; RREADY = 0;
        AWADDR = 0; WDATA = 0; ARADDR = 0;
        rx = 1;   //rx in idle is high for UART (note: unconnected in loopback TB, see DUT instantiation)
 
    /*
        Corner cases to cover:
        
            1.Normal reset: raise reset, all registered outputs should be low after, READY signals should be HIGH (IDLE state)
            2.Normal TX_DATA write: Master sends correct write address and a byte data, raising as well the VALID inputs, tx_start pulses and BRESP is OKAY 
            3.Incorrect TX_DATA write: Master sends an incorrect write address, tx_start stays LOW, tx_byte does not load, and BRESP should throw ERROR (10)
            4.Normal STATUS read: Master reads STATUS, tx_busy should be HIGH because a byte was transmitted a few cycles before (TC2), done should be LOW
            5.Normal RX_DATA read: after the loopback byte from TC2 is fully received (wait for done), Master reads RX_DATA and it should be the sent byte (112 decimal)
            6.Read RX_DATA cleared: after reading the byte from past TC5, CAPTURED_DONE should be LOW, confirming the read cleared it and no new byte re-raised it, or another signal re-raised it
            7.Overrun: a byte is captured and unread, then a second byte arrives (forced done_rising), the second one is dropped, overrun goes HIGH, and reading RX_DATA returns the oldest byte

    */
    
        $display("");
        $display("TC1 begins. (normal reset in beginning)");
    
        reset = 1; 
    
        @(posedge clk);
        #1;
    
        reset = 0;
    
        //output reset's (there are checked in a SVA as well, but here they are manually checked just to cover the corner case
        check("AWREADY reset is HIGH", AWREADY, 1);
        check("WREADY reset is HIGH", WREADY, 1);
        check("BRESP reset is 00", BRESP, 00);
        check("BVALID reset is LOW", BVALID, 0);
        check("ARREADY reset is HIGH", ARREADY, 1);
        check("RDATA reset is all low", RDATA, '0);
        check("RRESP reset is 00", RRESP, 2'b00);
        check("RVALID reset is LOW", RVALID, 0);
        
        $display("TC1 finished."); 
        
        //3 clock edge separation to distinguish between corner cases in waveform 
        repeat (3) @(posedge clk);
        #1;        
    
        $display("");
        $display("TC2 begins. (normal TX_DATA write adress)");            
    
        axi_write (4'h0, 8'd112);
        
        $display("TC2 finished.");  
    
        repeat (3) @(posedge clk);
        #1;   
    
        $display("");
        $display("TC3 begins. (incorrect TX_DATA write adress)");
             
        $display("NOTE: FAILS are expected in tx_start, tx_byte, BRESP would be 10 (ERROR)");
           
        axi_write (4'h4, 8'd243);
        
        $display("TC3 finished.");     
    
        repeat (3) @(posedge clk);
        #1;          
    
        $display("");
        $display("TC4 begins. (normal STATUS read adress)");           
    
        //tx_busy should be HIGH because we previously write a byte a few cycles before (TC2)
        //STATUS = {29'd0, overrun, CAPTURED_DONE, tx_busy}. Here: tx_busy=1, done=0, overrun=0 -> 3'b001
        
        axi_read (4'h8);
        check ("RDATA (status) is 001: tx_busy=1, done=0, overrun=0", RDATA, 32'd1);
        
        $display("TC4 finished.");
        
        repeat (3) @(posedge clk);
        #1;           
    
        $display("");
        $display("TC5 begins. (normal RX_DATA read adress)");
        
        //wait for the done signal of the previously TC2 sent byte (112 decimal), because the cycle speed of sending an UART byte is +8000 cycles
        wait (DUT.CAPTURED_DONE == 1);             
    
        axi_read (4'h4);
        check ("RDATA (rx_byte) is 112 decimal after read", RDATA, 8'd112);        
    
        $display("TC5 finished.");
        
        repeat (3) @(posedge clk);
        #1;          
        
        $display("");
        $display("TC6 begins. (just checks if CAPTURED_DONE is LOW after we read the last byte and we didnt send another one)");
        
        //STATUS now: tx_busy=0 (transmit long done), done=0 (cleared by TC5 read), overrun=0 -> all zero
        axi_read (4'h8);
        check ("RDATA (status) is 000 (no busy, no done, no overrun)", RDATA, 32'd0);
        check ("overrun bit is LOW (no drop occurred)", DUT.overrun, 0);
        
        $display("TC6 finished.");        

        repeat (3) @(posedge clk);
        #1;

        $display("");
        $display("TC7 begins. (overrun: a second byte arrives while the first is still unread, we should keep the oldest)");

        //first we send a byte (200 decimal) and wait until its captured and unread
        axi_write (4'h0, 8'd200);
        wait (DUT.CAPTURED_DONE == 1);
        
        @(posedge clk);
        #1;
        
        check ("first byte (200) is captured and unread", DUT.CAPTURED_RX_BYTE, 8'd200);
        check ("overrun is still LOW before the second byte", DUT.overrun, 0);

        //now we force a second byte (55 decimal) into the rx submodule while the first is unread, so done_rising fires again
        @(posedge clk);
        #1;
        
        force DUT.DUT_RX.done    = 1'b0;
        force DUT.DUT_RX.rx_byte = 8'd55;
        
        @(posedge clk);
        #1;
        
        force DUT.DUT_RX.done    = 1'b1;   //0 to 1 edge makes done_rising HIGH
        
        @(posedge clk);
        #1;

        check ("overrun is HIGH after the second byte is dropped", DUT.overrun, 1);
        check ("captured byte is STILL the first one (200), the second (55) was dropped", DUT.CAPTURED_RX_BYTE, 8'd200);

        //release the forces so the rx submodule works normal again
        release DUT.DUT_RX.done;
        release DUT.DUT_RX.rx_byte;

        //Master reads RX_DATA, it should be the OLDEST byte (200), not the dropped one (55)
        axi_read (4'h4);
        check ("RDATA (rx_byte) is the oldest byte 200 decimal, not the dropped 55", RDATA, 8'd200);

        @(posedge clk);
        #1;
        
        check ("overrun is LOW after RX_DATA read", DUT.overrun, 0);
        check ("CAPTURED_DONE is LOW after RX_DATA read", DUT.CAPTURED_DONE, 0);

        $display("TC7 finished.");
        $display("");
        $display("End of AXI4LITE WRAPPER UART Testbench.");
        $display("");        
                    
        $finish;
    end


endmodule
 