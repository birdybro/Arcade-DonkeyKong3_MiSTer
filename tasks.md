# Clock Rework — Task List

Goal: convert the entire DK3 core to a single synchronous clock domain
(98.304 MHz master, every flop `posedge clk` + clock-enable). Full detail in
[docs/clock-rework/ANALYSIS.md](docs/clock-rework/ANALYSIS.md).

Rules of engagement:
- Every step ends GREEN in **both** Quartus (compiles + timing closes) and
  `make regress` (differential + golden-trace TBs) before the next begins.
- No `negedge`, no register/ripple/counter-bit used as a clock, no gated clock.
- SDC band-aids are deleted as their reason disappears; multicycle added per phase map.
- Follow `docs/hdl-coding-guidelines/` (clocking §11, SDC §40, verification §41,
  memory §30, anti-patterns §90).

Legend: `[ ]` todo · `[~]` in progress · `[x]` done

---

## Stage 0 — Verification harness & baseline (no RTL change)  ✅ DONE

- [x] 0.1 `tb/` layout (`common/`, `diff/`, `unit/`, `golden/`, `ghdl/`, `Makefile`).
- [x] 0.2 `make verilate` / `make ghdl` / `make regress` targets; verilator 5.048
      (`--binary --timing`) and ghdl 6.0 (mcode, `-a`/`-r`) confirmed on real core
      RTL. `make regress` → ALL PASS in <3 s.
- [x] 0.3 Scoreboard helpers in `tb/common/sim_pkg.svh` (`SB_CHECK`/`SB_REPORT`).
- [x] 0.5 Differential-harness template `tb/diff/hv_count_diff_tb.sv` (golden vs
      reworked, scoreboard at CEN ticks). Stage-0 smoke = golden-vs-golden (11.7M
      checks, 0 mismatches); Stage 2 swaps in the `_sync` DUT (documented in TB +
      `tb/README.md`). ghdl `t80_smoke` confirms the VHDL CPU flow.
- [~] 0.4 Golden trace: **method decided + documented** (`tb/README.md`) — the
      per-module differential test is the regression backbone (the original module
      *is* the live golden, no stored trace). The whole-core end-to-end trace
      needs a committed synthetic test ROM + mixed-language sim, so it is
      **deferred to Stage 1+** when an integration point exists. Mixed-language
      constraint (verilator=Verilog, ghdl=VHDL; CPU-adjacent glue uses a bus-replay
      stub) is documented.

## Stage 1 — Clock foundation

- [ ] 1.1 Regenerate `rtl/pll` → single output `clk = 98.304 MHz`; verify lock (LED_USER during bring-up).
- [ ] 1.2 New `rtl/clk_en.v`: phase counter + decoded strobes (`cen_24m_p/n`, `cen_12m_p/n`, `cen_6m`, `cen_pix`, decoded `cen_o_clk`/`cen_v_clk`) + fractional CENs (`cen_cpu` = 4.000 MHz exact via 125/3072 accumulator; `cen_snd` = 21.477272 MHz).
- [ ] 1.3 `tb/unit/clk_en`: assert each CEN's average rate + phase alignment.
- [ ] 1.4 Top: `clk_sys=clk`, `CLK_VIDEO=clk`, `CE_PIXEL=cen_pix`; instantiate `clk_en`; bridge legacy derived nets from new CENs so the core still runs.
- [ ] 1.5 Single async-assert/sync-release reset synchronizer in the `clk` domain.
- [ ] 1.6 Build + boot/video golden trace unchanged.

## Stage 2 — H/V counter & video timing

- [ ] 2.1 `dkong3_hv_count.v`: one counter on `cen_24m_p`; expose H/V counts + decoded `cen_o_clk`/`cen_v_clk`; remove `posedge O_CLK`/`posedge V_CLK`.
- [ ] 2.2 `tb/diff/hv_count_diff`: H/V counts, blank/sync edges match original bit-for-bit.
- [ ] 2.3 `dkong3_video.v` wiring to master domain.
- [ ] 2.4 Build + golden video trace match; `make regress` green.

## Stage 3 — VRAM, OBJ, colour palette

- [ ] 3.1 `dkong3_vram.v`: `negedge I_CLK_24M`, `posedge CLK_4PN`, `posedge I_H_CNT[2/6]` → `posedge clk + cen_*`; RAM to Intel registered-read template (`30-...md` §3, pick RDW mode explicitly).
- [ ] 3.2 `dkong3_obj.v`: every counter/register clock (`W_5F2_Q[*]`, `CLK_3E/4L/5L`, `I_H_CNT[*]`, both edges of 24M/12M) → decoded CENs in master domain.
- [ ] 3.3 `dkong3_col_pal.v`: `I_CLK_6M`/`W_1B2C_RST` → `cen_6m` + sync reset.
- [ ] 3.4 `tb/diff/` for vram, obj, col_pal (old vs new).
- [ ] 3.5 Build + golden video trace match; `make regress` green.

## Stage 4 — Main CPU subsystem

- [ ] 4.1 `dkong3_main.v`: Z80 `CLK=clk, CEN=cen_cpu` (T80as already supports CEN); work RAM 7F/7H to template (`posedge clk`, not `~I_CLK_12M`).
- [ ] 4.2 `dkong3_adec.v`: `posedge/negedge I_CLK` → `cen_cpu`/`cen_cpu_n`; NMI flop → synchronous VBLANK edge-detect gated by the 259 latch (remove `posedge W_VBLK or negedge W_3E_Q[4]`).
- [ ] 4.3 `dkong3_dma.v`: `~I_MCPU_CLK` → `posedge clk + cen_cpu_n`.
- [ ] 4.4 `tb/diff/` for adec, main (+ Z80 bus equivalence), dma.
- [ ] 4.5 Build + gameplay golden trace (Z80 bus + video) match; `make regress` green.

## Stage 5 — Sound subsystem

- [ ] 5.1 `dkong3_sound.v`: `div_cpu` chain + all RAM/latch flops from `posedge I_SUBCLK` → `posedge clk + cen_snd`; derive `cpu_ce/phi2/odd_or_even` on `cen_snd`.
- [ ] 5.2 `dkong3_sub.v` / `apu.sv` driven by `clk` + the sound CENs (logic unchanged).
- [ ] 5.3 `tb/diff/sound_diff` against the original `clk_sub` sound subsystem (audio sample equivalence).
- [ ] 5.4 Build + audio golden trace match; `make regress` green.

## Stage 6 — SDC cleanup & timing closure

- [ ] 6.1 Delete all custom SDC lines (the `set_max_delay $sync_max` block, the reset-sync `set_false_path`s). Keep `derive_pll_clocks` + `derive_clock_uncertainty`.
- [ ] 6.2 Add multicycle constraints per the §6 phase map (24m=4/3, 12m=8/7, half-period=2/1, cpu/snd ≥24) using register groups.
- [ ] 6.3 `check_timing` clean (no unconstrained paths, no fabric-derived clocks); all corners (setup/hold/recovery/removal/min-pulse) ≥ 0.
- [ ] 6.4 Confirm no `negedge`/ripple/register/gated clock remains (grep + Quartus clock report shows only `clk`).

## Stage 7 — Final verification & bring-up

- [ ] 7.1 Full `make regress` green (all diff + unit + golden).
- [ ] 7.2 Quartus: synthesis warnings reviewed (no latch/removed/no-driver surprises); RAMs land on M10K/MLAB as intended (Fitter report).
- [ ] 7.3 On-hardware bring-up: boot, gameplay, audio, no flicker/reset over extended play.
- [ ] 7.4 Update CLAUDE.md / memory with the final clock map.

---

## Out of scope (tabled)

- Pause / hi-score features — revisit **after** the synchronous rework lands.
