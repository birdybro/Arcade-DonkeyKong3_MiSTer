//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Control inputs / DIP switches
// (synchronous rework of dkong3_input)
//
// Single clock `clk` + clock-enable `cen` (= cen_o_clk_p, the posedge-O_CLK
// strobe that was the original `clk` = I_CLK_12M). Logic is otherwise identical.
//----------------------------------------------------------------------------

module dkong3_input_sync
(
   input       clk,
   input       cen,
   input  [7:0]I_SW1,
   input  [7:0]I_SW2,
   input  [7:0]I_DIP1,
   input  [7:0]I_DIP2,
   input       I_SW1_OE_n,
   input       I_SW2_OE_n,
   input       I_DIP1_OE_n,
   input       I_DIP2_OE_n,

   output reg [7:0]O_D
);

wire   [7:0]W_SW1  = I_SW1_OE_n  ?  8'h00: ~I_SW1;
wire   [7:0]W_SW2  = I_SW2_OE_n  ?  8'h00: !I_DIP2[7] ? ~I_SW2 : {~I_SW2[7:5],~I_SW1[4:0]};
wire   [7:0]W_DIP1 = I_DIP1_OE_n ?  8'h00:  I_DIP1;
wire   [7:0]W_DIP2 = I_DIP2_OE_n ?  8'h00:  {I_DIP2[7:3],I_DIP2[0],I_DIP2[1],I_DIP2[2]};

always @(posedge clk) if (cen)
 O_D <= W_SW1 | W_SW2 | W_DIP1 | W_DIP2;

endmodule
