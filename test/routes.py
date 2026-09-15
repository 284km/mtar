# Enumerate the escape routes and ask the corpus which of them actually occur.
import os, sys, collections
res = collections.Counter(); ex = collections.defaultdict(list)

def note(route, detail):
    res[route] += 1
    if len(ex[route]) < 3: ex[route].append(detail)

for path in sorted(sys.argv[1:]):
    symlinks = {}          # name -> target, as created earlier in THIS archive
    dirs = set()
    with open(path, "rb") as f:
        while True:
            h = f.read(512)
            if len(h) < 512 or h == b"\0"*512: break
            name = h[0:100].rstrip(b"\0").decode("latin1")
            prefix = h[345:500].rstrip(b"\0").decode("latin1")
            full = (prefix + "/" + name) if prefix else name
            t = h[156:157].decode("latin1")
            link = h[157:257].rstrip(b"\0").decode("latin1")
            sz = h[124:136]
            size = 0 if sz[0] & 0x80 else int(sz.rstrip(b"\0 ") or b"0", 8)

            # R1 absolute name
            if full.startswith("/"): note("R1 absolute name", full)
            # R2 dotdot component in the name
            if any(c == ".." for c in full.split("/")): note("R2 dotdot in name", full)
            # R3 write THROUGH a symlink created earlier in the same archive
            parts = full.rstrip("/").split("/")
            for i in range(1, len(parts)):
                anc = "/".join(parts[:i])
                if anc in symlinks:
                    note("R3 ancestor is a symlink", f"{full}  (via {anc} -> {symlinks[anc]})")
                    break
            # R4 hardlink target escaping
            if t == "1":
                if link.startswith("/") or any(c == ".." for c in link.split("/")):
                    note("R4 hardlink target escapes", f"{full} -> {link}")
            # R5 symlink TARGET pointing outside (legitimate in a rootfs)
            if t == "2":
                if link.startswith("/"): note("R5 symlink target absolute (legitimate)", f"{full} -> {link}")
                elif any(c == ".." for c in link.split("/")): note("R5b symlink target has dotdot", f"{full} -> {link}")
                symlinks[full.rstrip("/")] = link
            if t == "5": dirs.add(full.rstrip("/"))
            if size > 0: f.read((size + 511)//512*512)

print(f"scanned {len(sys.argv)-1} archives")
for k in sorted(res): 
    print(f"  {k}: {res[k]}")
    for e in ex[k]: print(f"      e.g. {e}")
for k in ["R1 absolute name","R2 dotdot in name","R3 ancestor is a symlink","R4 hardlink target escapes","R5b symlink target has dotdot"]:
    if k not in res: print(f"  {k}: 0")
