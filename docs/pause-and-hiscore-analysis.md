# Implementing Pause & High-Score Saving in DK3

Analysis of how to port the **pause** and **high-score save/restore (NVRAM)** features from the
reference [Arcade-DonkeyKong_MiSTer](https://github.com/MiSTer-devel/Arcade-DonkeyKong_MiSTer) core
into this Donkey Kong 3 core.

The two reference modules — `rtl/pause.v` and `rtl/hiscore.v` — are generic MiSTer-arcade modules
and drop in almost unchanged. The real work is **wiring** them into DK3's clocking and memory map,
which differ from the DK core in a few important ways.

---

## 1. What the reference core does

### 1.1 Pause

The DK core uses the shared `pause` module:

```verilog
module pause #(parameter RW=8, GW=8, BW=8, CLKSPD=12)
(
   input  clk_sys, reset, user_button, pause_request,
   input  [1:0] options,
   input  OSD_STATUS,
   input  [(RW-1):0] r, [(GW-1):0] g, [(BW-1):0] b,
   output pause_cpu,        // assert to halt the game CPU
   output dim_video,        // assert after ~10s to prevent burn-in
   output [(RW+GW+BW-1):0] rgb_out
);
```

Instantiated as:

```verilog
pause #(4,4,4,25) pause (
  .*,
  .reset(reset),
  .user_button(m_pause),
  .pause_request(),
  .options(~status[22:21])
);
```

- `pause_cpu` is fed into `dkong_top`'s `paused` port. Inside `dkong_top`, **pause is realized by
  forcing the Z80 `WAIT_n` low**:

  ```verilog
  .WAIT_n((W_CPU_WAITn | (W_CPU_IORQn & W_CPU_MREQn)) & (~paused)),
  ```

  i.e. when `paused` is high the CPU is held in wait states and stops advancing.
- `options` (OSD bits) select "pause when OSD open" and "dim video after 10s".
- `m_pause` comes from a dedicated joystick button (`joy[8]` in DK).
- The CONF_STR adds:
  ```
  "P1,Pause options;",
  "P1OL,Pause when OSD is open,On,Off;",
  "P1OM,Dim video after 10s,On,Off;",
  ```

### 1.2 High-score saving

The DK core uses the shared `hiscore` module:

```verilog
module hiscore #(
   parameter HS_ADDRESSWIDTH=10, HS_SCOREWIDTH=8,
             HS_CONFIGINDEX=3, HS_DUMPINDEX=4,
             CFG_ADDRESSWIDTH=4, CFG_LENGTHWIDTH=1
)(
   input  clk, paused, reset, autosave,
   input  ioctl_upload, output reg ioctl_upload_req,
   input  ioctl_download, ioctl_wr,
   input  [24:0] ioctl_addr, input [7:0] ioctl_index,
   input  OSD_STATUS,
   input  [7:0] data_from_hps, data_from_ram,
   output [HS_ADDRESSWIDTH-1:0] ram_address,
   output [7:0] data_to_hps, data_to_ram,
   output reg ram_write,
   output ram_intent_read, ram_intent_write,
   output reg pause_cpu,
   output configured
);
```

Instantiated as:

```verilog
hiscore #(.HS_ADDRESSWIDTH(16), .HS_SCOREWIDTH(8),
          .CFG_ADDRESSWIDTH(4), .CFG_LENGTHWIDTH(2)) hi (
   .*,
   .clk(clk_sys),
   .paused(pause_cpu),
   .autosave(status[23]),
   .ram_address(hs_address),
   .data_from_ram(hs_data_out),
   .data_to_ram(hs_data_in),
   .data_from_hps(ioctl_dout),
   .data_to_hps(ioctl_din),
   .ram_write(hs_write_enable),
   .ram_intent_read(hs_access_read),
   .ram_intent_write(hs_access_write),
   .pause_cpu(hs_pause),
   .configured(hs_configured)
);
```

**How it works:**

1. The `.mra` carries a config blob at `<rom index="3">` (the MAME *hiscore.dat* entry for the game)
   and declares `<nvram index="4" size="N">`. For DK: `<nvram index="4" size="179">`.
2. On boot the HPS streams the index-3 config into `hiscore` (`HS_CONFIGINDEX=3`). The config is a
   16-byte timing header followed by table entries; each entry is `{4-byte start address, 1–2 byte
   length, expected start byte, expected end byte}`. The expected bytes let the module wait until the
   game RAM has been initialised before it injects saved scores.
3. The module then drives `ram_address` / `ram_intent_read|write` / `ram_write` to **read or write
   the game's work RAM** through a spare RAM port, asserting `pause_cpu` (→ `hs_pause`) while it
   touches RAM so the CPU can't race it.
4. On OSD-open (and/or `autosave`), it dumps the score region back to the HPS via `data_to_hps` →
   `ioctl_din`, which the HPS persists to a `.nvm` file on the SD card. On next boot the HPS streams
   that `.nvm` back in at `HS_DUMPINDEX=4`.

**RAM integration in `dkong_top`** — the score RAM is given a second access path. Two patterns are
used:

```verilog
// Pattern A: true dual-port RAM, port B dedicated to hiscore
ram_1024_8_8 U_3C4C (
   .I_CLKA(I_CLK_24576M), .I_ADDRA(W_CPU_A[9:0]), .I_DA(WI_D),
   .I_CEA(~W_RAM1_CSn),   .I_WEA(~W_CPU_WRn),     .O_DA(W_RAM1_DO),
   .I_CLKB(I_CLK_24576M), .I_ADDRB(hs_address[9:0]), .I_DB(hs_data_in),
   .I_CEB(hs_cs_RAM1),    .I_WEB(hs_write),          .O_DB(hs_data_out_RAM1)
);

// Pattern B: single-port RAM, address/CE/WE muxed by hs_access
wire hs_access_RAM3 = hs_access & hs_cs_RAM3;
wire [9:0] RAM3_ADDR = hs_access_RAM3 ? hs_address[9:0] : W_CPU_A[9:0];
wire       RAM3_CE   = hs_access_RAM3 ? hs_cs_RAM3      : ~W_RAM3_CSn;
wire       RAM3_WE   = hs_access_RAM3 ? hs_write        : ~W_CPU_WRn;
```

Pattern A is preferred when a free RAM port exists; Pattern B when it doesn't (safe because the CPU
is paused during `hs_access`).

---

## 2. DK3 differences that affect the port

| Concern | DK core | DK3 core (this repo) |
|---|---|---|
| Main CPU clock | Z80 with clock-enable on 24.576 MHz | Z80 (`Z80IP`) on **free-running 4 MHz** `I_CLK_4M`; `WAIT_n` gates it |
| Work RAM clock | 24.576 MHz | `W_CLK_12M` (12 MHz pixel domain) |
| Work RAM | `ram_1024_8` / `ram_1024_8_8` | `ram_2048_8` (7F, **single-port**) and `ram_2048_8_8` (7H, **dual-port, port B already used by sprite DMA**) — see `rtl/dkong3_bram.v`, `rtl/dkong3_main.v` |
| hps_io ports wired | includes `ioctl_din`, `ioctl_upload`, `ioctl_upload_req` | **missing** these (only download path wired) — `Arcade-DonkeyKong3.sv:264` |
| `OSD_STATUS` | input present | input present (`Arcade-DonkeyKong3.sv:182`), currently unused |
| Pause module | present | **absent** |
| hiscore module | present | **absent** |
| Spare joystick button | `joy[8]` = pause | buttons 4–8 already used (Jump/Start1/Start2/Coin/**Test**); pause needs **button 9** |

Two things to confirm before coding:

1. **Where DK3's high-score table lives.** The score config (start addresses) must come from the
   *dkong3* entry of MAME's `hiscore.dat`. DK3's work RAM is 7F and 7H (each 2 KB). The DMA comment
   in `rtl/dkong3_main.v:225` (`transfers $19F bytes from $6900 to $7000`) places 7H around
   `$6800–$6FFF`. The hiscore addresses determine **which** of 7F/7H (or both) must expose a
   hiscore port. Do not guess — pull the real config.
2. **Note that `ram_2048_8` is already a `dpram` with an unused B port** (`rtl/dkong3_bram.v:259`).
   Adding a hiscore port to 7F is therefore cheap: switch `U_7F` to the existing `ram_2048_8_8`
   primitive (which exposes port B) rather than writing new RAM.

---

## 3. Proposed implementation plan

### Step 0 — Bring in the modules
Copy `rtl/pause.v` and `rtl/hiscore.v` from the DK core into `rtl/`, and add both to `files.qip`
(never via the Quartus GUI — see `CLAUDE.md`). They are game-agnostic and need no edits.

### Step 1 — Wire the missing HPS upload path (`Arcade-DonkeyKong3.sv`)
Add the upload/readback signals and ports that the current `hps_io` instance lacks:

```verilog
wire        ioctl_upload;
wire        ioctl_upload_req;
wire  [7:0] ioctl_din;
```
```verilog
hps_io #(.CONF_STR(CONF_STR)) hps_io (
   .clk_sys(clk_sys), .HPS_BUS(HPS_BUS), .EXT_BUS(),
   .buttons(buttons), .status(status),
   .status_menumask({~hs_configured, direct_video}),   // grey out hiscore opts until configured
   .forced_scandoubler(forced_scandoubler),
   .video_rotated(video_rotated), .gamma_bus(gamma_bus),
   .direct_video(direct_video),
   .ioctl_download(ioctl_download),
   .ioctl_upload(ioctl_upload),
   .ioctl_upload_req(ioctl_upload_req),
   .ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr),
   .ioctl_dout(ioctl_dout), .ioctl_din(ioctl_din),
   .ioctl_index(ioctl_index),
   .joystick_0(joy_0), .joystick_1(joy_1)
);
```

### Step 2 — Extend CONF_STR & inputs (`Arcade-DonkeyKong3.sv`)
Add menu entries and a pause button. Pick free status bits (DK uses 21/22/23):

```verilog
"H1ON,Autosave Hiscores,Off,On;",
"P1,Pause options;",
"P1OL,Pause when OSD is open,On,Off;",
"P1OM,Dim video after 10s,On,Off;",
"-;",
...
"J1,Jump,Start 1P,Start 2P,Coin,Test,Pause;",   // add Pause = button bit 9
"jn,A,Start,Select,R,L,X;",
```

```verilog
wire m_pause = joy_0[9] | joy_1[9];
```

Update `status_menumask` so the *Autosave Hiscores* line (the `H1` line) is hidden until
`hs_configured` is asserted.

### Step 3 — Instantiate `pause` (`Arcade-DonkeyKong3.sv`)
DK3's pixel/system clock is 24.576 MHz, so `CLKSPD=25` is correct; RGB is 4-bit:

```verilog
wire pause_cpu, dim_video;
wire hs_pause;

pause #(4,4,4,25) pause (
   .clk_sys(clk_sys),
   .reset(reset),
   .user_button(m_pause),
   .pause_request(hs_pause),    // let hiscore stall the CPU during RAM access
   .options(~status[22:21]),
   .OSD_STATUS(OSD_STATUS),
   .r(r), .g(g), .b(b),
   .pause_cpu(pause_cpu),
   .dim_video(dim_video),
   .rgb_out()                   // optional: feed dimmed RGB to arcade_video instead of {r,g,b}
);
```

To get the dimming effect, route `pause`'s `rgb_out` (or gate `{r,g,b}` with `dim_video`) into the
`arcade_video` `RGB_in` instead of the raw `{r,g,b}`.

### Step 4 — Instantiate `hiscore` (`Arcade-DonkeyKong3.sv`)

```verilog
wire [15:0] hs_address;
wire  [7:0] hs_data_in, hs_data_out;
wire        hs_write_enable, hs_access_read, hs_access_write, hs_configured;

hiscore #(
   .HS_ADDRESSWIDTH(16),
   .HS_SCOREWIDTH(8),
   .CFG_ADDRESSWIDTH(4),
   .CFG_LENGTHWIDTH(2)
) hi (
   .clk(clk_sys),
   .paused(pause_cpu),
   .reset(reset),
   .autosave(status[23]),
   .ioctl_upload(ioctl_upload),
   .ioctl_upload_req(ioctl_upload_req),
   .ioctl_download(ioctl_download),
   .ioctl_wr(ioctl_wr),
   .ioctl_addr(ioctl_addr),
   .ioctl_index(ioctl_index),
   .OSD_STATUS(OSD_STATUS),
   .data_from_hps(ioctl_dout),
   .data_to_hps(ioctl_din),
   .data_from_ram(hs_data_out),
   .data_to_ram(hs_data_in),
   .ram_address(hs_address),
   .ram_write(hs_write_enable),
   .ram_intent_read(hs_access_read),
   .ram_intent_write(hs_access_write),
   .pause_cpu(hs_pause),
   .configured(hs_configured)
);
```

### Step 5 — Thread `paused` + hiscore RAM signals through to the core
`dkong3_top` and `dkong3_main` need new ports:

```verilog
// dkong3_top + dkong3_main: add
input          I_PAUSE,
input  [15:0]  hs_address,
input   [7:0]  hs_data_in,
output  [7:0]  hs_data_out,
input          hs_write,
input          hs_access,   // = hs_access_read | hs_access_write
```

Pass them from `emu`:

```verilog
dkong3_top dkong3 (
   ...,
   .I_PAUSE(pause_cpu),
   .hs_address(hs_address),
   .hs_data_in(hs_data_in),
   .hs_data_out(hs_data_out),
   .hs_write(hs_write_enable),
   .hs_access(hs_access_read | hs_access_write)
);
```

### Step 6 — Gate the Z80 on pause (`dkong3_main.v`)
The CPU's `WAIT_n` is currently `W_MCPU_WAITn` (`rtl/dkong3_main.v:82`). Hold it low while paused:

```verilog
.WAIT_N(W_MCPU_WAITn & ~I_PAUSE),
```

This stalls the Z80 cleanly without touching the free-running clock. **Note:** this pauses only the
main CPU. The two 2A03 sound CPUs (`dkong3_sound.v`, `clk_sub` domain) keep running. That matches
the DK behaviour (visuals/logic freeze) and is usually fine because the game stops issuing new sound
commands; if a looping sound is audible during pause, optionally also gate the sound subsystem
(e.g. hold `I_SUB_RESETn` or freeze the sound CE) — evaluate after testing.

### Step 7 — Give the score RAM a hiscore port (`dkong3_main.v`)
Decode `hs_address` against the work-RAM region(s) that hold the score table (from the config in
Step 9), then expose a port. For **7F** (currently single-port `ram_2048_8` at `U_7F`,
`rtl/dkong3_main.v:180`), promote it to the dual-port primitive and use port B for hiscore — this is
the lowest-risk path because the underlying `dpram` B port is already idle:

```verilog
wire hs_cs_7F = (hs_address[15:11] == 5'b0_1100);  // example: $6000-$67FF — set from real config
wire [7:0] hs_do_7F;

ram_2048_8_8 U_7F (
   // Port A — CPU (unchanged behaviour)
   .I_CLKA(~I_CLK_12M), .I_ADDRA(W_MCPU_A[10:0]), .I_DA(WI_D),
   .I_CEA(~W_MRAM_CS_n[0]), .I_OEA(1'b1), .I_WEA(~W_MCPU_WRn), .O_DA(W_7F_DO),
   // Port B — hiscore, clocked at 24.576 MHz like the hiscore module
   .I_CLKB(I_CLK_24M), .I_ADDRB(hs_address[10:0]), .I_DB(hs_data_in),
   .I_CEB(hs_access & hs_cs_7F), .I_OEB(1'b1), .I_WEB(hs_write), .O_DB(hs_do_7F)
);
```

If the score table also (or instead) lives in **7H**, that RAM's port B is already taken by the
sprite DMA, so use **Pattern B** (mux `hs_address`/CE/WE onto the CPU port — safe because the CPU is
paused during `hs_access`). Combine the per-RAM read-backs:

```verilog
assign hs_data_out = hs_cs_7F ? hs_do_7F : hs_do_7H;
```

`I_CLK_24M` is already available in `dkong3_main` (port at `rtl/dkong3_main.v:11`), so the hiscore
port can run in the HPS clock domain exactly as in the DK core.

### Step 8 — `.mra` changes (`releases/Donkey Kong 3 (US).mra`)
Add, alongside the existing `<rom index="0">`:

```xml
<rom index="3" md5="none">
   <part>
   ...dkong3 hiscore.dat config bytes...
   </part>
</rom>
<nvram index="4" size="N"></nvram>
```

The DK reference for comparison:

```xml
<nvram index="4" size="179"></nvram>
<rom index="3" md5="none">
   <part>
   00 00 00 00 00 FF 00 02 00 02 00 01 00 FF 02 00   <- 16-byte timing header
   00 00 61 00 00 AA 94 76                           <- entry: addr/len/start/end
   ...
   </part>
</rom>
```

`size="N"` must equal the total bytes of the score region(s) the config dumps. The config-byte block
is the *dkong3* stanza from MAME's `hiscore.dat`, re-encoded into the `.mra` `<part>` format.

### Step 9 — Source the DK3 hiscore config
Obtain the `dkong3` entry from MAME's `hiscore.dat` and translate its `start:length` ranges into the
`.mra` `<rom index="3">` table (4-byte address, 2-byte length per `CFG_LENGTHWIDTH=2`, plus
start/end check bytes). These addresses also drive the `hs_cs_*` decodes in Step 7. **This is the
one piece that is genuinely DK3-specific and cannot be copied from the DK core.**

---

## 4. Effort & risk summary

| Item | Effort | Risk |
|---|---|---|
| Copy `pause.v` / `hiscore.v`, add to `files.qip` | trivial | none |
| Pause (CONF_STR, button, `WAIT_n` gate, threading) | low | low — `WAIT_n` gating is clean |
| HPS upload path + `ioctl_din`/upload ports | low | low |
| hiscore module instantiation | low | low |
| Score-RAM dual-porting (7F promote / 7H mux) | medium | medium — must hit the right RAM + clock domain |
| Correct DK3 hiscore config + `.mra` nvram | medium | **highest** — wrong addresses = no save or corruption |
| Optional video dimming via `rgb_out` | low | none |
| Optional sound pause | low | low |

**Critical path:** the only blocker is obtaining the correct *dkong3* high-score memory map
(Step 9), which then fixes the RAM decode (Step 7) and `.mra` (Step 8). Everything else is
mechanical wiring that mirrors the DK core. Recommend bringing up **pause first** (fully
self-contained, immediately testable), then high-score saving.

### Files touched
- `rtl/pause.v`, `rtl/hiscore.v` *(new — copied)*
- `files.qip` *(add the two modules)*
- `Arcade-DonkeyKong3.sv` *(hps_io upload ports, CONF_STR, pause button, `pause` + `hiscore` insts, thread `paused`/hs signals, optional dim)*
- `rtl/dkong3_top.v` *(pass-through ports)*
- `rtl/dkong3_main.v` *(`WAIT_n` gate, score-RAM hiscore port)*
- `releases/Donkey Kong 3 (US).mra` *(`<rom index="3">` config + `<nvram index="4">`)*
