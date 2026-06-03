//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - inferred true-dual-port RAM (clock rework)
//
// A plain inferred M10K true-dual-port RAM: single clock `clk`, one independent
// clock-enable per port, registered read address, unregistered (async) output,
// new-data read-during-write per port. Used for the rework's dual-port RAMs that
// need TWO DIFFERENT clock-enables on the one master clock (e.g. OBJ RAM: DMA
// write on cen_o_clk_n + scan read on cen_o_clk_p; work RAM 7H: CPU + DMA).
//
// This replaces the altsyncram-based `dpram` for those cases: feeding altsyncram
// clock0=clock1 with DIFFERENT clocken0/clocken1 is an unusual configuration; a
// straight inferred RAM gives Quartus the exact, predictable behaviour (and
// matches the behavioural model used in the testbenches bit-for-bit).
//
// Behaviour is identical to tb/common/dpram.sv (same registered-address /
// async-output / per-port-enable semantics), so the differential testbenches
// stay valid when a `_sync` module swaps dpram -> tdp_ram.
//----------------------------------------------------------------------------

module tdp_ram
#(
   parameter AW = 10,
   parameter DW = 8
)
(
   input               clk,

   // Port A
   input  [AW-1:0]     addr_a,
   input  [DW-1:0]     data_a,
   input               en_a,
   input               we_a,
   output [DW-1:0]     q_a,

   // Port B
   input  [AW-1:0]     addr_b,
   input  [DW-1:0]     data_b,
   input               en_b,
   input               we_b,
   output [DW-1:0]     q_b
);

   reg [DW-1:0] mem [0:(2**AW)-1];
   reg [AW-1:0] ra_a, ra_b;

   always @(posedge clk) if (en_a) begin
      if (we_a) mem[addr_a] <= data_a;
      ra_a <= addr_a;
   end

   always @(posedge clk) if (en_b) begin
      if (we_b) mem[addr_b] <= data_b;
      ra_b <= addr_b;
   end

   assign q_a = mem[ra_a];   // registered read address, async (unregistered) output
   assign q_b = mem[ra_b];

endmodule
