//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade
//
// Author: gaz68 (https://github.com/gaz68) July 2020
//
// Top level module
//----------------------------------------------------------------------------

module dkong3_top
(
   input         I_CLK_24M,
   input         I_CLK_4M,
   input         I_SUBCLK,
   input         I_RESETn,

   input    [7:0]I_SW1,
   input    [7:0]I_SW2,
   input    [7:0]I_DIP_SW1,
   input    [7:0]I_DIP_SW2,

   input   [16:0]dn_addr,
   input    [7:0]dn_data,
   input         dn_wr,

   input         flip_screen,
   input    [8:0]H_OFFSET,
   input    [8:0]V_OFFSET,

   output   [3:0]O_VGA_R,
   output   [3:0]O_VGA_G,
   output   [3:0]O_VGA_B,
   output        O_VGA_HSYNCn,
   output        O_VGA_VSYNCn,
   output        O_HBLANK,
   output        O_VBLANK,
   output        O_PIX,

   output signed [15:0] O_SOUND_DAT
);

wire   W_RESETn      = I_RESETn;

// 2-FF reset deassertion sync into clk_main. I_RESETn is generated
// synchronously in clk_sys (Arcade-DonkeyKong3.sv); without this, the
// emu|reset -> T80as|Reset_s recovery path crosses two PLL outputs
// (24.576 MHz -> 4 MHz) with a non-integer ratio, and the cross-PLL
// common-period window collapses below routing delay. s1 async-asserts
// on reset, sync-deasserts on clk_main; s2 is purely synchronous so it
// has no cross-PLL recovery path of its own.
reg cpu_resetn_s1;
always @(posedge I_CLK_4M or negedge W_RESETn) begin
   if (!W_RESETn) cpu_resetn_s1 <= 1'b0;
   else           cpu_resetn_s1 <= 1'b1;
end

reg cpu_resetn_s2;
always @(posedge I_CLK_4M) cpu_resetn_s2 <= cpu_resetn_s1;

wire   W_CPU_RESETn  = cpu_resetn_s2;

//-----------------
// Clocks / Timing
//-----------------

wire        W_CLK_12M;
wire        W_CPU_CLK;

wire   [9:0]W_H_CNT;
wire   [7:0]W_V_CNT;
wire   [7:0]W_VF_CNT;
wire        W_HBLANKn;
wire        W_VBLANKn;
wire        W_CBLANKn;
wire        W_HSYNCn;
wire        W_VSYNCn;

dkong3_hv_count hv
(
   .I_CLK(I_CLK_24M),
   .I_RST_n(W_RESETn),
   .I_VFLIP(W_FLIP_HV),
   .H_OFFSET(H_OFFSET),
   .V_OFFSET(V_OFFSET),

   .O_CLK(W_CLK_12M),
   .H_CNT(W_H_CNT),
   .V_CNT(W_V_CNT), // Not used
   .VF_CNT(W_VF_CNT),
   .H_BLANKn(W_HBLANKn),
   .V_BLANKn(W_VBLANKn),
   .C_BLANKn(W_CBLANKn),
   .H_SYNCn(W_HSYNCn),
   .V_SYNCn(W_VSYNCn)
);

assign O_PIX         = W_H_CNT[0];

assign O_HBLANK      = ~W_HBLANKn;
assign O_VBLANK      = ~W_VBLANKn;
assign O_VGA_HSYNCn  = W_HSYNCn;
assign O_VGA_VSYNCn  = W_VSYNCn;

//-----------------------------------------
// Main CPU 
// ROM, RAM, address decoding, inputs etc.
//-----------------------------------------

wire  [15:0]W_MCPU_A;
wire   [7:0]ZDI;
wire   [7:0]WI_D = ZDI;
wire        W_MCPU_RDn;  
wire        W_MCPU_WRn;

wire   [9:0]W_DMAD_A;
wire   [7:0]W_DMAD_D;
wire        W_DMAD_CE;

wire        W_OBJ_RQn;
wire        W_OBJ_RDn;
wire        W_OBJ_WRn;
wire        W_VRAM_RDn;
wire        W_VRAM_WRn;

wire   [7:0]W_3E_Q;
wire   [3:0]W_4E_Q;
wire        W_SUB_RESETn_RAW;
wire        W_SUB_RESETn;

// 2-FF reset deassertion sync into I_SUBCLK. W_SUB_RESETn_RAW comes from
// dkong3_adec registered on clk_sys/12M; T65 has its own internal sync but
// the APU on clk_sub does not. Same shape as the Z80 sync above: s1 async-
// asserts and sync-deasserts; s2 is purely synchronous in clk_sub.
reg sub_resetn_s1;
always @(posedge I_SUBCLK or negedge W_SUB_RESETn_RAW) begin
   if (!W_SUB_RESETn_RAW) sub_resetn_s1 <= 1'b0;
   else                   sub_resetn_s1 <= 1'b1;
end

reg sub_resetn_s2;
always @(posedge I_SUBCLK) sub_resetn_s2 <= sub_resetn_s1;

assign W_SUB_RESETn = sub_resetn_s2;

dkong3_main maincpu
(
   .I_CLK_24M(I_CLK_24M),
   .I_CLK_12M(W_CLK_12M),
   .I_MCPU_CLK(I_CLK_4M),
   .I_MCPU_RESETn(W_CPU_RESETn),
   .I_VRAMBUSY_n(W_VRAMBUSYn),
   .I_VBLK_n(W_VBLANKn),
   .I_VRAM_DB(W_VRAM_DB),
   .I_DLADDR(dn_addr), 
   .I_DLDATA(dn_data),
   .I_DLWR(dn_wr),
   .I_SW1(I_SW1),
   .I_SW2(I_SW2),
   .I_DIP1(I_DIP_SW1),
   .I_DIP2(I_DIP_SW2),

   .O_MCPU_A(W_MCPU_A),
   .WI_D(ZDI),
   .O_MCPU_RDn(W_MCPU_RDn),
   .O_MCPU_WRn(W_MCPU_WRn),
   .O_DMAD_A(W_DMAD_A),
   .O_DMAD_D(W_DMAD_D),
   .O_DMAD_CE(W_DMAD_CE),
   .O_OBJ_RQn(W_OBJ_RQn),
   .O_OBJ_RDn(W_OBJ_RDn),
   .O_OBJ_WRn(W_OBJ_WRn),
   .O_VRAM_RDn(W_VRAM_RDn),
   .O_VRAM_WRn(W_VRAM_WRn),
   .O_3E_Q(W_3E_Q),
   .O_4E_Q(W_4E_Q),
   .O_SUB_RESETn(W_SUB_RESETn_RAW)
);

//------------------------------------
// Video
// Background tiles, sprites, colours
//------------------------------------

wire       W_VRAMBUSYn;
wire  [7:0]W_VRAM_DB;
wire  [7:0]W_OBJ_DB;
wire       W_FLIP_HV;
wire  [3:0]W_R;
wire  [3:0]W_G;
wire  [3:0]W_B;

dkong3_video vid
(
   .I_CLK_24M(I_CLK_24M),
   .I_CLK_12M(W_CLK_12M),
   .I_RESETn(W_RESETn),
   .I_CPU_A(W_MCPU_A[9:0]),
   .I_CPU_D(WI_D),

   .I_VRAM_WRn(W_VRAM_WRn),
   .I_VRAM_RDn(W_VRAM_RDn),
   .I_3E_Q(W_3E_Q),

   .I_H_CNT(W_H_CNT),
   .I_VF_CNT(W_VF_CNT),
   .I_CBLANKn(W_CBLANKn), 

   .I_OBJDMA_A(W_DMAD_A),
   .I_OBJDMA_D(W_DMAD_D),
   .I_OBJDMA_CE(W_DMAD_CE),
   .I_DLADDR(dn_addr), 
   .I_DLDATA(dn_data),
   .I_DLWR(dn_wr),
   .flip_screen(flip_screen),

   .O_VRAM_DB(W_VRAM_DB),
   .O_VRAMBUSYn(W_VRAMBUSYn),
   .O_FLIP_HV(W_FLIP_HV),
   .O_OBJ_DB(W_OBJ_DB), // Not used
   .O_VGA_RED(W_R),
   .O_VGA_GRN(W_G),
   .O_VGA_BLU(W_B)
);

assign O_VGA_R = W_R;
assign O_VGA_G = W_G;
assign O_VGA_B = W_B;

//-------
// Sound
//-------

wire signed[15:0] W_APU_SAMPLE;

dkong3_sound sound
(
   .I_CLK_24M(I_CLK_24M),
   .I_SUBCLK(I_SUBCLK),
   .I_SUB_NMIn(W_VBLANKn),
   .I_SUB_RESETn(W_SUB_RESETn),
   .I_4E_Q(W_4E_Q),
   .I_MCPU_DO(WI_D),
   
   .I_DLADDR(dn_addr), 
   .I_DLDATA(dn_data),
   .I_DLWR(dn_wr),
   
   .O_SAMPLE(W_APU_SAMPLE)
);

assign O_SOUND_DAT = W_APU_SAMPLE;


endmodule


