# Synchronous Clock Rework — Analysis

> Branch: `clock-rework`
> Goal: convert the **entire** Donkey Kong 3 core to a single, fully-synchronous
> clock domain — one master clock, every flop on `posedge clk`, every "clock"
> that exists today (PLL outputs, ripple-counter taps, register outputs, gated
> nets) replaced by a **clock-enable (CEN)**.
> Status: design analysis (no RTL changed yet).

This document follows the project HDL guidelines in `docs/hdl-coding-guidelines/`
(esp. `11-clocking-resets-and-cyclone-v-clock-networks.md`,
`40-timing-closure-and-sdc.md`, `41-quartus-reports-and-verification.md`,
`30-memory-inference-cyclone-v.md`, `90-anti-patterns.md`) and the framework
reference `docs/mister-framework-reference/12-clocks-resets-plls.md`. Claim
labels `[C]` contract / `[V]` convention / `[I]` inference are used where useful.

---

## 1. Why (the problem)

The core today runs on **three asynchronous PLL outputs** plus a large number of
**fabric-derived and register-output clocks**. This violates the single most
load-bearing rule in the guidelines:

> [C] "Every flop in synthesizable RTL is clocked from a clock network … not
> from combinational fabric logic." … "do not feed a divider register's output
> to a downstream flop's clock pin." — `11-clocking-...md` §2, anti-pattern #9.

### 1.1 Current clock domains (3 async PLL outputs)

| Net | Freq | Source | Used by |
|---|---|---|---|
| `clk_sys` | 24.576 MHz | `pll.outclk_0` | hv_count, video, hps_io, download |
| `clk_sub` | 21.477 MHz | `pll.outclk_1` | sound (2× 2A03 + APUs) |
| `clk_main` | 4.000 MHz | `pll.outclk_2` | Z80, adec, sprite DMA |

These ratios are non-integer (24.576 / 4 = 6.144; 24.576 / 21.477 ≈ 1.144), so
the domains are genuinely asynchronous and require CDC synchronizers and a pile
of `set_max_delay`/`set_false_path` band-aids in the SDC. The pause work (now
tabled) repeatedly hit instability that traced back to this async structure.

### 1.2 Fabric-derived / ripple / register-as-clock nets (anti-pattern #9)

Inventory of every "clock" that is **not** a PLL output (grep of `rtl/`):

| File | Construct | What it really is |
|---|---|---|
| `dkong3_hv_count.v:62` | `assign O_CLK = H_CNT_r[0]` then `always@(posedge O_CLK)` | counter LSB used as a 12.288 MHz clock |
| `dkong3_hv_count.v:81,90` | `always@(posedge V_CLK ...)` | `V_CLK` decoded from H_CNT used as the V-counter clock |
| `dkong3_vram.v:90` | `always@(negedge I_CLK_24M)` | opposite edge of clk_sys |
| `dkong3_vram.v:127,150` | `always@(posedge CLK_4PN)` (`CLK_4PN = I_H_CNT[0]`) | counter bit as a shift-register clock |
| `dkong3_vram.v:183,200` | `always@(posedge I_H_CNT[2/6] or negedge I_H_CNT[9])` | counter bits as clock **and** async reset |
| `dkong3_obj.v` (many) | `posedge/negedge I_CLK_24M`, `negedge I_CLK_12M`, `posedge I_H_CNT[6]`, `negedge I_H_CNT[9]`, `posedge W_5F2_Q[0/2]`, `posedge CLK_4L`, `posedge CLK_5L`, `posedge CLK_3E` | counter bits and **register outputs** used as clocks |
| `dkong3_adec.v:57,66` | `posedge/negedge I_CLK` (clk_main) | opposite edge of clk_main |
| `dkong3_adec.v:79` | `always@(posedge W_VBLK or negedge W_3E_Q[4])` | derived VBLANK as clock; **a 259-latch bit as async reset** |
| `dkong3_col_pal.v:49` | `posedge I_CLK_6M or negedge W_1B2C_RST` | another derived clock + derived reset |
| `dkong3_main.v:182,205` etc. | RAM `I_CLK(~I_CLK_12M)` | negedge-clocked RAM (also violates `30-memory-...md` template) |
| `dkong3_dma.v:36` | `I_CLK(~I_MCPU_CLK)` | negedge-clocked DMA |
| `dkong3_logic.v:40` | generic `posedge CLK or negedge RST` (JK FF) | clocked by whatever derived net is passed in |

These are exactly the "registers incorrectly used as clocks" that make the fit
seed-dependent (the `V_CLK was determined to be a clock without an associated
clock assignment` warnings) and unconstrainable — TimeQuest cannot reason about
them, so those paths are effectively untimed.

---

## 2. Target architecture (the fix)

**One PLL output, one clock domain, everything CEN-gated.**

### 2.1 Master clock = 98.304 MHz

- `pll` is regenerated to a single output `clk = 98.304 MHz`. This is **4 ×
  24.576 MHz** (the video clock), chosen so that:
  - the 24.576 MHz pixel domain is a clean ÷4 phase, and
  - **both edges** of the current 24.576 and 12.288 MHz clocks map to distinct
    `posedge clk` phases (see §2.3) — this is what lets every `negedge` and
    every ripple/register clock become a plain enable. A lower master (49.152,
    24.576) cannot represent the 24.576 MHz *negedge* as a posedge phase.
- 98.304 MHz is well inside the Cyclone V `5CSEBA6U23I7` fabric/PLL envelope.
  The logic does **not** have to close at 10.17 ns single-cycle — see §6 (the
  CEN-gated paths get their real settling window via multicycle constraints).
- `[C]` framework: the core owns exactly one `pll` from `CLK_50M`; regenerate it
  per `mister-framework-reference/12-clocks-resets-plls.md`. The PLL is sensitive
  (note the prior "Revert PLL to original" commit) — regenerate carefully and
  verify lock.

`CLK_VIDEO = clk` (98.304), `CE_PIXEL = cen_pix`. The framework video chain is
CE-based, so a fast `CLK_VIDEO` with a gated `CE_PIXEL` is the normal mode
(`12-clocks-...md` §2, `CE_PIXEL` contract `[C]`).

### 2.2 Clock-enable generator (`clk_en` module, new)

A small module clocked by `posedge clk` that produces all enables. Two kinds:

**(a) Integer phase strobes** — from a free-running ÷ counter `phase[?:0]`:

| CEN | Fires when | Replaces |
|---|---|---|
| `cen_24m_p` | every 4 master cycles, phase 0 | `posedge clk_sys` (24.576) |
| `cen_24m_n` | every 4 master cycles, phase 2 | `negedge clk_sys` |
| `cen_12m_p` | every 8 master cycles, phase 0 | `posedge O_CLK`/`I_CLK_12M` (12.288) |
| `cen_12m_n` | every 8 master cycles, phase 4 | `negedge I_CLK_12M` |

The H/V counter (`hv_count`) becomes a plain counter advancing on `cen_24m_p`;
every H_CNT-bit-derived "clock" (`O_CLK`, `V_CLK`, `CLK_4PN=H_CNT[0]`,
`I_H_CNT[2/6/9]`, the obj `CLK_4L/5L/3E`, `W_5F2_Q[*]`) becomes a **decoded
CEN** = "the master cycle on which that counter bit / FSM output transitions."
Since the counter is now in the master domain, these are deterministic,
master-aligned, fully analyzable enables — no edge-detect or metastability.

**(b) Fractional CENs** (phase accumulators) — for rates not harmonically
related to 98.304:

| CEN | Target avg rate | Accumulator (add/wrap) | Replaces |
|---|---|---|---|
| `cen_cpu` | 4.000 MHz exact | +125, wrap 3072 (125/3072 × 98.304 = 4.000) | `clk_main` (Z80, adec, DMA) |
| `cen_snd` | 21.477272 MHz | fractional (ratio 21.477272/98.304) | `clk_sub` base for the sound divider |

`cen_cpu` averages exactly 4 MHz with bounded jitter (24–25 master cycles per
tick) — invisible to a static Z80, and the VRAM `WAIT`/busy arbitration (now in
the *same* domain as the CPU) absorbs the jitter exactly. The sound 2A03 chain
keeps its existing `div_cpu=12 → cpu_ce/phi2/odd_or_even` structure but runs it
on `cen_snd` instead of `posedge clk_sub`.

> NOTE on faithfulness: on real hardware the Z80 is a separate 8 MHz/2 crystal,
> *asynchronous* to video (MAME `dkong.cpp`, `XTAL(8'000'000)/2`, "verified in
> schematics"). Making it a synchronous CEN is a deliberate, documented
> deviation: average rate is preserved (4.000 MHz), and synchronizing it to
> video is what removes the arbitration hazards. This is the standard MiSTer
> approach (`12-clocks-...md` §2: `clk_sys` "is the universal CE-domain master").

### 2.3 Phase map (negedge / ripple → posedge + CEN)

With `phase` counting 0..7 (÷8 of the 98.304 master = one 12.288 MHz period):

```
master cycle:   0    1    2    3    4    5    6    7
24.576 edge:    ↑         ↓         ↑         ↓          (cen_24m_p@0, cen_24m_n@2,4,6...)
12.288 edge:    ↑                   ↓                    (cen_12m_p@0, cen_12m_n@4)
```

Every current clocked process is rewritten as `always @(posedge clk) if (cen_X)`
where `cen_X` is the strobe for that process's original edge. A `negedge X`
process uses the *opposite-phase* CEN of `X`. A process clocked by a counter bit
uses the CEN decoded for that bit's transition.

---

## 3. Per-file conversion plan

| File | Current clocks | Becomes |
|---|---|---|
| `dkong3_hv_count.v` | `posedge I_CLK`, `posedge O_CLK`, `posedge V_CLK` | one counter on `cen_24m_p`; emit `cen_o_clk`, `cen_v_clk` as decoded strobes (and expose H/V counts directly) |
| `dkong3_vram.v` | `negedge I_CLK_24M`, `posedge CLK_4PN`, `posedge I_H_CNT[2/6]`, RAM `~I_CLK_12M` | all `posedge clk + cen_*`; RAM rewritten to the Intel registered-read template (`30-memory-...md` §3) |
| `dkong3_obj.v` | many counter/register clocks | all `posedge clk + cen_*`; the `W_5F2_Q`-clocked and `CLK_3E/4L/5L`-clocked FSMs become enables decoded from the same counter |
| `dkong3_adec.v` | `posedge/negedge I_CLK`, `posedge W_VBLK or negedge W_3E_Q[4]` | `posedge clk + cen_cpu` (and `cen_cpu_n`); NMI flop becomes a synchronous edge-detect of VBLANK gated by the 259 latch |
| `dkong3_main.v` | Z80 `clk_main`, RAM `~I_CLK_12M`, DMA `~I_MCPU_CLK` | Z80 `CLK=clk, CEN=cen_cpu` (T80as already supports CEN); RAMs to template; DMA on `cen_cpu_n` |
| `dkong3_sound.v` | `posedge I_SUBCLK` ×N | `posedge clk + cen_snd`; the `div_cpu` chain and all RAM/latch flops gated by `cen_snd` (and the derived `cpu_ce/phi2`) |
| `dkong3_col_pal.v` | `posedge I_CLK_6M or negedge W_1B2C_RST` | `posedge clk + cen_6m`, sync reset |
| `dkong3_logic.v` | generic JK FF on derived clock | `posedge clk + cen` (enable = the net it was clocked by) |
| `dkong3_dma.v` | `~I_MCPU_CLK` | `posedge clk + cen_cpu_n` |
| `dkong3_sub.v` / `apu.sv` / `t65` / `t80asd_ip` | already `posedge clk + enable/ce` | unchanged logic; only the *driving* clock/CEN at the wrapper changes |
| `dkong3_roms.v`, `dkong3_bram.v`, `dpram.vhd` | `posedge CLKx` | feed `clk`; reads/writes gated by the appropriate CEN |
| `Arcade-DonkeyKong3.sv` | 3 PLL outs | 1 PLL out `clk`; instantiate `clk_en`; `CLK_VIDEO=clk`, `CE_PIXEL=cen_pix`; reset sync into the one domain |

The soft-CPU cores themselves (T80as/T65/APU) are **already** synchronous
`posedge clk` + clock-enable designs — only their *clock source* changes from a
PLL output to `clk`+CEN. No core-internal logic is touched.

---

## 4. Reset

Single domain ⇒ one async-assert / sync-release synchronizer (`11-clocking-...md`
§5, `[C]`). `RESET | status[0] | buttons[1]` async-asserts a 2–3 FF synchronizer
clocked by `clk`; the released `rst` (active-low, consistent polarity) drives all
sync clears. All the per-domain reset syncs (`cpu_resetn_s*`, `sub_resetn_s*`)
and the derived async resets (`negedge W_3E_Q[4]`, `negedge W_1B2C_RST`,
`negedge I_H_CNT[9]`) collapse into synchronous clears in the one domain.

---

## 5. SDC

End state (per `40-timing-closure-and-sdc.md`):

```tcl
derive_pll_clocks
derive_clock_uncertainty
# + multicycle constraints for the CEN-gated paths (see §6)
```

**All** of the current custom lines — `set_max_delay … $sync_max`, the sound
sync relaxations, `set_false_path` on the reset syncs — are **deleted**. They
exist only to paper over the async domains, which no longer exist. (Matches the
user's intent and `12-clocks-...md` §8: Template ships only `derive_pll_clocks`
+ `derive_clock_uncertainty`.)

---

## 6. Timing-closure strategy (multicycle)

`[V]` `set_multicycle_path` is reserved for paths where the RTL guarantees the
source is stable for N clocks — exactly what a CEN provides (`40-...md` §2).
Without multicycle, TimeQuest analyzes every CEN-gated path single-cycle at
10.17 ns and reports a wall of *false* failures (and can mask real ones). With
it, each path gets its true window:

- 24.576-rate paths (ride `cen_24m_p`, 4 master cycles apart): `-setup 4 -hold 3`.
- 12.288-rate paths (8 apart): `-setup 8 -hold 7`.
- Half-period (ex-`negedge`, posedge-phase→opposite-phase, 2 apart): `-setup 2 -hold 1`.
- CPU/sound CEN paths (≥24 apart): covered by ≥ the 24-cycle multicycle.

These are applied per CEN domain using register groups (`-from`/`-to`
`[get_registers ...]`). The CEN generator itself (the accumulator + phase
counter) runs every cycle and closes single-cycle trivially. This must be a
first-class deliverable — an under-constrained multicycle silently masks
failures (`40-...md` §7), an over-constrained one yields false reds.

---

## 7. Verification — testbenches for every piece (ghdl + verilator)

Per `41-quartus-reports-and-verification.md` (scoreboarded testbenches + handshake
SVA, no waveform-only sign-off). Because this is a *behavior-preserving refactor*,
the primary technique is **differential / equivalence testing**:

### 7.1 Differential equivalence harness (the regression backbone)

For each module being converted, a testbench instantiates **both** the original
(pre-rework, from `master`) and the reworked module, drives identical stimulus,
and asserts their outputs match **cycle-for-cycle at every CEN-active point**:

- The original sees its real clocks (e.g. `clk_main`, `clk_sub`, ripple nets);
  the reworked sees `clk` + CENs generated to fire on the same logical edges.
- A scoreboard captures both output streams; `$fatal` on first divergence.
- This proves the conversion changed *timing representation only*, not behavior.

Tooling:
- **verilator** for the Verilog/SV modules (hv_count, vram, obj, adec, main glue,
  sound glue, video, dma, col_pal, logic, top). C++ or SV test harness; immediate
  assertions (`$fatal`) for the scoreboard (Verilator's concurrent-SVA support is
  partial — use immediate-assertion / `$past`-style checks in clocked blocks).
- **ghdl** for the VHDL IP (`t80asd_ip`, `t65`, `dpram`). These don't change
  logically; ghdl TBs confirm the CEN-driven wrapper exercises them identically.
- Mixed-language top: keep VHDL cores behind their existing Verilog wrappers so
  verilator drives the whole subsystem; ghdl covers the VHDL units in isolation.

### 7.2 Golden-trace end-to-end regression

A whole-core (or large-subsystem) verilator sim runs a fixed scripted scenario
(ROM load → reset release → N frames with a canned input vector) and dumps a
trace: per-frame video signature (RGB + HSync/VSync timing), the audio sample
stream, and the Z80 bus activity. The `master` build produces the **golden**
trace; each rework checkpoint must reproduce it (allowing only the documented
CPU-jitter alignment). `$fatal` on mismatch. This is the catch-all that proves
the integrated core still behaves.

### 7.3 Per-module unit checks

Where a module has a self-contained contract (counters, RAM RDW, the CEN
generator), add a direct scoreboarded unit TB (`41-...md` §5 Pattern A):
- `clk_en`: assert each CEN's average rate and phase alignment over a window.
- RAMs: write-then-read latency + RDW-collision mode (`30-...md` §8).
- hv_count: H/V counts, blank/sync edges match the original bit-for-bit.

### 7.4 Harness layout

```
tb/
  common/         clk_en, reset, scoreboard helpers
  diff/           one *_diff_tb per converted module (old vs new)
  unit/           clk_en, ram, hv_count unit TBs
  golden/         end-to-end trace capture + compare
  Makefile        `make verilate`, `make ghdl`, `make regress`
```

`make regress` runs the full suite and prints PASS/FAIL; run it after **every**
conversion step so regressions surface immediately.

---

## 8. Sequencing (buildable + testable checkpoints)

Each step ends green in both Quartus (compiles, timing closes) and `make regress`
before the next begins.

0. **Harness first.** Build the `tb/` skeleton + the golden-trace capture from
   `master`. No RTL change. Establishes the regression baseline.
1. **Clock foundation.** Regenerate `pll` → 98.304; add `clk_en`; wire
   `CLK_VIDEO`/`CE_PIXEL`; reset sync. Core still uses derived clocks internally
   (bridge old nets from new CENs). Verify boot + video unchanged.
2. **hv_count + video timing** → master domain (kills the worst ripple clocks).
3. **vram + obj + col_pal** → master domain (RAM templates, all CENs). Golden
   video trace must match.
4. **Main CPU** (Z80 + adec + DMA + work RAM) → `clk` + `cen_cpu`. Gameplay trace.
5. **Sound** (div_cpu chain + 2A03 + APU + RAM/latches) → `clk` + `cen_snd`.
   Audio trace. (Trickiest — 2A03 phi2/get-put timing.)
6. **SDC cleanup.** Delete all CDC band-aids; add the multicycle set; confirm
   `check_timing` clean and all corners ≥ 0.
7. **Final regression + on-hardware bring-up.**

---

## 9. Risks

- **PLL regeneration** is sensitive (prior revert). Mitigate: regen carefully,
  verify lock on `LED_USER` during bring-up.
- **Multicycle SDC** is the highest-skill part; wrong values mask or fake
  failures. Mitigate: derive per-domain from the phase map, review against the
  Timing Analyzer report each step.
- **Sound 2A03 timing** is jitter-sensitive. Mitigate: differential TB against
  the original `clk_sub` sound subsystem; audio golden trace.
- **CPU jitter** vs the original exact 4 MHz: average preserved; differential TB
  must align on CEN ticks, not master cycles.
- **Scope.** Large refactor touching every file. Mitigate: the staged,
  per-checkpoint regression in §8 — never advance on a red suite.
