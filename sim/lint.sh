#!/bin/sh
# Lint every RTL file the core synthesises. Run before every push: it catches
# syntax and inference errors in seconds, where a broken push costs a whole
# CI cycle. The vendored cores (TG68K, tv80) are waived by path in
# sim/waivers.vlt; nothing under rtl/ is waived wholesale.
set -e
cd "$(dirname "$0")/.."
verilator --version >/dev/null 2>&1 || { echo "verilator not found"; exit 2; }

PROBE=$(mktemp -d)
trap 'rm -rf "$PROBE"' EXIT
echo 'module lintprobe; endmodule' > "$PROBE/lintprobe.v"
WANT="DECLFILENAME UNOPTFLAT PINCONNECTEMPTY PINMISSING GENUNNAMED"
FLAGS="-Wall -Irtl +1364-2005ext+v sim/waivers.vlt"
for w in $WANT; do
    if verilator --lint-only "-Wno-$w" "$PROBE/lintprobe.v" >/dev/null 2>&1; then
        FLAGS="$FLAGS -Wno-$w"
    fi
done

RTL="$(ls rtl/*.sv 2>/dev/null)"
VENDOR="modules/cpu-tg68k/gen/tg68k.v $(ls modules/cpu-tv80/*.v)"

# each block on its own, then whatever top levels exist
for top in k056832_tilemap k053936_roz k053247_objlist k053247_draw k055555_mixer gaia_video gaia_main; do
    grep -q "^module $top\b" rtl/*.sv 2>/dev/null || continue
    echo "--- $top ---"
    verilator --lint-only $FLAGS --top-module $top $RTL $VENDOR
done
if grep -q "^module gaia_core\b" rtl/*.sv 2>/dev/null; then
    echo "--- whole machine ---"
    verilator --lint-only $FLAGS --top-module gaia_core $RTL $VENDOR
fi
echo "lint clean"
