# Gaiapolis — Analogue Pocket core (openFPGA)

Gaiapolis (Konami, 1993) on Konami "pre-GX" GX123 hardware, for the Analogue
Pocket via openFPGA/opengateware.

**Status: release v0.1.0 -- the game runs on the Pocket.** The whole machine
is in gateware: the 68000 and the Z80 sound board with its two K054539s, the
ER5911 EEPROM, the K054000, and the video chain (K056832 tilemaps, K053936
rotating plane, K053247 sprites, K055555 mixer). It boots through its
self-test with every item OK, into the attract mode with music, and plays.
On the board every memory reads back its region of the image (the core checks
at each load) and the three renderers hold their line budgets with the real
memories through the scenes exercised so far; the build uses 58% of the
logic and 68% of the block RAM with timing closed at 96 MHz.

| RTL, frame 1400 | MAME, frame 1400 | self-test |
|---|---|---|
| ![RTL attract](artifacts/system/attract_f1400.png) | ![MAME attract](artifacts/system/attract_mame_f1400.png) | ![self-test, every item OK](artifacts/system/selftest_all_ok.png) |

## Trying it on the Pocket

Tagged releases publish `gaia-pocket-sdcard.zip`; every push to `main` also
compiles the core (`.github/workflows/compile.yml`) and uploads the package
as the `gaia-pocket` workflow artifact. Unzip it onto the SD card root, build
`gaiapols.rom` as described below (or in the package's `README.txt`), put it
in `Assets/gaia/common/`, and the core loads it on launch without asking.
Settings and records go to `gaiapols.sav`. `./build-local.sh` does the same
compile in Docker and leaves the package in `release/pocket/`.

At each load the core holds the game for about 2.5 s while it reads every
memory back against the image it just received; the screen is black for
that time. The core menu offers the screen shape (the arcade 3:4 monitor or
square pixels), scanlines, a shadow mask, and the board's test-mode switch
(the game's own service menu).

## How it is verified

The reference renderer (`tools/render_model.py`) reproduces MAME's output
exactly, full frames including shadows, on a corpus of frozen machine
states (`tools/regress_render.sh`: 28 gates, zero differing pixels). Each
RTL block is gated against it with zero differing pixels, and the whole
video pipeline together (`sim/run_frame.sh`), which also measures each
renderer's worst line with the Pocket memories' latencies:

| block | gate | worst line, Pocket latencies |
|---|---|---|
| `rtl/k056832_tilemap.sv` -- four tilemap layers | `sim/run_tilemap.sh` | 3,354 clocks |
| `rtl/k053936_roz.sv` -- rotate/zoom plane: 128-tile cache, runs up to 7 lines ahead | `sim/run_roz.sh` | no line late at any rotation angle; 1,400-3,200 average |
| `rtl/k053247_objlist.sv` -- sprite list and per-object line range | `sim/run_objlist.sh` | ~3,200 per frame, in vblank |
| `rtl/k053247_draw.sv` -- sprite rasterizer with column prefetch | `sim/run_sprite.sh` | 4,310 (busiest screen) |
| `rtl/k055555_mixer.sv` -- priority encoder + colour stage | `sim/run_frame.sh` | -- |

The budget is 6,144 clocks a line. The full machine runs under Verilator
(`sim/run_system.sh`) from reset with the real program; `MEM=pocket` puts
the Pocket memory subsystem and behavioural SDRAM, PSRAM and SRAM chips in
the loop, `MAMESCHED=1` drives the inputs on the schedule the frozen states
were taken with, and the trace reports each renderer's dropped lines and the
sprite renderer's work per frame. The memory subsystem has its own gate
(`sim/run_mem.sh`: the image in through the loader at the APF's maximum
rate, out through every core port, under contention) and the pixel hand-over
to the Pocket's video clock another (`sim/run_pixsync.sh`). The boot tracks
MAME's frame by frame through the MAME Lua oracles in `tools/`.

For developers the core carries a diagnostic overlay (memory verdicts,
dropped lines per renderer per frame, the CPUs' state) and runtime switches
for the memories' capture timing; the menu entries that enable them were
removed for the release and are kept in `docs/hardware.md` section 11.

## What is here

| Path | What it is |
|---|---|
| `rtl/` | The core: CPUs' boards, the chips, the video pipeline |
| `target/pocket/` | The Pocket: `core_top.sv` (APF glue), `gaia_mem.sv` (the memory partition, loader, built-in memory test), the vendored controllers |
| `pkg/pocket/` | The SD-card package: core, platform, assets note |
| `docs/hardware.md` | The board: memory map, chip set, ROM layout, the Pocket partition and its measured budgets, the overlay |
| `docs/rtl-conventions.md` | How the RTL is written and why |
| `docs/prior-art.md` | What already exists in open RTL, and what does not |
| `METHODOLOGY.md` | The MAME-as-oracle method the work follows |
| `gaiapolis.mra`, `tools/mra_build.py` | ROM description and the dependency-free builder; CRC-checks every part, md5-checks the image |
| `tools/render_model.py`, `tools/regress_render.sh` | The reference renderer and its gate |
| `tools/dump_state.lua`, `tools/probe_*.lua` | MAME Lua: frozen states, and oracles for device reads, the Z80's boot, the EEPROM, the 68000's pacing, the sprite list |
| `tools/roz_fetches.py` | Sizes the ROZ plane's memory traffic from the model's transform |
| `sim/run_*.sh` | The gates above and the system bench |
| `artifacts/states/` | The frozen-state corpus and its matching MAME snapshots |
| `artifacts/` | Snapshots, measurements, and other generated output |

## Open items

* The ROZ plane renders up to 7 lines ahead of the display, starting six
  raster lines before the visible area; a write to its registers later than
  that in vblank reaches those first lines a frame late. Not observed: the
  game writes them in its vblank handler.
* In the first frames of the intro after a new game, while its clouds
  load, the tilemap renderer drops 2-16 lines a frame for a dozen frames
  waiting behind the sprite and ROZ bursts on the SDRAM; clean after.
* Two shadow objects on one pixel are drawn as one where the chip darkens
  twice; the board flags it in some scenes.
* The attract intro runs about four times longer than in MAME before the
  music starts (140 frames against 31 from the self-test's end). Every
  device read the 68000 makes in that phase matches MAME; the wait is a
  loop at `200e2a` on a work-RAM flag the vblank handler clears, so the
  difference is in what the handler computes from RAM.
* The memory test at each load holds the core for about 2.5 s.

## Building the ROM

```sh
python3 tools/mra_build.py gaiapolis.mra /path/to/gaiapols.zip
python3 tools/verify_rom.py gaiapols.rom     # optional, needs artifacts/mame_regions.txt
```

The builder writes `gaiapols.rom`, 20,316,288 bytes, md5
`7ed05d08287ecc2be8592b0ef0158aad`. **No ROMs are distributed with this
repository.**

## Credits

The Gaiapolis-specific RTL, reference renderer and verification harness
(`rtl/`, `tools/`, `sim/`) are original; the rest of the core is built on
other people's work.

**Platform & toolchain**

* the **Analogue Pocket** openFPGA framework (APF) itself -- Analogue
  Enterprises Limited, `platform/pocket/bsp/pocket/apf_top.sv`,
  `platform/pocket/peripherals/io_pad_controller.sv`, and the Analogue
  copyright carried in `target/pocket/core_top.sv`
* **Marcus Andrade** ([@boogermann](https://github.com/boogermann)) /
  [OpenGateware](https://github.com/opengateware) -- the Pocket integration
  framework the rest of `platform/pocket/` (pad, audio, save/hiscore, video
  and memory glue) is built from, and the `raetro/quartus:pocket` Docker
  image `build-local.sh` and CI compile with; 41 of its 63 files carry his
  copyright. Also in the platform layer: **Alexey Melnikov (Sorgelig)** --
  audio filters, DC blocker, scanlines and shadowmask; **Till Harbaum** --
  the original scanline generator; **Adam Gastineau** -- the data loader
  and unloader; **Jim Gregory** and **Alan Steremberg** -- MAME
  hiscore.dat support; **Jacob Boline** -- USB HID keyboard translation.
* **GHDL** -- converts the vendored TG68K.C VHDL kernel to Verilog
  (`modules/cpu-tg68k/gen/`) so one source feeds both Quartus and Verilator
* **Verilator** -- every simulation bench in `sim/`

**Vendored cores** (`modules/`, see `modules/VENDOR.md`)

* **TG68K.C**, the switchable 68000/68010/68020 kernel, by Tobias Gubener
  -- `modules/cpu-tg68k`, LGPL-3.0
* **tv80**, the Z80 core, by Guy Hutchison -- `modules/cpu-tv80`, MIT,
  based on Daniel Wallner's VHDL T80 core, by way of `plasticbugs/punchout`
* the PSRAM controller, from the openFPGA SNES core, by Adam Gastineau --
  `target/pocket/psram.sv`, MIT
* the SDRAM controller's pin-level timing -- CL2, read data captured at
  READ+4, proven on the Pocket at 96 MHz -- carried over from this
  author's own S.T.U.N. Runner core, itself derived from the Punch-Out!!
  core's `sdram16.sv` (`target/pocket/sdram_ctrl.sv`)

**Reference & verification**

* **The MAME team**, the oracle throughout (`docs/hardware.md` section 10,
  `METHODOLOGY.md`). `ref/mame/mystwarr.cpp` and `mystwarr_v.cpp` (R.
  Belmont, Phil Stroffolino, Acho A. Tang, Nicola Salmoria) describe the
  board; `konamigx_v.cpp` (R. Belmont, Acho A. Tang, Phil Stroffolino,
  Olivier Galibert) is the GX-era video/mixer model this "pre-GX" driver
  shares. Kept as reference only -- none of it is compiled into the core.
* The custom-chip device models in `ref/mame/`, same terms: `k054539.cpp`
  and `k054321.cpp` (Olivier Galibert); `k054156_k054157_k056832.cpp`,
  `k053246_k053247_k055673.cpp`, `k053936.cpp` and `k055555.cpp` (David
  Haywood); `k054338.cpp` (David Haywood); `k054000.cpp` (David Haywood,
  Angelo Salese); `eepromser.cpp` (Aaron Giles).
* **jotego (Jose Tejada)**'s `jtcores` and **Furrtek**'s silicon reverse
  engineering of this Konami chip generation, plus jotego's released
  `jtrungun` (Run and Gun) core against the same chipset -- the prior-art
  survey this core is scoped against (`docs/prior-art.md`). No code from
  either is vendored here; the video pipeline ended up written directly
  from the reference renderer instead of ported (see above).

## Licence

GPL-3.0, following the GPL-3.0-or-later files in the OpenGateware platform
layer (`platform/pocket/`) and the LGPL-3.0 TG68K.C kernel
(`modules/cpu-tg68k/`). No jtcores RTL is vendored in this repository --
jotego's `jtcores` and Furrtek's silicon reverse engineering informed the
prior-art survey and hardware research (`docs/prior-art.md`) but
contributed no code.
