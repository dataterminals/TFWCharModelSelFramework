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

        // Blueprint roster modes operate on a BlueprintGeneratedClass, which has no
        // DataTableExport — so they must run before the DataTable lookup below.
        bool isBpMode = mode == "bpskins" || mode == "bpset" || mode == "bpadd" || mode == "bpexports";

        if (mode == "bpexports")
        {
            foreach (var e in asset.Exports)
            {
                string cls = e.ClassIndex != null && e.ClassIndex.IsImport()
                    ? S(e.ClassIndex.ToImport(asset)?.ObjectName) : "?";
                string props = e is NormalExport ne
                    ? string.Join(", ", ne.Data.Select(p => S(p.Name)))
                    : "(unparsed)";
                Console.WriteLine($"  {e.GetType().Name,-16} {S(e.ObjectName),-52} class={cls}");
                if (e is NormalExport && props.Length > 0) Console.WriteLine($"        [{props}]");
            }
            return 0;
        }

        DataTableExport dt = null;
        List<StructPropertyData> rows = null;
        if (!isBpMode)
        {
            var tables = asset.Exports.OfType<DataTableExport>().ToList();
            if (tables.Count == 0)
            {
                Console.WriteLine("no DataTableExport found; exports were:");
                foreach (var e in asset.Exports) Console.WriteLine($"  {e.GetType().Name}  {S(e.ObjectName)}");
                return 2;
            }
            dt = tables[0];
            rows = dt.Table.Data;
        }

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

        // ---- Blueprint roster modes -------------------------------------------------
        // The real skin roster is FWSkinChangeComponent.SkinChoices on BP_Player_<Char>,
        // not DT_SkinUIData. These modes work on that array. `bpskins` lists it;
        // `bpset` repoints one entry at another mesh, which is the minimal way to prove
        // "roster array drives availability" without needing a TArray append.
        if (mode == "bpskins" || mode == "bpset" || mode == "bpadd")
        {
            var comp = asset.Exports.OfType<NormalExport>()
                .FirstOrDefault(e => e.Data.Any(p => S(p.Name) == "SkinChoices"));
            if (comp == null)
            {
                Console.WriteLine("no export carrying SkinChoices; exports were:");
                foreach (var e in asset.Exports.OfType<NormalExport>())
                    Console.WriteLine($"  {S(e.ObjectName)}  [{string.Join(", ", e.Data.Select(p => S(p.Name)))}]");
                return 2;
            }
            var arr = comp.Data.First(p => S(p.Name) == "SkinChoices") as ArrayPropertyData;
            Console.WriteLine($"[{S(comp.ObjectName)}] SkinChoices = {arr.Value.Length}");
            for (int i = 0; i < arr.Value.Length; i++)
                Console.WriteLine($"  [{i}] {Describe(arr.Value[i])}");

            if (mode == "bpskins") return 0;

            // bpadd <in> <usmap> <out> <"/Package/Path.Object"> ...
            // Appends to SkinChoices. New elements clone the template element's Name and
            // Ancestry, which unversioned (usmap-driven) serialization depends on.
            if (mode == "bpadd")
            {
                if (args.Length < 5) { Console.WriteLine("usage: skinpatch bpadd <in> <usmap> <out> <path>..."); return 1; }
                var outAdd = args[3];
                var paths = args.Skip(4).ToList();

                var tpl0 = arr.Value.OfType<SoftObjectPropertyData>().FirstOrDefault();
                if (tpl0 == null) { Console.WriteLine("ABORT: SkinChoices has no SoftObject element to use as a template"); return 3; }

                var list = arr.Value.ToList();
                int before = list.Count;
                var existing = new HashSet<string>(
                    arr.Value.OfType<SoftObjectPropertyData>().Select(x => x.Value.ToString()),
                    StringComparer.OrdinalIgnoreCase);

                foreach (var addPath in paths)
                {
                    int d = addPath.LastIndexOf('.');
                    if (d < 0) { Console.WriteLine($"ABORT: expected /Package/Path.Object, got: {addPath}"); return 1; }
                    string pk = addPath.Substring(0, d), ob = addPath.Substring(d + 1);

                    var sp = new FSoftObjectPath(
                        new FTopLevelAssetPath(FName.FromString(asset, pk), FName.FromString(asset, ob)),
                        FString.FromString(""));

                    if (existing.Contains(sp.ToString()))
                    {
                        Console.WriteLine($"  = already present, skipping: {addPath}");
                        continue;
                    }
                    list.Add(new SoftObjectPropertyData(tpl0.Name) { Ancestry = tpl0.Ancestry, Value = sp });
                    existing.Add(sp.ToString());
                    Console.WriteLine($"  + {addPath}");
                }

                arr.Value = list.ToArray();
                Console.WriteLine($"SkinChoices {before} -> {arr.Value.Length}");
                asset.Write(outAdd);
                Console.WriteLine($"wrote {outAdd}");
                return 0;
            }

            // bpset <in> <usmap> <out> <index> <"/Package/Path.Object">
            if (args.Length < 6) { Console.WriteLine("usage: skinpatch bpset <in> <usmap> <out> <index> <path>"); return 1; }
            var outPath2 = args[3];
            int idx = int.Parse(args[4]);
            string full = args[5];
            if (idx < 0 || idx >= arr.Value.Length) { Console.WriteLine($"index {idx} out of range"); return 1; }

            int dot2 = full.LastIndexOf('.');
            string pkg2 = full.Substring(0, dot2), obj2 = full.Substring(dot2 + 1);

            var target = arr.Value[idx];
            bool wrote = false;
            if (target is SoftObjectPropertyData sop)
            {
                sop.Value = new FSoftObjectPath(
                    new FTopLevelAssetPath(FName.FromString(asset, pkg2), FName.FromString(asset, obj2)),
                    FString.FromString(""));
                wrote = true;
            }
            else if (target is StructPropertyData sp)
            {
                // FSoftObjectPath serialised as a struct: rewrite its inner soft path.
                var inner = sp.Value.OfType<SoftObjectPropertyData>().FirstOrDefault();
                if (inner != null)
                {
                    inner.Value = new FSoftObjectPath(
                        new FTopLevelAssetPath(FName.FromString(asset, pkg2), FName.FromString(asset, obj2)),
                        FString.FromString(""));
                    wrote = true;
                }
            }
            if (!wrote)
            {
                Console.WriteLine($"ABORT: unhandled element type {target.GetType().Name} — inspect with bpskins first");
                return 3;
            }

            Console.WriteLine($"  set [{idx}] -> {full}");
            asset.Write(outPath2);
            Console.WriteLine($"wrote {outPath2}");
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

    // Render an array element readably regardless of how the soft path is serialised.
    static string Describe(PropertyData p)
    {
        if (p is SoftObjectPropertyData s) return $"SoftObject  {s.Value}";
        if (p is ObjectPropertyData o) return $"Object      {o.Value?.Index}";
        if (p is StructPropertyData st)
        {
            var inner = st.Value.OfType<SoftObjectPropertyData>().FirstOrDefault();
            if (inner != null) return $"Struct<{S(st.StructType)}>  {inner.Value}";
            return $"Struct<{S(st.StructType)}>  [{string.Join(", ", st.Value.Select(x => S(x.Name) + ":" + x.GetType().Name))}]";
        }
        return p.GetType().Name;
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
