//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Sprite DMA (synchronous rework of dkong3_dma)
//
// Single clock `clk` (98.304 MHz) + clock-enable `cen` (= the negedge-4MHz
// strobe cen_cpu_n in the integrated core). The original ran the DMA state
// machine on ~I_MCPU_CLK (negedge of the 4 MHz CPU clock); here it advances one
// step per `cen` tick. Logic is otherwise identical to dkong3_dma.
// Verified by tb/diff/dma_diff_tb.sv.
//----------------------------------------------------------------------------

module dkong3_dma_sync
(
   input         clk,
   input         cen,
   input         I_RSTn,
   input         I_DMA_TRIG,
   input    [7:0]I_DMA_DS,

   output   [9:0]O_DMA_AS,
   output   [9:0]O_DMA_AD,
   output   [7:0]O_DMA_DD,
   output        O_DMA_CES,
   output        O_DMA_CED
);

parameter dma_cnt_end = 10'h19F;

reg W_DMA_EN = 1'b0;
reg [10:0]W_DMA_CNT;
reg [7:0]W_DMA_DATA;
reg [9:0]DMA_ASr;
reg [9:0]DMA_ADr;
reg [7:0]DMA_DDr;
reg DMA_CESr, DMA_CEDr;
reg old_trig;

always @(posedge clk) if (cen)
begin
   old_trig <= I_DMA_TRIG;

   if(~old_trig & I_DMA_TRIG)
      begin
         DMA_ASr     <= 10'h100;
         DMA_ADr     <= 0;
         W_DMA_CNT   <= 0;
         W_DMA_EN    <= 1'b1;
         DMA_CESr    <= 1'b1;
         DMA_CEDr    <= 1'b1;
      end
   else if(W_DMA_EN == 1'b1)
      begin
         case(W_DMA_CNT[1:0])
            1: DMA_DDr <= I_DMA_DS;
            2: DMA_ASr <= DMA_ASr + 1'd1;
            3: DMA_ADr <= DMA_ADr + 1'd1;
            default:;
         endcase
         W_DMA_CNT <= W_DMA_CNT + 1'd1;
         W_DMA_EN  <= W_DMA_CNT==dma_cnt_end*4 ? 1'b0 : 1'b1;
      end
   else
      begin
         DMA_CESr <= 1'b0;
         DMA_CEDr <= 1'b0;
      end
end

assign O_DMA_AS   = DMA_ASr;
assign O_DMA_AD   = DMA_ADr;
assign O_DMA_DD   = DMA_DDr;
assign O_DMA_CES  = DMA_CESr;
assign O_DMA_CED  = DMA_CEDr;

endmodule
