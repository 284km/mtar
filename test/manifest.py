# test/manifest.py — one line per path, identical on macOS and Linux.
# type, mode, size-or-target, sha256 for regular files, and the hardlink
# grouping (inode identity collapsed to a group id, so two extractors agree
# on WHICH files share an inode without agreeing on the inode number).
import hashlib, os, sys

root = sys.argv[1]
rows = []
groups = {}
for dirpath, dirnames, filenames in os.walk(root):
    dirnames.sort()
    for n in sorted(dirnames) + sorted(filenames):
        p = os.path.join(dirpath, n)
        rel = os.path.relpath(p, root)
        st = os.lstat(p)
        mode = oct(st.st_mode & 0o7777)
        if os.path.islink(p):
            rows.append(f"l {mode} {rel} -> {os.readlink(p)}")
        elif os.path.isdir(p):
            rows.append(f"d {mode} {rel}")
        else:
            h = hashlib.sha256(open(p, "rb").read()).hexdigest()[:16]
            key = (st.st_dev, st.st_ino)
            g = groups.setdefault(key, len(groups))
            nl = st.st_nlink
            rows.append(f"f {mode} {rel} {st.st_size} {h} links={nl} grp={g if nl > 1 else '-'}")
print("\n".join(sorted(set(rows))))
