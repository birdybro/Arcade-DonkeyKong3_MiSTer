// tb/diff/sprite_dma_diff_tb.sv
// Integration diff for the FULL sprite path with a live per-frame DMA refresh:
//   GOLDEN : dkong3_hv_count + dkong3_dma      + dkong3_obj
//   DUT    : dkong3_hv_count_sync + dkong3_dma_sync + dkong3_obj_sync
//
// Every prior sprite test used a STATIC, pre-filled OBJ RAM. Here the OBJ RAM is
// continuously refreshed by the real sprite DMA (copying a shared work-RAM into
// the obj engine's internal OBJ RAM) and re-triggered every "frame", while the
// engine scans/displays. The DMA runs on cen_cpu_n (locked to clk), the OBJ RAM
// write on cen_o_clk_n, the scan read on cen_o_clk_p -- the interaction the
// rework changed from the original async/opposite-edge design. Scoreboard
// asserts O_OBJ_DO matches across many DMA-refreshed frames.
//
// video (÷4) and cpu (÷6) clocks are both derived from one mod-12 master phase,
// matching clk_en's locked relationship.
`timescale 1ns/1ps
`include "sim_pkg.svh"

module sprite_dma_diff_tb;
  logic       clk = 0;
  logic [3:0] mc  = 0;            // mod-12 master phase
  always #5 clk = ~clk;
  always @(posedge clk) mc <= (mc == 4'd11) ? 4'd0 : mc + 4'd1;

  wire [1:0] p4 = mc % 4;
  wire [2:0] p6 = mc % 6;

  wire clk_24m   = (p4 >= 2'd2);   // golden video 24.576 clock
  wire cen_24m_p = (p4 == 2'd1);
  wire cen_24m_n = (p4 == 2'd3);
  wire cpuclk    = (p6 >= 3'd3);   // golden cpu clock (÷6)
  wire cen_cpu_n = (p6 == 3'd5);   // DUT: advances on cpuclk negedge (p6 5->0)

  // ---- shared stimulus ----
  logic rst_n;
  logic i_2psl, i_flipn, i_cmpblkn, flip_screen;
  logic trig;
  logic [17:0] dladdr;  logic [7:0] dldata;  logic dlwr;
  logic compare_en = 0;

  // shared work-RAM (DMA source); identical content both chains
  reg [7:0] workram [0:1023];
  integer i;
  initial for (i=0;i<1024;i=i+1) workram[i] = (i*13) ^ (i>>3) ^ 8'h2A;

  // =========================================================================
  // GOLDEN
  // =========================================================================
  wire        g_oclk, g_hb,g_vb,g_cb,g_hs,g_vs;
  wire [9:0]  g_hcnt; wire [7:0] g_vcnt, g_vfcnt;
  dkong3_hv_count u_g_hv (
    .I_CLK(clk_24m), .I_RST_n(rst_n), .I_VFLIP(1'b0), .H_OFFSET(9'd0), .V_OFFSET(9'd0),
    .O_CLK(g_oclk), .H_CNT(g_hcnt), .V_CNT(g_vcnt), .VF_CNT(g_vfcnt),
    .H_BLANKn(g_hb), .V_BLANKn(g_vb), .C_BLANKn(g_cb), .H_SYNCn(g_hs), .V_SYNCn(g_vs));

  wire [9:0] g_das, g_dad;  wire [7:0] g_ddd;  wire g_dced;
  wire [7:0] g_dma_ds = workram[g_das];
  dkong3_dma u_g_dma (
    .I_CLK(~cpuclk), .I_RSTn(rst_n), .I_DMA_TRIG(trig), .I_DMA_DS(g_dma_ds),
    .O_DMA_AS(g_das), .O_DMA_AD(g_dad), .O_DMA_DD(g_ddd), .O_DMA_CES(), .O_DMA_CED(g_dced));

  wire [5:0] g_objdo;  wire g_fv, g_fhv, g_lcb;
  dkong3_obj u_g_obj (
    .I_CLK_24M(clk_24m), .I_CLK_12M(g_oclk),
    .I_AB(), .I_DB(), .I_OBJ_WRn(1'b1), .I_OBJ_RDn(1'b1), .I_OBJ_RQn(1'b1),
    .I_2PSL(i_2psl), .I_FLIPn(i_flipn), .I_CMPBLKn(i_cmpblkn),
    .I_H_CNT(g_hcnt), .I_VF_CNT(g_vfcnt),
    .I_OBJ_DMA_A(g_dad), .I_OBJ_DMA_D(g_ddd), .I_OBJ_DMA_CE(g_dced),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr), .flip_screen(flip_screen),
    .O_DB(), .O_OBJ_DO(g_objdo), .O_FLIP_VRAM(g_fv), .O_FLIP_HV(g_fhv), .O_L_CMPBLKn(g_lcb));

  // =========================================================================
  // DUT
  // =========================================================================
  wire        d_oclk, d_hb,d_vb,d_cb,d_hs,d_vs;
  wire [9:0]  d_hcnt; wire [7:0] d_vcnt, d_vfcnt;
  wire        cen_o_clk_p, cen_o_clk_n, cen_hcnt0_p, cen_hcnt2_p, cen_hcnt6_p, cen_hcnt9_n;
  dkong3_hv_count_sync u_d_hv (
    .clk(clk), .cen_24m_p(cen_24m_p), .I_RST_n(rst_n), .I_VFLIP(1'b0), .H_OFFSET(9'd0), .V_OFFSET(9'd0),
    .O_CLK(d_oclk), .H_CNT(d_hcnt), .V_CNT(d_vcnt), .VF_CNT(d_vfcnt),
    .H_BLANKn(d_hb), .V_BLANKn(d_vb), .C_BLANKn(d_cb), .H_SYNCn(d_hs), .V_SYNCn(d_vs),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt0_p(cen_hcnt0_p), .cen_hcnt2_p(cen_hcnt2_p),
    .cen_hcnt6_p(cen_hcnt6_p), .cen_hcnt9_n(cen_hcnt9_n));

  wire [9:0] d_das, d_dad;  wire [7:0] d_ddd;  wire d_dced;
  wire [7:0] d_dma_ds = workram[d_das];
  dkong3_dma_sync u_d_dma (
    .clk(clk), .cen(cen_cpu_n), .I_RSTn(rst_n), .I_DMA_TRIG(trig), .I_DMA_DS(d_dma_ds),
    .O_DMA_AS(d_das), .O_DMA_CES(), .O_DMA_AD(d_dad), .O_DMA_DD(d_ddd), .O_DMA_CED(d_dced));

  wire [5:0] d_objdo;  wire d_fv, d_fhv, d_lcb;
  dkong3_obj_sync u_d_obj (
    .clk(clk), .cen_24m_p(cen_24m_p), .cen_24m_n(cen_24m_n),
    .cen_o_clk_p(cen_o_clk_p), .cen_o_clk_n(cen_o_clk_n),
    .cen_hcnt9_n(cen_hcnt9_n), .I_OCLK(d_oclk),
    .I_AB(10'd0), .I_DB(8'd0), .I_OBJ_WRn(1'b1), .I_OBJ_RDn(1'b1), .I_OBJ_RQn(1'b1),
    .I_2PSL(i_2psl), .I_FLIPn(i_flipn), .I_CMPBLKn(i_cmpblkn),
    .I_H_CNT(d_hcnt), .I_VF_CNT(d_vfcnt),
    .I_OBJ_DMA_A(d_dad), .I_OBJ_DMA_D(d_ddd), .I_OBJ_DMA_CE(d_dced),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr), .flip_screen(flip_screen),
    .O_DB(), .O_OBJ_DO(d_objdo), .O_FLIP_VRAM(d_fv), .O_FLIP_HV(d_fhv), .O_L_CMPBLKn(d_lcb));

  // ---- scoreboard (quiet phase mc==4) ----
  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (compare_en && rst_n && mc == 4'd4) begin
    `SB_CHECK("O_OBJ_DO",    g_objdo, d_objdo)
    `SB_CHECK("O_L_CMPBLKn", g_lcb,   d_lcb)
  end

  function [7:0] rom_data(input [17:0] a); rom_data = a[7:0]^a[15:8]^8'hA5; endfunction
  task dl_write(input [17:0] a);
    begin dladdr = a; dldata = rom_data(a); dlwr = 1'b1; repeat (8) @(posedge clk); end
  endtask

  integer k;
  initial begin
    rst_n = 0; i_2psl=0; i_flipn=1; i_cmpblkn=1; flip_screen=0;
    trig=0; dlwr=0; dladdr=0; dldata=0;
    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    // load OBJ ROMs 7C/7D/7E/7F
    for (k=0;k<4096;k=k+1) dl_write(18'h0A000+k);
    for (k=0;k<4096;k=k+1) dl_write(18'h0B000+k);
    for (k=0;k<4096;k=k+1) dl_write(18'h0C000+k);
    for (k=0;k<4096;k=k+1) dl_write(18'h0D000+k);
    dlwr = 0;

    // warm up + initial DMA
    trig = 1;  repeat (40000) @(posedge clk);  trig = 0;
    repeat (200000) @(posedge clk);

    compare_en = 1;
    // several "frames": re-trigger DMA periodically while the engine scans
    for (k=0;k<12;k=k+1) begin
      trig = 1;  repeat (4000) @(posedge clk);  trig = 0;
      repeat (140000) @(posedge clk);
    end

    `SB_REPORT("sprite_dma_diff")
  end

  initial begin #800_000_000; $fatal(1, "TIMEOUT"); end
endmodule
