//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Address decoding (synchronous rework of dkong3_adec)
//
// Single clock `clk` (98.304 MHz). The original mixed three fabric clocks:
//   I_CLK   (4 MHz CPU)  -> cen_cpu (posedge) / cen_cpu_n (negedge)
//   I_CLK12M(= O_CLK)    -> cen_o_clk_p
//   W_VBLK / I_VBLK_n    -> level reset + clk-domain edge-detect
// The two async resets (negedge I_VBLK_n on the WAIT flop, negedge W_3E_Q[4] on
// the NMI flop) become level resets; the NMI set on posedge W_VBLK becomes a
// registered negedge-detect of I_VBLK_n. Behaviour is bit-identical at the cen
// ticks (verified by tb/diff/adec_diff_tb.sv).
//----------------------------------------------------------------------------

module dkong3_adec_sync
(
   input        clk,
   input        cen_cpu,     // posedge 4 MHz CPU clock
   input        cen_cpu_n,   // negedge 4 MHz CPU clock
   input        cen_o_clk_p, // posedge O_CLK (12.288, was I_CLK12M)

   input        I_RESET_n,
   input  [15:0]I_AB,
   input   [3:0]I_DB,
   input        I_MREQ_n,
   input        I_RFSH_n,
   input        I_RD_n,
   input        I_WR_n,
   input        I_VRAMBUSY_n,
   input        I_VBLK_n,

   input        I_DLCLK,
   input  [16:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,

   output       O_WAIT_n,
   output       O_NMI_n,

   output  [3:0]O_MROM_CSn,
   output  [1:0]O_MRAM_CSn,

   output       O_5A_G_n,
   output       O_OBJ_RQ_n,
   output       O_OBJ_RD_n,
   output       O_OBJ_WR_n,
   output       O_VRAM_RD_n,
   output       O_VRAM_WR_n,
   output       O_SW1_OE_n,
   output       O_SW2_OE_n,
   output       O_DIP1_OE_n,
   output       O_DIP2_OE_n,
   output  [7:0]O_3E_Q,
   output  reg [3:0]O_4E_Q,
   output       O_SUB_RESETn
);

//----------
// CPU WAIT  (was posedge I_CLK / async negedge I_VBLK_n)
//----------
reg    W_2D1_Qn;
reg    W_2D2_Q;
assign O_WAIT_n = W_2D1_Qn;

always@(posedge clk)
begin
   if(I_VBLK_n == 1'b0)
      W_2D1_Qn <= 1'b1;
   else if (cen_cpu)
      W_2D1_Qn <= I_VRAMBUSY_n | W_3B2_Q[1] | ~I_RFSH_n;
end

// Enable signal for writing to VRAM and OBJRAM (was negedge I_CLK).
always@(posedge clk) if (cen_cpu_n)
   W_2D2_Q <= W_2D1_Qn;

//-----------------------------------------------
// CPU NMI  (was posedge W_VBLK / async negedge W_3E_Q[4])
//-----------------------------------------------
reg   vblk_n_d;
always@(posedge clk) vblk_n_d <= I_VBLK_n;
wire  vblk_fall = vblk_n_d & ~I_VBLK_n;   // posedge W_VBLK = negedge I_VBLK_n

reg   NMI_n;
always@(posedge clk)
begin
   if(~W_3E_Q[4])
      NMI_n <= 1'b1;
   else if (vblk_fall)
      NMI_n <= 1'b0;
end

assign O_NMI_n = NMI_n;

//---------------------------
// Address Decoder PROM @ 5E  (was posedge I_CLK12M)
//---------------------------
wire  [7:0]W_PROM5E_Q;

ADEC_PROM_CE prom5e(clk, cen_o_clk_p, I_AB[15:11], W_PROM5E_Q,
                    I_DLCLK, I_DLADDR, I_DLDATA, I_DLWR);

assign O_MROM_CSn = W_PROM5E_Q[4:1];
assign O_MRAM_CSn = W_PROM5E_Q[6:5];

//--------------
// 74LS139 @ 3B
//--------------
wire   [3:0]W_3B1_Q, W_3B2_Q;

logic_74xx139 U_3B_1
(
   .I_G(W_PROM5E_Q[0]),
   .I_Sel({1'b0,I_AB[11]}),
   .O_Q(W_3B1_Q)
);

assign O_5A_G_n = W_3B1_Q[0];

logic_74xx139 U_3B_2
(
   .I_G(W_PROM5E_Q[0] | I_MREQ_n),
   .I_Sel(I_AB[11:10]),
   .O_Q(W_3B2_Q)
);

assign O_OBJ_RQ_n = W_3B2_Q[0];

//--------------
// 74LS138 @ 2A
//--------------
wire  [7:0]W_2A_Q;

logic_74xx138 U_2A
(
   .I_G1(W_2D2_Q),
   .I_G2a(I_WR_n),
   .I_G2b(I_MREQ_n),
   .I_Sel({W_PROM5E_Q[0],I_AB[11:10]}),
   .O_Q(W_2A_Q)
);

assign O_OBJ_WR_n  = W_2A_Q[0];
assign O_VRAM_WR_n = W_2A_Q[1];

//--------------
// 74LS138 @ 3A
//--------------
wire  [7:0]W_3A_Q;

logic_74xx138 U_3A
(
   .I_G1(1'b1),
   .I_G2a(I_RD_n),
   .I_G2b(I_MREQ_n),
   .I_Sel({W_PROM5E_Q[0],I_AB[11:10]}),
   .O_Q(W_3A_Q)
);

assign O_OBJ_RD_n  = W_3A_Q[0];
assign O_VRAM_RD_n = W_3A_Q[1];

//--------------------------------------
// 74LS138 @ 4E
//--------------------------------------
wire [7:0]W_4E_Q;

logic_74xx138 U_4E
(
   .I_G1(1'b1),
   .I_G2a(I_WR_n),
   .I_G2b(W_3B2_Q[3]),
   .I_Sel(I_AB[9:7]),
   .O_Q(W_4E_Q)
);

always @(posedge clk) if (cen_o_clk_p)
 O_4E_Q <= W_4E_Q[3:0];

//-----------------------------------
// 74LS138 @ 4F
//-----------------------------------
wire [7:0]W_4F_Q;

logic_74xx138 U_4F
(
   .I_G1(1'b1),
   .I_G2a(I_RD_n),
   .I_G2b(W_3B2_Q[3]),
   .I_Sel(I_AB[9:7]),
   .O_Q(W_4F_Q)
);

assign O_SW1_OE_n  = W_4F_Q[0];
assign O_SW2_OE_n  = W_4F_Q[1];
assign O_DIP2_OE_n = W_4F_Q[2];
assign O_DIP1_OE_n = W_4F_Q[3];

//--------------------------------------
// 74LS259 @ 3E  (was posedge I_CLK12M / async negedge I_RESET_n)
//--------------------------------------
reg   [7:0]W_3E_Q;

always@(posedge clk)
begin
   if(I_RESET_n == 1'b0) begin
      W_3E_Q <= 0;
   end
   else if (cen_o_clk_p) begin
      if(W_4E_Q[5] == 1'b0) begin
         case(I_AB[2:0])
            3'h0 : W_3E_Q[0] <= I_DB[0];
            3'h1 : W_3E_Q[1] <= I_DB[0];
            3'h2 : W_3E_Q[2] <= I_DB[0];
            3'h3 : W_3E_Q[3] <= I_DB[0];
            3'h4 : W_3E_Q[4] <= I_DB[0];
            3'h5 : W_3E_Q[5] <= I_DB[0];
            3'h6 : W_3E_Q[6] <= I_DB[0];
            3'h7 : W_3E_Q[7] <= I_DB[0];
         endcase
      end
   end
end

assign O_3E_Q = W_3E_Q;

//---------------------------
// 74LS174 @ 5H  (was posedge I_CLK12M / async negedge I_RESET_n)
//---------------------------
reg  sub_resetn;
reg  prev_4e3;

always@(posedge clk)
begin
   if(I_RESET_n == 1'b0) begin
      sub_resetn <= 0;            // (original leaves `prev` unreset)
   end
   else if (cen_o_clk_p) begin
      prev_4e3 <= W_4E_Q[3];
      if (~prev_4e3 & W_4E_Q[3]) begin
         sub_resetn <= I_DB[0];
      end
   end
end

assign O_SUB_RESETn = sub_resetn;

endmodule
