#!/usr/bin/env python3
"""Compare a mod pak's zen import/export surface against the live cook's own copies.

WHAT THIS TESTS, AND WHY IT IS NOT THE SCRIPT-OBJECT CHECK
    `scriptobjects_diff.py` answers "does this pak import a NATIVE symbol the game no longer
    has". This answers the other two container questions, which are about PACKAGES rather than
    script objects:

      PROVIDES  For a pak that OVERRIDES a base package, the game gets our export map instead of
                its own. Every other package that imports this one resolves by
                `PublicExportHash`. So our copy must provide a SUPERSET of the hashes the live
                cook's copy provides -- if the September game imports an export our July-cooked
                override does not carry, that is a missing import and fatal in a shipping build.
                This is the INVERSE direction from the usual "our imports are stale" worry and is
                the more dangerous one, because it breaks the base game rather than the mod.

      EXPECTS   Each package carries `ImportedPublicExportHashes` -- the hashes it needs FROM the
                packages it imports. Ours may legitimately be a superset (a mod that adds rows
                imports more), as long as nothing the live copy expected has gone missing from
                ours. The number that matters is therefore `game-only`, NOT set equality.

    Getting that predicate wrong reports a false alarm: CMSF's `DT_SkinUIData` expects 193 hashes
    where the game's copy expects 1, because the framework adds 192 rows pointing at its own
    string tables. Set inequality there is the mod working, not breaking. Only `game-only > 0`
    is a defect.

RESULT ON BUILD 25071553 (recorded so nobody re-derives it)
    All seven CMSF-overridden packages -- the six `BP_Player_*` and `DT_SkinUIData` -- came back
    compatible against the game's own cooked copies:
      * PROVIDES identical for all 7, so the September game can resolve every export it imports
        from our overrides.
      * EXPECTS identical for the six pawns; `DT_SkinUIData` a strict superset (+192, every one
        supplied by CMSF's own pak) with `game-only = 0`.
    That also settles a caveat the July-vs-rebuild comparison could not: since our export hashes
    match the GAME'S cooker exactly, retoc's `to-zen` hashing is game-compatible, and a
    July-vs-rebuild-only test was not merely retoc-vs-retoc.

    Conclusion: container staleness is eliminated for CMSF in all three dimensions -- script
    imports, package imports, and export provision. See docs/11-container-staleness-refuted.md.

ZEN LAYOUT (validated by invariants, not assumed)
    FZenPackageSummary, UE 5.4, 52 bytes, all little-endian:

        0   u32  bHasVersioningInfo          (0 in shipped cooks)
        4   u32  HeaderSize
        8   u32  Name.Index                  (low 30 bits index the package's own name map)
        12  u32  Name.Number
        16  u32  PackageFlags
        20  u32  CookedHeaderSize
        24  i32  ImportedPublicExportHashesOffset
        28  i32  ImportMapOffset
        32  i32  ExportMapOffset
        36  i32  ExportBundleEntriesOffset
        40  i32  DependencyBundleHeadersOffset
        44  i32  DependencyBundleEntriesOffset
        48  i32  ImportedPackageNamesOffset
        52       name batch (same format as scriptobjects.bin -- see scriptobjects_diff.py)

    ImportMap entries are u64 `FPackageObjectIndex`; the top two bits give the type
    (0 Export, 1 ScriptImport, 2 PackageImport, 3 Null). `FExportMapEntry` is 72 bytes with
    `PublicExportHash` at +40.

    Three invariants are asserted before a chunk is accepted, so a layout change fails loudly
    instead of yielding plausible-but-wrong numbers: the seven offsets must be monotonically
    increasing and inside `HeaderSize`, and the import and export regions must divide exactly by
    8 and 72. On the CMSF pak that accepts 199 of 200 chunks -- the reject is the container
    header, which is not a package.

USAGE
    # name every package in a raw-chunk directory (from `retoc unpack-raw`)
    python tools/zen_imports.py name <rawdir>

    # compare two raw-chunk dirs chunk-for-chunk (e.g. shipped pak vs a rebuild)
    python tools/zen_imports.py diff <rawdir-a> <rawdir-b>

    # compare a pak's overrides against the game's own copies of the same chunk ids
    python tools/zen_imports.py vs-base <rawdir> <basedir>

    Getting <basedir>: a package's chunk id is derived from its package path, so an overriding
    pak shares the base game's chunk id for that package. Find the holder with
    `retoc -a $KEY list <utoc>` (it prints chunk IDS, not paths -- grepping it for an asset name
    matches nothing, for any container) and pull single chunks with
    `retoc -a $KEY get <utoc> <chunkid> <out>`, which is far cheaper than unpacking a 2 GB
    container.

EXIT
    0  compatible
    1  a real defect: an override fails to PROVIDE a hash the live cook provides, or a package
       is missing an expectation the live copy had
    2  the check could not run (layout rejected, missing input)
"""
import json
import os
import struct
import sys

SUMMARY_SIZE = 52
IMPORT_TYPE = {0: "Export", 1: "ScriptImport", 2: "PackageImport", 3: "Null"}


def die(msg):
    print("  " + msg, file=sys.stderr)
    sys.exit(2)


def parse_package(path):
    """Parse one raw zen chunk, or return None if it is not a package."""
    try:
        with open(path, "rb") as fh:
            b = fh.read()
    except OSError:
        return None
    if len(b) < SUMMARY_SIZE:
        return None
    f = struct.unpack_from("<13I", b, 0)
    has_ver, hdr = f[0], f[1]
    ipeh, imp, exp, ebe = f[6], f[7], f[8], f[9]
    offs = list(f[6:13])
    if has_ver != 0 or hdr > len(b):
        return None
    if any(o > hdr for o in offs) or offs != sorted(offs):
        return None
    if (imp - ipeh) % 8 or (exp - imp) % 8 or (ebe - exp) % 72:
        return None
    n_exp = (ebe - exp) // 72
    return {
        "name_index": f[2] & 0x3FFFFFFF,
        "header_size": hdr,
        "expects": list(struct.unpack_from("<%dQ" % ((imp - ipeh) // 8), b, ipeh)),
        "imports": list(struct.unpack_from("<%dQ" % ((exp - imp) // 8), b, imp)),
        "provides": [struct.unpack_from("<Q", b, exp + i * 72 + 40)[0] for i in range(n_exp)],
        "n_exports": n_exp,
        "_buf": b,
    }


def package_name(pkg):
    """The package's own path, read out of its name map."""
    b = pkg["_buf"]
    off = SUMMARY_SIZE
    num, _nstr = struct.unpack_from("<II", b, off)
    hashver, = struct.unpack_from("<Q", b, off + 8)
    if hashver != 0xC1640000 or num == 0:
        return None
    p = off + 16 + 8 * num
    hdrs = [((b[p + 2 * i] & 0x80) != 0, ((b[p + 2 * i] & 0x7F) << 8) | b[p + 2 * i + 1])
            for i in range(num)]
    p += 2 * num
    names = []
    for is_u16, ln in hdrs:
        if is_u16:
            names.append(b[p:p + ln * 2].decode("utf-16-le", "replace")); p += ln * 2
        else:
            names.append(b[p:p + ln].decode("utf-8", "replace")); p += ln
    i = pkg["name_index"]
    return names[i] if i < len(names) else None


def load_dir(d):
    chunks = os.path.join(d, "chunks")
    if not os.path.isdir(chunks):
        chunks = d
    if not os.path.isdir(chunks):
        die("not a directory: %s" % d)
    out, rejected = {}, 0
    for f in sorted(os.listdir(chunks)):
        p = os.path.join(chunks, f)
        if not os.path.isfile(p):
            continue
        pkg = parse_package(p)
        if pkg is None:
            rejected += 1
        else:
            out[f] = pkg
    return out, rejected


def cmd_name(d):
    pkgs, rejected = load_dir(d)
    print("  %d package(s), %d non-package chunk(s) rejected" % (len(pkgs), rejected))
    for cid, pkg in sorted(pkgs.items(), key=lambda kv: package_name(kv[1]) or ""):
        print("  %s  %s" % (cid, package_name(pkg)))
    return 0


def cmd_diff(a, b):
    A, ra = load_dir(a)
    B, rb = load_dir(b)
    print("  A %d packages (%d rejected)   B %d packages (%d rejected)" % (len(A), ra, len(B), rb))
    print("  chunk-id sets identical: %s" % (set(A) == set(B)))
    common = sorted(set(A) & set(B))
    diffs = {k: [] for k in ("expects", "imports", "provides")}
    for cid in common:
        for k in diffs:
            if A[cid][k] != B[cid][k]:
                diffs[k].append(cid)
    tot_i = sum(len(A[c]["imports"]) for c in common)
    kinds = {}
    for c in common:
        for v in A[c]["imports"]:
            t = IMPORT_TYPE[(v >> 62) & 3]
            kinds[t] = kinds.get(t, 0) + 1
    print("  %d common packages, %d import entries: %s"
          % (len(common), tot_i, ", ".join("%s %d" % kv for kv in sorted(kinds.items()))))
    for k in ("expects", "imports", "provides"):
        print("  %-9s differ in %d of %d packages" % (k, len(diffs[k]), len(common)))
    if not any(diffs.values()):
        print("  OK   identical import/export surface -- a rebuild changes nothing here.")
    return 0


def cmd_vs_base(moddir, basedir):
    M, _ = load_dir(moddir)
    B, _ = load_dir(basedir)
    shared = sorted(set(M) & set(B))
    if not shared:
        die("no chunk ids in common -- is %s the base extract of the same packages?" % basedir)
    print("  comparing %d overridden package(s) against the live cook\n" % len(shared))
    print("  %-40s %8s  %-14s %-14s" % ("package", "exports", "PROVIDES ok?", "EXPECTS ok?"))
    problems = []
    for cid in shared:
        ours, game = M[cid], B[cid]
        nm = (package_name(ours) or cid).split("/")[-1]
        # PROVIDES: ours must be a SUPERSET of the game's, or the game cannot resolve an import.
        missing_provide = set(game["provides"]) - set(ours["provides"])
        # EXPECTS: ours may add, but must not LOSE an expectation the live copy had.
        missing_expect = set(game["expects"]) - set(ours["expects"])
        extra_expect = set(ours["expects"]) - set(game["expects"])
        pok, eok = not missing_provide, not missing_expect
        note = ""
        if extra_expect:
            note = "  (+%d expected, satisfied by this pak)" % len(extra_expect)
        print("  %-40s %8d  %-14s %-14s%s"
              % (nm, ours["n_exports"], str(pok), str(eok), note))
        if missing_provide:
            problems.append("%s: the live cook provides %d export hash(es) this override does "
                            "NOT -- the game cannot resolve them" % (nm, len(missing_provide)))
        if missing_expect:
            problems.append("%s: the live copy expects %d hash(es) this override dropped"
                            % (nm, len(missing_expect)))
    print()
    if not problems:
        print("  OK   every override provides what the live cook provides, and drops no")
        print("       expectation. Container-compatible with this build.")
        print("  NOTE this covers script imports, package imports and export provision. It says")
        print("       nothing about unversioned property-schema drift, which needs a usmap.")
        return 0
    print("  FAIL real container-level breakage:")
    for p in problems:
        print("    -> " + p)
    return 1


def main():
    if len(sys.argv) < 3:
        die("usage: zen_imports.py {name <dir> | diff <a> <b> | vs-base <mod> <base>}")
    cmd = sys.argv[1]
    if cmd == "name":
        return cmd_name(sys.argv[2])
    if cmd == "diff" and len(sys.argv) >= 4:
        return cmd_diff(sys.argv[2], sys.argv[3])
    if cmd == "vs-base" and len(sys.argv) >= 4:
        return cmd_vs_base(sys.argv[2], sys.argv[3])
    die("unknown command %r" % cmd)


if __name__ == "__main__":
    sys.exit(main())
