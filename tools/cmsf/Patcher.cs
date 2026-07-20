// UAssetAPI edits for the two assets CMSF touches.
//
// A skin needs BOTH halves and neither is visible alone:
//   * availability — its mesh appended to FWSkinChangeComponent.SkinChoices on
//     BP_Player_<Char>. This is the actual roster.
//   * identity — a row in DT_SkinUIData whose Skin points at that same mesh, carrying the
//     name, description and icon.
//
// The selector walks the table and shows a row when its mesh is in the roster, so a mesh
// with no row is unreachable (which is exactly why the game's own cut SK_SCV_FL_OCT never
// appeared) and a row with no roster entry is equally invisible.
//
// Both asset references in a row are SOFT object paths, resolved by string at load — which
// is what makes this tractable at all. An appended row can point at a modder's own package
// without any of the FPackageId / FolderName retargeting that overwrite-style skin mods
// need.
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.PropertyTypes.Structs;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

static class Patcher
{
    static string S(FName n) => n?.Value?.Value ?? "<null>";

    static (string pkg, string obj) SplitPath(string full)
    {
        int d = full.LastIndexOf('.');
        if (d < 0 || !full.StartsWith("/"))
            throw new ArgumentException($"expected /Package/Path.ObjectName, got: {full}");
        return (full.Substring(0, d), full.Substring(d + 1));
    }

    // Deterministic FText key, so rebuilding the same input is byte-stable and a real diff
    // stays visible.
    static string Key(string seed) =>
        Convert.ToHexString(System.Security.Cryptography.MD5.HashData(
            System.Text.Encoding.UTF8.GetBytes(seed)));

    /// <summary>Append meshes to FWSkinChangeComponent.SkinChoices. Returns how many were added.</summary>
    public static int AddToRoster(string inPath, string usmapPath, string outPath, IEnumerable<string> meshes)
    {
        var usmap = new Usmap(usmapPath);
        var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, usmap);

        var comp = asset.Exports.OfType<NormalExport>()
            .FirstOrDefault(e => e.Data.Any(p => S(p.Name) == "SkinChoices"))
            ?? throw new InvalidOperationException(
                $"{Path.GetFileName(inPath)}: no export carrying SkinChoices — the pawn " +
                "Blueprint layout may have changed in a game update");

        var arr = (ArrayPropertyData)comp.Data.First(p => S(p.Name) == "SkinChoices");

        // New elements clone the template's Name and Ancestry: unversioned (usmap-driven)
        // serialization depends on both, and building them from scratch does not round-trip.
        var tpl = arr.Value.OfType<SoftObjectPropertyData>().FirstOrDefault()
            ?? throw new InvalidOperationException("SkinChoices has no element to use as a template");

        var list = arr.Value.ToList();
        var seen = new HashSet<string>(
            arr.Value.OfType<SoftObjectPropertyData>().Select(x => x.Value.ToString()),
            StringComparer.OrdinalIgnoreCase);

        int added = 0;
        foreach (var mesh in meshes)
        {
            var (pkg, obj) = SplitPath(mesh);
            var sp = new FSoftObjectPath(
                new FTopLevelAssetPath(FName.FromString(asset, pkg), FName.FromString(asset, obj)),
                FString.FromString(""));
            if (!seen.Add(sp.ToString())) continue;      // already present — idempotent
            list.Add(new SoftObjectPropertyData(tpl.Name) { Ancestry = tpl.Ancestry, Value = sp });
            added++;
        }

        arr.Value = list.ToArray();
        asset.Write(outPath);
        return added;
    }

    public record Row(string Name, string Display, string Description, string Icon, string Mesh);

    /// <summary>
    /// Append rows to DT_SkinUIData. Returns how many were added; any row whose name already
    /// existed is reported via <paramref name="collided"/> rather than silently dropped —
    /// a silent skip would mean a skin simply never appears, with nothing to explain why.
    /// </summary>
    public static int AddRows(string inPath, string usmapPath, string outPath, IEnumerable<Row> rows,
                              out List<string> collided)
    {
        collided = new List<string>();
        var usmap = new Usmap(usmapPath);
        var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, usmap);

        var dt = asset.Exports.OfType<DataTableExport>().FirstOrDefault()
            ?? throw new InvalidOperationException($"{Path.GetFileName(inPath)}: not a DataTable");
        var data = dt.Table.Data;

        // Template: a row that already uses INLINE FText (Base history) rather than a string
        // table, so no localisation plumbing has to be switched off. Its ancestry and flags
        // are reused verbatim.
        const string TEMPLATE = "Skin.Girl.MAY";
        var tplRow = data.FirstOrDefault(r => string.Equals(S(r.Name), TEMPLATE, StringComparison.OrdinalIgnoreCase))
            ?? throw new InvalidOperationException(
                $"DT_SkinUIData has no '{TEMPLATE}' row to use as a template — a game update " +
                "may have removed it; pick another inline-FText row");

        TextPropertyData TplText(string f) => (TextPropertyData)tplRow.Value.First(p => S(p.Name) == f);
        SoftObjectPropertyData TplSoft(string f) => (SoftObjectPropertyData)tplRow.Value.First(p => S(p.Name) == f);

        TextPropertyData MakeText(string field, string display, string seed)
        {
            var t = TplText(field);
            return new TextPropertyData(FName.FromString(asset, field))
            {
                Ancestry = t.Ancestry,
                Flags = t.Flags,
                HistoryType = t.HistoryType,           // Base
                TransformType = t.TransformType,
                TableId = null,
                Namespace = FString.FromString(""),
                Value = FString.FromString(Key(seed)),
                CultureInvariantString = FString.FromString(display ?? ""),
            };
        }

        SoftObjectPropertyData MakeSoft(string field, string full)
        {
            var (pkg, obj) = SplitPath(full);
            var s = TplSoft(field);
            return new SoftObjectPropertyData(FName.FromString(asset, field))
            {
                Ancestry = s.Ancestry,
                Value = new FSoftObjectPath(
                    new FTopLevelAssetPath(FName.FromString(asset, pkg), FName.FromString(asset, obj)),
                    FString.FromString("")),
            };
        }

        var existing = new HashSet<string>(data.Select(r => S(r.Name)), StringComparer.OrdinalIgnoreCase);
        int added = 0;
        foreach (var r in rows)
        {
            if (!existing.Add(r.Name)) { collided.Add(r.Name); continue; }
            data.Add(new StructPropertyData(FName.FromString(asset, r.Name))
            {
                Ancestry = tplRow.Ancestry,
                StructType = tplRow.StructType,
                Value = new List<PropertyData>
                {
                    MakeText("SkinName",    r.Display,     r.Name + "|name"),
                    MakeText("SkinDetails", r.Description, r.Name + "|desc"),
                    MakeSoft("SkinIcon",    r.Icon),
                    MakeSoft("Skin",        r.Mesh),
                },
            });
            added++;
        }

        asset.Write(outPath);
        return added;
    }

    /// <summary>Row names present in a DataTable — used to verify a built pak.</summary>
    public static HashSet<string> RowNames(string path, string usmapPath)
    {
        var asset = new UAsset(path, EngineVersion.VER_UE5_4, new Usmap(usmapPath));
        var dt = asset.Exports.OfType<DataTableExport>().First();
        return new HashSet<string>(dt.Table.Data.Select(r => S(r.Name)), StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Mesh paths in a pawn Blueprint's SkinChoices — used to verify a built pak.</summary>
    public static HashSet<string> RosterPaths(string path, string usmapPath)
    {
        var asset = new UAsset(path, EngineVersion.VER_UE5_4, new Usmap(usmapPath));
        var comp = asset.Exports.OfType<NormalExport>().First(e => e.Data.Any(p => S(p.Name) == "SkinChoices"));
        var arr = (ArrayPropertyData)comp.Data.First(p => S(p.Name) == "SkinChoices");
        return new HashSet<string>(
            arr.Value.OfType<SoftObjectPropertyData>().Select(x => x.Value.ToString()),
            StringComparer.OrdinalIgnoreCase);
    }
}
