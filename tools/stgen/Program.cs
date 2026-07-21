using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// stgen — generate a CMSF string table by cloning the game's own ST_FW_UI_Skins.
//
// This is the v0.2 name channel. A framework row's SkinName/SkinDetails point at
// /Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>, and whoever ships the highest-load-order pak
// containing that package owns the displayed name. The row never changes.
//
// Cloning rather than synthesizing, for the same reason skinpatch clones a template row:
// unversioned (usmap-driven) serialization depends on ancestry and flags that a
// from-scratch package would have to reproduce exactly.
//
// The export rename is NOT optional. A TableId is /Package/Path.ObjectName, so a clone that
// keeps the template's export name has to be referenced as
// "/Game/CMSF/Girl/00/ST_CMSF_Girl_00.ST_FW_UI_Skins" — which works but is a trap nobody
// will remember. This was the finding of probe 1; see docs/05-v2-distribution.md.
//
// Usage: stgen <template.uasset> <usmap> <out.uasset> <namespace> <ExportName> <key=value>...

if (args.Length < 6)
{
    Console.Error.WriteLine("usage: stgen <template.uasset> <usmap> <out.uasset> <namespace> <ExportName> <key=value>...");
    return 2;
}
string tplPath = args[0], usmapPath = args[1], outPath = args[2], ns = args[3], exportName = args[4];
var entries = args.Skip(5).Select(a =>
{
    int i = a.IndexOf('=');
    if (i <= 0) { Console.Error.WriteLine($"bad entry (want key=value): {a}"); Environment.Exit(2); }
    return (Key: a.Substring(0, i), Value: a.Substring(i + 1));
}).ToList();

var mappings = new Usmap(usmapPath);
var asset = new UAsset(tplPath, EngineVersion.VER_UE5_4, mappings);

var st = asset.Exports.OfType<StringTableExport>().FirstOrDefault();
if (st == null) { Console.Error.WriteLine("template has no StringTableExport"); return 1; }

Console.WriteLine($"template: {Path.GetFileName(tplPath)}  namespace='{st.Table?.TableNamespace}'  entries={st.Table?.Count}");

st.Table.Clear();
st.Table.TableNamespace = new FString(ns);
foreach (var (k, v) in entries) st.Table.Add(new FString(k), new FString(v));

// Rename the export, not just the file — see the header note.
string tplStem = Path.GetFileNameWithoutExtension(tplPath);
int renamed = 0;
foreach (var e in asset.Exports)
    if (e.ObjectName.ToString() == tplStem) { e.ObjectName = new FName(asset, exportName); renamed++; }
if (renamed == 0)
{
    Console.Error.WriteLine($"no export named '{tplStem}' to rename — TableId would not resolve");
    return 1;
}

Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
asset.Write(outPath);

// Never trust that the write landed; reload and prove it.
var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
var st2 = back.Exports.OfType<StringTableExport>().FirstOrDefault();
if (st2 == null) { Console.Error.WriteLine("reload lost the StringTableExport"); return 1; }

string gotExport = back.Exports.First(e => e is StringTableExport).ObjectName.ToString();
bool ok = gotExport == exportName
          && st2.Table.TableNamespace.ToString() == ns
          && st2.Table.Count == entries.Count;

Console.WriteLine($"wrote {outPath}");
Console.WriteLine($"  export:    {gotExport}");
Console.WriteLine($"  namespace: {st2.Table.TableNamespace}");
foreach (var kv in st2.Table) Console.WriteLine($"    {kv.Key} = {kv.Value}");

string pkg = "/Game/" + Path.GetDirectoryName(outPath).Replace('\\', '/').Split(new[] { "/Content/" }, StringSplitOptions.None).Last();
Console.WriteLine($"  TableId:   {pkg}/{exportName}.{exportName}");
Console.WriteLine(ok ? "OK" : "MISMATCH after reload");
return ok ? 0 : 1;
