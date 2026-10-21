// top.sv — replace with your design. Ports become block-design pins; `clk` is wired to pl_clk0.
module top (
    input  logic clk,
    output logic led
);
    logic [25:0] cnt;
    always_ff @(posedge clk) cnt <= cnt + 1'b1;
    always_comb led = cnt[25];
endmodule
