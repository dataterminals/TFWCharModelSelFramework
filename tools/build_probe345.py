#!/usr/bin/env python3
"""Build the probe 3-5 paks — does the game honour a CMSF string-table reference?

Probe 1 proved a CMSF string table is BUILDABLE. Probe 2 proved a placeholder mesh is
buildable. Neither proved the game RESOLVES either one. That is what these paks ask, and
probe 5 in particular is the v0.2 author channel itself: if a higher-load-order pak cannot
override a string table at a fixed path, authors cannot own their skin's name and the whole
distribution model dies.

Three stages, run in order. They deliberately CONFLICT — every stage ships DT_SkinUIData
and BP_Player_Girl, which are whole-asset overrides with exactly one owner — so install
exactly one stage at a time.

  Stage A (probe 3)  CMSF_P3_9_P                        expect name "CMSF P3 SAMEPAK"
  Stage B (probe 4)  CMSF_P45Core_9_P + CMSF_P45Low_9_P expect name "CMSF P4 LOW-AAA"
  Stage C (probe 5)  ...plus CMSF_P45High_11_P          expect name to flip to "CMSF P5 HIGH-BBB"

Stage B's real question is not just "does it render" but "does it render on the FIRST cold
menu open" — string tables load on demand, so a name that only appears after reopening the
menu is a partial failure needing an Init() retrigger.

CMSFUnlock must be active for any of this to be visible: the selector shows
LockedSkinChoices only by default, and these slots live in SkinChoices.

Usage:
    python tools/build_probe345.py
    python tools/build_probe345.py --keep    # do not wipe build/probe345 first
"""
import argparse
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

# --- the slot under test ---------------------------------------------------------------
SLOT_DIR  = "ForeverWinter/Content/CMSF/Girl/00"
MESH_OBJ  = "SK_CMSF_Girl_00"
ST_OBJ    = "ST_CMSF_Girl_00"
MESH_PATH = f"/Game/CMSF/Girl/00/{MESH_OBJ}.{MESH_OBJ}"
TABLE_ID  = f"/Game/CMSF/Girl/00/{ST_OBJ}.{ST_OBJ}"
ROW       = "CMSF.Girl.00"
ICON      = ("/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl."
             "T_Menu_PickCharacter_Portrait_ScavGirl")

BP_REL    = "ForeverWinter/Content/FW/Player/Class/BP_Player_Girl.uasset"
TBL_REL   = "ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset"
ST_TPL    = "ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset"

# The strings are the readout. Make them unmistakable on screen.
VARIANTS = {
    "p3":   ("CMSF P3 SAMEPAK",  "probe 3 - string table shipped in the same pak"),
    "low":  ("CMSF P4 LOW-AAA",  "probe 4 - cross-pak table at LOW load order"),
    "high": ("CMSF P5 HIGH-BBB", "probe 5 - HIGH load order override; if you can read this, the author channel works"),
}


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keep", action="store_true", help="do not wipe build/probe345 first")
    args = ap.parse_args()

    build = ROOT / "build" / "probe345"
    if build.exists() and not args.keep:
        shutil.rmtree(build)
    src, out = build / "src", ROOT / "dist" / "probe345"
    src.mkdir(parents=True, exist_ok=True)
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    print(f"retoc {RETOC}\nusmap {USMAP}\npaks  {PAKS}\n")

    # --- tools --------------------------------------------------------------------------
    print("==> building tools")
    for t in ("skinpatch", "stgen", "mshprobe"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"], quiet=True)
    skinpatch = ROOT / "tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
    stgen     = ROOT / "tools/stgen/bin/Release/net8.0/stgen.exe"
    mshprobe  = ROOT / "tools/mshprobe/bin/Release/net8.0/mshprobe.exe"

    # --- extract from the LIVE cook, never a snapshot ------------------------------------
    print("==> extracting from the live cook")
    for f in ("BP_Player_Girl", "DT_SkinUIData", "ST_FW_UI_Skins", "SK_SCV_FL"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, PAKS, src], quiet=True)
    for rel in (BP_REL, TBL_REL, ST_TPL):
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {rel} — is the filter still right for this build?")

    # --- the placeholder mesh at the slot path (probe 2's output) -----------------------
    print(f"==> mesh: SK_SCV_FL -> {MESH_PATH}")
    mesh_dir = build / "mesh" / SLOT_DIR
    run([mshprobe, src / "ForeverWinter/Content/Character/Scavengers/Female/SK_SCV_FL.uasset",
         USMAP, mesh_dir / f"{MESH_OBJ}.uasset", MESH_OBJ], quiet=True)

    # --- one string table per variant ---------------------------------------------------
    for key, (name, desc) in VARIANTS.items():
        print(f"==> string table [{key}]: \"{name}\"")
        run([stgen, src / ST_TPL, USMAP,
             build / "st" / key / SLOT_DIR / f"{ST_OBJ}.uasset",
             f"CMSF.Girl.00", ST_OBJ, f"Name={name}", f"Desc={desc}"])

    # --- the roster append and the table row --------------------------------------------
    print(f"==> BP_Player_Girl: append {MESH_PATH} to SkinChoices")
    bp_out = build / "patched" / BP_REL
    bp_out.parent.mkdir(parents=True, exist_ok=True)
    run([skinpatch, "bpadd", src / BP_REL, USMAP, bp_out, MESH_PATH])

    print(f"==> DT_SkinUIData: add {ROW} -> {TABLE_ID}")
    tbl_out = build / "patched" / TBL_REL
    tbl_out.parent.mkdir(parents=True, exist_ok=True)
    run([skinpatch, "addst", src / TBL_REL, USMAP, tbl_out,
         f"{ROW}|{TABLE_ID}|Name|Desc|{ICON}|{MESH_PATH}"])

    # --- stage the four paks ------------------------------------------------------------
    # A cooked package is .uasset + .uexp (+ .ubulk). Copying only the .uasset produces a
    # pak that builds without error and contains nothing usable — retoc silently drops the
    # orphan. Always move the whole set.
    def copy_pkg(src_stem: Path, dst_stem: Path):
        dst_stem.parent.mkdir(parents=True, exist_ok=True)
        found = False
        for ext in (".uasset", ".uexp", ".ubulk"):
            s = src_stem.with_suffix(ext)
            if s.is_file():
                shutil.copy(s, dst_stem.with_suffix(ext))
                found = True
        if not found:
            sys.exit(f"nothing to stage for {src_stem} — expected at least a .uasset")

    def stage(name, *, with_core, st_variant):
        d = build / "stage" / name
        if d.exists():
            shutil.rmtree(d)
        if with_core:
            for rel in (BP_REL, TBL_REL):
                copy_pkg((build / "patched" / rel).with_suffix(""), (d / rel).with_suffix(""))
            copy_pkg(mesh_dir / MESH_OBJ, d / SLOT_DIR / MESH_OBJ)
        if st_variant:
            copy_pkg(build / "st" / st_variant / SLOT_DIR / ST_OBJ, d / SLOT_DIR / ST_OBJ)
        run([RETOC, "to-zen", "--version", "UE5_4", d, out / f"{name}.utoc"], quiet=True)
        size = sum(f.stat().st_size for f in out.glob(f"{name}.*"))
        print(f"    {name:<20} {size/1024/1024:6.2f} MB")
        return d

    print("==> packing")
    stage("CMSF_P3_9_P",       with_core=True,  st_variant="p3")
    stage("CMSF_P45Core_9_P",  with_core=True,  st_variant=None)
    stage("CMSF_P45Low_9_P",   with_core=False, st_variant="low")
    stage("CMSF_P45High_11_P", with_core=False, st_variant="high")

    # --- verify by decoding each built pak back out -------------------------------------
    # A pak that installs cleanly and does nothing is indistinguishable in-game from
    # "the approach does not work". Never skip this.
    print("==> verifying built paks")
    # Declare what each pak MUST contain, then assert against it. An earlier version nested
    # the row check inside `if has_tbl:`, so a pak missing the table entirely reported no
    # problems at all — the exact silent-empty-pak failure this step exists to catch.
    expect = {
        "CMSF_P3_9_P":       dict(table=True,  mesh=True,  st=True,  st_text="CMSF P3 SAMEPAK"),
        "CMSF_P45Core_9_P":  dict(table=True,  mesh=True,  st=False, st_text=None),
        "CMSF_P45Low_9_P":   dict(table=False, mesh=False, st=True,  st_text="CMSF P4 LOW-AAA"),
        "CMSF_P45High_11_P": dict(table=False, mesh=False, st=True,  st_text="CMSF P5 HIGH-BBB"),
    }
    problems = []
    for name, want in expect.items():
        vsrc, vout = build / "v" / name / "src", build / "v" / name / "out"
        vsrc.mkdir(parents=True, exist_ok=True)
        for g in ("global.utoc", "global.ucas"):
            shutil.copy(Path(PAKS) / g, vsrc / g)
        for f in out.glob(f"{name}.*"):
            shutil.copy(f, vsrc / f.name)
        run([RETOC, "to-legacy", "--version", "UE5_4", vsrc, vout], quiet=True)

        got = dict(
            table=(vout / TBL_REL).is_file(),
            mesh=(vout / SLOT_DIR / f"{MESH_OBJ}.uasset").is_file(),
            st=(vout / SLOT_DIR / f"{ST_OBJ}.uasset").is_file(),
        )
        for k in ("table", "mesh", "st"):
            if got[k] != want[k]:
                problems.append(f"{name}: {k} present={got[k]}, expected {want[k]}")

        # Presence is not enough — the row and the roster entry must have survived repack.
        if got["table"]:
            if ROW not in run([skinpatch, "inspect", vout / TBL_REL, USMAP], quiet=True):
                problems.append(f"{name}: {ROW} missing from the rebuilt table")
            if not (vout / BP_REL).is_file():
                problems.append(f"{name}: BP_Player_Girl missing from the rebuilt pak")
            elif MESH_PATH.rsplit(".", 1)[0] not in run([skinpatch, "bpskins", vout / BP_REL, USMAP], quiet=True):
                problems.append(f"{name}: mesh missing from the rebuilt roster")
        # The string is the entire readout of probes 3-5; confirm the right one shipped.
        if got["st"] and want["st_text"]:
            blob = (vout / SLOT_DIR / f"{ST_OBJ}.uexp").read_bytes()
            if want["st_text"].encode("utf-16-le") not in blob and want["st_text"].encode() not in blob:
                problems.append(f"{name}: string table does not contain {want['st_text']!r}")
        print(f"    {name:<20} table={got['table']} mesh={got['mesh']} st={got['st']}")

    if problems:
        print("\nVERIFY FAILED:")
        for p in problems:
            print("  " + p)
        return 2

    print(f"\ndone -> {out}\n")
    print("Install ONE stage at a time (they all ship DT_SkinUIData + BP_Player_Girl):")
    print("  A/probe3   CMSF_P3_9_P                            expect  CMSF P3 SAMEPAK")
    print("  B/probe4   CMSF_P45Core_9_P + CMSF_P45Low_9_P     expect  CMSF P4 LOW-AAA   (on the FIRST cold menu open)")
    print("  C/probe5   + CMSF_P45High_11_P                    expect  CMSF P5 HIGH-BBB")
    print("\nCMSFUnlock must be enabled — these slots live in SkinChoices, which the")
    print("selector hides by default.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
