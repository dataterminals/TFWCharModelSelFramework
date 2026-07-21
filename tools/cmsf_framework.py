#!/usr/bin/env python3
"""CMSF v0.2 framework generator — the pak a user installs once.

This is the generalisation of tools/build_probe7.py from one character and two slots to N
slots across all six. It emits, per slot `<Char>/<NN>`:

  * a DT_SkinUIData row `CMSF.<Char>.<NN>` whose name/description are string-table
    references, and whose icon and mesh are soft paths into the slot's frozen directory
  * the matching SkinChoices append on BP_Player_<Char>
  * a ~1 KB sentinel string table

and nothing else. **No meshes and no portraits.** Both paths resolve to nothing until an
author claims the slot, which is harmless (probe 6), and shipping a sentinel portrait would
actively break rung 9: a texture at the slot's own icon path is exactly what CMSFUnlock reads
as a CLAIM, so a sentinel would make every slot permanently unprunable. See
docs/05-v2-distribution.md "The claim signal".

Slot paths under /Game/CMSF/ are a permanent public ABI: append-only, never renumbered. That
promise is what lets an author's pak survive every framework rebase untouched. Slot numbers
are TWO DIGITS by ABI — CMSFUnlock matches `CMSF%.%a+%.%d%d`, so 100 slots is the hard cap.

Always rebuilds from the LIVE cook, never a committed snapshot: a stale DT_SkinUIData would
delete the developers' new rows (the staleness inversion in docs/04-authoring.md).

Usage:
    python tools/cmsf_framework.py --slots 8              # all six characters
    python tools/cmsf_framework.py --slots 64 --stress    # ABI sizing measurement
"""
import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AES = "0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795"

# The only six playable characters. BP_Player_MaskMan is the one usually mis-remembered as
# "Mech Trooper".
CHARACTERS = ["BagMan", "Girl", "Gunhead", "MaskMan", "OldMan", "Shaman"]

BP_DIR   = "ForeverWinter/Content/FW/Player/Class"
TBL_REL  = "ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset"
ST_TPL   = "ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset"

# Each spec is ~190 chars and Windows caps a command line near 32k, so addst is chained in
# batches: batch N's output is batch N+1's input.
SPEC_BATCH = 100


def find(env, candidates, what):
    v = os.environ.get(env)
    if v and Path(v).exists():
        return v
    for c in candidates:
        if Path(c).exists():
            return c
    sys.exit(f"could not locate {what}; set ${env}")


RETOC = find("RETOC", [
    r"H:\Github Repositories\AllWeaponsUnlockableFix\tools\retoc\retoc.exe",
    r"D:\Github Repositories\HeavyRifleRebalanceFix\tools\retoc\retoc.exe",
], "retoc.exe")
USMAP = find("USMAP", [
    r"H:\Github Repositories\forever-winter-datamine\datamine\mappings\ForeverWinter-5.4.2.usmap",
    r"D:\Github Repositories\forever-winter-datamine\datamine\mappings\ForeverWinter-5.4.2.usmap",
], "the usmap")
PAKS = find("FW_PAKS", [
    r"H:\SteamLibrary\steamapps\common\The Forever Winter\Windows\ForeverWinter\Content\Paks",
    r"D:\SteamLibrary\steamapps\common\The Forever Winter\Windows\ForeverWinter\Content\Paks",
], "the game's Paks directory")


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)[:400]}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def slot_paths(char, slot):
    d = f"/Game/CMSF/{char}/{slot}"
    return dict(
        dir=f"ForeverWinter/Content/CMSF/{char}/{slot}",
        st_obj=f"ST_CMSF_{char}_{slot}",
        mesh=f"{d}/SK_CMSF_{char}_{slot}.SK_CMSF_{char}_{slot}",
        table=f"{d}/ST_CMSF_{char}_{slot}.ST_CMSF_{char}_{slot}",
        icon=f"{d}/T_CMSF_{char}_{slot}.T_CMSF_{char}_{slot}",
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--slots", type=int, default=8, help="slots per character (max 100)")
    ap.add_argument("--characters", default=",".join(CHARACTERS))
    ap.add_argument("--stress", action="store_true",
                    help="name the output CMSF_Stress_* so it cannot be mistaken for a release")
    args = ap.parse_args()

    chars = [c.strip() for c in args.characters.split(",") if c.strip()]
    for c in chars:
        if c not in CHARACTERS:
            sys.exit(f"unknown character {c!r}; known: {', '.join(CHARACTERS)}")
    if not 1 <= args.slots <= 100:
        sys.exit("--slots must be 1..100 — slot numbers are two digits by ABI")

    tag = "Stress" if args.stress else "Core"
    pak = f"CMSF_{tag}_9_P"
    build = ROOT / "build" / "framework"
    src, stage = build / "src", build / "stage"
    out = ROOT / "dist" / ("stress" if args.stress else "framework")
    if stage.exists():
        shutil.rmtree(stage)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    src.mkdir(parents=True, exist_ok=True)

    total = args.slots * len(chars)
    print(f"==> {args.slots} slots x {len(chars)} character(s) = {total} slots")

    print("==> building tools")
    for t in ("skinpatch", "stgen"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"],
            quiet=True)
    skinpatch = ROOT / "tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
    stgen     = ROOT / "tools/stgen/bin/Release/net8.0/stgen.exe"

    print("==> extracting from the live cook")
    for f in ["DT_SkinUIData", "ST_FW_UI_Skins"] + [f"BP_Player_{c}" for c in chars]:
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src],
            quiet=True)
    need = [TBL_REL, ST_TPL] + [f"{BP_DIR}/BP_Player_{c}.uasset" for c in chars]
    for rel in need:
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {rel}")

    # ---- sentinel string tables --------------------------------------------------------
    print(f"==> {total} sentinel string tables", end="", flush=True)
    specs, per_char_meshes = [], {}
    for char in chars:
        meshes = []
        for i in range(args.slots):
            slot = f"{i:02d}"
            p = slot_paths(char, slot)
            run([stgen, src / ST_TPL, USMAP, stage / p["dir"] / f"{p['st_obj']}.uasset",
                 f"CMSF.{char}.{slot}", p["st_obj"],
                 f"Name=CMSF {char} slot {slot} — unclaimed",
                 "Desc=No skin is installed in this slot. Unclaimed slots are normally "
                 "hidden; if you can see this, pruning is off or unavailable."], quiet=True)
            meshes.append(p["mesh"])
            specs.append(f"CMSF.{char}.{slot}|{p['table']}|Name|Desc|{p['icon']}|{p['mesh']}")
        per_char_meshes[char] = meshes
        print(".", end="", flush=True)
    print()

    # ---- roster appends, one asset per character ---------------------------------------
    print(f"==> roster: {args.slots} entries on each of {len(chars)} pawn(s)")
    for char in chars:
        rel = f"{BP_DIR}/BP_Player_{char}.uasset"
        (stage / rel).parent.mkdir(parents=True, exist_ok=True)   # skinpatch will not
        run([skinpatch, "bpadd", src / rel, USMAP, stage / rel] + per_char_meshes[char],
            quiet=True)

    # ---- rows, chained in batches ------------------------------------------------------
    print(f"==> DT_SkinUIData: {len(specs)} rows in {-(-len(specs)//SPEC_BATCH)} batch(es)")
    (stage / TBL_REL).parent.mkdir(parents=True, exist_ok=True)
    cur = src / TBL_REL
    for i in range(0, len(specs), SPEC_BATCH):
        run([skinpatch, "addst", cur, USMAP, stage / TBL_REL] + specs[i:i + SPEC_BATCH],
            quiet=True)
        cur = stage / TBL_REL      # chain: this batch's output feeds the next

    print("==> packing")
    run([RETOC, "to-zen", "--version", "UE5_4", stage, out / f"{pak}.utoc"], quiet=True)
    sz = sum(f.stat().st_size for f in out.glob(f"{pak}.*"))
    print(f"    {pak:<20} {sz/1024/1024:7.2f} MB   ({sz/total/1024:.1f} KB per slot)")

    # ---- verify ------------------------------------------------------------------------
    print("==> verifying (decode the built pak back out)")
    vsrc, vout = build / "vsrc", build / "vout"
    for d in (vsrc, vout):
        if d.exists():
            shutil.rmtree(d)
    vsrc.mkdir(parents=True)
    for f in Path(PAKS).iterdir():
        if f.suffix in (".pak", ".utoc", ".ucas"):
            os.link(f, vsrc / f.name)
    for f in out.glob(f"{pak}.*"):
        shutil.copy(f, vsrc / f.name)
    # -f is mandatory against a full mount, or this extracts the entire cook.
    for filt in ["DT_SkinUIData", "ST_CMSF_"] + [f"BP_Player_{c}" for c in chars]:
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout],
            quiet=True)

    problems = []
    tbl = run([skinpatch, "inspect", vout / TBL_REL, USMAP], quiet=True)
    for char in chars:
        roster = run([skinpatch, "bpskins", vout / f"{BP_DIR}/BP_Player_{char}.uasset",
                      USMAP], quiet=True)
        missing_rows = missing_slots = missing_st = 0
        for i in range(args.slots):
            slot = f"{i:02d}"
            p = slot_paths(char, slot)
            if f"CMSF.{char}.{slot}" not in tbl:
                missing_rows += 1
            if p["mesh"].rsplit(".", 1)[0] not in roster:
                missing_slots += 1
            if not (vout / p["dir"] / f"{p['st_obj']}.uasset").is_file():
                missing_st += 1
            # A shipped mesh or portrait would silently disable pruning for that slot.
            for stray in (f"SK_CMSF_{char}_{slot}", f"T_CMSF_{char}_{slot}"):
                if (vout / p["dir"] / f"{stray}.uasset").is_file():
                    problems.append(f"{char}/{slot}: shipped {stray} — breaks rung 9")
        for label, n in (("rows", missing_rows), ("roster entries", missing_slots),
                         ("string tables", missing_st)):
            if n:
                problems.append(f"{char}: {n} missing {label}")
        print(f"    {char:<8} rows={args.slots - missing_rows}/{args.slots} "
              f"roster={args.slots - missing_slots}/{args.slots} "
              f"st={args.slots - missing_st}/{args.slots}")

    if problems:
        print("\nVERIFY FAILED:")
        for x in problems[:20]:
            print("  " + x)
        return 2

    print(f"\ndone -> {out}")
    if args.stress:
        print("\nSTRESS BUILD — for measuring selector cost, not for release.")
        print("Install with runtime/CMSFTime, open a skin menu, then run `cmsftime`.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
