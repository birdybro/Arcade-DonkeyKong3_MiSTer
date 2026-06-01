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

## Stage 1 — Clock foundation  ✅ DONE

- [x] 1.1 PLL regenerated (by user) with 4 outputs: `outclk_0`=98.304 (master
      `clk`), `outclk_1`=24.576, `outclk_2`=21.477, `outclk_3`=4.0. The legacy
      three are KEPT (phase-locked to `clk`) for the staged migration; trimmed to
      single 98.304 in Stage 6.
- [x] 1.2 `rtl/clk_en.v`: phase strobes `cen_24m_p/n` (÷4 @ phase 0/2),
      `cen_12m_p/n` (÷8 @ phase 0/4); fractional `cen_cpu` = 4.000 MHz exact
      (125/3072 NCO); `cen_snd` ≈ 21.4773 MHz (229094/2^20 NCO). (`cen_6m`/`cen_pix`/
      decoded `cen_o_clk`/`cen_v_clk` added in Stage 2 from the H counter.)
- [x] 1.3 `tb/unit/clk_en_unit`: exact rate counts + phase invariants (gaps,
      mutual exclusion, 12m⊂24m). PASS.
- [x] 1.4 Top: `clk`=outclk_0 wired; `clk_en` instantiated. (CLK_VIDEO/CE_PIXEL
      stay on legacy `clk_sys` until video converts in Stage 2; CENs unused until
      consumed per-subsystem.)
- [x] 1.5 `clk`-domain async-assert / sync-release reset (`clk_rst`).
- [x] 1.6 Quartus: 0 errors, timing met (setup +0.601, hold +0.206, 4-output PLL
      OK). `make regress` ALL PASS. Core still boots on legacy clocks (unchanged).

## Stage 2 — H/V counter & video timing

> INTEGRATION NOTE (found during 2.1): `hv_count`'s `O_CLK` (12.288 MHz) is
> consumed **as a clock** by vram, obj, adec, and the main RAMs, so `hv_count`
> cannot be *integrated* alone — it integrates with that whole 24.576/12.288
> group. Per-module `_sync` conversions are written + diff-verified **in
> isolation** (cleanly stageable), then the coupled group is swapped into
> `dkong3_top` atomically. Revised unit grouping in Stage 3.

- [x] 2.1 `rtl/dkong3_hv_count_sync.v`: one counter on `cen_24m_p`; ripple
      `O_CLK`/`V_CLK` clocks → decoded enables (`cen_o_clk_p/n`, internal vclk
      edge). Bit-identical behavior.
- [x] 2.2 `tb/diff/hv_count_diff` flipped to golden(24.576) vs sync(clk+cen):
      13.5M checks, 0 mismatches (incl. flip-screen + H/V offsets). PASS.
- [ ] 2.3 Integrate with the video/main group (see Stage 3) — deferred to group swap.
- [ ] 2.4 Build + golden video trace match; `make regress` green (at group integration).

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
