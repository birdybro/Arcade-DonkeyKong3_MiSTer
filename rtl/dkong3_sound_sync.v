//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Sound subsystem (synchronous rework of dkong3_sound)
//
// The legacy module was already a clean single-clock design (everything on
// posedge I_SUBCLK = 21.477 MHz; the 2A03 cadence is the div_cpu clock-enable).
// The rework just moves it onto the single master clock `clk` (98.304 MHz)
// gated by cen_snd (the 21.477 MHz NCO enable): every flop becomes
// `posedge clk + if(cen_snd)`, RAM/ROM run on cen_snd, and the 2A03 cores get
// I_CPU_CE = cpu_ce & cen_snd (a single master-clk pulse at the cpu rate).
// Functionally identical to dkong3_sound.
//----------------------------------------------------------------------------

module dkong3_sound_sync
(
   input        clk,
   input        cen_snd,
   input        I_SUB_NMIn,
   input        I_SUB_RESETn,
   input   [3:0]I_4E_Q,
   input   [7:0]I_MCPU_DO,

   input        I_DLCLK,
   input  [16:0]I_DLADDR,
   input   [7:0]I_DLDATA,
   input        I_DLWR,

   output signed [15:0]O_SAMPLE
);

// Data-bus / NMI capture (kept as registered stages; harmless in one domain).
reg [7:0]I_MCPU_DO_S1, I_MCPU_DO_REG;
always @(posedge clk) if (cen_snd) begin
   I_MCPU_DO_S1  <= I_MCPU_DO;
   I_MCPU_DO_REG <= I_MCPU_DO_S1;
end

reg I_SUB_NMIn_S1, I_SUB_NMIn_S2;
always @(posedge clk) if (cen_snd) begin
   I_SUB_NMIn_S1 <= I_SUB_NMIn;
   I_SUB_NMIn_S2 <= I_SUB_NMIn_S1;
end

//--------
// Clocks - 2A03 cadence (div_cpu) now advances on cen_snd
//--------
reg odd_or_even = 1;
localparam div_cpu_n = 5'd12;
reg [4:0] div_cpu = 5'd1;

wire cpu_ce = (div_cpu == div_cpu_n);
wire phi2   = (div_cpu > 4 && div_cpu < div_cpu_n);

always @(posedge clk) if (cen_snd) begin
   div_cpu <= cpu_ce || (div_cpu > div_cpu_n) ? 5'd1 : div_cpu + 5'd1;
   if (~I_SUB_RESETn)
      odd_or_even <= 1;
   else if (cpu_ce)
      odd_or_even <= ~odd_or_even;
end

// single master-clk cpu enable for the 2A03 cores
wire cpu_ce_g = cpu_ce & cen_snd;

//-----------------------------
// Sub CPU 1 @ 4M (Ricoh 2A03)
//-----------------------------
wire  [15:0]W_SUB1_ADDR;
wire   [7:0]W_SUB1_DBO;
wire        W_SUB1_RnW;
wire  [15:0]W_APU1_SAMPLE;

dkong3_sub_sync sub1
(
   .clk(clk),
   .I_SUB_NMIn(I_SUB_NMIn_S2),
   .I_SUB_RESETn(I_SUB_RESETn),
   .I_SUB_DBI(W_SUB1_DBI),
   .I_CPU_CE(cpu_ce_g),
   .I_PHI2(phi2),
   .I_ODD_OR_EVEN(odd_or_even),
   .O_SUB_ADDR(W_SUB1_ADDR),
   .O_SUB_DB0(W_SUB1_DBO),
   .O_SUB_RNW(W_SUB1_RnW),
   .O_SAMPLE(W_APU1_SAMPLE)
);

wire   [7:0]W_SUB1_DBI = W_SUB1ROM_DO | W_SUB1RAM_DO | W_SUB1INP0_DO | W_SUB1INP1_DO;

//----------------------
// ROM 5L for Sub CPU 1
//----------------------
wire  [7:0]W_SUB1ROM_DO;
wire       W_SUB1ROM_OEn = (W_SUB1_ADDR[15] == 1'b0);

SUB1_ROM_CE sub1rom(clk, cen_snd, W_SUB1_ADDR[12:0], 1'b0, W_SUB1ROM_OEn, W_SUB1ROM_DO,
                    I_DLCLK, I_DLADDR, I_DLDATA, I_DLWR);

//----------
// RAM @ 5K
//----------
reg   [7:0]W_SUB1RAM_DO;
wire  [7:0]W_RAM5K_DO;
wire       W_SUB1RAM_SEL = (W_SUB1_ADDR[15] == 1'b0)
                        & (W_SUB1_ADDR != 16'h4016)
                        & (W_SUB1_ADDR != 16'h4017);

dpram #(11,8) U_5K
(
   .clock_a   (clk),
   .address_a (W_SUB1_ADDR[10:0]),
   .data_a    (W_SUB1_DBO),
   .enable_a  (cen_snd),                 // I_CE was 1'b1
   .wren_a    (~W_SUB1_RnW & (W_SUB1_ADDR[15] == 1'b0)),
   .q_a       (W_RAM5K_DO),
   .clock_b   (clk)
);

always@(posedge clk) if (cen_snd)
   W_SUB1RAM_DO <= (W_SUB1RAM_SEL & W_SUB1_RnW) ? W_RAM5K_DO : 8'h00;

//----------------------------
// 74LS374 @ 4J - input port 0 for Sub CPU 1
//----------------------------
reg   [7:0]sub1inp0;
reg   q0_s1, q0_s2, q0_s3;
wire  [7:0]W_SUB1INP0_DO;

always@(posedge clk) if (cen_snd)
begin
   q0_s1 <= I_4E_Q[0];
   q0_s2 <= q0_s1;
   q0_s3 <= q0_s2;
   if (q0_s2 & ~q0_s3)
      sub1inp0 <= I_MCPU_DO_REG;
end

assign W_SUB1INP0_DO = (W_SUB1_ADDR == 16'h4016) & W_SUB1_RnW ? sub1inp0 : 8'h00;

//----------------------------
// 74LS374 @ 4H - input port 1 for Sub CPU 1
//----------------------------
reg   [7:0]sub1inp1;
reg   q1_s1, q1_s2, q1_s3;
wire  [7:0]W_SUB1INP1_DO;

always@(posedge clk) if (cen_snd)
begin
   q1_s1 <= I_4E_Q[1];
   q1_s2 <= q1_s1;
   q1_s3 <= q1_s2;
   if (q1_s2 & ~q1_s3)
      sub1inp1 <= I_MCPU_DO_REG;
end

assign W_SUB1INP1_DO = (W_SUB1_ADDR == 16'h4017) & W_SUB1_RnW ? sub1inp1 : 8'h00;

//-----------------------------
// Sub CPU 2 @ 5J (Ricoh 2A03)
//-----------------------------
wire  [15:0]W_SUB2_ADDR;
wire   [7:0]W_SUB2_DBO;
wire        W_SUB2_RnW;
wire  [15:0]W_APU2_SAMPLE;

dkong3_sub_sync sub2
(
   .clk(clk),
   .I_SUB_NMIn(I_SUB_NMIn_S2),
   .I_SUB_RESETn(I_SUB_RESETn),
   .I_SUB_DBI(W_SUB2_DBI),
   .I_CPU_CE(cpu_ce_g),
   .I_PHI2(phi2),
   .I_ODD_OR_EVEN(odd_or_even),
   .O_SUB_ADDR(W_SUB2_ADDR),
   .O_SUB_DB0(W_SUB2_DBO),
   .O_SUB_RNW(W_SUB2_RnW),
   .O_SAMPLE(W_APU2_SAMPLE)
);

wire   [7:0]W_SUB2_DBI = W_SUB2ROM_DO | W_SUB2RAM_DO | W_SUB2INP_DO;

//----------------------
// ROM 6M for Sub CPU 2
//----------------------
wire  [7:0]W_SUB2ROM_DO;
wire       W_SUB2ROM_OEn = (W_SUB2_ADDR[15] == 1'b0);

SUB2_ROM_CE sub2rom(clk, cen_snd, W_SUB2_ADDR[12:0], 1'b0, W_SUB2ROM_OEn, W_SUB2ROM_DO,
                    I_DLCLK, I_DLADDR, I_DLDATA, I_DLWR);

//------------------------
// RAM @ 6F for Sub CPU 2
//------------------------
reg   [7:0]W_SUB2RAM_DO;
wire  [7:0]W_RAM6F_DO;
wire       W_SUB2RAM_SEL = (W_SUB2_ADDR[15] == 1'b0)
                        & (W_SUB2_ADDR != 16'h4016)
                        & (W_SUB2_ADDR != 16'h4017);

dpram #(11,8) U_6F
(
   .clock_a   (clk),
   .address_a (W_SUB2_ADDR[10:0]),
   .data_a    (W_SUB2_DBO),
   .enable_a  (cen_snd),
   .wren_a    (~W_SUB2_RnW & (W_SUB2_ADDR[15] == 1'b0)),
   .q_a       (W_RAM6F_DO),
   .clock_b   (clk)
);

always@(posedge clk) if (cen_snd)
   W_SUB2RAM_DO <= (W_SUB2RAM_SEL & W_SUB2_RnW) ? W_RAM6F_DO : 8'h00;

//--------------------------
// 74LS374 @ 5F - input port for Sub CPU 2
//--------------------------
reg   [7:0]sub2inp;
reg   q2_s1, q2_s2, q2_s3;
wire  [7:0]W_SUB2INP_DO;

always@(posedge clk) if (cen_snd)
begin
   q2_s1 <= I_4E_Q[2];
   q2_s2 <= q2_s1;
   q2_s3 <= q2_s2;
   if (q2_s2 & ~q2_s3)
      sub2inp <= I_MCPU_DO_REG;
end

assign W_SUB2INP_DO = (W_SUB2_ADDR == 16'h4016) & W_SUB2_RnW ? sub2inp : 8'h00;

// Attenuate and mix
assign O_SAMPLE = {W_APU1_SAMPLE[15],W_APU1_SAMPLE[15:1]} +
                  {W_APU2_SAMPLE[15],W_APU2_SAMPLE[15:1]};

endmodule
