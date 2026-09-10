# Sprite rasterizer: design notes

The K053247 sprite block is split in two. `rtl/k053247_objlist.sv` is built and
gated (`sim/run_objlist.sh`); the rasterizer is the remaining piece and this
records what was worked out for it, so it does not have to be re-derived.

## Interface

Inputs: the ordered object list, sprite RAM, the sprite ROM, and the two
reciprocal ROMs. Output: a line buffer read back per pixel as
`{opaque, pen[11:0], pri[7:0]}` plus `{shadow, shtab[1:0]}`.

## Sprite ROM addressing

`K055673_LAYOUT_RNG` is 16x16, 4bpp, planes at bit offsets {24,16,8,0}, x
offsets 0..7 then 32..39, row stride 64 bits. So **one 64-bit word is one
complete 16-pixel row**, 128 bytes per tile, and the row address is
`code * 16 + row`.

With `rom_q[63:56]` as the lowest byte, pixel `c` of the row is:

```
half = c[3]                                  // 0: bytes 0..3, 1: bytes 4..7
p0 = half ? rom_q[ 7: 0] : rom_q[39:32]      // MSB plane
p1 = half ? rom_q[15: 8] : rom_q[47:40]
p2 = half ? rom_q[23:16] : rom_q[55:48]
p3 = half ? rom_q[31:24] : rom_q[63:56]      // LSB plane
pen = {p0[7-c[2:0]], p1[7-c[2:0]], p2[7-c[2:0]], p3[7-c[2:0]]}
```

Note the byte order **reverses** between the halves rather than shifting:
`xoffset` jumps from 7 to 32 at pixel 8, so the upper half's planes run
through bytes 7,6,5,4 while the lower half's run through 3,2,1,0.

## Why the reciprocal ROMs exist

Two places need an exact C integer division, and reproducing the truncation is
the whole point -- an approximation changes which source pixel is sampled:

* the zoom factor, `(0x400000 + (raw >> 1)) / raw` from the 10-bit register;
* the source step per destination pixel, `(16 << 19) / dst_size`, taken per
  tile because rounding makes the per-tile destination size alternate.

A worst-case line needs roughly 220 of these, so an iterative divider (~24
clocks each) would eat 5,300 of the 6,144-clock line budget on its own.
`tools/gen_sprite_tables.py` emits `rtl/data/zoom.hex` (1024 x 24) and
`rtl/data/recip.hex` (2048 x 24) instead, 9 KB of block RAM total.

Once a tile's step is known the sampling is a plain DDA: accumulate the step
per destination pixel and take bits [23:19] as the source column.

## Shadows

Shadow objects carry their own Z and priority buffer and, in MAME, darken
whatever is in the framebuffer at that point in the draw order. The rasterizer
instead marks the pixel with a flag and a 2-bit table index, leaving the
palette lookup and the K054338 darkening downstream. A solid write clears the
flag, which reproduces MAME's "a later solid overwrites the shadow".

That is exact only if no pixel is ever shadowed twice, and no pixel is, across
the whole frozen-state corpus (measured: 0 of 829-967 shadowed pixels in the
three states that have any). The Z/priority test does permit it in principle,
so the module should raise `shadow_overlap` if it ever happens rather than
silently dropping one.

## Cycle budget

Per line, against 6,144 clocks:

| | clocks |
|---|---|
| clear the line buffer | 376 |
| walk all objects, y-range reject | ~124 x 10 = 1,240 |
| covered objects: ROM row fetches | ~20 x 8 x 4 = 640 |
| pixel writes (worst measured) | 2,110 |
| **total** | **~4,400** |

Tight but inside budget. If it overruns, the first thing to do is precompute
each object's y range during the vblank pass so the per-line reject costs two
clocks instead of ten -- that alone recovers about a thousand.
