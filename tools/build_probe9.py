#!/usr/bin/env python3
"""Build probe 9 — everything rung 9 (pruning unclaimed tiles) depends on, in one run.

Rung 9 wants CMSFUnlock to collapse the tiles of slots no author has claimed. Four things
must hold, and none of them has been measured. This pak plus runtime/CMSFProbe9 answers all
four in a single in-game session.

  Q1  Does a row whose SkinIcon path resolves to NOTHING render gracefully?
      Probe 6 proved an unresolvable MESH path is a silent no-op. The icon is a separate
      soft path and is untested. If it is graceful, the framework can stop shipping a
      571 KB sentinel portrait per slot — the single largest cost in the artifact, and the
      thing that was capping how deep the slot pool could go.

  Q2  Can Lua read a tile's SkinIcon brush resource object, and is it NULL for such a row?
      That is the claim signal: unclaimed slots ship no portrait, so a null icon means
      unclaimed. Self-contained — no pak-filename convention, nothing to get wrong at the
      author's end, nothing for a mod manager to rewrite.

  Q3  Can Lua read tile.SkinRow.RowName?
      WBP_SkinButton_C.SkinRow is an FDataTableRowHandle (verified in the cook, its CDO
      reads RowName: "Bagman0"). If it reads live, a tile carries its own exact slot
      identity and no text matching is needed anywhere.

  Q4  Does a plain Visibility byte write collapse a tile, and does it survive Init()?
      Init() is what CMSFUnlock already calls, so a prune that Init() undoes is no prune.

Three slots on Girl, no meshes on any of them (unclaimed is the state under test):

  slot 00   sentinel string table + sentinel portrait      today's shape
  slot 01   sentinel string table, NO portrait             the proposal; the prune target
  slot 02   sentinel string table, NO portrait             identical to 01, left alone

01 and 02 are deliberately identical so the prune command has a control sitting next to its
target: if 01 collapses and 02 does not, the write worked and nothing else moved.

Usage:
    python tools/build_probe9.py
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
TEX_DIR = "ForeverWinter/Content/UI/Textures/MainMenu/Menu"
SENTINEL_TEX = f"{TEX_DIR}/T_Menu_PickCharacter_Portrait_LockedV2.uasset"

# ship_tex is the whole experiment: 00 keeps the sentinel plate, 01 and 02 ship no portrait
# at all and their rows point at a texture path where nothing exists.
SLOTS = [
    {"slot": "00", "ship_tex": True,
     "name": "CMSF 00 PLATE",
     "desc": "Unclaimed, WITH the sentinel portrait. Today's shape."},
    {"slot": "01", "ship_tex": False,
     "name": "CMSF 01 NO PORTRAIT",
     "desc": "Unclaimed, NO portrait shipped. Prune target for `cmsfprune`."},
    {"slot": "02", "ship_tex": False,
     "name": "CMSF 02 NO PORTRAIT",
     "desc": "Identical to 01. The control — must stay visible when 01 collapses."},
]

PAK = "CMSF_P9_9_P"


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def main():
    build = ROOT / "build" / "probe9"
    src, stage = build / "src", build / "stage"
    out = ROOT / "dist" / "probe9"
    if stage.exists():
        shutil.rmtree(stage)
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
    for f in ("BP_Player_Girl", "DT_SkinUIData", "ST_FW_UI_Skins",
              "T_Menu_PickCharacter_Portrait_LockedV2"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src], quiet=True)
    for rel in (BP_REL, TBL_REL, ST_TPL, SENTINEL_TEX):
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {rel}")

    specs, meshes = [], []
    for s in SLOTS:
        slot = s["slot"]
        sd = f"ForeverWinter/Content/CMSF/Girl/{slot}"
        d = f"/Game/CMSF/Girl/{slot}"
        mesh_obj, st_obj, tex_obj = (f"SK_CMSF_Girl_{slot}", f"ST_CMSF_Girl_{slot}",
                                     f"T_CMSF_Girl_{slot}")
        mesh_path = f"{d}/{mesh_obj}.{mesh_obj}"
        table_id  = f"{d}/{st_obj}.{st_obj}"
        icon_path = f"{d}/{tex_obj}.{tex_obj}"

        print(f"==> slot {slot}: string table"
              + ("  + sentinel portrait" if s["ship_tex"] else "  (NO portrait — the experiment)"))
        run([stgen, src / ST_TPL, USMAP, stage / sd / f"{st_obj}.uasset",
             f"CMSF.Girl.{slot}", st_obj, f"Name={s['name']}", f"Desc={s['desc']}"], quiet=True)
        if s["ship_tex"]:
            run([mshgen, src / SENTINEL_TEX, USMAP, stage / sd / f"{tex_obj}.uasset",
                 tex_obj], quiet=True)

        # The row always points at the slot's frozen icon path, shipped or not. That is the
        # whole point: an author claims the slot by shipping a package at that same path.
        meshes.append(mesh_path)
        specs.append(f"CMSF.Girl.{slot}|{table_id}|Name|Desc|{icon_path}|{mesh_path}")

    # skinpatch does not create its output directory; stgen/mshgen do.
    for rel in (BP_REL, TBL_REL):
        (stage / rel).parent.mkdir(parents=True, exist_ok=True)
    print(f"==> {len(meshes)} roster entries (no meshes shipped — every slot is unclaimed)")
    run([skinpatch, "bpadd", src / BP_REL, USMAP, stage / BP_REL] + meshes, quiet=True)
    print(f"==> {len(specs)} rows")
    run([skinpatch, "addst", src / TBL_REL, USMAP, stage / TBL_REL] + specs, quiet=True)

    print("==> packing")
    run([RETOC, "to-zen", "--version", "UE5_4", stage, out / f"{PAK}.utoc"], quiet=True)
    sz = sum(f.stat().st_size for f in out.glob(f"{PAK}.*"))
    print(f"    {PAK:<18} {sz/1024/1024:7.2f} MB")

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
    for f in out.glob(f"{PAK}.*"):
        shutil.copy(f, vsrc / f.name)
    # -f is mandatory against a full mount, or this extracts the entire cook.
    for filt in ("BP_Player_Girl", "DT_SkinUIData", "T_CMSF_Girl", "ST_CMSF_Girl"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout], quiet=True)

    problems = []
    tbl = run([skinpatch, "inspect", vout / TBL_REL, USMAP], quiet=True)
    roster = run([skinpatch, "bpskins", vout / BP_REL, USMAP], quiet=True)
    for s in SLOTS:
        slot = s["slot"]
        sd = vout / f"ForeverWinter/Content/CMSF/Girl/{slot}"
        if f"CMSF.Girl.{slot}" not in tbl:
            problems.append(f"row CMSF.Girl.{slot} missing")
        if f"/Game/CMSF/Girl/{slot}/SK_CMSF_Girl_{slot}" not in roster:
            problems.append(f"slot {slot} missing from the roster")
        has_st  = (sd / f"ST_CMSF_Girl_{slot}.uasset").is_file()
        has_tex = (sd / f"T_CMSF_Girl_{slot}.uasset").is_file()
        has_msh = (sd / f"SK_CMSF_Girl_{slot}.uasset").is_file()
        if not has_st:
            problems.append(f"slot {slot}: string table missing")
        if has_tex != s["ship_tex"]:
            problems.append(f"slot {slot}: portrait present={has_tex}, expected {s['ship_tex']}")
        if has_msh:
            problems.append(f"slot {slot}: a mesh was shipped; no slot here should have one")
        print(f"    slot {slot}  row=yes roster=yes st={has_st} tex={has_tex} mesh={has_msh}")

    if problems:
        print("\nVERIFY FAILED:")
        for x in problems:
            print("  " + x)
        return 2

    print(f"\ndone -> {out}\n")
    print("Install the pak AND runtime/CMSFProbe9 (alongside CMSFUnlock, which does the unfilter).")
    print("Open Scav Girl's skin menu, then read the log. Expect three CMSF tiles.")
    print("  Q1  do 01 and 02 render gracefully with no portrait, or broken/checkerboard?")
    print("  Q2  the log reports icon=null for 01/02 and icon=<object> for 00")
    print("  Q3  the log reports row=CMSF.Girl.NN for all three")
    print("  Q4  run `cmsfprune` — slot 01 must collapse, 02 must stay. Then reopen the menu.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
