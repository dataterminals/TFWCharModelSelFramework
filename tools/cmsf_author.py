#!/usr/bin/env python3
"""CMSF v0.2 author tool — turn one skin into one ordinary pak trio.

An author claims a slot by shipping exactly three packages at that slot's frozen paths, at a
higher load order than the framework:

    /Game/CMSF/<Char>/<NN>/SK_CMSF_<Char>_<NN>     the mesh
    /Game/CMSF/<Char>/<NN>/T_CMSF_<Char>_<NN>      the portrait
    /Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>     the name and description

and nothing else. **Never `DT_SkinUIData`, never `BP_Player_*`** — that is the whole trick,
and it is why two CMSF skins cannot clobber each other. This tool refuses to emit them, and
the verify pass fails the build if they appear.

THE PORTRAIT IS MANDATORY. CMSFUnlock decides a slot is unclaimed by checking whether its
icon resolves to the slot's own path, so a claim that ships no portrait is not merely ugly —
it is **hidden**, pruned as though it had never been installed. This is the one authoring
mistake that produces a working-looking build and an invisible skin, so it is a hard error
here rather than a surprise in-game.

`skin.json` is a build-time input and never ships. The end user installs pak trios only — no
manifest, no config, no exe.

skin.json:
    {
      "character":   "Girl",              one of the six pawns
      "slot":        "00",                the claimed slot (or pass --slot)
      "name":        "Octogirl",
      "description": "...",
      "mesh":        "/Game/... .SK_X"    a cooked path to clone, OR a local .uasset
      "icon":        "/Game/... .T_X"     likewise — REQUIRED
    }

A /Game/ value is cloned out of the live cook. Anything else is treated as a path relative
to the skin directory, which is how an author ships their own cooked assets.

Usage:
    python tools/cmsf_author.py skins/octogirl --slot 00
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AES = "0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795"
CHARACTERS = ["BagMan", "Girl", "Gunhead", "MaskMan", "OldMan", "Shaman"]

# Must match tools/cmsf_framework.py exactly: the framework's row references this namespace
# and these two keys, and an override only lands if all three agree.
ST_KEY_NAME, ST_KEY_DESC = "Name", "Desc"

# The framework ships at _9_P. A claim has to load above it or it never wins.
PAK_ORDER = 11


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


def game_to_rel(p):
    """/Game/A/B/C.C -> ForeverWinter/Content/A/B/C.uasset"""
    pkg = p.split(".")[0]
    if not pkg.startswith("/Game/"):
        sys.exit(f"expected a /Game/ path, got {p!r}")
    return "ForeverWinter/Content/" + pkg[len("/Game/"):] + ".uasset"


def resolve_source(value, skin_dir, src, kind):
    """Return a .uasset path to clone from, extracting out of the live cook if needed."""
    if value.startswith("/Game/"):
        obj = value.split(".")[-1]
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", obj, PAKS, src],
            quiet=True)
        rel = game_to_rel(value)
        f = src / rel
        if not f.is_file():
            sys.exit(f"{kind}: nothing named {obj!r} came out of the cook for {value!r}")
        return f
    f = (skin_dir / value).resolve()
    if not f.is_file():
        sys.exit(f"{kind}: {f} does not exist")
    if f.suffix != ".uasset":
        sys.exit(f"{kind}: expected a .uasset, got {f.name}")
    return f


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("skin", help="directory containing skin.json")
    ap.add_argument("--slot", help="claimed slot, two digits (overrides skin.json)")
    ap.add_argument("--pool-slots", type=int, default=32,
                    help="depth of the installed framework, for a sanity check")
    args = ap.parse_args()

    skin_dir = Path(args.skin).resolve()
    jf = skin_dir / "skin.json"
    if not jf.is_file():
        sys.exit(f"no skin.json in {skin_dir}")
    skin = json.loads(jf.read_text(encoding="utf-8"))

    char = skin.get("character")
    if char not in CHARACTERS:
        sys.exit(f"character must be one of {', '.join(CHARACTERS)} — got {char!r}")
    slot = args.slot or skin.get("slot")
    if not slot:
        sys.exit("no slot claimed — put \"slot\": \"00\" in skin.json or pass --slot")
    slot = str(slot).zfill(2)
    if not (len(slot) == 2 and slot.isdigit()):
        sys.exit(f"slot must be two digits — got {slot!r}")
    if int(slot) >= args.pool_slots:
        sys.exit(f"slot {slot} is outside the installed pool of {args.pool_slots} "
                 f"(00..{args.pool_slots - 1:02d}); nothing would reference it")

    name = skin.get("name")
    if not name:
        sys.exit("skin.json needs a \"name\"")
    desc = skin.get("description", "")
    mesh_src_v = skin.get("mesh")
    icon_src_v = skin.get("icon")
    if not mesh_src_v:
        sys.exit("skin.json needs a \"mesh\"")
    if not icon_src_v:
        sys.exit("skin.json needs an \"icon\". A claim with no portrait is HIDDEN, not just "
                 "plain: CMSFUnlock treats an icon that does not resolve to the slot's own "
                 "path as proof the slot is unclaimed, and prunes the tile.")

    ident = skin.get("id") or skin_dir.name
    mesh_obj, tex_obj, st_obj = (f"SK_CMSF_{char}_{slot}", f"T_CMSF_{char}_{slot}",
                                 f"ST_CMSF_{char}_{slot}")
    sd = f"ForeverWinter/Content/CMSF/{char}/{slot}"
    pak = f"CMSF_{char}{slot}_{ident}_{PAK_ORDER}_P"

    print(f"==> {name!r} claims {char}/{slot}")

    build = ROOT / "build" / "author" / ident
    src, stage = build / "src", build / "stage"
    out = ROOT / "dist" / "author" / ident
    for d in (stage, out):
        if d.exists():
            shutil.rmtree(d)
    out.mkdir(parents=True)
    src.mkdir(parents=True, exist_ok=True)

    print("==> building tools")
    for t in ("stgen", "mshgen"):
        run(["dotnet", "build", ROOT / "tools" / t, "-c", "Release", "-v", "q", "--nologo"],
            quiet=True)
    stgen  = ROOT / "tools/stgen/bin/Release/net8.0/stgen.exe"
    mshgen = ROOT / "tools/mshgen/bin/Release/net8.0/mshgen.exe"

    print("==> resolving sources")
    mesh_src = resolve_source(mesh_src_v, skin_dir, src, "mesh")
    icon_src = resolve_source(icon_src_v, skin_dir, src, "icon")
    print(f"      mesh  {mesh_src.name}")
    print(f"      icon  {icon_src.name}")

    # mshgen rewrites package identity — both the name-map entry and FolderName. Without
    # that the clone collides by FPackageId and the loader serves it in its template's
    # place, which is the trap that cost an hour in the probe session.
    print(f"==> cloning to /Game/CMSF/{char}/{slot}/")
    run([mshgen, mesh_src, USMAP, stage / sd / f"{mesh_obj}.uasset", mesh_obj], quiet=True)
    run([mshgen, icon_src, USMAP, stage / sd / f"{tex_obj}.uasset", tex_obj], quiet=True)

    # The string table is cloned from the game's own, never from the author's assets.
    st_tpl = src / "ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset"
    if not st_tpl.is_file():
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", "ST_FW_UI_Skins",
             PAKS, src], quiet=True)
    if not st_tpl.is_file():
        sys.exit("could not extract ST_FW_UI_Skins from the cook")
    run([stgen, st_tpl, USMAP, stage / sd / f"{st_obj}.uasset",
         f"CMSF.{char}.{slot}", st_obj,
         f"{ST_KEY_NAME}={name}", f"{ST_KEY_DESC}={desc}"], quiet=True)

    print("==> packing")
    run([RETOC, "to-zen", "--version", "UE5_4", stage, out / f"{pak}.utoc"], quiet=True)
    sz = sum(f.stat().st_size for f in out.glob(f"{pak}.*"))
    print(f"    {pak}   {sz/1024/1024:.2f} MB")

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
    for filt in (mesh_obj, tex_obj, st_obj, "DT_SkinUIData", f"BP_Player_{char}"):
        run([RETOC, "-a", AES, "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout],
            quiet=True)

    problems = []
    for obj in (mesh_obj, tex_obj, st_obj):
        if not (vout / sd / f"{obj}.uasset").is_file():
            problems.append(f"missing from the pak: {obj}")
    # The pak must contain ONLY the three slot packages. Anything else — above all
    # DT_SkinUIData or BP_Player_* — would make two CMSF skins clobber each other.
    shipped = sorted(p.relative_to(stage).as_posix()
                     for p in stage.rglob("*.uasset"))
    allowed = {f"{sd}/{o}.uasset" for o in (mesh_obj, tex_obj, st_obj)}
    for f in shipped:
        if f not in allowed:
            problems.append(f"pak ships something it must not: {f}")
    print(f"    mesh={mesh_obj}  icon={tex_obj}  table={st_obj}")
    print(f"    shipped {len(shipped)} package(s), all inside /Game/CMSF/{char}/{slot}/")

    if problems:
        print("\nVERIFY FAILED:")
        for x in problems:
            print("  " + x)
        return 2

    print(f"\ndone -> {out}\n")
    print(f"Install alongside the framework. This pak MUST load ABOVE it "
          f"(_{PAK_ORDER}_P beats _9_P; under MO2, higher priority wins).")
    print(f"Expect {char} slot {slot} to show {name!r} with this portrait and mesh.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
