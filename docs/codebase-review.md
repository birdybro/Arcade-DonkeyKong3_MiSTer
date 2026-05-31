# DK3 Codebase Review — Issues & Cleanup

A review of the current RTL against the two reference bundles:
`hdl-coding-guidelines/` (Cyclone V HDL practice) and `mister-framework-reference/` (MiSTer framework
contracts). Findings cite the bundle entry that classifies them; the bundle's claim labels apply
(**[C]** contract / **[V]** convention / **[I]** inference).

**Context for weighting.** This core compiles, has dated `.rbf` releases, and works on hardware. Much
of the RTL is an era-faithful 2003–2004 reconstruction (Katsumi Degawa) wrapped for MiSTer, so several
guideline "violations" are deliberate mirror-of-the-PCB choices that Quartus tolerates. Findings are
tiered by **risk-adjusted value**, not raw severity: a clean compile does not mean a finding is wrong,
but it does mean none of these are blocking today. Nothing here is added to `tasks.md`.

---

## Tier 1 — Safe, isolated cleanups (low risk, do anytime)

### 1.1 Blocking assignments in sequential (`posedge`) blocks
Mixing/using blocking `=` inside `always @(posedge …)` is anti-pattern **#2** in
`hdl-coding-guidelines/90-anti-patterns.md` ([C]: `always_ff` must use `<=` only). Three confirmed
instances drive registers with `=`:

- `rtl/dkong3_adec.v:179-180` — `always @(posedge I_CLK12M) O_4E_Q = W_4E_Q[3:0];` (`O_4E_Q` is `output reg`).
- `rtl/dkong3_input.v:101-102` — `always @(posedge clk) O_D = W_SW1 | W_SW2 | …;` (`O_D` is `output reg`).
- `Arcade-DonkeyKong3.sv:388` — `muted = 1'b0;` inside `always_ff @(posedge clk_sys)`.
- `Arcade-DonkeyKong3.sv:408-409` — `reset = RESET | status[0] | buttons[1];` inside `always @(posedge clk_sys)`.

**Impact:** these are single-register blocks with no intra-block ordering, so behaviour is currently
correct — but the pattern is exactly the sim/synth-mismatch hazard the rule guards against, and it
trips lint. **Fix:** change each to `<=`. Trivial, mechanical, no functional change expected.

> Note: `rtl/dkong3_logic.v` (`O_Q = …`) and the `W_SW*` wires in `dkong3_input.v` use blocking `=` in
> **combinational** blocks (74xx-gate emulation) — that is correct (`always_comb` uses `=`). Not a finding.

### 1.2 Dead code / unused declarations
Resource-economy cleanups (`hdl-coding-guidelines/16` family). All compile-clean but add noise and
mislead readers:

- `rtl/dkong3_dma.v:30` — `reg [7:0] W_DMA_DATA;` declared, never assigned or read. Delete.
- `rtl/dkong3_dma.v:15` — `input I_RSTn` is declared, **never used** inside the module, **and not
  connected** at the instantiation (`rtl/dkong3_main.v:235-246` omits `.I_RSTn`). Either wire a real
  reset and use it, or remove the port. See also 2.3.
- Commented-out dead line `rtl/dkong3_main.v:62` (`//wire [7:0]WI_D = ZDI;`) and the `// Not used`
  ports/wires: `O_5A_G_n` (`dkong3_adec.v:114`), `W_V_CNT`/`.V_CNT()` (`dkong3_top.v:70`), `O_OBJ_DB`
  (threaded through `dkong3_top`/`dkong3_video` but unused), `O_ESBLKn()` (`dkong3_video.v:71`).
  These are harmless but worth pruning for clarity; some (e.g. `O_OBJ_DB`) carry a full 8-bit bus
  through hierarchy for no consumer (anti-pattern **#28**, wide bus leaves ignore).

### 1.3 `apu.sv` lives in `rtl/` root despite being vendored
Not a bug — just noting `rtl/apu.sv` (NES 2A03 APU, lifted from NES_MiSTer) is third-party and large;
a header comment pinning its upstream origin/revision would help future maintenance (matches the
provenance convention the analyses use).

---

## Tier 2 — Framework-contract / latent issues (do before feature work)

### 2.1 `DDRAM_*` and `FB_*` outputs are undriven  ⚠️
`MISTER_FB=1` is set in the `.qsf`, so `Arcade-DonkeyKong3.sv` carries the `FB_*` and `DDRAM_*` output
ports — but the only assignment among them is `assign FB_FORCE_BLANK = 0;` (`:193`). **`FB_EN`,
`FB_FORMAT`, `FB_WIDTH`, `FB_HEIGHT`, `FB_BASE`, `FB_STRIDE`, and the entire `DDRAM_*` group are never
driven.**

- `mister-framework-reference/90-anti-patterns.md` **T.1** [C]: unused `DDRAM_*` must be tied to `'0`
  (they feed the on-chip Avalon `f2sdram` bridge — an undriven/tri-stated internal bus port is illegal
  and can leave the bridge in a bad state; `f2sdram_safe_terminator` exists because of this hazard).
  The Template does `assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;`.
- Undriven module outputs also produce synthesis warnings and implicit-0 drivers (`53 §8` expects
  *no* undriven-output warnings).

**Impact:** today the core uses `arcade_video` (not the DDR framebuffer), so FB-off is the intended
behaviour and Quartus has been pinning these to 0 with warnings — it works, but it violates the
explicit-tie-off contract. **Fix:** add the explicit `DDRAM_* = '0` tie-off and `assign FB_EN = 0;`
(plus 0 for the other `FB_*`). **This becomes load-bearing for savestates/rewind** (`docs/savestates-
analysis.md`, `docs/rewind-analysis.md`), which need to *drive* `DDRAM_*` — so resolve the tie-off
story before that work starts.

### 2.2 No `v,<n>` CONF_STR version directive
`Arcade-DonkeyKong3.sv:212-229` has the `V,v` build banner (`:228`) but **no `v,<n>` config-version
directive**. `mister-framework-reference/90-anti-patterns.md` **T.6** / `11-conf-str.md` C.14 [C]:
without bumping `v,<n>`, a CONF_STR bit-layout change replays the old persisted `status[]` snapshot
into the new layout, silently corrupting users' saved settings.

**Impact:** latent. It matters the moment status bits move — which is *exactly* what the planned
pause/hiscore/cheats/savestate work does (each adds `O[...]` options). **Fix:** add a `"v,0;"` (or
similar) line now, and bump it on every incompatible layout change going forward.

### 2.3 Reset discipline (async-assert without sync-release; combinational/register async clears)
`hdl-coding-guidelines/11` and anti-patterns **#10/#43** flag async resets released without a 2-FF
sync-release, and async-clears driven by **combinational or fabric-register** signals (glitch → spurious
reset). Present throughout, inherited from the discrete-logic original:

- `rtl/dkong3_col_pal.v:49` — `always@(posedge I_CLK_6M or negedge W_1B2C_RST)` where
  `W_1B2C_RST = I_CMPBLKn | W_1B2C_Q[0]` is a **combinational OR** used as async clear (#43).
- `rtl/dkong3_adec.v:79` — `always@(posedge W_VBLK or negedge W_3E_Q[4])` (async clear from a register bit).
- `rtl/dkong3_adec.v:57`, `rtl/dkong3_hv_count.v:81/90` — async reset on `I_VBLK_n` / `I_RST_n` with no
  per-domain sync-release.
- `Arcade-DonkeyKong3.sv` consumes `RESET` directly (T.11 [C]: `RESET` is async to `clk_sys` and should
  be synchronized).

**Impact:** these mirror 74-series flip-flops with async `CLR`, and the core runs — but they are the
classic "works in sim, intermittent on hardware" surface. **Recommendation:** treat as documented
technical debt; if any of these blocks is touched for other reasons, add a sync-release / register the
async source then. Not worth a blind sweep on a working, timing-marginal core.

---

## Tier 3 — Architectural: fabric-derived clocks (high value, high risk)

This is the single largest deviation from `hdl-coding-guidelines/11` and anti-pattern **#9** ([C],
Intel Cyclone V design guidelines): **clocks generated in fabric and routed to flop clock pins.** The
sanctioned Cyclone V approach is one PLL-sourced clock per domain plus **clock-enables** for slower
rates; the original DK hardware "divided a clock," and that was transliterated literally.

Confirmed fabric-derived clocks:

- `rtl/dkong3_hv_count.v:62` — `assign O_CLK = H_CNT_r[0];` a **counter LSB used as a clock**. `O_CLK`
  feeds `always@(posedge O_CLK)` (`:66`) internally **and** is exported as the 12 MHz `W_CLK_12M`
  (`dkong3_top.v:68`) that clocks work RAM and the video subsystem.
- `rtl/dkong3_hv_count.v:64,81,90` — `V_CLK` (a register set on `posedge O_CLK`) used as a clock for
  `V_CNT_r`/`V_BLANK` — a derived clock clocked off another derived clock.
- `rtl/dkong3_video.v:134` — `.I_CLK_6M(I_H_CNT[0])`: a counter bit passed as the "6 MHz clock" into
  `dkong3_col_pal`, which clocks on `posedge I_CLK_6M` (`:49`).
- Inverted clocks routed to clock pins: `~I_CLK_12M` (`dkong3_main.v:182,206`; `dkong3_video.v:52`),
  `~I_MCPU_CLK` (`dkong3_main.v:237`), `~I_CLK` (`dkong3_adec.v:66`), `negedge I_CLK_12M`
  (`dkong3_obj.v:173`). Anti-pattern **#9** names clock inversion as PLL/clock-control-block work;
  single inversions are the mildest case (Quartus often maps to the negedge of the same network).

**Impact:** this is almost certainly why timing is marginal here (cf. the `840721a` "Marginally improve
timing closure" commit and the unusually aggressive physical-synthesis/retiming options + fixed `SEED`
in the `.qsf`). Each fabric clock consumes a global-clock network, complicates the static-timing model,
and can glitch. The guideline-faithful rewrite is to run everything on `clk_sys` (24.576 MHz) and
replace `O_CLK`/`V_CLK`/`I_H_CNT[0]` clocks with **clock-enable pulses** derived from the H/V counters
(`hdl-coding-guidelines/11 §5` shows the `if (en) q <= d;` pattern; the PGM/modern arcade cores all do
this).

**Recommendation: do NOT rush this.** It is a deep rearchitecture of a working, cycle-sensitive core,
and anti-patterns **#33/#34** warn that careless pipelining/restructuring changes observable cycle
counts and breaks cycle-exact behaviour. Value is real (timing headroom, fewer GCLKs, cleaner STA) but
risk is high. Treat as a separate, well-tested project — convert one derived clock to a CE at a time,
diffing video output against the current build, rather than as drive-by cleanup. If savestates (which
add a DDRAM master and more logic) push timing over the edge, this is the lever to pull.

---

## Tier 4 — Minor / stylistic

- **Case labels with runtime expressions** — `rtl/dkong3_hv_count.v:71-72`
  (`V_CL_P + H_OFFSET*2: V_CLK <= 1;`) uses input-dependent case items. Legal (synthesizes to
  comparators) but unusual; a comment or an explicit `if` comparator would read clearer.
- **Tabs vs spaces** — `mister-framework-reference/53` C.33 [V] notes upstream uses tabs; the RTL here
  is mixed. Cosmetic only.
- **`(* ramstyle *)` / `romstyle` annotations** — the PROM/RAM wrappers in `dkong3_roms.v` / `dpram.vhd`
  rely on default inference. If a future Fitter report shows small PROMs each eating a full M10K
  (anti-patterns **M.19/M.20** in the MiSTer bundle), annotate small ROMs with
  `(* romstyle = "MLAB" *)`. Not worth doing speculatively — gate on a Fitter resource report.
- **`dkong3_dma.v` FSM has no reset** — relies on Cyclone V flops powering up to 0 (`W_DMA_EN=0`), which
  is valid on this device (`hdl-coding-guidelines/11 §3.5`), but a one-line synchronous reset would be
  more robust and would give the orphaned `I_RSTn` port (2.1/1.2) a purpose.

---

## Suggested order (if acting on this)
1. **Tier 1** (blocking→nonblocking, dead-code prune) — minutes, zero functional risk, shrinks the
   warning log so real issues stand out.
2. **Tier 2.1 + 2.2** (DDRAM/FB tie-offs, add `v,0`) — do **before** the planned feature work; both
   become correctness issues once savestates/CONF_STR options land.
3. **Tier 2.3 / Tier 3** — document as known debt; address opportunistically or as a dedicated,
   carefully-verified clocking project. Do not sweep blindly on a working core.

## What was reviewed
`Arcade-DonkeyKong3.sv` and `rtl/dkong3_{top,main,sub,sound,video,vram,obj,col_pal,adec,dma,hv_count,
input,logic,bram,roms}.v` + `dpram.vhd`. The vendored CPU cores (`rtl/t80asd_ip/*.vhd`,
`rtl/t65/*.vhd`) and `rtl/apu.sv` were treated as third-party IP and not line-audited. `sys/` is the
frozen framework (`53` C.2) and was not reviewed.
