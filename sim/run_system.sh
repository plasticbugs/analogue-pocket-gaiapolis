#!/bin/sh
# Full-system simulation: the whole machine from reset with the real program.
#   sim/run_system.sh <gaiapolis.rom> [frames] [out-name]
# Writes artifacts/system/<name>.rgb, .png and .trace.
set -e
cd "$(dirname "$0")"
ROM="$1"; FRAMES="${2:-4}"; NAME="${3:-sys}"
[ -f "$ROM" ] || { echo "usage: $0 <gaiapolis.rom> [frames] [name]" >&2; exit 2; }
case "$ROM" in /*) ;; *) ROM="$PWD/$ROM" ;; esac

verilator --cc --exe --build -j 8 -O2 -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY \
    +1364-2005ext+v waivers.vlt --top-module tb_system_top -Mdir obj_system \
    ../rtl/*.sv ../modules/cpu-tg68k/gen/tg68k.v tb_system_top.sv tb_system.cpp \
    > obj_system.log 2>&1 || { tail -30 obj_system.log; exit 1; }

mkdir -p ../artifacts/system
./obj_system/Vtb_system_top "$ROM" "$FRAMES" ../artifacts/system/$NAME.rgb ../artifacts/system/$NAME.trace
# periodic frames (SNAPEVERY=n) become <name>.f<n>.png as well
for f in ../artifacts/system/$NAME.rgb.f*; do
    [ -f "$f" ] || continue
    python3 ../tools/rgb2png.py "$f" "${f%.rgb.f*}.f${f##*.f}.png" >/dev/null
done
python3 - <<PY
import sys, struct; sys.path.insert(0,'../tools')
import pngio
VIS_W,VIS_H=376,224
d=open('../artifacts/system/$NAME.rgb','rb').read(); buf=struct.unpack('<%dI'%(VIS_W*VIS_H), d)
w,h=VIS_H,VIS_W; out=bytearray(w*h*3)
for y in range(VIS_H):
    for x in range(VIS_W):
        v=buf[y*VIS_W+x]; o=(x*w+(VIS_H-1-y))*3
        out[o]=(v>>16)&0xff; out[o+1]=(v>>8)&0xff; out[o+2]=v&0xff
pngio.write('../artifacts/system/$NAME.png',w,h,out)
nz=sum(1 for v in buf if v)
print('wrote artifacts/system/$NAME.png  non-black pixels: %d (%.1f%%)'%(nz,100*nz/(VIS_W*VIS_H)))
PY
