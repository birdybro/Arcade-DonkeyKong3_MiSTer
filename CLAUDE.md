# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

This is the **Donkey Kong 3** arcade core for MiSTer FPGA (Intel Cyclone V SoC
`5CSEBA6U23I7`, DE10-Nano). It is an FPGA hardware emulation (Verilog/SystemVerilog
+ VHDL) of the original DK3 arcade PCB, wrapped in the MiSTer framework. Core
logic by gaz68; based on Katsumi Degawa's dkong; soft CPUs are T80 (Z80), T65
(6502/2A03), and the NES APU.

## Current focus: synchronous clock rework (`clock-rework` branch)

The active work is converting the **entire core to a single synchronous clock
domain**. Read these before touching RTL:
- `docs/clock-rework/ANALYSIS.md` — the design (98.304 MHz master, everything
  `posedge clk` + clock-enable, phase map, SDC/multicycle strategy, verification).
- `tasks.md` — the staged, checkpointed task list. Work top-to-bottom; each stage
  must end green in **both** Quartus and `make regress` before the next.

Why it matters: the legacy design uses **three async PLL clocks** (`clk_sys`
24.576 / `clk_sub` 21.477 / `clk_main` 4 MHz) plus many **ripple/register/counter-bit
clocks** (`O_CLK=H_CNT_r[0]`, `V_CLK`, `CLK_4PN=I_H_CNT[0]`, `W_5F2_Q[*]`,
`CLK_3E/4L/5L`, `posedge W_VBLK or negedge W_3E_Q[4]`, negedge-clocked RAMs…).
These are the root cause of the core's instability and seed-dependent fits. The
rework replaces every one with a decoded or fractional clock-enable.

Pause / hi-score work is **tabled** until the rework lands.

## Non-negotiable HDL rules (from `docs/hdl-coding-guidelines/`)

These are project contracts — `docs/hdl-coding-guidelines/` is an authoritative
Cyclone V bundle (claim labels `[C]`/`[V]`/`[O]`/`[I]`; `[C]` = non-negotiable).
Load the relevant chapter before writing RTL in that area:

- **One clock domain; no fabric-derived clocks.** Every flop is `posedge clk`.
  Never gate a clock, never clock a flop from a counter bit / register output /
  divider. "Stopping a clock" = a clock-enable (`if (cen) q <= d;`). (§11, §90 #9)
- **Reset = async-assert / sync-release**, one synchronizer per domain, one
  consistent polarity (active-low). (§11)
- **Inferred RAM/ROM**: single `always @(posedge clk)`, **registered read**,
  explicit read-during-write mode (blocking = new-data, nonblocking = old-data).
  No negedge-clocked or async-read memories. (§30)
- **SDC**: `derive_pll_clocks` + `derive_clock_uncertainty` + evidence-backed
  `set_multicycle_path` for CEN-gated paths. `set_false_path`/`set_max_delay`
  only for genuine async-by-construction paths (none should remain after the
  rework). (§40)
- **Verify, don't eyeball**: scoreboarded testbenches + reset/edge coverage;
  every Quartus synthesis warning (latch/removed/no-driver) is investigated;
  confirm inferred RAM landed on M10K/MLAB in the Fitter report. (§41)

There is also `docs/mister-framework-reference/` for the MiSTer wrapper contract
(emu top-level, conf string, clocks/PLLs, hps_io, video, audio).

## Build

Toolchain: Intel Quartus 17.0 Lite at `~/intelFPGA_lite/17.0/quartus/bin/`.

```sh
# Full compile (synthesis + fit + assemble + timing). ~4 min.
~/intelFPGA_lite/17.0/quartus/bin/quartus_sh --flow compile Arcade-DonkeyKong3
# Outputs: output_files/Arcade-DonkeyKong3.{sof,rbf}
```

```sh
# Timing-analysis only against the existing fit (fast; no re-fit needed for SDC-only changes):
~/intelFPGA_lite/17.0/quartus/bin/quartus_sta Arcade-DonkeyKong3
# Check closure:
grep -iE "Worst-case (setup|hold|recovery|removal|minimum pulse width) slack" output_files/Arcade-DonkeyKong3.sta.rpt
grep -c "Timing requirements not met" output_files/Arcade-DonkeyKong3.sta.rpt   # must be 0
```

**Adding/removing RTL files**: edit `files.qip`, **not** the Quartus IDE (the
`.qsf` warns the IDE will mangle the project). `Arcade-DonkeyKong3.qsf` sets the
optimization/fitter assignments and `SEED`; `Arcade-DonkeyKong3.sdc` holds timing
constraints.

The fitter critical path is the **framework `ascal` HDMI scaler** on `pll_hdmi`
(~+0.4 ns, knife-edge even on master) — a pre-existing framework marginality,
not core logic. If overall setup slack is barely positive/negative there, it's
that path, not a core regression.

## Test / simulate

Simulators installed: **ghdl** (VHDL) and **verilator** (Verilog/SV). The
regression strategy (see `docs/clock-rework/ANALYSIS.md` §7) is **differential
equivalence** — instantiate the original module and the reworked module, drive
identical stimulus, assert outputs match at every clock-enable tick — plus a
**golden end-to-end trace** captured from `master`.

```sh
# Quick syntax/lint of a self-contained Verilog/SV module:
verilator --lint-only -Wno-lint <file.v>
# Analyze the VHDL CPU chain (catches VHDL errors without a full build):
ghdl -a --std=08 rtl/t80asd_ip/T80_Pack.vhd rtl/t80asd_ip/T80_MCode.vhd \
  rtl/t80asd_ip/T80_ALU.vhd rtl/t80asd_ip/T80_Reg.vhd rtl/t80asd_ip/T80.vhd rtl/t80asd_ip/T80as.vhd
```

The `tb/` harness (built in Stage 0 of `tasks.md`) provides `make verilate`,
`make ghdl`, and `make regress`. **Run `make regress` after every conversion
step** so regressions surface immediately; never advance a stage on a red suite.

## Architecture

**Top level** `Arcade-DonkeyKong3.sv` (module `emu`): the MiSTer wrapper. Owns
the `pll` (derives core clocks from `CLK_50M`), `hps_io` (HPS interface, status
word, ROM download via `ioctl_*`), the `CONF_STR` (OSD menu / DIP / controls),
input mapping (joysticks → `m_sw1`/`m_sw2`), and the video/audio plumbing into
the framework (`arcade_video`, `CLK_VIDEO`/`CE_PIXEL`, `AUDIO_*`). ROM data
arrives as a download stream and is routed to the core by `ioctl_index`.

**Core top** `rtl/dkong3_top.v`: wires the three subsystems and the H/V counter.

- `dkong3_hv_count.v` — master H/V counter and all blank/sync generation; the
  legacy source of `O_CLK`/`V_CLK` ripple clocks.
- `dkong3_main.v` — **main CPU**: Z80 (`Z80IP`→`T80as`, VHDL) + `dkong3_adec`
  (address decode, WAIT/NMI, the LS259 `3E`/LS138 `4E` control latches) + work
  RAM (7F/7H) + `dkong3_dma` (sprite DMA, $6900→$7000). Runs at 4 MHz today.
- `dkong3_video.v` — instantiates `dkong3_vram` (tilemap/playfield),
  `dkong3_obj` (sprites; OBJ RAM is DMA-written, video-read), `dkong3_col_pal`.
  VRAM/OBJ addresses are **time-multiplexed** between CPU and video scan;
  `O_VRAMBUSYn` arbitrates CPU access via the Z80 `WAIT` line.
- `dkong3_sound.v` — **sound**: two Ricoh 2A03 (`dkong3_sub` → `T65` + `apu.sv`),
  ROM/RAM, input latches. Main CPU writes sound commands one-way via the `4E`
  latches; there is no read-back path. Runs at 21.477 MHz today with a `div_cpu`
  divider producing the 2A03 `cpu_ce`/`phi2` cadence.

**Hardware facts that matter** (verified against MAME `src/mame/nintendo/dkong.cpp`):
- DK3 Z80 = `XTAL(8'000'000)/2` = 4.000 MHz; on real HW it is a *separate
  crystal*, async to video. **dkong3 has NO watchdog** (unlike dkong2b/dkongjr).
- VRAM/OBJ writes are gated by the time-shared addressing — a CPU write strobe
  must land only in the CPU's access slot, or it scribbles the scan-addressed RAM.

**ROMs are not included** (see README.txt). The `.mra` in `releases/` specifies
the MAME ROM set + checksums; loading is via the MiSTer arcade ROM flow.

## Git / branches

- `master` is the baseline (and the golden-trace reference for regression).
- Work happens on feature branches (currently `clock-rework`). Branch off
  `master`; commit/push only when asked.
