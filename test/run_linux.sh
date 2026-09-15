#!/bin/sh
# test/run_linux.sh — the same comparison on Linux aarch64, as root.
#
# Two things only show up here. (1) The guest is where mtar actually runs, and
# "fork/exec is POSIX" is not the same as having measured it. (2) As ROOT, tar
# restores uid/gid; as a non-root user on macOS it silently cannot, so the
# macOS run cannot tell whether mtar chowns at all. This one compares owner.
#
# Extraction happens inside the container's OWN filesystem, not the mounted
# working directory: a bind mount backed by macOS keeps neither uid 0 nor a
# mode-000 file, so comparing there measures the mount instead of mtar.
#
# The corpus must already exist (build it with test/run.sh on the host: that
# step needs docker, which is not available inside this container).
#
#   sh test/run_linux.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${IMG:-gcc:14}"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
work="$here/.build"
corp="$work/corpus"
ls "$corp"/*.tar >/dev/null 2>&1 || { echo "no corpus: run test/run.sh on the host first" >&2; exit 2; }

echo "== emit (host) =="
"$M" -c "$here/mtar.mere" > "$work/mtar-linux.c" 2> "$work/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$work/emit.err" >&2; exit 1; }
[ -s "$work/mtar-linux.c" ] || { echo "FAIL: emitted C is empty" >&2; exit 1; }

echo "== compile + compare (linux aarch64, root, in $IMG) =="
docker run --rm -v "$here:/w" -w /w "$IMG" sh -c '
set -u
cc -O1 -o .build/mtar-linux .build/mtar-linux.c fs_shim.c || exit 1
# type, mode, owner, path, symlink target -- plus a content hash for files.
man() {
  ( cd "$1" && find . -printf "%y %m %U:%G %p %l\n" | sort )
  ( cd "$1" && find . -type f -exec sha256sum {} \; | sort )
}
fail=0; n=0
for src in .build/corpus/*.tar; do
  rm -rf /tmp/lx_mine /tmp/lx_ref; mkdir -p /tmp/lx_mine /tmp/lx_ref
  ./.build/mtar-linux extract "$src" /tmp/lx_mine >/dev/null 2>/tmp/lx.err || {
    echo "  FAIL  $(basename $src): mtar exited nonzero"; sed -n 1,3p /tmp/lx.err; fail=1; continue; }
  tar xpf "$src" -C /tmp/lx_ref 2>/dev/null
  man /tmp/lx_mine > /tmp/lx.mine; man /tmp/lx_ref > /tmp/lx.ref
  if cmp -s /tmp/lx.mine /tmp/lx.ref; then
    echo "  ok    $(basename $src)  ($(wc -l < /tmp/lx.ref | tr -d " ") rows)"; n=$((n+1))
  else
    echo "  FAIL  $(basename $src)"; diff /tmp/lx.ref /tmp/lx.mine | head -8; fail=1
  fi
done
[ "$n" -gt 0 ] || { echo "  FAIL  nothing compared"; fail=1; }
echo "  compared $n archives against GNU tar as root (type, mode, OWNER, path, symlink target, sha256)"
exit $fail
'
rc=$?
[ "$rc" = 0 ] && echo "mtar/linux PASS" || echo "mtar/linux FAIL"
exit "$rc"
