#!/bin/sh
# Frozen-state gate for the reference renderer.
#
# Every state in artifacts/states/<name>.txt has a matching MAME snapshot in
# artifacts/states/<name>/gaiapols/0000.png. States whose name ends in a layer
# tag were captured with that layer isolated via FORCE_ENABLE, so the model is
# asked for the same layers. Zero differing pixels is the pass condition.
#
# Usage: tools/regress_render.sh [rom-image]
set -e
ROM="${1:-gaiapolis.rom}"
[ -f "$ROM" ] || { echo "usage: $0 <gaiapolis.rom>" >&2; exit 2; }
mkdir -p artifacts/render

fail=0
for st in artifacts/states/*.txt; do
    name=$(basename "$st" .txt)
    ref="artifacts/states/$name/gaiapols/0000.png"
    [ -f "$ref" ] || continue
    case "$name" in
        *_A) layers=A ;; *_B) layers=B ;; *_C) layers=C ;; *_D) layers=D ;;
        *_tm) layers=A,B,C,D ;;
        *) continue ;;          # full-frame states need sprites + ROZ; not yet
    esac
    out=$(python3 tools/render_model.py "$st" "$ROM" --layers="$layers" \
            --out="artifacts/render/$name.png" --ref="$ref" \
            --diff="artifacts/render/${name}_diff.png" | grep differing)
    n=$(echo "$out" | sed 's/.*: \([0-9]*\) .*/\1/')
    if [ "$n" = "0" ]; then
        printf '  PASS  %-16s %s\n' "$name" "$layers"
    else
        printf '  FAIL  %-16s %s  %s\n' "$name" "$layers" "$out"
        fail=1
    fi
done
[ $fail = 0 ] && echo "all states match MAME" || echo "FAILURES"
exit $fail
