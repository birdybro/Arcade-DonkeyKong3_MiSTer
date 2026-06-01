# Clock-rework regression harness

Verification for the synchronous clock rework (see
`docs/clock-rework/ANALYSIS.md` §7). Two simulators:

- **verilator** (5.x, `--binary --timing`) — Verilog/SystemVerilog modules.
- **ghdl** (mcode, `-a` then `-r`) — the VHDL CPU cores (T80, T65) + dpram.

## Run

```sh
cd tb
make regress        # build + run everything, print overall PASS/FAIL
make verilate       # all verilator tests
make ghdl           # all ghdl tests
make <name>         # one test, e.g.  make hv_count_diff   /   make t80_smoke
make clean
```

`make regress` is the gate: run it after **every** conversion step. A green run
means every converted module still matches the original.

## Layout

```
tb/
  common/   sim_pkg.svh   scoreboard macros (SB_CHECK / SB_REPORT)
  diff/     <mod>_diff_tb.sv   differential equivalence: golden vs reworked
  unit/     self-contained unit checks (clk_en rate/phase, RAM RDW, …)
  ghdl/     VHDL testbenches for the CPU cores
  golden/   end-to-end trace capture/compare (see "Golden trace" below)
  build/    generated (gitignored)
```

## The method: differential equivalence

The rework is a **behavior-preserving refactor** (timing representation changes,
logic does not). So the primary check is: instantiate the **golden** (original)
module and the **reworked** module, drive identical stimulus, and assert their
outputs match. The original module *is* the golden reference — run live, no
stored trace to maintain.

`diff/hv_count_diff_tb.sv` is the template. Today (Stage 0) both instances are
the original module on the same clock, so it passes trivially and proves the
harness. **To convert it for a reworked module (Stage 2+):**

1. Instantiate the reworked module as `u_dut` (e.g. `dkong3_hv_count_sync`).
2. Add the 98.304 MHz `clk` + the relevant CEN(s) (e.g. `cen_24m_p`) from the
   same time base as the golden's `clk_24m`, and clock `u_dut` on `clk`.
3. Move the `SB_CHECK` block into `if (cen_24m_p)` so golden (sampled on its
   24.576 edge) and DUT (sampled on the aligned CEN tick) are compared at the
   same logical instant.

The scoreboard and stimulus are reused unchanged. Add the test to the registry
in `Makefile` (`define_vtest`).

## Mixed-language constraint

verilator is Verilog/SV-only; ghdl is VHDL-only. Modules that **mix** them —
`dkong3_main` (VHDL Z80), `dkong3_sub` (VHDL T65), `dkong3_top` (both) — cannot
be simulated whole by either free tool. The clocking changes there are in the
**Verilog glue**, not the CPU cores (which are unchanged). So for those modules
the diff TB replaces the VHDL CPU with a small Verilog **bus-replay stub** that
drives the same address/data/control sequence into the golden and reworked glue,
and we compare the RAM/strobe/arbitration outputs. The CPU cores themselves are
covered by the ghdl smoke/equivalence TBs in `ghdl/`.

## Golden trace (end-to-end)

A whole-core trace (video signature + audio + Z80 bus over a scripted scenario)
is the catch-all for integration bugs. It needs game ROMs (not in the repo) or a
**synthetic test ROM** fed through the download interface, plus mixed-language
sim. Because of the mixed-language constraint above, the end-to-end trace is
built once an integration point exists (Stage 1+), driven by a committed
synthetic test ROM so it is reproducible without the real game ROMs. Until then,
the per-module differential tests are the regression backbone.

## Adding a test

- Verilog/SV differential: add `diff/<mod>_diff_tb.sv` (copy the hv_count
  template) and one `define_vtest` line in `Makefile`.
- VHDL: add `ghdl/<name>_tb.vhd` and a target mirroring `t80_smoke`.
