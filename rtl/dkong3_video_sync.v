//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Top level video (synchronous rework of dkong3_video)
//
// Wires the three converted submodules (dkong3_vram_sync, dkong3_obj_sync,
// dkong3_col_pal_sync) on the single master clock `clk` (98.304 MHz). All the
// fabric-derived clocks of the legacy video path are supplied here as decoded
// clock-enables from dkong3_hv_count_sync, plus O_CLK as a level (I_OCLK) for
// obj's gated-clock decodes. Same I/O contract as dkong3_video otherwise.
// Verified by tb/diff/video_diff_tb.sv.
//----------------------------------------------------------------------------

module dkong3_video_sync
(
   input        clk,
   // clock-enables / level from dkong3_hv_count_sync
   input        cen_24m_p,
   input        cen_24m_n,
   input        cen_o_clk_p,
   input        cen_o_clk_n,
   input        cen_hcnt0_p,
   input        cen_hcnt2_p,
   input        cen_hcnt6_p,
   input        cen_hcnt9_n,
   input        I_OCLK,        // O_CLK level (12.288)

   input        I_RESETn,
   input   [9:0]I_CPU_A,
   input   [7:0]I_CPU_D,
   input        I_VRAM_WRn,
   input        I_VRAM_RDn,
   input   [7:0]I_3E_Q,
   input   [9:0]I_H_CNT,
   input   [7:0]I_VF_CNT,
   input        I_CBLANKn,
   input   [9:0]I_OBJDMA_A,
   input   [7:0]I_OBJDMA_D,
   input        I_OBJDMA_CE,
   input        I_DLCLK,
   input  [17:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,
   input        flip_screen,

   output  [7:0]O_VRAM_DB,
   output       O_VRAMBUSYn,
   output       O_FLIP_HV,
   output  [7:0]O_OBJ_DB,
   output  [3:0]O_VGA_RED,
   output  [3:0]O_VGA_GRN,
   output  [3:0]O_VGA_BLU
);

//------------------
// VRAM - background tiles
//------------------
wire   [3:0]W_VRAM_COL;
wire   [1:0]W_VRAM_VID;
wire   [7:0]W_VRAM_DB;
wire        W_VRAMBUSYn;
wire        W_FLIP_VRAM;

dkong3_vram_sync vram
(
   .clk(clk),
   .cen_o_clk_p(cen_o_clk_p),
   .cen_o_clk_n(cen_o_clk_n),
   .cen_24m_n(cen_24m_n),
   .cen_hcnt0_p(cen_hcnt0_p),
   .cen_hcnt2_p(cen_hcnt2_p),
   .cen_hcnt6_p(cen_hcnt6_p),
   .cen_hcnt9_n(cen_hcnt9_n),
   .I_AB(I_CPU_A),
   .I_DB(I_CPU_D),
   .I_VRAM_WRn(I_VRAM_WRn),
   .I_VRAM_RDn(I_VRAM_RDn),
   .I_FLIP(W_FLIP_VRAM),
   .I_H_CNT(I_H_CNT),
   .I_VF_CNT(I_VF_CNT),
   .I_CMPBLK(I_CBLANKn),
   .I_GFXBANK(~I_3E_Q[1]),
   .I_DLCLK(I_DLCLK),
   .I_DLADDR(I_DLADDR),
   .I_DLDATA(I_DLDATA),
   .I_DLWR(I_DLWR),

   .O_DB(W_VRAM_DB),
   .O_COL(W_VRAM_COL),
   .O_VID(W_VRAM_VID),
   .O_VRAMBUSYn(W_VRAMBUSYn),
   .O_ESBLKn() // Not used
);

wire   [5:0]W_VRAM_DAT = {W_VRAM_COL[3:0],W_VRAM_VID[1:0]};

assign O_VRAM_DB   = W_VRAM_DB;
assign O_VRAMBUSYn = W_VRAMBUSYn;

//-------------------
// Objects / Sprites
//-------------------
wire  [5:0]W_OBJ_DAT;
wire       W_FLIP_HV;
wire       W_FLIPn = I_3E_Q[2];
wire       W_2PSL  = I_3E_Q[3];
wire       W_L_CMPBLKn;
wire  [7:0]W_OBJ_DB;

dkong3_obj_sync sprites
(
   .clk(clk),
   .cen_24m_p(cen_24m_p),
   .cen_24m_n(cen_24m_n),
   .cen_o_clk_p(cen_o_clk_p),
   .cen_o_clk_n(cen_o_clk_n),
   .cen_hcnt9_n(cen_hcnt9_n),
   .I_OCLK(I_OCLK),
   .I_AB(10'd0),       // not used
   .I_DB(8'd0),        // not used
   .I_OBJ_WRn(1'b1),   // not used
   .I_OBJ_RDn(1'b1),   // not used
   .I_OBJ_RQn(1'b1),   // not used
   .I_2PSL(W_2PSL),
   .I_FLIPn(W_FLIPn),
   .I_CMPBLKn(I_CBLANKn),
   .I_H_CNT(I_H_CNT),
   .I_VF_CNT(I_VF_CNT),
   .I_OBJ_DMA_A(I_OBJDMA_A),
   .I_OBJ_DMA_D(I_OBJDMA_D),
   .I_OBJ_DMA_CE(I_OBJDMA_CE),
   .I_DLADDR(I_DLADDR),
   .I_DLDATA(I_DLDATA),
   .I_DLWR(I_DLWR),
   .flip_screen(flip_screen),

   .O_DB(W_OBJ_DB), // not used
   .O_OBJ_DO(W_OBJ_DAT),
   .O_FLIP_VRAM(W_FLIP_VRAM),
   .O_FLIP_HV(W_FLIP_HV),
   .O_L_CMPBLKn(W_L_CMPBLKn)
);

assign O_OBJ_DB  = W_OBJ_DB;
assign O_FLIP_HV = W_FLIP_HV;

//----------------
// Colour Palette
//----------------
wire   [3:0]W_R;
wire   [3:0]W_G;
wire   [3:0]W_B;

dkong3_col_pal_sync cpal
(
   .clk(clk),
   .cen_24m_p(cen_24m_p),
   .cen_hcnt0_p(cen_hcnt0_p),
   .I_VRAM_D(W_VRAM_DAT),
   .I_OBJ_D(W_OBJ_DAT),
   .I_CMPBLKn(W_L_CMPBLKn),
   .I_CPAL_SEL(I_3E_Q[7:6]),
   .I_DLCLK(I_DLCLK),
   .I_DLADDR(I_DLADDR),
   .I_DLDATA(I_DLDATA),
   .I_DLWR(I_DLWR),

   .O_R(W_R),
   .O_G(W_G),
   .O_B(W_B)
);

assign O_VGA_RED = W_R;
assign O_VGA_GRN = W_G;
assign O_VGA_BLU = W_B;

endmodule
