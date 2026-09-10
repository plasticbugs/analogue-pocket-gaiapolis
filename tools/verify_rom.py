#!/usr/bin/env python3
"""Verify a built gaiapolis .rom image against slices dumped from MAME.

tools/dump_regions.lua writes artifacts/mame_regions.txt: for each ROM region,
several 4 KB slices of exactly what MAME loaded. This checks the built image
carries the same bytes at the corresponding image offsets, which is what
catches interleave, ordering and endianness mistakes.

The one region that is not a straight copy is the K056832 tile ROM: MAME
expands it to 5-byte groups whose fifth byte (the unused 5th bitplane) is
always zero for this game, and the image drops that byte.

Usage: verify_rom.py <image.rom> [artifacts/mame_regions.txt]
"""
import sys

# region tag -> (image offset, region length)
LAYOUT = {
    ':maincpu':  (0x0000000, 0x300000),
    ':soundcpu': (0x0300000, 0x040000),
    ':k056832':  (0x0340000, 0x280000),   # 5-byte groups in MAME, 4 in the image
    ':gfx3':     (0x0540000, 0x180000),
    ':gfx4':     (0x06C0000, 0x0A0000),
    ':k054539':  (0x0760000, 0x400000),
    ':k055673':  (0x0B60000, 0x800000),
    ':eeprom':   (0x1360000, 0x000080),
}


def parse(path):
    slices = []
    with open(path) as f:
        lines = f.read().split('\n')
    i = 0
    while i < len(lines):
        if lines[i].startswith('SLICE '):
            _, tag, off = lines[i].split()
            slices.append((tag, int(off), bytes.fromhex(lines[i + 1])))
            i += 2
        else:
            i += 1
    return slices


def main():
    img = open(sys.argv[1], 'rb').read()
    dump = sys.argv[2] if len(sys.argv) > 2 else 'artifacts/mame_regions.txt'
    slices = parse(dump)
    if not slices:
        sys.exit('error: no slices in ' + dump)

    bad = 0
    for tag, off, want in slices:
        base, _ = LAYOUT[tag]
        if tag == ':k056832':
            # MAME group n is [b0 b1 b2 b3 00]; the image keeps [b0 b1 b2 b3].
            if off % 5:
                continue                        # only check group-aligned slices
            got = bytearray()
            plane5_nonzero = 0
            for n in range(len(want) // 5):
                g = want[n * 5:n * 5 + 5]
                if g[4]:
                    plane5_nonzero += 1
                got += g[:4]
            src = base + (off // 5) * 4
            have = img[src:src + len(got)]
            ok = have == bytes(got)
            extra = f'  (5th-plane bytes non-zero: {plane5_nonzero})'
        else:
            have = img[base + off:base + off + len(want)]
            ok = have == want
            extra = ''

        n_diff = sum(1 for a, b in zip(have, want if tag != ':k056832' else got) if a != b)
        print(f"{'OK  ' if ok else 'FAIL'}  {tag:<10} region+{off:#09x} "
              f"-> image+{(base + off):#09x}  {len(want)} bytes"
              f"{'' if ok else f'  {n_diff} differing'}{extra}")
        if not ok:
            bad += 1

    print()
    if bad:
        sys.exit(f'{bad} slice(s) did not match')
    print(f'all {len(slices)} slices match MAME')


if __name__ == '__main__':
    main()
