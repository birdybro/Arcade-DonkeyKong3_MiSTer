//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Video RAM (synchronous rework of dkong3_vram)
//
// Single clock `clk` (98.304 MHz). Every flop is `posedge clk` + a clock-enable
// that pulses at the exact instant the original fabric-derived clock edge
// occurred. The strobes come from dkong3_hv_count_sync:
//   cen_o_clk_p  posedge O_CLK (12.288)  -> VRAM read/write     (was ~I_CLK_12M)
//   cen_o_clk_n  negedge O_CLK            -> COL PROM / VID ROM   (was  I_CLK_12M)
//   cen_24m_n    negedge 24.576           -> LS174 COL latch      (was negedge I_CLK_24M)
//   cen_hcnt0_p  posedge H_CNT[0]         -> 4P/4N shift regs     (was CLK_4PN)
//   cen_hcnt2_p  posedge H_CNT[2]         -> VRAMBUSY             (was posedge I_H_CNT[2])
//   cen_hcnt6_p  posedge H_CNT[6]         -> ESBLK                (was posedge I_H_CNT[6])
//   cen_hcnt9_n  negedge H_CNT[9]         -> VRAMBUSY/ESBLK clear (was negedge I_H_CNT[9])
//
// Behaviour is bit-identical to dkong3_vram (verified by tb/diff/vram_diff_tb.sv).
// See docs/clock-rework/ANALYSIS.md.
//----------------------------------------------------------------------------

module dkong3_vram_sync(

   input        clk,
   input        cen_o_clk_p,
   input        cen_o_clk_n,
   input        cen_24m_n,
   input        cen_hcnt0_p,
   input        cen_hcnt2_p,
   input        cen_hcnt6_p,
   input        cen_hcnt9_n,

   input   [9:0]I_AB,
   input   [7:0]I_DB,
   input        I_VRAM_WRn,
   input        I_VRAM_RDn,
   input        I_FLIP,
   input   [9:0]I_H_CNT,
   input   [7:0]I_VF_CNT,
   input        I_CMPBLK,
   input        I_GFXBANK,
   input        I_DLCLK,
   input  [17:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,

   output     [7:0]O_DB,
   output reg [3:0]O_COL,
   output     [1:0]O_VID,
   output          O_VRAMBUSYn,
   output          O_ESBLKn
);

//-------------------------
// VRAM
// 2 x 2114 @ 2P, 2R (1KB)
//-------------------------

wire   [7:0]WI_DB = I_VRAM_WRn ? 8'h00: I_DB;
wire   [7:0]WO_DB;

assign O_DB       = I_VRAM_RDn ? 8'h00: WO_DB;

wire   [4:0]W_HF_CNT  = I_H_CNT[8:4]^{5{I_FLIP}};
wire   [9:0]W_cnt_AB  = {I_VF_CNT[7:3],W_HF_CNT[4:0]};
wire   [9:0]W_vram_AB = I_CMPBLK ? W_cnt_AB : I_AB ;
wire        W_vram_CS = I_CMPBLK ? 1'b0     : I_VRAM_WRn & I_VRAM_RDn;
wire        W_2S4     = I_CMPBLK ? 1'b0     : 1'b1 ;

// Original: ram_1024_8 on posedge O_CLK with enable = ~W_vram_CS.
// Rework: single dpram on `clk`, capture gated by cen_o_clk_p (= posedge O_CLK).
wire   [7:0]W_ram_q;
assign WO_DB = (~W_vram_CS) ? W_ram_q : 8'h00;   // = ram_1024_8 O_D

dpram #(10,8) U_2PR(
   .clock_a   (clk),
   .address_a (W_vram_AB),
   .data_a    (WI_DB),
   .enable_a  (~W_vram_CS & cen_o_clk_p),
   .wren_a    (~I_VRAM_WRn),
   .q_a       (W_ram_q),

   .clock_b   (clk)
);

//----------------
// Colour PROM 2N
//----------------

wire  [7:0]W_2N_AD = {W_vram_AB[9:7],W_vram_AB[4:0]};
wire  [3:0]W_2N_DO;

COL_PROM_256_4_CE prom2n(clk, cen_o_clk_n, W_2N_AD, W_2N_DO,
                         I_DLCLK, I_DLADDR[16:0], I_DLDATA, I_DLWR);

//-----------------
// Part 2M (LS174)
//-----------------
// Original: always@(negedge I_CLK_24M). Rework: posedge clk + cen_24m_n.

reg    CLK_2M;
reg    [3:0]COL;
reg    CLK_2Mp, H_CNT0p;

always@(posedge clk) if (cen_24m_n) begin

   CLK_2M  <= ~(&I_H_CNT[3:1]);
   CLK_2Mp <= CLK_2M;

   if (CLK_2Mp && !CLK_2M) COL <= W_2N_DO[3:0];

   // Fix for timing issue
   H_CNT0p <= I_H_CNT[0];
   if (!H_CNT0p && I_H_CNT[0]) O_COL <= COL;

end

//-------------------
// Video ROMs 3N, 3P
//-------------------

wire [11:0]W_VRAM_AB = {I_GFXBANK,WO_DB[7:0],I_VF_CNT[2:0]};
wire [15:0]W_3PN_DO;

VID_ROM_CE roms3PN(clk, cen_o_clk_n, W_VRAM_AB, 1'b0, W_3PN_DO,
                   I_DLCLK, I_DLADDR[16:0], I_DLDATA, I_DLWR);

//-------------------
// Shift register 4P
//-------------------
// Original: always@(posedge CLK_4PN) where CLK_4PN = I_H_CNT[0].
// Rework: posedge clk + cen_hcnt0_p (= posedge H_CNT[0]).

wire   W_4P_Qa,W_4P_Qh;

wire   [1:0]C_4P = W_4M_Y[1:0];
wire   [7:0]I_4P = W_3PN_DO[7:0];
reg    [7:0]reg_4P;

always@(posedge clk) if (cen_hcnt0_p)
begin
   case(C_4P)
      2'b00: reg_4P <= reg_4P;
      2'b10: reg_4P <= {reg_4P[6:0],1'b0};
      2'b01: reg_4P <= {1'b0,reg_4P[7:1]};
      2'b11: reg_4P <= I_4P;
   endcase
end

assign W_4P_Qa = reg_4P[7];
assign W_4P_Qh = reg_4P[0];

//-------------------
// Shift register 4N
//-------------------

wire   W_4N_Qa,W_4N_Qh;

wire   [1:0]C_4N = W_4M_Y[1:0];
wire   [7:0]I_4N = W_3PN_DO[15:8];
reg    [7:0]reg_4N;

always@(posedge clk) if (cen_hcnt0_p)
begin
   case(C_4N)
      2'b00: reg_4N <= reg_4N;
      2'b10: reg_4N <= {reg_4N[6:0],1'b0};
      2'b01: reg_4N <= {1'b0,reg_4N[7:1]};
      2'b11: reg_4N <= I_4N;
   endcase
end

assign W_4N_Qa = reg_4N[7];
assign W_4N_Qh = reg_4N[0];

//-----------------
// Part 4M (LS157)
//-----------------

wire   [3:0]W_4M_a,W_4M_b;
wire   [3:0]W_4M_Y;

assign W_4M_a = {W_4P_Qa,W_4N_Qa,1'b1,~(CLK_2M|W_2S4)};
assign W_4M_b = {W_4P_Qh,W_4N_Qh,~(CLK_2M|W_2S4),1'b1};
assign W_4M_Y = I_FLIP ? W_4M_b:W_4M_a;

assign O_VID[0] = W_4M_Y[2];
assign O_VID[1] = W_4M_Y[3];

//-----------------------
// VRAM BUSY signal @ 2K
//-----------------------
// Original: always@(posedge I_H_CNT[2] or negedge I_H_CNT[9]).
// Rework: posedge clk; cen_hcnt9_n (negedge H_CNT[9]) clear has priority,
// else cen_hcnt2_p (posedge H_CNT[2]) does the capture. The H_CNT bits read
// here ([9],[7:4]) do not change across either trigger edge, so sampling the
// registered I_H_CNT matches the original's post-edge value.

reg    W_VRAMBUSY;

always@(posedge clk)
begin
   if (cen_hcnt9_n)
      W_VRAMBUSY <= 1'b1;
   else if (cen_hcnt2_p) begin
      if(I_H_CNT[9] == 1'b0)
         W_VRAMBUSY <= 1'b1;
      else
         W_VRAMBUSY <= I_H_CNT[4]&I_H_CNT[5]&I_H_CNT[6]&I_H_CNT[7];
   end
end

assign O_VRAMBUSYn = ~W_VRAMBUSY;

//-------------------
// ESBLK signal @ 2K
// This signal doesn't go anywhere on the schematic.
//-------------------

reg    W_ESBLK;

always@(posedge clk)
begin
   if (cen_hcnt9_n)
      W_ESBLK <= 1'b0;
   else if (cen_hcnt6_p) begin
      if(I_H_CNT[9] == 1'b0)
         W_ESBLK <= 1'b0;
      else
         W_ESBLK <= ~I_H_CNT[7];
   end
end

assign O_ESBLKn = ~W_ESBLK;

endmodule
