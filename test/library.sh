#!/bin/sh
# test/library.sh — mtar is vendored into a daemon, so a refusal must not exit.
#
# Three malformed archives, then a good one, all in one process. The program
# prints STILL RUNNING at the end; if a refusal took the process down, that
# line never appears and neither do the refusals after the first.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
out="$here/.build/lib"; rm -rf "$out"; mkdir -p "$out/dest"

"$M" -c "$here/test/lib_survives.mere" > "$out/l.c" 2> "$out/e" || { echo "FAIL: emit"; sed -n 1,10p "$out/e"; exit 1; }
cc -O1 -o "$out/lib_survives" "$out/l.c" "$here/fs_shim.c" || { echo "FAIL: cc"; exit 1; }

python3 - "$out" <<'PY'
import io, os, sys, tarfile
out = sys.argv[1]
# A header with a good checksum but a name that climbs out.
with tarfile.open(f"{out}/traversal.tar", "w", format=tarfile.USTAR_FORMAT) as t:
    b = b"x"; ti = tarfile.TarInfo("../escaped"); ti.size = len(b)
    t.addfile(ti, io.BytesIO(b))
with tarfile.open(f"{out}/good.tar", "w", format=tarfile.USTAR_FORMAT) as t:
    b = b"ok\n"; ti = tarfile.TarInfo("good.txt"); ti.size = len(b)
    t.addfile(ti, io.BytesIO(b))
raw = open(f"{out}/good.tar", "rb").read()
# Truncated mid-header, and a header whose magic is not ustar.
open(f"{out}/truncated.tar", "wb").write(raw[:300])
bad = bytearray(raw); bad[257:262] = b"nope!"
open(f"{out}/badmagic.tar", "wb").write(bytes(bad))
PY

"$out/lib_survives" "$out/truncated.tar" "$out/badmagic.tar" "$out/traversal.tar" \
                    "$out/good.tar" "$out/dest" > "$out/log" 2>&1
rc=$?
cat "$out/log"

fail=0
c() { n=$(grep -c "$1" "$out/log" 2>/dev/null); [ -n "$n" ] || n=0; echo "$n"; }
chk() { if [ "$(c "$1")" = "$2" ]; then echo "  ok    $3"; else echo "  FAIL  $3"; fail=1; fi; }
chk '^truncated: refused' 1 'a truncated archive is refused, not reported as a short one'
chk '^bad-magic: refused' 1 'a refusal after a refusal still happens (the process did not exit)'
chk '^traversal: refused' 1 'and a third one'
chk '^good: accepted'     1 'a good archive still reads after three refusals'
chk '^STILL RUNNING$'     1 'the process reached the end'
[ "$rc" = 0 ] && echo "  ok    exit 0" || { echo "  FAIL  exit $rc"; fail=1; }
[ "$fail" = 0 ] && echo "library PASS" || echo "library FAIL"
exit "$fail"
