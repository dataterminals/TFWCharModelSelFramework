// The two package generators, absorbed from tools/mshgen and tools/stgen.
//
// Both were standalone exes because cmsf_author.py had to shell out to reach them. Inside a
// single tool they are just functions, which is why the shipped author bundle is
// cmsf-author.exe + retoc.exe rather than four executables.
//
// The originals stay in the repo: tools/cmsf_framework.py still drives them, and the
// framework generator is run by the maintainer from a clone, so it has no reason to move.
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

static class Clone
{
    /// <summary>
    /// Clone any cooked package to a slot path under a new identity — was tools/mshgen.
    /// Package-generic despite the old name: it needs only an export matching the file stem,
    /// so a SkeletalMesh and a Texture2D clone identically.
    /// </summary>
    public static void Package(string inPath, Usmap mappings, string outPath, string newName)
    {
        string tplStem = Path.GetFileNameWithoutExtension(inPath);
        var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, mappings);
        int importsBefore = asset.Imports.Count;

        var id = Identity.Rewrite(asset, tplStem, newName, outPath);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
        asset.Write(outPath);

        Identity.VerifyWritten(outPath, mappings, id, newName);

        // The imports are what make a mesh actually render; losing them produces a package
        // that loads and shows nothing.
        var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
        if (back.Imports.Count != importsBefore)
            throw new BuildError(
                $"{Path.GetFileName(outPath)}: import table changed ({importsBefore} -> {back.Imports.Count})");
    }

    /// <summary>
    /// Generate a CMSF string table by cloning the game's own ST_FW_UI_Skins — was
    /// tools/stgen. Cloning rather than synthesising, because unversioned (usmap-driven)
    /// serialisation depends on ancestry and flags a from-scratch package would have to
    /// reproduce exactly.
    /// </summary>
    public static void StringTable(string tplPath, Usmap mappings, string outPath,
                                   string ns, string exportName,
                                   IEnumerable<(string Key, string Value)> entries)
    {
        var list = entries.ToList();
        var asset = new UAsset(tplPath, EngineVersion.VER_UE5_4, mappings);

        var st = asset.Exports.OfType<StringTableExport>().FirstOrDefault();
        if (st == null) throw new BuildError($"{Path.GetFileName(tplPath)} has no StringTableExport");

        st.Table.Clear();
        st.Table.TableNamespace = new FString(ns);
        foreach (var (k, v) in list) st.Table.Add(new FString(k), new FString(v));

        // The export rename is not optional. A TableId is /Package/Path.ObjectName, so a
        // clone keeping the template's export name would have to be referenced as
        // ".../ST_CMSF_Girl_00.ST_FW_UI_Skins" — which works, and which nobody will remember.
        var id = Identity.Rewrite(asset, Path.GetFileNameWithoutExtension(tplPath), exportName, outPath);

        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
        asset.Write(outPath);

        Identity.VerifyWritten(outPath, mappings, id, exportName);

        var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
        var st2 = back.Exports.OfType<StringTableExport>().FirstOrDefault();
        if (st2 == null) throw new BuildError("reload lost the StringTableExport");
        if (st2.Table.TableNamespace.ToString() != ns)
            throw new BuildError($"namespace did not survive the write: got '{st2.Table.TableNamespace}', wanted '{ns}'");
        if (st2.Table.Count != list.Count)
            throw new BuildError($"entry count did not survive the write: got {st2.Table.Count}, wanted {list.Count}");
    }
}
