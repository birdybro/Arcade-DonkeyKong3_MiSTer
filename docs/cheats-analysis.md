# Implementing Cheats in the DK3 Core

Analysis of how to add a cheat engine to this Donkey Kong 3 core, using the
[Arcade-IremM92_MiSTer](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer) cheat engine as the
implementation reference, plus how MAME's `dkong3` cheats work and how they map onto it.

The cheat engine is a **man-in-the-middle on the CPU read data bus** — it watches the live CPU
address and, when it matches a stored code, substitutes a value into the data the CPU reads. This is
the Game-Genie model: you don't poke RAM, you intercept reads. It is independent of the `.mra` (the
codes arrive over a dedicated download channel, not as a ROM region).

---

## 1. How the IremM92 cheat engine works

### 1.1 The module — `rtl/cheatengine.sv`

```systemverilog
// Code layout:
// {clock bit, code flags,     32'b address, 32'b compare, 32'b replace}
//  128        127:96          95:64         63:32         31:0
module cheatengine_32_16(
   input  clk,           // keep slow-ish for timing
   input  reset,         // pulse before loading a new code set / on new rom
   input  enable,
   output available,     // |next_index — at least one code loaded
   input  [128:0] code,
   input  [ADDR_WIDTH - 1:0] addr_in,
   input  [15:0] data_in,
   output [15:0] data_out
);
parameter ADDR_WIDTH = 16;   // up to 32
parameter MAX_CODES  = 32;
```

Each stored code (`code_t`) holds: `method[1:0]`, `value_mask[3:0]` (which byte lanes are active),
`compare_mask[31:0]`, `value[31:0]`, `compare[31:0]`, and `addr[ADDR_WIDTH-1:0]`.

**Code loading** (sequential, on `clk`):

```systemverilog
code_change <= code[128];
if (code[128] && ~code_change && next_index < MAX_CODES) begin // posedge of clock bit
   case ({code_addr[1:0], code_width[2:0]})            // decode width + byte lane
      ... // builds value/compare/mask for byte / word / dword
   endcase
   codes[next_index].value_mask   <= mask;
   codes[next_index].compare_mask <= code_comp_f ? {expanded mask} : 32'd0; // 0 = unconditional
   codes[next_index].addr  <= code_addr;
   codes[next_index].value <= value;
   codes[next_index].compare <= compare;
   codes[next_index].method <= code_method;
   next_index <= next_index + 1'b1;
end
```

**Substitution** (combinational — this is the actual cheat):

```systemverilog
always_comb begin
   wdi = addr_in[1] ? { data_in, 16'd0 } : { 16'd0, data_in };
   wdo = wdi;
   if (enable) begin
      for (x = 0; x < MAX_CODES; x = x + 1) begin
         if (codes[x].addr[ADDR_WIDTH-1:2] == addr_in[ADDR_WIDTH-1:2]) begin
            compare = (codes[x].compare ^ wdi) & codes[x].compare_mask;
            if ( ~|compare ) begin                       // compare passes (or disabled)
               for (p = 0; p < 4; p = p + 1)
                  if (codes[x].value_mask[p]) case(codes[x].method)
                     1: wdo[8*p +: 8] = codes[x].value[8*p +: 8] | wdi[8*p +: 8]; // OR
                     2: wdo[8*p +: 8] = codes[x].value[8*p +: 8] & wdi[8*p +: 8]; // AND
                     default: wdo[8*p +: 8] = codes[x].value[8*p +: 8];           // replace
                  endcase
            end
         end
      end
   end
   data_out = addr_in[1] ? wdo[31:16] : wdo[15:0];
end
```

Key properties:
- **Compare gating:** if `compare_mask != 0`, the substitution only fires when the bus value equals
  the compare value. This lets a code patch a specific ROM byte only at the intended location
  (Game-Genie 8-letter codes). `compare_mask == 0` ⇒ unconditional (6-letter style).
- **Methods:** replace / OR / AND, per byte lane.
- The matcher is purely combinational, so the patched value appears on the same read cycle.

### 1.2 How it's hooked up (in `rtl/m92.sv`)

**Code download** — codes arrive on the standard HPS `ioctl` download channel at **index 255**,
shifted in a byte at a time, latched every 16th byte:

```systemverilog
wire code_download = ioctl_download && (ioctl_index == 8'd255);
always_ff @(posedge clk_sys) begin
   gg_code[128] <= 1'b0;
   if (code_download & ioctl_wr) begin
      gg_code[127:0] <= { gg_code[119:0], ioctl_dout }; // shift in next byte (big-endian)
      gg_code[128]   <= &ioctl_addr[3:0];               // pulse clock bit on 16th byte
   end
end
```

**Engine instances on the read path** — M92 has separate ROM and RAM read buses, so it uses *two*
engines, each sitting between a read source and the CPU read mux:

```systemverilog
cheatengine_32_16 #(.ADDR_WIDTH(20)) codes_rom (
   .clk(clk_sys), .reset(code_download && ioctl_wr && !ioctl_addr), .enable(1),
   .code(gg_code), .addr_in(cpu_word_addr),
   .data_in(cpu_rom_data),  .data_out(genie_rom_data));

cheatengine_32_16 #(.ADDR_WIDTH(20)) codes_ram (
   .clk(clk_sys), .reset(code_download && ioctl_wr && !ioctl_addr), .enable(1),
   .code(gg_code), .addr_in(cpu_word_addr),
   .data_in(cpu_ram_dout), .data_out(genie_ram_dout));
```

The CPU read mux then consumes the **patched** outputs, never the raw ones:

```systemverilog
else if (cpu_rom_memrq) cpu_mem_in = genie_rom_data;   // patched ROM
else                    cpu_mem_in = genie_ram_dout;   // patched RAM
```

**Menu:** the OSD entry is a single CONF_STR directive (`rtl/m92.sv:245`):

```
"C,Cheats;",
```

This makes the MiSTer firmware show a *Cheats* loader; selecting a cheat file streams its codes to
the core at index 255. `reset` is pulsed at the start of a code download (`!ioctl_addr`), and
`enable` is tied high (cheats active whenever codes are loaded).

---

## 2. How MAME `dkong3` cheats work, and how they map

### 2.1 MAME cheat formats

MAME cheats come in two relevant flavours (see the
[MAME cheat docs](https://docs.mamedev.org/debugger/cheats.html) and
[Pugsy's cheats](https://www.mamecheat.co.uk/)):

- **XML cheats** (modern, `cheat/dkong3.xml` inside the cheat collection). Actions poke memory each
  frame:
  ```xml
  <cheat desc="Infinite Lives">
    <script state="run">
      <action>:maincpu.pb@0xADDR=0xVAL</action>
    </script>
  </cheat>
  ```
  `:maincpu` = the main CPU address space (DK3's **Z80** map), `.pb` = poke byte, `@0xADDR` =
  address, `=0xVAL` = value. A *run* action repeats every frame ⇒ the value is held constant.
- **Game-Genie / Pro-Action-Replay style** = `{address, compare, value}` triples. MAME can ingest
  these via `cheat.simple`; the *compare* field is the address's original value.

For `dkong3` the addresses live in the **Z80 work-RAM** region (the `maincpu` space — DK3 work RAM
7F/7H, roughly `$6000–$6FFF`; the original PCB maps program ROM at `$0000–$3FFF`). The search did not
surface the exact published byte addresses, so those must be obtained (see §5) — but the *shape* of a
DK3 cheat is invariably "hold work-RAM byte X at value V" (lives, bug-spray/insecticide count,
invincibility flag, etc.).

### 2.2 The mapping: MAME poke → MiSTer read-intercept

This is the conceptual bridge:

| MAME | MiSTer cheat engine |
|---|---|
| `:maincpu.pb@ADDR=VAL` repeated every frame (poke RAM) | code `{addr=ADDR, value=VAL, compare disabled, method=replace}` — intercepts every CPU **read** of ADDR and returns VAL |
| Z80 address `ADDR` | `addr_in` match = `W_MCPU_A == ADDR` |
| value `VAL` | `value` (replace method) |
| GG 8-letter "patch ROM byte only if it was X" | `compare = X`, `compare_mask != 0` |

For "lock a RAM value" cheats (the common DK3 case — infinite lives/insecticide), read-interception
is equivalent to per-frame poking **as long as the game reads that RAM byte to use/display it** — it
will see the locked value. It does not *write* RAM, so a value the game only writes-then-trusts
without re-reading wouldn't change; in practice arcade counters are read back, so this works. ROM
patches (changing game code/constants) work directly because the Z80 re-reads ROM each fetch.

The MiSTer wire format is the 16-byte big-endian `{flags, addr(32), compare(32), replace(32)}`
record from §1. So a DK3 conversion of `:maincpu.pb@0x6080=0x05` (illustrative) becomes a code with
`address=0x00006080`, `compare` disabled, `value=0x00000005`, `width=byte`, `method=replace`.

---

## 3. DK3 has a simpler bus than M92 — one tap point

M92 needed two engine instances because ROM and RAM are on different read buses (SDRAM vs BRAM). In
this core, **every read source is OR-combined into a single Z80 read bus** in `rtl/dkong3_main.v`:

```verilog
// dkong3_main.v:94-95
wire [7:0]WO_D = W_MROM_DO | W_MRAM7F_DO | W_MRAM7H_DO | W_SW_DO | I_VRAM_DB;
assign ZDO = WO_D;
```

and `ZDO` feeds the Z80's data input:

```verilog
Z80IP CPU ( ... .DINP(ZDO), ... );   // dkong3_main.v:67-87
```

So a **single 8-bit engine instance** spliced between `WO_D` and `.DINP` covers ROM, work RAM, VRAM
read-back and switch reads at once. `addr_in` is the full 16-bit `W_MCPU_A` — which is exactly the
`maincpu` address space MAME cheats reference. No address translation needed.

(If you ever want to restrict cheats to RAM-only or ROM-only, you can instead tap the individual
`W_MRAM7F_DO`/`W_MROM_DO` legs, mirroring M92's split — but for DK3 the single combined tap is the
clean choice.)

---

## 4. Implementation plan

### Step 0 — Add an 8-bit cheat engine
The M92 engine is `_32_16` (32-bit stored value, 16-bit data bus, 4 byte lanes). DK3's Z80 bus is
8-bit, so add a trimmed **`cheatengine_8`** to `rtl/` (and to `files.qip`). It is the M92 engine with
the byte-lane loop collapsed to a single byte:

```systemverilog
module cheatengine_8 #(parameter ADDR_WIDTH = 16, MAX_CODES = 16) (
   input  clk, reset, enable,
   output available,
   input  [128:0] code,        // same 16-byte wire format as M92
   input  [ADDR_WIDTH-1:0] addr_in,
   input  [7:0] data_in,
   output [7:0] data_out
);
   // store {addr, value[7:0], compare[7:0], compare_en, method[1:0]} per code,
   // loaded on posedge of code[128] exactly like cheatengine_32_16.
   // combinational match:
   //   data_out = data_in;
   //   for each code: if (enable && code.addr==addr_in &&
   //                      (!code.compare_en || code.compare==data_in))
   //        data_out = method==1 ? code.value | data_in
   //                 : method==2 ? code.value & data_in
   //                 :             code.value;
endmodule
```

Keeping the **same 128:0 code wire format** means existing MiSTer code files / the firmware loader
work unchanged; we just ignore the upper bytes of the 32-bit value/compare fields.

### Step 1 — CONF_STR (`Arcade-DonkeyKong3.sv`)
Add the cheats menu directive next to the existing entries (`Arcade-DonkeyKong3.sv:212`):

```verilog
"C,Cheats;",
"-;",
```

Optionally add a status-bit toggle (e.g. `"OX,Cheats,On,Off;"`) and wire it to the engine `enable`
if you want an OSD on/off; M92 just ties `enable` high.

### Step 2 — Code download loader (`Arcade-DonkeyKong3.sv`)
Reuse the M92 shift-in loader verbatim (`ioctl_index == 255`). `clk_sys` here is the 24.576 MHz
`clk_sys`:

```verilog
reg  [128:0] gg_code;
wire         code_download = ioctl_download && (ioctl_index == 8'd255);
always @(posedge clk_sys) begin
   gg_code[128] <= 1'b0;
   if (code_download & ioctl_wr) begin
      gg_code[127:0] <= { gg_code[119:0], ioctl_dout };
      gg_code[128]   <= &ioctl_addr[3:0];
   end
end
```

`ioctl_index` is already wired into the existing `hps_io` instance, so no new HPS port is needed
(unlike the hiscore work, which needed the upload path).

### Step 3 — Thread the code bus into the core
Add ports so the engine can live where the Z80 read bus is. Two options:

- **(A) Engine inside `dkong3_main`** (recommended — it's where `WO_D`/`ZDO` live). Add inputs
  `I_GG_CODE[128:0]`, `I_GG_RESET`, `I_GG_EN` to `dkong3_main` (and pass-throughs in `dkong3_top`),
  driven from `emu`.
- (B) Bring `WO_D` and `W_MCPU_A` up to `emu`, patch there, feed back. More wiring; avoid.

### Step 4 — Splice the engine onto the read bus (`dkong3_main.v`)
Rename the raw bus and insert the engine before the CPU:

```verilog
wire [7:0] WO_D_raw = W_MROM_DO | W_MRAM7F_DO | W_MRAM7H_DO | W_SW_DO | I_VRAM_DB;
wire [7:0] WO_D;     // patched bus into the CPU

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

assign ZDO = WO_D;   // CPU .DINP now sees patched data
```

Drive `I_GG_RESET` with `code_download && ioctl_wr && !ioctl_addr` (start of a new code set) and
`I_GG_EN` with `1'b1` (or the optional status toggle). The match is combinational, adding a tiny
delay on a Z80 read path that has enormous margin at 4 MHz — no timing concern. Clocking the loader
on `I_CLK_24M` follows the M92 "keep it slow-ish" guidance.

### Step 5 — Source / convert the DK3 codes (see §5)

### `.mra` note
No `.mra` change is required for the engine itself. Cheat files are loaded by the MiSTer firmware
from the cheats database, keyed by the `.mra` `<name>`/`setname` (`dkong3`), and streamed at index
255. (Contrast: hiscore needed `<rom index="3">` + `<nvram>` baked into the `.mra`.)

---

## 5. Getting the actual DK3 codes

This is the only DK3-specific research task, and the one with the least certainty:

1. **Find the addresses.** Either pull `dkong3` from Pugsy's MAME XML cheat collection
   (`cheat/dkong3.xml`), or derive them with the MAME debugger: run `mame dkong3 -cheat -debug`,
   watch the work-RAM byte that decrements when you lose a life / use insecticide
   (`wpset`/`find`), and note the Z80 address and the "good" value.
2. **Translate to the MiSTer 16-byte format.** For each cheat build
   `{flags(4B), address(4B, big-endian Z80 addr), compare(4B), value(4B)}`:
   - lock-value cheat → compare disabled, method=replace, width=byte, `value = desired byte`.
   - conditional ROM patch → set compare to the original byte and the compare flag.
3. **Package** the codes as a MiSTer cheat file for `dkong3` so the firmware serves them at index
   255 (the community MiSTer "cheats" database is the normal home; locally you can drop the file in
   the core's cheats folder).

Because the engine speaks the standard MiSTer code format, any correctly-converted `dkong3` cheat
file works without further core changes — adding new cheats later is a data task, not an RTL task.

---

## 6. Effort & risk summary

| Item | Effort | Risk |
|---|---|---|
| `cheatengine_8` module (trim of M92's), add to `files.qip` | low | low — engine logic is simple & combinational |
| CONF_STR `"C,Cheats;"` + optional enable toggle | trivial | none |
| ioctl-255 code loader (copied from M92) | trivial | none |
| Thread code bus into `dkong3_main`, splice on `ZDO` | low | low — single tap, generous Z80 timing |
| Source + convert `dkong3` MAME cheats | medium | **highest** — must find correct Z80 addresses; wrong address = no effect or glitch |

**Critical path:** the RTL is small and low-risk (one combinational MITM on `dkong3_main.v:94-95`).
The real work is *data*: obtaining and converting the `dkong3` cheat addresses (§5). Recommend
standing up the engine with one known-good test code first (e.g. lock the lives byte), verify in
sim/hardware, then expand the cheat file.

### Files touched
- `rtl/cheatengine_8.sv` *(new — trimmed from M92's `cheatengine.sv`)*
- `files.qip` *(add the module)*
- `Arcade-DonkeyKong3.sv` *(CONF_STR `"C,Cheats;"`, code loader, pass `I_GG_*` to the core)*
- `rtl/dkong3_top.v` *(pass-through ports)*
- `rtl/dkong3_main.v` *(rename `WO_D`→`WO_D_raw`, splice `cheatengine_8` before `ZDO`)*

---

## Sources
- [Arcade-IremM92_MiSTer — `rtl/cheatengine.sv` and `rtl/m92.sv`](https://github.com/MiSTer-devel/Arcade-IremM92_MiSTer)
- [MAME Cheat Debugger Commands](https://docs.mamedev.org/debugger/cheats.html)
- [Pugsy's Cheats (MAME XML cheat collection)](https://www.mamecheat.co.uk/)
- [MAME `dkong.cpp` driver (dkong3 hardware/memory map)](https://github.com/mamedev/mame/blob/master/src/mame/nintendo/dkong.cpp)
