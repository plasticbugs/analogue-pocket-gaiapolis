#!/usr/bin/env python3
"""Reference renderer for Gaiapolis video hardware (Konami pre-GX / GX123).

This is the executable spec the RTL is written against: it consumes a frozen
machine state dumped by tools/dump_state.lua plus the built ROM image, and
reproduces the frame MAME produced. Semantics are taken from MAME 0.288
(k054156_k054157_k056832.cpp, k053246_k053247_k055673.cpp, k053936.cpp,
konamigx_v.cpp) -- see docs/hardware.md.

Raster space is 376 x 224 with the visible origin at (40, 16); the cabinet is
ROT90 so MAME's snapshot is 224 wide by 376 tall.

Usage:
    render_model.py <state.txt> <rom> [--layers=A,B,C,D,OBJ,SUB1] [--out out.png]
                    [--ref mame.png] [--diff diff.png]
"""
import sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

# ---------------------------------------------------------------- geometry
VIS_W, VIS_H = 376, 224          # raster: X is the 376 axis, Y the 224 axis
VIS_X0, VIS_Y0 = 40, 16          # visible origin inside the 512x264 raster

# ---------------------------------------------------------- ROM image map
ROM_MAINCPU   = 0x0000000
ROM_SOUNDCPU  = 0x0300000
ROM_TILES     = 0x0340000        # 2 MB, 4bpp chunky, 4 bytes per 8-pixel row
ROM_ROZCHAR   = 0x0540000        # gfx3, 1.5 MB, 4bpp 16x16 packed MSB
ROM_ROZMAP    = 0x06C0000        # gfx4, 640 KB
ROM_PCM       = 0x0760000
ROM_SPRITES   = 0x0B60000        # 8 MB, 4bpp, 64-bit word = one 16-pixel row
ROM_EEPROM    = 0x1360000

# gaiapolis constants from mystwarr.cpp / mystwarr_v.cpp
LAYER_OFFS   = [(-2 + 2 - 1, 0 - 1), (0 + 2, 0), (2 + 2, 0), (3 + 2, 0)]  # set_layer_offs
SPR_DX, SPR_DY = -61, -22        # k055673 set_config(K055673_LAYOUT_RNG, -61, -22)
ROZ_OFFS     = (-10, 0)          # K053936GP_set_offset(0, -10, 0)
LSRAM_PAGE   = [(i, i << 11) for i in range(8)]   # k056832 defaults

K056832_PAGE_W, K056832_PAGE_H = 64, 32          # tiles
SHIFTMASKS = [(6, 0x3f, 0, 0x00), (4, 0x0f, 2, 0x30),
              (2, 0x03, 2, 0x3c), (0, 0x00, 2, 0x3f)]

# K055555 register indices (k055555.h)
K55_PALBASE_A, K55_PALBASE_OBJ, K55_PALBASE_SUB1 = 23, 27, 28
K55_PRIINP = {'A': 7, 'B': 10, 'C': 13, 'D': 14, 'OBJ': 15, 'SUB1': 16}
K55_INPUT_ENABLES = 45
K55_INP_BIT = {'A': 0x01, 'B': 0x02, 'C': 0x04, 'D': 0x08, 'OBJ': 0x10, 'SUB1': 0x20}


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


class State:
    """A frozen frame, as written by tools/dump_state.lua."""

    def __init__(self, path):
        self.vram = [None] * 17
        for line in open(path):
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            key = parts[0]
            if key == 'FRAME':
                self.frame = int(parts[1])
                continue
            if key == 'VRAM':
                self.vram[int(parts[1])] = [int(x, 16) for x in parts[2:]]
                continue
            vals = [int(x, 16) for x in parts[1:]]
            setattr(self, key.lower(), vals)

    # --- K056832 ------------------------------------------------------
    def layer_pages(self, layer):
        r0 = (self.k56regs[8 + layer] & 0x18) >> 3
        h = self.k56regs[8 + layer] & 3
        c0 = (self.k56regs[12 + layer] & 0x18) >> 3
        w = self.k56regs[12 + layer] & 3
        return r0, h + 1, c0, w + 1

    def layer_scroll(self, layer):
        dy = s16(self.k56regs[16 + layer])
        dx = s16(self.k56regs[20 + layer])
        return dx, dy

    def scrollmode(self, layer):
        return (self.k56regs[5] >> (LSRAM_PAGE[layer][0] << 1)) & 3

    def colorbase(self, layer):
        return self.k55regs[K55_PALBASE_A + layer] << 4

    # --- palette ------------------------------------------------------
    def color(self, idx):
        """xRGB_888: word 2i = 0x00RR, word 2i+1 = 0xGGBB (big-endian 68k)."""
        w0 = self.palette[idx * 2]
        w1 = self.palette[idx * 2 + 1]
        return (w0 & 0xff, (w1 >> 8) & 0xff, w1 & 0xff)


class Roms:
    def __init__(self, path):
        self.d = open(path, 'rb').read()
        if len(self.d) < ROM_EEPROM:
            raise ValueError(f'{path}: too small ({len(self.d)} bytes)')

    def tile_row(self, code, row):
        """4 bytes = one 8-pixel row of an 8x8 tile."""
        o = ROM_TILES + ((code * 32 + row * 4) % 0x200000)
        return self.d[o:o + 4]

    def roz_char_row(self, code, row):
        """8 bytes = one 16-pixel row of a 16x16 4bpp tile."""
        o = ROM_ROZCHAR + ((code * 128 + row * 8) % 0x180000)
        return self.d[o:o + 8]

    def roz_map(self, i):
        """gfx4 layout: colour nibbles (two tiles per byte) at 0, attribute
        bytes at 0x20000, tile low bytes at 0x60000."""
        b = ROM_ROZMAP
        return self.d[b + (i >> 1)], self.d[b + 0x20000 + i], self.d[b + 0x60000 + i]

    def sprite_row(self, code, row):
        """8 bytes = one 16-pixel row of a 16x16 4bpp sprite tile."""
        o = ROM_SPRITES + ((code * 128 + row * 8) % 0x800000)
        return self.d[o:o + 8]


def nib(b, i):
    """pixel i of a packed-MSB 4bpp byte run"""
    return (b[i >> 1] >> 4) if not (i & 1) else (b[i >> 1] & 0x0f)


# ------------------------------------------------------------ tile layers
def render_tilemap(st, roms, layer, pix, pri, layer_pri):
    """Paint one K056832 layer into pix[] (palette index, -1 = transparent)."""
    r0, rowspan, c0, colspan = st.layer_pages(layer)
    dx, dy = st.layer_scroll(layer)
    mode = st.scrollmode(layer)
    cb = st.colorbase(layer)
    fbits = (st.k56regs[3] >> 6) & 3
    flips_sh, palm1, pals2, palm2 = SHIFTMASKS[fbits]
    flip_override = (st.k56regs[1] >> (layer << 1)) & 3
    ox, oy = LAYER_OFFS[layer]

    width = colspan * K056832_PAGE_W * 8
    height = rowspan * K056832_PAGE_H * 8

    scrollbank = ((st.k56regs[0x18] >> 1) & 0xc) | (st.k56regs[0x18] & 3)
    ls_base = LSRAM_PAGE[layer][1] >> 1

    # MAME draws the tilemap into the full 512x264 raster bitmap and clips to
    # the visible area, so tilemap coordinates are absolute raster coordinates:
    # visible (0,0) is raster (VIS_X0, VIS_Y0).
    for y in range(VIS_H):
        ry = y + VIS_Y0
        if mode == 3:                       # xy scroll
            sx = dx
        elif mode == 0:                     # linescroll
            sx = st.vram[scrollbank][(ls_base + ry * 2 + 1) & 0xfff]
        else:                               # rowscroll
            sx = st.vram[scrollbank][(ls_base + (ry >> 3) * 16 + 1) & 0xfff]
        # MAME: set_scrolly(0, ay) with ay = (dy - layer_offs_y) % height, and
        # a tilemap scroll of v shows source pixel (screen + v).
        vy = (ry + dy - oy) % height
        py = (vy >> 8) % rowspan
        ty = (vy >> 3) & (K056832_PAGE_H - 1)
        fy = vy & 7
        row_base = ((r0 + py) & 3) << 2

        for x in range(VIS_W):
            vx = (x + VIS_X0 + sx - ox) % width
            px_ = (vx >> 9) % colspan
            tx = (vx >> 3) & (K056832_PAGE_W - 1)
            fx = vx & 7
            page = row_base | ((c0 + px_) & 3)
            vram = st.vram[page]
            i = ((ty * K056832_PAGE_W) + tx) << 1
            attr, code = vram[i], vram[i + 1]

            flip = flip_override & ((attr >> flips_sh) & 3)
            color = (attr & palm1) | ((attr >> pals2) & palm2)
            color = cb | ((color >> 2) & 0x0f)      # game4bpp_tile_callback

            rr = 7 - fy if (flip & 2) else fy
            cc = 7 - fx if (flip & 1) else fx
            pv = nib(roms.tile_row(code, rr), cc)
            if pv:
                o = y * VIS_W + x
                pix[o] = (color << 4) | pv
                pri[o] = layer_pri


# ------------------------------------------------------------------ ROZ
# K053936-class PSAC2 plane, driven through the K053936GP_* helpers in
# MAME's k053936.cpp. Virtual plane is 512x512 tiles of 16x16 = 8192x8192.
def roz_tile(st, roms, ti):
    """-> (tile number, colour) for tilemap index ti, per get_gai_936_tile_info"""
    d1, d2, d3 = roms.roz_map(ti)
    tileno = d3 | ((d2 & 0x3f) << 8)
    colour = (d1 & 0x0f) if (ti & 1) else ((d1 >> 4) & 0x0f)
    if d2 & 0x80:
        colour |= 0x10
    colour |= st.k55regs[K55_PALBASE_SUB1] << 4
    return tileno, colour


def render_roz(st, roms, pix, pri, layer_pri):
    if not (st.rozctrl[0] & 0x0100):        # ddd_053936_enable_w bit 8
        return
    c = st.rozct16
    startx = s16(c[0]) << 8
    starty = s16(c[1]) << 8
    incyx, incyy = s16(c[2]), s16(c[3])
    incxx, incxy = s16(c[4]), s16(c[5])
    if c[6] & 0x4000:
        incyx <<= 8; incyy <<= 8
    if c[6] & 0x0040:
        incxx <<= 8; incxy <<= 8

    if c[7] & 0x0040:
        raise NotImplementedError('K053936 "super" (per-line) mode not modelled yet')

    ox, oy = ROZ_OFFS
    startx -= oy * incyx; starty -= oy * incyy
    startx -= ox * incxx; starty -= ox * incxy
    startx <<= 5; starty <<= 5
    incxx <<= 5; incxy <<= 5; incyx <<= 5; incyy <<= 5

    # copyroz32clip: the caller's cliprect is the visible area, and the walk
    # starts from its top-left corner in raster coordinates. MAME carries the
    # accumulators as uint32_t, so the >>16 is an unsigned shift -- Python's
    # unbounded ints have to be masked to match.
    startx = (startx + VIS_X0 * incxx + VIS_Y0 * incyx) & 0xffffffff
    starty = (starty + VIS_X0 * incxy + VIS_Y0 * incyy) & 0xffffffff
    incxx &= 0xffffffff; incxy &= 0xffffffff
    incyx &= 0xffffffff; incyy &= 0xffffffff

    # source clip window (ddd_053936_clip_w)
    clip = st.rozclip[1] & 0x0100
    if clip:
        m = st.rozclip[0]
        cx, cy = m & 0x3f, (m & 0x0fc0) >> 6
        sxs, sys = (m & 0x3000) >> 12, (m & 0xc000) >> 14
        sxs = {3: 1, 2: 2}.get(sxs, 4)
        sys = {3: 1, 2: 2}.get(sys, 4)
        minx, maxx = cx << 7, ((cx + sxs) << 7) - 1
        miny, maxy = cy << 7, ((cy + sys) << 7) - 1
    else:
        minx = miny = -0x10000
        maxx = maxy = 0x10000

    tile_cache = {}
    # MAME's K053936GP_copyroz32clip advances its destination pointer by one
    # row before the loop body while leaving the accumulators at their initial
    # value, so raster row N is painted with the transform for row N-1 and the
    # first visible row is never written. Reproduced here so the frozen-state
    # gate can be exact; flagged because it looks like a MAME artefact rather
    # than hardware behaviour (docs/hardware.md section 10) and the RTL should
    # probably not copy it.
    for ti in range(VIS_H):
        y = ti + 1
        cx, cy = startx, starty
        startx = (startx + incyx) & 0xffffffff
        starty = (starty + incyy) & 0xffffffff
        if y >= VIS_H:
            break
        for x in range(VIS_W):
            srcx = (cx >> 16) & 0x1fff
            srcy = (cy >> 16) & 0x1fff
            cx = (cx + incxx) & 0xffffffff
            cy = (cy + incxy) & 0xffffffff
            if srcx < minx or srcx > maxx or srcy < miny or srcy > maxy:
                continue
            ti = ((srcy >> 4) << 9) | (srcx >> 4)
            ent = tile_cache.get(ti)
            if ent is None:
                ent = roz_tile(st, roms, ti)
                tile_cache[ti] = ent
            tileno, colour = ent
            pv = nib(roms.roz_char_row(tileno, srcy & 15), srcx & 15)
            if not pv:                       # cmask 0xf for 4bpp: pen 0 is clear
                continue
            o = y * VIS_W + x
            pix[o] = (colour << 4) | pv
            pri[o] = layer_pri


# ------------------------------------------------------------------ main
def render(st, roms, layers):
    n = VIS_W * VIS_H
    pix = [-1] * n
    pri = [0] * n
    if 'SUB1' in layers:
        render_roz(st, roms, pix, pri, st.k55regs[K55_PRIINP['SUB1']])
    for name in ('D', 'C', 'B', 'A'):        # back to front for now
        if name not in layers:
            continue
        li = 'ABCD'.index(name)
        render_tilemap(st, roms, li, pix, pri, st.k55regs[K55_PRIINP[name]])
    return pix


def to_rgb_rot90(st, pix):
    """raster (x,y) -> ROT90 snapshot (223-y, x); returns (w,h,rgb)."""
    w, h = VIS_H, VIS_W
    out = bytearray(w * h * 3)
    for y in range(VIS_H):
        for x in range(VIS_W):
            v = pix[y * VIS_W + x]
            r, g, b = st.color(v & 0x7ff) if v >= 0 else (0, 0, 0)
            o = (x * w + (VIS_H - 1 - y)) * 3
            out[o], out[o + 1], out[o + 2] = r, g, b
    return w, h, out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    opts = dict(a[2:].split('=', 1) for a in sys.argv[1:] if a.startswith('--') and '=' in a)
    if len(args) < 2:
        sys.exit(__doc__)
    st = State(args[0])
    roms = Roms(args[1])
    layers = set((opts.get('layers') or 'A,B,C,D').split(','))

    pix = render(st, roms, layers)
    w, h, rgb = to_rgb_rot90(st, pix)

    out = opts.get('out')
    if out:
        pngio.write(out, w, h, rgb)
        print(f'wrote {out} ({w}x{h})')

    ref = opts.get('ref')
    if ref:
        rw, rh, rpx = pngio.read(ref)
        if (rw, rh) != (w, h):
            sys.exit(f'reference is {rw}x{rh}, model is {w}x{h}')
        diff = sum(1 for i in range(0, len(rgb), 3)
                   if rgb[i:i + 3] != rpx[i:i + 3])
        # coverage: how much of the frame the model actually painted. A state
        # where the layer is blank passes trivially, so report it alongside.
        drawn = sum(1 for v in pix if v >= 0)
        print(f'differing pixels: {diff} / {w*h} ({100.0*diff/(w*h):.2f}%) '
              f'coverage {100.0*drawn/(VIS_W*VIS_H):.1f}%')
        dimg = opts.get('diff')
        if dimg:
            dd = bytearray(w * h * 3)
            for i in range(0, len(rgb), 3):
                if rgb[i:i + 3] != rpx[i:i + 3]:
                    dd[i] = 0xff
                else:
                    g = (rgb[i] + rgb[i + 1] + rgb[i + 2]) // 6
                    dd[i] = dd[i + 1] = dd[i + 2] = g
            pngio.write(dimg, w, h, dd)
            print(f'wrote {dimg}')


if __name__ == '__main__':
    main()
