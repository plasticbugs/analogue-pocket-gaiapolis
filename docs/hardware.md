# Gaiapolis — Konami "pre-GX" hardware (GX123)

Source of truth: MAME 0.288 `src/mame/konami/mystwarr.cpp`, `mystwarr_v.cpp`,
`konamigx_v.cpp` and the device files listed in §9. Everything here was read out
of that source or measured with the Lua probes in `tools/`.

MAME driver status for `gaiapols`: **`MACHINE_IMPERFECT_GRAPHICS`**, sound
`imperfect`. That matters — see §10.

---

## 1. Board summary

| | |
|---|---|
| Game | Gaiapolis (ver EAF), Konami, 1993 |
| Board | GX123, "pre-GX" family (shared with Mystic Warriors, Violent Storm, Metamorphic Force, Martial Champion, Monster Maulers) |
| Main CPU | MC68000 @ 16.000 MHz (32 MHz / 2) |
| Sound CPU | Z80 @ 8.000 MHz (32 MHz / 4) |
| Sound | 2 × K054539 8-channel PCM/ADPCM @ 18.432 MHz (16 voices total), stereo |
| EEPROM | ER5911, 128 × 8, serial |
| Display | 376 × 224 visible, **ROT90** (vertical monitor → 224 wide × 376 tall) |
| Pixel clock | 8.000 MHz, htotal 512, vtotal 264 → **59.1856 Hz** |
| Palette | 2048 entries, **xRGB_888** (24-bit colour), shadows + highlights enabled |
| ROM total | 18.875 MB across 19 files |

Raster geometry (`set_raw(8000000, 384+24+64+40, 0, 383, 224+16+8+16, 0, 223)`
plus `set_visarea(40, 40+376-1, 16, 16+224-1)`):

```
htotal 512 px  @ 8 MHz  → 64.0 us per line
vtotal 264 lines        → 16.896 ms per frame  (59.1856 Hz)
visible 376 x 224, origin (40, 16)
K053252 CRTC offsets for this game: (40, 16)
```

The raster line runs along the **376-pixel axis**. After ROT90 that axis is
vertical on the cabinet. Sprite/tilemap X is the 376 axis; Y is the 224 axis.

## 2. Custom chip set

| Chip | Function | Notes |
|---|---|---|
| K056832 | Tilemap generator, 4 layers (A/B/C/D) | configured `K056832_BPP_5`, but only 4 planes are populated — see §6 |
| K055673 | Sprite generator (K053246/K053247 family) | layout `K055673_LAYOUT_RNG` (**4bpp**), global offset (dx,dy) = (−61, −22) |
| K055555 | 8-input 5bpp priority encoder / mixer | inputs A,B,C,D + OBJ + SUB1..3 |
| K054338 | Colour mixer: alpha blend, brightness, shadow RGB | |
| K053936-class | PSAC2 rotate/zoom plane ("ROZ", SUB1 input) | driven through `K053936GP_*` helpers in `konamigx_v.cpp` |
| K053252 | CRTC / timing / interrupt controller | 6 MHz input in MAME |
| K054321 | Main↔sound CPU latch (3 × 8-bit) | |
| K054000 | Bounding-box collision protection | |

## 3. Main CPU memory map (`gaiapols_map`)

| Range | Width | Function |
|---|---|---|
| `000000–2FFFFF` | R | Program ROM, 3 MB |
| `400000–40FFFF` | RW | Sprite RAM, **scattered** window (see §4) |
| `410000–411FFF` | RW | K056832 tilemap RAM (8 KB) |
| `412000–413FFF` | RW | K056832 tilemap RAM mirror (**essential**, game reads it) |
| `420000–421FFF` | RW | Palette RAM, 2048 × xRGB_888 (4 bytes/entry) |
| `430000–430007` | W | K055673 / K053246 registers (`k053246_w`) |
| `440000–441FFF` | R | K056832 tile-ROM readback |
| `450000–45000F` | R | K055673 sprite-ROM readback |
| `450010–45001F` | W | K055673 registers |
| `460000–46001F` | W | ROZ control registers (`k053936_0_ct16`) |
| `470000–470FFF` | RW | ROZ line RAM (`k053936_0_li16`), 4 KB |
| `480000–48003F` | W | K056832 VACSET |
| `482000–482007` | W | K056832 VSCCS |
| `484000–484003` | W | ROZ clip window (`ddd_053936_clip_w`) |
| `486000–48601F` | RW | K053252 CRTC (byte, `umask16(0x00ff)`) |
| `488000–4880FF` | W | K055555 registers (48 × 8-bit) |
| `48A000–48A01F` | RW | K054321 sound latch (`umask16(0xff00)`) |
| `48C000–48C01F` | W | K054338 |
| `48E000` | R | `IN0_P1` (bit 3 = test switch) |
| `48E020` | R | `IN1` (high byte) / `P2` (low byte) |
| `600000–60FFFF` | RW | Work RAM, 64 KB |
| `660000–66003F` | RW | K054000 collision (byte) |
| `6A0000` | W | EEPROM out (DI / CS / CLK on bits 0/1/2) |
| `6C0000` | W | ROZ enable (bit 8) + ROZ ROM bank (bits 14–15) |
| `6E0000` | W | Sound IRQ trigger (Z80 IRQ0, HOLD_LINE) |
| `800000–87FFFF` | R | ROZ tilemap readback 0 (`gfx4`+0x20000 / +0x60000, byte-pair) |
| `A00000–A7FFFF` | R | ROZ tilemap readback 1 (`gfx4`, byte at offset/2) |
| `C00000–DFFFFF` | R | ROZ char readback (`gfx3`, banked by ROZ ROM bank) |
| `E00000` | W | Watchdog |

**Interrupt:** a single VBLANK interrupt on **IRQ5** (`ddd_interrupt`,
`HOLD_LINE`). No scanline timer for this game (`scantimer` is removed).

## 4. Sprite RAM scatter

`400000–40FFFF` is a 64 KB window over the K053247's 0x800-word internal RAM:

```
if (offset & 0x0078)  -> plain RAM (shadow)
else                  -> k053247 word ((offset & 7) | ((offset & 0x7f80) >> 4))
```

Inverting it, k053247 word `w` lives at byte address
`0x400000 + ((w & 0x7f8) << 5) + (w & 7) * 2`. `tools/probe_sprites.lua` uses
this to read the live sprite table.

### Sprite entry (8 words per sprite, 256 sprites)

| Word | Contents |
|---|---|
| 0 | bit15 active; bits 11–8 size (`w = 1 << (n & 3)`, `h = 1 << (n >> 2 & 3)` in 16×16 tiles → up to 128×128); bit12 flipx; bit13 flipy; bit14 "use Y zoom for X"; bits 7–0 **z-code** |
| 1 | tile code |
| 2 | Y (10-bit) |
| 3 | X (10-bit) |
| 4 | Y zoom (10-bit; 0x40 = 1:1, smaller = larger) |
| 5 | X zoom (10-bit) |
| 6 | colour/attr; bit14 mirror-X; bit15 mirror-Y; gaiapolis callback: `priority_mask = color & 0xe0`, `color = base | (color >> 4 & 0x20) | (color & 0x1f)` |

Zoom is `zoom = (0x400000 + (raw >> 1)) / raw`, applied as 13.19 fixed point.
**X and Y zoom are independent.**

The K053247 maintains a **per-pixel Z buffer**: a sprite pixel is not drawn over
a pixel with an equal or smaller Z value, regardless of priority. Shadows carry
their host's Z but may take a different priority. Sprites are processed in
Z-code order (ascending or descending per OPSET bit 4 of register 0x0c).

## 5. ROZ / PSAC2 plane (K055555 SUB1 input)

* Virtual plane: 512 × 512 tiles of 16 × 16 px = **8192 × 8192 px**, wraparound on.
* Tile map comes from ROM region `gfx4` (512 KB), not RAM:
  * `dat1 = gfx4 + 0`, `dat2 = gfx4 + 0x20000`, `dat3 = gfx4 + 0x60000`
  * `tile = dat3[i] | ((dat2[i] & 0x3f) << 8)`
  * `colour = (i & 1) ? (dat1[i>>1] & 0xf) : (dat1[i>>1] >> 4) & 0xf`, `|= 0x10 if dat2[i] & 0x80`
* Tile chars come from `gfx3` (1.5 MB), **4bpp 16×16, packed MSB**.
* Per-line transform from the 4 KB line RAM at `470000`; global control at `460000`.
* Clip window from `484000`: `minx = clip_x << 7`, size 1/2/4 × 128 px.
* Enable + a 2-bit ROM bank at `6C0000`.
* Global offset for gaiapolis: `K053936GP_set_offset(0, -10, 0)`.

## 6. Tile layers (K056832)

* 4 layers built from 8 KB of tile RAM, 8 x 8 tiles, pages of 64 x 32 tiles.
* Chip is configured `K056832_BPP_5`, but **gaiapolis tiles are effectively
  4bpp**: only two tile ROMs are loaded and the fifth-plane byte stays 0
  (`ROMREGION_ERASE00`, no `ROM_LOADTILE_BYTE`). The tile callback masks the
  colour to 4 bits: `color = layer_colorbase[layer] | (color >> 2 & 0x0f)`.
* ROM storage. `ROM_LOADTILE_WORD` expands to
  `ROM_GROUPWORD | ROM_SKIP(3) | ROM_REVERSE`, so MAME's 5-byte group is:

  ```
  region[5n+0] = 123e16[2n+1]     region[5n+2] = 123e17[2n+1]
  region[5n+1] = 123e16[2n+0]     region[5n+3] = 123e17[2n+0]
  region[5n+4] = 0                (fifth plane, unused here)
  ```

  Dropping the zero plane, the tile ROM is plain **4bpp packed chunky, MSB
  first, 4 bytes per 8-pixel row** (byte 0 = pixels 0,1; byte 1 = pixels 2,3;
  ...), i.e. 32 bytes per 8x8 tile, 65,536 tiles in 2 MB. `decode_tiles()` in
  `mystwarr_v.cpp` only repacks this into GX planar order for MAME's own
  `drawgfx`; RTL can read the chunky form directly. The raw layout must stay
  intact because the game's self-test reads it back through `440000`.
* Per-layer X offsets for gaiapolis: A -1, B +2, C +4, D +5 (Y all 0).

## 7. Sound

Z80 @ 8 MHz, banked:

| Range | Function |
|---|---|
| `0000–7FFF` | ROM (fixed) |
| `8000–BFFF` | ROM bank, 16 × 16 KB, selected by `sound_ctrl_w` bits 0–3 |
| `C000–DFFF` | RAM (8 KB) |
| `E000–E22F` | K054539 #1 |
| `E230–E3FF` | RAM |
| `E400–E62F` | K054539 #2 |
| `E630–E7FF` | RAM |
| `F000–F003` | K054321 sound side |
| `F800` | `sound_ctrl_w`: bit 4 enables the K054539 timer NMI, bits 0–3 ROM bank |

* Main CPU raises Z80 **IRQ0** by writing `6E0000`.
* K054539 #1's timer output drives the Z80 **NMI** on its rising edge, gated by
  `sound_ctrl` bit 4. **This is what paces the music** — see METHODOLOGY §5.3.
* PCM sample ROM: 4 MB (`k054539` region), shared by both chips.
* MAME applies per-channel gain fix-ups at reset for this driver (chip 1 ch 0–3
  ×0.8, ch 4–7 ×2.0 for mystwarr; gaiapolis uses the `gaiapols` reset override).

## 8. Inputs

4 players, 8-way joystick + 3 buttons each, 2 coin slots.

* `IN0_P1` low byte: bit0 L, bit1 R, bit2 U, bit3 D, bit4 B1, bit5 B2, bit6 B3, bit7 Start1
* `IN0_P1` high byte: bit8 Coin1, bit9 Coin2, bit11 Service Mode, bit12 Service1, bit13 Service2
* `P2`/`P3`/`P4`: same low-byte layout for players 2–4
* `IN1`: bit0 EEPROM DO, bit1 EEPROM READY, bit2 unassigned (reads **0**; the
  game spins on `btst #2,$48e020` at `201248` until it does, right after the
  self-test), bit3 test switch (active low), bit4 mono/stereo (0 = stereo),
  bit5 flip screen (1 = off), bits 6-7 unused (1)
* `IN1`: bit0 EEPROM DO, bit1 EEPROM ready, bit3 service, bit4 Mono/Stereo, bit5 Flip Screen

## 9. ROM map

| File | Size | CRC32 | Region | Offset | Step |
|---|---|---|---|---|---|
| `123e07.24m` | 1 MB | `f1a1db0f` | maincpu | 0 | 2 (even) |
| `123e09.19l` | 1 MB | `4b3b57e7` | maincpu | 1 | 2 (odd) |
| `123eaf11.19p` | 256 KB | `9c324ade` | maincpu | 0x200000 | 2 (even) |
| `123eaf12.17p` | 256 KB | `1dfa14c5` | maincpu | 0x200001 | 2 (odd) |
| `123e13.9c` | 256 KB | `e772f822` | soundcpu | 0 | 1 |
| `123e16.2t` | 1 MB | `a3238200` | k056832 | 0 | 2 |
| `123e17.2x` | 1 MB | `bd0b9fb9` | k056832 | 2 | 2 |
| `123e19.34u` | 2 MB | `219a7c26` | k055673 | 0 | 8 |
| `123e21.34y` | 2 MB | `1888947b` | k055673 | 2 | 8 |
| `123e18.36u` | 2 MB | `3719b6d4` | k055673 | 4 | 8 |
| `123e20.36y` | 2 MB | `490a6f64` | k055673 | 6 | 8 |
| `123e04.32n` | 512 KB | `0d4d5b8b` | gfx3 (ROZ chars) | 0 | 1 |
| `123e05.29n` | 512 KB | `7d123f3e` | gfx3 | 0x80000 | 1 |
| `123e06.26n` | 512 KB | `fa50121e` | gfx3 | 0x100000 | 1 |
| `123e01.36j` | 128 KB | `9dbc9678` | gfx4 (ROZ map) | 0 | 1 |
| `123e02.34j` | 256 KB | `b8e3f500` | gfx4 | 0x20000 | 1 |
| `123e03.36m` | 256 KB | `fde4749f` | gfx4 | 0x60000 | 1 |
| `123e14.2g` | 2 MB | `65dfd3ff` | k054539 (PCM) | 0 | 1 |
| `123e15.2m` | 2 MB | `7017ff07` | k054539 | 0x200000 | 1 |
| `gaiapols.nv` | 128 B | `44c78184` | eeprom | 0 | 1 |

Region totals: maincpu 3 MB, soundcpu 256 KB, k056832 2 MB, k055673 **8 MB**,
gfx3 1.5 MB, gfx4 512 KB (0xA0000 used), k054539 4 MB. **18.875 MB.**

Note the sprite ROMs interleave on an **8-byte stride** — the sprite ROM bus is
64 bits wide on the real board.

## 10. The oracle problem

MAME flags this driver `MACHINE_IMPERFECT_GRAPHICS`. `konamigx_v.cpp`'s mixer —
the software stand-in for the K055555 + K054338 pair — carries explicit
`UNIMPLEMENTED`, `HACK` and "not quite right" comments, and it is a
sort-and-composite software model rather than the per-pixel priority encoder the
real chip is. Captured attract-mode frames in `artifacts/snap/` show blocky
seams around the ROZ/tilemap wipe that are almost certainly MAME artefacts.

Consequence for METHODOLOGY §1: **a reference renderer built to match MAME
cannot be validated to pixel-exactness against real hardware**, because MAME is
not pixel-exact here. Two usable substitutes:

1. Match MAME everywhere the two models agree, and treat disagreements as
   open questions rather than bugs.
2. Prefer Furrtek's silicon reverse-engineering of these Konami parts, and
   jotego's HDL reconstructions derived from it, as the higher authority where
   they exist (see `docs/prior-art.md`).

### Running the MAME oracles

Every `tools/probe_*.lua` and `tools/dump_state.lua` runs the same way; the
output goes to `artifacts/` and MAME's own console must not be piped (that
kills the run):

```sh
mame gaiapols -rompath . -video none -sound none -nothrottle -skip_gameinfo \
     -cfg_directory tmp/cfg -nvram_directory tmp/nvram \
     -autoboot_script tools/probe_z80.lua -autoboot_delay 0 -seconds_to_run 23 \
     > /dev/null 2>&1
```

What the boot looks like from the oracle's side (frames at 59.19 Hz):

* frame 0-66: the Z80 pulls 4096 bytes a frame through K054539 #2's ROM
  port (its first pass), then writes latch 2 = 0x80 and steps `sound_ctrl`
  through banks 2..15 checking its own program (frames 66-171, 6.5 frames a
  bank);
* frames 171-196: latch 2 = 0x81, 0x83, 0x87, 0x97 -- results accumulating;
* frames ~200-915: the PCM checksum, 4360 bytes a frame, chip 1 then chip 2;
  latch 2 = 0x9f at 556, 0xbf then **0x3f at frame 915** -- bit 7 clear;
* the 68000's own phases (`tools/probe_68k.lua`): RAM/ROM checks at
  `201f80`-`202050` until frame 112, the DATA ROM checksum at `201eb8`-`201f64`
  until 153, then the wait for the Z80;
* the 68000 meanwhile sits in the loop at `201da4`: 6144 x 4096 `nop`/`dbf`
  iterations (22 s) polling latch 2 after each 4096, and moves on the moment
  bit 7 drops (`tools/probe_poll.lua` counts the polls: 4-5 a frame, i.e.
  19,300 inner iterations a frame at 14 cycles each -- the pacing target for
  `gaia_main`'s STEP_COST/STEP_GAIN);
* frame ~1207: the EEPROM check (`tools/probe_late.lua` records the pin
  traffic, `tools/eeprom_replay.py` replays it through the model);
* frame ~1320: the results screen gives way to the attract mode, and the
  first sound plays at 22.3 s (`artifacts/gaiapolis_mame_60s.wav`).

### 68000 pacing (gaia_main STEP_COST_BUS / STEP_COST_INT)

TG68K.C is paced by a token bucket: 4 tokens per 16 MHz clock, a bus-cycle
step costs 16 (four clocks, as the 68000's) and an internal step 8. Measured
against MAME with `sim/run_system.sh` (`PACE="-GSTEP_COST_BUS=n
-GSTEP_COST_INT=m"` overrides) on three phases of the boot:

| phase | MAME | 15/15 | 16/8 | 18/8 | 20/4 |
|---|---|---|---|---|---|
| RAM/ROM checks (branchy, write-heavy), frames | 110 | 77 | 77 | 86 | 93 |
| DATA ROM checksum, frames | 41 | 39 | 38 | 43 | 46 |
| `nop`/`dbf` wait loop, iterations a frame | 19,314 | 18,007 | 19,292 | 17,423 | 16,876 |

16/8 is the setting: exact on the fetch-bound loop, within 7% on the
checksum. The check phase runs ~30% fast whatever the costs because TG68K
takes fewer steps than the 68000 spends cycles on taken branches; a
per-instruction refinement is possible if a game phase ever turns out to
depend on it. The Pocket memories' ~12-clock latency sits inside the
24-clock bus step, so the paced rate holds with `LAT=pocket` too.

## 11. Measured load and bandwidth budget

Measured with `tools/probe_sprites.lua` over 5,322 frames (90 s) of attract,
intro and the opening of play; 475 of 887 samples had >= 20 sprites on screen.
Raw data in `artifacts/sprite_load.csv`.

| Per raster line | p50 | p95 | p99 | max |
|---|---|---|---|---|
| sprites crossing the line | 9 | 14 | 17 | **20** |
| destination pixels written | 345 | 856 | 1052 | **2110** |
| source pixels fetched | 288 | 431 | 934 | **1378** |

2110 destination pixels on a 376-pixel line is 5.6x overdraw, which the
per-pixel Z buffer resolves.

### Sprite ROM organisation

`K055673_LAYOUT_RNG` is 16x16, 4bpp, planes at bit offsets {24,16,8,0}, x
offsets 0..7 then 32..39, row stride 64 bits. So **one 64-bit word is one
complete 16-pixel row** of a sprite tile, 128 bytes per tile, and the four
2 MB ROMs interleave on an 8-byte stride precisely because the board's sprite
ROM bus is 64 bits wide.

That makes the fetch cost 4 x 16-bit words per 16 source pixels:

```
worst measured line: 1378 src px / 16 = 87 rows x 4 words = 348 words
```

### Line budget

One line is 512 pixel clocks at 8 MHz = **64.0 us**.

| Consumer | Words / line (worst) | Notes |
|---|---|---|
| Sprites | ~348 | 4 words per 16 px, measured worst case |
| Tilemaps | 376 | 4 layers x 376 px, 4bpp chunky, 2 words per 8 px — deterministic |
| ROZ plane | ~560 | 1 px/clk; map lookup + char byte, worst case with a 1-tile cache |
| 68000 | ~150 | 16 MHz, 4 clk/bus cycle, most cycles hit work RAM in BRAM |
| PCM | ~25 | 16 voices, negligible |

### The partition across the Pocket's memory buses (target/pocket/gaia_mem.sv)

The Pocket exposes **four independent memories** (`dram`, `cram0`, `cram1`,
`sram` in the openFPGA `core_top` port list). What is built:

| Bus | Size | Contents | Used | Access |
|---|---|---|---|---|
| `dram` SDRAM | 32 MB | tiles 2 MB, PCM 4 MB, sprites 8 MB | 14 MB | 2-word bursts (tiles), 4-word bursts (sprite rows), single words (PCM) |
| `cram0` PSRAM | 16 MB | ROZ chars 1.5 MB + ROZ map 640 KB | 2.1 MB | single 16-bit async reads, 12 clocks take to ack |
| `cram1` PSRAM | 16 MB | 68000 program 3 MB + Z80 program 256 KB | 3.25 MB | single 16-bit async reads, 12 clocks; the Z80 has a one-word cache |
| `sram` | 256 KB | K056832 tile RAM, 64K x 16 | 128 KB | single 16-bit async, 6 clocks (read data 42 ns after the address); byte-enabled writes |

Why this way round:

* The 68000 is the one client that wants a *random* access every bus cycle
  (24 clocks at 16 MHz). A PSRAM of its own answers each in 12 clocks with
  no other traffic to queue behind; on the SDRAM it would have taken ~40% of
  the bus by itself. The Z80's fetches share that chip: the two readers
  alternate when both are waiting, so neither waits more than one access of
  the other (12 + 12 = 24, both CPUs' bus cycle), and the Z80 -- a byte of
  a word at a time -- keeps the last word it fetched, so sequential code
  costs the chip one access per two bytes. With fixed 68000 priority and a
  14-clock access the Z80 ran at 74% of its rate in the self-test's sound
  check (`MEM=pocket sim/run_system.sh`: 16.1K steps a frame against 21.8K,
  with six times the wait clocks) and the check took five seconds longer.
  With the alternation, the 12-clock access and the prefetch the Z80 runs
  at 96% of its pace (20.9K steps a frame) and the 68000 gives up 0.3%.
  The read captures 9 clocks (94 ns) after the address strobe, the setting
  the board has answered correctly; the SNES core captures at 81.5 ns
  (7 clocks of 85.9 MHz), so 8 clocks (83 ns) is the next thing to try
  once the memory test says the path is clean.
* The SDRAM is the burst memory: a sprite row is four consecutive words and
  a tile group two, one row activation each. Tiles ~2,100 + sprites ~520 +
  PCM ~160 clocks of the 6,144-clock line.
* The ROZ's map and character reads are single 16-bit words, which is what an
  async PSRAM does natively; ~1,300 clocks per line with the tile cache.
* The tile RAM (128 KB) is the one *RAM* too big for the FPGA: as block RAM
  it needed two copies for its two readers, 2 Mbit of the device's 3.15.
  It lives in the 10 ns SRAM instead, behind one request/ack port shared by
  the K056832's fetch (priority) and the CPU's window (`rtl/ram_arb2.sv`).
  The tilemap fetch is a three-stage pipeline (tile RAM, tile ROM, emit) so
  the ~5-clock SRAM and ~12-clock SDRAM latencies overlap: `sim/run_tilemap.sh`
  with `LATARGS="+LAT_VRAM=5 +LAT_ROM=12"` measures 3,355 clocks a line.

The bench models these latencies (`sim/run_system.sh` with `LAT=pocket`) so
the budgets are measured, not assumed. Every memory holds big-endian 16-bit
words, the packing `sim/tb_system.cpp` uses, so the core sees the same data
in simulation and on the Pocket.

**The load.** The APF loader (`platform/pocket/interface/data_loader.sv`)
hands over one byte per 8 clocks at most, and a PSRAM write costs about 13,
so `gaia_mem` pairs each even byte with the odd one that follows it into a
single 16-bit write before its FIFO (the bridge delivers aligned 4-byte
words, so a pair never straddles a pause). The PSRAM writer acks on *take*,
not completion, so the next word queues while one writes. The core is held
in reset until the first `dataslot_allcomplete`, and the renderers hold
their requests low in reset, so the load has every bus to itself.

**The built-in memory test** (`mem_test` in `gaia_mem.sv`). Every byte of
the image is summed per region as it streams in. When the load completes,
and again on the menu's "Reset Core", the core is held in reset while each
region is read back through the core's own port and summed again, twice: a
region is *ok* if the first pass matched the load, *stable* if the second
pass matched the first, which separates a wrong write from a marginal
read. The tile RAM is then written with a pattern, read back counting bad
words, and cleared. About 2.5 s. The results are the overlay's rows
(below); `sim/run_mem.sh` runs it on 1/64 of each region and checks it
catches a corrupted word. Three menu switches bracket the timing without
a rebuild: "PSRAM slow reads" captures two clocks (21 ns) later than the
94 ns, "SRAM slow reads" one clock later than the 42 ns, "SRAM slow
writes" holds WE low three clocks instead of two and the data a clock
longer; set one, "Reset Core", and read the verdicts again. The first
board run said every ROM region ok and stable but the tile RAM bad, so
the SRAM pins' registers were moved into the IO cells
(`projects/gaia_pocket.qsf`) and the read capture given a fourth clock.

**The overlay** (interact menu "Diagnostic overlay", the bottom 12 lines,
three rows of 32 squares read left to right, green = 1):

| Row | Bits | Meaning |
|---|---|---|
| 0 | 31-24 | frame counter |
| 0 | 23-16 | PLL locked, SDRAM ready, download in progress, all-complete, save loaded, core in reset, IRQ5 this frame, 68000 stepped this frame |
| 0 | 15-8 | core resets seen (counter) |
| 0 | 7-0 | test done, test running, tile RAM ok, tile RAM bad words on a log scale (4: 0 none, n = 2^(n-1) to 2^n - 1, 15 = 16384 or more), Z80 stepped this frame |
| 1 | 31-8 | 68000 address |
| 1 | 7-1 | region read back ok: prog, snd, tile, chr, map, pcm, spr |
| 1 | 0 | sound heard |
| 2 | 31-25 | region read stable: prog, snd, tile, chr, map, pcm, spr |
| 2 | 23-16 | lines that overran their render budget in the last frame |
| 2 | 15-8 | sprites in the draw list, divided by 4 |
| 2 | 7-6 | sticky since reset: a renderer met an unsupported mode; a shadow overlapped a solid |
| 2 | 2-0 | which renderers overran in the last frame: tilemap, ROZ, sprites |

**The pixel hand-over.** The core emits one pixel per 8 MHz enable in the
96 MHz domain; the Pocket takes it on `clk_vid`, the PLL's 8 MHz output
half a system cycle after a system edge. The enable's phase is pinned to
that clock (`clk_enables.sv` `pix_sync`, from a two-flop synchroniser of a
toggle on `clk_vid`), so the colour stage updates two system clocks before
the edge that samples it, whatever the reset phase; `sim/run_pixsync.sh`
checks the alignment and the SDC starts the setup check from that launch
edge. Before this the phase was whatever the reset left, and the analyser
never checked the crossing at its 5.2 ns edge relationship.

`MEM=pocket sim/run_system.sh` runs the whole machine with this module and
behavioural chips in place of the ideal ROM ports, for the interplay the
unit gate cannot see (withdrawn requests, the two CPUs contending).
`sim/run_mem.sh <gaiapolis.rom> [gap]` is the gate for this module: the
memory subsystem with behavioural SDRAM, PSRAM and SRAM chips behind it,
2 KB from each end of every region loaded through the download port at
`gap` clocks a byte (default 8, the loader's maximum) and read back through
every core port, plus the tile RAM's byte lanes and the EEPROM hand-over.
It found the first hardware bug: a port re-arbitrating in the clock its ack
is visible, while the client's request is still standing, ran every access
twice -- harmless for reads, but the writer's second pass carried the *next*
byte, so every word loaded into a PSRAM held its neighbour's data.

### BRAM budget (Cyclone V 5CEBA4: 308 x M10K = 385 KB)

| Block | Size |
|---|---|
| Work RAM | 64 KB |
| Sprite window shadow (the 64 KB the CPU sees at `400000`, 4 KB of it the chip's) | 64 KB |
| K054539 chip RAM, 2 x 32 KB | 64 KB |
| Palette (2048 x 32-bit), two copies for its two readers | 16 KB |
| Sprite RAM (0x800 words), two copies | 8 KB |
| ROZ line RAM | 4 KB |
| Z80 RAM | 9 KB |
| Sprite zoom/reciprocal tables | 9 KB |
| Line buffers (4 tilemap + ROZ + sprite), sprite list | ~14 KB |
| **Subtotal** | **~252 KB** |

The K056832 tile RAM (128 KB) is in the Pocket's SRAM, not here: as block
RAM Quartus needed two copies of it for its two readers, and the whole design
then asked for 4.0 Mbit of the device's 3.15.

### The fit (Cyclone V 5CEBA4, Quartus 18.1)

| | used | of |
|---|---|---|
| Logic (ALMs) | 9,527 | 18,480 (52%) |
| Registers | ~12,100 | 73,920 |
| Block memory | 2.09 Mbit | 3.15 Mbit (66%) |
| DSP blocks | 33 | 66 |

The first fit asked for 174% of the logic: the sprite rasterizer's Z buffers
and the K054539 register files as registers with per-entry muxes. The rules
that brought it to 52% are in `docs/rtl-conventions.md` ("What Quartus will
and will not make a block RAM of"). `projects/output_files/
gaia_pocket.fit.summary` and `.sta.summary` are the numbers to watch; the CI
compile fails the build if a corner's slack goes negative.

### Timing at 96 MHz (projects/gaia_pocket.sdc)

The first fit closed at -7.6 ns. What it took, in order of appearance in
`projects/report_worst.tcl`'s reports:

* arithmetic that was one expression became short pipelines: the K054539's
  volume (table, pan table, product, gain product, cap: one state each), the
  ROZ's control decode and line start, the sprite rasterizer's column offset
  and object geometry, the K054000's compares, the master volume stage;
* multicycle constraints for logic that re-evaluates less than once a clock:
  the scan-out (line buffers, K055555 encoder, palette: once per 8 MHz
  pixel, 4 cycles granted), TG68K to the board (its outputs are sampled
  after gaia_main's three-clock gap: 3), the Z80 and the sound board both
  ways (it steps on cen_8m: 4), plus the kernels' own from the S.T.U.N.
  Runner core;
* the SDRAM clock phase 6.77 ns instead of 5.86: this design's address
  registers sat a few hundred ps further from the pins.

Worst corner after all that: +0.34 ns on the machine clock, +0.30 on the
SDRAM clock, at 52% of the logic.
