#!/usr/bin/env python3
"""Build probe 6b â€” force the respawn roll to land on an unresolvable path.

Probe 6 showed that SELECTING an unresolvable skin is a silent no-op. That is suggestive but
not sufficient: selection goes through GA_Player_ChangeSkin, and the respawn roll is a
different code path. It is the ROLL that docs/05-v2-distribution.md says produces "a broken
or invisible player model", and that claim is still [INFERRED]. It is also the entire reason
a reserved slot costs ~10 MB.

At probe 6's 7 roster entries an unresolvable path comes up ~1 death in 7, so several clean
respawns prove nothing. This stacks the deck instead:

  * every ORIGINAL vanilla entry is repointed to an unresolvable path (bpset)
  * ten more unresolvable paths are appended
  * exactly ONE resolvable entry remains â€” the October clone

So 15 of 16 entries resolve to nothing, and â€” this is the point â€” **no entry points at a
base ScavGirl mesh any more**. That makes the readout unambiguous:

  spawn looks DEFAULT     -> the engine fell back. Unresolvable paths are harmless in the
                             roll, the "must resolve" rule is wrong, and placeholders (and
                             their ~10 MB/slot) are unnecessary.
  spawn is INVISIBLE/broken -> the rule holds and placeholders are mandatory.
  spawn is OCTOBER        -> ~6% chance; confirms CMSF-appended entries participate in the
                             roll at all, which makes every other observation meaningful.

This pak deliberately strips vanilla skins out of the respawn pool. It is a diagnostic, not
something to leave installed. Untick it and everything reverts â€” nothing is written to disk
by the game.

Usage:
    python tools/build_probe6b.py
"""
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import fwlocate  # noqa: E402  (local module, beside this script)

AES = fwlocate.aes()
RETOC = fwlocate.retoc()
USMAP = fwlocate.usmap()
PAKS = fwlocate.paks()

BP_REL = "ForeverWinter/Content/FW/Player/Class/BP_Player_Girl.uasset"
TEMPLATE_MESH = "ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.uasset"
SLOT_DIR = "ForeverWinter/Content/CMSF/Girl/00"
MESH_OBJ = "SK_CMSF_Girl_00"
MESH_PATH = f"/Game/CMSF/Girl/{'00'}/{MESH_OBJ}.{MESH_OBJ}"

VANILLA_COUNT = 5          # indices 0-4, repointed to nothing
EXTRA_MISSING = 10         # appended, also nothing
PAK = "CMSF_P6B_9_P"


def missing_path(n):
    return f"/Game/CMSF/Girl/{n}/SK_CMSF_Girl_{n}.SK_CMSF_Girl_{n}"


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def main():
    build = ROOT / "build" / "probe6b"
    if build.exists():
        shutil.rmtree(build)
    src, stage, work = build / "src", build / "stage", build / "work"
    out = ROOT / "dist" / "probe6b"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for d in (src, work):
        d.mkdir(parents=True)

    print("==> building tools")
    for t in ("skinpatch", "mshgen"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"], quiet=True)
    skinpatch = ROOT / "tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
    mshgen    = ROOT / "tools/mshgen/bin/Release/net8.0/mshgen.exe"

    print("==> extracting from the live cook")
    for f in ("BP_Player_Girl", "SK_SCV_FL_OCT"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src], quiet=True)

    print("==> the one resolvable entry (October clone, identity-rewritten)")
    run([mshgen, src / TEMPLATE_MESH, USMAP, stage / SLOT_DIR / f"{MESH_OBJ}.uasset", MESH_OBJ], quiet=True)

    # --- repoint every vanilla entry at nothing ----------------------------------------
    # bpset takes one index at a time, so chain through intermediates.
    print(f"==> repointing {VANILLA_COUNT} vanilla entries to unresolvable paths")
    cur = src / BP_REL
    for i in range(VANILLA_COUNT):
        nxt = work / f"bp{i}.uasset"
        run([skinpatch, "bpset", cur, USMAP, nxt, str(i), missing_path(80 + i)], quiet=True)
        cur = nxt

    print(f"==> appending 1 resolvable + {EXTRA_MISSING} unresolvable")
    (stage / BP_REL).parent.mkdir(parents=True, exist_ok=True)
    appends = [MESH_PATH] + [missing_path(85 + i) for i in range(EXTRA_MISSING)]
    run([skinpatch, "bpadd", cur, USMAP, stage / BP_REL] + appends)

    print("==> packing")
    run([RETOC, "to-zen", "--version", "UE5_4", stage, out / f"{PAK}.utoc"], quiet=True)
    print(f"    {PAK}  {sum(f.stat().st_size for f in out.iterdir())/1024/1024:.2f} MB")

    # --- verify (full game mounted, ALWAYS filtered) ------------------------------------
    print("==> verifying")
    vsrc, vout = build / "vsrc", build / "vout"
    vsrc.mkdir(parents=True)
    for f in Path(PAKS).iterdir():
        if f.suffix in (".pak", ".utoc", ".ucas"):
            os.link(f, vsrc / f.name)
    for f in out.iterdir():
        shutil.copy(f, vsrc / f.name)
    # -f is mandatory: unfiltered against a full mount this extracts the entire cook.
    for filt in ("BP_Player_Girl", "SK_CMSF_Girl"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout], quiet=True)

    roster = run([skinpatch, "bpskins", vout / BP_REL, USMAP], quiet=True)
    resolvable = roster.count(f"/Game/CMSF/Girl/00/{MESH_OBJ}")
    # Count only indexed elements â€” bpskins' header line also starts with '['.
    total = sum(1 for ln in roster.splitlines() if re.match(r"^\[\d+\]", ln.strip()))
    vanilla_left = roster.count("/Game/Character/Scavengers/Female/SK_SCV_FL")
    shipped = (vout / SLOT_DIR / f"{MESH_OBJ}.uasset").is_file()

    print(f"    roster entries    {total}")
    print(f"    resolvable (Oct)  {resolvable}   mesh shipped={shipped}")
    print(f"    vanilla remaining {vanilla_left}  (must be 0 for the readout to be clean)")

    problems = []
    if total != VANILLA_COUNT + 1 + EXTRA_MISSING:
        problems.append(f"expected {VANILLA_COUNT + 1 + EXTRA_MISSING} roster entries, got {total}")
    if vanilla_left != 0:
        problems.append(f"{vanilla_left} vanilla entries survived â€” a default-looking spawn would be ambiguous")
    if resolvable != 1 or not shipped:
        problems.append("the single resolvable October entry is missing")
    if problems:
        print("\nVERIFY FAILED:")
        for p in problems:
            print("  " + p)
        return 2

    print(f"\ndone -> {out}\n")
    print("Enable ALONE. Then die in the tunnels and read the respawn:")
    print("  looks DEFAULT   -> engine falls back; the must-resolve rule is WRONG, no placeholders needed")
    print("  INVISIBLE/broken-> the rule holds; placeholders are mandatory")
    print("  OCTOBER (~6%)   -> confirms CMSF entries participate in the roll")
    print("\nUntick to revert. Nothing is persisted by the game.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

