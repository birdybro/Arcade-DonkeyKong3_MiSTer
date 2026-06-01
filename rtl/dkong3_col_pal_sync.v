//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Colour palette (synchronous rework of dkong3_col_pal)
//
// Single clock `clk` (98.304 MHz) + clock-enables:
//   cen_hcnt0_p  posedge H_CNT[0] (6.144) -> the 1B/2C latch (was I_CLK_6M)
//   cen_24m_p    posedge 24.576           -> CLUT PROMs 1D/1C (was I_CLK_24M)
//
// The 1B/2C register has a *self-resetting* async reset
// (W_1B2C_RST = I_CMPBLKn | W_1B2C_Q[0]); reproduced here as a level reset in
// the clk domain (asserts Q=0 while RST is low, loads on the cen tick otherwise).
// Behaviour is bit-identical (verified by tb/diff/col_pal_diff_tb.sv).
//----------------------------------------------------------------------------

module dkong3_col_pal_sync
(
   input        clk,
   input        cen_24m_p,
   input        cen_hcnt0_p,
   input   [5:0]I_VRAM_D,
   input   [5:0]I_OBJ_D,
   input        I_CMPBLKn,
   input   [1:0]I_CPAL_SEL,
   input        I_DLCLK,
   input  [17:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,

   output  [3:0]O_R,
   output  [3:0]O_G,
   output  [3:0]O_B
);

// Link CL1 on the schematics
parameter CL1 = 1'b1;

//-------------------------------------
// Parts 3M, 3L (74LS157) - sprite vs background, sprites take priority
//-------------------------------------
wire   [5:0]W_3ML_Y = (~(I_OBJ_D[0]|I_OBJ_D[1])) ? I_VRAM_D: I_OBJ_D;

//--------------
// Parts 1B, 2C  (was posedge I_CLK_6M / negedge W_1B2C_RST)
//--------------
wire   [8:0]W_1B2C_D = {I_CPAL_SEL,W_3ML_Y[5:0],I_CMPBLKn};
reg    [8:0]W_1B2C_Q;
wire   W_1B2C_RST  =  I_CMPBLKn | W_1B2C_Q[0];

always@(posedge clk)
begin
   if(W_1B2C_RST == 1'b0)
      W_1B2C_Q <= 9'd0;
   else if (cen_hcnt0_p)
      W_1B2C_Q <= W_1B2C_D;
end

//--------------------------------------------------------------
// Colour PROM's 1D (512 x 8bit) and 1C (512 x 4bit)
//--------------------------------------------------------------
wire   [8:0]W_PAL_AB = {CL1,W_1B2C_Q[8:1]};
wire   [7:0]W_1D_DO;
wire   [3:0]W_1C_DO;

CLUT_PROM_512_8_CE prom1d(clk, cen_24m_p, W_PAL_AB, W_1D_DO,
                          I_DLCLK, I_DLADDR[16:0], I_DLDATA, I_DLWR);

CLUT_PROM_512_4_CE prom1c(clk, cen_24m_p, W_PAL_AB, W_1C_DO,
                          I_DLCLK, I_DLADDR[16:0], I_DLDATA, I_DLWR);

assign {O_R, O_G, O_B} = {W_1D_DO,W_1C_DO};

endmodule
