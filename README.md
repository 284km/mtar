# mtar

A POSIX USTAR reader and extractor written in [Mere](https://merelang.org/),
for reading container image layers. Verified against `bsdtar` on macOS and
against GNU `tar` running as root on Linux — type, mode, owner, size, content
hash, symlink target, and which files share an inode.

```sh
export MERE=/path/to/a/merelang/mere/checkout
mere -c mtar.mere > m.c && cc -O2 m.c fs_shim.c -o mtar

./mtar list    image.tar
./mtar extract image.tar ./rootfs
```

## The scope is measured, not guessed

`test/corpus.py` sweeps every layer of the images you name and reports which
tar typeflags actually appear. Across `alpine:latest` and `redis:7-alpine`:

```
COVER 0=657  1=258  2=1098  5=343
```

regular files, **hardlinks**, symlinks, directories — and nothing else. No PAX
headers, no GNU long names, no base-256 sizes, `ustar\0` magic throughout, every
name under 100 bytes.

`alpine` alone would have hidden the hardlinks: its layers use only `0`, `2` and
`5`. One image is not a corpus, which is why the sweep takes a list.

So mtar implements those four and **refuses everything else by name**:

```
mtar: refused: a PAX extended header (typeflag 'x')  [var/lib/whatever]
mtar: refused: a base-256 size field (file larger than 8 GiB)  [big.img]
```

A refusal that names what it refused tells the next person exactly which
feature to add. An extractor that silently approximates does not.

## Testing

```sh
export MERE=/path/to/mere
sh test/run.sh          # extract with mtar and with bsdtar, compare manifests
sh test/run_linux.sh    # the same on linux/arm64 as root, comparing owner too
```

`test/run.sh` fails if the corpus does not cover all four typeflags, so the
hardlink path cannot pass by never running. Both scripts need `docker` for the
corpus; `IMG` selects the Linux image (default `gcc:14`).

Two poisons were used to check the harness itself is load-bearing: disabling
`fs_chmod` turns every archive red, and turning `fs_link` into `symlink` turns
red **only** the one layer that contains hardlinks.

## Escaping the destination

Layers are untrusted input. The escape routes are enumerated in
[SECURITY_ROUTES](SECURITY_ROUTES) and the corpus was asked which of them occur
legitimately *before* any was refused, because the answer decides the design:

- an absolute name, a `..` component, an ancestor that is a symlink, and a
  hardlink target leaving the destination — **0 occurrences, all refused**
- a symlink whose *target* is absolute or contains `..` — **1,836 occurrences,
  allowed**. `/bin/sh -> /bin/busybox` and `etc/mtab -> ../proc/mounts` are what
  a rootfs is made of, and a stored target writes nothing

So mtar stores any target and refuses to write *through* one. The ancestor check
asks the filesystem rather than this archive, because the symlink a layer writes
through may have come from the layer below it.

```sh
sh test/attacks.sh   # one crafted archive per route
```

Each route is checked twice: the guarded build refuses it by name, **and nothing
appears outside the destination**. A second binary with the guard removed runs
the same archives as a control, so no route can be recorded as blocked when the
attack was never going to work — which is how R4 was caught aiming one directory
past its target.

## What it does not do yet

- No writing — reading only. A tar writer arrives when something needs to push.
- No overlayfs whiteouts (`.wh.*`), so this reads a layer but does not stack one.
- No gzip. Layers are usually `.tar.gz`; decompress them first
  ([mgz](https://github.com/284km/mgz) does that in Mere).

## Why the C file

Mere has `mkdir_p`, `write_bytes` and `file_pread_bytes`, but no `symlink`, no
`link`, no `chmod` and no `chown`. `fs_shim.c` is those four calls and nothing
else. `lchmod` and `lchown` are the symlink-safe spellings: plain `chmod` on a
symlink would change the target instead, and on Linux `lchmod` does not exist,
so the shim reports "not applicable" rather than claiming a write it did not
make.


## Writing

```sh
mtar create archive.tar dir
```

Not the reader backwards. Reading an archive means believing what the header
says; writing one means **deciding** what it says, and every field that is a
choice is made in one place and written down: the octal fields, the checksum
computed over a header whose own checksum field is full of spaces, the split of
a long name between `name[100]` and `prefix[155]` at a slash.

The same subset this package reads — regular files, directories and symlinks.
Anything else is **refused by name**: a device node or a socket written as a
regular file is an archive that is wrong in a way no reader can see. So is a
name that fits neither field, and a file whose size will not cross the FFI
boundary — a silently truncated size writes a header that says one length and a
body that is another, which every reader would believe.

**The same tree twice is the same archive.** Directory entries are sorted, so a
layer that is rebuilt does not get a new digest because a directory was read in
a different order.

`test/create.sh` is the check and its oracle is `tar`: not that `tar tvf`
accepts the archive — a reader accepts a great many archives that are not what
was asked for — but that **extracting it with `tar` gives back the tree it came
from**, modes and symlinks included. Its poison adds one to the checksum, and
`tar` is the one that has to notice.

## Applying a layer

```
mtar layer layer.tar ./rootfs
```

A tar archive cannot say **delete**. A container image layer has to, so the
image format spells deletion as a *filename*: `.wh.x` beside `x` means x is
gone, and `.wh..wh..opq` in a directory means the layers below contributed
nothing to it.

**The reader cannot decide this.** `mtar extract` on an archive that happens to
hold a file called `.wh.x` must write that file — the name means nothing there.
Only the caller applying a *layer* knows the convention is in force, which is
why it is a second spelling and not a rule of the reader. The gate poisons
exactly that: it applies the same layers with `extract` and requires both
`etc/motd` and a literal `etc/.wh.motd` to be there afterwards.

The apply runs the walk **twice** — once for the deletions, once for the
entries. A whiteout is a statement about the layers *below*, and the same layer
may put something back where it just cleared: `.wh.x` followed by `x`, or an
opaque directory that is then refilled. In one pass the answer depends on the
order the archive happens to list a directory in.

`test/whiteout.sh`'s oracle is **a real container**: the image is built with
docker, so the whiteouts are the ones a real builder emits, and the expected
answer is what a real runtime shows for it — `find /` inside the container.

## Writing a layer

```
mtar upper layer.tar ./overlay-upper-dir
```

The upper directory of an overlay mount **is** the layer: what a build step
changed, and nothing else. But the kernel and the image format do not spell the
same things the same way, and exactly two entries need translating:

| overlayfs | image layer |
|---|---|
| a character device `0:0` | a file called `.wh.<name>` |
| xattr `trusted.overlay.opaque=y` | a file called `.wh..wh..opq` inside |

`mtar create` on the same directory **refuses** the device node by name, and
that is the right answer there — a directory is a directory. Which alphabet is
in force is the caller's to say, so it is a second spelling, as with
`extract` / `layer`.

`test/upper.sh`'s oracle is **the kernel**: it mounts a real overlay, runs a
step against the merged view, and requires

```
merged  ==  apply(lower) then apply-as-layer(upper)
```

The left side is what the container saw; the right side is what anyone pulling
the image gets. It runs on a tmpfs — an upper directory has to hold `trusted.*`
xattrs, and a container's own overlay root cannot be one.
