# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An FPGA implementation of the Nintendo **Donkey Kong 3** (1983) arcade hardware for the
[MiSTer](https://github.com/MiSTer-devel) platform (Intel Cyclone V, DE10-Nano). The RTL is a
cycle-oriented reconstruction of the original board (Z80 main CPU + dual Ricoh 2A03 sound CPUs),
wrapped in the standard MiSTer framework. By gaz68, based on Katsumi Degawa's Donkey Kong core and
Sorgelig's original MiSTer port. Mixed Verilog / SystemVerilog / VHDL.

## Building

This is a Quartus FPGA project, not a software project — there is no compiler/lint/test toolchain
in the usual sense. The build product is a `.rbf` bitstream.

- Build: open `Arcade-DonkeyKong3.qpf` in **Quartus 17.0.2 Lite** (the pinned version, see
  `LAST_QUARTUS_VERSION` in the `.qsf`) and run a full compilation, or headless:
  `quartus_sh --flow compile Arcade-DonkeyKong3`. Output `.rbf` lands in `output_files/`.
- Released bitstreams live in `releases/` (dated `Arcade-DonkeyKong3_YYYYMMDD.rbf`).
- `clean.bat` removes Quartus-generated build artifacts (also covered by `.gitignore`).

**Adding source files:** never add files through the Quartus GUI — it rewrites the `.qsf` and
breaks the MiSTer structure (warning is in the `.qsf` header). Add HDL files manually to
`files.qip` instead. The `.qsf` only sources `sys/sys.tcl`, `sys/sys_analog.tcl`, and `files.qip`.

There is no ROM in the repo. To actually run the core on hardware you supply the MAME `dkong3.zip`
ROM; the `.mra` file in `releases/` lists the required parts and CRCs and tells MiSTer how to
assemble them into the download stream.

## Architecture

### Two layers: MiSTer wrapper vs. the game core

- **`Arcade-DonkeyKong3.sv`** — the `emu` top module, MiSTer's standard interface. It instantiates
  `hps_io` (HPS↔FPGA communication, OSD menu, ROM download), the `pll`, video scaling
  (`arcade_video`, `screen_rotate`), audio output, and maps joystick/keyboard to the arcade's
  switch ports. The OSD menu layout and DIP switches are defined by the `CONF_STR` localparam here.
  Everything in `sys/` is the shared, mostly-unmodified MiSTer framework — treat it as a vendored
  library, not project code.
- **`rtl/dkong3_top.v`** — the actual game board. The `emu` module wires the three clocks, reset,
  switches, the ROM-download bus (`dn_addr`/`dn_data`/`dn_wr`), and video/audio in and out of this
  module. **This is where game logic changes go.** It connects three subsystems:
  `dkong3_main` (CPU), `dkong3_video`, and `dkong3_sound`.

### Clocks

The `pll` produces three clocks consumed by `dkong3_top`:
- `clk_sys` = 24.576 MHz (`I_CLK_24M`) — master/video clock, also `hps_io` clock.
- `clk_main` = 4 MHz (`I_CLK_4M`) — Z80 main CPU clock.
- `clk_sub` = 21.477 MHz (`I_SUBCLK`) — sound subsystem master clock; the 2A03 CPU cadence is
  derived from it by the divider in `dkong3_sound.v` (`cpu_ce`, `phi2`, `odd_or_even`).

`dkong3_hv_count` generates the 12 MHz pixel-domain clock plus all H/V counters, blanking, and sync,
with `H_OFFSET`/`V_OFFSET` (from OSD) for analog positioning and `flip_screen` support.

### Subsystems (`rtl/dkong3_*.v`)

- **Main CPU** (`dkong3_main.v`) — Z80 core (`z80ip_t.v` → `rtl/t80asd_ip/` T80) plus program ROM,
  work RAM, DIP/input latches, and `dkong3_adec` address decoding (driven by the `5E` decoder PROM).
  Drives object DMA (`dkong3_dma`), the output latches `O_3E_Q`/`O_4E_Q` (control + sound command
  bytes to the sound CPUs), and the sub-CPU reset.
- **Video** (`dkong3_video.v`) — background tilemap (`dkong3_vram`), sprites/objects (`dkong3_obj`),
  and color (`dkong3_col_pal` + CLUT/palette PROMs). Outputs 4-bit RGB + blanking. The
  VRAM-busy handshake (`O_VRAMBUSYn`) stalls the main CPU during contended VRAM access.
- **Sound** (`dkong3_sound.v`) — two independent `dkong3_sub` instances. Each is a 6502 (T65, from
  `rtl/t65/`) + its NES APU (`rtl/apu.sv`, lifted from the NES MiSTer project) emulating a Ricoh
  2A03, with its own ROM and 2 KB RAM. The main CPU writes sound commands into per-CPU input latches
  (mapped at `$4016`/`$4017` in APU address space). The two APU samples are attenuated and summed
  into `O_SOUND_DAT`.

### ROM loading (`dkong3_roms.v`)

ROMs are not stored on the FPGA; they stream in at runtime over the HPS download bus and land in
on-chip block RAM. `hps_io` asserts `ioctl_download` and walks `ioctl_addr`/`ioctl_dout`; in the
`emu` module these become `dn_addr`/`dn_data`/`dn_wr` (gated on `ioctl_index==0`) and fan out to
every subsystem. Each `DLROM`/`DLROMB` instance is a dual-port BRAM that latches its slice by
**decoding the high bits of `dn_addr`** — so the byte offsets in the load stream must match the
address-range comments at the top of `dkong3_roms.v` (`0x00000` 7B program ROM … `0x12500` 5E
decoder PROM). The `.mra` part order defines that stream, so the `.mra` and these address decodes
must stay in sync. DIP switches arrive separately via `ioctl_index==254` into `sw[]`.

## Conventions

- Signal naming follows the original schematic: `W_` = internal wire, `I_`/`O_` = module port
  direction, and many net names (`3E_Q`, `4E_Q`, `5E`, `7B`, `1D`) are the **chip designators from
  the real PCB**. When touching a subsystem, cross-reference the schematic names rather than
  renaming for clarity.
- Active-low signals carry an `n` suffix (`I_RESETn`, `O_VGA_HSYNCn`, `W_VRAMBUSYn`).
- Timing-closure-sensitive: the `.qsf` runs aggressive physical-synthesis/retiming options and a
  fixed `SEED`. The `840716a`-era "improve timing closure" history shows fitter results matter here;
  prefer registered/pipelined changes and re-check timing after edits to hot paths (CPU, video).
