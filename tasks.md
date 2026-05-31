# Implementation Tasks: Pause, Hiscore Saving, Cheats

Actionable checklist for adding **pause**, **high-score saving (NVRAM)**, and **cheats** to the
Donkey Kong 3 core. Derived from:
- [`docs/pause-and-hiscore-analysis.md`](docs/pause-and-hiscore-analysis.md)
- [`docs/cheats-analysis.md`](docs/cheats-analysis.md)

Reference cores: pause/hiscore ← [Arcade-DonkeyKong_MiSTer](https://github.com/MiSTer-devel/Arcade-DonkeyKong_MiSTer),
cheats ← [Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer).

## Conventions & ground rules
- [ ] Never add HDL files through the Quartus GUI — add every new `.v`/`.sv` to `files.qip` manually
      (see `CLAUDE.md`).
- [ ] All three features need free `status[]` bits and free joystick button bits. Allocate them once,
      up front, to avoid collisions (see **Bit allocation** below).
- [ ] Build with Quartus 17.0.2 Lite (`Arcade-DonkeyKong3.qpf`); re-check timing after CPU/video edits.
- [ ] Recommended order: **Pause → Hiscore → Cheats** (pause is a dependency of hiscore; cheats are
      independent but smallest).

### Bit allocation (decide first, fill in actual values)
- [ ] `status[0]` = Reset (existing). Existing used bits per `Arcade-DonkeyKong3.sv:212-229`:
      2 (orientation), 3-5 (scandoubler), 7 (flip), 19-20 (aspect, `OJK`), 24-28 (H-pos `OOS`),
      29-31 (V-pos `OTV`).
- [ ] Pause: pick 2 free bits for options (DK uses 21,22) → e.g. `status[22:21]`.
- [ ] Hiscore: pick 1 free bit for autosave (DK uses 23) → e.g. `status[23]`.
- [ ] Cheats: optional 1 bit for on/off toggle, or tie `enable` high.
- [ ] Joystick: pause needs a new button. Current `J1` uses bits 4-8 (Jump/Start1/Start2/Coin/Test,
      `Arcade-DonkeyKong3.sv:226`). Add **Pause = bit 9**.

---

## FEATURE 1 — PAUSE

Reference: `rtl/pause.v`. Mechanism in DK3: hold the Z80 `WAIT_n` low while paused
(`dkong3_main.v:82`). Fully self-contained and testable on its own.

### 1.1 Bring in the module
- [ ] Copy `rtl/pause.v` from the DK core into `rtl/pause.v` (no edits needed — game-agnostic).
- [ ] Add `set_global_assignment -name VERILOG_FILE rtl/pause.v` to `files.qip`.

### 1.2 CONF_STR + input (`Arcade-DonkeyKong3.sv`)
- [ ] Add menu lines to `CONF_STR` (around line 212-229):
      ```
      "P1,Pause options;",
      "P1OL,Pause when OSD is open,On,Off;",
      "P1OM,Dim video after 10s,On,Off;",
      ```
- [ ] Add `Pause` to the `J1` button list and `jn`:
      ```
      "J1,Jump,Start 1P,Start 2P,Coin,Test,Pause;",
      "jn,A,Start,Select,R,L,X;",
      ```
- [ ] Declare the pause button signal:
      ```verilog
      wire m_pause = joy_0[9] | joy_1[9];
      ```

### 1.3 Instantiate `pause` (`Arcade-DonkeyKong3.sv`)
- [ ] Declare signals:
      ```verilog
      wire pause_cpu, dim_video;
      wire hs_pause;          // driven by hiscore in Feature 2; tie 1'b0 until then
      ```
- [ ] Instantiate (CLKSPD=25 for the 24.576 MHz clk_sys; RGB is 4-bit):
      ```verilog
      pause #(4,4,4,25) pause (
         .clk_sys(clk_sys),
         .reset(reset),
         .user_button(m_pause),
         .pause_request(hs_pause),     // 1'b0 placeholder until hiscore is wired
         .options(~status[22:21]),
         .OSD_STATUS(OSD_STATUS),
         .r(r), .g(g), .b(b),
         .pause_cpu(pause_cpu),
         .dim_video(dim_video),
         .rgb_out()
      );
      ```

### 1.4 Thread `paused` into the core
- [ ] Add `input I_PAUSE,` to `dkong3_top` port list (`rtl/dkong3_top.v`).
- [ ] Add `input I_PAUSE,` to `dkong3_main` port list (`rtl/dkong3_main.v`).
- [ ] In `dkong3_top`, pass `I_PAUSE` down into the `dkong3_main maincpu (...)` instance.
- [ ] In `emu`, connect `.I_PAUSE(pause_cpu)` on the `dkong3_top dkong3 (...)` instance
      (`Arcade-DonkeyKong3.sv:411`).

### 1.5 Gate the Z80 (`rtl/dkong3_main.v`)
- [ ] Change the CPU `WAIT_N` connection (line 82) from `.WAIT_N(W_MCPU_WAITn)` to:
      ```verilog
      .WAIT_N(W_MCPU_WAITn & ~I_PAUSE),
      ```

### 1.6 (Optional) Video dimming
- [ ] Route `pause`'s `rgb_out` (or gate `{r,g,b}` with `dim_video`) into `arcade_video`'s `RGB_in`
      instead of raw `{r,g,b}` (`Arcade-DonkeyKong3.sv:349-363`).

### 1.7 (Optional) Pause sound too
- [ ] Evaluate after testing: if a looping sound is audible during pause, also freeze the sound
      subsystem (`dkong3_sound.v`, `clk_sub` domain) — e.g. hold its CE or `I_SUB_RESETn`. The two
      2A03 CPUs are NOT gated by `WAIT_n`, so by default they keep running.

### 1.8 Test pause
- [ ] Build; in-game press the Pause button → game freezes, audio behaves as expected.
- [ ] Open OSD → verify "Pause when OSD is open" option works.
- [ ] Leave paused ~10s → verify "Dim video after 10s" dims the screen.

---

## FEATURE 2 — HIGH-SCORE SAVING (NVRAM)

Reference: `rtl/hiscore.v`. Depends on Feature 1 (`pause_cpu`). Requires the HPS **upload** path that
the current `hps_io` instance lacks, plus a dual-port path into the score work-RAM, plus a DK3-specific
config in the `.mra`.

### 2.1 Bring in the module
- [ ] Copy `rtl/hiscore.v` from the DK core into `rtl/hiscore.v` (no edits — game-agnostic).
- [ ] Add `set_global_assignment -name VERILOG_FILE rtl/hiscore.v` to `files.qip`.

### 2.2 Add the missing HPS upload path (`Arcade-DonkeyKong3.sv`)
The current `hps_io` (line 264) only wires the download path. Add:
- [ ] Declare:
      ```verilog
      wire        ioctl_upload;
      wire        ioctl_upload_req;
      wire  [7:0] ioctl_din;
      ```
- [ ] Add these ports to the `hps_io` instance:
      ```verilog
      .ioctl_upload(ioctl_upload),
      .ioctl_upload_req(ioctl_upload_req),
      .ioctl_din(ioctl_din),
      ```
- [ ] Update `status_menumask` to hide the autosave option until configured:
      ```verilog
      .status_menumask({~hs_configured, direct_video}),
      ```
      (adjust the `H`-line index in CONF_STR to match the menumask bit; DK uses `H1`/`H2`.)

### 2.3 CONF_STR (`Arcade-DonkeyKong3.sv`)
- [ ] Add the autosave toggle (gated by the menumask bit chosen above):
      ```
      "H1ON,Autosave Hiscores,Off,On;",
      ```

### 2.4 Instantiate `hiscore` (`Arcade-DonkeyKong3.sv`)
- [ ] Declare signals:
      ```verilog
      wire [15:0] hs_address;
      wire  [7:0] hs_data_in, hs_data_out;
      wire        hs_write_enable, hs_access_read, hs_access_write, hs_configured;
      ```
- [ ] Instantiate:
      ```verilog
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
- [ ] Confirm `hs_pause` is wired into `pause`'s `.pause_request(hs_pause)` (replace the 1'b0
      placeholder from 1.3) so hiscore can stall the CPU during RAM access.

### 2.5 Thread hiscore RAM signals into the core
- [ ] Add ports to `dkong3_top` AND `dkong3_main`:
      ```verilog
      input  [15:0]  hs_address,
      input   [7:0]  hs_data_in,
      output  [7:0]  hs_data_out,
      input          hs_write,
      input          hs_access,
      ```
- [ ] In `dkong3_top`, pass them through to `dkong3_main`.
- [ ] In `emu`, connect on the `dkong3_top dkong3 (...)` instance:
      ```verilog
      .hs_address(hs_address),
      .hs_data_in(hs_data_in),
      .hs_data_out(hs_data_out),
      .hs_write(hs_write_enable),
      .hs_access(hs_access_read | hs_access_write),
      ```

### 2.6 Give the score work-RAM a hiscore port (`rtl/dkong3_main.v`)
Depends on knowing WHICH work RAM holds the score table (Task 2.8). `ram_2048_8` (used for 7F,
line 180) is already a `dpram` with a free B port; promote it to the dual-port primitive.
- [ ] Decode `hs_address` against the score-RAM region (example shown; set range from 2.8):
      ```verilog
      wire hs_cs_7F = (hs_address[15:11] == 5'b0_1100);  // e.g. $6000-$67FF — fix per real config
      ```
- [ ] Replace the `ram_2048_8 U_7F` instance with `ram_2048_8_8`, port A = CPU (unchanged), port B =
      hiscore clocked on `I_CLK_24M`:
      ```verilog
      ram_2048_8_8 U_7F (
         .I_CLKA(~I_CLK_12M), .I_ADDRA(W_MCPU_A[10:0]), .I_DA(WI_D),
         .I_CEA(~W_MRAM_CS_n[0]), .I_OEA(1'b1), .I_WEA(~W_MCPU_WRn), .O_DA(W_7F_DO),
         .I_CLKB(I_CLK_24M), .I_ADDRB(hs_address[10:0]), .I_DB(hs_data_in),
         .I_CEB(hs_access & hs_cs_7F), .I_OEB(1'b1), .I_WEB(hs_write), .O_DB(hs_do_7F)
      );
      ```
- [ ] If the score table is (also) in 7H (already dual-port, port B used by sprite DMA): use the
      mux pattern instead (safe because the CPU is paused during `hs_access`):
      ```verilog
      wire        hs_acc_7H = hs_access & hs_cs_7H;
      wire [10:0] a7h = hs_acc_7H ? hs_address[10:0] : W_MCPU_A[10:0];
      wire        ce7h = hs_acc_7H ? 1'b1            : ~W_MRAM_CS_n[1];
      wire        we7h = hs_acc_7H ? hs_write        : ~W_MCPU_WRn;
      // ...feed a7h/ce7h/we7h into U_7H port A; B stays DMA.
      ```
- [ ] Combine read-back into `hs_data_out`:
      ```verilog
      assign hs_data_out = hs_cs_7F ? hs_do_7F : hs_do_7H;
      ```

### 2.7 `.mra` config (`releases/Donkey Kong 3 (US).mra`)
- [ ] Add a hiscore config blob and nvram element alongside `<rom index="0">`:
      ```xml
      <rom index="3" md5="none">
         <part>
         ...dkong3 hiscore config bytes (from 2.8)...
         </part>
      </rom>
      <nvram index="4" size="N"></nvram>
      ```
- [ ] Set `size="N"` = total bytes of the dumped score region(s).
- [ ] Reference (DK core): `<nvram index="4" size="179">`; config header is 16 bytes then per-entry
      `{4-byte addr, length, start-check, end-check}`.

### 2.8 Source the DK3-specific hiscore config  ⚠️ critical/blocking
- [ ] Obtain the `dkong3` stanza from MAME's `hiscore.dat`.
- [ ] Translate its `start:length` ranges into the `<rom index="3">` table format
      (4-byte address, 2-byte length per `CFG_LENGTHWIDTH=2`, start/end check bytes).
- [ ] Use the same addresses to set the `hs_cs_*` decode(s) in Task 2.6 (identify whether scores
      live in 7F `$6000-$67FF`, 7H `$6800-$6FFF`, or both — DMA comment at `dkong3_main.v:225`
      places 7H near `$6800-$6FFF`).

### 2.9 Test hiscore
- [ ] Build. Play, set a high score, power-cycle (or reload) → score persists.
- [ ] Verify `configured` deasserts the autosave menu line until the config + RAM init complete.
- [ ] Verify save-on-OSD-open and `autosave` both produce a `.nvm` on the SD card.
- [ ] Verify no CPU glitches when hiscore accesses RAM (it pauses via `hs_pause`).

---

## FEATURE 3 — CHEATS

Reference: `rtl/cheatengine.sv` (`cheatengine_32_16`). Independent of pause/hiscore. Mechanism in
DK3: a single 8-bit man-in-the-middle on the combined Z80 read bus `WO_D`/`ZDO`
(`dkong3_main.v:94-95`). Codes download at `ioctl_index == 255`.

### 3.1 Add an 8-bit cheat engine
- [ ] Create `rtl/cheatengine_8.sv` — a trim of the M92 `cheatengine_32_16` with the byte-lane loop
      collapsed to a single 8-bit lane. Keep the **same 128:0 code wire format** so existing MiSTer
      cheat files / firmware loader work unchanged.
      ```systemverilog
      module cheatengine_8 #(parameter ADDR_WIDTH = 16, MAX_CODES = 16) (
         input  clk, reset, enable,
         output available,
         input  [128:0] code,          // {clk bit, flags, 32b addr, 32b compare, 32b replace}
         input  [ADDR_WIDTH-1:0] addr_in,
         input  [7:0] data_in,
         output [7:0] data_out
      );
      // load on posedge of code[128] (same as M92); store {addr, value[7:0], compare[7:0],
      //   compare_en, method[1:0]} per code.
      // combinational:
      //   data_out = data_in;
      //   foreach code: if (enable && code.addr==addr_in &&
      //                     (!code.compare_en || code.compare==data_in))
      //       data_out = method==1 ? code.value | data_in
      //                : method==2 ? code.value & data_in
      //                :             code.value;
      endmodule
      ```
- [ ] Add `set_global_assignment -name SYSTEMVERILOG_FILE rtl/cheatengine_8.sv` to `files.qip`.
- [ ] (Alternative) Reuse M92's `cheatengine_32_16` verbatim with `ADDR_WIDTH(16)` if maximal
      fidelity is preferred over logic savings — note its `addr_in[1]` word-lane handling is awkward
      for the 8-bit Z80; the `_8` trim is recommended.

### 3.2 CONF_STR (`Arcade-DonkeyKong3.sv`)
- [ ] Add the cheats menu directive (near line 212-229):
      ```
      "C,Cheats;",
      "-;",
      ```
- [ ] (Optional) Add an enable toggle, e.g. `"OX,Cheats,On,Off;"`, wired to the engine `enable`.

### 3.3 Code-download loader (`Arcade-DonkeyKong3.sv`)
- [ ] Copy the M92 loader verbatim (`ioctl_index` already wired; no new HPS port needed):
      ```verilog
      reg  [128:0] gg_code;
      wire         code_download = ioctl_download && (ioctl_index == 8'd255);
      always @(posedge clk_sys) begin
         gg_code[128] <= 1'b0;
         if (code_download & ioctl_wr) begin
            gg_code[127:0] <= { gg_code[119:0], ioctl_dout };  // shift in (big-endian)
            gg_code[128]   <= &ioctl_addr[3:0];                // pulse on 16th byte
         end
      end
      ```

### 3.4 Thread the code bus into the core
- [ ] Add ports to `dkong3_top` AND `dkong3_main`:
      ```verilog
      input  [128:0] I_GG_CODE,
      input          I_GG_RESET,
      input          I_GG_EN,
      ```
- [ ] In `dkong3_top`, pass them through to `dkong3_main`.
- [ ] In `emu`, connect on the `dkong3_top dkong3 (...)` instance:
      ```verilog
      .I_GG_CODE(gg_code),
      .I_GG_RESET(code_download && ioctl_wr && !ioctl_addr),
      .I_GG_EN(1'b1),     // or the optional status toggle
      ```

### 3.5 Splice the engine onto the read bus (`rtl/dkong3_main.v`)
- [ ] Rename the raw read bus (line 94) and insert the engine before `ZDO`:
      ```verilog
      wire [7:0] WO_D_raw = W_MROM_DO | W_MRAM7F_DO | W_MRAM7H_DO | W_SW_DO | I_VRAM_DB;
      wire [7:0] WO_D;
      cheatengine_8 #(.ADDR_WIDTH(16)) cheats (
         .clk(I_CLK_24M),
         .reset(I_GG_RESET),
         .enable(I_GG_EN),
         .available(),
         .code(I_GG_CODE),
         .addr_in(W_MCPU_A),
         .data_in(WO_D_raw),
         .data_out(WO_D)
      );
      assign ZDO = WO_D;     // CPU .DINP now sees patched data
      ```
- [ ] Confirm timing: the match is combinational on a 4 MHz Z80 read path with large margin — re-run
      timing analysis but no fix is expected.

### 3.6 Source / convert DK3 codes  ⚠️ highest-uncertainty
- [ ] Find addresses: pull `dkong3` from Pugsy's MAME XML cheat collection (`cheat/dkong3.xml`), or
      derive via `mame dkong3 -cheat -debug` (watch the work-RAM byte that decrements on life loss /
      insecticide use; note the Z80 address + good value).
- [ ] Translate each cheat to the 16-byte MiSTer format `{flags, addr(32, big-endian Z80 addr),
      compare(32), value(32)}`:
      - lock-value cheat → compare disabled, method=replace, width=byte, `value = desired byte`.
      - conditional ROM patch → set `compare` = original byte + compare flag.
- [ ] Package as a MiSTer cheat file keyed by `setname` `dkong3` (community cheats DB, or local
      cheats folder) so the firmware serves codes at index 255.
- [ ] Note: NO `.mra` change is needed for cheats (unlike hiscore).

### 3.7 Test cheats
- [ ] Build. Load a single known-good test code (e.g. lock the lives byte) → verify the effect
      in-game.
- [ ] Verify behavior with cheats off (toggle, if added) and with no cheat file loaded (engine inert).
- [ ] Expand the cheat file with the remaining converted codes.

---

## FEATURE 4 — SAVESTATES

Reference: [Arcade-IGSPGM_MiSTer](https://github.com/wickerwaka/Arcade-IGSPGM_MiSTer) — `rtl/savestates.sv`,
`rtl/savestate_ui.sv`, `rtl/PGM.sv`, `util/state_module.py`. Full analysis in
[`docs/savestates-analysis.md`](docs/savestates-analysis.md).

> ⚠️ **Scope warning.** This is far larger than Features 1-3. A savestate must capture *every*
> flip-flop and RAM in the machine. Do Features 1-3 first; savestates **reuse the `I_PAUSE` gate
> from Feature 1**. DK3 has two obstacles PGM did not: its CPUs (T80, T65) are **VHDL** so the
> Verilog-only auto-generator can't instrument them, and the NES APU is highly stateful. Plan in
> phases and ship a reduced-scope first version.

### 4.0 Decisions to make first (blocking, affects everything below)
- [ ] **Scope:** v1 = capture **main Z80 + all work/video/sprite/palette RAM + control latches/DMA/HV
      state**; **let the two 6502+APU sound subsystems free-run** (brief audio glitch on restore, no
      gameplay error). Document "sound state not restored" in the UI. Full sound capture = later phase.
- [ ] **Main-CPU state strategy** (the critical-path decision):
      - Option (a) **Swap `T80as` → `tv80s`** (Verilog; PGM ships a ready `tv80_auto_ss.sv` +
        `auto_save_adaptor2`). Most faithful to the reference, but re-verify CPU timing/cycle behaviour.
      - Option (b) **Hand-instrument the T80 VHDL** to expose its registers on the ssbus. No core swap,
        but large/error-prone.
- [ ] **Transport:** Option B (recommended for DK3's small state) = stream the snapshot to/from the
      HPS over `ioctl_upload`/`ioctl_download` into a `.ss` file (same mechanism as hiscore `.nvm`),
      no DDR. Option A (PGM-faithful) = port `memory_stream`/`ddr_if`/`ddr_mux` and drive the
      currently-unused `DDRAM_*` wrapper ports, 4 MB/slot.

### 4.1 Port the savestate framework
- [ ] Copy `rtl/savestates.sv` (interface `ssbus_if`, `ssbus_mux`, `auto_save_adaptor`,
      `auto_save_adaptor2`, `save_state_data`) into `rtl/`.
- [ ] Copy `rtl/savestate_ui.sv` into `rtl/`.
- [ ] Copy the RAM adaptor module(s) (`ram_ss_adaptor`; the M68k-specific `m68k_ram_ss_adaptor` is not
      needed for DK3's 8-bit RAMs — use/derive a plain 8-bit `ram_ss_adaptor`).
- [ ] If Option A (DDR): also port `memory_stream`, `ddr_if`, `ddr_mux`, and the relevant `sys/ddr_svc`
      pieces. If Option B (HPS): replace `save_state_data`'s DDR `memory_stream` with an
      ioctl-upload/download streamer.
- [ ] Add all new files to `files.qip`.

### 4.2 Define the savestate device map
- [ ] Allocate a unique `SS_IDX` per device. Minimum v1 set:
      `SSIDX_Z80`, `SSIDX_RAM_7F`, `SSIDX_RAM_7H`, `SSIDX_VRAM`, `SSIDX_OBJRAM`, `SSIDX_PALRAM`,
      `SSIDX_MISC` (latches `3E_Q`/`4E_Q`, DMA counters, flip/HV state), plus `SSIDX_GLOBAL` scratch
      if needed.
- [ ] Instantiate `ssbus_if ssb[N]()` and `ssbus_mux #(.COUNT(N))` in the core (e.g. `dkong3_top` or a
      new `dkong3_ss` wrapper) connecting all `ssb[*]` to the streamer's `ssbus`.

### 4.3 Main CPU state (per 4.0 decision)
- [ ] **Option (a):** replace the `Z80IP`/`T80as` instance in `dkong3_main.v` with `tv80s`; add the
      `auto_ss_*` ports; add the generated `tv80_auto_ss.sv` to `files.qip`; instantiate
      `auto_save_adaptor2 #(.SS_IDX(SSIDX_Z80))` and wire it to the tv80 `auto_ss_*` ports
      (mirror `rtl/PGM.sv:915-952`). Re-verify Z80 behaviour against the current T80.
- [ ] **Option (b):** add savestate read/write ports to the T80 VHDL exposing its architectural
      registers; wire to an adaptor. (Large; only if avoiding the core swap.)

### 4.4 RAM adaptors (wrap every captured BRAM)
- [ ] Wrap each on-chip RAM with a `ram_ss_adaptor` on a second/muxed port, each with its `SS_IDX`.
      DK3's `ram_2048_8` already sits on a `dpram` with a free B port (same trick as hiscore Task 2.6):
      - [ ] `U_7F` (work RAM, `dkong3_main.v:180`)
      - [ ] `U_7H` (work RAM / DMA, `dkong3_main.v:202` — port B used by DMA; mux savestate access while paused)
      - [ ] VRAM (`dkong3_vram.v`)
      - [ ] sprite/object RAM (`dkong3_obj.v`)
      - [ ] palette RAM (`dkong3_col_pal.v`)
- [ ] For each adaptor: during normal run it passes the game's port through; during ssbus access
      (CPU paused) it drives the RAM from the streamer. Confirm `count`/`width` reported via `setup()`.

### 4.5 Misc register state
- [ ] Concatenate non-RAM game-visible flops — control latches `3E_Q` (8b) / `4E_Q` (4b), DMA
      address/state, `flip`/HV-related regs, sub-reset latch — into one `auto_save_adaptor`
      (`SS_IDX = SSIDX_MISC`) `bits_in`/`bits_out` vector. Double-check nothing game-visible is missed.

### 4.6 Coordinator FSM
- [ ] Build an `ss_state` FSM (model on `rtl/PGM.sv`, but **no M68k SSP-spill trick needed** — the Z80
      exposes its regs directly):
      1. On `ss_save`/`ss_load`, assert `I_PAUSE` (reuse Feature 1's `WAIT_n` gate).
      2. Wait for a safe boundary (e.g. VBLANK and CPU not mid-bus-cycle) to avoid a torn snapshot.
      3. Pulse `write_start` (save) or `read_start` (load) on `save_state_data`; wait `busy` low.
      4. Release `I_PAUSE`.
- [ ] Ensure the Z80 `WAIT_n` pause and the streamer's RAM access don't collide (RAM adaptors assume
      the CPU is paused during ssbus access).

### 4.7 Storage transport
- [ ] **Option B (HPS file):** assign a savestate `ioctl_index`; on save, stream the collected
      snapshot to the HPS via `ioctl_upload`/`ioctl_din` into a `.ss` file; on load, stream it back via
      `ioctl_download`. Reuse the upload-path ports added for hiscore (Task 2.2).
- [ ] **Option A (DDR):** drive the `emu` wrapper's `DDRAM_*` ports (`Arcade-DonkeyKong3.sv:129-138`,
      currently unused) from the ported `ddr_if`/`memory_stream`; one DDR region per slot
      (`SS_DDR_BASE + slot*4MB`).

### 4.8 UI + CONF_STR (`Arcade-DonkeyKong3.sv`)
- [ ] Add savestate menu lines (model on PGM):
      ```
      "O[NN:MM],Savestate Slot,1,2,3,4;",
      "O[KK],Autoincrement Slot,Off,On;",
      ```
      (allocate free `status[]` bits — coordinate with the Feature 1-3 bit map at top of this file.)
- [ ] Instantiate `savestate_ui #(.INFO_TIMEOUT_BITS(25))`; wire PS/2 `ps2_key`, the gamepad SS chord
      (hold button + D-pad), `status_slot`, `OSD_saveload`, and outputs `ss_save`/`ss_load`/
      `selected_slot` into the coordinator FSM.
- [ ] Add a dedicated savestate modifier button to `J1`/`jn` (joySS), or reuse an existing combo.

### 4.9 Test savestates
- [ ] Build. Save in slot 1 mid-game, change state, load slot 1 → exact game state restored
      (sprites, score, RAM, CPU regs).
- [ ] Verify multi-slot and autoincrement.
- [ ] Verify a save/load survives a brief audio glitch only (sound free-runs in v1).
- [ ] Verify no visual tearing/crash from the pause boundary choice (4.6 step 2).
- [ ] (Later phases) add T65×2 + APU×2 capture for full sound-state fidelity.

---

## FEATURE 5 — REWIND

Reference: [GBA_MiSTer](https://github.com/MiSTer-devel/GBA_MiSTer) — `rtl/gba_statemanager.vhd`,
`GBA.sv`. Full analysis in [`docs/rewind-analysis.md`](docs/rewind-analysis.md).

> ⚠️ **Rewind is a thin ring-buffer scheduler on top of Savestates — it adds NO new state capture.**
> It is **100% dependent on Feature 4**, and specifically requires Feature 4's **DDR transport
> (Option A)** with a `request_save/load/address/busy` handshake — the SD-card file path (Option B)
> is too slow to capture once per second. Build Feature 4 (DDR variant) first.

### 5.0 Prerequisite check (blocking)
- [ ] Feature 4 savestates working with a **fast local (DDR) transport**, exposing a
      save/load-to-address-N + busy handshake (model on PGM's `save_state_data`:
      `write_start`/`read_start`/`index`/`busy`). If Feature 4 shipped with Option B (HPS file), add
      the DDR path before starting rewind.

### 5.1 Port the rewind scheduler
- [ ] Create `rtl/dkong3_statemanager.v(hd)` from `gba_statemanager.vhd` — a small FSM with:
      - edge-detected manual `save`/`load` → request at `manual_base + slot*SIZE`;
      - a **capture timer** and a **ring write pointer** (`savestatepos`, `savestatecount`,
        `REWIND_COUNT`);
      - a **playback timer** that steps the pointer backwards on `rewind_active`;
      - `request_savestate`/`request_loadstate`/`request_address`/`request_busy` to the streamer;
      - a `sleep_rewind` output to freeze the core between loads.
- [ ] Add to `files.qip`.

### 5.2 Retime for DK3 (VBLANK counting)
- [ ] Replace GBA's `clk100` cycle constants with **VBLANK-pulse counts** (DK3 ≈60 Hz):
      `TIME_CAPTURE` → every N vblanks (e.g. 60 = 1 s, or 30 = 0.5 s for smoother rewind);
      `TIME_REWIND` → every M vblanks for playback step. Feed the core's VBLANK
      (`O_VBLANK` / `W_VBLANKn`) as the tick.
- [ ] Counting VBLANKs also aligns captures to a safe boundary automatically.

### 5.3 Memory map (DDR rewind ring)
- [ ] Allocate two regions in the savestate DDR area: the **manual-slot region**
      (`manual_base + slot*SS_SIZE`) and the **rewind ring** (`rewind_base + pos*SS_SIZE`,
      `REWIND_COUNT` slots). DK3 snapshots are a few KB, so even a 64-slot ring is well under 1 MB —
      pick `REWIND_COUNT` freely (64 ≈ history length × capture interval).
- [ ] (Alternative) For a *short* ring (8–16 slots) an on-chip BRAM ring is possible, avoiding DDR
      entirely — note the M10K cost.

### 5.4 Freeze-between-loads
- [ ] Wire `sleep_rewind` into the **Feature-1 `I_PAUSE`** path (OR it in) so the core holds each
      rewound frame between reloads; reset the freeze on each load (mirror GBA's `vsync_counter`).
- [ ] Do **not** capture while `rewind_active` (hold the capture timer at 0).

### 5.5 CONF_STR + inputs (`Arcade-DonkeyKong3.sv`)
- [ ] Add the capture toggle (allocate a free `status[]` bit, coordinate with the bit map at top):
      ```
      "O[RR],Rewind Capture,Off,On;",
      "Rewinding...;",
      ```
- [ ] Add a **Rewind** button to `J1`/`jn` (GBA uses a dedicated joy bit).
- [ ] Wire `savestate_ui`'s already-present `joyRewind` and `rewindEnable` inputs (ported in
      Feature 4) to the Rewind button and the capture-toggle status bit.
- [ ] `.rewind_on(status[RR])`, `.rewind_active(status[RR] & m_rewind)` into `dkong3_statemanager`.
- [ ] Keep capturing when the OSD is open (do NOT pause-on-OSD while rewind capture is on — mirror
      GBA's `pause <= ... & ~rewind_on`).

### 5.6 Test rewind
- [ ] Enable Rewind Capture; play ~30 s; hold Rewind → game visibly steps backward through recent
      states at the playback cadence.
- [ ] Release Rewind → play resumes from the rewound point; new captures continue.
- [ ] Verify the ring wraps (history bounded to `REWIND_COUNT × capture interval`) with no crash.
- [ ] Verify capture doesn't visibly hitch gameplay (snapshot is small; pause window is brief).

---

## Cross-feature integration notes
- [ ] `pause_cpu` is shared: it gates the Z80 (Feature 1) AND is the `paused` input to `hiscore`
      (Feature 2). `hs_pause` feeds back into `pause.pause_request`. Wire this loop once.
- [ ] `ioctl_index` routing summary (no collisions): `0` = ROM (existing), `3` = hiscore config,
      `4` = nvram dump, `254` = DIP (existing, `Arcade-DonkeyKong3.sv:337`), `255` = cheats.
- [ ] `OSD_STATUS` (already a port, `Arcade-DonkeyKong3.sv:182`, currently unused) is consumed by
      both `pause` and `hiscore`.
- [ ] `dkong3_main` gains ports for all four features (`I_PAUSE`, the `hs_*` group, the `I_GG_*`
      group, the savestate `ssbus`/`SS_IDX` group); update `dkong3_top` pass-throughs and the `emu`
      instance once for all of them.
- [ ] **`I_PAUSE` is reused by savestates** (Feature 4 asserts it to drain the CPU before snapshotting)
      — build Feature 1 first.
- [ ] **The hiscore upload path (Task 2.2: `ioctl_upload`/`ioctl_upload_req`/`ioctl_din`) is reused by
      the savestate HPS transport** (Feature 4, Option B) — build Feature 2 first if taking Option B.
- [ ] **The free `dpram` B-port trick** is used by both hiscore (Task 2.6) and savestate RAM adaptors
      (Task 4.4) — a RAM serving both must share/arbitrate that port (both only access while paused).
- [ ] **Rewind (Feature 5) reuses the savestate engine + `I_PAUSE`** and forces Feature 4's **DDR
      transport** — if savestates ship with the HPS-file transport (Option B), add the DDR path before
      rewind. Rewind adds only a ring-buffer scheduler, no new state capture.
- [ ] `ioctl_index` routing summary (no collisions): `0` = ROM (existing), `3` = hiscore config,
      `4` = nvram dump, `254` = DIP (existing, `Arcade-DonkeyKong3.sv:337`), `255` = cheats,
      `<pick a free index>` = savestate file (Feature 4 Option B; not used by rewind).

## Files touched (all five features)
- [ ] `rtl/pause.v` *(new — copied)*
- [ ] `rtl/hiscore.v` *(new — copied)*
- [ ] `rtl/cheatengine_8.sv` *(new — trimmed from M92)*
- [ ] `rtl/savestates.sv`, `rtl/savestate_ui.sv`, `ram_ss_adaptor` *(new — ported from PGM)*
- [ ] `rtl/memory_stream.*` / `ddr_if` / `ddr_mux` *(new — Feature 4 Option A/DDR; required for Feature 5)*
- [ ] `rtl/tv80*` + `rtl/tv80_auto_ss.sv` *(new — Feature 4 Option (a), if swapping the Z80 core)*
- [ ] `rtl/dkong3_statemanager.v(hd)` *(new — ported from `gba_statemanager.vhd`, Feature 5)*
- [ ] `files.qip` *(add all new modules)*
- [ ] `Arcade-DonkeyKong3.sv` *(CONF_STR, buttons, hps_io upload ports, pause/hiscore/cheat/savestate/rewind insts + loaders, thread signals to core)*
- [ ] `rtl/dkong3_top.v` *(pass-through ports for all five; possibly host the ssbus/mux)*
- [ ] `rtl/dkong3_main.v` *(`WAIT_n` gate; score-RAM dual-port; cheat engine splice on `ZDO`; CPU + RAM savestate adaptors)*
- [ ] `rtl/dkong3_video.v`, `rtl/dkong3_obj.v`, `rtl/dkong3_vram.v`, `rtl/dkong3_col_pal.v` *(savestate RAM adaptors — Feature 4)*
- [ ] `releases/Donkey Kong 3 (US).mra` *(hiscore `<rom index="3">` + `<nvram>` only)*

## Critical-path / blocking items
- [ ] **Hiscore:** the `dkong3` `hiscore.dat` config + correct score-RAM addresses (Task 2.8).
- [ ] **Cheats:** the converted `dkong3` cheat codes (Task 3.6).
- [ ] **Savestates:** the main-CPU state strategy (Task 4.0) — DK3's T80/T65 are **VHDL**, so the
      Verilog auto-generator can't instrument them; either swap T80→tv80s (re-verify) or hand-instrument.
      This is the dominant risk/effort item; everything else (RAM/latch capture, bus framework, UI)
      ports cleanly.
- [ ] **Rewind:** depends entirely on Feature 4 using the **DDR transport** with a request/busy
      handshake (Task 5.0). Rewind itself is a small ring-buffer scheduler (low risk); the gating cost
      is the Feature-4 DDR savestate path.
- [ ] **Recommended sequencing:** Pause → Hiscore → Cheats → Savestates (DDR variant) → Rewind.
      Savestates reuse the pause gate; Rewind reuses the savestate engine + pause gate + DDR transport.
- [ ] Everything else is mechanical wiring that mirrors the reference cores.
