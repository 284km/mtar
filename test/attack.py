# test/attack.py — generate one archive per escape route in SECURITY_ROUTES.
# Each one tries to create a file at ESCAPE/<marker>, outside the destination.
import os, io, sys, tarfile

out, escape = sys.argv[1], os.path.abspath(sys.argv[2])
os.makedirs(out, exist_ok=True)

def payload(name):
    b = b"pwned\n"
    t = tarfile.TarInfo(name); t.size = len(b); t.mode = 0o644
    return t, io.BytesIO(b)

def write(fn, build):
    with tarfile.open(os.path.join(out, fn), "w", format=tarfile.USTAR_FORMAT) as t:
        build(t)

# R1: an absolute name pointing straight at the escape directory.
def r1(t):
    ti, f = payload(escape + "/pwned-r1"); t.addfile(ti, f)
write("attack_r1.tar", r1)

# R2: climb out with "..". dest is <work>/dest, escape is <work>/escape.
def r2(t):
    ti, f = payload("../escape/pwned-r2"); t.addfile(ti, f)
write("attack_r2.tar", r2)

# R3: a legitimate-looking symlink, then a write through it. This is the one a
# name-only check does not see -- neither entry's name contains ".." or "/".
def r3(t):
    ln = tarfile.TarInfo("stage"); ln.type = tarfile.SYMTYPE
    ln.linkname = escape; ln.mode = 0o777
    t.addfile(ln)
    ti, f = payload("stage/pwned-r3"); t.addfile(ti, f)
write("attack_r3.tar", r3)

# R4: a hardlink whose target is outside. Extracting it exposes the outside
# file's contents under a name inside the destination.
def r4(t):
    d = tarfile.TarInfo("sub"); d.type = tarfile.DIRTYPE; d.mode = 0o755
    t.addfile(d)
    ln = tarfile.TarInfo("sub/leak"); ln.type = tarfile.LNKTYPE
    # dest is <work>/dest and the target is <work>/escape, so ONE level up.
    # The first version wrote "../../" and climbed past the target, which made
    # the unguarded control report "harmless" -- the attack missing, not the
    # code being safe. An attack input has to be verified to reach its target.
    ln.linkname = "../escape/secret"
    t.addfile(ln)
write("attack_r4.tar", r4)

print("r1 r2 r3 r4")
