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
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fwlocate  # noqa: E402  (local module, beside this script)

ROOT = Path(__file__).resolve().parent.parent
CHARACTERS = ["BagMan", "Girl", "Gunhead", "MaskMan", "OldMan", "Shaman"]

# Must match tools/cmsf_framework.py exactly: the framework's row references this namespace
# and these two keys, and an override only lands if all three agree.
ST_KEY_NAME, ST_KEY_DESC = "Name", "Desc"

# The framework ships at _9_P. A claim has to load above it or it never wins.
PAK_ORDER = 11


# Resolved lazily in main(), after --list-free returns — listing slots needs no toolchain.
RETOC = USMAP = PAKS = None


def run(cmd, quiet=False):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)[:400]}\n{r.stdout}\n{r.stderr}")
    if not quiet and r.stdout.strip():
        for line in r.stdout.strip().splitlines():
            print("      " + line)
    return r.stdout


# docs/slots.md is the registry. Slots 28..31 are the private range: never registered, never
# policed, so a personal or work-in-progress skin never has to touch the file and can never
# collide with a published one.
REGISTRY = ROOT / "docs" / "slots.md"
PRIVATE_FROM = 28

# | Character | Slot | ID | Skin | Author |
_ROW = re.compile(r"^\|\s*(\w+)\s*\|\s*(\d{2})\s*\|\s*([\w.-]+)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|")


def load_registry():
    """{(char, slot): {id, skin, author}} from docs/slots.md. Empty if absent."""
    out = {}
    if not REGISTRY.is_file():
        return out
    for line in REGISTRY.read_text(encoding="utf-8").splitlines():
        m = _ROW.match(line.strip())
        if not m:
            continue
        char, slot, ident, skin, author = m.groups()
        if char in CHARACTERS:      # skips the header and the |---|---| separator
            out[(char, slot)] = {"id": ident, "skin": skin, "author": author}
    return out


def free_slots(char, pool, reg):
    return [f"{i:02d}" for i in range(min(pool, PRIVATE_FROM))
            if (char, f"{i:02d}") not in reg]


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
        run([RETOC, "-a", fwlocate.aes(), "to-legacy", "--version", "UE5_4", "-f", obj, PAKS, src],
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
    ap.add_argument("skin", nargs="?", help="directory containing skin.json")
    ap.add_argument("--slot", help="claimed slot, two digits (overrides skin.json)")
    ap.add_argument("--pool-slots", type=int, default=32,
                    help="depth of the installed framework, for a sanity check")
    ap.add_argument("--list-free", metavar="CHAR",
                    help="list unclaimed public slots for a character and exit")
    ap.add_argument("--unregistered", action="store_true",
                    help="silence the note about building on an unregistered public slot")
    args = ap.parse_args()

    if args.list_free:
        char = args.list_free
        if char not in CHARACTERS:
            sys.exit(f"unknown character {char!r}; known: {', '.join(CHARACTERS)}")
        reg = load_registry()
        free = free_slots(char, args.pool_slots, reg)
        taken = sorted(s for (c, s) in reg if c == char)
        print(f"{char}: pool 00..{args.pool_slots - 1:02d}, "
              f"public 00..{PRIVATE_FROM - 1:02d}, private {PRIVATE_FROM:02d}..31")
        print(f"  free   {', '.join(free) if free else '(none)'}")
        for s in taken:
            h = reg[(char, s)]
            print(f"  {s}     {h['id']}  -  {h['skin']} by {h['author']}")
        if not REGISTRY.is_file():
            print(f"  (no registry at {REGISTRY} — every public slot reads as free)")
        return 0

    if not args.skin:
        ap.error("a skin directory is required (or use --list-free CHAR)")
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

    ident = skin.get("id") or skin_dir.name

    # Registry check. Taking someone else's slot is an error; building on an unregistered
    # public slot is only a warning, so nobody is ever blocked waiting on a merge to test
    # something locally. The private range is not policed at all.
    reg = load_registry()
    held = reg.get((char, slot))
    if held and held["id"] != ident:
        free = free_slots(char, args.pool_slots, reg)
        sys.exit(f"{char}/{slot} is registered to {held['id']!r} "
                 f"({held['skin']} by {held['author']}) - claiming it would make one of the "
                 f"two skins invisible.\n"
                 f"  free public slots for {char}: "
                 f"{', '.join(free) if free else '(none — the public range is full)'}\n"
                 f"  see docs/slots.md, or use {PRIVATE_FROM:02d}..31 for a private skin")
    if not held and int(slot) < PRIVATE_FROM and not args.unregistered:
        print(f"    NOTE  {char}/{slot} is not in docs/slots.md. Fine for testing; claim it "
              f"before publishing, or use {PRIVATE_FROM:02d}..31 for a private skin.")

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

    # All input is validated; only now locate the toolchain (--list-free needs none of it).
    global RETOC, USMAP, PAKS
    RETOC, USMAP, PAKS = fwlocate.retoc(), fwlocate.usmap(), fwlocate.paks()

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
        run([RETOC, "-a", fwlocate.aes(), "to-legacy", "--version", "UE5_4", "-f", "ST_FW_UI_Skins",
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
        run([RETOC, "-a", fwlocate.aes(), "to-legacy", "--version", "UE5_4", "-f", filt, vsrc, vout],
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
