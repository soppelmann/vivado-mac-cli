// hello.sv — hold the button, the LED flashes at ~2 Hz; or the PS forces it on over AXI.
//
// SystemVerilog refresher, line by line:
//   module/endmodule   : one hardware block, like a chip with pins (the ports)
//   input logic        : a wire coming in ("logic" replaces reg/wire; use it everywhere)
//   localparam         : a named constant, resolved at compile time
//   always_ff          : flip-flops — this block runs once per rising clock edge
//   always_comb        : pure combinational logic (no clock, no memory)
//   <=                 : non-blocking assignment, the only kind to use inside always_ff
//   =                  : blocking assignment, used in always_comb and for constants
//   cnt[23]            : one bit of a vector; the MSB of a 24-bit counter toggles slowly

module hello #(
    parameter int CLK_HZ   = 100_000_000,  // set to the real PL clock frequency
    parameter int FLASH_HZ = 2             // flashes per second while the button is held
) (
    input  logic clk,   // PL clock from the module/carrier (see te0820.xdc)
    input  logic btn,   // push button; set BTN_ACTIVE_LOW below to match the board
    input  logic [0:0] force_on, // phase 2: AXI GPIO bit 0 from the PS (FreeBSD) forces the LED on
    output logic led
);
    // Many carrier boards wire buttons active-low (pressed = 0). Flip this if
    // the LED flashes while the button is NOT pressed.
    localparam bit BTN_ACTIVE_LOW = 1'b1;

    // A counter that overflows FLASH_HZ*2 times per second; its top bit is the blink.
    // $clog2 = bits needed to count to N. For 100 MHz and 2 Hz: 25,000,000 → 25 bits.
    localparam int PERIOD = CLK_HZ / (2 * FLASH_HZ);
    localparam int W      = $clog2(PERIOD);

    logic           pressed;                 // button, normalized to 1 = pressed
    logic [1:0]     btn_sync;                // two flip-flops to tame metastability
    logic [W-1:0]   cnt;
    logic           blink;

    // 1. bring the asynchronous button into the clock domain
    always_ff @(posedge clk) btn_sync <= {btn_sync[0], btn};
    always_comb pressed = BTN_ACTIVE_LOW ? ~btn_sync[1] : btn_sync[1];

    // 2. free-running divider: toggles 'blink' every PERIOD clocks
    always_ff @(posedge clk) begin
        if (cnt == PERIOD - 1) begin
            cnt   <= '0;         // '0 = "all bits zero", width inferred
            blink <= ~blink;
        end else begin
            cnt <= cnt + 1'b1;
        end
    end

    // 3. the LED: blink while pressed, or steady on when the CPU says so
    always_comb led = (pressed & blink) | force_on[0];
endmodule
