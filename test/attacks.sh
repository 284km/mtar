#!/bin/sh
# test/attacks.sh — one archive per route in SECURITY_ROUTES.
#
# Two claims per route, and the second is the one that matters:
#   1. the guarded build REFUSES, naming the route
#   2. NOTHING was created outside the destination
#
# And a control, so the test cannot pass by the attack being harmless: the SAME
# archive is extracted by a build with the guard removed, and the run records
# whether that one escaped. A route whose control does not escape is reported as
# "not exploitable here" rather than counted as a save.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
work="$here/.build/attacks"
rm -rf "$work"; mkdir -p "$work"

# guarded
"$M" -c "$here/mtar.mere" > "$work/g.c" || exit 1
cc -O1 -o "$work/mtar" "$work/g.c" "$here/fs_shim.c" || exit 1

# unguarded control: the two guard predicates neutered, nothing else changed
mkdir -p "$work/nog"
sed -e 's|^let name_escapes = fn (p: str) ->|let name_escapes = fn (p: str) -> false;\nlet unused_name_escapes = fn (p: str) ->|' \
    -e 's|^let symlink_ancestor = fn (dest: str) -> fn (name: str) ->|let symlink_ancestor = fn (dest: str) -> fn (name: str) -> "";\nlet unused_symlink_ancestor = fn (dest: str) -> fn (name: str) ->|' \
    "$here/tar.mere" > "$work/nog/tar.mere"
cp "$here/mtar.mere" "$work/nog/mtar.mere"
"$M" -c "$work/nog/mtar.mere" > "$work/n.c" || { echo "FAIL: control build refused"; exit 1; }
cc -O1 -o "$work/mtar-unguarded" "$work/n.c" "$here/fs_shim.c" || exit 1

python3 "$here/test/attack.py" "$work/tars" "$work/escape" >/dev/null

fail=0
for r in r1 r2 r3 r4; do
  tar="$work/tars/attack_$r.tar"

  # --- control: does this attack work at all without the guard? ---
  rm -rf "$work/dest" "$work/escape"; mkdir -p "$work/dest" "$work/escape"
  echo "top secret" > "$work/escape/secret"
  "$work/mtar-unguarded" extract "$tar" "$work/dest" >/dev/null 2>&1
  if [ -e "$work/escape/pwned-$r" ] || [ -e "$work/dest/sub/leak" ]; then control=ESCAPES; else control=harmless; fi

  # --- guarded ---
  rm -rf "$work/dest" "$work/escape"; mkdir -p "$work/dest" "$work/escape"
  echo "top secret" > "$work/escape/secret"
  "$work/mtar" extract "$tar" "$work/dest" > "$work/$r.out" 2>&1
  rc=$?
  named=$(grep -c "R[0-9]" "$work/$r.out" 2>/dev/null); [ -n "$named" ] || named=0

  leaked=no
  [ -e "$work/escape/pwned-$r" ] && leaked=yes
  # R4 leaks by exposing the outside file INSIDE the destination
  if [ -e "$work/dest/sub/leak" ]; then
    grep -q "top secret" "$work/dest/sub/leak" 2>/dev/null && leaked=yes
  fi

  if [ "$rc" != 0 ] && [ "$named" -ge 1 ] && [ "$leaked" = no ]; then
    echo "  ok    $r  refused by name, nothing escaped   (unguarded control: $control)"
    [ "$control" = ESCAPES ] || echo "        note: this route is not exploitable in this build even unguarded"
  else
    echo "  FAIL  $r  exit=$rc named=$named leaked=$leaked  (unguarded control: $control)"
    sed -n '1,3p' "$work/$r.out"
    fail=1
  fi
done
[ "$fail" = 0 ] && echo "attacks PASS" || echo "attacks FAIL"
exit "$fail"
