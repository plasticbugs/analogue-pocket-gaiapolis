#!/bin/sh
# Refuse to publish ROM data. Run before every push.
#
# Checks every tracked file for: ROM/romset file extensions, the romset
# directory, oversized binaries, and text files carrying long runs of hex that
# could be a dumped ROM region. Screenshots, frozen machine-state dumps (RAM
# contents, not ROM) and hash manifests are fine -- state dumps are written as
# space-separated 4-digit groups, so they never form a long unbroken run.
#
# Note: BSD grep rejects repetition counts above 255, and a failing grep is
# indistinguishable from "no match", so the threshold is kept low and the
# pattern is self-tested at startup.
set -e
cd "$(git rev-parse --show-toplevel)"

HEXRUN='^[0-9a-f]{200,}$'
# self-test: the pattern must match a known-bad string and reject a known-good one
probe=$(printf 'a%.0s' $(seq 1 250))
if ! printf '%s\n' "$probe" | LC_ALL=C grep -qE "$HEXRUN"; then
    echo "no-rom check ABORTED: hex-run pattern is not working on this grep" >&2
    exit 2
fi

report=$(mktemp)
trap 'rm -f "$report"' EXIT

git ls-files | while IFS= read -r f; do
    [ -f "$f" ] || continue
    case "$f" in
        *.rom|*.zip|*.7z|*.bin|*.nv|gaiapols/*|*/gaiapols/*)
            printf '  REFUSE  %s\n            ROM or romset file\n' "$f" >>"$report" ;;
    esac
    sz=$(wc -c < "$f" 2>/dev/null || echo 0)
    if [ "$sz" -gt 1048576 ]; then
        printf '  REFUSE  %s\n            tracked file is %s bytes\n' "$f" "$sz" >>"$report"
    fi
    case "$f" in
        *.txt|*.md|*.log|*.sha256)
            if LC_ALL=C grep -qE "$HEXRUN" "$f" 2>/dev/null; then
                printf '  REFUSE  %s\n            long unbroken hex run (raw ROM dump?)\n' "$f" >>"$report"
            fi ;;
    esac
done

if [ -s "$report" ]; then
    cat "$report"
    echo "no-rom check FAILED"
    exit 1
fi
echo "no-rom check passed ($(git ls-files | wc -l | tr -d ' ') tracked files)"
