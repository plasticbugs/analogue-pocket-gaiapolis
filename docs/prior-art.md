# Prior art: what already exists in open RTL

Written before any RTL, because it changes the plan completely.

## Summary

Gaiapolis uses eight Konami custom chips. **Seven of the eight already have an
open Verilog implementation**, and a core using most of them
(`jtrungun` — Run and Gun, same 1993 Konami generation) is a **released,
working Analogue Pocket core today**. Gaiapolis is not a leap into unexplored
hardware; it is roughly "Moo Mesa's chipset plus Run and Gun's rotating plane".

## Chip-by-chip

| Chip | Function | Open RTL | Where | Proven on Pocket? |
|---|---|---|---|---|
| MC68000 | main CPU | yes | `fx68k`, or TG68K already vendored in `~/work/stunrunner/modules/cpu-tg68k` | yes |
| Z80 | sound CPU | yes | T80 | yes |
| K054539 ×2 | 8-ch PCM/ADPCM | yes | `jotego/jt539` (jtcores submodule) | yes — `jtrungun` |
| K055673 / K053246-7 | sprites, dual-axis zoom, Z buffer | yes | `jtcores/cores/simson/hdl/jt053246.sv`, `_scan.sv`, `_dma.v`, `_mmr.v` | yes — `jtsimson`, `jtxmen`, `jtrungun` |
| K053936 | PSAC2 rotate/zoom plane | yes | `jtcores/cores/rungun/hdl/jt053936.v` (+ `jtrungun_psac.v`) | yes — `jtrungun` |
| K053252 | CRTC / timing | yes | `jtcores/cores/rungun/hdl/jtk053252.v` | yes — `jtrungun` |
| K054338 | alpha blend / brightness | yes | `jtcores/cores/moo/hdl/jt054338.v` | **no** — `moo` is unreleased WIP |
| K054000 | collision protection | yes | `jtcores/cores/simson/hdl/jtk054000.v` | yes — `jtsimson` |
| K054321 | main↔sound latch | yes | inside `jtrungun_sound.v` | yes |
| ER5911 | serial EEPROM | yes | `jotego/jteeprom` | yes |
| K056832 | 4-layer tilemaps | **partial** | `jtcores/modules/jt05415x` — K054156/K054157 reconstructed from Furrtek's silicon RE; K056832 is the superset. README says "is being reconstructed" | **no** |
| **K055555** | 8-input 5bpp priority encoder | **no** | Moo Mesa and X-Men use the older K053251 (`jtcolmix_053251.v`); `jtmoo_colmix.v` / `jtxmen_colmix.v` are game-specific mixers | **no** |

Two genuine gaps: **K055555**, and finishing **K056832** (the released
`jtrungun` does not use it — Run and Gun's fixed layer is TTL, not a K056832).

## Licensing

`jotego/jtcores` is **GPL-3.0-or-later** ("you are obliged to publish your code
if you use mine"). Every existing core in `~/work` — stunrunner, supersprint,
punchout — is already GPL-3.0. So reuse is clean provided this core is GPL-3.0
and published, with attribution to Jose Tejada and, for the silicon-derived
parts, to Furrtek.

## Why this matters for the K055555

The K055555 is a *per-pixel* priority encoder: eight inputs each present a
colour code plus priority, and the chip picks a winner every pixel. MAME models
it as a software sort-and-composite in `konamigx_v.cpp`, which is why that file
is 1,600 lines of approximation studded with `HACK` and `UNIMPLEMENTED`.

**In RTL the real structure is simpler than MAME's model**, because RTL can do
what the chip does: run all six layers in parallel and compare per pixel. There
are 12 core clocks per pixel at 96 MHz against an 8 MHz pixel clock — ample. So
the missing chip is the one where the software oracle is least trustworthy and
the hardware description is most natural. That is a real risk, but it is
bounded, and Furrtek has silicon-level work on this Konami family.

## Two possible routes

**A. Port the modules into an opengateware core** (what the existing cores in
`~/work` do). Keeps the toolchain, CI, MRA/ROM builder, release scripts and
`core_top.sv` conventions already proven across four cores. Cost: the jtcores
modules use JTFRAME interfaces (ROM request/ack with `_cs`/`_ok`, `jtframe_ram`
wrappers, JTFRAME's own SDRAM arbiter), so each imported module needs an
adapter, and jt05415x/K056832 has to be finished.

**B. Add a `mystwarr`/`gaiapolis` core to jtcores.** Every module is already in
its native framework and jotego already ships Pocket builds. Far less
integration work; the K055555 and K056832 gaps remain either way. Costs the
tooling and release conventions built up in `~/work`, and means working inside
someone else's repo and release cadence.

Route A is the larger build but the one that matches every other core here.
