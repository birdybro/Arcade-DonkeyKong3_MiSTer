//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Objects/sprites (synchronous rework of dkong3_obj)
//
// Single clock `clk` (98.304 MHz). Every flop is `posedge clk` + a clock-enable.
// Strobes from dkong3_hv_count_sync (obj's I_CLK_12M is O_CLK itself, NOT the
// inverted copy vram receives):
//   cen_24m_p / cen_24m_n   posedge / negedge 24.576
//   cen_o_clk_p / cen_o_clk_n  posedge / negedge O_CLK (12.288)
//   cen_hcnt9_n             negedge H_CNT[9]
//   I_OCLK                  O_CLK as a *level* (data input, not a clock) for the
//                           gated-clock decode of CLK_5L / CLK_3E.
//
// Register/gated/ripple clocks of the original are reproduced as decoded
// enables. For the register-as-clock flops whose data is produced by another
// flop clocked on the SAME originating edge (negedge 24M), the original's
// physical clk-to-Q delay makes them capture the *post-edge* data; we reproduce
// that with a one-clk-delayed strobe (`*_rise_d`). Behaviour is bit-identical
// (verified by tb/diff/obj_diff_tb.sv). See docs/clock-rework/ANALYSIS.md.
//----------------------------------------------------------------------------

module dkong3_obj_sync
(
   input        clk,
   input        cen_24m_p,
   input        cen_24m_n,
   input        cen_o_clk_p,
   input        cen_o_clk_n,
   input        cen_hcnt9_n,
   input        I_OCLK,        // O_CLK level (12.288), used only as data

   input   [9:0]I_AB,
   input   [7:0]I_DB,
   input        I_OBJ_WRn,
   input        I_OBJ_RDn,
   input        I_OBJ_RQn,
   input        I_2PSL,
   input        I_FLIPn,
   input        I_CMPBLKn,
   input   [9:0]I_H_CNT,
   input   [7:0]I_VF_CNT,
   input   [9:0]I_OBJ_DMA_A,
   input   [7:0]I_OBJ_DMA_D,
   input        I_OBJ_DMA_CE,
   input  [17:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,
   input        flip_screen,

   output  [7:0]O_DB, // Not used
   output  [5:0]O_OBJ_DO,
   output       O_FLIP_VRAM,
   output       O_FLIP_HV,
   output       O_L_CMPBLKn
);

// ---- W_5B : was negedge I_CLK_24M --------------------------------------
wire   W_5F1_G = ~(I_H_CNT[0]&I_H_CNT[1]&I_H_CNT[2]&I_H_CNT[3]);
reg    W_5B;
always@(posedge clk) if (cen_24m_n)
   W_5B <= ~(I_H_CNT[0]&I_H_CNT[1]&I_H_CNT[2]&I_H_CNT[3]);

wire   [3:0]W_5F1_Q;
wire   [3:0]W_5F2_QB;

logic_74xx139 U_5F1
(
   .I_G(W_5F1_G),
   .I_Sel({~I_H_CNT[9],I_H_CNT[3]}),
   .O_Q(W_5F1_Q)
);

logic_74xx139 U_5F2
(
   .I_G(1'b0),
   .I_Sel({I_H_CNT[3],I_H_CNT[2]}),
   .O_Q(W_5F2_QB)
);

// W_5F2_Q : was negedge I_CLK_24M
reg    [3:0]W_5F2_Q;
always@(posedge clk) if (cen_24m_n) W_5F2_Q <= W_5F2_QB;

// posedge of the register-as-clock outputs W_5F2_Q[0] / W_5F2_Q[2].
// W_5F2_Q only changes on cen_24m_n; its next value is W_5F2_QB. The data the
// dependent flops capture (W_HD / RAM 7M output) also updates on cen_24m_n, so
// the original sees the post-edge data -> apply via a one-clk-delayed strobe.
wire   w5f2q0_rise = cen_24m_n & ~W_5F2_Q[0] & W_5F2_QB[0];
wire   w5f2q2_rise = cen_24m_n & ~W_5F2_Q[2] & W_5F2_QB[2];
reg    w5f2q0_rise_d, w5f2q2_rise_d;
always@(posedge clk) begin
   w5f2q0_rise_d <= w5f2q0_rise;
   w5f2q2_rise_d <= w5f2q2_rise;
end

//----------  FLIP ----------------------------------------------------
wire   W_FLIP_1  = ~I_FLIPn ^ flip_screen;            // INV
wire   W_FLIP_2  =  W_FLIP_1 ^ 1'b1;                  // INV => XOR
wire   W_FLIP_3  = ~W_FLIP_2;                         // INV => XOR => INV
wire   W_FLIP_4  =  W_FLIP_3 | W_5F2_Q[0];
wire   W_FLIP_5  = ~W_FLIP_4;

assign O_FLIP_VRAM = W_FLIP_1;
assign O_FLIP_HV   = W_FLIP_3;

//-------  DB CONTROL  ------------------------------------------------
wire   [7:0]WI_DB = I_OBJ_WRn ? 8'h00: I_DB;
wire   [7:0]WO_DB;

//-------------------
// Object RAM 6P, 6R   (was ram_1024_8_8: A=~I_CLK_12M write, B=I_CLK_12M read)
//-------------------
wire   [9:0]W_OBJ_AB = {I_2PSL, I_H_CNT[8:0]};
wire   [7:0]W_OBJ_DI;

// Inferred TDP RAM (not altsyncram): two different clock-enables on the one
// master clk (write @ cen_o_clk_n, read @ cen_o_clk_p) need predictable M10K
// behaviour. See rtl/tdp_ram.v.
tdp_ram #(10,8) U_6PR
(
   .clk     (clk),
   // A Port - DMA write (was ~I_CLK_12M = negedge O_CLK)
   .addr_a  (I_OBJ_DMA_A),
   .data_a  (I_OBJ_DMA_D),
   .en_a    (I_OBJ_DMA_CE & cen_o_clk_n),
   .we_a    (1'b1),
   .q_a     (),
   // B Port - scan read (was I_CLK_12M = posedge O_CLK)
   .addr_b  (W_OBJ_AB),
   .data_b  (8'h00),
   .en_b    (cen_o_clk_p),
   .we_b    (1'b0),
   .q_b     (W_OBJ_DI)
);

//-------  AB CONTROL  ------------------------------------------------
wire        W_AB_SEL = I_OBJ_WRn & I_OBJ_RDn & I_OBJ_RQn;
wire   [9:0]W_obj_AB = W_AB_SEL ? {I_2PSL,I_H_CNT[8:0]} : I_AB ;
wire        W_obj_CS = W_AB_SEL ? 1'b0     : I_OBJ_WRn & I_OBJ_RDn;

//-------  VFC_CNT[7:0] : was negedge I_H_CNT[9] -----------------------
reg    [7:0]W_VFC_CNT;
always@(posedge clk) if (cen_hcnt9_n) W_VFC_CNT <= I_VF_CNT;

//------  PARTS 6N : was negedge I_CLK_12M ----------------------------
reg    [7:0]W_6N_Q;
always@(posedge clk) if (cen_o_clk_n) W_6N_Q <= W_OBJ_DI;

wire   [7:0]W_78R_A = W_6N_Q;
wire   [7:0]W_78R_B = {4'b1111,I_FLIPn ^ flip_screen,W_FLIP_1,W_FLIP_1,1'b1};

wire   [8:0]W_78R_Q = W_78R_A + W_78R_B + 8'b00000001;

wire   [7:0]W_78P_A = W_78R_Q[7:0];
wire   [7:0]W_78P_B = I_VF_CNT[7:0];

wire   [8:0]W_78P_Q = W_78P_A + W_78P_B;

// W_7H : was posedge I_CLK_12M
reg    W_7H;
always@(posedge clk) if (cen_o_clk_p)
   W_7H <= ~(W_78P_Q[7]&W_78P_Q[6]&W_78P_Q[5]&W_78P_Q[4]);

// CLK_4L : was negedge I_CLK_24M (reg used as a clock for W_4L_Q)
reg    [7:0]W_5L_Q;
reg    CLK_4L;
wire   CLK_4L_next = ~(I_H_CNT[0]&(~I_H_CNT[1]));
always@(posedge clk) if (cen_24m_n) CLK_4L <= CLK_4L_next;
wire   clk4l_rise = cen_24m_n & ~CLK_4L & CLK_4L_next;

wire   W_6L = ~(W_5L_Q[6]|W_5L_Q[7]);
wire   W_3P = ~(I_H_CNT[2]&I_H_CNT[3]&I_H_CNT[4]&I_H_CNT[5]&I_H_CNT[6]&I_H_CNT[7]&I_H_CNT[8] & W_6L);

//-- U_4L --- was posedge CLK_4L, async reset RST_4L=~I_H_CNT[9] --------
reg    W_4L_Q;
always@(posedge clk)
begin
   if (I_H_CNT[9])         W_4L_Q <= 1'b0;          // RST_4L low (H9=1)
   else if (clk4l_rise)    W_4L_Q <= ~(W_7H&W_3P);
end

// CLK_5L : gated clock ~(I_CLK_12M & ~H9 & W_4L_Q & W_6L). Reproduced as a
// combinational level (for the 7M RAM write-enable, sampled at negedge 24M) and
// a posedge strobe (for the W_5L_Q counter): its rising edge is at negedge
// O_CLK when the gate term held.
wire   CLK_5L     = ~(I_OCLK & ~I_H_CNT[9] & W_4L_Q & W_6L);
wire   clk5l_rise = cen_o_clk_n & ~I_H_CNT[9] & W_4L_Q & W_6L;

//-- U_5L --- counter, was posedge CLK_5L, async reset W_5L_RST=~H9 -----
always@(posedge clk)
begin
   if (I_H_CNT[9])         W_5L_Q <= 8'd0;          // W_5L_RST low (H9=1)
   else if (clk5l_rise)    W_5L_Q <= W_5L_Q + 1'b1;
end

//------  PARTS 6M : was negedge I_CLK_12M ----------------------------
reg    [7:0]W_6M_Q;
always@(posedge clk) if (cen_o_clk_n) W_6M_Q <= W_6N_Q;

//----------------------------------------------------------------
wire   [5:0]W_RAM_7M_AB   = ~I_H_CNT[9] ? W_5L_Q[5:0]:I_H_CNT[7:2];
wire   [8:0]W_RAM_7M_DIB  = {W_6M_Q[7:0],W_3P};
wire   [8:0]W_RAM_7M_DOB;
wire   [8:0]W_RAM_7M_DOBn = W_RAM_7M_DOB[8:0];

// W_HD : was negedge I_CLK_24M
reg    [7:0]W_HD;
always@(posedge clk) if (cen_24m_n) W_HD <= W_RAM_7M_DOBn[8:1];

wire   [7:0]W_78K_A = W_RAM_7M_DOBn[8:1];
wire   [7:0]W_78K_B = {4'b1111,W_FLIP_5,W_FLIP_4,W_FLIP_4,1'b1};

wire   [8:0]W_78K_Q = W_78K_A + W_78K_B + 8'b00000001;

wire   [7:0]W_78J_A = W_78K_Q[7:0];
wire   [7:0]W_78J_B = W_VFC_CNT[7:0];

wire   [8:0]W_78J_Q = W_78J_A + W_78J_B;
wire   [7:0]W_8H_D  = W_78J_Q[7:0];

// W_8H_Q : was posedge W_5F2_Q[0] (data W_8H_D updates on cen_24m_n -> delayed)
reg    [7:0]W_8H_Q;
always@(posedge clk) if (w5f2q0_rise_d) W_8H_Q <= W_8H_D;

// W_6J_Q : was posedge W_5F2_Q[2] (data W_HD updates on cen_24m_n -> delayed)
reg    [7:0]W_6J_Q;
always@(posedge clk) if (w5f2q2_rise_d) W_6J_Q <= W_HD[7:0];

wire   [7:0]W_6K_D = {W_6J_Q[7],I_CMPBLKn,~I_H_CNT[9],
                      ~(I_H_CNT[9]|W_FLIP_2),W_6J_Q[3:0]};

// W_6K_Q : was posedge I_CLK_12M, enable ~W_5B
reg    [7:0]W_6K_Q;
always@(posedge clk) if (cen_o_clk_p)
begin
   if(W_5B == 1'b0) W_6K_Q <= W_6K_D;
   else             W_6K_Q <= W_6K_Q;
end

assign O_L_CMPBLKn = W_6K_Q[6];

// U_8N 74xx109 : CLK=W_5F2_Q[0], RST=I_H_CNT[9] (reset when 0), J=~DOBn[0], K=1.
// J data updates on cen_24m_n -> delayed strobe.
reg    W_8N_Q;
always@(posedge clk)
begin
   if (~I_H_CNT[9])           W_8N_Q <= 1'b0;       // RST asserted (H9=0)
   else if (w5f2q0_rise_d) begin
      if (~W_RAM_7M_DOBn[0])  W_8N_Q <= 1'b1;       // J=1 -> set; J=0 -> hold
   end
end

wire   W_6F  = ~(W_8H_Q[4]&W_8H_Q[5]&W_8H_Q[6]&W_8H_Q[7]);
wire   W_5J  = W_8N_Q|W_6F;
wire   W_6L1 = ~(W_5J|W_5B);

//------  PARTS 6H : latch (W_6H_G transparent) + posedge I_CLK_24M ----
wire    [7:0]W_6H_Q;
reg    [7:0]W_6H_Q_reg;
wire   W_6H_G = ~W_5F2_Q[1];
assign W_6H_Q = W_6H_G ? W_HD[7:0] : W_6H_Q_reg;
always @(posedge clk) if (cen_24m_p) W_6H_Q_reg <= W_6H_Q;

//------------
// Object ROM   (was OBJ_ROM on I_CLK_12M = posedge O_CLK)
//------------
wire   [11:0]W_ROM_OBJ_AB;
assign W_ROM_OBJ_AB[3:0]  = W_8H_Q[3:0]^{W_6H_Q[7],W_6H_Q[7],W_6H_Q[7],W_6H_Q[7]};
assign W_ROM_OBJ_AB[11:4] = {W_6J_Q[6],W_6H_Q[6:0]};
wire [31:0]W_ROM_OBJ_D;

OBJ_ROM_CE objrom(clk, cen_o_clk_p, W_ROM_OBJ_AB, ~I_H_CNT[9], W_ROM_OBJ_D,
                  clk, I_DLADDR[16:0], I_DLDATA, I_DLWR);

//----------------------------------------------------------------
wire   [3:0]W_8B_A,W_8B_B,W_8B_Y;
wire   W_8C_Qa,W_8D_Qh;
wire   W_8E_Qa,W_8F_Qh;

//------  PARTS 8CD : was posedge I_CLK_12M --------------------------
wire   [1:0]C_8CD = W_8B_Y[1:0];
wire  [15:0]I_8CD = W_ROM_OBJ_D[31:16];
reg   [15:0]reg_8CD;

assign W_8C_Qa = reg_8CD[15];
assign W_8D_Qh = reg_8CD[0];

always@(posedge clk) if (cen_o_clk_p)
begin
   case(C_8CD)
      2'b00: reg_8CD <= reg_8CD;
      2'b10: reg_8CD <= {reg_8CD[14:0],1'b0};
      2'b01: reg_8CD <= {1'b0,reg_8CD[15:1]};
      2'b11: reg_8CD <= I_8CD;
   endcase
end

//------  PARTS 8EF : was posedge I_CLK_12M --------------------------
wire   [1:0]C_8EF = W_8B_Y[1:0];
wire  [15:0]I_8EF = W_ROM_OBJ_D[15:0];
reg   [15:0]reg_8EF;

assign W_8E_Qa = reg_8EF[15];
assign W_8F_Qh = reg_8EF[0];

always@(posedge clk) if (cen_o_clk_p)
begin
   case(C_8EF)
      2'b00: reg_8EF <= reg_8EF;
      2'b10: reg_8EF <= {reg_8EF[14:0],1'b0};
      2'b01: reg_8EF <= {1'b0,reg_8EF[15:1]};
      2'b11: reg_8EF <= I_8EF;
   endcase
end

//------  PARTS 8B  ----------------------------------------------
assign W_8B_A = {W_8C_Qa,W_8E_Qa,1'b1,W_6L1};
assign W_8B_B = {W_8D_Qh,W_8F_Qh,W_6L1,1'b1};
assign W_8B_Y = W_6K_Q[7] ? W_8B_B:W_8B_A;

//------  PARTS 3E & 4E  -----------------------------------------
// CLK_3E : was negedge I_CLK_24M (reg used as a clock for W_3E_Q)
reg    CLK_3E;
wire   CLK_3E_next = ~(~(I_H_CNT[0]&W_6K_Q[5]) & I_OCLK);
always@(posedge clk) if (cen_24m_n) CLK_3E <= CLK_3E_next;

// posedge CLK_3E; W_3E load data W_3E_LD_DI=W_78K_Q updates on cen_24m_n
// (via RAM 7M output) -> delayed strobe.
wire   clk3e_rise = cen_24m_n & ~CLK_3E & CLK_3E_next;
reg    clk3e_rise_d;
always@(posedge clk) clk3e_rise_d <= clk3e_rise;

wire   [7:0]W_3E_LD_DI = W_78K_Q[7:0];

wire   W_3E_RST = W_5F1_Q[3]|W_6K_Q[5];
wire   W_3E_LD  = W_5F1_Q[1];

reg    [7:0]W_3E_Q;
always@(posedge clk) if (clk3e_rise_d)
begin
   if(W_3E_LD == 1'b0)
      W_3E_Q <= W_3E_LD_DI;
   else begin
      if(W_3E_RST == 1'b0)
         W_3E_Q <= 8'b0 ;
      else
         W_3E_Q <= W_3E_Q +1'b1;
   end
end

wire   [5:0]W_RAM_2EH_DO;
wire   [5:0]W_3J_B       = {W_6K_Q[3:0],W_8B_Y[2],W_8B_Y[3]};

wire   [5:0]W_RAM_2EH_DI = W_6K_Q[5] ? 6'h00 :(W_8B_Y[2]|W_8B_Y[3])? W_3J_B: W_RAM_2EH_DO;
wire   [7:0]W_RAM_2EH_AB = W_3E_Q[7:0]^{8{W_6K_Q[4]}};

// U_2EH_7M : 256x6 on posedge I_CLK_24M (WE=~CLK_3E); 64x9 on negedge I_CLK_24M
// (WE=~CLK_5L).
dpram #(8,6) U_2EH
(
   .clock_a   (clk),
   .address_a (W_RAM_2EH_AB),
   .data_a    (W_RAM_2EH_DI),
   .enable_a  (cen_24m_p),
   .wren_a    (~CLK_3E),
   .q_a       (W_RAM_2EH_DO),
   .clock_b   (clk)
);

dpram #(6,9) U_7M
(
   .clock_a   (clk),
   .address_a (W_RAM_7M_AB),
   .data_a    (W_RAM_7M_DIB),
   .enable_a  (cen_24m_n),
   .wren_a    (~CLK_5L),
   .q_a       (W_RAM_7M_DOB),
   .clock_b   (clk)
);

//------  PARTS 3K : was posedge I_CLK_24M, enable ~I_CLK_12M ---------
reg    [5:0]W_OBJ_DO;
always@(posedge clk) if (cen_24m_p)
begin
   if(~I_OCLK)
      W_OBJ_DO <= W_RAM_2EH_DO;
   else
      W_OBJ_DO <= W_OBJ_DO ;
end

assign O_OBJ_DO = W_OBJ_DO;

endmodule
