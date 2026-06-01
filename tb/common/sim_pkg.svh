// tb/common/sim_pkg.svh
// Shared simulation helpers for the clock-rework testbenches.
// Included (not imported) so it works under Verilator --binary and is
// timescale-agnostic. See docs/clock-rework/ANALYSIS.md §7.
`ifndef SIM_PKG_SVH
`define SIM_PKG_SVH

// ---------------------------------------------------------------------------
// Scoreboard: a self-contained mismatch counter + reporter. A differential
// testbench calls `sb_check` every comparison point; `sb_report` ends the sim.
// Usage: declare `int sb_errors = 0, sb_checks = 0;` in the TB, then call the
// macros below. We use macros (not a class) so signal names resolve in the TB
// scope and Verilator stays happy.
// ---------------------------------------------------------------------------

// Compare two values; on mismatch, print context and bump the error count.
// NAME is a string literal, GOLD/DUT are the two values to compare.
`define SB_CHECK(NAME, GOLD, DUT)                                              \
  begin                                                                        \
    sb_checks++;                                                               \
    if ((GOLD) !== (DUT)) begin                                                \
      sb_errors++;                                                             \
      if (sb_errors <= 20)                                                     \
        $display("  MISMATCH @%0t %-12s gold=%h dut=%h", $time, NAME, (GOLD), (DUT)); \
    end                                                                        \
  end

// Final verdict. Prints PASS/FAIL and $finish/$fatal accordingly.
`define SB_REPORT(LABEL)                                                       \
  begin                                                                        \
    $display("[%s] %0d checks, %0d mismatches", LABEL, sb_checks, sb_errors);  \
    if (sb_errors == 0) begin $display("PASS: %s", LABEL); $finish; end         \
    else                 $fatal(1, "FAIL: %s (%0d mismatches)", LABEL, sb_errors); \
  end

`endif
