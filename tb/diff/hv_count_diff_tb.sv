// tb/diff/hv_count_diff_tb.sv
// Differential equivalence: dkong3_hv_count (GOLDEN, on 24.576 MHz) vs
// dkong3_hv_count_sync (DUT, on the 98.304 MHz master + cen_24m_p).
//
// Alignment: a ÷4 phase `ph` off the master generates clk_24m = ph[1] (the
// golden's clock) and cen_24m_p = (ph==1), which makes the DUT advance on the
// SAME master edge that clk_24m rises (the golden's posedge). Both are then
// stable for the rest of the 24.576 period; we compare at ph==3 (settled).
`timescale 1ns/1ps
`include "sim_pkg.svh"

module hv_count_diff_tb;
  logic       clk = 0;
  logic [1:0] ph  = 0;
  logic       rst_n, vflip;
  logic [8:0] h_off, v_off;

  always #5 clk = ~clk;                 // 98.304-ish master (period irrelevant)
  always @(posedge clk) ph <= ph + 2'd1;
  wire clk_24m   = ph[1];               // golden clock (÷4, 50% duty)
  wire cen_24m_p = (ph == 2'd1);        // DUT enable, aligned to clk_24m posedge

  // golden outputs
  logic       g_oclk, g_hbl_n, g_vbl_n, g_cbl_n, g_hs_n, g_vs_n;
  logic [9:0] g_hcnt; logic [7:0] g_vcnt, g_vfcnt;
  // dut outputs
  logic       d_oclk, d_hbl_n, d_vbl_n, d_cbl_n, d_hs_n, d_vs_n;
  logic [9:0] d_hcnt; logic [7:0] d_vcnt, d_vfcnt;

  int sb_errors = 0, sb_checks = 0;

  dkong3_hv_count u_gold (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(vflip),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(g_oclk), .H_CNT(g_hcnt), .V_CNT(g_vcnt), .VF_CNT(g_vfcnt),
    .H_BLANKn(g_hbl_n), .V_BLANKn(g_vbl_n), .C_BLANKn(g_cbl_n),
    .H_SYNCn(g_hs_n), .V_SYNCn(g_vs_n)
  );

  dkong3_hv_count_sync u_dut (
    .clk(clk), .cen_24m_p(cen_24m_p), .I_RST_n(rst_n), .I_VFLIP(vflip),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(d_oclk), .H_CNT(d_hcnt), .V_CNT(d_vcnt), .VF_CNT(d_vfcnt),
    .H_BLANKn(d_hbl_n), .V_BLANKn(d_vbl_n), .C_BLANKn(d_cbl_n),
    .H_SYNCn(d_hs_n), .V_SYNCn(d_vs_n),
    .cen_o_clk_p(), .cen_o_clk_n()
  );

  // compare at ph==3 (both settled after the ph 1->2 update edge)
  always @(posedge clk) if (rst_n && ph == 2'd3) begin
    `SB_CHECK("O_CLK",    g_oclk,  d_oclk)
    `SB_CHECK("H_CNT",    g_hcnt,  d_hcnt)
    `SB_CHECK("V_CNT",    g_vcnt,  d_vcnt)
    `SB_CHECK("VF_CNT",   g_vfcnt, d_vfcnt)
    `SB_CHECK("H_BLANKn", g_hbl_n, d_hbl_n)
    `SB_CHECK("V_BLANKn", g_vbl_n, d_vbl_n)
    `SB_CHECK("C_BLANKn", g_cbl_n, d_cbl_n)
    `SB_CHECK("H_SYNCn",  g_hs_n,  d_hs_n)
    `SB_CHECK("V_SYNCn",  g_vs_n,  d_vs_n)
  end

  initial begin
    rst_n = 0; vflip = 0; h_off = 9'd0; v_off = 9'd0;
    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (4_000_000) @(posedge clk);          // ~2.5 frames @98.304/4

    vflip = 1; h_off = 9'd5; v_off = 9'd3;
    repeat (2_000_000) @(posedge clk);

    `SB_REPORT("hv_count_diff")
  end

  initial begin #400_000_000; $fatal(1, "TIMEOUT"); end
endmodule
