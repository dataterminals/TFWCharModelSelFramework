#!/usr/bin/env python3
"""Build probe 7 — the slot claim, end to end, in the shape v0.2 actually ships.

This is the first build of the POST-PLACEHOLDER design. Probe 6 disproved the rule that
every reserved roster path must resolve, so the framework no longer ships meshes at all. A
reserved slot is now a DataTable row, a roster entry, and two KB-to-sub-MB sentinels.

  framework (user installs once)   rows + roster entries + sentinel string table
                                   + sentinel portrait, per slot. NO meshes.
  author    (per skin)             mesh + portrait + string table, at the slot's frozen
                                   paths, at a higher load order. Three packages, nothing
                                   else — no DT_SkinUIData, no BP_Player_*, no manifest.

Two slots are built so both states are visible at once:

  slot 00  CLAIMED   by the author pak — name, portrait AND mesh should all be the author's
  slot 01  UNCLAIMED — sentinel name and sentinel portrait, and selecting it does nothing

What this proves that probe 5 did not: probe 5 overrode a string table alone. A real claim
overrides three packages together, and the interesting failure is a PARTIAL one — an
author's name arriving with the framework's portrait, or a mesh without its name. Higher
load order should win all three or none.

Untick the author pak and slot 00 must revert cleanly to the sentinel. That is the
uninstall path, and it is the other half of this rung.

Usage:
    python tools/build_probe7.py
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

BP_REL  = "ForeverWinter/Content/FW/Player/Class/BP_Player_Girl.uasset"
TBL_REL = "ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset"
ST_TPL  = "ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset"
TEX_DIR = "ForeverWinter/Content/UI/Textures/MainMenu/Menu"

# Sentinel portrait: the vanilla "locked" plate, which reads as deliberate rather than
# broken, and is a quarter the size of a real portrait.
SENTINEL_TEX = f"{TEX_DIR}/T_Menu_PickCharacter_Portrait_LockedV2.uasset"
# Author portrait: visibly not the sentinel, so a partial claim is obvious at a glance.
AUTHOR_TEX   = f"{TEX_DIR}/T_Menu_PickCharacter_Portrait_DLC04_Scavgirl.uasset"
AUTHOR_MESH  = "ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.uasset"

SLOTS = ["00", "01"]
CLAIMED = "00"

CORE_PAK   = "CMSF_P7Core_9_P"
AUTHOR_PAK = "CMSF_P7Author_11_P"


def slot_paths(slot):
    d = f"/Game/CMSF/Girl/{slot}"
    return dict(
        dir=f"ForeverWinter/Content/CMSF/Girl/{slot}",
        mesh_obj=f"SK_CMSF_Girl_{slot}", st_obj=f"ST_CMSF_Girl_{slot}", tex_obj=f"T_CMSF_Girl_{slot}",
        mesh=f"{d}/SK_CMSF_Girl_{slot}.SK_CMSF_Girl_{slot}",
        table=f"{d}/ST_CMSF_Girl_{slot}.ST_CMSF_Girl_{slot}",
        icon=f"{d}/T_CMSF_Girl_{slot}.T_CMSF_Girl_{slot}",
    )


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def main():
    build = ROOT / "build" / "probe7"
    src = build / "src"
    core, author = build / "core", build / "author"
    out = ROOT / "dist" / "probe7"
    for d in (core, author):
        if d.exists():
            shutil.rmtree(d)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    src.mkdir(parents=True, exist_ok=True)

    print("==> building tools")
    for t in ("skinpatch", "stgen", "mshgen"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"], quiet=True)
    skinpatch = ROOT / "tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
    stgen     = ROOT / "tools/stgen/bin/Release/net8.0/stgen.exe"
    mshgen    = ROOT / "tools/mshgen/bin/Release/net8.0/mshgen.exe"

    print("==> extracting from the live cook")
    for f in ("BP_Player_Girl", "DT_SkinUIData", "ST_FW_UI_Skins", "SK_SCV_FL_OCT",
              "T_Menu_PickCharacter_Portrait_LockedV2", "T_Menu_PickCharacter_Portrait_DLC04_Scavgirl"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src], quiet=True)
    for rel in (BP_REL, TBL_REL, ST_TPL, SENTINEL_TEX, AUTHOR_TEX, AUTHOR_MESH):
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {rel}")

    # ---- the framework -----------------------------------------------------------------
    specs, meshes = [], []
    for slot in SLOTS:
        p = slot_paths(slot)
        print(f"==> framework slot {slot}: sentinel string table + sentinel portrait")
        run([stgen, src / ST_TPL, USMAP, core / p["dir"] / f"{p['st_obj']}.uasset",
             f"CMSF.Girl.{slot}", p["st_obj"],
             f"Name=CMSF SLOT {slot} UNCLAIMED",
             f"Desc=No skin is installed in slot {slot}. Install a mod that claims it."], quiet=True)
        run([mshgen, src / SENTINEL_TEX, USMAP, core / p["dir"] / f"{p['tex_obj']}.uasset",
             p["tex_obj"]], quiet=True)
        meshes.append(p["mesh"])
        specs.append(f"CMSF.Girl.{slot}|{p['table']}|Name|Desc|{p['icon']}|{p['mesh']}")

    for rel in (BP_REL, TBL_REL):
        (core / rel).parent.mkdir(parents=True, exist_ok=True)
    print(f"==> framework: {len(meshes)} roster entries (pointing at meshes nobody ships yet)")
    run([skinpatch, "bpadd", src / BP_REL, USMAP, core / BP_REL] + meshes, quiet=True)
    print(f"==> framework: {len(specs)} rows")
    run([skinpatch, "addst", src / TBL_REL, USMAP, core / TBL_REL] + specs, quiet=True)

    # ---- the author's pak --------------------------------------------------------------
    p = slot_paths(CLAIMED)
    print(f"==> author claims slot {CLAIMED}: mesh + portrait + string table")
    run([mshgen, src / AUTHOR_MESH, USMAP, author / p["dir"] / f"{p['mesh_obj']}.uasset",
         p["mesh_obj"]], quiet=True)
    run([mshgen, src / AUTHOR_TEX, USMAP, author / p["dir"] / f"{p['tex_obj']}.uasset",
         p["tex_obj"]], quiet=True)
    run([stgen, src / ST_TPL, USMAP, author / p["dir"] / f"{p['st_obj']}.uasset",
         f"CMSF.Girl.{CLAIMED}", p["st_obj"],
         "Name=OCTOBER SCAV (CLAIMED)",
         "Desc=Shipped by an author pak. Name, portrait and mesh should ALL be theirs."], quiet=True)

    print("==> packing")
    for name, d in ((CORE_PAK, core), (AUTHOR_PAK, author)):
        run([RETOC, "to-zen", "--version", "UE5_4", d, out / f"{name}.utoc"], quiet=True)
        sz = sum(f.stat().st_size for f in out.glob(f"{name}.*"))
        print(f"    {name:<22} {sz/1024/1024:7.2f} MB")

    # ---- verify ------------------------------------------------------------------------
    print("==> verifying")
    vsrc, vout = build / "vsrc", build / "vout"
    for d in (vsrc, vout):
        if d.exists():
            shutil.rmtree(d)
    vsrc.mkdir(parents=True)
    for f in Path(PAKS).iterdir():
        if f.suffix in (".pak", ".utoc", ".ucas"):
            os.link(f, vsrc / f.name)
    # Author pak only, so the decode shows what the CLAIM contributes.
    for f in out.glob(f"{AUTHOR_PAK}.*"):
        shutil.copy(f, vsrc / f.name)
    for f in out.glob(f"{CORE_PAK}.*"):
        shutil.copy(f, vsrc / f.name)
    # -f is mandatory against a full mount, or this extracts the entire cook.
    for filt in ("BP_Player_Girl", "DT_SkinUIData", "SK_CMSF_Girl", "T_CMSF_Girl", "ST_CMSF_Girl"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout], quiet=True)

    problems = []
    tbl = run([skinpatch, "inspect", vout / TBL_REL, USMAP], quiet=True)
    roster = run([skinpatch, "bpskins", vout / BP_REL, USMAP], quiet=True)
    for slot in SLOTS:
        p = slot_paths(slot)
        if f"CMSF.Girl.{slot}" not in tbl:
            problems.append(f"row CMSF.Girl.{slot} missing")
        if p["mesh"].rsplit(".", 1)[0] not in roster:
            problems.append(f"slot {slot} missing from the roster")
        has = {k: (vout / p["dir"] / f"{p[o]}.uasset").is_file()
               for k, o in (("st", "st_obj"), ("tex", "tex_obj"), ("mesh", "mesh_obj"))}
        want_mesh = slot == CLAIMED
        if has["mesh"] != want_mesh:
            problems.append(f"slot {slot}: mesh present={has['mesh']}, expected {want_mesh}")
        if not has["st"] or not has["tex"]:
            problems.append(f"slot {slot}: missing st={not has['st']} tex={not has['tex']}")
        print(f"    slot {slot}  row=yes roster=yes st={has['st']} tex={has['tex']} mesh={has['mesh']}")

    # The claimed slot's table must be the AUTHOR's, since its pak loads higher.
    claimed_st = vout / slot_paths(CLAIMED)["dir"] / f"{slot_paths(CLAIMED)['st_obj']}.uexp"
    if claimed_st.is_file():
        blob = claimed_st.read_bytes()
        won = b"OCTOBER SCAV (CLAIMED)" in blob or "OCTOBER SCAV (CLAIMED)".encode("utf-16-le") in blob
        print(f"    slot {CLAIMED} string table is the AUTHOR's: {won}")
        if not won:
            problems.append(f"slot {CLAIMED}: the framework's sentinel table won over the author's")

    if problems:
        print("\nVERIFY FAILED:")
        for x in problems:
            print("  " + x)
        return 2

    print(f"\ndone -> {out}\n")
    print("Install BOTH. The author pak must sit ABOVE the core pak in MO2 priority.")
    print(f"  slot 00  expect  OCTOBER SCAV (CLAIMED)   author portrait, October mesh on select")
    print(f"  slot 01  expect  CMSF SLOT 01 UNCLAIMED   locked portrait, selecting does nothing")
    print("\nThen untick ONLY the author pak: slot 00 must revert to its sentinel.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
