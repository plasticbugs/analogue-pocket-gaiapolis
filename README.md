# Gaiapolis — Analogue Pocket core (openFPGA)

Gaiapolis (Konami, 1993) on Konami "pre-GX" GX123 hardware, for the Analogue
Pocket via openFPGA/opengateware.

**Status: reference renderer in progress. No RTL yet.**

**The reference renderer is complete and reproduces MAME's output exactly** --
full frames, not just individual layers. `tools/regress_render.sh`: 28 gates,
zero differing pixels (24 substantive; the trivial ones are labelled).

Covered: K056832 tilemaps, K053936 ROZ plane, K055673 sprites with the
per-pixel Z buffer and shadows, and the K055555 priority mixer.

RTL so far, each gated against the reference renderer with zero differing
pixels (`sim/run_tilemap.sh`, `sim/run_roz.sh`):

| block | worst line | budget |
|---|---|---|
| `rtl/k056832_tilemap.sv` -- four tilemap layers | 2,660 clocks | 6,144 |
| `rtl/k053936_roz.sv` -- rotate/zoom plane | 2,777 clocks | 6,144 |

Next: the sprite engine, then the mixer, then CPUs and platform integration.

## What is here

| Path | What it is |
|---|---|
| `docs/hardware.md` | The board: memory map, chip set, ROM layout, measured bandwidth budget |
| `docs/prior-art.md` | What already exists in open RTL, and what does not |
| `gaiapolis.mra` | ROM description (standard MiSTer MRA) |
| `tools/mra_build.py` | Dependency-free ROM builder; CRC-checks every part, md5-checks the image |
| `tools/verify_rom.py` | Verifies a built image against slices of what MAME actually loads |
| `tools/dump_regions.lua` | MAME Lua: dumps those region slices |
| `tools/probe_sprites.lua` | MAME Lua: per-scanline sprite load measurement |
| `tools/dump_state.lua` | MAME Lua: freezes one frame (VRAM, palette, sprite RAM, ROZ, all chip registers) next to MAME's own snapshot; `FORCE_ENABLE` isolates a single layer |
| `tools/render_model.py` | Reference renderer -- the executable spec the RTL is written against |
| `tools/pngio.py` | Dependency-free PNG read/write |
| `tools/regress_render.sh` | Frozen-state gate for the model: renders every state and requires zero differing pixels |
| `sim/run_tilemap.sh`, `sim/run_roz.sh` | Frozen-state gates for the RTL, diffed against the model |
| `rtl/` | Core RTL |
| `artifacts/states/` | The frozen-state corpus and its matching MAME snapshots |
| `artifacts/` | Snapshots, measurements, and other generated output |

## Running the frozen-state gate

```sh
tools/regress_render.sh gaiapolis.rom
```

## Building the ROM

```sh
python3 tools/mra_build.py gaiapolis.mra /path/to/gaiapols.zip gaiapolis.rom
python3 tools/verify_rom.py gaiapolis.rom     # optional, needs artifacts/mame_regions.txt
```

The image is 20,316,288 bytes, md5 `7ed05d08287ecc2be8592b0ef0158aad`.
**No ROMs are distributed with this repository.**

## The short version of the feasibility question

* 18.9 MB of ROM against 48 MB across the Pocket's four independent memory
  buses — it fits, with a clean partition (`docs/hardware.md` §11).
* Worst measured sprite load is 348 16-bit words per 64 us scanline. Bandwidth
  is not the blocker.
* Seven of the eight custom chips already have open Verilog, and `jtrungun`
  (Run and Gun — same Konami generation, K055673 sprites + K053936 ROZ +
  2 x K054539) is a released Pocket core. The gaps are the **K055555** priority
  encoder and finishing the **K056832** tilemap generator.
* MAME itself is `MACHINE_IMPERFECT_GRAPHICS` for this driver, so the usual
  "make MAME the oracle" method needs adjusting (`docs/hardware.md` §10).

## Licence

GPL-3.0. Reuses work from jotego's `jtcores` (GPL-3.0) and silicon reverse
engineering by Furrtek; see `docs/prior-art.md`.
