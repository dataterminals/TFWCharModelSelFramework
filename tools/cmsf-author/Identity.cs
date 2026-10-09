// The identity rule, in one place.
//
// tools/mshgen and tools/stgen each carried their own copy of this. The copies had drifted
// only cosmetically, but they encode the single most expensive lesson in the repo, so having
// two of them was a liability: a fix to one would silently not reach the other. mshgen now
// links this file instead of carrying a copy.
//
// Cloning a cooked package must rewrite BOTH the name-map package entry AND FolderName. Miss
// either and the clone still claims to be its template, its FPackageId collides, and the
// loader serves the clone in the template's place. Observed in-game 2026-07-21: a cloned
// string table replaced the game's own ST_FW_UI_Skins and every vanilla skin rendered as
// <MISSING STRING TABLE ENTRY>. See docs/05-v2-distribution.md §"The identity rule".
//
// Since authors can ship their own materials and textures (skin.json "assets"), a clone also
// has to REPOINT its references to the other packages shipping beside it — the mesh's import
// of its material, the material's import of its texture. That is the same name-map rewrite
// applied to someone else's path, so it lives here too (Relink).
using System.Text.RegularExpressions;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

static class Identity
{
    public record Result(string TemplatePackage, string NewPackage);

    // Unreal splits a trailing _<digits> off a name and stores it as a number: "Image_0" lives
    // in the name map as "Image", referenced with number 1. Digits with a leading zero are not
    // split ("Foo_01" stays whole) — except "0" itself. So a package path ending in _<digits>
    // may exist in a name map ONLY as its base, and an exact-string search misses it. That is
    // why an author's texture named Image_0 used to be refused as "no package-name entry".
    static readonly Regex Numbered = new(@"^(.*)_(0|[1-9]\d{0,8})$");

    static (string Base, string Suffix)? SplitNumber(string path)
    {
        var m = Numbered.Match(path);
        return m.Success ? (m.Groups[1].Value, m.Groups[2].Value) : null;
    }

    static string Leaf(string path) => path[(path.LastIndexOf('/') + 1)..];

    /// <summary>
    /// Where a package says it lives. FolderName first: it is what to-zen hashes into the
    /// FPackageId, so it IS the identity. The name map is the fallback for packages whose
    /// summary carries no usable FolderName.
    /// </summary>
    public static string PackagePathOf(UAsset asset, string stem)
    {
        var fn = asset.FolderName?.Value;
        if (fn != null && fn.StartsWith("/Game/", StringComparison.Ordinal) &&
            fn.EndsWith("/" + stem, StringComparison.Ordinal))
            return fn;

        // Match only the package's OWN entry. Siblings that merely share the stem as a prefix
        // (SK_SCV_FL_OCT_Skeleton next to SK_SCV_FL_OCT) are real imports and stay untouched.
        foreach (var n in asset.GetNameMapIndexList())
            if (n.Value.StartsWith("/Game/", StringComparison.Ordinal) &&
                n.Value.EndsWith("/" + stem, StringComparison.Ordinal))
                return n.Value;

        throw new BuildError(
            $"'{stem}' names no /Game/ package in its FolderName or name map — cannot tell where it " +
            "claims to live, so a clone could not be given a clean identity");
    }

    /// <summary>
    /// Rename the export matching the template's file stem, then repoint the package identity
    /// at the slot path implied by <paramref name="outPath"/>. Throws <see cref="BuildError"/>
    /// rather than returning a code — every caller treated a non-zero return as fatal anyway.
    /// </summary>
    public static Result Rewrite(UAsset asset, string tplStem, string newName, string outPath)
    {
        // A roster entry is a soft path /Package/Path.ObjectName, so the object name is
        // load-bearing. Renaming the FILE does not rename the export.
        int renamed = 0;
        foreach (var e in asset.Exports)
            if (e.ObjectName.ToString() == tplStem) { e.ObjectName = new FName(asset, newName); renamed++; }
        if (renamed == 0)
            throw new BuildError($"no export named '{tplStem}' — the soft path would not resolve");

        string newPkg = SlotPackagePath(outPath, newName);
        string tplPkg = PackagePathOf(asset, tplStem);

        // FolderName is a separate summary field, not a name-map entry, and carries the
        // package path independently. This is the half that is easy to forget.
        if (asset.FolderName != null && asset.FolderName.Value == tplPkg)
            asset.FolderName = FString.FromString(newPkg);

        RenamePath(asset, tplPkg, newPkg);
        return new Result(tplPkg, newPkg);
    }

    /// <summary>/Game/ path for a staged file: .../Content/A/B/Name.uasset -> /Game/A/B/Name.</summary>
    public static string SlotPackagePath(string outPath, string name)
    {
        string outDir = Path.GetDirectoryName(Path.GetFullPath(outPath)).Replace('\\', '/');
        int ci = outDir.LastIndexOf("/Content/", StringComparison.OrdinalIgnoreCase);
        if (ci < 0)
            throw new BuildError($"cannot derive a /Game/ package path from {outPath} — expected a .../Content/... staging path");
        return "/Game/" + outDir.Substring(ci + "/Content/".Length) + "/" + name;
    }

    /// <summary>
    /// Repoint references to packages that ship alongside this one: every old path in
    /// <paramref name="map"/> is rewritten to its new slot path. Returns how many name-map
    /// entries changed. An entry for the package's own old path is harmless — Rewrite has
    /// already moved it, so there is nothing left to match.
    /// </summary>
    public static int Relink(UAsset asset, IReadOnlyDictionary<string, string> map)
    {
        int n = 0;
        foreach (var (oldPkg, newPkg) in map) n += RenamePath(asset, oldPkg, newPkg);
        return n;
    }

    /// <summary>
    /// Rewrite one package path wherever the name map carries it: the exact string, a soft
    /// object path built on it ("/Pkg.Obj"), or — for a numbered leaf — its split base.
    /// </summary>
    static int RenamePath(UAsset asset, string oldPkg, string newPkg)
    {
        int n = 0;
        var names = asset.GetNameMapIndexList();
        for (int i = 0; i < names.Count; i++)
        {
            string v = names[i].Value;
            if (v == oldPkg) { asset.SetNameReference(i, FString.FromString(newPkg)); n++; }
            else if (v.StartsWith(oldPkg + ".", StringComparison.Ordinal))
            { asset.SetNameReference(i, FString.FromString(newPkg + v[oldPkg.Length..])); n++; }
        }

        if (SplitNumber(oldPkg) is not { } o) return n;
        for (int i = 0; i < names.Count; i++)
        {
            if (names[i].Value != o.Base) continue;
            // The number lives on every FName that points here, not in this string, so the
            // new path must end in the SAME _<digits> or those references come out wrong.
            // Moving a package keeps its leaf; renaming a numbered one cannot be done safely.
            if (SplitNumber(newPkg) is not { } nw || nw.Suffix != o.Suffix)
                throw new BuildError(
                    $"'{Leaf(oldPkg)}' ends in _{o.Suffix}, which Unreal stores as a numbered name. CMSF can " +
                    $"move it but cannot rename it to '{Leaf(newPkg)}'. Rename the asset in Unreal so its " +
                    "name does not end in _<number>, and cook it again.");
            asset.SetNameReference(i, FString.FromString(nw.Base));
            n++;
        }
        return n;
    }

    /// <summary>Full /Game/ paths of every package this one imports.</summary>
    /// <summary>
    /// The package a SkeletalMesh's Skeleton property points at, or null when the package
    /// holds no SkeletalMesh (or its Skeleton isn't an import). Read from the property itself,
    /// not guessed from import names: a mesh also imports physics assets and materials.
    /// </summary>
    public static string SkeletonOf(UAsset asset)
    {
        foreach (var e in asset.Exports.OfType<NormalExport>())
        {
            var cls = e.ClassIndex.IsImport() ? e.ClassIndex.ToImport(asset).ObjectName.ToString() : null;
            if (cls != "SkeletalMesh") continue;
            var prop = e.Data.OfType<ObjectPropertyData>().FirstOrDefault(p => p.Name.ToString() == "Skeleton");
            if (prop == null || !prop.Value.IsImport()) return null;
            var obj = prop.Value.ToImport(asset);
            return obj.OuterIndex.IsImport() ? obj.OuterIndex.ToImport(asset).ObjectName.ToString() : null;
        }
        return null;
    }

    // Each character's skeleton, measured from every mesh in its BP_Player_<Char> roster on
    // build 25071553 (the table in docs/07-authoring-v2.md). Not "everyone but Shaman shares
    // one", as that guide used to say: BagMan is on _MainCharacters too, and Gunhead has his own.
    static readonly Dictionary<string, string> CharacterSkeleton = new(StringComparer.OrdinalIgnoreCase)
    {
        ["BagMan"]  = "/Game/Animations/GenericHumanoid/GenericHumanoid_Skeleton_MainCharacters",
        ["Girl"]    = "/Game/Animations/GenericHumanoid/GenericHumanoid_Skeleton",
        ["Gunhead"] = "/Game/Character/Scavengers/Gunhead/SK_SCV_GHD_V01_Skeleton",
        ["MaskMan"] = "/Game/Animations/GenericHumanoid/GenericHumanoid_Skeleton",
        ["OldMan"]  = "/Game/Animations/GenericHumanoid/GenericHumanoid_Skeleton",
        ["Shaman"]  = "/Game/Animations/GenericHumanoid/GenericHumanoid_Skeleton_MainCharacters",
    };

    /// <summary>
    /// A warning when the mesh is bound to a different skeleton than the character's own, or
    /// null. A warning, not an error: it builds, and it's the author's call. But the wrong one
    /// of the two GenericHumanoid skeletons doesn't T-pose. It animates almost right, with a
    /// stretched neck and a gun pointing off, which is how the first outside author's skin
    /// shipped before anyone measured it.
    /// </summary>
    public static string SkeletonWarning(UAsset mesh, string character)
    {
        if (!CharacterSkeleton.TryGetValue(character, out var want)) return null;
        var got = SkeletonOf(mesh);
        if (got == null || got.Equals(want, StringComparison.OrdinalIgnoreCase)) return null;
        return $"your mesh is bound to {got.Split('/').Last()}, but every {character} skin in the game " +
               $"uses {want.Split('/').Last()}. Expect wrong animation (a T-pose, or a stretched neck and " +
               "a gun pointing off). Re-import the mesh in Unreal against " + want + ".";
    }

    public static List<string> PackageImports(UAsset asset) =>
        asset.Imports
            .Where(i => i.ClassName?.ToString() == "Package")
            .Select(i => i.ObjectName.ToString())
            .Where(p => p.StartsWith("/Game/", StringComparison.Ordinal))
            .Distinct(StringComparer.Ordinal)
            .ToList();

    /// <summary>
    /// Reload what was written and prove the identity actually changed — and, when a relink
    /// map was applied, that nothing still points at an old path. Both failures are silent in
    /// game (a collision, or a material that quietly falls back), so this never trusts the write.
    /// </summary>
    public static void VerifyWritten(string outPath, Usmap mappings, Result r, string newName,
                                     IReadOnlyDictionary<string, string> relinked = null)
    {
        var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
        string file = Path.GetFileName(outPath);

        // Compare WHOLE name-map entries, never a byte scan. A substring scan cannot tell a
        // residual identity from a legitimate sibling import.
        var names = back.GetNameMapIndexList().Select(n => n.Value).ToList();
        if (names.Any(v => v == r.TemplatePackage) || back.FolderName?.Value == r.TemplatePackage)
            throw new BuildError($"{file} still carries package identity '{r.TemplatePackage}' — it would override the game's own asset");
        if (back.FolderName != null && back.FolderName.Value != r.NewPackage)
            throw new BuildError($"{file} has FolderName '{back.FolderName.Value}', not '{r.NewPackage}' — its FPackageId would be wrong");
        // With no FolderName the name map is the only carrier, so the new path must be there.
        if (back.FolderName == null && !names.Any(v => v == r.NewPackage))
            throw new BuildError($"{file} has no package entry '{r.NewPackage}' — the path would not resolve");
        if (!back.Exports.Any(e => e.ObjectName.ToString() == newName))
            throw new BuildError($"{file} has no export named '{newName}' after reload");

        if (relinked == null) return;
        foreach (var imp in PackageImports(back))
            if (relinked.ContainsKey(imp))
                throw new BuildError($"{file} still imports '{imp}' instead of its slot copy '{relinked[imp]}'");
    }
}

/// <summary>A build failure with a message already fit for an author to read.</summary>
class BuildError : Exception
{
    public BuildError(string message) : base(message) { }
}
