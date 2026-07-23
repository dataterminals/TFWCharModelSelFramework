#!/usr/bin/env python3
"""Build the probe 6 pak — the respawn constraint, and what an unresolvable path really does.

This is the rung the whole placeholder design rests on. docs/05-v2-distribution.md states:

    Every reserved roster path must resolve to a real mesh.
    Reserved capacity is never inert — it is always live in the respawn roll.

That rule is why a slot costs ~10 MB. But the thing it protects against — what the engine
does with a soft path that resolves to nothing — is marked [INFERRED]. If the engine
silently falls back to the default look, placeholders are unnecessary and the framework
collapses to a table patch. So this probe ships BOTH cases side by side:

  slot 00  RESOLVABLE  - a real mesh at a CMSF path (a clone of the October skin, which is
                         visually unmistakable, so "it loaded" is obvious at a glance)
  slot 99  MISSING     - a roster entry and a table row pointing at a path where NOTHING
                         is shipped

Note what probes 3-5 could NOT show: a tile renders whenever its row's mesh path appears in
the roster, because the selector string-matches rather than loading. So a tile appearing
proves nothing about the mesh. Selecting it does.

Both meshes are cloned with tools/mshgen, which rewrites package identity. mshprobe does
not, and the probe 3-5 paks consequently shipped a "placeholder" that was really an
override of the game's own SK_SCV_FL. See docs §"The identity rule".

Usage:
    python tools/build_probe6.py
"""
import os
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

# The October skin: complete, shipped, unreachable in vanilla (00-findings.md §5), and
# visually unmistakable — which is the point. A clone of the BASE mesh would be
# indistinguishable from the base skin, so "did it load" would be unanswerable.
TEMPLATE_MESH = "ForeverWinter/Content/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.uasset"

PORTRAIT = ("/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl."
            "T_Menu_PickCharacter_Portrait_ScavGirl")
LOCKED = ("/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_LockedV2."
          "T_Menu_PickCharacter_Portrait_LockedV2")

SLOTS = [
    dict(slot="00", ship_mesh=True,
         name="CMSF P6 RESOLVABLE",
         desc="slot 00 - a real mesh at a CMSF path. Selecting this should show the October look.",
         icon=PORTRAIT),
    dict(slot="99", ship_mesh=False,
         name="CMSF P6 MISSING",
         desc="slot 99 - NOTHING is shipped at this path. Selecting this is the experiment.",
         icon=LOCKED),
]

PAK = "CMSF_P6_9_P"


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def copy_pkg(src_stem: Path, dst_stem: Path):
    dst_stem.parent.mkdir(parents=True, exist_ok=True)
    found = False
    for ext in (".uasset", ".uexp", ".ubulk"):
        s = src_stem.with_suffix(ext)
        if s.is_file():
            shutil.copy(s, dst_stem.with_suffix(ext))
            found = True
    if not found:
        sys.exit(f"nothing to stage for {src_stem}")


def main():
    build = ROOT / "build" / "probe6"
    if build.exists():
        shutil.rmtree(build)
    src, stage = build / "src", build / "stage"
    out = ROOT / "dist" / "probe6"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    src.mkdir(parents=True)

    print("==> building tools")
    for t in ("skinpatch", "stgen", "mshgen"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"], quiet=True)
    skinpatch = ROOT / "tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
    stgen     = ROOT / "tools/stgen/bin/Release/net8.0/stgen.exe"
    mshgen    = ROOT / "tools/mshgen/bin/Release/net8.0/mshgen.exe"

    print("==> extracting from the live cook")
    for f in ("BP_Player_Girl", "DT_SkinUIData", "ST_FW_UI_Skins", "SK_SCV_FL_OCT"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src], quiet=True)
    for rel in (BP_REL, TBL_REL, ST_TPL, TEMPLATE_MESH):
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {rel}")

    specs, meshes = [], []
    for s in SLOTS:
        slot, sd = s["slot"], f"ForeverWinter/Content/CMSF/Girl/{s['slot']}"
        mesh_obj, st_obj = f"SK_CMSF_Girl_{slot}", f"ST_CMSF_Girl_{slot}"
        mesh_path = f"/Game/CMSF/Girl/{slot}/{mesh_obj}.{mesh_obj}"
        table_id  = f"/Game/CMSF/Girl/{slot}/{st_obj}.{st_obj}"

        if s["ship_mesh"]:
            print(f"==> slot {slot}: mesh (identity-rewritten)")
            run([mshgen, src / TEMPLATE_MESH, USMAP, stage / sd / f"{mesh_obj}.uasset", mesh_obj])
        else:
            print(f"==> slot {slot}: NO mesh shipped — this is the experiment")

        print(f"==> slot {slot}: string table")
        run([stgen, src / ST_TPL, USMAP, stage / sd / f"{st_obj}.uasset",
             f"CMSF.Girl.{slot}", st_obj, f"Name={s['name']}", f"Desc={s['desc']}"], quiet=True)

        meshes.append(mesh_path)
        specs.append(f"CMSF.Girl.{slot}|{table_id}|Name|Desc|{s['icon']}|{mesh_path}")

    # stgen/mshgen create their own output directories; skinpatch does not.
    for rel in (BP_REL, TBL_REL):
        (stage / rel).parent.mkdir(parents=True, exist_ok=True)

    print(f"==> BP_Player_Girl: appending {len(meshes)} roster entries")
    run([skinpatch, "bpadd", src / BP_REL, USMAP, stage / BP_REL] + meshes)

    print(f"==> DT_SkinUIData: adding {len(specs)} rows")
    run([skinpatch, "addst", src / TBL_REL, USMAP, stage / TBL_REL] + specs)

    print("==> packing")
    run([RETOC, "to-zen", "--version", "UE5_4", stage, out / f"{PAK}.utoc"], quiet=True)
    total = sum(f.stat().st_size for f in out.iterdir())
    print(f"    {PAK}  {total/1024/1024:.2f} MB")

    # --- verify against the FULL game, not just global ----------------------------------
    # Decoding with only global.utoc staged makes any unmounted package read as
    # /Engine/UnknownPackage, which is indistinguishable from real corruption. That cost an
    # hour on probe 3. Mount everything.
    print("==> verifying (full game mounted)")
    vsrc, vout = build / "vsrc", build / "vout"
    vsrc.mkdir(parents=True)
    for f in Path(PAKS).iterdir():
        if f.suffix in (".pak", ".utoc", ".ucas"):
            os.link(f, vsrc / f.name)
    for f in out.iterdir():
        shutil.copy(f, vsrc / f.name)
    # -f is MANDATORY here. Mounting the full game and decoding unfiltered extracts the
    # entire cook — 5 GB and climbing before it dies. Harmless in build_probe345.py, which
    # stages only global.utoc, and very much not harmless once every container is linked in.
    for filt in ("BP_Player_Girl", "DT_SkinUIData", "SK_CMSF_Girl"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout], quiet=True)

    problems = []
    tbl = run([skinpatch, "inspect", vout / TBL_REL, USMAP], quiet=True)
    roster = run([skinpatch, "bpskins", vout / BP_REL, USMAP], quiet=True)
    for s in SLOTS:
        slot = s["slot"]
        if f"CMSF.Girl.{slot}" not in tbl:
            problems.append(f"row CMSF.Girl.{slot} missing from the rebuilt table")
        if f"/Game/CMSF/Girl/{slot}/SK_CMSF_Girl_{slot}" not in roster:
            problems.append(f"slot {slot} missing from the rebuilt roster")
        shipped = (vout / f"ForeverWinter/Content/CMSF/Girl/{slot}/SK_CMSF_Girl_{slot}.uasset").is_file()
        if shipped != s["ship_mesh"]:
            problems.append(f"slot {slot}: mesh shipped={shipped}, expected {s['ship_mesh']}")
        print(f"    slot {slot}  row=yes roster=yes mesh={shipped}")

    if problems:
        print("\nVERIFY FAILED:")
        for p in problems:
            print("  " + p)
        return 2

    print(f"\ndone -> {out}\n")
    print("9 tiles expected. The two new ones:")
    print("  CMSF P6 RESOLVABLE  - select it. October look = a CMSF-path mesh loads.")
    print("  CMSF P6 MISSING     - select it. Whatever happens IS the finding.")
    print("\nThen die in the tunnels a few times with neither selected, and watch whether a")
    print("respawn ever rolls the October look — that is SkinChoices feeding the roll.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
