// tb/common/dpram.sv
// Behavioral simulation model of rtl/dpram.vhd (the Altera altsyncram wrapper).
// Matches the synthesis config in dpram.vhd:
//   - BIDIR_DUAL_PORT, two clocks
//   - clocken0/1 = enable_a/b  (the clock-enable; gates addr/wren/data capture)
//   - outdata UNREGISTERED      (q is async: mem[registered_read_address])
//   - read_during_write = NEW_DATA  (write shows on q same cycle if same address)
// Same name/ports/generics as the real dpram so it drops in for both the golden
// and reworked DUTs in a diff testbench. NOT for synthesis (Quartus uses the
// real dpram.vhd via files.qip).
module dpram #(
   parameter addr_width_g = 8,
   parameter data_width_g = 8
)(
   input  [addr_width_g-1:0] address_a,
   input  [addr_width_g-1:0] address_b,
   input                     clock_a,
   input                     clock_b,
   input  [data_width_g-1:0] data_a,
   input  [data_width_g-1:0] data_b,
   input                     enable_a,
   input                     enable_b,
   input                     wren_a,
   input                     wren_b,
   output [data_width_g-1:0] q_a,
   output [data_width_g-1:0] q_b
);
   reg [data_width_g-1:0] mem [0:(2**addr_width_g)-1];
   reg [addr_width_g-1:0] ra_a, ra_b;

   // `=== 1'b1` so an undriven port (VHDL defaults enable=1/wren=0; an unconnected
   // Verilog input would be X) never spuriously writes.
   always @(posedge clock_a) if (enable_a === 1'b1) begin
      if (wren_a === 1'b1) mem[address_a] <= data_a;
      ra_a <= address_a;
   end
   always @(posedge clock_b) if (enable_b === 1'b1) begin
      if (wren_b === 1'b1) mem[address_b] <= data_b;
      ra_b <= address_b;
   end

   assign q_a = mem[ra_a];   // unregistered (async) read; new-data RDW falls out
   assign q_b = mem[ra_b];
endmodule
