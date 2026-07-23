#!/usr/bin/env python3
"""CMSF build — generate one pak that adds every registered skin to the game.

CMSF is a GENERATOR, not a fixed framework pak. It reads the skins registered under
`skins/`, and emits a single pak containing:

  * each affected BP_Player_<Char> with the skins' meshes APPENDED to
    FWSkinChangeComponent.SkinChoices   (availability)
  * DT_SkinUIData with one appended row per skin                (identity: name/desc/icon)

Why a generator rather than a reserved slot pool: a pak override replaces a whole asset, so
only one artifact can own DT_SkinUIData and the BP_Player_* assets. Regenerating a combined
pak from all registered skins sidesteps that completely — no fixed pool size, no slot
allocation registry, no "CMSF Slot 05" placeholder names, and no empty slots pointing at
assets that do not exist. Adding a skin means dropping in a folder and re-running this.

Always re-extracts from the LIVE cook, never from a committed snapshot, so output is rebased
on whatever build is installed. Verifies by decoding the built pak back out and asserting
every mesh and row survived — a silently-empty pak is indistinguishable in-game from "the
approach does not work", and we have already been bitten by exactly that.

Note: this is Python rather than shell on purpose. Git Bash's MSYS path conversion rewrites
any argument starting with /Game/... into C:/Program Files/Git/Game/..., which silently
corrupted an earlier build. subprocess with a list argv bypasses that entirely.

Usage:
    python tools/cmsf_build.py            # build
    python tools/cmsf_build.py --list     # show what is registered, build nothing
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fwlocate  # noqa: E402  (local module, beside this script)

ROOT = Path(__file__).resolve().parent.parent

# Pawn Blueprint per character key. These are the only six playable characters;
# BP_Player_MaskMan is the one usually mis-remembered as "Mech Trooper".
CHARACTERS = {
    "BagMan":  "BP_Player_BagMan",
    "Girl":    "BP_Player_Girl",
    "Gunhead": "BP_Player_Gunhead",
    "MaskMan": "BP_Player_MaskMan",
    "OldMan":  "BP_Player_OldMan",
    "Shaman":  "BP_Player_Shaman",
}

BP_DIR = "ForeverWinter/Content/FW/Player/Class"
TABLE_REL = "ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset"

# retoc/usmap/paks resolve from the --flags, then env vars, then fwlocate discovery (Steam
# for the paks, tools/retoc and PATH for retoc, USMAP for the mappings). The game's AES key
# comes from FW_AES_KEY and is never bundled — see tools/fwlocate.py.

# Load order: the token between the LAST TWO underscores of a _P.pak is parsed as the chunk
# version (N -> N+1, PakOrder += 100*CVN). A numeric PREFIX is inert. Under MO2 the plugin
# appends its own priority token, which then wins the parse — harmless, since nothing else
# ships these assets.
PAK_NAME = "CMSF_9_P"


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.exit(f"FAILED: {' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def load_skins():
    """Every skins/*/skin.json, validated. Returns {character: [skin, ...]}."""
    out = {}
    skins_dir = ROOT / "skins"
    if not skins_dir.is_dir():
        return out
    for d in sorted(p for p in skins_dir.iterdir() if p.is_dir()):
        f = d / "skin.json"
        if not f.is_file():
            continue
        try:
            s = json.loads(f.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            sys.exit(f"{f}: invalid JSON — {e}")

        missing = [k for k in ("character", "name", "mesh") if not s.get(k)]
        if missing:
            sys.exit(f"{f}: missing required field(s): {', '.join(missing)}")
        if s["character"] not in CHARACTERS:
            sys.exit(f"{f}: unknown character {s['character']!r}; expected one of "
                     f"{', '.join(CHARACTERS)}")
        for k in ("mesh", "icon"):
            v = s.get(k)
            if v and ("." not in v.rsplit("/", 1)[-1] or not v.startswith("/Game/")):
                sys.exit(f"{f}: {k} must look like /Game/Path/Asset.Asset — got {v!r}")

        s["id"] = s.get("id") or d.name
        s["row"] = f"CMSF.{s['character']}.{s['id']}"      # dotted names are proven to work
        s.setdefault("description", "")
        # Falling back to the character's stock portrait keeps an icon-less skin from
        # showing an empty tile; authors are expected to override it.
        s.setdefault("icon", "/Game/UI/Textures/MainMenu/Menu/"
                             "T_Menu_PickCharacter_Portrait_ScavGirl."
                             "T_Menu_PickCharacter_Portrait_ScavGirl")
        s["_src"] = str(f)
        out.setdefault(s["character"], []).append(s)
    return out


def main():
    ap = argparse.ArgumentParser(description="Build the CMSF pak from registered skins.")
    ap.add_argument("--paks", default=os.environ.get("FW_PAKS"))
    ap.add_argument("--retoc", default=os.environ.get("RETOC"))
    ap.add_argument("--usmap", default=os.environ.get("USMAP"))
    ap.add_argument("--out", default=str(ROOT / "dist" / "CMSF"))
    ap.add_argument("--list", action="store_true", help="show registered skins and exit")
    ap.add_argument("--pool", type=int, default=0, metavar="N",
                    help="also reserve N empty slots per character (CMSF Core pool build). "
                         "Reserved slots point at framework-owned paths that no asset "
                         "occupies until a skin mod ships one there.")
    ap.add_argument("--pool-characters", default=",".join(CHARACTERS),
                    help="comma-separated characters to reserve pool slots for")
    args = ap.parse_args()

    skins = load_skins()

    # Reserved pool slots. These point at framework-owned paths that NOTHING occupies until
    # a skin mod ships an asset there — which is exactly what lets CMSF Core be prebuilt and
    # dropped in, with no toolchain on the user's side.
    #
    # Open question this is built to answer first: does the game silently skip a soft path
    # that does not resolve, or does it render an empty entry? If it skips, unclaimed slots
    # cost nothing and no pruning is needed. If it renders, CMSFUnlock must hide them.
    for char in [c.strip() for c in args.pool_characters.split(",") if c.strip()]:
        if char not in CHARACTERS:
            sys.exit(f"--pool-characters: unknown character {char!r}")
        for i in range(args.pool):
            slot = f"{i:02d}"
            base = f"/Game/CMSF/{char}/{slot}"
            skins.setdefault(char, []).append({
                "character": char,
                "id": slot,
                "row": f"CMSF.{char}.{slot}",
                "name": f"CMSF Slot {slot} (empty)",
                "description": "Nothing is installed here yet. Install a skin mod that "
                               "claims this slot, or hide empty slots with CMSFUnlock.",
                "mesh": f"{base}/SK_CMSF_{char}_{slot}.SK_CMSF_{char}_{slot}",
                # Vanilla "locked" portrait rather than a slot-specific texture that will
                # not exist until claimed. An unresolvable icon renders as a blank white
                # tile that reads as breakage; this makes an unclaimed slot look deliberate.
                # Purely a fallback for when CMSFUnlock's pruning is absent or fails —
                # normally these are hidden before the player ever sees them.
                "icon": "/Game/UI/Textures/MainMenu/Menu/"
                        "T_Menu_PickCharacter_Portrait_LockedV2."
                        "T_Menu_PickCharacter_Portrait_LockedV2",
                "_src": "(reserved pool slot)",
                "_pool": True,
            })

    total = sum(len(v) for v in skins.values())

    if args.list or total == 0:
        if total == 0:
            print("No skins registered under skins/. See docs/04-authoring.md.")
            return 0
        for char, items in sorted(skins.items()):
            print(f"{char} ({len(items)}):")
            for s in items:
                print(f"  {s['row']:36} {s['name']!r}")
                print(f"  {'':36} {s['mesh']}")
        return 0

    # Everything below needs the toolchain; --list and the no-skins case have already returned.
    args.paks = args.paks or fwlocate.paks()
    args.retoc = args.retoc or fwlocate.retoc()
    args.usmap = args.usmap or fwlocate.usmap()
    for p in (args.retoc, args.usmap):
        if not Path(p).is_file():
            sys.exit(f"missing: {p}")
    if not Path(args.paks).is_dir():
        sys.exit(f"missing paks dir: {args.paks}")

    skinpatch = ROOT / "tools" / "skinpatch" / "bin" / "Release" / "net8.0" / "skinpatch.exe"
    print("==> building skinpatch")
    run(["dotnet", "build", str(ROOT / "tools" / "skinpatch"), "-c", "Release", "-v", "q", "--nologo"])
    if not skinpatch.is_file():
        sys.exit(f"skinpatch not found at {skinpatch}")

    build = ROOT / "build" / "gen"
    src, staged = build / "src", build / "staged"
    for d in (build,):
        shutil.rmtree(d, ignore_errors=True)
    src.mkdir(parents=True)
    staged.mkdir(parents=True)

    # --- extract from the live cook -----------------------------------------------------
    needed = sorted(CHARACTERS[c] for c in skins)
    print(f"==> extracting {len(needed)} pawn Blueprint(s) + DT_SkinUIData from the live cook")
    for f in needed + ["DT_SkinUIData"]:
        run([args.retoc, "-a", fwlocate.aes(), "to-legacy", "--version", "UE5_4", "-f", f,
             args.paks, str(src)])

    # --- patch the roster, one Blueprint per affected character -------------------------
    for char, items in sorted(skins.items()):
        bp = CHARACTERS[char]
        rel = f"{BP_DIR}/{bp}.uasset"
        if not (src / rel).is_file():
            sys.exit(f"extract produced no {bp} — is the filter still correct for this build?")
        (staged / BP_DIR).mkdir(parents=True, exist_ok=True)
        print(f"==> {bp}: appending {len(items)} mesh(es) to SkinChoices")
        out = run([str(skinpatch), "bpadd", str(src / rel), args.usmap, str(staged / rel)]
                  + [s["mesh"] for s in items])
        for line in out.splitlines():
            if line.startswith(("  +", "  =", "SkinChoices")):
                print("    " + line.strip())

    # --- patch the presentation table ---------------------------------------------------
    if not (src / TABLE_REL).is_file():
        sys.exit("extract produced no DT_SkinUIData")
    (staged / Path(TABLE_REL).parent).mkdir(parents=True, exist_ok=True)
    specs = [f"{s['row']}|{s['name']}|{s['description']}|{s['icon']}|{s['mesh']}"
             for items in skins.values() for s in items]
    print(f"==> DT_SkinUIData: appending {len(specs)} row(s)")
    out = run([str(skinpatch), "add", str(src / TABLE_REL), args.usmap,
               str(staged / TABLE_REL)] + specs)
    print("    " + out.strip().splitlines()[-1])

    # --- repack -------------------------------------------------------------------------
    outdir = Path(args.out)
    shutil.rmtree(outdir, ignore_errors=True)
    outdir.mkdir(parents=True)
    print("==> repacking")
    run([args.retoc, "to-zen", "--version", "UE5_4", str(staged), str(outdir / f"{PAK_NAME}.utoc")])

    # --- verify by decoding the BUILT pak back out --------------------------------------
    # Never trust that the writes landed; a pak that installs cleanly and does nothing looks
    # exactly like a failed approach.
    print("==> verifying built pak")
    vsrc, vout = build / "vsrc", build / "vout"
    vsrc.mkdir()
    for g in ("global.utoc", "global.ucas"):          # mod pak has no ScriptObjects chunk
        shutil.copy(Path(args.paks) / g, vsrc / g)
    for f in outdir.iterdir():
        shutil.copy(f, vsrc / f.name)
    run([args.retoc, "to-legacy", "--version", "UE5_4", str(vsrc), str(vout)])

    problems = []
    for char, items in sorted(skins.items()):
        rel = f"{BP_DIR}/{CHARACTERS[char]}.uasset"
        got = run([str(skinpatch), "bpskins", str(vout / rel), args.usmap])
        for s in items:
            pkg = s["mesh"].rsplit(".", 1)[0]
            if pkg not in got:
                problems.append(f"{CHARACTERS[char]}: mesh missing after repack — {s['mesh']}")
    table = run([str(skinpatch), "inspect", str(vout / TABLE_REL), args.usmap])
    for items in skins.values():
        for s in items:
            if s["row"] not in table:
                problems.append(f"DT_SkinUIData: row missing after repack — {s['row']}")

    if problems:
        print("\nVERIFY FAILED:")
        for p in problems:
            print("  " + p)
        return 2

    print(f"    ok: {total} skin(s), {len(skins)} character(s) verified in the built pak")
    print("\ndone:")
    for f in sorted(outdir.iterdir()):
        print(f"  {f}")
    print("\nInstall the trio to Content\\Paks\\Mods\\ (or as an MO2 mod with them under Mods\\),")
    print("and enable the CMSFUnlock UE4SS mod so the selector lists them.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
