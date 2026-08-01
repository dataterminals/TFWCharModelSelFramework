"""Assert every soft-object reference in a decoded pak resolves against the live build.

WHY THIS EXISTS
---------------
Build 24479102 renamed every player weapon DataAsset
(`DA_WPN_RFL01_v2` -> `DA_WPN_PLAYER_RFL01`). Our shipped `WeaponsDetailsData` override still
pinned the old names in every row's `DataAsset` pointer, so once the mod was installed *every
weapon in the game* lost its definition and the gun-customization UI stopped working.

Nothing caught it. `retoc verify` only validates the container. `verify_trees.py` checked row
counts, AllowTags and ChildSkills -- all of which were correct. The break was in a field nobody
was asserting on, and it was reported by a user before it was found here.

A dangling soft-object reference is the *generic* form of that failure, and it is the signature
failure mode of a pak mod after a patch: the mod pins a name, the devs rename the asset, the
override silently points at nothing. This module checks the whole class at once, on any dump, for
any mod -- so it does not need to be re-derived per mod or per field.

    python tools/verify_softrefs.py <dump-dir> <filelist.txt> [--ignore SUBSTR ...] [--allow-empty]

Exit codes: 0 clean · 1 dangling references found · 2 the check did not run.

WHY EXIT 2 EXISTS (added 2026-08-01)
------------------------------------
This script used to print "OK 0 dangling" when it had scanned *nothing at all* -- an empty
dump dir, or a decoder invocation that silently failed, both produced a confident pass. That
happened for real: a stale decoder binary did not recognise the `dumptree` mode, wrote no
dumps, and this script green-lit two paks it had never looked at.

A verifier that passes on an empty input is worse than no verifier, because it launders a
non-result into a result. So an empty scan is now a distinct, loud failure. Pass
`--allow-empty` only for a pak that genuinely holds no object references (a texture-only
mod, say), and pass it deliberately.
"""
import json
import os
import re
import sys

# Reference namespaces that are native/engine-side and never appear in a pak filelist.
_NATIVE_PREFIXES = ("/script/", "/engine/transient", "/temp/")


def load_filelist(path):
    """-> (package-path set, basename set), both lowercased.

    filelist lines look like `ForeverWinter/Content/FW/.../Foo.uasset`; the engine refers to the
    same asset as `/Game/FW/.../Foo`. Normalise to the engine form and also index bare basenames,
    because some references carry only the object name.
    """
    paths, names = set(), set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            p = line.strip()
            if not p.lower().endswith((".uasset", ".umap")):
                continue
            noext = p.rsplit(".", 1)[0]
            paths.add(re.sub(r"^ForeverWinter/Content/", "/Game/", noext, flags=re.I).lower())
            paths.add(noext.lower())
            names.add(os.path.basename(noext).lower())
    return paths, names


def _package_of(ref):
    """Strip an engine reference down to its package path.

    `/Game/A/B/Foo.Foo`        -> `/game/a/b/foo`      (FSoftObjectPath)
    `/Game/A/B/Foo.Foo_C`      -> `/game/a/b/foo`      (generated class)
    `/Game/A/B/Foo.3`          -> `/game/a/b/foo`      (export index suffix)
    """
    if not ref:
        return None
    ref = ref.strip()
    if not ref or ref.lower() in ("none", "null"):
        return None
    ref = ref.split(":", 1)[0]          # drop SubPathString-style suffixes
    slash = ref.rfind("/")
    if slash < 0:
        return None
    head, leaf = ref[:slash], ref[slash + 1:]
    leaf = leaf.split(".", 1)[0]        # `Foo.Foo_C` / `Foo.3` -> `Foo`
    return (head + "/" + leaf).lower()


def _walk(node, out, trail=""):
    """Collect (json-path, reference-string) for every soft/hard object reference in the doc."""
    if isinstance(node, dict):
        for key in ("AssetPathName", "ObjectPath"):
            v = node.get(key)
            if isinstance(v, str) and v.strip():
                out.append((trail or "<root>", v))
        for k, v in node.items():
            _walk(v, out, f"{trail}.{k}" if trail else k)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _walk(v, out, f"{trail}[{i}]")


def check_dump(dump_dir, filelist, ignore=()):
    """-> (scanned_count, checked_count, [(file, json-path, reference)]) that do not resolve.

    `scanned_count` counts JSON documents actually parsed, not files found -- a directory full
    of truncated dumps must not read as a successful scan.
    """
    paths, names = load_filelist(filelist)
    dangling, checked, scanned = [], 0, 0

    files = []
    for root, _dirs, fnames in os.walk(dump_dir):
        files.extend(os.path.join(root, f) for f in fnames if f.endswith(".json"))

    for f in sorted(files):
        try:
            with open(f, encoding="utf-8") as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        scanned += 1
        refs = []
        _walk(doc, refs)
        for where, ref in refs:
            low = ref.lower()
            if any(low.startswith(p) for p in _NATIVE_PREFIXES):
                continue
            if any(ig.lower() in low for ig in ignore):
                continue
            pkg = _package_of(ref)
            if pkg is None:
                continue
            checked += 1
            if pkg in paths:
                continue
            if os.path.basename(pkg) in names:
                continue          # basename match -- asset moved but still present
            dangling.append((os.path.basename(f), where, ref))
    return scanned, checked, dangling


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    dump_dir, filelist = argv[1], argv[2]
    allow_empty = "--allow-empty" in argv[3:]
    ignore = [a for a in argv[3:] if not a.startswith("--")]

    print(f"\n=== soft-object references ===")

    if not os.path.isdir(dump_dir):
        print(f"  FAIL the dump directory does not exist: {dump_dir}")
        print("  The check did not run. Nothing here says the pak is good.")
        return 2

    if not os.path.isfile(filelist):
        print(f"  FAIL the filelist does not exist: {filelist}")
        print("  The check did not run. Nothing here says the pak is good.")
        return 2

    scanned, checked, dangling = check_dump(dump_dir, filelist, ignore)
    print(f"  scanned {scanned} dump(s), checked {checked} reference(s) across {dump_dir}")

    if scanned == 0:
        print("  FAIL no JSON dumps were parsed under that directory.")
        print("  The decoder wrote nothing, or wrote nothing readable. This is NOT a pass --")
        print("  the pak was never examined. Check the decoder invocation and its mode name.")
        return 2

    if checked == 0 and not allow_empty:
        print(f"  FAIL parsed {scanned} dump(s) but found 0 object references in them.")
        print("  For a pak that overrides tables or skill trees this means the dumps are not")
        print("  the ones you meant to check. Re-run with --allow-empty only if this mod")
        print("  genuinely ships no object references (a texture-only pak, for instance).")
        return 2

    if not dangling:
        print("  OK   0 dangling references - every reference resolves in the live build")
        return 0

    print(f"  FAIL {len(dangling)} DANGLING reference(s):")
    for fname, where, ref in dangling[:40]:
        print(f"    {fname}  {where}\n        -> {ref}")
    if len(dangling) > 40:
        print(f"    ... and {len(dangling) - 40} more")
    print("\n  A dangling reference means this pak pins an asset name the live build no longer has.")
    print("  Rebuild against the current base (retoc to-legacy re-pulls corrected pointers).")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
