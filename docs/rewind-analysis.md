# Implementing Rewind in the DK3 Core

Analysis of how rewind is achieved in [GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer) and
how it could be implemented here.

**Bottom line up front:** rewind is **not a new state-capture mechanism — it is a thin scheduler
layered on top of savestates.** The savestate engine does all the heavy lifting (serialize the whole
machine to a memory region and restore it); rewind just (1) keeps a **ring buffer** of recent
snapshots, (2) writes a new one on a **timer**, and (3) on a button hold, steps the ring **backwards**
and reloads. Therefore rewind in DK3 is **entirely dependent on Feature 4 (Savestates)** — it cannot
exist without it, and it specifically requires the *fast local* (DDR/SDRAM/BRAM) savestate transport,
not the SD-card file path. The good news: DK3's snapshot is tiny, so a long rewind history costs very
little memory.

---

## 1. How the GBA core does it

### 1.1 The scheduler — `rtl/gba_statemanager.vhd`

A single small process on `clk100` that drives the savestate engine through four signals:

```vhdl
request_savestate : out std_logic;   -- "save now"
request_loadstate : out std_logic;   -- "load now"
request_address   : out integer;     -- where in memory
request_busy      : in  std_logic;   -- engine busy?
```

It manages **two memory regions** (generics):

```vhdl
Softmap_SaveState_ADDR  -- manual save slots: base + savestate_number * SAVESTATESIZE
Softmap_Rewind_ADDR     -- rewind ring: base + savestatepos * SAVESTATESIZE
```

with these constants:

```vhdl
SAVESTATESIZE : integer := 16#20000#; -- 512 KB per snapshot
REWIND_COUNT  : integer := 64;        -- ring of 64 snapshots
TIME_CAPTURE  : integer := 100000000; -- 1 second  @ 100 MHz  -> capture interval
TIME_REWIND   : integer := 50000000;  -- 500 ms              -> playback step interval
```

### 1.2 The three behaviours

**Manual save/load** (the Feature-4 path): edge-detect `save`/`load`, then when the engine is idle
(`request_busy = '0'`) issue a request to `Softmap_SaveState_ADDR + savestate_number*SAVESTATESIZE`.

**Rewind capture** (ring writer): while `rewind_on = '1'`,
- on first enable, capture an initial snapshot into ring slot 0 and set `savestatecount=1`,
  `savestatepos=1`;
- thereafter, **every `TIME_CAPTURE` (1 s)**, capture into `Softmap_Rewind_ADDR + savestatepos*SIZE`,
  advance `savestatepos` circularly (wrap at `REWIND_COUNT`), and grow `savestatecount` up to 64.

So the ring always holds the **last ~64 seconds** of game state, overwriting the oldest.

**Rewind playback** (ring reader): while `rewind_active = '1'` (the Rewind button held),
- `timer_rewind` is held at 0 (no new captures while rewinding);
- **every `TIME_REWIND` (500 ms)** step `savestatepos` **backwards** (wrap), decrement
  `savestatecount`, and `request_loadstate` from that slot — playing snapshots in reverse.

```vhdl
elsif (rewind_enabled = '1' and rewind_slow = TIME_REWIND) then
   if (savestatecount > 1) then
      savestatecount <= savestatecount - 1;
      if (savestatepos > 0) then savestatepos <= savestatepos - 1;
      else savestatepos <= REWIND_COUNT - 1; end if;
      rewind_load_next <= '1';
   end if;
   rewind_slow <= 0;
elsif (rewind_load_next = '1') then
   request_address   <= Softmap_Rewind_ADDR + (savestatepos * SAVESTATESIZE);
   request_loadstate <= '1';
```

**Freeze between loads** — `sleep_rewind` is asserted after 2 vsyncs while rewinding so the core
holds on the displayed frame between reloads (and is reset on each load):

```vhdl
sleep_rewind <= '0';
if (vsync_counter = 2 and rewind_active = '1') then sleep_rewind <= '1'; end if;
```

### 1.3 Top-level wiring (`GBA.sv`)

- CONF_STR: a capture toggle and a Rewind button + info text:
  ```
  "P3O[27],Rewind Capture,Off,On;",
  "J1,...,FastForward,Rewind,Savestates;",
  "Rewinding...;",
  ```
- `.rewind_on(status[27])`, `.rewind_active(status[27] & joy[11])`, `.savestate_number(ss_slot)`.
- Memory map: `Softmap_SaveState_ADDR(58720256)` (one region) and
  `Softmap_Rewind_ADDR(33554432)` (64 × 512 KB ring) — both in the large DDR/SDRAM the GBA core
  already uses.
- Pause interaction: when rewind capture is on, the core deliberately does **not** pause on OSD-open,
  so capture keeps running (`pause <= ... & ~status[27]`).
- `savestate_ui.sv` already exposes `joyRewind` / `rewindEnable` inputs and a "Rewinding…" info text —
  the same UI module the savestate feature uses.

### 1.4 The essential insight

```
savestate engine (Feature 4)  ──drives──▶  serialize/restore whole machine to memory[addr]
        ▲ request_savestate / request_loadstate / request_address / request_busy
        │
gba_statemanager (rewind)  =  ring-buffer pointer + capture timer + playback timer + sleep
```

Rewind adds **no new state plumbing** — only a pointer, two timers, and a second memory region.

---

## 2. What this means for DK3

### 2.1 Hard dependency on Savestates (Feature 4)
Rewind reuses the Feature-4 savestate engine verbatim (the ssbus collection + the streamer). **Do not
attempt rewind before savestates work.** Specifically, rewind needs the savestate engine to expose a
"save/load to address N, are you busy?" handshake — i.e. the same `request_*`/`busy` contract GBA's
`save_state_data`-style streamer provides. (PGM's `save_state_data` already has
`read_start`/`write_start`/`index`/`busy` — that maps directly.)

### 2.2 Transport: rewind forces the *fast local* path
The Savestate analysis offered two transports: **Option A (DDR)** and **Option B (HPS `.ss` file)**.
**Rewind is incompatible with Option B** — you cannot push a snapshot through the SD-card file system
once per second, let alone read them back at 2 Hz during playback. Rewind requires a fast,
randomly-addressable local memory ring:
- **DDR3** (recommended) — DK3's `emu` wrapper already exposes unused `DDRAM_*` ports
  (`Arcade-DonkeyKong3.sv:124-133`); a rewind ring lives there comfortably.
- **On-chip BRAM** — viable only for a *short* ring, because DK3's M10K is mostly used. See sizing.

**Implication:** if rewind is a goal, build Feature 4 with the **DDR transport (Option A)** rather
than the HPS-file transport. (Manual savestates can still also write an SD file; rewind uses the DDR
ring.)

### 2.3 Sizing — rewind is *cheap* for DK3
GBA snapshots are 512 KB each ⇒ a 64-slot ring is 32 MB (needs DDR). DK3's pragmatic snapshot (main
Z80 regs + work/video/sprite/palette RAM + latches) is on the order of **a few KB**. So:
- A 64-slot ring (≈64 s history at 1 capture/s) is only a few **hundred KB** — trivial in DDR, and a
  short ring (8–16 slots ≈ 8–16 s) could even fit on-chip BRAM if you wanted to avoid DDR entirely.
- You can afford a **finer capture cadence** (e.g. every 0.5 s or every 30 frames) for smoother
  rewind without memory pressure.

### 2.4 Timer/clock specifics
GBA times in `clk100` cycles. For DK3, count in the chosen savestate-engine clock domain
(`clk_sys` = 24.576 MHz) or, more robustly, count **VBLANK pulses** (60/s) — capture every N vblanks,
play back every M vblanks. Counting frames is cleaner than raw cycles and naturally aligns capture to
a safe (VBLANK) boundary.

---

## 3. DK3 implementation sketch

Add a small **`dkong3_statemanager`** (port of `gba_statemanager` logic) between `savestate_ui` and
the Feature-4 savestate streamer:

```
savestate_ui ──ss_save/ss_load/ss_slot, joyRewind, rewindEnable──▶ dkong3_statemanager
                                                                      │ request_savestate/loadstate
                                                                      │ request_address (slot in DDR ring or manual region)
                                                                      │ request_busy ◀── streamer
                                                                      ▼
                                            Feature-4 streamer (ssbus + DDR memory_stream)
```

- **Two regions** in the DDR savestate area: a manual-slot region (`base + slot*SIZE`) and a rewind
  ring (`rewind_base + pos*SIZE`, `REWIND_COUNT` slots).
- **Capture timer:** every N VBLANKs while `rewind_on`, assert `request_savestate` at the ring's write
  pointer, advance the pointer circularly, grow count up to `REWIND_COUNT`.
- **Playback timer:** while `rewind_active` (Rewind button held), every M VBLANKs step the pointer
  back and assert `request_loadstate`.
- **Freeze:** assert a `sleep_rewind`-equivalent that holds the core (reuse the Feature-1 `I_PAUSE`
  gate) between reloads so the screen shows each rewound frame.
- **Don't capture while rewinding** (hold the capture timer at 0 during `rewind_active`).

`savestate_ui.sv` (ported in Feature 4) already provides `joyRewind`/`rewindEnable` inputs and the
"Rewinding…" info text, so the UI side needs only the CONF_STR toggle + Rewind button.

---

## 4. Effort & risk summary

| Item | Effort | Risk |
|---|---|---|
| **Prerequisite: Feature 4 savestates with DDR transport** | (see savestates doc) | **gating** — rewind can't start until this works |
| Port `gba_statemanager` logic → `dkong3_statemanager` (pointer + 2 timers + sleep) | low–med | low — small, self-contained FSM |
| Allocate DDR rewind-ring region + manual-slot region | low | low — DK3 snapshots are tiny |
| Capture/playback cadence by VBLANK counting | low | low |
| Freeze-between-loads via `I_PAUSE` reuse | low | med — pick a clean boundary; avoid tearing |
| CONF_STR "Rewind Capture" toggle + Rewind button; wire `savestate_ui` rewind inputs | low | low |
| Ensure capture window fits the pause budget (snapshot small ⇒ fine) | low | low |

**The entire risk is upstream:** rewind itself is a tiny ring-buffer scheduler. Its only real
requirement is that **Feature 4 exists and uses a fast local (DDR) transport with a
`request/busy` handshake**. If savestates ship with the HPS-file transport (Option B), rewind will
require adding the DDR path first.

### Files touched
- `rtl/dkong3_statemanager.v(hd)` *(new — ported from `gba_statemanager.vhd`)*
- `rtl/savestates.sv` / streamer *(ensure `request_savestate/loadstate/address/busy` + DDR region
  addressing are exposed — Feature 4)*
- `Arcade-DonkeyKong3.sv` *(CONF_STR "Rewind Capture" + Rewind button; instantiate `dkong3_statemanager`
  between `savestate_ui` and the streamer; DDR memory-map constants for the ring; keep capturing when
  OSD opens)*
- `files.qip` *(add the statemanager)*

---

## Sources
- [GBA_MiSTer — `rtl/gba_statemanager.vhd`, `rtl/savestate_ui.sv`, `GBA.sv`](https://github.com/MiSTer-devel/GBA_MiSTer)
- Companion docs in this repo: [`docs/savestates-analysis.md`](savestates-analysis.md) (the prerequisite).
