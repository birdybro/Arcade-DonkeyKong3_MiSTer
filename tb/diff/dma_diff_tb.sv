// tb/diff/dma_diff_tb.sv
// Differential equivalence for the sprite DMA:
//   GOLDEN : dkong3_dma      on a divided "cpu" clock (dclk)
//   DUT    : dkong3_dma_sync on clk + an enable aligned to dclk's posedge
//
// The DMA is a self-contained state machine triggered by I_DMA_TRIG; both
// instances advance on the same master edges (golden on dclk posedge, DUT on
// the cen tick one cycle earlier) and read an identical source model
// (I_DMA_DS = f(O_DMA_AS)). The scoreboard asserts the full address/data/CE
// transfer sequence matches at the quiet phase.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module dma_diff_tb;
  logic       clk = 0;
  logic [2:0] cnt = 0;
  always #5 clk = ~clk;
  always @(posedge clk) cnt <= (cnt == 3'd5) ? 3'd0 : cnt + 3'd1;

  wire dclk = (cnt >= 3'd3);     // golden cpu clock (÷6, ~50% duty)
  wire cen  = (cnt == 3'd2);     // DUT advances on cnt 2->3 = golden dclk posedge

  logic rst_n, trig;

  // golden
  wire [9:0] g_as, g_ad;  wire [7:0] g_dd;  wire g_ces, g_ced;
  wire [7:0] g_ds = g_as[7:0] ^ {g_as[9:8],6'b0} ^ 8'h2D;
  dkong3_dma u_g (
    .I_CLK(dclk), .I_RSTn(rst_n), .I_DMA_TRIG(trig), .I_DMA_DS(g_ds),
    .O_DMA_AS(g_as), .O_DMA_AD(g_ad), .O_DMA_DD(g_dd),
    .O_DMA_CES(g_ces), .O_DMA_CED(g_ced)
  );

  // dut
  wire [9:0] d_as, d_ad;  wire [7:0] d_dd;  wire d_ces, d_ced;
  wire [7:0] d_ds = d_as[7:0] ^ {d_as[9:8],6'b0} ^ 8'h2D;
  dkong3_dma_sync u_d (
    .clk(clk), .cen(cen), .I_RSTn(rst_n), .I_DMA_TRIG(trig), .I_DMA_DS(d_ds),
    .O_DMA_AS(d_as), .O_DMA_AD(d_ad), .O_DMA_DD(d_dd),
    .O_DMA_CES(d_ces), .O_DMA_CED(d_ced)
  );

  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (cnt == 3'd5) begin
    `SB_CHECK("O_DMA_AS",  g_as,  d_as)
    `SB_CHECK("O_DMA_AD",  g_ad,  d_ad)
    `SB_CHECK("O_DMA_DD",  g_dd,  d_dd)
    `SB_CHECK("O_DMA_CES", g_ces, d_ces)
    `SB_CHECK("O_DMA_CED", g_ced, d_ced)
  end

  integer t;
  initial begin
    rst_n = 0; trig = 0;
    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // a few DMA bursts
    for (t = 0; t < 3; t = t + 1) begin
      repeat (200) @(posedge clk);
      trig = 1;
      repeat (12000) @(posedge clk);   // > 0x19F*4 steps * 6 clks/step
      trig = 0;
      repeat (2000) @(posedge clk);
    end

    `SB_REPORT("dma_diff")
  end

  initial begin #20_000_000; $fatal(1, "TIMEOUT"); end
endmodule
