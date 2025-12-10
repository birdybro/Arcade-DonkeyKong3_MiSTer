//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade
//
// Author: gaz68 (https://github.com/gaz68) July 2020
//
// Simplified sprite DMA.
// To Do: Implement full z80 DMA controller.
// Donkey Kong 3 transfers $19F bytes from $6900 to $7000 when DMA
// is triggered.
//----------------------------------------------------------------------------

module dkong3_dma
(
   input         I_CLK,
   input         I_RSTn,
   input         I_DMA_TRIG,
   input    [7:0]I_DMA_DS,

   output   [9:0]O_DMA_AS,
   output   [9:0]O_DMA_AD,
   output   [7:0]O_DMA_DD,
   output        O_DMA_CES,
   output        O_DMA_CED,
   output        O_DMA_WE
);

parameter dma_cnt_end = 10'h19F;

reg W_DMA_EN = 1'b0;
reg [10:0]W_DMA_CNT;
reg [7:0]W_DMA_DATA;
reg [9:0]DMA_ASr;
reg [9:0]DMA_ADr;
reg [7:0]DMA_DDr;
reg DMA_CESr, DMA_CEDr;
reg DMA_WEr;

always @(posedge I_CLK)
begin
   reg old_trig;

   if(~I_RSTn) begin
      old_trig  <= 1'b0;
      W_DMA_EN  <= 1'b0;
      W_DMA_CNT <= 0;
      DMA_WEr   <= 1'b0;
      DMA_CESr  <= 1'b0;
      DMA_CEDr  <= 1'b0;
   end
   else begin
      old_trig <= I_DMA_TRIG;

      if(~old_trig & I_DMA_TRIG)
         begin
            DMA_ASr     <= 10'h100; 
            DMA_ADr     <= 0;
            W_DMA_CNT   <= 0;
            W_DMA_EN    <= 1'b1;
            DMA_CESr    <= 1'b1;
            DMA_CEDr    <= 1'b1;
            DMA_WEr     <= 1'b0;
         end
      else if(W_DMA_EN == 1'b1)
         begin
            case(W_DMA_CNT[1:0])
               1: begin
                  DMA_DDr <= I_DMA_DS;
                  DMA_WEr <= 1'b1; // valid data+address phase
               end
               2: DMA_ASr <= DMA_ASr + 1'd1;
               3: DMA_ADr <= DMA_ADr + 1'd1;
               default:;
            endcase 
            W_DMA_CNT <= W_DMA_CNT + 1'd1;
            W_DMA_EN  <= W_DMA_CNT==dma_cnt_end*4 ? 1'b0 : 1'b1;
            if(W_DMA_CNT[1:0]!=2'd1)
               DMA_WEr <= 1'b0;
         end
      else
         begin
            DMA_CESr <= 1'b0;
            DMA_CEDr <= 1'b0;
            DMA_WEr  <= 1'b0;
         end
   end
end

assign O_DMA_AS   = DMA_ASr;
assign O_DMA_AD   = DMA_ADr;
assign O_DMA_DD   = DMA_DDr;
assign O_DMA_CES  = DMA_CESr;
assign O_DMA_CED  = DMA_CEDr;
assign O_DMA_WE   = DMA_WEr;

endmodule
