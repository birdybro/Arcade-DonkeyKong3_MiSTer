// tb/diff/hv_count_diff_tb.sv
// Differential equivalence testbench for dkong3_hv_count.
//
// This is the TEMPLATE for every clock-rework conversion (analysis §7.1):
// instantiate the GOLDEN (original) module and the DUT (reworked) module,
// drive identical stimulus, and assert their outputs match at every point
// where they should agree.
//
// STAGE 0: there is no reworked module yet, so both instances are the original
// dkong3_hv_count driven by the same 24.576 MHz clock. This proves the harness
// (instantiation, stimulus, scoreboard, PASS/FAIL, verilator flow). It passes
// trivially (a module equals itself).
//
// STAGE 2 (when dkong3_hv_count_sync exists): replace the DUT instance with the
// synchronous version, add a 98.304 MHz `clk` + `cen_24m_p` (÷4) driven from the
// same time base as `clk_24m`, clock the DUT on `clk`, and move the compare into
// an `if (cen_24m_p)` block so golden (on its 24.576 edge) and DUT (on the
// aligned CEN tick) are sampled at the same logical instant. The scoreboard and
// stimulus below are reused unchanged.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module hv_count_diff_tb;
  // --- stimulus ---
  logic        clk_24m = 0;
  logic        rst_n;
  logic        vflip;
  logic [8:0]  h_off, v_off;

  // --- golden outputs ---
  logic        g_oclk, g_hbl_n, g_vbl_n, g_cbl_n, g_hs_n, g_vs_n;
  logic [9:0]  g_hcnt;
  logic [7:0]  g_vcnt, g_vfcnt;

  // --- dut outputs ---
  logic        d_oclk, d_hbl_n, d_vbl_n, d_cbl_n, d_hs_n, d_vs_n;
  logic [9:0]  d_hcnt;
  logic [7:0]  d_vcnt, d_vfcnt;

  int sb_errors = 0, sb_checks = 0;

  // 24.576 MHz nominal (period chosen for clean ns; exact value is irrelevant
  // to a functional equivalence check — both DUTs see the identical clock).
  always #20 clk_24m = ~clk_24m;

  // GOLDEN: original module on the 24.576 clock.
  dkong3_hv_count u_gold (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(vflip),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(g_oclk), .H_CNT(g_hcnt), .V_CNT(g_vcnt), .VF_CNT(g_vfcnt),
    .H_BLANKn(g_hbl_n), .V_BLANKn(g_vbl_n), .C_BLANKn(g_cbl_n),
    .H_SYNCn(g_hs_n), .V_SYNCn(g_vs_n)
  );

  // DUT: STAGE 0 == original (golden-vs-golden smoke). STAGE 2 == _sync version.
  dkong3_hv_count u_dut (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(vflip),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(d_oclk), .H_CNT(d_hcnt), .V_CNT(d_vcnt), .VF_CNT(d_vfcnt),
    .H_BLANKn(d_hbl_n), .V_BLANKn(d_vbl_n), .C_BLANKn(d_cbl_n),
    .H_SYNCn(d_hs_n), .V_SYNCn(d_vs_n)
  );

  // Compare all outputs on every 24.576 edge (settled values).
  always @(posedge clk_24m) if (rst_n) begin
    `SB_CHECK("O_CLK",   g_oclk,  d_oclk)
    `SB_CHECK("H_CNT",   g_hcnt,  d_hcnt)
    `SB_CHECK("V_CNT",   g_vcnt,  d_vcnt)
    `SB_CHECK("VF_CNT",  g_vfcnt, d_vfcnt)
    `SB_CHECK("H_BLANKn",g_hbl_n, d_hbl_n)
    `SB_CHECK("V_BLANKn",g_vbl_n, d_vbl_n)
    `SB_CHECK("C_BLANKn",g_cbl_n, d_cbl_n)
    `SB_CHECK("H_SYNCn", g_hs_n,  d_hs_n)
    `SB_CHECK("V_SYNCn", g_vs_n,  d_vs_n)
  end

  initial begin
    // deterministic reset + input plan
    rst_n = 0; vflip = 0; h_off = 9'd0; v_off = 9'd0;
    repeat (10) @(posedge clk_24m);
    rst_n = 1;

    // ~2 full frames at H_count=1536 to exercise H/V counters, blanks, syncs.
    repeat (900_000) @(posedge clk_24m);

    // exercise flip + offsets (both DUTs see them identically)
    vflip = 1; h_off = 9'd5; v_off = 9'd3;
    repeat (400_000) @(posedge clk_24m);

    `SB_REPORT("hv_count_diff")
  end

  // safety net so a hang can't run forever
  initial begin #200_000_000; $fatal(1, "TIMEOUT"); end
endmodule
