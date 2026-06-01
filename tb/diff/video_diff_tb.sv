// tb/diff/video_diff_tb.sv
// Whole-video-group differential equivalence (Stage 3.4 integration):
//   GOLDEN : dkong3_hv_count + dkong3_video      (vram+obj+col_pal, fabric clks)
//   DUT    : dkong3_hv_count_sync + dkong3_video_sync (single clk + CENs)
//
// All ROMs (char/colour PROM, video ROM, object ROM, CLUT PROMs) are loaded
// with identical content via the shared download port; VRAM is pre-filled with
// CPU writes and OBJ RAM with a DMA sweep. The engine then free-runs off the H/V
// counters with LFSR-varied CPU/control inputs, and the scoreboard asserts the
// end-to-end outputs (VRAM data/busy, flip, and the final RGB) match.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module video_diff_tb;
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
  logic [9:0]  i_cpu_a;
  logic [7:0]  i_cpu_d;
  logic        i_vram_wrn, i_vram_rdn;
  logic [7:0]  i_3e_q;
  logic        i_cblankn, flip_screen;
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

  wire [7:0] g_vdb, g_odb;  wire g_busyn, g_fliphv;
  wire [3:0] g_r, g_g, g_b;
  dkong3_video u_g_vid (
    .I_CLK_24M(clk_24m), .I_CLK_12M(g_oclk), .I_RESETn(rst_n),
    .I_CPU_A(i_cpu_a), .I_CPU_D(i_cpu_d),
    .I_VRAM_WRn(i_vram_wrn), .I_VRAM_RDn(i_vram_rdn),
    .I_3E_Q(i_3e_q), .I_H_CNT(g_hcnt), .I_VF_CNT(g_vfcnt), .I_CBLANKn(i_cblankn),
    .I_OBJDMA_A(i_dma_a), .I_OBJDMA_D(i_dma_d), .I_OBJDMA_CE(i_dma_ce),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .flip_screen(flip_screen),
    .O_VRAM_DB(g_vdb), .O_VRAMBUSYn(g_busyn), .O_FLIP_HV(g_fliphv),
    .O_OBJ_DB(g_odb), .O_VGA_RED(g_r), .O_VGA_GRN(g_g), .O_VGA_BLU(g_b)
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

  wire [7:0] d_vdb, d_odb;  wire d_busyn, d_fliphv;
  wire [3:0] d_r, d_g, d_b;
  dkong3_video_sync u_d_vid (
    .clk(clk),
    .cen_24m_p(cen_24m_p), .cen_24m_n(cen_24m_n),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt0_p(cen_hcnt0_p), .cen_hcnt2_p(cen_hcnt2_p),
    .cen_hcnt6_p(cen_hcnt6_p), .cen_hcnt9_n(cen_hcnt9_n),
    .I_OCLK(d_oclk),
    .I_RESETn(rst_n),
    .I_CPU_A(i_cpu_a), .I_CPU_D(i_cpu_d),
    .I_VRAM_WRn(i_vram_wrn), .I_VRAM_RDn(i_vram_rdn),
    .I_3E_Q(i_3e_q), .I_H_CNT(d_hcnt), .I_VF_CNT(d_vfcnt), .I_CBLANKn(i_cblankn),
    .I_OBJDMA_A(i_dma_a), .I_OBJDMA_D(i_dma_d), .I_OBJDMA_CE(i_dma_ce),
    .I_DLCLK(clk),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .flip_screen(flip_screen),
    .O_VRAM_DB(d_vdb), .O_VRAMBUSYn(d_busyn), .O_FLIP_HV(d_fliphv),
    .O_OBJ_DB(d_odb), .O_VGA_RED(d_r), .O_VGA_GRN(d_g), .O_VGA_BLU(d_b)
  );

  // =========================================================================
  // Scoreboard
  // =========================================================================
  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (compare_en && rst_n && ph == 2'd3) begin
    `SB_CHECK("O_VRAM_DB",   g_vdb,   d_vdb)
    `SB_CHECK("O_VRAMBUSYn", g_busyn, d_busyn)
    `SB_CHECK("O_FLIP_HV",   g_fliphv,d_fliphv)
    `SB_CHECK("O_VGA_RED",   g_r,     d_r)
    `SB_CHECK("O_VGA_GRN",   g_g,     d_g)
    `SB_CHECK("O_VGA_BLU",   g_b,     d_b)
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  function [7:0] rom_data(input [17:0] a);
    rom_data = a[7:0] ^ a[15:8] ^ a[17:16] ^ 8'h5A;
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
    rst_n = 0; vflip_hv = 0; flip_screen = 0;
    i_cpu_a = 0; i_cpu_d = 0; i_vram_wrn = 1; i_vram_rdn = 1;
    i_3e_q = 8'h00; i_cblankn = 1;
    i_dma_a = 0; i_dma_d = 0; i_dma_ce = 0;
    dlwr = 0; dladdr = 0; dldata = 0; lfsr = 16'hBEEF;

    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- load all ROMs ----
    for (k = 0; k < 256;  k = k + 1) dl_write(18'h12400 + k);  // char colour PROM 2N
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h06000 + k);  // VID ROM 3P
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h07000 + k);  // VID ROM 3N
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0A000 + k);  // OBJ 7C
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0B000 + k);  // OBJ 7D
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0C000 + k);  // OBJ 7E
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h0D000 + k);  // OBJ 7F
    for (k = 0; k < 512;  k = k + 1) dl_write(18'h12000 + k);  // CLUT 1D
    for (k = 0; k < 512;  k = k + 1) dl_write(18'h12200 + k);  // CLUT 1C
    dlwr = 0;

    // ---- pre-fill OBJ RAM via DMA sweep ----
    i_dma_ce = 1;
    for (k = 0; k < 1024; k = k + 1) begin
      i_dma_a = k[9:0];
      i_dma_d = k[7:0] ^ {k[9:2]} ^ 8'h6C;
      repeat (16) @(posedge clk);
    end
    i_dma_ce = 0;

    // ---- pre-fill VRAM via CPU write sweep (CPU mode, write) ----
    i_cblankn = 0; i_vram_rdn = 1; i_vram_wrn = 0;
    for (k = 0; k < 1024; k = k + 1) begin
      i_cpu_a = k[9:0];
      i_cpu_d = k[7:0] ^ {k[9:2]} ^ 8'h3C;
      repeat (16) @(posedge clk);
    end
    i_vram_wrn = 1; i_cblankn = 1;

    // ---- warm up internal RAMs for ~1 frame ----
    repeat (1_700_000) @(posedge clk);

    // ---- compare across frames with LFSR-varied CPU/control ----
    compare_en = 1;
    for (k = 0; k < 5_000_000; k = k + 1) begin
      @(posedge clk);
      if (ph == 2'd0) begin
        lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        i_cpu_a    = lfsr[9:0];
        i_cpu_d    = lfsr[7:0] ^ lfsr[15:8];
        i_vram_wrn = lfsr[11] | lfsr[12];
        i_vram_rdn = lfsr[13];
        i_3e_q     = {lfsr[6:5], 4'b0, lfsr[1], lfsr[3]}; // CPAL_SEL,2PSL,FLIPn,GFXBANK
        flip_screen = lfsr[14] & lfsr[2];
      end
    end

    `SB_REPORT("video_diff")
  end

  initial begin #900_000_000; $fatal(1, "TIMEOUT"); end
endmodule
