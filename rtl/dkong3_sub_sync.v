//----------------------------------------------------------------------------
// Donkey Kong 3 Arcade - Sub CPU 2A03 (synchronous rework of dkong3_sub)
//
// Identical to dkong3_sub except the core clock is the single master `clk`
// (98.304 MHz) instead of I_SUBCLK. The T65 and APU are already clock-enable
// designs (I_CPU_CE / I_PHI2); the parent passes I_CPU_CE = cpu_ce & cen_snd
// (a single master-clk pulse at the 2A03 cpu rate) so every rate-critical
// signal fires on the same cpu cycles as before. The APU's PHI2-edge detector
// simply oversamples at the faster clk, which is harmless. See ANALYSIS.md.
//----------------------------------------------------------------------------

module dkong3_sub_sync
(
   input        clk,
   input        I_SUB_RESETn,
   input        I_SUB_NMIn,
   input   [7:0]I_SUB_DBI,
   input        I_CPU_CE,
   input        I_PHI2,
   input        I_ODD_OR_EVEN,

   output [15:0]O_SUB_ADDR,
   output  [7:0]O_SUB_DB0,
   output       O_SUB_RNW,

   output signed [15:0]O_SAMPLE
);

wire [7:0] cpu_dout;
wire [15:0] cpu_addr;
wire cpu_rnw;
wire apu_irq;

T65 cpu(
   .mode   (2'b00),
   .BCD_en (1'b0),

   .res_n  (I_SUB_RESETn),
   .clk    (clk),
   .enable (I_CPU_CE),
   .rdy    (1'b1),

   .IRQ_n  (~apu_irq),
   .NMI_n  (I_SUB_NMIn),
   .R_W_n  (cpu_rnw),

   .A      (cpu_addr),
   .DI     (cpu_rnw ? W_CPU_DBUS : cpu_dout),
   .DO     (cpu_dout)
);

assign O_SUB_ADDR = cpu_addr;
assign O_SUB_DB0  = cpu_dout;
assign O_SUB_RNW  = cpu_rnw;

wire   [7:0]W_CPU_DBUS = (cpu_addr == 16'h4015 & cpu_rnw) ? apu_dout : I_SUB_DBI;

//-----
// APU
//-----
wire apu_cs = cpu_addr >= 'h4000 && cpu_addr < 'h4018;
wire [7:0]apu_dout;
wire [15:0] sample_apu;

APU apu (
   .MMC5           (1'b0),
   .clk            (clk),
   .PHI2           (I_PHI2),
   .CS             (apu_cs),
   .PAL            (1'b0),
   .ce             (I_CPU_CE),
   .reset          (~I_SUB_RESETn),
   .cold_reset     (1'b0),
   .ADDR           (cpu_addr[4:0]),
   .RW             (cpu_rnw),
   .DIN            (cpu_dout),
   .DOUT           (apu_dout),
   .audio_channels (5'b11111),
   .Sample         (sample_apu),
   .DmaReq         (),
   .DmaAck         (1'b0),
   .DmaAddr        (),
   .DmaData        (8'h00),
   .get_or_put     (I_ODD_OR_EVEN),
   .IRQ            (apu_irq),
   .get_ce         (),
   .put_ce         ()
);

wire [15:0] sample_inverted = 16'hFFFF - sample_apu;

assign O_SAMPLE = {~sample_inverted[15],sample_inverted[14:0]};

endmodule
