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

// Rewrite the package identity. A clone keeps the template's package name in its name map,
// so its FPackageId collides with the game's table and the loader serves OURS in place of
// ST_FW_UI_Skins — replacing 42 entries with 2 and rendering every vanilla skin as
// <MISSING STRING TABLE ENTRY>, while our own TableId points at a package that was never
// really published. Observed in-game 2026-07-21; this is the README's FolderName/FPackageId
// collision, built by accident.
string outDir = Path.GetDirectoryName(Path.GetFullPath(outPath)).Replace('\\', '/');
int contentIdx = outDir.LastIndexOf("/Content/", StringComparison.OrdinalIgnoreCase);
if (contentIdx < 0)
{
    Console.Error.WriteLine($"cannot derive a /Game/ package path from {outPath} — expected a .../Content/... staging path");
    return 1;
}
string newPkg = "/Game/" + outDir.Substring(contentIdx + "/Content/".Length) + "/" + exportName;
string tplPkg = null;

var nameMap = asset.GetNameMapIndexList();
for (int i = 0; i < nameMap.Count; i++)
{
    string v = nameMap[i].Value;
    // The template's own package path — the entry that carries its identity.
    if (v.StartsWith("/Game/", StringComparison.Ordinal) && v.EndsWith("/" + tplStem, StringComparison.Ordinal))
    {
        tplPkg = v;
        asset.SetNameReference(i, FString.FromString(newPkg));
    }
}
if (tplPkg == null)
{
    Console.Error.WriteLine($"no /Game/ package-name entry ending in '{tplStem}' found — refusing to ship a clone that would collide with the template");
    return 1;
}
Console.WriteLine($"package: {tplPkg} -> {newPkg}");

// FolderName is a separate summary field, not a name-map entry, and carries the package
// path independently.
if (asset.FolderName != null && asset.FolderName.Value == tplPkg)
{
    asset.FolderName = FString.FromString(newPkg);
    Console.WriteLine($"  FolderName -> {newPkg}");
}
else if (asset.FolderName != null)
{
    Console.WriteLine($"  FolderName is '{asset.FolderName.Value}' (left alone)");
}
foreach (var n in asset.GetNameMapIndexList())
    if (n.Value.Contains(tplStem, StringComparison.Ordinal))
        Console.WriteLine($"  residual name-map entry: '{n.Value}'");

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

Console.WriteLine($"  TableId:   {newPkg}.{exportName}");

// The collision is silent and catastrophic, so prove the identity actually changed rather
// than trusting the write.
string blob = System.Text.Encoding.ASCII.GetString(File.ReadAllBytes(outPath));
if (blob.Contains(tplPkg, StringComparison.Ordinal))
{
    Console.Error.WriteLine($"!! written asset still carries '{tplPkg}' — it would override the game's table");
    return 1;
}
if (!blob.Contains(newPkg, StringComparison.Ordinal))
{
    Console.Error.WriteLine($"!! written asset does not carry '{newPkg}' — TableId would not resolve");
    return 1;
}
Console.WriteLine($"  identity:  clean (no '{tplPkg}', carries '{newPkg}')");
Console.WriteLine(ok ? "OK" : "MISMATCH after reload");
return ok ? 0 : 1;
