// tb/diff/vram_diff_tb.sv
// Differential equivalence for the coupled video timing group:
//   GOLDEN : dkong3_hv_count (24.576) + dkong3_vram     (fabric-derived clocks)
//   DUT    : dkong3_hv_count_sync     + dkong3_vram_sync (single clk + CENs)
//
// Alignment is the same ÷4 phase scheme as hv_count_diff_tb: a 2-bit `ph` off
// the 98.304-ish master gives clk_24m = ph[1] (the golden's 24M clock),
// cen_24m_p = (ph==1) (DUT 24M-posedge enable) and cen_24m_n = (ph==3) (DUT
// 24M-negedge enable, for the LS174 colour latch). The hv_count_sync emits the
// O_CLK / H_CNT-bit strobes the vram_sync consumes. Inputs change on ph==0
// (quiet) and outputs are compared on ph==3 (quiet) so every flop is settled.
//
// Both ROM sets (COL PROM 2N, VID ROM 3P/3N) are loaded with identical pseudo-
// random content via the shared download port; VRAM is pre-filled with a CPU
// write sweep. After that, an LFSR drives the CPU/scan inputs identically into
// both chains and the scoreboard asserts every output matches.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module vram_diff_tb;
  logic       clk = 0;
  logic [1:0] ph  = 0;
  always #5 clk = ~clk;
  always @(posedge clk) ph <= ph + 2'd1;

  wire clk_24m   = ph[1];          // golden 24.576 clock
  wire cen_24m_p = (ph == 2'd1);   // DUT 24M posedge enable
  wire cen_24m_n = (ph == 2'd3);   // DUT 24M negedge enable (LS174)

  // ---- shared stimulus ----
  logic        rst_n, vflip_hv;
  logic [8:0]  h_off = 0, v_off = 0;
  logic        i_flip, i_cmpblk, i_gfxbank;
  logic [9:0]  i_ab;
  logic [7:0]  i_db;
  logic        i_vram_wrn, i_vram_rdn;
  logic        dlwr;
  logic [17:0] dladdr;
  logic [7:0]  dldata;
  logic        compare_en = 0;

  // =========================================================================
  // GOLDEN chain
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

  wire [7:0] g_db;  wire [3:0] g_col;  wire [1:0] g_vid;
  wire       g_busyn, g_esblkn;

  dkong3_vram u_g_vram (
    .I_CLK_24M(clk_24m), .I_CLK_12M(~g_oclk),
    .I_AB(i_ab), .I_DB(i_db),
    .I_VRAM_WRn(i_vram_wrn), .I_VRAM_RDn(i_vram_rdn),
    .I_FLIP(i_flip), .I_H_CNT(g_hcnt), .I_VF_CNT(g_vfcnt),
    .I_CMPBLK(i_cmpblk), .I_GFXBANK(i_gfxbank),
    .I_DLCLK(clk), .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_DB(g_db), .O_COL(g_col), .O_VID(g_vid),
    .O_VRAMBUSYn(g_busyn), .O_ESBLKn(g_esblkn)
  );

  // =========================================================================
  // DUT chain
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

  wire [7:0] d_db;  wire [3:0] d_col;  wire [1:0] d_vid;
  wire       d_busyn, d_esblkn;

  dkong3_vram_sync u_d_vram (
    .clk(clk),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n), .cen_24m_n(cen_24m_n),
    .cen_hcnt0_p(cen_hcnt0_p), .cen_hcnt2_p(cen_hcnt2_p),
    .cen_hcnt6_p(cen_hcnt6_p), .cen_hcnt9_n(cen_hcnt9_n),
    .I_AB(i_ab), .I_DB(i_db),
    .I_VRAM_WRn(i_vram_wrn), .I_VRAM_RDn(i_vram_rdn),
    .I_FLIP(i_flip), .I_H_CNT(d_hcnt), .I_VF_CNT(d_vfcnt),
    .I_CMPBLK(i_cmpblk), .I_GFXBANK(i_gfxbank),
    .I_DLCLK(clk), .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_DB(d_db), .O_COL(d_col), .O_VID(d_vid),
    .O_VRAMBUSYn(d_busyn), .O_ESBLKn(d_esblkn)
  );

  // =========================================================================
  // Scoreboard (compare on ph==3, the quiet phase)
  // =========================================================================
  int sb_errors = 0, sb_checks = 0;

  always @(posedge clk) if (compare_en && rst_n && ph == 2'd3) begin
    `SB_CHECK("O_DB",        g_db,     d_db)
    `SB_CHECK("O_COL",       g_col,    d_col)
    `SB_CHECK("O_VID",       g_vid,    d_vid)
    `SB_CHECK("O_VRAMBUSYn", g_busyn,  d_busyn)
    `SB_CHECK("O_ESBLKn",    g_esblkn, d_esblkn)
  end

  // =========================================================================
  // Stimulus
  // =========================================================================
  // deterministic content for a download address
  function [7:0] rom_data(input [17:0] a);
    rom_data = a[7:0] ^ a[15:8] ^ 8'h5A;
  endfunction

  task dl_write(input [17:0] a);
    begin
      @(posedge clk); dladdr = a; dldata = rom_data(a); dlwr = 1'b1;
      @(posedge clk); dlwr = 1'b0;
    end
  endtask

  integer k;
  reg [15:0] lfsr;

  initial begin
    rst_n = 0; vflip_hv = 0; i_flip = 0; i_cmpblk = 1; i_gfxbank = 0;
    i_ab = 0; i_db = 0; i_vram_wrn = 1; i_vram_rdn = 1;
    dlwr = 0; dladdr = 0; dldata = 0; lfsr = 16'hACE1;

    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // ---- load ROMs (identical content to golden + DUT) ----
    // COL PROM 2N : 0x12400..0x124FF
    for (k = 0; k < 256;  k = k + 1) dl_write(18'h12400 + k);
    // VID ROM 3P  : 0x06000..0x06FFF
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h06000 + k);
    // VID ROM 3N  : 0x07000..0x07FFF
    for (k = 0; k < 4096; k = k + 1) dl_write(18'h07000 + k);
    dlwr = 0;

    // ---- pre-fill VRAM via a CPU write sweep (CPU mode, write) ----
    i_cmpblk = 0; i_vram_rdn = 1; i_vram_wrn = 0;
    // golden + DUT share i_ab/i_db and their write edges coincide, so each
    // address is captured identically regardless of phase; just hold long
    // enough (16 master cycles) to guarantee >= 1 posedge-O_CLK write window.
    for (k = 0; k < 1024; k = k + 1) begin
      i_ab = k[9:0];
      i_db = k[7:0] ^ {k[9:2]} ^ 8'h3C;
      repeat (16) @(posedge clk);
    end
    i_vram_wrn = 1; i_cmpblk = 1;

    // ---- main randomized run: identical stimulus into both chains ----
    compare_en = 1;
    for (k = 0; k < 1_200_000; k = k + 1) begin
      @(posedge clk);
      if (ph == 2'd0) begin
        // advance LFSR
        lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        i_ab       = lfsr[9:0];
        i_db       = lfsr[7:0] ^ lfsr[15:8];
        i_cmpblk   = lfsr[10];           // blank vs CPU-access
        i_vram_wrn = lfsr[11] | lfsr[12];    // mostly read, occasional write
        i_vram_rdn = lfsr[13];
        i_gfxbank  = lfsr[14];
        i_flip     = lfsr[3] & lfsr[5];      // occasionally flip
      end
    end

    // ---- a focused flip-screen + offset pass ----
    @(posedge clk);
    if (ph == 2'd0) begin vflip_hv = 1; h_off = 9'd5; v_off = 9'd3; end
    repeat (400_000) @(posedge clk);

    `SB_REPORT("vram_diff")
  end

  initial begin #120_000_000; $fatal(1, "TIMEOUT"); end
endmodule
