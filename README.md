# Gaiapolis — Analogue Pocket core (openFPGA)

Gaiapolis (Konami, 1993) on Konami "pre-GX" GX123 hardware, for the Analogue
Pocket via openFPGA/opengateware.

**Status: investigation and foundations. No RTL yet.**

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
| `artifacts/` | Snapshots, measurements, and other generated output |

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
