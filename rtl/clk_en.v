//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - clock-enable generator
//
// Part of the synchronous clock rework (docs/clock-rework/ANALYSIS.md).
// Single 98.304 MHz master `clk`; every former clock in the core becomes one
// of the enables below, sampled as `if (cen_X) q <= d;` in the destination's
// `always @(posedge clk)`. No fabric/derived/ripple clocks.
//
// Enables are registered (clean timing at 98.304 MHz, glitch-free) and all
// shifted by the same one cycle, so their RELATIVE alignment is exact. Absolute
// phase is free-running (irrelevant: the design is internally consistent and
// the framework follows CE_PIXEL, not an absolute phase).
//----------------------------------------------------------------------------

module clk_en
(
   input        clk,        // 98.304 MHz master
   input        rst,        // active-high, sync-released in the clk domain

   // Integer phase strobes (÷ of the 98.304 master). 98.304/24.576 = 4,
   // 98.304/12.288 = 8, so both edges of the legacy 24.576 / 12.288 clocks
   // map to distinct posedge phases.
   output reg   cen_24m_p,  // 24.576 MHz, phase 0   (replaces posedge clk_sys)
   output reg   cen_24m_n,  // 24.576 MHz, phase 2   (replaces negedge clk_sys)
   output reg   cen_12m_p,  // 12.288 MHz, phase 0   (replaces posedge O_CLK/12M)
   output reg   cen_12m_n,  // 12.288 MHz, phase 4   (replaces negedge 12M)

   // Fractional (NCO) enables for rates not harmonic with 98.304.
   output reg   cen_cpu,    // 4.000 MHz exact  (replaces clk_main / Z80)
   output reg   cen_snd     // ~21.477 MHz      (replaces clk_sub / 2A03 base)
);

// --- phase counter: 0..7 = one 12.288 MHz period of the 98.304 master -------
reg [2:0] phase;

// --- CPU NCO: exactly 4.000 MHz = 125/3072 * 98.304 MHz ---------------------
localparam [11:0] CPU_INC = 12'd125;
localparam [11:0] CPU_MOD = 12'd3072;
reg [11:0] acc_cpu;

// --- sound NCO: ~21.4773 MHz (power-of-2 accumulator; carry-out = enable) ---
// 229094/2^20 * 98.304 MHz = 21.4773 MHz (target NES master 21.477272 MHz).
localparam [19:0] SND_INC = 20'd229094;
reg [19:0] acc_snd;

always @(posedge clk) begin
   if (rst) begin
      phase     <= 3'd0;
      acc_cpu   <= 12'd0;
      acc_snd   <= 20'd0;
      cen_24m_p <= 1'b0;
      cen_24m_n <= 1'b0;
      cen_12m_p <= 1'b0;
      cen_12m_n <= 1'b0;
      cen_cpu   <= 1'b0;
      cen_snd   <= 1'b0;
   end else begin
      phase     <= phase + 3'd1;

      // Decode the current phase; the registered strobe fires next cycle.
      cen_24m_p <= (phase[1:0] == 2'd0);
      cen_24m_n <= (phase[1:0] == 2'd2);
      cen_12m_p <= (phase      == 3'd0);
      cen_12m_n <= (phase      == 3'd4);

      // CPU NCO (mod 3072 -> exact 4.000 MHz average).
      if (acc_cpu + CPU_INC >= CPU_MOD) begin
         acc_cpu <= acc_cpu + CPU_INC - CPU_MOD;
         cen_cpu <= 1'b1;
      end else begin
         acc_cpu <= acc_cpu + CPU_INC;
         cen_cpu <= 1'b0;
      end

      // Sound NCO (2^20 wrap -> carry-out is the enable).
      {cen_snd, acc_snd} <= acc_snd + SND_INC;
   end
end

endmodule
