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

## What it does not do yet

- **No path traversal guard.** An entry named `../etc/passwd` escapes the
  destination. Layers are untrusted input; this is the next thing to fix.
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
