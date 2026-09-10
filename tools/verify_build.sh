#!/usr/bin/env bash
# Verify the shipped CMSF paks against the LIVE game build.
#
# WHY THIS EXISTS
#   Every build path here stops at retoc's container check plus the generator's own decode-back
#   pass, and both of those are measured against the cook the pak was BUILT on. Neither says
#   anything about the build that is installed today. That is exactly the gap that passed
#   AllWeaponsUnlockableFix's pak on build 24479102 while every weapon in the game pointed at a
#   deleted DataAsset -- a user found that, not the build. See tools/verify_softrefs.py.
#
# WHAT CMSF OWNS (read from the build scripts, not guessed)
#   tools/cmsf_framework.py -> dist/framework/CMSF_Core_9_P
#     OVERRIDES  ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset      (TBL_REL, :47)
#     OVERRIDES  ForeverWinter/Content/FW/Player/Class/BP_Player_<Char>.uasset  (BP_DIR :46,
#                CHARACTERS :44 = BagMan, Girl, Gunhead, MaskMan, OldMan, Shaman)
#     ADDS       ForeverWinter/Content/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>.uasset  (:77, :142)
#                (ST_FW_UI_Skins at :48 is only the clone template, never shipped)
#   tools/cmsf_author.py -> dist/author/<id>/CMSF_<Char><NN>_<id>_11_P
#     ADDS ONLY  ForeverWinter/Content/CMSF/<Char>/<NN>/{SK_,T_,ST_}CMSF_<Char>_<NN>.uasset
#                (:222, :296 -- the build FAILS if it ships anything else)
#
#   So there are three ways a patch breaks this mod, and all three are checked below:
#     1. a vanilla mesh or portrait the rows and SkinChoices arrays point at gets renamed
#        -> the frozen override pins a dead name                     [soft-reference check]
#     2. the devs ADD a skin row or a roster entry
#        -> our whole-asset override silently DELETES their new content for every CMSF user
#           and logs nothing anywhere                                [reversion check]
#     3. the devs EDIT A VALUE IN PLACE in an asset we override -- same row keys, same paths,
#        same array lengths, so checks 1 and 2 both report clean while the pak serves a
#        months-old copy                                             [cook-drift check, #5]
#        Found the hard way on 25071553: six pawn .uexp files drifted by 2-23 scalar bytes at
#        identical length while checks 1-4 all passed. See docs/10-patch-25071553.md.
#
# THE FROZEN CONTRACT, AND WHY /Game/CMSF/ IS IGNORED
#   CMSF publishes slot paths under /Game/CMSF/<Char>/<NN>/ as a PUBLIC ABI: third-party skin
#   authors cook their own mesh, portrait and string table to those exact paths. Those paths are
#   ABSENT FROM THE BASE GAME BY DESIGN and their absence is the REQUIRED state, not a defect --
#   an unclaimed slot resolves to nothing, which is harmless, while shipping anything at the
#   icon path would make the slot permanently unprunable.
#
#   A naive soft-reference run therefore reports all ~384 slot mesh/portrait references as
#   "dangling" and is WRONG. They are ignored here deliberately. See the FROZEN CONTRACT
#   identifiers section of tfw-update-ops/state/asset-dependencies.md, which reaches the same
#   conclusion ("Mis-recorded by schema, not broken ... Reclassify, do not investigate").
#
#   The correct assertion for that namespace is INVERTED, and it is check [2] below: the live
#   filelist must hold ZERO ForeverWinter/Content/CMSF/ entries. A non-zero count means the
#   developers have collided with the framework's namespace and every claimed third-party slot
#   in the wild breaks at once.
#
# WHY THIS DOES NOT COPY ScavgirlCarryPerks/tools/verify_build.sh EXACTLY
#   That script stages the whole live game as hardlinks and drops the mod in renamed zzz_ so it
#   "wins the FPackageId collision". Measured on this repo, that does not hold: CUE4Parse's
#   provider resolves each colliding path independently and NON-DETERMINISTICALLY. Nine full
#   mounts of CMSF_Core_9_P over the live game returned the mod's copy for 0, 3, 4 or 7 of its
#   7 overridden packages depending on the run, and renaming the pak 000_/aaa_/zzz_ changed
#   nothing. A green run there is luck, and a losing run silently grades the BASE GAME while
#   printing "OK 0 dangling" -- precisely the laundered non-result verify_softrefs' exit 2 was
#   added to stop. So:
#
#     * a pak that OVERRIDES base assets is mounted ALONE (its trio + global.utoc/global.ucas).
#       No base copy is present, so no collision can occur and the bytes are certainly the
#       mod's. FSoftObjectPath values -- AssetPathName, which is where a DataTable row and a
#       SkinChoices entry pin their target -- are stored as strings in the package and survive
#       this intact. Hard imports (a mesh's Skeleton, its materials) resolve through the global
#       package store and come out null here; that is a documented gap, and it is not this
#       pak's exposure.
#     * a pak that only ADDS packages collides with nothing, so it is mounted over the full
#       live game, where its hard imports DO resolve. That is exactly its exposure.
#
#   bash tools/verify_build.sh
#
# ---------------------------------------------------------------------------------------------
# WHICH OF THESE CHECKS SURVIVE A STALE USMAP  (gate 1b was RED on build 25071553)
#
# The right question is not "is the usmap stale" but: DID THIS CONCLUSION COME FROM THE TYPE
# MAP, OR FROM THE PACKAGE'S OWN NAME TABLE? Framing due to the tfw-update-ops board; see
# tfw-update-ops/docs/gate-1b-partial-validity.md. A blanket "1b is red so nothing counts"
# freezes work that is provably fine.
#
#   SOUND under a stale map -- name-table or byte derived:
#     * check [5]'s byte comparison via `retoc to-legacy`, which is passed NO usmap at all.
#       This is the gold standard in this file and the reason it exists.
#     * check [5]'s script-object name-set diff (tools/scriptobjects_diff.py) -- name batches.
#     * check [1]/[2] filelist and path existence, and FPackageId binding.
#     * DataTable ROW KEYS and soft-path STRINGS -- both live in the package name map.
#     * anything tools/zen_imports.py reports: raw zen header bytes, no type map.
#
#   VOID under a stale map -- type-map derived:
#     * property counts, property names, any scalar value, "0 properties dropped",
#       and any catalog rebuilt from a decode.
#
# THE REFINEMENT THAT ACTUALLY BITES, and it applies to checks [3] and [4] here:
# a detected DIFFERENCE is sound; a detected IDENTITY is not. A stale map TRUNCATES -- on this
# build FWWeaponDefinition stops at 30 properties of 57 -- and anything past the truncation
# point is never compared and therefore reports clean. So "identical" only ever means
# "identical in the part the map could still reach", and a soft-reference check can report
# 0 DANGLING because it never reached the properties that hold the references.
#
# So the reversion check [4] survives BECAUSE it rests on row keys, soft-path strings and array
# lengths. It would not survive if it rested on property shape. That is a stronger claim than
# "check [5] is the one I trust", and it was verified rather than asserted:
#
#   DT_SkinUIData, live base: 33 rows x 2 FSkinDetails soft paths = 66 occurrences, of which
#   53 are DISTINCT -- the 13-path gap is exactly 7 character portraits shared across rows
#   (ScavGirl x5, BagMan x4, MaskMan x3, OldMan/Gunhead/Shaman/DLC04_Scavgirl x2). The check
#   reports 53. The arithmetic closes to the unit, so FSkinDetails is decoding FULLY and this
#   particular "0 dropped" is not a truncation artifact.
#
# That verification covers FSkinDetails (4 fields). It does NOT extend to the pawn Blueprints,
# whose property shape is exactly the risky case -- so treat [3]/[4] pawn numbers as bounded by
# the caveat above until 1b is green.
# ---------------------------------------------------------------------------------------------

# Requires: the game installed, the forever-winter-datamine decoder built, python.
# NEVER launches the game. Reads paks only.
# Exit: 0 clean - 1 real breakage found - 2 the check could not run.
set -uo pipefail

# ---------------------------------------------------------------------------------------------
# Per-machine path resolution.
#
# This collection is worked on from two machines: SylG5 (laptop, everything on D:) and SylDesk
# (desktop, everything on H:). A hardcoded root works on exactly one of them, and a
# find-and-replace that fixes one BREAKS the other. So nothing below is hardcoded:
#
#   1. an explicit environment variable always wins (REPO / GAME_PAKS / DECODER / USMAP)
#   2. otherwise each candidate root is tried in order and the first that EXISTS is used
#
# Adding a third machine means adding its drive to ROOTS. If nothing resolves the script prints
# every candidate it tried and exits 2 -- it never guesses, and it never "passes" by skipping.
ROOTS="D: H:"

PAKS_SUFFIX="/SteamLibrary/steamapps/common/The Forever Winter/Windows/ForeverWinter/Content/Paks"
DEC_SUFFIX="/Github Repositories/forever-winter-datamine/datamine/decoder/bin/Release/net10.0/fwextract.exe"
MAP_DIR_SUFFIX="/Github Repositories/forever-winter-datamine/datamine/mappings"
USMAP_SUFFIX="$MAP_DIR_SUFFIX/ForeverWinter-5.4.2.usmap"
REPO_SUFFIX="/Github Repositories/TFWCharModelSelFramework"

pick() {                                  # pick <what> <suffix>; echo the first that exists
  local what="$1" suffix="$2" r tried=""
  for r in $ROOTS; do
    if [ -e "$r$suffix" ]; then printf '%s\n' "$r$suffix"; return 0; fi
    tried="$tried
    $r$suffix"
  done
  echo "MISSING: could not locate the $what. Looked for:$tried" >&2
  echo "  Set the matching environment variable (REPO / GAME_PAKS / DECODER / USMAP)." >&2
  return 1
}

# REPO needs no drive list in the normal case: this script lives inside the repo, so its own
# location is right on every machine by construction. The root list is the fallback for a copy
# that has been moved out of the tree.
SELF_REPO="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
if [ -z "${REPO:-}" ]; then
  if [ -f "$SELF_REPO/tools/verify_softrefs.py" ]; then
    REPO="$SELF_REPO"
  else
    REPO="$(pick "CMSF repo" "$REPO_SUFFIX")" || exit 2
  fi
fi

GAME_PAKS="${GAME_PAKS:-$(pick "game Paks directory" "$PAKS_SUFFIX")}" || exit 2
DECODER="${DECODER:-$(pick "fwextract decoder" "$DEC_SUFFIX")}"        || exit 2

# The usmap filename carries the engine version and will be renamed eventually. Take the named
# one, else the sole *.usmap in that folder -- but never guess between several, because a wrong
# type map does not fail, it decodes plausible-but-wrong values under neighbouring names.
if [ -z "${USMAP:-}" ]; then
  if ! USMAP="$(pick "usmap" "$USMAP_SUFFIX" 2>/dev/null)"; then
    MAPDIR="$(pick "mappings directory" "$MAP_DIR_SUFFIX")" || exit 2
    N=$(ls -1 "$MAPDIR"/*.usmap 2>/dev/null | wc -l)
    if [ "$N" -eq 1 ]; then
      USMAP="$(ls -1 "$MAPDIR"/*.usmap)"
      echo "NOTE: $(basename "$USMAP_SUFFIX") is gone; using the only usmap in $MAPDIR"
    else
      echo "MISSING: $USMAP_SUFFIX, and $MAPDIR holds $N .usmap files." >&2
      echo "  Set USMAP to the one matching the installed build." >&2
      exit 2
    fi
  fi
fi

# An explicit override that points at nothing is a typo, not a configuration. Say so here
# rather than failing three minutes into a decode.
for v in REPO GAME_PAKS DECODER USMAP; do
  eval "p=\$$v"
  [ -e "$p" ] || { echo "MISSING: $v is set to a path that does not exist: $p"; exit 2; }
done

PY="${PY:-python}"
command -v "$PY" >/dev/null 2>&1 || { echo "MISSING: python (set PY)"; exit 2; }
[ -f "$REPO/tools/verify_softrefs.py" ] || { echo "MISSING: $REPO/tools/verify_softrefs.py"; exit 2; }
for g in global.utoc global.ucas; do
  [ -f "$GAME_PAKS/$g" ] || { echo "MISSING: $GAME_PAKS/$g (needed to mount a pak alone)"; exit 2; }
done

# build/ is gitignored precisely because decoded game assets are copyright-derived and must
# never be committed, so the work tree goes there rather than in a fresh work/. It MUST sit on
# the same volume as the game or the hardlink staging below fails.
WORK="$REPO/build/verify-live"

# The assets this mod owns. The BP path prefix is deliberate: a bare "BP_Player_" also matches
# the 14 vanilla ABP_Player_* animation layers, which this mod does not touch and must not be
# judged on. "Content/CMSF/" is the mod's own namespace, shipped by both pak kinds.
OWNED="FW/Player/Data/DT_SkinUIData,FW/Player/Class/BP_Player_"
SLOTS="Content/CMSF/"

# The frozen public ABI, ignored by verify_softrefs for the reasons in the header.
# NOTE the missing leading slash: Git Bash's MSYS layer rewrites any argument that STARTS with a
# slash into a Windows path (/Game/CMSF/ -> C:/Program Files/Git/Game/CMSF/), which would
# silently disarm the ignore and make every slot read as dangling. tools/cmsf_build.py documents
# the same hazard. Substring matching in verify_softrefs is unanchored, so dropping the leading
# slash is exact enough and portable; both engine spellings are passed.
IGNORE_A="Game/CMSF/"
IGNORE_B="Content/CMSF/"

echo "repo    $REPO"
echo "paks    $GAME_PAKS"
echo "decoder $DECODER"
echo "usmap   $USMAP"

rm -rf "$WORK"; mkdir -p "$WORK"
# CUE4Parse auto-downloads oodle-data-shared.dll into the CURRENT directory on first mount.
# Run from the gitignored work tree so it does not land in the repo root as an untracked file.
# Every path resolved above is absolute, so this is safe.
cd "$WORK" || { echo "MISSING: cannot enter $WORK"; exit 2; }
FAIL=0
NORUN=0
DRIFT=0   # 0 = in sync, 1 = cook has moved (rebuild owed), 2 = check [5] skipped

# ---------------------------------------------------------------------------------------------
echo
echo "[1/5] regenerate the base filelist from the LIVE game"
BASELIST="$WORK/base-list"; mkdir -p "$BASELIST"
FW_OUT="$BASELIST" FW_PAKS="$GAME_PAKS" FW_USMAP="$USMAP" "$DECODER" list >"$WORK/list.log" 2>&1
if [ ! -s "$BASELIST/filelist.txt" ]; then
  echo "      FAIL the decoder produced no filelist. Nothing below could have been checked."
  tail -20 "$WORK/list.log" | sed 's/^/      /'
  exit 2
fi
echo "      $(wc -l < "$BASELIST/filelist.txt") entries"

# ---------------------------------------------------------------------------------------------
# The inverted assertion. This is the one check in this repo that guards OTHER PEOPLE's paks.
echo
echo "[2/5] frozen-contract namespace must stay vacant"
CMSF_HITS=$(grep -c "^ForeverWinter/Content/CMSF/" "$BASELIST/filelist.txt" || true)
if [ "$CMSF_HITS" -eq 0 ]; then
  echo "      OK   0 ForeverWinter/Content/CMSF/ entries in the live build (required: 0)"
else
  echo "      FAIL $CMSF_HITS ForeverWinter/Content/CMSF/ entries in the LIVE build."
  grep "^ForeverWinter/Content/CMSF/" "$BASELIST/filelist.txt" | head -20 | sed 's/^/        /'
  echo "      The developers have collided with CMSF's public namespace. Every claimed"
  echo "      third-party slot in the wild breaks at once. This is not a CMSF bug and it"
  echo "      cannot be fixed by rebuilding -- the ABI has to be renegotiated."
  FAIL=1
fi

# ---------------------------------------------------------------------------------------------
echo
echo "[3/5] decode the CURRENT BASE owned assets (reference for the reversion check)"
BASEOUT="$WORK/base"; mkdir -p "$BASEOUT"
FW_OUT="$BASEOUT" FW_PAKS="$GAME_PAKS" FW_USMAP="$USMAP" \
  "$DECODER" dumptree "$OWNED" base >"$WORK/base.log" 2>&1
NBASE=$(find "$BASEOUT/dumptree/base" -name "*.json" 2>/dev/null | wc -l)
echo "      $NBASE base dump(s)  (expect 7: DT_SkinUIData + 6 pawns)"
if [ "$NBASE" -eq 0 ]; then
  echo "      FAIL the decoder wrote no base dumps. The filter or the decoder mode is wrong."
  tail -20 "$WORK/base.log" | sed 's/^/      /'
  exit 2
fi

# ---------------------------------------------------------------------------------------------
echo
echo "[4/5] decode each shipped pak + verify"

# label | path under dist/ (no extension) | kind
#   override = owns DT_SkinUIData and the pawns -> mounted ALONE (see the header), reversion
#              check applies
#   addition = ships only its own slot packages -> mounted over the FULL live game, nothing it
#              could revert
for spec in \
  "framework|framework/CMSF_Core_9_P|override" \
  "release-v0.2.0|release/CMSF-v0.2.0/Windows/ForeverWinter/Content/Paks/Mods/CMSF_Core_9_P|override" \
  "author-octogirl|author/octogirl/CMSF_Girl00_octogirl_11_P|addition"
do
  LABEL="${spec%%|*}"; REST="${spec#*|}"; PAK="${REST%%|*}"; KIND="${REST##*|}"
  echo
  echo "  --- $LABEL ($KIND) ---"
  if [ ! -e "$REPO/dist/$PAK.utoc" ]; then
    echo "      SKIP not built: dist/$PAK.utoc"
    continue
  fi

  VSTAGE="$WORK/stage"; VOUT="$WORK/out-$LABEL"
  rm -rf "$VSTAGE" "$VOUT"; mkdir -p "$VSTAGE" "$VOUT"

  # global.utoc carries the ScriptObjects chunk; a mod pak has none, so it is always staged.
  LINKED=0
  if [ "$KIND" = "addition" ]; then
    for f in "$GAME_PAKS"/*; do
      [ -f "$f" ] || continue
      ln "$f" "$VSTAGE/$(basename "$f")" 2>/dev/null && LINKED=$((LINKED + 1))
    done
    FILTER="$SLOTS"                       # only the mod's own packages; the base assets the
                                          # OWNED filter would also match are not this pak's
  else
    for g in global.utoc global.ucas; do
      ln "$GAME_PAKS/$g" "$VSTAGE/$g" 2>/dev/null && LINKED=$((LINKED + 1))
    done
    FILTER="$OWNED,$SLOTS"
  fi
  if [ "$LINKED" -eq 0 ]; then
    echo "      FAIL hardlinked 0 files from the game into $VSTAGE."
    echo "      The work dir must be on the SAME VOLUME as the game for ln to work."
    rm -rf "$VSTAGE"; NORUN=1; continue
  fi
  for e in pak ucas utoc; do
    [ -f "$REPO/dist/$PAK.$e" ] && cp "$REPO/dist/$PAK.$e" "$VSTAGE/zzz_CMSF.$e"
  done

  FW_OUT="$VOUT" FW_PAKS="$VSTAGE" FW_USMAP="$USMAP" \
    "$DECODER" dumptree "$FILTER" shipped >"$WORK/$LABEL.log" 2>&1
  rm -rf "$VSTAGE"

  SHIPDIR="$VOUT/dumptree/shipped"
  NSHIP=$(find "$SHIPDIR" -name "*.json" 2>/dev/null | wc -l)
  NCMSF=$(find "$SHIPDIR" -name "*CMSF*.json" 2>/dev/null | wc -l)
  echo "      staged $LINKED game container file(s) + this pak; $NSHIP dump(s), $NCMSF in the CMSF namespace"

  # Mount gate. If the mod's own packages are not in the dump then the pak did not mount, and
  # everything below would be measuring something else and calling it a pass. Same reasoning as
  # verify_softrefs' exit 2: a non-result must never be laundered into a result.
  if [ "$NCMSF" -eq 0 ]; then
    echo "      FAIL no CMSF-namespace package appeared in the dump. Nothing here was verified."
    tail -10 "$WORK/$LABEL.log" | sed 's/^/        /'
    NORUN=1; continue
  fi

  "$PY" "$REPO/tools/verify_softrefs.py" "$SHIPDIR" "$BASELIST/filelist.txt" \
        "$IGNORE_A" "$IGNORE_B"
  rc=$?
  [ $rc -eq 1 ] && FAIL=1
  [ $rc -eq 2 ] && NORUN=1

  [ "$KIND" = "override" ] || continue

  # -------------------------------------------------------------------------------------------
  # Reversion check -- the Group 1 staleness inversion, and the reason this mod is the most
  # dangerous one in the collection to leave stale. It asks one question per owned asset: does
  # the shipped override still carry everything the CURRENT LIVE base carries?
  #
  # SCOPE, and why it is not simply "every reference".
  # The base side is dumped over the full game and the shipped side alone (header: the full
  # mount is a race), so only surfaces that survive BOTH mount styles can be compared. Measured
  # on this build:
  #   * DT_SkinUIData      survives whole. Row keys AND every FSoftObjectPath match, so both
  #                        are compared -- a dev-added skin row, or a row repointed at a new
  #                        mesh, is caught.
  #   * BP_Player_<Char>   degrades: a sub-object whose hard import cannot resolve serialises
  #                        as null, taking ~16 unrelated soft paths (VO sound cues) with it.
  #                        Comparing those would report ~91 phantom losses. SkinChoices --
  #                        the array bpadd appends to, and the ONLY property of these pawns
  #                        this mod alters -- does survive intact and is compared. That is
  #                        also the array the generator checks at build time
  #                        (tools/cmsf_framework.py:204-211), and it doubles as the random
  #                        respawn pool, so dropping a vanilla entry degrades the game for
  #                        users with no skin mods at all.
  # Not covered: a rename confined to a pawn property CMSF never touches. That is not this
  # mod's exposure, and claiming otherwise would be the false confidence this whole file exists
  # to avoid.
  "$PY" - "$BASEOUT/dumptree/base" "$SHIPDIR" "$LABEL" <<'PY'
import json, os, re, sys
base_dir, ship_dir, label = sys.argv[1:4]

STEM = re.compile(r"__[0-9a-f]{8}\.json$")     # dumptree appends a per-run path hash

def load(d):
    """{logical asset path: parsed json} for every dump under d."""
    out = {}
    for root, _dirs, files in os.walk(d):
        for f in files:
            if not f.endswith(".json"):
                continue
            try:
                with open(os.path.join(root, f), encoding="utf-8") as fh:
                    out[STEM.sub("", f)] = json.load(fh)
            except (OSError, ValueError):
                pass
    return out

def rows(doc):
    """DataTable row keys, or None if this is not a DataTable."""
    for e in doc if isinstance(doc, list) else []:
        if isinstance(e, dict) and isinstance(e.get("Rows"), dict):
            return set(e["Rows"])
    return None

def softpaths(doc):
    return set(re.findall(r'"AssetPathName":\s*"([^"]+)"', json.dumps(doc)))

def skinchoices(doc):
    """Every entry of every SkinChoices array in the document."""
    out = set()
    def walk(n):
        if isinstance(n, dict):
            for k, v in n.items():
                if k == "SkinChoices" and isinstance(v, list):
                    for x in v:
                        if isinstance(x, dict) and x.get("AssetPathName"):
                            out.add(x["AssetPathName"])
                walk(v)
        elif isinstance(n, list):
            for v in n:
                walk(v)
    walk(doc)
    return out

base, ship = load(base_dir), load(ship_dir)
print("=== Group 1 reversion check ===")
if not base or not ship:
    print("  base %d dump(s), shipped %d dump(s)" % (len(base), len(ship)))
    print("  FAIL one side has no dumps. This check did not run.")
    sys.exit(2)

problems, compared = [], 0
for key, bdoc in sorted(base.items()):
    short = key.split("_Content_")[-1]
    sdoc = ship.get(key)
    if sdoc is None:
        problems.append("%s: the shipped pak does not contain this asset at all" % short)
        continue
    compared += 1
    brows = rows(bdoc)
    if brows is not None:
        srows = rows(sdoc) or set()
        bpaths, spaths = softpaths(bdoc), softpaths(sdoc)
        for r in sorted(brows - srows):
            problems.append("%s: row in the LIVE base, dropped here -> %s" % (short, r))
        for p in sorted(bpaths - spaths):
            problems.append("%s: soft path in the LIVE base, dropped here -> %s" % (short, p))
        print("  %-46s rows %3d -> %3d   soft paths %3d -> %3d"
              % (short, len(brows), len(srows), len(bpaths), len(spaths)))
    else:
        bsc, ssc = skinchoices(bdoc), skinchoices(sdoc)
        for p in sorted(bsc - ssc):
            problems.append("%s: SkinChoices entry in the LIVE base, dropped here -> %s" % (short, p))
        print("  %-46s SkinChoices %3d -> %3d  (+%d CMSF slot(s))"
              % (short, len(bsc), len(ssc), sum(1 for x in ssc if "/CMSF/" in x)))

print("  compared %d owned asset(s)" % compared)
if compared == 0:
    print("  FAIL no owned asset was compared. This check did not run.")
    sys.exit(2)
if not problems:
    print("  OK   0 rows, soft paths or roster entries dropped -")
    print("       %s reverts nothing the live build ships" % label)
    sys.exit(0)
print("  FAIL %d item(s) the LIVE base has and this override drops:" % len(problems))
for p in problems[:25]:
    print("    -> " + p)
if len(problems) > 25:
    print("    ... and %d more" % (len(problems) - 25))
print("")
print("  This is a stale whole-asset override. Installed, it DELETES the content above for")
print("  every user, in-game, with no log line anywhere.")
print("  Rebuild: python tools/cmsf_framework.py --slots 32")
sys.exit(1)
PY
  rc=$?
  [ $rc -eq 1 ] && FAIL=1
  [ $rc -eq 2 ] && NORUN=1
done

# ---------------------------------------------------------------------------------------------
# Cook drift. The one check here that reads NO type map, and the one that caught what checks
# [1]-[4] structurally cannot see.
#
# WHY IT EXISTS. Checks [3]/[4] compare rows, soft paths and SkinChoices entries. Those catch a
# dev-ADDED row and a repointed path -- the loud failures. They are blind to a dev-side edit that
# changes a VALUE in place: identical row keys, identical paths, identical array lengths, so the
# reversion check prints "OK 0 dropped" while the shipped override is quietly serving a months-old
# copy of the asset. Measured on build 25071553: every BP_Player_*.uasset header was
# byte-identical to the pak's July copy and every .uexp was the same LENGTH, with 3-7 scalar bytes
# changed. Checks [3] and [4] both passed clean on that. See docs/10-patch-25071553.md.
#
# HOW. `retoc to-legacy` is passed no usmap at all, so this comparison is immune to the type-map
# staleness that gates everything else after a patch -- which is exactly when you most want it.
# It compares the LIVE cook against build/framework/src, the pristine extraction the pak was
# built from, so what it measures is "has the cook moved since this pak was generated".
#
# WHY DRIFT IS NOT A FAILURE. A drifted cook means a rebuild is owed, not that the pak is broken;
# on 25071553 the drift was a few tuning scalars. It is reported, it is carried into the RESULT
# line so it cannot be read as a clean bill of health, and it does not set the exit code.
#
# WHY IT IS OPPORTUNISTIC. It needs retoc and the game's AES key, neither of which this repo
# ships and neither of which the other four checks require. Missing either is a SKIP with the
# reason named -- never a silent pass, and never a hard failure for someone who only wanted
# checks [1]-[4].
echo
echo "[5/5] cook drift since the pak was built (usmap-free byte comparison)"

SRCTREE="$REPO/build/framework/src/ForeverWinter"
RETOC_BIN="${RETOC:-}"
if [ -z "$RETOC_BIN" ]; then
  for cand in "$REPO/tools/retoc/retoc.exe" "$REPO/dist/release"/CMSF-author-*/retoc.exe; do
    [ -f "$cand" ] && { RETOC_BIN="$cand"; break; }
  done
fi
[ -z "$RETOC_BIN" ] && command -v retoc >/dev/null 2>&1 && RETOC_BIN="$(command -v retoc)"

if [ ! -d "$SRCTREE" ]; then
  echo "      SKIP no build/framework/src on this machine -- nothing to compare the live cook"
  echo "           against. It appears once tools/cmsf_framework.py has been run here."
  DRIFT=2
elif [ -z "$RETOC_BIN" ]; then
  echo "      SKIP retoc not found (tried \$RETOC, tools/retoc/, dist/release/CMSF-author-*/, PATH)."
  DRIFT=2
elif [ -z "${FW_AES_KEY:-}" ]; then
  echo "      SKIP FW_AES_KEY is not set. It is the game's own pak key, so this repo does not"
  echo "           ship it; retoc cannot open the containers without it."
  DRIFT=2
else
  LIVELEG="$WORK/live-legacy"
  rm -rf "$LIVELEG"; mkdir -p "$LIVELEG"
  AESARG="${FW_AES_KEY}"
  case "$AESARG" in 0x*|0X*) ;; *) AESARG="0x$AESARG" ;; esac
  # retoc's -f takes ONE filter, not a comma-separated list: passing "$OWNED" whole matches
  # nothing and still exits 0 -- which is how this check first reported 14 phantom drifts and
  # then "compared 0 files". tools/cmsf_framework.py:127 loops one -f per filter; do the same.
  : >"$WORK/drift.log"
  RETOC_OK=1
  ( IFS=,; for filt in $OWNED; do
      "$RETOC_BIN" -a "$AESARG" to-legacy --version UE5_4 -f "$filt" "$GAME_PAKS" "$LIVELEG" >>"$WORK/drift.log" 2>&1 || exit 1
    done ) || RETOC_OK=0
  if [ "$RETOC_OK" -eq 0 ]; then
    echo "      SKIP retoc could not extract the owned assets from the live cook:"
    tail -5 "$WORK/drift.log" | sed 's/^/           /'
    DRIFT=2
  else
    NCMP=0; NDRIFT=0
    while IFS= read -r rel; do
      a="$SRCTREE/$rel"; b="$LIVELEG/ForeverWinter/$rel"
      [ -f "$a" ] || continue
      if [ ! -f "$b" ]; then
        echo "      DRIFT $(basename "$rel") -- present in the build tree, ABSENT from the live cook"
        NDRIFT=$((NDRIFT + 1)); continue
      fi
      NCMP=$((NCMP + 1))
      if ! cmp -s "$a" "$b"; then
        n=$(cmp -l "$a" "$b" 2>/dev/null | wc -l)
        sa=$(stat -c%s "$a"); sb=$(stat -c%s "$b")
        note="same length"
        [ "$sa" != "$sb" ] && note="$sa -> $sb bytes"
        echo "      DRIFT $(basename "$rel")  $n byte(s) differ ($note)"
        NDRIFT=$((NDRIFT + 1))
      fi
    done <<'RELS'
Content/FW/Player/Class/BP_Player_BagMan.uasset
Content/FW/Player/Class/BP_Player_BagMan.uexp
Content/FW/Player/Class/BP_Player_Girl.uasset
Content/FW/Player/Class/BP_Player_Girl.uexp
Content/FW/Player/Class/BP_Player_Gunhead.uasset
Content/FW/Player/Class/BP_Player_Gunhead.uexp
Content/FW/Player/Class/BP_Player_MaskMan.uasset
Content/FW/Player/Class/BP_Player_MaskMan.uexp
Content/FW/Player/Class/BP_Player_OldMan.uasset
Content/FW/Player/Class/BP_Player_OldMan.uexp
Content/FW/Player/Class/BP_Player_Shaman.uasset
Content/FW/Player/Class/BP_Player_Shaman.uexp
Content/FW/Player/Data/DT_SkinUIData.uasset
Content/FW/Player/Data/DT_SkinUIData.uexp
RELS

    # ---------------------------------------------------------------------------------------
    # Script-object exposure. The byte comparison above says the cook MOVED; this says whether
    # the movement can actually break a pak, which is a different and much narrower question.
    #
    # A zen container's script imports are hashes of object PATH NAMES resolved through the
    # global ScriptObjects chunk, so appending symbols is harmless and a pak breaks only if it
    # imports a name that was REMOVED or RENAMED. Measured on 25071553: the store grew 5,258
    # bytes, 78 names were added and exactly TWO were removed. Reporting the size delta would
    # have condemned every pre-patch pak in the collection; reporting removals condemns almost
    # none. See tools/scriptobjects_diff.py for the full reasoning and the format.
    #
    # retoc drops scriptobjects.bin at the root of a to-legacy output, so both sides are already
    # on disk here for free -- the build tree's copy is a fingerprint of the cook the pak was
    # packed against.
    SO_SRC="$REPO/build/framework/src/scriptobjects.bin"
    SO_LIVE="$LIVELEG/scriptobjects.bin"
    if [ -f "$SO_SRC" ] && [ -f "$SO_LIVE" ]; then
      echo "      --- script-object exposure ---"
      "$PY" "$REPO/tools/scriptobjects_diff.py" "$SO_SRC" "$SO_LIVE"             --refs "$REPO/build/framework/stage" 2>&1 | sed 's/^/  /'
      so_rc=${PIPESTATUS[0]}
      # exit 1 is real exposure: a shipped asset imports a symbol the live build no longer has.
      # exit 2 means the format changed and the check could not run -- never a pass.
      [ "$so_rc" -eq 1 ] && FAIL=1
      [ "$so_rc" -eq 2 ] && NORUN=1
    else
      echo "      --- script-object exposure: SKIP (no scriptobjects.bin on one side) ---"
    fi

    rm -rf "$LIVELEG"
    if [ "$NCMP" -eq 0 ]; then
      echo "      SKIP compared 0 files -- the build tree holds none of the expected assets."
      DRIFT=2
    elif [ "$NDRIFT" -eq 0 ]; then
      echo "      OK   $NCMP file(s) byte-identical to the live cook -- the pak was built on THIS cook"
    else
      echo "      $NDRIFT of $NCMP file(s) have drifted. The pak was built on an older cook, so it"
      echo "      serves stale bytes for the values above. Not a break; a rebuild is owed:"
      echo "         python tools/cmsf_framework.py --slots 32"
      DRIFT=1
    fi
  fi
fi

echo
if [ "$NORUN" -ne 0 ]; then
  echo "RESULT: THE CHECK DID NOT RUN for at least one pak (see above). This is not a pass."
  exit 2
fi
if [ "$FAIL" -ne 0 ]; then
  echo "RESULT: FAILURES ABOVE"
  exit 1
fi
if [ "$DRIFT" -eq 1 ]; then
  echo "RESULT: no breakage - 0 dangling soft references, 0 base rows or soft paths dropped,"
  echo "        CMSF namespace vacant - BUT THE COOK HAS DRIFTED (check 5). A rebuild is owed"
  echo "        before this ships: python tools/cmsf_framework.py --slots 32"
  exit 0
fi
if [ "$DRIFT" -eq 2 ]; then
  echo "RESULT: clean on checks 1-4 - 0 dangling soft references, 0 base rows or soft paths"
  echo "        dropped, CMSF namespace vacant. CHECK 5 DID NOT RUN (reason above), so this"
  echo "        says nothing about whether the pak was built on the current cook."
  exit 0
fi
echo "RESULT: clean - 0 dangling soft references, 0 base rows or soft paths dropped,"
echo "        CMSF namespace vacant, and the pak was built on the live cook"
