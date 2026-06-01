// tb/diff/col_pal_diff_tb.sv
// Differential equivalence for the colour palette:
//   GOLDEN : dkong3_col_pal     (posedge I_CLK_6M=H_CNT[0] / negedge self-reset)
//   DUT    : dkong3_col_pal_sync (single clk + cen_hcnt0_p / cen_24m_p)
//
// A shared hv_count chain supplies H_CNT[0] (golden 6M clock) and the
// cen_hcnt0_p strobe (DUT). The CLUT PROMs (1D/1C) are loaded with identical
// content via the shared download port; an LFSR drives the pixel inputs into
// both and the scoreboard asserts O_R/O_G/O_B match at the quiet phase.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module col_pal_diff_tb;
  logic       clk = 0;
  logic [1:0] ph  = 0;
  always #5 clk = ~clk;
  always @(posedge clk) ph <= ph + 2'd1;

  wire clk_24m   = ph[1];
  wire cen_24m_p = (ph == 2'd1);

  // ---- shared stimulus ----
  logic        rst_n;
  logic [5:0]  i_vram_d, i_obj_d;
  logic        i_cmpblkn;
  logic [1:0]  i_cpal_sel;
  logic        dlwr;
  logic [17:0] dladdr;
  logic [7:0]  dldata;
  logic        compare_en = 0;

  // ---- shared hv chains (for H_CNT[0] / cen_hcnt0_p) ----
  wire        g_oclk, g_hbl, g_vbl, g_cbl, g_hs, g_vs;
  wire [9:0]  g_hcnt;  wire [7:0] g_vcnt, g_vfcnt;
  dkong3_hv_count u_g_hv (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(1'b0),
    .H_OFFSET(9'd0), .V_OFFSET(9'd0),
    .O_CLK(g_oclk), .H_CNT(g_hcnt), .V_CNT(g_vcnt), .VF_CNT(g_vfcnt),
    .H_BLANKn(g_hbl), .V_BLANKn(g_vbl), .C_BLANKn(g_cbl),
    .H_SYNCn(g_hs), .V_SYNCn(g_vs)
  );

  wire        d_oclk, d_hbl, d_vbl, d_cbl, d_hs, d_vs;
  wire [9:0]  d_hcnt;  wire [7:0] d_vcnt, d_vfcnt;
  wire        cen_o_clk_p, cen_o_clk_n, cen_hcnt0_p, cen_hcnt2_p, cen_hcnt6_p, cen_hcnt9_n;
  dkong3_hv_count_sync u_d_hv (
    .clk(clk), .cen_24m_p(cen_24m_p), .I_RST_n(rst_n), .I_VFLIP(1'b0),
    .H_OFFSET(9'd0), .V_OFFSET(9'd0),
    .O_CLK(d_oclk), .H_CNT(d_hcnt), .V_CNT(d_vcnt), .VF_CNT(d_vfcnt),
    .H_BLANKn(d_hbl), .V_BLANKn(d_vbl), .C_BLANKn(d_cbl),
    .H_SYNCn(d_hs), .V_SYNCn(d_vs),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt0_p(cen_hcnt0_p), .cen_hcnt2_p(cen_hcnt2_p),
    .cen_hcnt6_p(cen_hcnt6_p), .cen_hcnt9_n(cen_hcnt9_n)
  );

  // ---- GOLDEN col_pal ----
  wire [3:0] g_r, g_g, g_b;
  dkong3_col_pal u_g_cp (
    .I_CLK_24M(clk_24m), .I_CLK_6M(g_hcnt[0]),
    .I_VRAM_D(i_vram_d), .I_OBJ_D(i_obj_d),
    .I_CMPBLKn(i_cmpblkn), .I_CPAL_SEL(i_cpal_sel),
    .I_DLCLK(clk), .I_DLADDR({1'b0,dladdr[16:0]}), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_R(g_r), .O_G(g_g), .O_B(g_b)
  );

  // ---- DUT col_pal_sync ----
  wire [3:0] d_r, d_g, d_b;
  dkong3_col_pal_sync u_d_cp (
    .clk(clk), .cen_24m_p(cen_24m_p), .cen_hcnt0_p(cen_hcnt0_p),
    .I_VRAM_D(i_vram_d), .I_OBJ_D(i_obj_d),
    .I_CMPBLKn(i_cmpblkn), .I_CPAL_SEL(i_cpal_sel),
    .I_DLCLK(clk), .I_DLADDR({1'b0,dladdr[16:0]}), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_R(d_r), .O_G(d_g), .O_B(d_b)
  );

  // ---- scoreboard ----
  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (compare_en && rst_n && ph == 2'd3) begin
    `SB_CHECK("O_R", g_r, d_r)
    `SB_CHECK("O_G", g_g, d_g)
    `SB_CHECK("O_B", g_b, d_b)
  end

  // ---- stimulus ----
  function [7:0] rom_data(input [17:0] a);
    rom_data = a[7:0] ^ a[15:8] ^ 8'h93;
  endfunction

  task dl_write(input [17:0] a);
    begin
      dladdr = a; dldata = rom_data(a); dlwr = 1'b1;
      repeat (8) @(posedge clk);
    end
  endtask

  integer k;
  reg [15:0] lfsr;

  initial begin
    rst_n = 0; i_vram_d = 0; i_obj_d = 0; i_cmpblkn = 1; i_cpal_sel = 0;
    dlwr = 0; dladdr = 0; dldata = 0; lfsr = 16'h1234;

    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // load CLUT PROMs: 1D 0x12000..0x121FF, 1C 0x12200..0x123FF
    for (k = 0; k < 512; k = k + 1) dl_write(18'h12000 + k);
    for (k = 0; k < 512; k = k + 1) dl_write(18'h12200 + k);
    dlwr = 0;

    compare_en = 1;
    for (k = 0; k < 1_500_000; k = k + 1) begin
      @(posedge clk);
      if (ph == 2'd0) begin
        lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        i_vram_d   = lfsr[5:0];
        i_obj_d    = lfsr[11:6] ^ {lfsr[1:0],lfsr[15:12]};
        i_cpal_sel = lfsr[13:12];
        i_cmpblkn  = lfsr[14];       // exercise the self-resetting latch
      end
    end

    `SB_REPORT("col_pal_diff")
  end

  initial begin #200_000_000; $fatal(1, "TIMEOUT"); end
endmodule
