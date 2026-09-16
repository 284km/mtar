#!/bin/sh
# test/whiteout.sh -- applying a layer is not extracting an archive.
#
# A tar archive cannot say "delete". A container image layer has to, so the
# image format spells deletion as a FILENAME: `.wh.x` beside x, and
# `.wh..wh..opq` inside a directory the layers below contributed nothing to.
#
# THE ORACLE IS A REAL CONTAINER. The image is built here with the host's
# docker, so the whiteouts are the ones a real builder emits and not ones this
# project invented; the answer is what a real runtime SHOWS for that image --
# `find /` inside a container. Applying the same layers with mtar has to
# produce the same set of paths.
#
# The poison at the end is the point of the file: it applies the layers with
# `extract` instead of `layer`, and that MUST fail. Without it this gate would
# pass on a build that ignores whiteouts entirely, because the deleted files
# would simply still be there and nothing would be looking.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "needs docker: the oracle is a real container" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "needs python3 to read the image layout" >&2; exit 2; }
out="$here/.build"; mkdir -p "$out"
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }

"$M" -c "$here/mtar.mere" > "$out/mtar.c" 2>"$out/e" || { echo "FAIL compile"; sed -n 1,8p "$out/e"; exit 1; }
cc -O2 -o "$out/mtar" "$out/mtar.c" "$here/fs_shim.c" 2>/dev/null || { echo "FAIL cc"; exit 1; }

echo "== an image with whiteouts in it =="
w="$out/wh"; rm -rf "$w"; mkdir -p "$w"
cat > "$w/Dockerfile" <<'EOF'
FROM alpine:latest
RUN echo kept > /kept.txt \
 && mkdir -p /d && echo a > /d/a && echo b > /d/b \
 && mkdir -p /opq && echo old1 > /opq/old1 && echo old2 > /opq/old2
RUN rm /etc/motd && rm /d/a \
 && rm -rf /opq && mkdir -p /opq && echo new > /opq/new
EOF
docker build -q -t mtar-whiteout-gate:v1 "$w" >/dev/null 2>&1; say $? "built the witness image"

rm -rf "$w/save"; mkdir -p "$w/save"
docker save mtar-whiteout-gate:v1 2>/dev/null | tar -x -C "$w/save"; say $? "docker save"

# The layer blobs, in order, gunzipped. python3 only reads the layout and
# decompresses -- it does not apply anything.
python3 - "$w/save" "$w/layers" <<'PY' > "$w/order.txt" 2>"$w/py.err"
import json, sys, os, gzip
src, dst = sys.argv[1], sys.argv[2]
os.makedirs(dst, exist_ok=True)
load = lambda d: json.load(open(os.path.join(src, "blobs", "sha256", d.split(":")[1])))
m = load(json.load(open(os.path.join(src, "index.json")))["manifests"][0]["digest"])
if "manifests" in m: m = load(m["manifests"][0]["digest"])
for i, l in enumerate(m["layers"]):
    blob = os.path.join(src, "blobs", "sha256", l["digest"].split(":")[1])
    raw = open(blob, "rb").read()
    if raw[:2] == b"\x1f\x8b": raw = gzip.decompress(raw)
    p = os.path.join(dst, "%02d.tar" % i)
    open(p, "wb").write(raw)
    print(p)
PY
nl=$(wc -l < "$w/order.txt" | tr -d ' ')
[ "$nl" -ge 3 ]; say $? "the image has $nl layers"

# The whiteouts have to actually BE there, or the rest of this file proves
# nothing. This is the same trap as a poison that misses its anchor.
n_wh=$(tar -tf "$(tail -1 "$w/order.txt")" | grep -c '\.wh\.' || true)
[ "$n_wh" -ge 3 ]; say $? "the top layer carries $n_wh whiteout entries"

echo "== the oracle: what a real runtime shows =="
docker run --rm mtar-whiteout-gate:v1 sh -c 'cd / && find kept.txt etc/motd d opq -maxdepth 2 2>/dev/null | sort' \
  > "$w/want.txt" 2>/dev/null
[ -s "$w/want.txt" ]; say $? "the oracle listed $(wc -l < "$w/want.txt" | tr -d ' ') paths"

echo "== applying the layers with mtar =="
r="$w/root"; rm -rf "$r"; mkdir -p "$r"
rc=0
while read -r t; do "$out/mtar" layer "$t" "$r" >/dev/null 2>&1 || rc=1; done < "$w/order.txt"
say $rc "mtar applied every layer"
(cd "$r" && find kept.txt etc/motd d opq -maxdepth 2 2>/dev/null | sort) > "$w/got.txt"
diff -u "$w/want.txt" "$w/got.txt" > "$w/diff.txt" 2>&1; say $? "the same paths as the container"
[ -s "$w/diff.txt" ] && sed -n 1,12p "$w/diff.txt"

# Named checks, so a failure says which rule broke rather than "the diff".
[ -f "$r/kept.txt" ];      say $? "a file from a lower layer survives"
[ ! -e "$r/etc/motd" ];    say $? ".wh.motd deleted etc/motd"
[ ! -e "$r/d/a" ];         say $? ".wh.a deleted d/a"
[ -f "$r/d/b" ];           say $? "and left its sibling d/b"
[ -f "$r/opq/new" ];       say $? "the opaque directory has this layer's file"
[ ! -e "$r/opq/old1" ] && [ ! -e "$r/opq/old2" ]
say $? "and none of what the layers below put there"
[ -z "$(find "$r" -name '.wh.*' -print -quit)" ]
say $? "no .wh. file was written out as a file"

echo "== poison: the same layers, applied as plain archives =="
# `extract` must NOT honour whiteouts -- a name is a name there. If this
# passes, `layer` and `extract` are the same thing and the flag means nothing.
p="$w/poison"; rm -rf "$p"; mkdir -p "$p"
while read -r t; do "$out/mtar" extract "$t" "$p" >/dev/null 2>&1; done < "$w/order.txt"
[ -e "$p/etc/motd" ] && [ -e "$p/etc/.wh.motd" ]
say $? "extract kept both etc/motd and the literal .wh.motd"

[ "$fail" = 0 ] && echo "whiteout PASS" || echo "whiteout FAIL"
exit "$fail"
