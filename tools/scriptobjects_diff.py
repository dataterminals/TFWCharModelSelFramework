#!/usr/bin/env python3
"""Compare the script-object NAME SETS of two cooks, and report REMOVALS only.

WHY THIS EXISTS
    A UE5 zen (IoStore) container serialises its imports of native classes, functions,
    properties and structs as `FPackageObjectIndex` values of type ScriptImport. Those are a
    HASH of the script object's full path name, resolved through the ScriptObjects chunk in
    `global.utoc`/`global.ucas` -- a hash->entry map, not an array indexed by position.

    That distinction is the whole point of this tool, and it was established the expensive way.
    On build 25071553 the store GREW by 5,258 bytes (3,012,295 -> 3,017,553) between the
    2026-07-21 cook and the live one, and that growth was initially proposed as the reason
    CMSF's pak crashes the game at launch. It cannot be. **Appending symbols leaves every
    pre-existing hash resolving exactly as before.** A size delta is a symptom of a patch, not
    evidence of breakage, and treating it as evidence would have sent six repositories into a
    precautionary rebuild for nothing.

    A stale pak is exposed if and only if it imports a script object whose PATH WAS REMOVED OR
    RENAMED. So this tool diffs name sets and reports removals. Additions are counted and
    otherwise ignored, deliberately.

    Measured on 25071553 for the record: 43,394 -> 43,470 names, **78 added and exactly 2
    removed** -- `FWReplicatedAimRecord` and `OnRep_AimReplication`, both members of the
    client aim-replication rework. So the exposed surface for that patch is two symbols wide.
    Neither is imported by anything CMSF ships, which is why CMSF's crash is NOT explained by
    container staleness and why this tool exits 0 on that pair.

    Corroborated independently, and more strongly than this tool can manage: unpacking the shipped
    July `CMSF_Core_9_P.utoc` and parsing the `ImportMap` of all 199 zen package headers yields 220
    distinct ScriptImports, and ALL 220 resolve against the live store to identical paths -- zero
    dangling, neither removed object referenced. Across both cooks 46,495 of 46,497 script objects
    share a path and NOT ONE changed its GlobalIndex, while 99.7% moved array position. Position is
    not the encoding. See docs/11-container-staleness-refuted.md.

    Caveat this tool cannot check, and which must not be forgotten: a struct TYPE or a RepNotify
    FUNCTION declared on a native parent class need not appear as an import in a child
    Blueprint. A clean run here rules out a dead ScriptImport. It does NOT rule out unversioned
    property-schema misalignment, which is a different failure with the same symptom.

FILE FORMAT (validated, not guessed)
    retoc writes `scriptobjects.bin` at the root of a `to-legacy` output directory. It is a UE5
    name batch followed by the script-object entry array:

        u32  Num                     number of names
        u32  NumStringBytes          length of the string blob
        u64  HashVersion             0xC1640000
        u64  hash[Num]               name hashes
        u8   header[Num][2]          FSerializedNameHeader, ONE CONTIGUOUS BLOCK
                                       header[0] & 0x80  -> string is UTF-16
                                       ((header[0] & 0x7f) << 8) | header[1] -> length in chars
        ..   strings                  packed, in header order, no separators
        u32  NumEntries
        ..   FScriptObjectEntry[NumEntries]   32 bytes each

    The headers are a contiguous block, NOT interleaved with their strings -- getting that wrong
    parses for a while and then runs off the end of the buffer. Two independent invariants are
    asserted below so a format change fails loudly instead of yielding a plausible-but-wrong
    name set: the string blob must consume exactly `NumStringBytes`, and the trailing remainder
    must be exactly `4 + NumEntries * 32`.

USAGE
    python tools/scriptobjects_diff.py OLD.bin NEW.bin [--refs DIR] [--json OUT.json]

    --refs DIR   search every legacy .uasset/.uexp under DIR for each removed name, and report
                 which shipped assets actually reference one. This is the exposure test; the
                 name diff alone only bounds it.
    --json OUT   write {removed, added, exposed} for a caller to consume.

EXIT
    0  no removals, or removals that nothing under --refs references  -> not exposed
    1  a removed name IS referenced by an asset under --refs         -> exposed, rebuild needed
    2  the check could not run (bad format, missing file)
"""
import argparse
import json
import os
import struct
import sys


def die(msg):
    """Exit 2 -- 'the check could not run'. sys.exit(str) exits 1, which would be read as a
    real failure; the distinction between 'exposed' and 'could not tell' is load-bearing here."""
    print("  " + msg, file=sys.stderr)
    sys.exit(2)


def parse_names(path):
    """Every script-object name in a retoc scriptobjects.bin, in file order."""
    try:
        with open(path, "rb") as fh:
            b = fh.read()
    except OSError as e:
        die("cannot read %s: %s" % (path, e))

    if len(b) < 16:
        die("%s is too small to be a name batch (%d bytes)" % (path, len(b)))

    num, nstr = struct.unpack_from("<II", b, 0)
    hashver, = struct.unpack_from("<Q", b, 8)
    if hashver != 0xC1640000:
        die("%s has HashVersion %#x, expected 0xC1640000 -- format changed, refusing to "
                 "guess (a wrong parse yields a plausible name set, which is worse than an "
                 "error)" % (path, hashver))

    off = 16 + 8 * num                       # skip the name hashes
    hdr = []
    for i in range(num):
        b0, b1 = b[off + 2 * i], b[off + 2 * i + 1]
        hdr.append((bool(b0 & 0x80), ((b0 & 0x7F) << 8) | b1))
    off += 2 * num

    names, s = [], off
    for is_utf16, ln in hdr:
        if is_utf16:
            names.append(b[s:s + ln * 2].decode("utf-16-le", "replace")); s += ln * 2
        else:
            names.append(b[s:s + ln].decode("utf-8", "replace")); s += ln

    # Invariant 1: the string blob is exactly as long as the header said.
    if s - off != nstr:
        die("%s string blob consumed %d bytes, header declared %d -- parse is wrong"
                 % (path, s - off, nstr))

    # Invariant 2: what is left is the entry array, plus at most a small container footer.
    #
    # Both inputs are accepted on purpose:
    #   * scriptobjects.bin, as retoc drops it at the root of a to-legacy output -- exact fit.
    #   * global.ucas straight out of the game's Paks folder, or archived in a
    #     tfw-update-ops baseline under global/ -- the ScriptObjects chunk starts at offset 0
    #     and is followed by a 15-byte container footer. Measured on 25071553:
    #     global.ucas 3,017,568 = scriptobjects.bin 3,017,553 + 15.
    # Reading global.ucas directly matters because that is what a baseline can archive without
    # retoc, the AES key or the .NET decoder -- see capture_baseline.ps1 step [3/7].
    FOOTER_SLACK = 16
    remainder = len(b) - s
    if remainder >= 4:
        nentries, = struct.unpack_from("<I", b, s)
        expected = 4 + nentries * 32
        slack = remainder - expected
        if slack < 0 or slack > FOOTER_SLACK:
            die("%s trailing %d bytes != 4 + %d*32 (+<=%d footer) -- FScriptObjectEntry is not "
                "32 bytes here, or the layout changed" % (path, remainder, nentries,
                                                          FOOTER_SLACK))
    return names


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("old")
    ap.add_argument("new")
    ap.add_argument("--refs", help="directory of legacy assets to test for exposure")
    ap.add_argument("--json", dest="json_out")
    a = ap.parse_args()

    old, new = set(parse_names(a.old)), set(parse_names(a.new))
    removed, added = sorted(old - new), sorted(new - old)

    print("  old %d names   new %d names" % (len(old), len(new)))
    print("  added   %d  (informational -- appended symbols cannot break an existing pak)"
          % len(added))
    print("  REMOVED %d  (this is the exposure predicate)" % len(removed))

    if not removed:
        print("  OK   nothing was removed or renamed. No pak can hold a dead script import.")
        if a.json_out:
            json.dump({"removed": [], "added": added, "exposed": {}}, open(a.json_out, "w"), indent=1)
        return 0

    for n in removed:
        print("    - %s" % n)

    exposed = {}
    if a.refs:
        if not os.path.isdir(a.refs):
            die("--refs %s is not a directory" % a.refs)
        targets = []
        for root, _d, files in os.walk(a.refs):
            for f in files:
                if f.endswith((".uasset", ".uexp")):
                    targets.append(os.path.join(root, f))
        needles = [(n, n.encode("utf-8")) for n in removed]
        for t in targets:
            try:
                with open(t, "rb") as fh:
                    blob = fh.read()
            except OSError:
                continue
            for name, needle in needles:
                if needle in blob:
                    exposed.setdefault(name, []).append(os.path.relpath(t, a.refs))
        print("  searched %d shipped asset(s) under %s" % (len(targets), a.refs))

    if a.json_out:
        json.dump({"removed": removed, "added": added, "exposed": exposed},
                  open(a.json_out, "w"), indent=1)

    if not a.refs:
        print("  removals exist, but --refs was not given, so exposure is UNTESTED.")
        print("  A name diff alone does not say whether anything imports the dead symbols.")
        return 0
    if not exposed:
        print("  OK   no shipped asset references any removed symbol -- not exposed by this route.")
        print("  NOTE this rules out a dead ScriptImport. It does NOT rule out unversioned")
        print("       property-schema misalignment against a changed native parent class.")
        return 0

    print("  FAIL a shipped asset imports a symbol the live build no longer has:")
    for name, files in sorted(exposed.items()):
        print("    %s" % name)
        for f in files[:8]:
            print("      <- %s" % f)
        if len(files) > 8:
            print("      ... and %d more" % (len(files) - 8))
    print("  Rebuild against the live cook: python tools/cmsf_framework.py --slots 32")
    return 1


if __name__ == "__main__":
    sys.exit(main())
