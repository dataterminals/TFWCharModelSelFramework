// skinpatch — inspect / append rows in DT_SkinUIData (UAssetAPI).
//
//   skinpatch inspect <in.uasset> <usmap>              list rows + field types
//   skinpatch schema  <in.uasset> <usmap> <rowName>    reflection dump of one row's fields
//   skinpatch add     <in.uasset> <usmap> <out.uasset> "<spec>" ...
//
//     spec = RowName|DisplayName|Description|/Game/Icon/Path.Obj|/Game/Mesh/Path.Obj
//
// FSkinDetails' asset refs are SOFT object paths, so appended rows need no import-table
// entries at all — unlike ScavgirlCarryPerks' skillpatch, which must synthesise an import
// chain for hard object references. That is the whole reason appending skins is tractable.
//
// Rows are cloned from an existing inline-FText row (Skin.Girl.MAY) rather than built from
// scratch, so ancestry/flags that unversioned (usmap-driven) serialization depends on are
// carried over verbatim. Field objects are new instances — never shared with the template.
//
// FText keys are derived deterministically from the row name (MD5) so rebuilding the same
// spec produces byte-identical output and real diffs stay visible.
using System.Reflection;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.PropertyTypes.Structs;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

class Program
{
    static string S(FName n) => n?.Value?.Value ?? "<null>";

    static int Main(string[] args)
    {
        if (args.Length < 3)
        {
            Console.WriteLine("usage: skinpatch <inspect|schema> <in.uasset> <usmap> [rowName]");
            return 1;
        }
        var mode = args[0];
        var usmap = new Usmap(args[2]);
        var asset = new UAsset(args[1], EngineVersion.VER_UE5_4, usmap);

        var tables = asset.Exports.OfType<DataTableExport>().ToList();
        if (tables.Count == 0)
        {
            Console.WriteLine("no DataTableExport found; exports were:");
            foreach (var e in asset.Exports) Console.WriteLine($"  {e.GetType().Name}  {S(e.ObjectName)}");
            return 2;
        }

        var dt = tables[0];
        var rows = dt.Table.Data;

        if (mode == "inspect")
        {
            Console.WriteLine($"[{S(dt.ObjectName)}] rows = {rows.Count}");
            foreach (var row in rows)
            {
                Console.WriteLine($"  {S(row.Name)}   structType={S(row.StructType)}  fields={row.Value.Count}");
                foreach (var f in row.Value)
                    Console.WriteLine($"      {S(f.Name),-14} {f.GetType().Name}");
            }
            return 0;
        }

        if (mode == "schema")
        {
            var want = args.Length > 3 ? args[3] : null;
            var row = want == null
                ? rows[0]
                : rows.FirstOrDefault(r => string.Equals(S(r.Name), want, StringComparison.OrdinalIgnoreCase));
            if (row == null) { Console.WriteLine($"row not found: {want}"); return 3; }

            Console.WriteLine($"=== row '{S(row.Name)}'  structType={S(row.StructType)} ===");
            foreach (var f in row.Value)
            {
                Console.WriteLine($"\n--- field {S(f.Name)} : {f.GetType().FullName}");
                foreach (var p in f.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
                {
                    object v;
                    try { v = p.GetValue(f); } catch (Exception ex) { v = "<" + ex.GetType().Name + ">"; }
                    Console.WriteLine($"      .{p.Name,-24} {p.PropertyType.Name,-22} = {Fmt(v)}");
                }
                foreach (var fi in f.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
                {
                    object v;
                    try { v = fi.GetValue(f); } catch (Exception ex) { v = "<" + ex.GetType().Name + ">"; }
                    Console.WriteLine($"      #{fi.Name,-24} {fi.FieldType.Name,-22} = {Fmt(v)}");
                }
            }
            return 0;
        }

        if (mode == "add")
        {
            if (args.Length < 5) { Console.WriteLine("usage: skinpatch add <in> <usmap> <out> \"<spec>\"..."); return 1; }
            var outPath = args[3];
            var specs = args.Skip(4).ToList();

            // Template: an existing row that already uses INLINE FText (Base history), so no
            // string-table plumbing has to be switched off. Its ancestry/flags are reused.
            const string TEMPLATE = "Skin.Girl.MAY";
            var tpl = rows.FirstOrDefault(r => string.Equals(S(r.Name), TEMPLATE, StringComparison.OrdinalIgnoreCase));
            if (tpl == null) { Console.WriteLine($"template row missing: {TEMPLATE}"); return 3; }

            TextPropertyData TplText(string f) => tpl.Value.First(p => S(p.Name) == f) as TextPropertyData;
            SoftObjectPropertyData TplSoft(string f) => tpl.Value.First(p => S(p.Name) == f) as SoftObjectPropertyData;

            TextPropertyData MakeText(string field, string display, string keySeed)
            {
                var t = TplText(field);
                return new TextPropertyData(FName.FromString(asset, field))
                {
                    Ancestry = t.Ancestry,
                    Flags = t.Flags,
                    HistoryType = t.HistoryType,          // Base
                    TransformType = t.TransformType,
                    TableId = null,
                    Namespace = FString.FromString(""),
                    Value = FString.FromString(Key(keySeed)),
                    CultureInvariantString = FString.FromString(display),
                };
            }

            SoftObjectPropertyData MakeSoft(string field, string fullPath)
            {
                int dot = fullPath.LastIndexOf('.');
                if (dot < 0) throw new ArgumentException($"expected /Package/Path.ObjectName, got: {fullPath}");
                string pkg = fullPath.Substring(0, dot), obj = fullPath.Substring(dot + 1);
                var s = TplSoft(field);
                return new SoftObjectPropertyData(FName.FromString(asset, field))
                {
                    Ancestry = s.Ancestry,
                    Value = new FSoftObjectPath(
                        new FTopLevelAssetPath(FName.FromString(asset, pkg), FName.FromString(asset, obj)),
                        FString.FromString("")),
                };
            }

            foreach (var spec in specs)
            {
                var p = spec.Split('|');
                if (p.Length != 5)
                {
                    Console.WriteLine($"bad spec (want RowName|Name|Desc|IconPath|MeshPath): {spec}");
                    return 1;
                }
                string rowName = p[0], display = p[1], desc = p[2], icon = p[3], mesh = p[4];

                if (rows.Any(r => string.Equals(S(r.Name), rowName, StringComparison.OrdinalIgnoreCase)))
                {
                    Console.WriteLine($"ABORT: row already exists: {rowName}");
                    return 4;
                }

                var row = new StructPropertyData(FName.FromString(asset, rowName))
                {
                    Ancestry = tpl.Ancestry,
                    StructType = tpl.StructType,
                    Value = new List<PropertyData>
                    {
                        MakeText("SkinName",    display, rowName + "|name"),
                        MakeText("SkinDetails", desc,    rowName + "|desc"),
                        MakeSoft("SkinIcon",    icon),
                        MakeSoft("Skin",        mesh),
                    },
                };
                rows.Add(row);
                Console.WriteLine($"  + {rowName}");
                Console.WriteLine($"      name  \"{display}\"");
                Console.WriteLine($"      mesh  {mesh}");
                Console.WriteLine($"      icon  {icon}");
            }

            asset.Write(outPath);
            Console.WriteLine($"rows {rows.Count - specs.Count} -> {rows.Count}; wrote {outPath}");
            return 0;
        }

        Console.WriteLine($"unknown mode: {mode}");
        return 1;
    }

    // Deterministic 32-char uppercase hex key, so rebuilds are byte-stable.
    static string Key(string seed)
    {
        var h = System.Security.Cryptography.MD5.HashData(System.Text.Encoding.UTF8.GetBytes(seed));
        return Convert.ToHexString(h);
    }

    static string Fmt(object v)
    {
        if (v == null) return "<null>";
        var s = v.ToString();
        if (s.Length > 120) s = s.Substring(0, 120) + "...";
        return s;
    }
}
