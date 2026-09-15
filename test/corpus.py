# test/corpus.py — build the test corpus from real images, and REPORT what
# typeflags it covers. A corpus that happens to contain no hardlinks would let
# the hardlink path pass without being executed, so run.sh fails when coverage
# is missing rather than reporting green on an unexercised branch.
import collections, gzip, io, os, subprocess, sys, tarfile

out = sys.argv[1]
images = sys.argv[2:]
os.makedirs(out, exist_ok=True)
cover = collections.Counter()
kept = []

for img in images:
    safe = img.replace(":", "_").replace("/", "_")
    save = os.path.join(out, f"save_{safe}.tar")
    if not os.path.exists(save):
        subprocess.run(["docker", "save", img, "-o", save], check=True)
    kept.append(save)
    with tarfile.open(save) as t:
        for m in t:
            if not m.isfile() or "blobs" not in m.name:
                continue
            data = t.extractfile(m).read()
            if data[:2] == b"\x1f\x8b":
                try: data = gzip.decompress(data)
                except Exception: continue
            if len(data) < 512 or data[257:262] != b"ustar":
                continue
            dst = os.path.join(out, f"layer_{safe}_{m.name.split('/')[-1][:8]}.tar")
            with open(dst, "wb") as f: f.write(data)
            kept.append(dst)

for path in kept:
    with open(path, "rb") as f:
        while True:
            h = f.read(512)
            if len(h) < 512 or h == b"\0" * 512: break
            cover[h[156:157].decode("latin1")] += 1
            sz = h[124:136]
            size = 0 if sz[0] & 0x80 else int(sz.rstrip(b"\0 ") or b"0", 8)
            if size > 0: f.read((size + 511) // 512 * 512)

print(" ".join(os.path.basename(k) for k in kept))
print("COVER " + " ".join(f"{k}={v}" for k, v in sorted(cover.items())), file=sys.stderr)
