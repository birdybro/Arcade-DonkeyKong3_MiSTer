/***************************************************************
 Z80_IP INTERFACE < T80asd >
***************************************************************/
module Z80IP(

ADRS,
DINP,
DOUT,
BUSWO,
RESET_N,
INT_N,
NMI_N,
WAIT_N,
M1_N,
MREQ_N,
IORQ_N,
RD_N,
WR_N,
RFSH_N,
HALT_N,
CLK2X,
CLK

);

// I/O assign
output [15:0] ADRS;
input  [7:0] DINP;
output [7:0] DOUT;
input  RESET_N,INT_N,NMI_N,WAIT_N,CLK2X,CLK;
output M1_N,MREQ_N,IORQ_N,RD_N,WR_N,RFSH_N,HALT_N,BUSWO;

// Z80IP interface
T80as z80core (

.RESET_n(RESET_N),
.CLK_n(CLK),
.WAIT_n(WAIT_N),
.INT_n(INT_N),
.NMI_n(NMI_N),
.BUSRQ_n(1'b1),
.M1_n(M1_N),
.MREQ_n(MREQ_N),
.IORQ_n(IORQ_N),
.RD_n(RD_N),
.WR_n(WR_N),
.RFSH_n(RFSH_N),
.HALT_n(HALT_N),
.BUSAK_n(),
.A(ADRS),
.DI(DINP),
.DO(DOUT),
.DOE(BUSWO)

);


endmodule

/***************************************************************
 Z80_IP INTERFACE < T80asd > with clock-enable (clock-rework)
 Same as Z80IP but the Z80 runs on the single master clock CLK
 gated by CEN (= cen_cpu, the 4 MHz NCO enable).
***************************************************************/
module Z80IP_CEN(

ADRS,
DINP,
DOUT,
BUSWO,
RESET_N,
CEN,
INT_N,
NMI_N,
WAIT_N,
M1_N,
MREQ_N,
IORQ_N,
RD_N,
WR_N,
RFSH_N,
HALT_N,
CLK2X,
CLK

);

output [15:0] ADRS;
input  [7:0] DINP;
output [7:0] DOUT;
input  RESET_N,CEN,INT_N,NMI_N,WAIT_N,CLK2X,CLK;
output M1_N,MREQ_N,IORQ_N,RD_N,WR_N,RFSH_N,HALT_N,BUSWO;

T80as z80core (

.RESET_n(RESET_N),
.CLK_n(CLK),
.CEN_i(CEN),
.WAIT_n(WAIT_N),
.INT_n(INT_N),
.NMI_n(NMI_N),
.BUSRQ_n(1'b1),
.M1_n(M1_N),
.MREQ_n(MREQ_N),
.IORQ_n(IORQ_N),
.RD_n(RD_N),
.WR_n(WR_N),
.RFSH_n(RFSH_N),
.HALT_n(HALT_N),
.BUSAK_n(),
.A(ADRS),
.DI(DINP),
.DO(DOUT),
.DOE(BUSWO)

);

endmodule
