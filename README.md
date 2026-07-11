# AXI4Lite UART Wrapper — RV32I SoC

5-state slave FSM · 32-bit AXI4Lite bus · Synthesized for Basys 3 (Artix-7) · Simulation-verified

**Role in the system:**

This wrapper is the second piece I built for my RV32I SoC project, right after the UART. It sits between the CPU and the UART and lets the CPU talk to the UART through a standard bus (AXI4Lite), so the processor can send and receive bytes just by reading and writing a few memory addresses, without knowing anything about how the serial line actually works.

It exposes the UART as three registers the CPU can access: one to send a byte, one to read a received byte, and one to check the UART's status. Internally, the wrapper drives the `uart_tx` and `uart_rx` modules I built earlier. This is the step that connects the UART to the rest of the SoC, turning it from a standalone module into something the processor can actually use.

---

## System Architecture

![System architecture](docs/axi4lite_wrapper_uart_system_architecture_diagram.png)

The CPU acts as the AXI4Lite master and the wrapper is the slave. The wrapper exposes three memory-mapped registers and internally drives the `uart_tx` / `uart_rx` modules that handle the serial line. The physical path to the PC (pins, USB-UART bridge, PuTTY) is shown for context — verification was done in simulation using an internal loopback, wiring the wrapper's `tx` output back to its own `rx` input.

---

## Register Map

| Address | Name     | Access | Description                                        |
|---------|----------|--------|----------------------------------------------------|
| `0x00`  | TX_DATA  | Write  | Write a byte here to transmit it over the UART. Only bits [7:0] are used. |
| `0x04`  | RX_DATA  | Read   | Reads the last received byte (bits [7:0]). Reading clears the "byte ready" and "overrun" flags. |
| `0x08`  | STATUS   | Read   | Bit 0 = `tx_busy` (UART transmitting), Bit 1 = `done` (a received byte is waiting), Bit 2 = `overrun` (a byte was dropped). |

Writing to any address other than TX_DATA, or reading any address other than RX_DATA / STATUS, returns a `SLVERR` (`2'b10`) response.

**STATUS bit layout** (`RDATA = {29'd0, overrun, done, tx_busy}`):
- bit 0 — `tx_busy` — TX is mid-transmission
- bit 1 — `done` (`CAPTURED_DONE`) — an unread received byte is waiting
- bit 2 — `overrun` — a byte arrived while one was already unread (a byte was dropped)

---

## The AXI4Lite Interface

AXI4Lite has five independent channels, each following the same VALID/READY handshake: the sender raises VALID when it has data, the receiver raises READY when it can accept, and the transfer happens on the clock edge where both are high.

- **Write:** AW (address), W (data), B (response)
- **Read:** AR (address), R (data + response)

The key rule the whole protocol depends on: once a sender raises VALID, it must hold VALID and keep its payload stable until the handshake completes — it can never lower VALID, and it can never wait for READY before raising VALID. Putting a value on the bus is *offering* it; the handshake is the *confirmation* the other side actually took it.

This wrapper is the slave: it drives the READY signals and the responses (B and R channels), and receives everything else from the master.

---

## The 5-State FSM

![FSM](docs/axi4lite_wrapper_uart_state_diagram.png)

The wrapper runs on a 5-state FSM:

- **IDLE** — waiting for a transaction. All three READY signals (`AWREADY`, `WREADY`, `ARREADY`) are high here, so the wrapper is always ready to accept a request. On `AWVALID && WVALID` it goes to WRITE; on `ARVALID` it goes to READ.
- **WRITE** — a one-cycle *action* state. It pulses `tx_start`, loads the captured byte into the UART, and decodes the write response, then unconditionally moves to WRITE_RESP.
- **WRITE_RESP** — a *waiting* state. It holds `BVALID` and `BRESP` stable until the master raises `BREADY`, then returns to IDLE.
- **READ** — a one-cycle *action* state. It latches the read response (`RDATA` / `RRESP`) once, based on the captured address, then unconditionally moves to READ_RESP.
- **READ_RESP** — a *waiting* state. It holds `RVALID` and the latched `RDATA` / `RRESP` stable until the master raises `RREADY`, then returns to IDLE.

**Why WRITE and WRITE_RESP are separate:** a write has two jobs with incompatible durations. Pulsing `tx_start` must last exactly one cycle, but holding `BVALID` until `BREADY` can take any number of cycles. Combining both into one state would stretch the `tx_start` pulse across the entire wait, causing repeated transmissions. Splitting them keeps the one-cycle pulse in WRITE and the open-ended wait in WRITE_RESP.

**Why READ and READ_RESP are also separate (and why I was wrong to think READ was deletable):** at first I thought the read side didn't need its own action state — unlike the write side, it has no `tx_start`-style signal that must last exactly one cycle, so it looked like I could delete READ and do everything in READ_RESP. That's wrong. The two-state split isn't only about pulsing a one-cycle signal — it's about **computing the response once, on entry, then holding it steady while waiting for the handshake.** Under AXI4Lite, while `RVALID` is HIGH, `RDATA` and `RRESP` must not change until `RREADY` completes the transfer.

If READ and READ_RESP were merged into a single state that recomputed `RDATA` every cycle, a byte arriving mid-wait (`done_rising` firing while the FSM sits in the response state waiting for a slow `RREADY`) would silently change `RDATA` while `RVALID` is still asserted — an AXI protocol violation, and a real bug, because the master could sample a different value than the one it was promised. Keeping READ as the one-cycle "latch the response" state and READ_RESP as the "hold it steady" state makes this correct by construction: `RDATA` is assigned only in READ, and READ_RESP never touches it again. The write side relies on the exact same property for `BRESP`, so the two channels are symmetric on purpose. The difference between them is only that writes have an *additional* timed action (the `tx_start` pulse) living in their action state, while reads only have data to latch.

**Why the READY signals are just `state == IDLE`:** a READY signal reflects the wrapper's *capacity to accept a request*, not the content of any response. The wrapper is free to accept whenever it's idle, so all three READYs are simply high in IDLE and low otherwise. They come up high before the master even raises VALID (ready-before-valid), which is the simplest, deadlock-free handshake ordering.

---

## Design Notes

**Why the CAPTURED registers exist:**

The master only holds AWADDR, WDATA, and ARADDR stable *until the handshake completes*. After that edge, the spec lets the master change them to anything. But the FSM needs those values *after* the handshake — in WRITE / WRITE_RESP / READ / READ_RESP — to decode the address, load the byte, and drive the response. So each is captured into a register on the handshake edge (`state == IDLE && AWVALID && WVALID` for writes, the AR handshake for reads), and the FSM works only with the frozen copies. This decouples the wrapper's internal timing from the master: the action state can run any cycle later and still read stable values, no matter how fast the master moves on.

**`CAPTURED_RX_BYTE` and `CAPTURED_DONE` are captured by a different event:**

Unlike the address/data captures, which happen on an *AXI transaction* edge, these come from `uart_rx` on the PC's schedule — outside any transaction. `rx_byte` from the UART is only valid while the RX FSM is in its DONE state (one bit-period); it drops to 0 afterward. And the CPU may read RX_DATA long after the byte arrived. So `CAPTURED_RX_BYTE` latches the byte the moment it arrives and holds it, bridging the time gap between "a byte arrived" and "the CPU read it." `CAPTURED_DONE` is the "unread byte waiting" flag: it sets when a byte arrives and clears when the CPU reads RX_DATA (clear-on-read), so software can tell a fresh byte from one it already read.

**Detecting the rising edge of `done`:**

`done` from `uart_rx` is a *level* — it stays high for a full bit-period. Using it directly as the set condition for `CAPTURED_DONE` re-asserts the flag every cycle, which blocks the clear (see Bug 2). Instead, the wrapper detects `done`'s *rising edge*: `done_prev` is registered each cycle, and `done_rising = done & ~done_prev` is true for exactly one cycle when a byte completes. This sets the flag once per byte instead of continuously, so a read can clear it and it stays cleared. A data signal like `done` is never used as a clock — its edge is detected synchronously against the one system clock.

**RX buffering policy — single-byte, oldest-held:**

The wrapper has a one-byte RX buffer. When a byte is already captured and unread (`CAPTURED_DONE == 1`) and a new byte arrives, the wrapper **keeps the oldest byte and drops the new one**, raising the `overrun` flag. The capture is gated on `!CAPTURED_DONE`, so the oldest unread byte is never overwritten.

The alternative — "always keep the newest byte, overwrite the unread one" — was considered and rejected. It has a subtle race: a byte arriving while the FSM is in READ_RESP waiting for `RREADY` would overwrite `CAPTURED_RX_BYTE`, then the read-completion would clear `CAPTURED_DONE`, leaving a byte physically sitting in the register while STATUS reports nothing pending (the byte becomes invisible until a later byte re-triggers `done_rising`). The oldest-held approach has no such race: `CAPTURED_DONE` always accurately reflects whether the byte in `CAPTURED_RX_BYTE` is unread. It also matches how a classic single-byte UART data register behaves — read the data register, it clears the ready flag, the next byte can land.

Multiple bytes arriving between reads is not a bug; it is the defining behavior of a single-byte buffer. A byte is only ever dropped with the `overrun` flag raised, so the loss is never silent. Reading RX_DATA consumes the byte and clears both `done` and `overrun`.

**Polled operation:**

The wrapper works in polled mode. Software should read STATUS before writing TX_DATA (to check `tx_busy`) and before reading RX_DATA (to check `done`, and `overrun` if it cares whether a byte was missed). Writing while `tx_busy` is high drops the byte — standard polled-UART behavior. STATUS exists to give the data meaning: the data registers hold values, and STATUS tells software whether those values are worth acting on.

---

## Design Parameters

| Parameter        | Value              | Derivation                                  |
|------------------|--------------------|---------------------------------------------|
| Clock frequency  | 100 MHz            | Basys 3 onboard oscillator (pin W5)         |
| Bus width        | 32-bit             | AXI4Lite data bus (CPU word size); UART uses low 8 bits |
| Address width    | 4-bit              | Three word-aligned registers (0x00, 0x04, 0x08) |
| Error response   | SLVERR (`2'b10`)   | Returned for unmapped addresses             |
| Clock domain     | Single-clock       | UART and wrapper share one clock domain |
| Fmax (post-implementation) | ~257 MHz | WNS = +6.107ns @ 100MHz clock             |
| Critical path    | FSM state register → RRESP register | Read-response decode; total delay 3.404ns (logic 0.704ns, net 2.700ns) |

---

## Verification

All verification was done in simulation (behavioral) and synthesis (timing). The wrapper was not run on hardware — that comes when it's integrated with the CPU.

### Testbench — `tb/tb_axi4lite_wrapper_uart.sv`

The testbench uses a bus functional model (BFM): `axi_write` and `axi_read` tasks that drive full AXI transactions, plus a reusable `check` task for PASS/FAIL reporting. RX is fed by TX loopback (`tx → rx`), so a byte written to TX_DATA reappears on the RX side after transmission.

| Test Case | Description                                              | Result |
|-----------|---------------------------------------------------------|--------|
| TC1       | Reset behavior — READY signals HIGH, VALIDs LOW after reset | PASS |
| TC2       | Normal TX_DATA write — byte 112, `tx_start` pulses one cycle, BRESP OKAY | PASS |
| TC3       | Bad-address write — SLVERR returned, `tx_start` stays LOW (expected fails) | PASS |
| TC4       | STATUS read — `tx_busy` HIGH (byte from TC2 still transmitting), `done` LOW → `001` | PASS |
| TC5       | Loopback round-trip — write byte 112, transmit → receive → read RX_DATA = 112 | PASS |
| TC6       | Read clears flag — after reading RX_DATA, `CAPTURED_DONE` LOW, STATUS all zero | PASS |
| TC7       | Overrun — byte 200 captured and unread, second byte 55 forced in, 55 dropped, `overrun` HIGH, read returns the oldest byte 200 | PASS |

TC5 is the end-to-end proof: `tx` is wired to `rx`, so a byte written over AXI transmits serially, loops back, is received, and is read back over AXI — verifying the write path, both UART modules, the capture logic, and the read path in one transaction.

**How TC7 forces a second byte:** the loopback TB can't cleanly inject a second byte on demand, so TC7 uses `force`/`release` on the RX submodule's `done` and `rx_byte` to fake a second byte arriving (`done_rising`) while the first is still unread. This proves the drop path and the oldest-held behavior directly.

**SVA:**
- `p_idle_outputs` — in IDLE, all READY signals HIGH and both VALIDs LOW
- `p_write_state` — IDLE + `AWVALID` + `WVALID` → next state WRITE
- `p_read_state` — IDLE + `ARVALID` → next state READ
- `p_bvalid_low` — `BVALID` LOW the cycle after `BREADY`
- `p_rvalid_low` — `RVALID` LOW the cycle after `RREADY`
- `p_captured_done_low` — reading RX_DATA in READ_RESP clears `CAPTURED_DONE`
- `p_overrun_set` — a byte arriving while one is unread sets `overrun`
- `p_oldest_held` — when a byte is dropped, `CAPTURED_RX_BYTE` stays stable (the formal statement of the oldest-held rule; uses `$stable`)

---

## Waveforms

Take these five captures from the behavioral simulation. Signal groups assume the DUT hierarchy `DUT.*` plus the top-level AXI ports.

**1. Write transaction — normal (OKAY):**

*TC2.* Show `clk`, `state`, `tx_start`, `AWADDR`, `AWVALID`, `AWREADY`, `WDATA`, `WVALID`, `WREADY`, `BVALID`, `BRESP`, `BREADY`. `state` steps 0→1→2 (IDLE→WRITE→WRITE_RESP); the AW/W handshakes complete into WRITE; `tx_start` pulses once; `WDATA = 112` loads; `BRESP = 0` (OKAY); and `BVALID` is held until `BREADY` completes the response.

![Write OKAY](docs/waveform_write_okay.png)

**2. Write transaction — bad address (SLVERR):**

*TC3.* Same signal group as above. The key contrast: `AWADDR = 0x04` (unmapped write) with `WDATA = 243`, `tx_start` never pulses, and `BRESP = 2` (SLVERR). Placed next to capture 1, it shows the wrapper rejecting a bad address instead of transmitting.

![Write SLVERR](docs/waveform_write_slverr.png)

**3. `tx_start` is exactly one cycle wide:**

*TC2, zoomed on the WRITE→WRITE_RESP transition.* Show `clk`, `state`, `tx_start`, zoomed so individual clock edges are visible. `tx_start` is high for exactly one clock period while `state = 1` (WRITE), then drops as the FSM enters `state = 2` (WRITE_RESP). This is the direct proof of why WRITE is its own state — the pulse lasts one cycle even though the response wait that follows can take many. It's the write-side analogue of the read-side "latch once, then hold" argument.

![tx_start one cycle](docs/waveform_tx_start_one_cycle.png)

**4. Two reads back-to-back — STATUS then loopback RX_DATA:**

*TC4 into TC5.* Show `clk`, `state`, `ARADDR`, `ARVALID`, `ARREADY`, `RVALID`, `RRESP`, `RREADY`, `CAPTURED_RX_BYTE`, `RDATA`, `CAPTURED_DONE`. Two full read transactions are visible, each cycling `state` through 0→3→4 (IDLE→READ→READ_RESP): first `ARADDR = 0x08` (STATUS, `RDATA = 1` — `tx_busy` still high from the earlier write), then `ARADDR = 0x04` (RX_DATA, `RDATA = 112`). `CAPTURED_RX_BYTE` holds `112` across both. This is the clearest proof of the whole path *and* the read FSM: a byte written over AXI has transmitted serially, looped back through `rx`, been received into `CAPTURED_RX_BYTE`, and is read back over AXI with the correct value — and you can see READ latch the response one cycle before READ_RESP holds it through the handshake.

![Two reads: STATUS then RX_DATA](docs/waveform_reads_status_rxdata.png)

**5. Overrun — oldest byte held, new byte dropped:**

*During TC7.* Show `clk`, `state`, `ARADDR`, `RVALID`, `RREADY`, `CAPTURED_RX_BYTE`, `RDATA`, `CAPTURED_DONE`, `overrun`, `done_rising`, `done_prev`. This is the money shot for the RX policy: `CAPTURED_RX_BYTE` transitions `112 → 200` when the first byte is captured, then **holds at 200** for the rest of the window; a second `done_rising` pulse arrives while `CAPTURED_DONE` is already high; `overrun` goes high; `CAPTURED_RX_BYTE` does **not** change to `55` (the dropped byte); and the following RX_DATA read drives `RDATA = 200` and clears `CAPTURED_DONE` and `overrun`. If you can only add one new waveform to the repo, add this one — it's the visual statement of the entire RX-buffering design decision.

![Overrun oldest held](docs/waveform_overrun_oldest_held.png)

---

## Timing (post-implementation)

![Design timing summary](docs/timing_design_summary.png)

All user-specified timing constraints are met: WNS = **+6.107 ns**, WHS = **+0.154 ns**, WPWS = **+4.500 ns**, with 0 failing endpoints out of 187 (setup/hold) and 101 (pulse width). At the 100 MHz (10 ns) constraint this gives **Fmax ≈ 257 MHz** (1 / (10 − 6.107) ns).

![Intra-clock critical paths](docs/timing_critical_paths.png)

The critical path (Path 1, slack 6.107 ns) runs from the **FSM state register** (`FSM_sequential_state_reg[0]/C`) to the **`RRESP` register** (`RRESP_reg[1]/R`) — the read-response decode. Total delay is 3.404 ns, dominated by net delay (2.700 ns) over logic delay (0.704 ns), which is typical for a small design where routing, not logic depth, sets the path. The next cluster of paths (slack ~6.19 ns) all target the `RDATA` register bits, confirming the read-response path is where the design is tightest — consistent with READ being the state that latches the entire read response in one cycle.

---

## Bugs Found and Fixed

### Bug 1: Uninitialized inputs poisoned `state`
**Detected by:** Waveform inspection — `state` showed X mid-simulation
**Root cause:** Testbench inputs (`ARVALID`, `BREADY`, `RREADY`, `rx`) were left uninitialized and floated at X. The IDLE next-state logic reads `ARVALID` in a ternary, so an X condition produced an X next-state.
**Fix:** Initialized every DUT input to a known value at the top of the `initial` block, before reset.

### Bug 2: `CAPTURED_DONE` wouldn't clear — level vs edge
**Detected by:** Tracing the failing clear cycle-by-cycle in the waveform
**Root cause:** `done` from `uart_rx` is a level, held HIGH for a full bit-period (868 cycles). Using it directly as the set condition re-asserted `CAPTURED_DONE` every cycle. Since the set has priority over the clear, a read during that 868-cycle window would clear the flag only for it to be re-set on the very next edge — the flag could never clear while `done` was still high.
**Fix:** Detected the *rising edge* of `done` instead of its level: `done_prev` registered each cycle, `done_rising = done & ~done_prev` true for one cycle only. The flag now sets once per byte, so a read clears it and it stays cleared.

### Bug 3: New RX byte could overwrite an unread one silently
**Detected by:** Design review of the `done_rising` capture logic
**Root cause:** The capture block latched `CAPTURED_RX_BYTE` and set `CAPTURED_DONE` on every `done_rising`, with no guard. If a second byte arrived before the master read the first, the first byte was overwritten and lost with no indication it had happened.
**Fix:** Gated the capture on `!CAPTURED_DONE` so the oldest unread byte is preserved, and added an `overrun` flag that sets when a byte arrives while one is already unread, so the drop is never silent.

---

## Known limitations

- **Single-byte RX buffer.** The wrapper holds one received byte at a time. Bytes arriving faster than the master reads are dropped, flagged via `overrun`.
- **Directed multi-byte RX test uses forced signals.** TC7 uses `force`/`release` on the RX submodule to inject the second byte, since the loopback testbench has no directly drivable `rx` line.
- **Not run on hardware.** Verification is by behavioral simulation and post-implementation timing only.

---

## How to Simulate

### Requirements
- Xilinx Vivado

### Setting up the project
1. Create a new Vivado project (RTL Project). Use part `xc7a35tcpg236-1` if you plan to synthesize for Basys 3.
2. Add `src/axi4lite_wrapper_uart.sv` (and the `uart_tx.sv` / `uart_rx.sv` it instantiates) as design sources.
3. Add `tb/tb_axi4lite_wrapper_uart.sv` as a simulation source.
4. For timing analysis, add the `.xdc` constraint (defines the 100 MHz clock on `clk`) as a constraint source.

### Run the testbench
1. Right-click `tb/tb_axi4lite_wrapper_uart.sv` → **Set as Top**
2. Flow Navigator → **Run Simulation → Run Behavioral Simulation**
3. In the Tcl Console: `run -all`
4. Check the log for `PASS`/`FAIL` on each of the 7 test cases. TC3's fails are expected (bad-address error path).

### Timing (Fmax)
1. **Run Synthesis → Run Implementation**
2. Open the implemented design → **Report Timing Summary**
3. WNS should be positive (constraints met); Fmax = 1 / (clock period − WNS).
