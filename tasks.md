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

## Stage 3 — VRAM, OBJ, colour palette  (the coupled video group)

> Infrastructure ready: `hv_count_sync` exposes `cen_o_clk_p/n` (12.288 edges,
> H-aligned) and `cen_hcnt0_p` (=CLK_4PN), `cen_hcnt2_p`, `cen_hcnt6_p`. Consumers
> take these clean enables (no cross-module edge-detect/skew). `cen_24m_n` (from
> clk_en) covers negedge-24M logic.

- [x] 3.0 (de-risked) Shared `dpram`-based RAMs need **NO rewrite**: `dpram` maps
      `enable_a → altsyncram clocken0` (the dedicated clock-enable) with async read.
      A consumer converts by driving `clock=clk` and `enable = orig_CE & cen` —
      e.g. vram RAM: `clock_a=clk`, `enable_a = ~W_vram_CS & cen_o_clk_p`. The
      inferred-RAM ROMs (dkong3_roms.v `posedge CLK0; DO<=core[AD]`) clock on `clk`;
      add `if(cen)` on the read register (or accept faster-but-stable read sampled
      at cen ticks). Compare in diff TBs only at cen ticks.
- [x] 3.0b `tb/common/dpram.sv`: behavioral altsyncram model (clocken-gated,
      async read, new-data RDW) — REQUIRED for every memory-containing diff test
      (the real dpram is Altera IP, unsimulatable by verilator/ghdl). Done.
- [x] 3.1 `dkong3_vram_sync.v`: RAM on `cen_o_clk_p` (dpram directly, clock=clk,
      enable=`~W_vram_CS & cen_o_clk_p`); COL PROM / VID ROM on `cen_o_clk_n`
      (new `COL_PROM_256_4_CE`/`VID_ROM_CE`/`DLROM_CE` in dkong3_roms.v);
      negedge-24M COL latch → `cen_24m_n`; reg_4P/4N shift regs → `cen_hcnt0_p`;
      W_VRAMBUSY → `cen_hcnt2_p` capture + `cen_hcnt9_n` clear; W_ESBLK →
      `cen_hcnt6_p` + `cen_hcnt9_n`. Added `cen_hcnt9_n` (negedge H_CNT[9]) to
      hv_count_sync.
      ✅ CROSS-MODULE TIMING RESOLVED (no combined module / no H_CNT_nxt needed):
      each strobe edge only toggles H_CNT bits *below* the ones its consumer
      reads (posedge H_CNT[2] → bits[3:0] roll, but VRAMBUSY reads [9],[7:4]
      which don't change; posedge O_CLK → only bit0 toggles, RAM/PROM read
      [9:1] unchanged). So sampling the *registered* I_H_CNT on the strobe tick
      already equals the original's post-edge value. The one true coincidence
      (reg_4P's `posedge CLK_4PN` ≡ VID_ROM's `negedge O_CLK`) is preserved
      because both sides update on the same master edge with NBA, so reg_4P sees
      the pre-edge ROM output exactly as the original did. Verified, not eyeballed.
- [x] 3.1b `tb/diff/vram_diff`: golden hv_count+vram vs sync hv_count_sync+vram_sync,
      shared ROM download + VRAM write sweep, LFSR-randomized CPU/scan/flip/offset
      stimulus, compare O_DB/O_COL/O_VID/O_VRAMBUSYn/O_ESBLKn at quiet phase.
      **2,000,005 checks, 0 mismatches.** `make regress` ALL PASS.
- [x] 3.2 `dkong3_obj_sync.v` (largest): every fabric clock → decoded enable.
      negedge-24M flops (W_5B/W_5F2_Q/CLK_4L/CLK_3E/W_HD) → `cen_24m_n`; 12M
      flops (W_6N/W_6M/W_7H/W_6K/reg_8CD/8EF/OBJ_ROM) → `cen_o_clk_p/n`;
      `negedge H_CNT[9]` (W_VFC_CNT) → `cen_hcnt9_n`; gated clock `CLK_5L`
      reproduced as a combinational level (7M-RAM write-enable) + `cen_o_clk_n`
      posedge strobe (W_5L_Q counter); `CLK_4L`/`CLK_3E` register-clocks →
      next-value rising-edge strobes; async resets (`RST_4L`, W_5L_RST, U_8N)
      → H_CNT[9]-level resets. Register-as-clock captures whose data updates on
      the same negedge-24M edge (W_8H_Q←W_5F2_Q[0], W_6J_Q←W_5F2_Q[2],
      U_8N, W_3E_Q) use a one-clk-delayed strobe to reproduce the original's
      post-edge (clk-to-Q-delayed) data capture. New `OBJ_ROM_CE`/`DLROM_CE`.
      O_CLK is taken as a *level* (I_OCLK) for the gated-clock decodes.
- [x] 3.2b `tb/diff/obj_diff`: golden hv_count+obj vs sync, DMA-filled OBJ RAM +
      loaded OBJ ROMs, free-running engine over multiple frames incl.
      flip-screen/offsets/2PSL/CMPBLK variations. **6,800,000 checks, 0 mismatches.**
- [ ] 3.3 `dkong3_col_pal_sync.v`: `I_CLK_6M`(=H_CNT[0]) → `cen_hcnt0_p`; the
      self-resetting latch `W_1B2C_RST = I_CMPBLKn | W_1B2C_Q[0]` → synchronous
      equivalent. + `tb/diff/col_pal_diff`.
- [ ] 3.4 `dkong3_video_sync` wires the group; integrate into `dkong3_top`.
- [ ] 3.5 Build + video golden trace match; `make regress` green.

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
