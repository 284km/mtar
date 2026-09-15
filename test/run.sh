#!/bin/sh
# test/run.sh — the oracle is bsdtar. Extract the same archive with both,
# compare a manifest that covers type, mode, size, content hash, symlink
# target and hardlink grouping.
#
#   MERE=<mere checkout> sh test/run.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
work="${WORK:-$here/.build}"
mkdir -p "$work"

echo "== build =="
"$M" -c "$here/mtar.mere" > "$work/mtar.c" 2> "$work/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$work/emit.err" >&2; exit 1; }
[ -s "$work/mtar.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }
cc -O1 -o "$work/mtar" "$work/mtar.c" "$here/fs_shim.c" 2> "$work/cc.err" || {
  echo "FAIL: cc" >&2; sed -n '1,20p' "$work/cc.err" >&2; exit 1; }

echo "== corpus =="
corp="$work/corpus"
mkdir -p "$corp"
list=$(python3 "$here/test/corpus.py" "$corp" alpine:latest redis:7-alpine 2> "$work/cover.txt")
cover=$(cat "$work/cover.txt")
echo "  $cover"

fail=0
# A corpus with no hardlinks (or no symlinks) would let that branch pass
# without ever running. Refuse to report green on an unexercised path.
for need in "'0'" "'1'" "'2'" "'5'"; do
  echo "$cover" | grep -q "$(echo "$need" | tr -d "'")=" || {
    echo "  FAIL  corpus covers no typeflag $need"; fail=1; }
done

n_ok=0
for f in $list; do
  src="$corp/$f"
  rm -rf "$work/out_mine" "$work/out_ref"
  mkdir -p "$work/out_mine" "$work/out_ref"
  "$work/mtar" extract "$src" "$work/out_mine" >/dev/null 2>"$work/$f.err" || {
    echo "  FAIL  $f: mtar exited nonzero"; sed -n "1,5p" "$work/$f.err"; fail=1; continue; }
  tar xpf "$src" -C "$work/out_ref" 2>/dev/null
  python3 "$here/test/manifest.py" "$work/out_mine" > "$work/$f.mine"
  python3 "$here/test/manifest.py" "$work/out_ref"  > "$work/$f.ref"
  n=$(grep -c . "$work/$f.ref" || true)
  if cmp -s "$work/$f.mine" "$work/$f.ref"; then
    echo "  ok    $f  ($n paths)"
    n_ok=$((n_ok + 1))
  else
    echo "  FAIL  $f  ($n paths in reference)"
    diff "$work/$f.ref" "$work/$f.mine" | head -8
    fail=1
  fi
done
[ "$n_ok" -gt 0 ] || { echo "  FAIL  no archive was actually compared"; fail=1; }
echo "  compared $n_ok archives against bsdtar (type, mode, size, sha256, symlink target, hardlink grouping)"

[ "$fail" = 0 ] && echo "mtar PASS" || echo "mtar FAIL"
exit "$fail"
