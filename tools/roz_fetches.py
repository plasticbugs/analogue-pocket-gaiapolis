#!/usr/bin/env python3
"""How many memory fetches a line of the ROZ plane needs, per frozen state,
under the character-column cache: a 16x16 tile's 4-pixel word column is one
16-word block (one word per row); a small cache of blocks is refilled when a
pixel's (tile, word column) is not in it. Also counts tile changes (a map
fetch each). Usage: tools/roz_fetches.py <state.txt> [...]"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
import render_model as rm

def analyse(path, cache_ways=2):
    st = rm.State(path)
    if not (st.rozctrl[0] & 0x0100): return None
    c = st.rozct16
    s16 = rm.s16
    startx = s16(c[0]) << 8; starty = s16(c[1]) << 8
    incyx, incyy = s16(c[2]), s16(c[3]); incxx, incxy = s16(c[4]), s16(c[5])
    if c[6] & 0x4000: incyx <<= 8; incyy <<= 8
    if c[6] & 0x0040: incxx <<= 8; incxy <<= 8
    ox, oy = rm.ROZ_OFFS
    startx -= oy * incyx; starty -= oy * incyy; startx -= ox * incxx; starty -= ox * incxy
    startx <<= 5; starty <<= 5; incxx <<= 5; incxy <<= 5; incyx <<= 5; incyy <<= 5
    startx = (startx + rm.VIS_X0 * incxx + rm.VIS_Y0 * incyx) & 0xffffffff
    starty = (starty + rm.VIS_X0 * incxy + rm.VIS_Y0 * incyy) & 0xffffffff
    incxx &= 0xffffffff; incxy &= 0xffffffff; incyx &= 0xffffffff; incyy &= 0xffffffff
    worst_blocks = worst_tiles = 0; tot_blocks = tot_tiles = 0
    for y in range(rm.VIS_H):
        cx, cy = startx, starty
        startx = (startx + incyx) & 0xffffffff; starty = (starty + incyy) & 0xffffffff
        cache = []; last_tile = None; blocks = tiles = 0
        for x in range(rm.VIS_W):
            srcx = (cx >> 16) & 0x1fff; srcy = (cy >> 16) & 0x1fff
            cx = (cx + incxx) & 0xffffffff; cy = (cy + incxy) & 0xffffffff
            ti = ((srcy >> 4) << 9) | (srcx >> 4)
            if ti != last_tile: tiles += 1; last_tile = ti
            blk = (ti, (srcx & 15) >> 2)
            if blk in cache: cache.remove(blk); cache.append(blk)
            else:
                blocks += 1; cache.append(blk)
                if len(cache) > cache_ways: cache.pop(0)
        worst_blocks = max(worst_blocks, blocks); worst_tiles = max(worst_tiles, tiles)
        tot_blocks += blocks; tot_tiles += tiles
    return worst_blocks, worst_tiles, tot_blocks / rm.VIS_H, tot_tiles / rm.VIS_H, (incxx, incxy, incyx, incyy)

for p in sys.argv[1:]:
    r = analyse(p)
    name = os.path.basename(p).replace('.txt', '')
    if r is None: print("%-14s ROZ off" % name); continue
    wb, wt, ab, at, inc = r
    est = wb * 28 + wt * 3 * 12
    print("%-14s worst line: %3d block fetches, %3d tile changes  (mean %.0f, %.0f)  est. %5d clocks; inc xx=%08x xy=%08x" % (name, wb, wt, ab, at, est, inc[0], inc[1]))
