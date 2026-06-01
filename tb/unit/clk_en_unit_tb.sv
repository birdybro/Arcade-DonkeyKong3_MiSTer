// tb/unit/clk_en_unit_tb.sv
// Unit test for rtl/clk_en.v: validates each clock-enable's average rate and
// the phase relationships the rest of the rework relies on.
//
// Window N = 3*2^20 = 3,145,728 cycles is a multiple of every enable's period
// (4, 8, the CPU mod-3072, and the sound 2^20) so the expected counts are exact.
`timescale 1ns/1ps

module clk_en_unit_tb;
  logic clk = 0, rst;
  logic cen_24m_p, cen_24m_n, cen_12m_p, cen_12m_n, cen_cpu, cen_snd;

  always #5 clk = ~clk;  // 100 MHz-ish; period irrelevant to a count/phase check

  clk_en dut (
    .clk(clk), .rst(rst),
    .cen_24m_p(cen_24m_p), .cen_24m_n(cen_24m_n),
    .cen_12m_p(cen_12m_p), .cen_12m_n(cen_12m_n),
    .cen_cpu(cen_cpu), .cen_snd(cen_snd)
  );

  // counts
  longint n_24p=0, n_24n=0, n_12p=0, n_12n=0, n_cpu=0, n_snd=0, cyc=0;
  // gap trackers
  int g_24p=0, g_24n=0, g_12p=0;
  bit seen_24p=0, seen_24n=0, seen_12p=0;
  int errors=0;

  task automatic chk(input bit cond, input string msg);
    if (!cond) begin errors++; if (errors<=20) $display("  FAIL: %s @cyc %0d", msg, cyc); end
  endtask

  localparam longint N = 3*1048576;

  always @(posedge clk) if (!rst) begin
    cyc++;
    // counts
    n_24p += cen_24m_p; n_24n += cen_24m_n;
    n_12p += cen_12m_p; n_12n += cen_12m_n;
    n_cpu += cen_cpu;   n_snd += cen_snd;

    // --- continuous phase invariants ---
    // 24m posedge and negedge never coincide
    chk(!(cen_24m_p && cen_24m_n), "24m_p and 24m_n coincide");
    // 12m strobes land on 24m-posedge ticks (O_CLK toggles on clk_sys posedges)
    if (cen_12m_p) chk(cen_24m_p, "12m_p without 24m_p");
    if (cen_12m_n) chk(cen_24m_p, "12m_n without 24m_p");

    // --- exact gaps for the integer strobes ---
    g_24p++; g_24n++; g_12p++;
    if (cen_24m_p) begin if (seen_24p) chk(g_24p==4, "24m_p gap!=4"); g_24p=0; seen_24p=1; end
    if (cen_24m_n) begin if (seen_24n) chk(g_24n==4, "24m_n gap!=4"); g_24n=0; seen_24n=1; end
    if (cen_12m_p) begin if (seen_12p) chk(g_12p==8, "12m_p gap!=8"); g_12p=0; seen_12p=1; end

    if (cyc == N) begin
      $display("counts over %0d cyc: 24p=%0d 24n=%0d 12p=%0d 12n=%0d cpu=%0d snd=%0d",
               N, n_24p, n_24n, n_12p, n_12n, n_cpu, n_snd);
      // expected exact (within +/-2 for boundary)
      chk(n_24p inside {[N/4-2 : N/4+2]}, "24m_p count");   // 786432
      chk(n_24n inside {[N/4-2 : N/4+2]}, "24m_n count");
      chk(n_12p inside {[N/8-2 : N/8+2]}, "12m_p count");   // 393216
      chk(n_12n inside {[N/8-2 : N/8+2]}, "12m_n count");
      chk(n_cpu inside {[128000-2 : 128000+2]}, "cpu count");   // exact 4.000 MHz
      chk(n_snd inside {[687282-2 : 687282+2]}, "snd count");   // ~21.4773 MHz
      if (errors==0) begin $display("PASS: clk_en_unit"); $finish; end
      else $fatal(1, "FAIL: clk_en_unit (%0d errors)", errors);
    end
  end

  initial begin
    rst = 1; repeat (8) @(posedge clk); rst = 0;
    #500_000_000; $fatal(1, "TIMEOUT");
  end
endmodule
