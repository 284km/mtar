#!/bin/sh
# test/upper.sh -- the upper directory of an overlay mount, written as a layer.
#
# THE ORACLE IS THE KERNEL. An overlay mount is a lower directory, an upper
# directory and a merged view, and the kernel maintains the relationship
# exactly. So the question "did this layer capture what the step changed?" has
# an answer that needs no judgement:
#
#     merged  ==  apply(lower) then apply-as-layer(upper)
#
# The left side is what the container saw. The right side is what anyone who
# pulls the image will get. If they differ, the layer is wrong -- and the
# difference is named, because it is a diff of two directory listings.
#
# Needs privileges to mount, so it runs in a --privileged container -- and on a
# tmpfs, because an overlay upper directory must be able to hold trusted.*
# xattrs and the container own root is itself an overlay, which cannot.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${IMG:-gcc:14}"
MERE="${MERE:-}"
[ -n "$MERE" ] || { echo "set MERE=<path to a merelang/mere checkout>" >&2; exit 2; }
M="$MERE/_build/default/bin/mere.exe"
[ -x "$M" ] || { echo "no mere binary at $M" >&2; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "needs docker: the oracle is a real overlay mount" >&2; exit 2; }
work="$here/.build"; mkdir -p "$work"

echo "== emit (host) =="
"$M" -c "$here/mtar.mere" > "$work/mtar-upper.c" 2> "$work/emit.err" || {
  echo "FAIL: mere -c refused" >&2; sed -n '1,20p' "$work/emit.err" >&2; exit 1; }

echo "== mount, change, capture (linux aarch64, root, in $IMG) =="
docker run --rm --privileged --tmpfs /t:rw,exec -v "$here:/w" -w /w "$IMG" sh -c '
set -u
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
cc -O1 -o .build/mtar-upper .build/mtar-upper.c fs_shim.c || exit 1
mtar=/w/.build/mtar-upper

# /t is a tmpfs: an upper directory has to hold trusted.* xattrs, and neither
# the container own overlay root nor a bind mount backed by macOS can.
mkdir -p /t/lower /t/upper /t/work /t/merged

# What the layers below already had.
mkdir -p /t/lower/etc /t/lower/d /t/lower/opq
echo motd            > /t/lower/etc/motd
echo keep            > /t/lower/keep.txt
echo a               > /t/lower/d/a
echo b               > /t/lower/d/b
echo old1            > /t/lower/opq/old1
echo old2            > /t/lower/opq/old2
( cd /t/lower && tar cf /t/lower.tar . ) || exit 1

mount -t overlay overlay -o lowerdir=/t/lower,upperdir=/t/upper,workdir=/t/work,redirect_dir=off,metacopy=off /t/merged
say $? "mounted an overlay"

# A step: it deletes, it writes, it replaces a whole directory.
( cd /t/merged \
  && rm etc/motd \
  && rm d/a \
  && echo new > new.txt \
  && echo more >> keep.txt \
  && rm -rf opq && mkdir opq && echo fresh > opq/fresh )
say $? "a step ran against the merged view"

# The kernel spelling of what it did.
[ -c /t/upper/etc/motd ]; say $? "overlayfs marked the deleted file as a device node"
python3 -c "import os,sys; sys.exit(0 if os.getxattr(sys.argv[1], b\"trusted.overlay.opaque\") == b\"y\" else 1)" /t/upper/opq 2>/dev/null
say $? "and the replaced directory as opaque"

echo "== the layer =="
$mtar upper /t/layer.tar /t/upper 2>&1 | tail -1
[ -s /t/layer.tar ]; say $? "mtar wrote a layer from the upper directory"
tar -tf /t/layer.tar | grep -q "etc/.wh.motd";        say $? "the deletion is a .wh. entry"
tar -tf /t/layer.tar | grep -q "d/.wh.a";             say $? "so is the other one"
tar -tf /t/layer.tar | grep -q "opq/.wh..wh..opq";    say $? "the replaced directory carries the opaque marker"

echo "== the oracle: merged == lower + layer =="
mkdir -p /t/rebuilt
$mtar extract /t/lower.tar /t/rebuilt >/dev/null 2>&1
$mtar layer   /t/layer.tar /t/rebuilt >/dev/null 2>&1; say $? "applied both"
man() { ( cd "$1" && find . -printf "%y %m %p %l\n" | sort ) ; \
        ( cd "$1" && find . -type f -exec sha256sum {} \; | sed "s| .*/| |" | sort ) ; }
man /t/merged  > /t/want.txt
man /t/rebuilt > /t/got.txt
diff -u /t/want.txt /t/got.txt > /t/diff.txt 2>&1
say $? "what the container saw is what the image gives back"
[ -s /t/diff.txt ] && sed -n 1,15p /t/diff.txt

# Poison: the same upper written as a plain directory. `create` must refuse the
# device node rather than write it as a file -- an archive nobody can see is
# wrong is the failure this whole file exists to prevent.
$mtar create /t/plain.tar /t/upper >/t/plain.out 2>&1
rc=$?
[ "$rc" != 0 ] && grep -q "not a file, a directory or a symlink" /t/plain.out
say $? "poison: as a plain directory the device node is refused by name"

umount /t/merged 2>/dev/null
[ "$fail" = 0 ] && echo "upper PASS" || echo "upper FAIL"
exit "$fail"
'
