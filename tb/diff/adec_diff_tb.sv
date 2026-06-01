// tb/diff/adec_diff_tb.sv
// Differential equivalence for the address decoder:
//   GOLDEN : dkong3_adec      (I_CLK 4MHz, I_CLK12M, async VBLK/RESET)
//   DUT    : dkong3_adec_sync (single clk + cen_cpu/cen_cpu_n/cen_o_clk_p)
//
// The 4 MHz CPU clock (÷6) and the 12.288 MHz video clock (÷4) are both derived
// from the master via one mod-12 counter `mc`, so they are rationally related
// exactly as in the post-rework single-clock design. Golden runs on those
// divided clocks; DUT runs on clk with the matching enables. Z80-bus stimulus
// (address/data/strobes) and VBLK are driven at the quiet phase mc==11; outputs
// are compared at the quiet phase mc==5 (every domain settled, edge-detect
// latency absorbed).
`timescale 1ns/1ps
`include "sim_pkg.svh"

module adec_diff_tb;
  logic        clk = 0;
  logic [3:0]  mc  = 0;            // mod-12 master phase
  always #5 clk = ~clk;
  always @(posedge clk) mc <= (mc == 4'd11) ? 4'd0 : mc + 4'd1;

  wire [2:0] p6 = mc % 6;
  wire [1:0] p4 = mc % 4;

  wire cpuclk      = (p6 >= 3'd3);     // golden 4 MHz clock
  wire clk12m      = (p4 >= 2'd2);     // golden 12.288 clock
  wire cen_cpu     = (p6 == 3'd2);     // DUT: posedge cpuclk (p6 2->3)
  wire cen_cpu_n   = (p6 == 3'd5);     // DUT: negedge cpuclk (p6 5->0)
  wire cen_o_clk_p = (p4 == 2'd1);     // DUT: posedge clk12m (p4 1->2)

  // ---- shared stimulus ----
  logic        rst_n;
  logic [15:0] i_ab;
  logic [3:0]  i_db;
  logic        i_mreq_n, i_rfsh_n, i_rd_n, i_wr_n, i_vrambusy_n, i_vblk_n;
  logic        dlwr;
  logic [16:0] dladdr;
  logic [7:0]  dldata;
  logic        compare_en = 0;

  // I_VBLK_n is, in the real core, a clean registered output of hv_count_sync.
  // Register it here too so the NMI edge-detect sees a glitch-free synchronous
  // transition (no race with the stimulus driver).
  reg vblk_n_r = 1'b1;
  always @(posedge clk) vblk_n_r <= i_vblk_n;

  // ---- golden ----
  wire        g_wait_n, g_nmi_n, g_5a_n;
  wire  [3:0] g_mrom_csn;  wire [1:0] g_mram_csn;
  wire        g_objrq_n, g_objrd_n, g_objwr_n, g_vramrd_n, g_vramwr_n;
  wire        g_sw1_n, g_sw2_n, g_dip1_n, g_dip2_n;
  wire  [7:0] g_3e;  wire [3:0] g_4e;  wire g_subrst_n;
  dkong3_adec u_g (
    .I_CLK12M(clk12m), .I_CLK(cpuclk), .I_RESET_n(rst_n),
    .I_AB(i_ab), .I_DB(i_db),
    .I_MREQ_n(i_mreq_n), .I_RFSH_n(i_rfsh_n), .I_RD_n(i_rd_n), .I_WR_n(i_wr_n),
    .I_VRAMBUSY_n(i_vrambusy_n), .I_VBLK_n(vblk_n_r),
    .I_DLCLK(clk), .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_WAIT_n(g_wait_n), .O_NMI_n(g_nmi_n),
    .O_MROM_CSn(g_mrom_csn), .O_MRAM_CSn(g_mram_csn),
    .O_5A_G_n(g_5a_n), .O_OBJ_RQ_n(g_objrq_n), .O_OBJ_RD_n(g_objrd_n),
    .O_OBJ_WR_n(g_objwr_n), .O_VRAM_RD_n(g_vramrd_n), .O_VRAM_WR_n(g_vramwr_n),
    .O_SW1_OE_n(g_sw1_n), .O_SW2_OE_n(g_sw2_n), .O_DIP1_OE_n(g_dip1_n),
    .O_DIP2_OE_n(g_dip2_n), .O_3E_Q(g_3e), .O_4E_Q(g_4e), .O_SUB_RESETn(g_subrst_n)
  );

  // ---- dut ----
  wire        d_wait_n, d_nmi_n, d_5a_n;
  wire  [3:0] d_mrom_csn;  wire [1:0] d_mram_csn;
  wire        d_objrq_n, d_objrd_n, d_objwr_n, d_vramrd_n, d_vramwr_n;
  wire        d_sw1_n, d_sw2_n, d_dip1_n, d_dip2_n;
  wire  [7:0] d_3e;  wire [3:0] d_4e;  wire d_subrst_n;
  dkong3_adec_sync u_d (
    .clk(clk), .cen_cpu(cen_cpu), .cen_cpu_n(cen_cpu_n), .cen_o_clk_p(cen_o_clk_p),
    .I_RESET_n(rst_n), .I_AB(i_ab), .I_DB(i_db),
    .I_MREQ_n(i_mreq_n), .I_RFSH_n(i_rfsh_n), .I_RD_n(i_rd_n), .I_WR_n(i_wr_n),
    .I_VRAMBUSY_n(i_vrambusy_n), .I_VBLK_n(vblk_n_r),
    .I_DLCLK(clk), .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_WAIT_n(d_wait_n), .O_NMI_n(d_nmi_n),
    .O_MROM_CSn(d_mrom_csn), .O_MRAM_CSn(d_mram_csn),
    .O_5A_G_n(d_5a_n), .O_OBJ_RQ_n(d_objrq_n), .O_OBJ_RD_n(d_objrd_n),
    .O_OBJ_WR_n(d_objwr_n), .O_VRAM_RD_n(d_vramrd_n), .O_VRAM_WR_n(d_vramwr_n),
    .O_SW1_OE_n(d_sw1_n), .O_SW2_OE_n(d_sw2_n), .O_DIP1_OE_n(d_dip1_n),
    .O_DIP2_OE_n(d_dip2_n), .O_3E_Q(d_3e), .O_4E_Q(d_4e), .O_SUB_RESETn(d_subrst_n)
  );

  // NMI comparison is enabled only after a defined W_3E_Q[4] negedge (the
  // golden NMI flop has no reset, so its value is undefined at power-up until
  // the first negedge of its async-clear input; the sync DUT models the clear
  // as a level, which is the physically-correct behaviour of the LS74).
  reg nmi_ok = 0, pq3e4 = 0;
  always @(posedge clk) begin
    if (pq3e4 & ~g_3e[4]) nmi_ok <= 1'b1;
    pq3e4 <= g_3e[4];
  end

  // ---- scoreboard (quiet phase mc==5) ----
  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (compare_en && rst_n && mc == 4'd5) begin
    `SB_CHECK("O_WAIT_n",    g_wait_n,   d_wait_n)
    if (nmi_ok) `SB_CHECK("O_NMI_n", g_nmi_n, d_nmi_n)
    `SB_CHECK("O_MROM_CSn",  g_mrom_csn, d_mrom_csn)
    `SB_CHECK("O_MRAM_CSn",  g_mram_csn, d_mram_csn)
    `SB_CHECK("O_5A_G_n",    g_5a_n,     d_5a_n)
    `SB_CHECK("O_OBJ_RQ_n",  g_objrq_n,  d_objrq_n)
    `SB_CHECK("O_OBJ_RD_n",  g_objrd_n,  d_objrd_n)
    `SB_CHECK("O_OBJ_WR_n",  g_objwr_n,  d_objwr_n)
    `SB_CHECK("O_VRAM_RD_n", g_vramrd_n, d_vramrd_n)
    `SB_CHECK("O_VRAM_WR_n", g_vramwr_n, d_vramwr_n)
    `SB_CHECK("O_SW1_OE_n",  g_sw1_n,    d_sw1_n)
    `SB_CHECK("O_SW2_OE_n",  g_sw2_n,    d_sw2_n)
    `SB_CHECK("O_DIP1_OE_n", g_dip1_n,   d_dip1_n)
    `SB_CHECK("O_DIP2_OE_n", g_dip2_n,   d_dip2_n)
    `SB_CHECK("O_3E_Q",      g_3e,       d_3e)
    `SB_CHECK("O_4E_Q",      g_4e,       d_4e)
    `SB_CHECK("O_SUB_RESETn",g_subrst_n, d_subrst_n)
  end

  integer k;
  reg [22:0] lfsr;

  initial begin
    rst_n = 0; i_ab = 0; i_db = 0;
    i_mreq_n = 1; i_rfsh_n = 1; i_rd_n = 1; i_wr_n = 1; i_vrambusy_n = 1; i_vblk_n = 1;
    dlwr = 0; dladdr = 0; dldata = 0; lfsr = 23'h12345;

    repeat (60) @(posedge clk);

    // load ADEC PROM @ 5E : 0x12500..0x1251F with 0x00 (so W_PROM5E_Q[0]=0 for
    // all addresses -> the 3E/4E write decode below is deterministic).
    for (k = 0; k < 32; k = k + 1) begin
      dladdr = 17'h12500 + k; dldata = 8'h00; dlwr = 1;
      repeat (4) @(posedge clk);
    end
    dlwr = 0;

    repeat (40) @(posedge clk);
    rst_n = 1;
    repeat (60) @(posedge clk);

    // Deterministic write to LS259 @3E bit 4 (7E84H), then clear it: this gives
    // the golden NMI flop its first defined negedge so NMI becomes comparable.
    // I_AB[11:10]=11, [9:7]=101 (selects W_4E_Q[5]), [2:0]=100 (bit 4).
    i_ab = 16'h0E84; i_mreq_n = 0; i_wr_n = 0; i_rd_n = 1; i_rfsh_n = 1;
    i_db = 4'b0001;  repeat (60) @(posedge clk);   // W_3E_Q[4] <= 1
    i_db = 4'b0000;  repeat (60) @(posedge clk);   // W_3E_Q[4] <= 0  (negedge)
    i_wr_n = 1; i_mreq_n = 1;
    repeat (40) @(posedge clk);

    compare_en = 1;
    for (k = 0; k < 4_000_000; k = k + 1) begin
      @(posedge clk);
      if (mc == 4'd11) begin               // change all inputs at the quiet phase
        lfsr = {lfsr[21:0], lfsr[22]^lfsr[17]};
        i_ab         = lfsr[15:0];
        i_db         = lfsr[19:16];
        i_mreq_n     = lfsr[20];
        i_rfsh_n     = lfsr[21] | lfsr[3];   // mostly 1
        i_rd_n       = lfsr[22];
        i_wr_n       = lfsr[0];
        i_vrambusy_n = lfsr[1] | lfsr[5];
        i_vblk_n     = ~(&lfsr[4:2]);        // occasional VBLANK (active-low low)
      end
    end

    `SB_REPORT("adec_diff")
  end

  initial begin #500_000_000; $fatal(1, "TIMEOUT"); end
endmodule
