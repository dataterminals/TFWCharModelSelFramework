#!/usr/bin/env bash
# Build the CMSF PoC paks.
#
# Always re-extracts DT_SkinUIData from the LIVE cook — never from a committed snapshot —
# so the output is rebased on whatever build is currently installed. See docs/01-design.md.
#
# Produces two paks:
#   CMSF_PoC_9_P          ScavGirl5 + CMSF.Girl.TEST   (the real experiment)
#   CMSF_PoCFallback_9_P  ScavGirl5 only               (disambiguates a total failure)
#
# The _9_P suffix sets load order: token between the last two underscores is "9", numeric,
# so ChunkVersionNumber = 10 and PakOrder = 100*10 + 3 = 1003. A numeric PREFIX does nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

# Everything game-derived comes from the environment; nothing personal or game-owned is baked
# in. Set RETOC and USMAP to your own copies, FW_PAKS to the game's Content/Paks, and
# FW_AES_KEY to the game's pak AES key — CMSF never ships that key, exactly as it never ships a
# usmap. The Python tools do the same discovery automatically via tools/fwlocate.py.
RETOC="${RETOC:?set RETOC to retoc.exe}"
USMAP="${USMAP:?set USMAP to your ForeverWinter-*.usmap}"
PAKS="${FW_PAKS:?set FW_PAKS to ...\\The Forever Winter\\Windows\\ForeverWinter\\Content\\Paks}"
AES="${FW_AES_KEY:?set FW_AES_KEY to the game pak AES key (CMSF does not ship it)}"

SKINPATCH="tools/skinpatch/bin/Release/net8.0/skinpatch.exe"
REL="ForeverWinter/Content/FW/Player/Data/DT_SkinUIData.uasset"

ICON="/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl.T_Menu_PickCharacter_Portrait_ScavGirl"
MESH="/Game/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.SK_SCV_FL_OCT"

for f in "$RETOC" "$USMAP"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done
[ -d "$PAKS" ] || { echo "missing paks dir: $PAKS" >&2; exit 1; }

echo "==> building skinpatch"
dotnet build tools/skinpatch -c Release -v q --nologo >/dev/null

echo "==> extracting DT_SkinUIData from the live cook"
rm -rf build/extract build/patched build/fallback build/verify build/verifysrc
"$RETOC" -a "$AES" to-legacy --version UE5_4 -f DT_SkinUIData "$PAKS" build/extract
[ -f "build/extract/$REL" ] || { echo "extract produced no table" >&2; exit 1; }

echo "==> patching rows"
cp -r build/extract build/patched
cp -r build/extract build/fallback
"$SKINPATCH" add "build/extract/$REL" "$USMAP" "build/patched/$REL" \
  "ScavGirl5|October|CMSF PoC - sequential row test|$ICON|$MESH" \
  "CMSF.Girl.TEST|October (CMSF)|CMSF PoC - dotted namespace test|$ICON|$MESH"
"$SKINPATCH" add "build/extract/$REL" "$USMAP" "build/fallback/$REL" \
  "ScavGirl5|October|CMSF PoC - sequential row test|$ICON|$MESH"

echo "==> repacking"
rm -rf dist/CMSF-PoC dist/CMSF-PoC-Fallback
mkdir -p dist/CMSF-PoC dist/CMSF-PoC-Fallback
"$RETOC" to-zen --version UE5_4 build/patched  "dist/CMSF-PoC/CMSF_PoC_9_P.utoc"
"$RETOC" to-zen --version UE5_4 build/fallback "dist/CMSF-PoC-Fallback/CMSF_PoCFallback_9_P.utoc"

# Verify by decoding the BUILT pak back out, rather than trusting the write landed.
# Needs the game's global.utoc alongside it — the mod pak has no ScriptObjects chunk.
echo "==> verifying built pak"
mkdir -p build/verifysrc
cp "$PAKS/global.utoc" "$PAKS/global.ucas" build/verifysrc/
cp dist/CMSF-PoC/CMSF_PoC_9_P.* build/verifysrc/
"$RETOC" to-legacy --version UE5_4 build/verifysrc build/verify >/dev/null 2>&1
rows=$("$SKINPATCH" inspect "build/verify/$REL" "$USMAP" | head -1)
echo "    built pak reads back: $rows"
for want in ScavGirl5 CMSF.Girl.TEST; do
  "$SKINPATCH" inspect "build/verify/$REL" "$USMAP" | grep -q "^  $want " \
    || { echo "VERIFY FAILED: $want missing from built pak" >&2; exit 2; }
  echo "    ok: $want"
done

echo
echo "done:"
ls -1 dist/CMSF-PoC/ dist/CMSF-PoC-Fallback/
