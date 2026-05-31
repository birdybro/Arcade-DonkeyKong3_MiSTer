# Implementing Savestates in the DK3 Core

Analysis of how savestates are achieved in
[Arcade-IGSPGM_MiSTer](https://github.com/wickerwaka/Arcade-IGSPGM_MiSTer) (wickerwaka's IGS PGM
core) and how they could be implemented here.

**Bottom line up front:** savestates are an order of magnitude more invasive than pause / hiscore /
cheats. Those three tap one bus each; a savestate must capture **every flip-flop and every RAM** in
the machine, then stream that snapshot to storage and reload it atomically. The PGM core solves this
with a clean, reusable framework (a "savestate bus" + auto-generated register wrappers + a DDR
streamer). Porting it to DK3 is feasible but is a substantial project, and DK3 has two specific
obstacles the PGM core did not (VHDL CPUs and a stateful NES APU). This document explains the PGM
architecture, then lays out a realistic DK3 path with an honest scope/risk assessment.

---

## 1. How the PGM core does it

The whole system is built around a small SystemVerilog **savestate bus** (`rtl/savestates.sv`) plus a
**Python code generator** (`util/state_module.py`) that auto-instruments modules. Pieces:

### 1.1 The savestate bus — `ssbus_if` (`rtl/savestates.sv`)

A single interface that a *streamer* (master) uses to talk to many *device adaptors* (slaves):

```systemverilog
interface ssbus_if();
    logic [63:0] data;       // master -> slave (write data)
    logic [31:0] addr;       // word index within the selected device
    logic [7:0]  select;     // which device/chunk is addressed
    logic write, read, query;
    logic [63:0] data_out;   // slave -> master (read data)
    logic ack;

    function logic access(int idx);             // "is this transfer for me?"
        return (select == idx[7:0]) & ~query & (read | write);
    function task setup(int idx, [31:0] count, int width); // advertise size during query
        if (select==idx && query) begin data_out <= {idx,...,width,count}; ack<=1; end
    task read_response(int idx, [63:0] dout);   // answer a read
    task write_ack(int idx);                    // acknowledge a write
endinterface
```

Each device owns a `select`/`SS_IDX`. During a **query** pass the streamer walks the indices and each
slave reports its `count` (number of words) and `width` via `setup()`; the streamer thereby learns
the total snapshot layout without any hand-maintained map.

### 1.2 The mux — `ssbus_mux`

Broadcasts one streamer's bus to up to `COUNT` device slaves and ORs their `ack`/`data_out` back.
PGM uses `ssbus_mux #(.COUNT(20))` — 20 savestate devices (CPU, each RAM, each custom chip, a global
scratch entry, …), each on `ssb[SSIDX_*]`.

### 1.3 Device adaptors

Three reusable adaptor styles wrap different kinds of state:

- **`auto_save_adaptor`** — wraps a flat register vector. `bits_in`/`bits_out`/`bits_wr`; on a
  savestate write it loads the bits and pulses `bits_wr`, on read it returns them. This is what the
  **auto-generated** module wrappers plug into.
- **`auto_save_adaptor2`** — for a device exposing an indexed internal register file
  (`device_idx`/`state_idx`, `rd`/`wr`/`ack`). It enumerates the device's registers during the query
  pass and builds an `idx_map`. The **Z80** uses this:
  ```systemverilog
  auto_save_adaptor2 #(.SS_IDX(SSIDX_Z80)) z80_ss_adaptor( .ssbus(ssb[SSIDX_Z80]),
     .rd(z80_ss_rd), .wr(z80_ss_wr), .ack(z80_ss_ack),
     .device_idx(z80_ss_device_idx), .state_idx(z80_ss_state_idx),
     .wr_data(z80_ss_in), .rd_data(z80_ss_out) );
  ```
- **`ram_ss_adaptor` / `m68k_ram_ss_adaptor`** — splice the streamer onto a RAM's access port.
  During normal operation the RAM sees the game's address/data; during savestate access the adaptor
  drives the RAM from the ssbus instead (the CPU is paused, so there's no contention):
  ```systemverilog
  m68k_ram_ss_adaptor #(.WIDTHAD(16), .SS_IDX(SSIDX_WORK_RAM)) workram_ss(
     .clk, .addr_in(...), .data_in(...), .q(workram_q),
     .addr_out(workram_addr), .data_out(workram_data), .ssbus(ssb[SSIDX_WORK_RAM]) );
  ```

### 1.4 The auto-generated register wrappers — `*_auto_ss.sv`

This is the key to making it tractable. `util/state_module.py` parses a module with **verible**,
finds every flip-flop, and emits a `<module>_auto_ss` wrapper that concatenates all those registers
onto an adaptor — so the module's entire state is serialized with no hand-maintained list:

```
python state_module.py tv80s rtl/tv80_auto_ss.v rtl/tv80/*.v
```

PGM ships `rtl/tv80_auto_ss.sv` (the Z80) and `rtl/jt10_auto_ss.sv` (the FM sound chip) generated
this way. The CPU instance gets `auto_ss_*` ports added (`auto_ss_rd/wr/device_idx/state_idx/
data_in/data_out/ack`).

### 1.5 The streamer + storage — `save_state_data` (`rtl/savestates.sv`)

Moves the whole concatenated snapshot to/from **DDR3**, one 4 MB region per slot:

```systemverilog
memory_stream memory_stream ( .ddr,
   .read_req(ssbus.read), .read_data(ssbus.data_out), .data_ack(ssbus.ack),
   .write_req(ssbus.write), .write_data(ssbus.data),
   .start_addr(SS_DDR_BASE + (index * 32'h00400000)),   // 4 MB per slot
   .length(32'h00400000),
   .chunk_select(ssbus.select), .chunk_address(ssbus.addr), .query_req(ssbus.query) );
```

Instantiated in `rtl/PGM.sv` with `.index(ss_index)`, `.read_start(ss_read)`,
`.write_start(ss_write)`, `.busy(ss_busy)`, `.ddr(ddr_ss)`.

### 1.6 The coordinator — `ss_state` FSM (`rtl/PGM.sv`)

Saving/restoring isn't a single cycle — the FSM pauses the core, drains it to a safe point, runs the
streamer, then resumes. PGM's M68k path is *complicated*: because fx68k doesn't expose the stack
pointer cleanly, the FSM forces an interrupt and single-steps the CPU to spill `SSP` to RAM
(`SST_SAVE_WAIT_IRQ`, `SST_SAVE_WAIT_SSP_SAVE`, etc.), saving it via a `SSIDX_GLOBAL` scratch entry.
The Z80 path is far simpler — `tv80_auto_ss` exposes the registers directly, so no spill trick is
needed.

### 1.7 The UI — `savestate_ui.sv`

Maps OSD options, PS/2 F1–F4 keys, and a gamepad chord (hold `joySS`, D-pad to pick slot, Down=save,
Up=load) to `ss_save`/`ss_load`/`ss_index`. CONF_STR entries (`Arcade-IGSPGM.sv`):

```
"O[42:41],Savestate Slot,1,2,3,4;",
"O[40],Autoincrement Slot,Off,On;",
... "Load=DPAD Up|Save=Down|Slot=L+R", ...
```

### 1.8 Data flow summary

```
savestate_ui ─▶ ss_save/ss_load/ss_index ─▶ ss_state FSM (pause + drain)
                                              │
                          save_state_data ◀───┘  ── ddr_if ──▶ DDR3 (4MB/slot)
                                │ ssbus (query→size, then read/write each word)
                                ▼ ssbus_mux (COUNT=20)
   ┌───────────────┬───────────────┬───────────────┬─────────────┐
 Z80(auto_ss2)  workram(ram_ss)  vram(ram_ss)   IGS chips     ICS2115 ...
```

---

## 2. Why DK3 is harder than it looks

| Concern | PGM core | DK3 core (this repo) |
|---|---|---|
| Main CPU | **tv80** (Verilog) — has a ready `tv80_auto_ss.sv` | **T80** = `rtl/t80asd_ip/*.vhd` — **VHDL**; the verible-based generator can't instrument it |
| Sound CPU | Z80 (covered above) + FM chip (`jt10_auto_ss`) | **two 6502s** = `rtl/t65/*.vhd` — **VHDL**, plus **two NES APUs** (`rtl/apu.sv`, ~34 KB, very stateful) |
| State storage | DDR3, 4 MB/slot, already plumbed (`ddr_if`, `ddr_mux`, `memory_stream`) | DDRAM interface exists in the `emu` wrapper but is **unused** by the core; no `memory_stream`/`ddr_if` ported |
| RAM | external/large, adaptor-wrapped | small on-chip BRAM (7F/7H 2 KB each, VRAM, sprite/obj, palette) — easy to wrap, easy to fit |
| Register surface | instrumented automatically | T80 + 2×T65 + 2×APU + video/DMA/latches — large, and mostly **VHDL** so not auto-instrumentable |

The single biggest issue: **the generator (`state_module.py`) only parses Verilog, but DK3's CPUs are
VHDL.** That removes the "automatic" from auto-savestate for the exact modules that need it most.

Two ways around it:
1. **Swap cores to Verilog equivalents.** Replace `T80as` with **tv80s** (already proven in this
   exact framework, with a ready `tv80_auto_ss.sv`) and replace `T65` with a Verilog 6502. This is
   the most faithful port of the PGM approach but changes the CPU implementations (re-verify timing
   and cycle behaviour).
2. **Hand-instrument** the VHDL cores (add savestate ports that read/write their internal registers)
   — large, error-prone, and must be redone for T80 and T65.

The **NES APU** (`apu.sv`) is the other hard spot: it has envelope/sweep/length counters, a frame
sequencer, DMC state, etc. It's SystemVerilog so the generator *could* run on it, but verifying a
clean save/restore of audio state is fiddly.

---

## 3. Recommended DK3 approach

### 3.1 Scope decision — what to capture
A fully-correct snapshot is everything. But DK3's two 6502+APU sound subsystems are **audio-only** and
resynchronise from new sound commands the main CPU sends. A **pragmatic savestate** can capture:

- **Must capture** (game-visible state): main Z80 (T80) registers; work RAM 7F & 7H; VRAM; sprite/
  object RAM; palette RAM; the control latches (`3E_Q`, `4E_Q`), DMA state, and the H/V counter /
  flip state.
- **Optional / can let free-run**: the two sound 6502s + APUs. Skipping them yields a brief audio
  glitch on restore but no gameplay error, and removes the hardest modules from scope.

This pragmatic scope is strongly recommended for a first version; full audio-state capture can come
later. **Be explicit in the UI/docs that sound state is not restored** if you take this path.

### 3.2 Transport decision — use the framework-native `SS` DDRAM mechanism
> **Corrected per the added framework docs** (`mister-framework-reference/32-rom-save-state-flows.md`
> §2.3, `11-conf-str.md`). An earlier draft proposed an HPS `ioctl_upload`/`download` `.ss` file path
> ("Option B"); that is **not** the canonical savestate transport and should not be used. The
> framework already provides DDRAM-backed savestate slots + automatic disk persistence.

The MiSTer framework has a **built-in savestate channel**, opt-in via the `CONF_STR` token
`SS<base>:<size>` (with `base`+`size` inside `[0x20000000, 0x40000000)`, `size ≤ 128 MB`):
- The HPS allocates **exactly 4 slots**, contiguous in DDRAM: slot `i` at `ss_base + i*ss_size`.
  (4 slots is fixed — not a core-side choice.) [C, doc 32 §2.3]
- Each slot's first 64 bits are a control header: `[31:0]` = **change detector**, `[63:32]` = size in
  32-bit words (excluding the header).
- The core saves by writing **payload → size word (`base+4`) → change detector (`base+0`) LAST**. The
  HPS polls each slot's change detector at ~1000 ms cadence and, on a delta, flushes `(size+2)*4`
  bytes to `<root>/savestates/<Core>/<basename>_<N>.ss`. **Disk persistence is automatic** — the core
  never touches `ioctl_upload`.
- On core launch the HPS reloads existing `.ss` files into the DDRAM slots and forces the change
  detectors to `0xFFFFFFFF`. Key "slot has data" off the **size word ≠ 0**, not the change detector
  (anti-pattern A.6, doc 32 §7).

**This is the transport.** It replaces both of the earlier draft's options:
- The PGM `save_state_data`/`memory_stream` streamer is essentially a custom writer into exactly this
  DDRAM region — so the work is "drive `DDRAM_*` per the SS slot layout + change-detector protocol,"
  not "invent a transport." Reuse the `ssbus`/adaptor framework to *collect* state, and point the
  streamer's writes/reads at `ss_base + slot*ss_size + 8` (payload) with the header protocol above.
- DK3 already declares `MISTER_FB`, so the DDRAM bridge is in use for the scaler framebuffer
  (reserved at byte `0x24000000`, doc 31). Pick an `SS` region that does **not** overlap it; the
  framework `sysmem`/`f2sdram_safe_terminator` arbitrates the core's `DDRAM_*` master against the
  framebuffer. Confirm whether DK3's `emu` currently drives or ties `DDRAM_*` before wiring.

**Critical write-ordering rule** (doc 32 §7 A.2): never bump the change detector before the payload
and size word have committed to DDRAM, or the HPS may flush a half-written state. If the DDRAM path
can reorder writes, fence before the detector write.

Reuse `ssbus_if`, `ssbus_mux`, the adaptors, and `savestate_ui.sv` unchanged regardless.

### 3.3 Architecture for DK3

```
savestate_ui (OSD/keys/pad) ─▶ ss_save/ss_load/ss_slot ─▶ ss_state FSM (assert I_PAUSE, drain)
                                                            │
        streamer ─▶ DDRAM_* into framework SS slot          │
        (ss_base + slot*ss_size; payload→size→detector LAST)│
                                │ ssbus
                                ▼ ssbus_mux(COUNT = N)
   ┌──────────────┬──────────────┬───────────────┬──────────────┬───────────────┐
 Z80 regs      RAM 7F/7H        VRAM         sprite/obj RAM    palette + latches/DMA
 (auto_ss2 or  (ram_ss_adaptor on each on-chip BRAM's 2nd port)
  hand port)
```

Pause reuse: the savestate FSM asserts the same `I_PAUSE` you add for the Pause feature
(`dkong3_main.v` `WAIT_n` gate) to freeze the Z80 while the snapshot streams.

---

## 4. Implementation outline

0. **Declare the SS region:** add `SS<base>:<size>` to `CONF_STR` (base/size inside
   `[0x20000000, 0x40000000)`, not overlapping the `0x24000000` framebuffer region). This turns on
   the framework's 4-slot DDRAM savestate channel + automatic `.ss` disk persistence.
1. **Framework:** port `rtl/savestates.sv` (interface, mux, adaptors) and `rtl/savestate_ui.sv`;
   add to `files.qip`. The streamer writes/reads the framework SS DDRAM slots (header protocol in
   §3.2); reuse PGM's `save_state_data`/`memory_stream` as the streamer, pointed at the SS region.
2. **Main CPU state:** either (a) replace `T80as`→`tv80s` and use the existing `tv80_auto_ss.sv` +
   `auto_save_adaptor2`, or (b) hand-add savestate read/write of the T80 VHDL registers. Decide
   early — it drives most of the risk.
3. **RAM adaptors:** wrap each on-chip BRAM (7F, 7H, VRAM, sprite/obj, palette) with a
   `ram_ss_adaptor` on its currently-spare or muxed second port (DK3's `ram_2048_8` already sits on a
   `dpram` with a free B port — same trick as the hiscore feature). Each gets a unique `SS_IDX`.
4. **Misc register state:** put the control latches (`3E_Q`,`4E_Q`), DMA counters, flip/HV state into
   an `auto_save_adaptor` (flat vector) entry, or hand-list them.
5. **Sound (optional/deferred):** either skip (audio resync) or instrument T65×2 + apu.sv via the
   generator/hand work in a later phase.
6. **Coordinator FSM:** assert `I_PAUSE`, wait for a safe boundary (e.g. VBLANK / CPU not mid-cycle),
   pulse `read_start`/`write_start`, wait `busy` low, release pause. DK3's Z80 needs no SSP-spill
   trick (unlike PGM's M68k).
7. **UI + CONF_STR:** add the savestate slot menu and the gamepad chord / OSD save-load, wire
   `savestate_ui` outputs to the FSM.
8. **Storage:** none to build — the `SS<base>:<size>` token (step 0) makes the HPS persist each
   changed slot to `.ss` automatically. The core only drives `DDRAM_*` into the slot region with the
   payload→size→change-detector-LAST write order (doc 32 §2.3, §7 A.2).

---

## 5. Effort & risk summary

| Item | Effort | Risk |
|---|---|---|
| Port `savestates.sv` + `savestate_ui.sv`, choose transport | medium | low — generic, reusable |
| RAM adaptors on 5+ on-chip BRAMs (unique SS_IDX each) | medium | low–med — mechanical but must cover every RAM |
| Misc latch/DMA/HV register capture | medium | medium — easy to miss a flop ⇒ subtle restore bugs |
| **Main CPU (T80) state** — VHDL, generator can't run | **high** | **high** — swap to tv80 (re-verify) *or* hand-instrument VHDL |
| Coordinator FSM (pause/drain/stream/resume) | medium | medium — must pick a glitch-free pause boundary |
| Storage (HPS buffer or DDR plumbing) | low (B) / high (A) | low (B) / medium (A) |
| Sound (T65×2 + APU×2) full capture | **very high** | **high** — defer; let sound free-run initially |

**The critical path is the CPU register capture**, because DK3's CPUs are VHDL and the PGM
auto-generator is Verilog-only. Everything else (RAM/latch capture, the bus framework, UI) ports
cleanly. A realistic first milestone is a **main-CPU-only savestate with sound left free-running**,
using the BRAM-buffer/HPS transport — then iterate toward full fidelity.

### Files touched (estimate)
- `rtl/savestates.sv`, `rtl/savestate_ui.sv` *(new — ported)*
- `rtl/memory_stream.*` / `ddr_if` *(new — the `DDRAM_*` streamer that writes/reads the framework `SS` slots)*
- `rtl/tv80*` + `rtl/tv80_auto_ss.sv` *(new — only if swapping the Z80 core)*
- `rtl/<ram>_ss_adaptor` wrappers around each BRAM in `rtl/dkong3_*` *(modified RAM instances)*
- `Arcade-DonkeyKong3.sv` *(CONF_STR slots, `savestate_ui`, streamer, ioctl/DDR storage, pause reuse)*
- `rtl/dkong3_top.v`, `rtl/dkong3_main.v`, `rtl/dkong3_video.v`, `rtl/dkong3_sound.v` *(thread ssbus, SS_IDX, pause-to-drain)*

---

## Sources
- [Arcade-IGSPGM_MiSTer — `rtl/savestates.sv`, `rtl/savestate_ui.sv`, `rtl/PGM.sv`, `util/state_module.py`](https://github.com/wickerwaka/Arcade-IGSPGM_MiSTer)
- This repo: `rtl/t80asd_ip/*.vhd` (T80, VHDL), `rtl/t65/*.vhd` (T65, VHDL), `rtl/apu.sv`, `rtl/dkong3_bram.v`, `rtl/dkong3_main.v`.
