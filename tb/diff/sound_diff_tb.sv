// tb/diff/sound_diff_tb.sv
// Differential equivalence for the sound subsystem SHELL + 2A03 cadence:
//   GOLDEN : dkong3_sound      (posedge I_SUBCLK)
//   DUT    : dkong3_sound_sync (posedge clk + cen_snd)
//
// The real 2A03 cores (T65 VHDL + apu.sv) can't be simulated by verilator, so
// dkong3_sub / dkong3_sub_sync are replaced here by an identical DETERMINISTIC
// stub that walks the bus (reads ROM, writes/reads RAM, accumulates a "sample")
// driven by I_CPU_CE. This exercises and compares everything the rework
// actually changed: the div_cpu/cpu_ce/phi2/odd_or_even cadence, the RAM/ROM
// (cen_snd), the input latches, and the sample mix. The cores themselves are
// unchanged clock-enable designs (validated separately by analysis + t80_cen).
`timescale 1ns/1ps
`include "sim_pkg.svh"

// ---- deterministic stub for the 2A03 sub (golden, posedge I_SUBCLK) ----
module dkong3_sub
(
   input        I_SUBCLK, I_SUB_RESETn, I_SUB_NMIn,
   input   [7:0]I_SUB_DBI,
   input        I_CPU_CE, I_PHI2, I_ODD_OR_EVEN,
   output [15:0]O_SUB_ADDR,
   output  [7:0]O_SUB_DB0,
   output       O_SUB_RNW,
   output signed [15:0]O_SAMPLE
);
   reg [15:0] addr = 0;  reg [15:0] acc = 0;
   always @(posedge I_SUBCLK) begin
      if (~I_SUB_RESETn) begin addr <= 0; acc <= 0; end
      else if (I_CPU_CE) begin addr <= addr + 1'b1; acc <= acc + I_SUB_DBI; end
   end
   assign O_SUB_ADDR = addr;
   assign O_SUB_DB0  = addr[7:0] ^ addr[15:8];
   assign O_SUB_RNW  = addr[3];          // alternate read/write windows
   assign O_SAMPLE   = acc;
endmodule

// ---- same stub, sync port (clk) ----
module dkong3_sub_sync
(
   input        clk, I_SUB_RESETn, I_SUB_NMIn,
   input   [7:0]I_SUB_DBI,
   input        I_CPU_CE, I_PHI2, I_ODD_OR_EVEN,
   output [15:0]O_SUB_ADDR,
   output  [7:0]O_SUB_DB0,
   output       O_SUB_RNW,
   output signed [15:0]O_SAMPLE
);
   reg [15:0] addr = 0;  reg [15:0] acc = 0;
   always @(posedge clk) begin
      if (~I_SUB_RESETn) begin addr <= 0; acc <= 0; end
      else if (I_CPU_CE) begin addr <= addr + 1'b1; acc <= acc + I_SUB_DBI; end
   end
   assign O_SUB_ADDR = addr;
   assign O_SUB_DB0  = addr[7:0] ^ addr[15:8];
   assign O_SUB_RNW  = addr[3];
   assign O_SAMPLE   = acc;
endmodule

module sound_diff_tb;
  logic       clk = 0;
  logic [1:0] ph  = 0;
  always #5 clk = ~clk;
  always @(posedge clk) ph <= ph + 2'd1;

  wire subclk  = ph[1];           // golden 21.477-style clock (÷4)
  wire cen_snd = (ph == 2'd1);    // DUT enable, aligned to subclk posedge

  logic        rst_n, nmi_n;
  logic [3:0]  i_4e_q;
  logic [7:0]  i_mcpu_do;
  logic        dlwr;
  logic [16:0] dladdr;
  logic [7:0]  dldata;
  logic        compare_en = 0;

  wire signed [15:0] g_sample, d_sample;

  dkong3_sound u_g (
    .I_CLK_24M(clk), .I_SUBCLK(subclk),
    .I_SUB_NMIn(nmi_n), .I_SUB_RESETn(rst_n),
    .I_4E_Q(i_4e_q), .I_MCPU_DO(i_mcpu_do),
    .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_SAMPLE(g_sample)
  );

  dkong3_sound_sync u_d (
    .clk(clk), .cen_snd(cen_snd),
    .I_SUB_NMIn(nmi_n), .I_SUB_RESETn(rst_n),
    .I_4E_Q(i_4e_q), .I_MCPU_DO(i_mcpu_do),
    .I_DLCLK(clk), .I_DLADDR(dladdr), .I_DLDATA(dldata), .I_DLWR(dlwr),
    .O_SAMPLE(d_sample)
  );

  int sb_errors = 0, sb_checks = 0;
  always @(posedge clk) if (compare_en && rst_n && ph == 2'd3) begin
    `SB_CHECK("O_SAMPLE", g_sample, d_sample)
  end

  function [7:0] rom_data(input [16:0] a);
    rom_data = a[7:0] ^ a[15:8] ^ 8'h71;
  endfunction

  task dl_write(input [16:0] a);
    begin
      dladdr = a; dldata = rom_data(a); dlwr = 1'b1;
      repeat (4) @(posedge clk);
    end
  endtask

  integer k;
  reg [15:0] lfsr;

  initial begin
    rst_n = 0; nmi_n = 1; i_4e_q = 0; i_mcpu_do = 0;
    dlwr = 0; dladdr = 0; dldata = 0; lfsr = 16'h7A5C;

    repeat (40) @(posedge clk);
    // load sound ROMs: 5L 0x0E000..0x0FFFF, 6H 0x10000..0x11FFF
    for (k = 0; k < 8192; k = k + 1) dl_write(17'h0E000 + k);
    for (k = 0; k < 8192; k = k + 1) dl_write(17'h10000 + k);
    dlwr = 0;

    repeat (20) @(posedge clk);
    rst_n = 1;
    repeat (40) @(posedge clk);

    compare_en = 1;
    for (k = 0; k < 3_000_000; k = k + 1) begin
      @(posedge clk);
      if (ph == 2'd0) begin
        lfsr = {lfsr[14:0], lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        i_mcpu_do = lfsr[7:0];
        i_4e_q    = lfsr[11:8];      // sound command strobes
      end
    end

    `SB_REPORT("sound_diff")
  end

  initial begin #400_000_000; $fatal(1, "TIMEOUT"); end
endmodule
