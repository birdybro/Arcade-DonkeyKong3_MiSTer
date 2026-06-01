// tb/diff/obj_diff_tb.sv
// Differential equivalence for the sprite/object engine:
//   GOLDEN : dkong3_hv_count (24.576) + dkong3_obj      (fabric/ripple/gated clocks)
//   DUT    : dkong3_hv_count_sync     + dkong3_obj_sync (single clk + CENs)
//
// Same ÷4 phase scheme as the other diff TBs. obj's I_CLK_12M is O_CLK itself
// (not the inverted copy vram gets), and obj_sync also needs O_CLK as a *level*
// (I_OCLK) for the CLK_5L/CLK_3E gated-clock decodes. The OBJ RAM is pre-filled
// by a DMA sweep, the OBJ ROMs are loaded via the shared download port, then the
// engine free-runs off the H/V counters; the scoreboard asserts every output
// (O_OBJ_DO, O_FLIP_VRAM, O_FLIP_HV, O_L_CMPBLKn) matches at the quiet phase.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module obj_diff_tb;
  logic       clk = 0;
  logic [1:0] ph  = 0;
  always #5 clk = ~clk;
  always @(posedge clk) ph <= ph + 2'd1;

  wire clk_24m   = ph[1];
  wire cen_24m_p = (ph == 2'd1);
  wire cen_24m_n = (ph == 2'd3);

  // ---- shared stimulus ----
  logic        rst_n, vflip_hv;
  logic [8:0]  h_off = 0, v_off = 0;
  logic [9:0]  i_ab;
  logic [7:0]  i_db;
  logic        i_obj_wrn, i_obj_rdn, i_obj_rqn;
  logic        i_2psl, i_flipn, i_cmpblkn, flip_screen;
  logic [9:0]  i_dma_a;
  logic [7:0]  i_dma_d;
  logic        i_dma_ce;
  logic        dlwr;
  logic [17:0] dladdr;
  logic [7:0]  dldata;
  logic        compare_en = 0;

  // =========================================================================
  // GOLDEN
  // =========================================================================
  wire        g_oclk, g_hbl, g_vbl, g_cbl, g_hs, g_vs;
  wire [9:0]  g_hcnt;  wire [7:0] g_vcnt, g_vfcnt;

  dkong3_hv_count u_g_hv (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(vflip_hv),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(g_oclk), .H_CNT(g_hcnt), .V_CNT(g_vcnt), .VF_CNT(g_vfcnt),
    .H_BLANKn(g_hbl), .V_BLANKn(g_vbl), .C_BLANKn(g_cbl),
    .H_SYNCn(g_hs), .V_SYNCn(g_vs)
  );

  wire [5:0] g_objdo;  wire g_flipv, g_fliphv, g_lcmpblkn;

  dkong3_obj u_g_obj (
    .I_CLK_24M(clk_24m), .I_CLK_12M(g_oclk),
    .I_AB(i_ab), .I_DB(i_db),
    .I_OBJ_WRn(i_obj_wrn), .I_OBJ_RDn(i_obj_rdn), .I_OBJ_RQn(i_obj_rqn),
    .I_2PSL(i_2psl), .I_FLIPn(i_flipn), .I_CMPBLKn(i_cmpblkn),
    .I_H_CNT(g_hcnt), .I_VF_CNT(g_vfcnt),
    .I_OBJ_DMA_A(i_dma_a), .I_OBJ_DMA_D(i_dma_d), .I_OBJ_DMA_CE(i_dma_ce),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .flip_screen(flip_screen),
    .O_DB(), .O_OBJ_DO(g_objdo),
    .O_FLIP_VRAM(g_flipv), .O_FLIP_HV(g_fliphv), .O_L_CMPBLKn(g_lcmpblkn)
  );

  // =========================================================================
  // DUT
  // =========================================================================
  wire        d_oclk, d_hbl, d_vbl, d_cbl, d_hs, d_vs;
  wire [9:0]  d_hcnt;  wire [7:0] d_vcnt, d_vfcnt;
  wire        cen_o_clk_p, cen_o_clk_n, cen_hcnt0_p, cen_hcnt2_p, cen_hcnt6_p, cen_hcnt9_n;

  dkong3_hv_count_sync u_d_hv (
    .clk(clk), .cen_24m_p(cen_24m_p), .I_RST_n(rst_n), .I_VFLIP(vflip_hv),
    .H_OFFSET(h_off), .V_OFFSET(v_off),
    .O_CLK(d_oclk), .H_CNT(d_hcnt), .V_CNT(d_vcnt), .VF_CNT(d_vfcnt),
    .H_BLANKn(d_hbl), .V_BLANKn(d_vbl), .C_BLANKn(d_cbl),
    .H_SYNCn(d_hs), .V_SYNCn(d_vs),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt0_p(cen_hcnt0_p), .cen_hcnt2_p(cen_hcnt2_p),
    .cen_hcnt6_p(cen_hcnt6_p), .cen_hcnt9_n(cen_hcnt9_n)
  );

  wire [5:0] d_objdo;  wire d_flipv, d_fliphv, d_lcmpblkn;

  dkong3_obj_sync u_d_obj (
    .clk(clk),
    .cen_24m_p(cen_24m_p), .cen_24m_n(cen_24m_n),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt9_n(cen_hcnt9_n), .I_OCLK(d_oclk),
    .I_AB(i_ab), .I_DB(i_db),
    .I_OBJ_WRn(i_obj_wrn), .I_OBJ_RDn(i_obj_rdn), .I_OBJ_RQn(i_obj_rqn),
    .I_2PSL(i_2psl), .I_FLIPn(i_flipn), .I_CMPBLKn(i_cmpblkn),
    .I_H_CNT(d_hcnt), .I_VF_CNT(d_vfcnt),
    .I_OBJ_DMA_A(i_dma_a), .I_OBJ_DMA_D(i_dma_d), .I_OBJ_DMA_CE(i_dma_ce),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .flip_screen(flip_screen),
    .O_DB(), .O_OBJ_DO(d_objdo),
    .O_FLIP_VRAM(d_flipv), .O_FLIP_HV(d_fliphv), .O_L_CMPBLKn(d_lcmpblkn)
  );

  // =========================================================================
  // Scoreboard
  // =========================================================================
  int sb_errors = 0, sb_checks = 0;

  always @(posedge clk) if (compare_en && rst_n && ph == 2'd3) begin
    `SB_CHECK("O_OBJ_DO",    g_objdo,    d_objdo)
    `SB_CHECK("O_FLIP_VRAM", g_flipv,    d_flipv)
    `SB_CHECK("O_FLIP_HV",   g_fliphv,   d_fliphv)
    `SB_CHECK("O_L_CMPBLKn", g_lcmpblkn, d_lcmpblkn)
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  function [7:0] rom_data(input [17:0] a);
    rom_data = a[7:0] ^ a[15:8] ^ 8'hA5;
  endfunction

  task dl_write(input [17:0] a);
    begin
      dladdr = a; dldata = rom_data(a); dlwr = 1'b1;
      repeat (8) @(posedge clk);   // hold across a full clk_24m period (golden DL clk)
    end
  endtask

  integer k;

  initial begin
    rst_n = 0; vflip_hv = 0; flip_screen = 0;
    i_ab = 0; i_db = 0; i_obj_wrn = 1; i_obj_rdn = 1; i_obj_rqn = 1;
    i_2psl = 0; i_flipn = 1; i_cmpblkn = 1;
    i_dma_a = 0; i_dma_d = 0; i_dma_ce = 0;
    dlwr = 0; dladdr = 0; dldata = 0;

    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- pre-fill OBJ RAM via a DMA write sweep ----
    i_dma_ce = 1;
    for (k = 0; k < 1024; k = k + 1) begin
      i_dma_a = k[9:0];
      i_dma_d = k[7:0] ^ {k[9:2]} ^ 8'h6C;
      repeat (16) @(posedge clk);   // >= 1 negedge-O_CLK write window
    end
    i_dma_ce = 0;

    // ---- load OBJ ROMs (7C/7D/7E/7F : 0x0A000..0x0DFFF) ----
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0A000 + k);
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0B000 + k);
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0C000 + k);
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0D000 + k);
    dlwr = 0;

    // ---- let the internal 2EH/7M RAMs fill for ~1 frame ----
    i_2psl = 1'b0; i_flipn = 1'b1; i_cmpblkn = 1'b1; flip_screen = 1'b0;
    repeat (1_700_000) @(posedge clk);

    // ---- compare across ~2 frames ----
    compare_en = 1;
    repeat (3_400_000) @(posedge clk);

    // ---- flip-screen + offsets ----
    flip_screen = 1'b1; i_flipn = 1'b0; vflip_hv = 1'b1;
    h_off = 9'd4; v_off = 9'd2;
    repeat (1_700_000) @(posedge clk);

    // ---- toggle 2PSL / CMPBLK pattern ----
    i_2psl = 1'b1; i_cmpblkn = 1'b0;
    repeat (1_700_000) @(posedge clk);

    `SB_REPORT("obj_diff")
  end

  initial begin #600_000_000; $fatal(1, "TIMEOUT"); end
endmodule
