#!/bin/sh
# test/create.sh — what this writes, read by tar.
#
# The reader in this package has been checked against tar from the beginning;
# the writer is new, and the question is the mirror of the old one: does the
# archive it produces mean, to somebody else's reader, the tree it came from?
#
# `tar tvf` accepting it is not enough -- a reader will accept a great many
# archives that are not what was asked for. The judgement is EXTRACTING it with
# tar and diffing the result against the original tree.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v tar >/dev/null 2>&1 || { echo "needs tar, for the oracle" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

"$M" -c "$here/mtar.mere" > "$out/mtar.c" 2>"$out/e" || { echo "FAIL: emit"; sed -n 1,8p "$out/e"; exit 1; }
cc -O2 -o "$out/mtar" "$out/mtar.c" "$here/fs_shim.c" 2>/dev/null || { echo "FAIL: cc"; exit 1; }
say 0 "mtar builds"

# Shapes a writer can get individually wrong: an empty file (size 0 and no
# body), a file whose size is not a multiple of the block, a directory with a
# mode of its own, a symlink, a name that does not fit the 100-byte field, and
# a name that needs the prefix split at a slash.
mkdir -p "$T/src/sub/deeper" "$T/src/$(printf 'd%.0s' $(seq 1 90))"
: > "$T/src/empty"
printf 'hello\n' > "$T/src/a.txt"
printf 'x%.0s' $(seq 1 5000) > "$T/src/sub/unaligned"
head -c 200000 /dev/urandom > "$T/src/sub/deeper/binary"
ln -s ../a.txt "$T/src/sub/link"
chmod 750 "$T/src/sub"
chmod 700 "$T/src/a.txt"
printf 'deep\n' > "$T/src/$(printf 'd%.0s' $(seq 1 90))/$(printf 'f%.0s' $(seq 1 60))"

"$out/mtar" create "$T/out.tar" "$T/src" > "$T/create.log" 2>&1
say $? "mtar create"
grep -q "wrote " "$T/create.log"; say $? "and said how many entries ($(sed 's/.*wrote //' "$T/create.log"))"

tar tf "$T/out.tar" > "$T/list.txt" 2>"$T/tar.err"
say $? "tar reads it"
[ ! -s "$T/tar.err" ]; say $? "without complaining ($(head -1 "$T/tar.err"))"

mkdir -p "$T/back"
tar xf "$T/out.tar" -C "$T/back" 2>/dev/null
diff -r "$T/src" "$T/back" >/dev/null 2>&1
say $? "extracting it with tar gives back the tree it came from"
[ "$(stat -f '%Lp' "$T/back/sub")" = 750 ]; say $? "including a directory's own mode"
[ "$(stat -f '%Lp' "$T/back/a.txt")" = 700 ]; say $? "and a file's"
[ -L "$T/back/sub/link" ]; say $? "and the symlink is a symlink"

# Our own reader, on our own writer. Not a substitute for the check above --
# two halves of one program agreeing proves only that they agree.
mkdir -p "$T/mine"
"$out/mtar" extract "$T/out.tar" "$T/mine" >/dev/null 2>&1
diff -r "$T/src" "$T/mine" >/dev/null 2>&1
say $? "and this package's own reader gives back the same tree"

# The same tree twice is the same archive. A layer that is rebuilt should not
# get a new digest because a directory was read in a different order.
"$out/mtar" create "$T/again.tar" "$T/src" >/dev/null 2>&1
cmp -s "$T/out.tar" "$T/again.tar"
say $? "the same tree written twice is byte for byte the same archive"

echo "== what it refuses =="
mkfifo "$T/src/fifo" 2>/dev/null && {
  "$out/mtar" create "$T/bad.tar" "$T/src" > "$T/bad.log" 2>&1
  [ "$?" != 0 ] && grep -q "not a file, a directory or a symlink" "$T/bad.log"
  say $? "a fifo is refused by name rather than written as a regular file"
  rm -f "$T/src/fifo"
} || echo "  --    (no mkfifo here)"

echo "== poison: break the checksum =="
# The header's checksum is computed over the header with its own field full of
# spaces. Getting that wrong produces an archive that this package's reader
# might still accept -- tar is the one that has to notice.
sed 's|let _ = put_bytes h 148 (oct_field ck 7) in|let _ = put_bytes h 148 (oct_field (ck + 1) 7) in|' \
  "$here/tar.mere" > "$T/poison_tar.mere"
cmp -s "$here/tar.mere" "$T/poison_tar.mere" && { echo "  FAIL  the poison changed nothing"; fail=1; }
sed "s|import \"tar.mere\";|import \"$T/poison_tar.mere\";|" "$here/mtar.mere" > "$T/poison_mtar.mere"
if "$M" -c "$T/poison_mtar.mere" > "$T/p.c" 2>/dev/null && cc -O2 -o "$T/mtar-poison" "$T/p.c" "$here/fs_shim.c" 2>/dev/null; then
  "$T/mtar-poison" create "$T/poison.tar" "$T/src" >/dev/null 2>&1
  tar tf "$T/poison.tar" >/dev/null 2>&1 \
    && { echo "  FAIL  tar accepted an archive with a wrong checksum"; fail=1; } \
    || echo "  ok    tar refuses an archive whose checksum is wrong"
else
  echo "  FAIL  the poisoned writer did not build"; fail=1
fi

[ "$fail" = 0 ] && echo "create PASS" || echo "create FAIL"
exit "$fail"
