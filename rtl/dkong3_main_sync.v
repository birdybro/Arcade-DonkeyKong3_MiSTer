//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Main CPU subsystem (synchronous rework of dkong3_main)
//
// Single clock `clk` (98.304 MHz). The Z80 runs on clk gated by cen_cpu (the
// 4 MHz NCO enable) via Z80IP_CEN; the work RAM / ROM that were clocked by
// O_CLK / ~O_CLK move to cen_o_clk_p / cen_o_clk_n; the address decoder and
// sprite DMA use their _sync variants. Functionally identical to dkong3_main
// (components verified: t80_cen, adec_diff, dma_diff).
//----------------------------------------------------------------------------

module dkong3_main_sync
(
   input        clk,
   input        cen_cpu,      // 4 MHz CPU enable
   input        cen_cpu_n,    // negedge-4 MHz enable (DMA)
   input        cen_o_clk_p,  // posedge O_CLK (12.288)
   input        cen_o_clk_n,  // negedge O_CLK
   input        I_MCPU_RESETn,

   input        I_VRAMBUSY_n,
   input        I_VBLK_n,
   input   [7:0]I_SW1,
   input   [7:0]I_SW2,
   input   [7:0]I_DIP1,
   input   [7:0]I_DIP2,
   input   [7:0]I_VRAM_DB,

   input        I_DLCLK,
   input  [16:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,

   output [15:0]O_MCPU_A,
   output [7:0] WI_D,
   output       O_MCPU_RDn,
   output       O_MCPU_WRn,

   output  [9:0]O_DMAD_A,
   output  [7:0]O_DMAD_D,
   output       O_DMAD_CE,

   output       O_OBJ_RQn,
   output       O_OBJ_RDn,
   output       O_OBJ_WRn,
   output       O_VRAM_RDn,
   output       O_VRAM_WRn,
   output  [7:0]O_3E_Q,
   output  [3:0]O_4E_Q,
   output       O_SUB_RESETn
);

//-----------------------
// Main CPU - Z80 (4 MHz via cen_cpu)
//-----------------------
wire   W_MCPU_WAITn;
wire   W_MCPU_RFSHn;
wire   W_MCPU_M1n;
wire   W_MCPU_NMIn;
wire   W_MCPU_MREQn;
wire   W_MCPU_RDn;
wire   W_MCPU_WRn;
wire   [15:0]W_MCPU_A;

wire   [7:0]ZDO, ZDI;
assign WI_D = ZDI;

Z80IP_CEN CPU
(
   .CLK2X(),
   .CLK(clk),
   .CEN(cen_cpu),
   .RESET_N(I_MCPU_RESETn),
   .INT_N(1'b1),
   .NMI_N(W_MCPU_NMIn),
   .ADRS(W_MCPU_A),
   .DOUT(ZDI),
   .DINP(ZDO),
   .M1_N(W_MCPU_M1n),
   .MREQ_N(W_MCPU_MREQn),
   .IORQ_N(),
   .RD_N(W_MCPU_RDn),
   .WR_N(W_MCPU_WRn),
   .WAIT_N(W_MCPU_WAITn),
   .BUSWO(),
   .RFSH_N(W_MCPU_RFSHn),
   .HALT_N()
);

assign O_MCPU_A    = W_MCPU_A;
assign O_MCPU_RDn  = W_MCPU_RDn;
assign O_MCPU_WRn  = W_MCPU_WRn;

wire   [7:0]WO_D = W_MROM_DO | W_MRAM7F_DO | W_MRAM7H_DO | W_SW_DO | I_VRAM_DB;
assign ZDO = WO_D;

//------------------
// Address decoding
//------------------
wire  [3:0]W_MROM_CS_n;
wire  [1:0]W_MRAM_CS_n;
wire       W_SW1_OEn;
wire       W_SW2_OEn;
wire       W_DIP1_OEn;
wire       W_DIP2_OEn;
wire  [7:0]W_3E_Q;

dkong3_adec_sync adec
(
   .clk(clk),
   .cen_cpu(cen_cpu),
   .cen_cpu_n(cen_cpu_n),
   .cen_o_clk_p(cen_o_clk_p),
   .I_RESET_n(I_MCPU_RESETn),
   .I_AB(W_MCPU_A),
   .I_DB(WI_D),
   .I_MREQ_n(W_MCPU_MREQn),
   .I_RFSH_n(W_MCPU_RFSHn),
   .I_RD_n(W_MCPU_RDn),
   .I_WR_n(W_MCPU_WRn),
   .I_VRAMBUSY_n(I_VRAMBUSY_n),
   .I_VBLK_n(I_VBLK_n),
   .I_DLCLK(I_DLCLK),
   .I_DLADDR(I_DLADDR),
   .I_DLDATA(I_DLDATA),
   .I_DLWR(I_DLWR),

   .O_WAIT_n(W_MCPU_WAITn),
   .O_NMI_n(W_MCPU_NMIn),
   .O_MROM_CSn(W_MROM_CS_n),
   .O_MRAM_CSn(W_MRAM_CS_n),
   .O_5A_G_n(),
   .O_OBJ_RQ_n(O_OBJ_RQn),
   .O_OBJ_RD_n(O_OBJ_RDn),
   .O_OBJ_WR_n(O_OBJ_WRn),
   .O_VRAM_RD_n(O_VRAM_RDn),
   .O_VRAM_WR_n(O_VRAM_WRn),
   .O_SW1_OE_n(W_SW1_OEn),
   .O_SW2_OE_n(W_SW2_OEn),
   .O_DIP1_OE_n(W_DIP1_OEn),
   .O_DIP2_OE_n(W_DIP2_OEn),
   .O_3E_Q(W_3E_Q),
   .O_4E_Q(O_4E_Q),
   .O_SUB_RESETn(O_SUB_RESETn)
);

assign O_3E_Q = W_3E_Q;

//----------
// Main ROM  (was posedge I_CLK_12M)
//----------
wire  [7:0]W_MROM_DO;

MAIN_ROM_CE mrom(clk, cen_o_clk_p, W_MCPU_A, W_MROM_CS_n, W_MCPU_RDn, W_MROM_DO,
                 I_DLCLK, I_DLADDR, I_DLDATA, I_DLWR);

//-----------------------
// Main CPU RAM 7F (2KB)  (was ~I_CLK_12M = negedge O_CLK)
//-----------------------
wire  [7:0]W_7F_DO_raw;
wire  [7:0]W_7F_DO = (~W_MRAM_CS_n[0]) ? W_7F_DO_raw : 8'h00;  // = ram_2048_8 O_D
reg   [7:0]W_MRAM7F_DO;

dpram #(11,8) U_7F
(
   .clock_a   (clk),
   .address_a (W_MCPU_A[10:0]),
   .data_a    (WI_D),
   .enable_a  (~W_MRAM_CS_n[0] & cen_o_clk_n),
   .wren_a    (~W_MCPU_WRn),
   .q_a       (W_7F_DO_raw),
   .clock_b   (clk)
);

always@(posedge clk) if (cen_o_clk_p)
   W_MRAM7F_DO <= (W_MCPU_RDn == 1'b0 & W_MRAM_CS_n[0] == 1'b0) ? W_7F_DO : 8'b0;

//------------------------------------------
// Main CPU RAM 7H (2KB) - also read by DMA
//------------------------------------------
wire  [7:0]W_7H_DOA_raw;
wire  [7:0]W_MRAM7H_DO = (~W_MRAM_CS_n[1] & ~W_MCPU_RDn) ? W_7H_DOA_raw : 8'h00; // = ram_2048_8_8 O_DA
wire  [7:0]W_DMAS_D_raw;
wire  [7:0]W_DMAS_D = (W_DMAS_CE & 1'b1) ? W_DMAS_D_raw : 8'h00;                 // O_DB (I_OEB=1)

dpram #(11,8) U_7H
(
   // A Port - CPU (was ~I_CLK_12M = negedge O_CLK)
   .clock_a   (clk),
   .address_a (W_MCPU_A[10:0]),
   .data_a    (WI_D),
   .enable_a  (~W_MRAM_CS_n[1] & cen_o_clk_n),
   .wren_a    (~W_MCPU_WRn),
   .q_a       (W_7H_DOA_raw),

   // B Port - DMA read (was I_CLK_12M = posedge O_CLK)
   .clock_b   (clk),
   .address_b (W_DMAS_A),
   .data_b    (8'h00),
   .enable_b  (W_DMAS_CE & cen_o_clk_p),
   .wren_b    (1'b0),
   .q_b       (W_DMAS_D_raw)
);

//------------------------------------------
// Sprite DMA  (was ~I_MCPU_CLK = negedge 4 MHz)
//------------------------------------------
wire  [9:0]W_DMAS_A;
wire       W_DMAS_CE;
wire  [9:0]W_DMAD_A;
wire  [7:0]W_DMAD_D;
wire       W_DMAD_CE;

dkong3_dma_sync sprite_dma
(
   .clk(clk),
   .cen(cen_cpu_n),
   .I_RSTn(I_MCPU_RESETn),
   .I_DMA_TRIG(W_3E_Q[5]),
   .I_DMA_DS(W_DMAS_D),

   .O_DMA_AS(W_DMAS_A),
   .O_DMA_CES(W_DMAS_CE),
   .O_DMA_AD(W_DMAD_A),
   .O_DMA_DD(W_DMAD_D),
   .O_DMA_CED(W_DMAD_CE)
);

assign O_DMAD_A  = W_DMAD_A;
assign O_DMAD_D  = W_DMAD_D;
assign O_DMAD_CE = W_DMAD_CE;

//---------------------------
// Inputs  (was posedge I_CLK_12M)
//---------------------------
wire [7:0]W_SW_DO;

dkong3_input_sync inputs
(
   .clk(clk),
   .cen(cen_o_clk_p),
   .I_SW1(I_SW1),
   .I_SW2(I_SW2),
   .I_DIP1(I_DIP1),
   .I_DIP2(I_DIP2),
   .I_SW1_OE_n(W_SW1_OEn),
   .I_SW2_OE_n(W_SW2_OEn),
   .I_DIP1_OE_n(W_DIP1_OEn),
   .I_DIP2_OE_n(W_DIP2_OEn),

   .O_D(W_SW_DO)
);

endmodule
