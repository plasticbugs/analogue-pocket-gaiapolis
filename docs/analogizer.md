# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This core supports it (`USE_ANALOGIZER = 1` in `core_top.sv`), wired as
the pocket-core-template does it (template commit 9233037; its
`docs/analogizer-retrofit.md` is the step-by-step this followed). This page
is what the player needs, what the core does, and what has been proven.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; this
core does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL (no scandoubler: below) |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -43 to +32 dots; + moves the picture right on the CRT (with the set on its side, along the game's vertical) |
| Analogizer V Position | -29 to +8 lines; + moves the picture down on the CRT (across the game, with the set on its side) |
| Analogizer H Size | -20% to +19%; + wider. With the set on its side, the game's height |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Stand the CRT on its side.** Gaiapolis's cabinet mounted its monitor
on its side (MAME's ROT90), and the CRT gets the board's raster exactly as
it scanned that monitor: nothing rotates it. Turn the set clockwise as you
face it (top of the set to the right), as MAME's ROT90 does; if the picture
comes out upside down, the other way.

**Width.** A third slider, "Analogizer H Size", makes the
15 kHz picture narrower or wider about its centre, in percent. A CRT has no
digital width: the picture is as wide as its dots take to draw, so the
core plays each line back a little faster or slower. Many consumer sets
have no width control at all, and on a set stood on its side for a
vertical game the width is the game's height. There is no vertical
equivalent: a CRT's height is its sweep, and scaling lines would double
or drop whole scanlines. The scandoubler modes are left alone (a VGA
monitor has its own width control).

The board leaves 32 dots before hsync and 72 after it (less the Y/C colour
burst's 29), so centre the picture first (H Position about -5), then widen
it: +19% is as far as it goes before the edge would reach the sync, and
where H Position and H Size together would put picture on the sync or the
burst, the core crops the edge instead, so the set never loses sync.

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre. They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing.

**Video.** The core sends the board's own signal, at the board's own line
and frame rate -- the timing a 15 kHz arcade monitor or a PVM expects:
376 × 224 visible of 512 × 264 dots at 8 MHz, 15.625 kHz lines, 59.19 Hz.

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |

**No scandoubler.** The adapter can also scandouble for a VGA monitor (with
HQ2x and scanline options), but its line buffers need block RAM this core
does not have: the released Gaiapolis already uses 307 of the FPGA's 308
blocks. So this core builds the adapter without it, as the S.T.U.N. Runner
core does; the 15 kHz modes above are all there is, for a TV, arcade
monitor or PVM.

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Gaiapolis is a two-player game, so the first four rows are the useful ones;
"P1,P2 -> P3,P4" and "P1-P4" put the pads on players the board does not
have. A pad's buttons arrive as the Pocket's own, so they do what the
Pocket's do here: A or Y button 1, B or X button 2, R button 3, Select
coin, Start start. A PlayStation pad in analog mode steers with its left
stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

**Confirmed on a Pocket with an Analogizer and a CRT** (0.3.0). What the bench proves is
listed under *What was measured* below. On a first try: with "Analogizer"
Off the core must play exactly as before -- this build also moves the SDRAM
chip's clock three steps earlier (6.51 → 6.12 ns, so its reads meet timing
with the Analogizer in the design), the one change that reaches the game
itself, so garbled graphics there point at it; then RGBS; then the position
and size sliders, each kept across a reload. Send problems with the adapter
itself to the Analogizer project.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, verbatim but for one local change (modules/VENDOR.md): parameters `USE_YC` and `USE_SD` (default 1 = upstream) leave out the Y/C encoder or the scandoubler, and a mode whose part is left out shows RGBS. This core sets `USE_SD = 0`. Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, position and width stages, Y/C constants, SNAC → controller words. Core-agnostic; the template's file at 9233037, plus parameters forwarding `USE_YC`/`USE_SD` (default 1). |
| `projects/gaia_pocket.qsf` | the short shift registers Quartus had put in block RAM (synchronisers, the Pocket video mixer's scanline generator, the Y/C encoder's delay line) kept in flops, for the RAM; fitter effort AUTO FIT (STANDARD FIT left seed-dependent paths a tenth of a nanosecond short at 99% RAM) |
| `projects/gaia_pocket.sdc` | the SDRAM clock three steps earlier (6.51 → 6.12 ns: its reads missed setup by 0.254 ns with the Analogizer in the fit); a two-clock multicycle into the wrapper's `h_pix`, which samples two clocks after the dot enable, as `VID_OUT` already has for the Pocket's own sample |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the instance (after the bring-up panel; `LINE_LEN` 512, `PIX_LAG` 2), `key1..key4` in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `rtl/gaia_video.sv`, `rtl/gaia_core.sv` | an `hblank` output, delayed one dot like `de`, for the adapter's blanking and the width stage, which time every line from it. Nothing that draws changed. |
| `core_pll` `outclk_4` | the Analogizer's 48 MHz, `clk_sys / 2` in phase (was an unused 96 MHz output); already in the SDC's PLL group. |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, 74–75 signed position sliders at `0xF7000004` and `0xF7000008`, and 76 the width slider at `0xF700000C`. 12 entries, 37 options: within what the firmware loads (`tools/check_json.py`: at most 68 options, 80 options and entries) |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below), at Gaiapolis's raster (the top of `sim/tb_analogizer.sv`) |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x (not built here: shown as RGBS) |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

**The range is the board's blanking.** Moving right, hsync may come
earlier until it meets the end of the picture; moving left, it may come
later until the Y/C colour burst, which ends about 3.5 µs after hsync
does (29 dots at 8 MHz), would reach the picture. Vsync may move either
way until it reaches a picture line. Gaiapolis's raster leaves 32 dots
before hsync (dots 416–447) and 72 after it (480–551, less the burst: 43),
8 lines before vsync (240–247) and 29 after it (251–279, modulo 264),
hence -43..+32 dots and -29..+8 lines. `sim/run_analogizer.sh` tries both
ends of the range in `interact.json` and fails if csync is low while a dot
is drawn or the picture starts inside the burst; one step past each end
fails it.

**Picture width.** `0xF700000C`, a signed slider in percent, scales the
15 kHz picture's width about its centre (`pocket_analogizer`'s width
stage). Each line's dots go into a two-line buffer, six bits a channel,
and the line before is read back during this one, `A × (100 + n) / 100`
clocks long where it was `A`, starting so its centre stays put: nearest
dot, the index advancing by `dots / clocks` (20 fractional bits, from a
divider run once a line) every clock. A dot is held `floor` or `ceil` of
its new length, so at 48 MHz and 8 MHz dots a 10% stretch holds them 6 or 7
clocks. All of a line's measures are the line before's. The picture comes
a line late, so vblank does too and the position stage delays vsync by a
line to match; the picture stays exactly where it was. Off (0), or in a
scandoubler mode, everything passes through as before.

The adapter module takes colour, blanks and syncs only on the *rising edge*
of its pixel enable (`openFPGA_Pocket_Analogizer.v`, "Fix video"). Fed the
source's enable, the scaled picture snapped back to the source's dots: the
bench measured every dot held 7 clocks at ±10%. Scaled, the wrapper makes
its own enable instead: a one-clock pulse whenever the dot, a blank or a
sync changes, delayed a clock if it would follow another directly so the
edge is still there. The bench now sees the 7/8 and 6/7 holds asked for.

A stretched line may run past the source's own next hsync (H Position can
have moved the output's later), so the read finishes the line from the
buffer and vblank latched at its start.

**Never into a sync.** Where H Position and H Size together would put
picture on hsync or on the colour burst after it, the wrapper crops the
picture's edge instead (`KEEP_CB`, from the previous line's hsync), so the
set never loses sync; a player sees an edge go missing and backs off.

**The width range is the blanking** with the picture centred: the
wider picture grows into both porches by half the increase, and a player
centres it with H Position first. The room is the line's whole free
blanking (less hsync and the burst), not just the shorter porch. The bench
centres the picture with H Position the way a player would (clamped to the
menu's range), tries both ends of the width range there (±10% where the
menu has no width entry) and fails if a line is the wrong length, off
centre, missing or reordering dots, a dot is held the wrong time, or the
picture moves vertically; then, at the largest width with H Position at
either end, it fails if csync is ever low while a dot is drawn or the
picture starts inside the colour burst.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so this core uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz. This
core's system clock is 96 MHz, which is more than the cart's level
translators have been asked to pass, so the PLL's spare output gives 48 MHz,
in phase with `clk_sys`. `pocket_analogizer` takes each pixel `PIX_LAG` (2)
system clocks after the dot enable into a holding register and hands it over
with a toggle. Here the colour changes one system clock before `cen_8m` and
the syncs, DE and blanks one after it (`rtl/clk_enables.sv`: the divider is
pinned so the mixer's colour lands two clocks before the Pocket's `clk_vid`
samples it), so a sample two clocks after the enable pairs them exactly as
the Pocket's does. The Analogizer side picks it up two or three of its clocks
later, well inside the dot. A core whose `clk_sys` is already 40–50 MHz can
pass `clk_sys` as both clocks. A core with an unrelated video clock can too,
because the hand-over is a proper synchroniser, but the SDC then needs the two
in separate asynchronous groups.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`. **Wherever a core reads `cont*_key` directly**
(players 3 and 4 often are), read `key*` instead, or SNAC will not reach it.

### What was measured

- `sim/run_analogizer.sh` (PASS): the wrapper and the vendored module at
  Gaiapolis's raster (512 × 264 dots, 376 × 224 visible from dot 40 and
  line 16, hsync 448–479, vsync 248–250, 12 system clocks or 6 Analogizer
  clocks a dot), read at the cartridge pins as the DAC reads them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of every Analogizer list in the package's `interact.json`
    (27), set as the firmware sets a masked entry, read back the word as
    the bridge samples it, merged and written: the word, the adapter's copy
    and the enable each followed.
  - RGBS: all 84,224 visible dots of a frame reach the DAC pins, in raster
    order, as their top six bits per channel, 0 differing; csync one
    32-dot pulse a line.
  - Scandoubler: not built (`USE_SD = 0`): each of its five mode values
    shows the RGBS picture instead, all 84,224 dots, 0 differing.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled; the blank bit; enable off again returns the port to idle.
  - Position at both ends of the shipped sliders (+32,+8 and -43,-29):
    csync moves by exactly 192 and 258 clocks (32 and 43 dots) and 8 and 29
    lines, never low while a dot is drawn, clear of the colour burst; the
    picture is every dot, 0 differing. Jumps
    written just after a pulse (V +8 to +4, H +32 to -1, V +4 to 0, H +32
    to 0) leave csync out of the picture for three frames. One step past
    each end (+33,+9 and -44,-30) fails the bench.
  - Width, centred by H Position -5 (32 dots before hsync, 43 clear after
    it): +19% and -20% give 224 lines of 2,685 and 1,805 clocks (asked
    2,685 and 1,805), centred to the clock, every dot from the first to the
    last in order, held 7 or 8 (4 or 5) clocks, the lines as far from vsync
    as at 0; at +19% with H Position at +32 and -43, csync is never low in
    the picture and the burst is clear (the crop). +20% fails: the line is
    cropped to 2,698 clocks.
- `sim/lint.sh`: clean, the machine with the new `hblank` port and the
  wrapper with the vendored module (whose warnings are dropped by path).
- The core's own gates, nothing that draws having changed: `sim/run_frame.sh`
  on 10 frozen states (attract, busy, play, play2, select, stage, intro,
  bird, and the attract object and ROZ layers), every full frame matching
  the reference renderer; `sim/run_pixsync.sh` 699 checks, 0 errors;
  `sim/run_system.sh` 30 frames from reset, no overrun lines.
- `tools/check_json.py`: clean (12 entries, 37 options, 2 data slots).
- Quartus 18.1: fits in 13,017 ALMs (70%), 305 of 308 RAM blocks and 37
  DSP blocks (the v0.2.2 release: 11,762, 307 and 31; the scandoubler left
  out and the short shift registers moved to flops pay for the
  Analogizer's RAM). No negative slack at any corner: worst setup +0.127 ns
  (slow 0C, the SDRAM read capture after its clock moved 6.51 → 6.12 ns;
  the release had +0.427), worst hold +0.112 ns (fast 0C; release +0.103);
  SDRAM capture hold +0.594 ns, outputs +3.0 ns or more; `h_pix` +4.9 ns
  under its two-clock multicycle. Every constraint in `gaia_pocket.sdc`
  applies except the `pal_rd_q` multicycle, which matched nothing in the
  release build either. Fitter effort AUTO FIT: STANDARD FIT left paths a
  tenth of a nanosecond short that moved with the seed.

**Not proven:** anything on hardware with this core; that the firmware
writes a signed slider as two's complement (the other cores' sliders are
the same kind); the SNAC serial protocols, which are the adapter module's
and are forced at its outputs in the bench rather than driven over the
pins; Y/C and YPbPr against any reference, only a run without unknowns.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, and take the seven menu entries
(ids 70–76) and `cartridge_adapter: 0` out of the JSON. `general[4]` was in
the SDC's PLL group before the Analogizer, as an unused output; with the
Analogizer off it drives nothing again.
