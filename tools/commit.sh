#!/bin/sh
# The only way commits are made here: stage everything, run the ROM guard on
# the staged tree, commit with the message file, push. The guard's failure is
# fatal -- it is never piped, so its exit status cannot be lost.
#   tools/commit.sh <message-file> [--no-push]
set -e
cd "$(git rev-parse --show-toplevel)"
[ -f "$1" ] || { echo "usage: $0 <message-file> [--no-push]" >&2; exit 2; }
git add -A
tools/check-no-roms.sh
git -c user.email=scottmosch@gmail.com -c user.name="Scott Moschella" commit -q -F "$1"
[ "$2" = "--no-push" ] || git push -q origin main
git log --oneline -1
