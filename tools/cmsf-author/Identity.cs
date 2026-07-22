// The identity rule, in one place.
//
// tools/mshgen and tools/stgen each carried their own copy of this. The copies had drifted
// only cosmetically, but they encode the single most expensive lesson in the repo, so having
// two of them was a liability: a fix to one would silently not reach the other.
//
// Cloning a cooked package must rewrite BOTH the name-map package entry AND FolderName. Miss
// either and the clone still claims to be its template, its FPackageId collides, and the
// loader serves the clone in the template's place. Observed in-game 2026-07-21: a cloned
// string table replaced the game's own ST_FW_UI_Skins and every vanilla skin rendered as
// <MISSING STRING TABLE ENTRY>. See docs/05-v2-distribution.md §"The identity rule".
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

static class Identity
{
    public record Result(string TemplatePackage, string NewPackage);

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

        string outDir = Path.GetDirectoryName(Path.GetFullPath(outPath)).Replace('\\', '/');
        int ci = outDir.LastIndexOf("/Content/", StringComparison.OrdinalIgnoreCase);
        if (ci < 0)
            throw new BuildError($"cannot derive a /Game/ package path from {outPath} — expected a .../Content/... staging path");
        string newPkg = "/Game/" + outDir.Substring(ci + "/Content/".Length) + "/" + newName;

        // Match only the template's OWN package entry. Sibling packages that merely share the
        // stem as a prefix (SK_SCV_FL_OCT_Skeleton next to SK_SCV_FL_OCT) are real imports the
        // mesh still needs, and rewriting them would break the clone.
        string tplPkg = null;
        var nameMap = asset.GetNameMapIndexList();
        for (int i = 0; i < nameMap.Count; i++)
        {
            string v = nameMap[i].Value;
            if (v.StartsWith("/Game/", StringComparison.Ordinal) &&
                v.EndsWith("/" + tplStem, StringComparison.Ordinal))
            {
                tplPkg = v;
                asset.SetNameReference(i, FString.FromString(newPkg));
            }
        }
        if (tplPkg == null)
            throw new BuildError($"no /Game/ package-name entry ending in '{tplStem}' — refusing to ship a clone that would collide with its template");

        // FolderName is a separate summary field, not a name-map entry, and carries the
        // package path independently. This is the half that is easy to forget.
        if (asset.FolderName != null && asset.FolderName.Value == tplPkg)
            asset.FolderName = FString.FromString(newPkg);

        return new Result(tplPkg, newPkg);
    }

    /// <summary>
    /// Reload what was written and prove the identity actually changed. The collision is
    /// silent and catastrophic, so this never trusts the write.
    /// </summary>
    public static void VerifyWritten(string outPath, Usmap mappings, Result r, string newName)
    {
        var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);

        // Compare WHOLE name-map entries, never a byte scan. A substring scan cannot tell a
        // residual identity from a legitimate sibling import.
        var names = back.GetNameMapIndexList().Select(n => n.Value).ToList();
        if (names.Any(v => v == r.TemplatePackage))
            throw new BuildError($"{Path.GetFileName(outPath)} still carries package identity '{r.TemplatePackage}' — it would override the game's own asset");
        if (!names.Any(v => v == r.NewPackage))
            throw new BuildError($"{Path.GetFileName(outPath)} has no package entry '{r.NewPackage}' — the path would not resolve");
        if (!back.Exports.Any(e => e.ObjectName.ToString() == newName))
            throw new BuildError($"{Path.GetFileName(outPath)} has no export named '{newName}' after reload");
    }
}

/// <summary>A build failure with a message already fit for an author to read.</summary>
class BuildError : Exception
{
    public BuildError(string message) : base(message) { }
}
