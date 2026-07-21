using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// mshgen — clone a cooked mesh to a CMSF slot path with a NEW package identity.
//
// tools/mshprobe was the probe-2 harness and answered "do the imports survive a round
// trip". It renames the export but leaves the package identity alone, which is fine for a
// probe and WRONG for anything shipped: the clone keeps claiming to be its template, so its
// FPackageId collides and the loader serves it in the template's place. Probes 3-5 shipped
// exactly that — a "placeholder" that was really an override of the game's SK_SCV_FL, and a
// slot path that never resolved to anything at all. The tile still rendered, because the
// selector string-matches the roster rather than loading the mesh.
//
// See docs/05-v2-distribution.md §"The identity rule". Two fields carry the identity and
// both must be rewritten; the name map alone is not enough.
//
// Usage: mshgen <in.uasset> <usmap> <out.uasset> <NewObjectName>

if (args.Length < 4)
{
    Console.Error.WriteLine("usage: mshgen <in.uasset> <usmap> <out.uasset> <NewObjectName>");
    return 2;
}
string inPath = args[0], usmapPath = args[1], outPath = args[2], newName = args[3];
string tplStem = Path.GetFileNameWithoutExtension(inPath);

var mappings = new Usmap(usmapPath);
var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, mappings);
Console.WriteLine($"template: {tplStem}  exports={asset.Exports.Count}  imports={asset.Imports.Count}");

// --- rename the export ------------------------------------------------------------------
// A roster entry is a soft path /Package/Path.ObjectName, so the object name is load-bearing.
int renamed = 0;
foreach (var e in asset.Exports)
    if (e.ObjectName.ToString() == tplStem) { e.ObjectName = new FName(asset, newName); renamed++; }
if (renamed == 0)
{
    Console.Error.WriteLine($"no export named '{tplStem}' — the soft path would not resolve");
    return 1;
}

// --- rewrite the package identity -------------------------------------------------------
string outDir = Path.GetDirectoryName(Path.GetFullPath(outPath)).Replace('\\', '/');
int ci = outDir.LastIndexOf("/Content/", StringComparison.OrdinalIgnoreCase);
if (ci < 0)
{
    Console.Error.WriteLine($"cannot derive a /Game/ package path from {outPath} — expected a .../Content/... staging path");
    return 1;
}
string newPkg = "/Game/" + outDir.Substring(ci + "/Content/".Length) + "/" + newName;

// Match only the template's OWN package entry. Sibling packages that merely share the stem
// as a prefix (SK_SCV_FL_Slim_PhysicsAsset next to SK_SCV_FL) must be left alone — they are
// real imports the mesh still needs.
string tplPkg = null;
var nameMap = asset.GetNameMapIndexList();
for (int i = 0; i < nameMap.Count; i++)
{
    string v = nameMap[i].Value;
    if (v.StartsWith("/Game/", StringComparison.Ordinal) && v.EndsWith("/" + tplStem, StringComparison.Ordinal))
    {
        tplPkg = v;
        asset.SetNameReference(i, FString.FromString(newPkg));
    }
}
if (tplPkg == null)
{
    Console.Error.WriteLine($"no /Game/ package-name entry ending in '{tplStem}' — refusing to ship a clone that would collide with its template");
    return 1;
}
Console.WriteLine($"package: {tplPkg} -> {newPkg}");

if (asset.FolderName != null && asset.FolderName.Value == tplPkg)
{
    asset.FolderName = FString.FromString(newPkg);
    Console.WriteLine($"  FolderName -> {newPkg}");
}

Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
asset.Write(outPath);
foreach (var ext in new[] { ".uexp", ".ubulk" })
{
    string d = Path.ChangeExtension(outPath, ext);
    if (File.Exists(d)) Console.WriteLine($"  {Path.GetFileName(d)}  {new FileInfo(d).Length:N0} B");
}

// --- prove it, rather than trusting the write -------------------------------------------
var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
bool nameOk = back.Exports.Any(e => e.ObjectName.ToString() == newName);
bool importsOk = back.Imports.Count == asset.Imports.Count;

// Compare whole name-map entries, not raw bytes. A substring scan cannot tell a residual
// identity from a legitimate sibling import: SK_SCV_FL_OCT's own skeleton lives at
// .../SK_SCV_FL_OCT_Skeleton, which contains the template's package path as a prefix and
// must survive untouched.
var backNames = back.GetNameMapIndexList().Select(n => n.Value).ToList();
if (backNames.Any(v => v == tplPkg))
{
    Console.Error.WriteLine($"!! still carries package identity '{tplPkg}' — this would override the game's own asset");
    return 1;
}
if (!backNames.Any(v => v == newPkg))
{
    Console.Error.WriteLine($"!! no package entry '{newPkg}' — the roster path would not resolve");
    return 1;
}
int siblings = backNames.Count(v => v.StartsWith(tplPkg, StringComparison.Ordinal));
if (siblings > 0)
    Console.WriteLine($"  kept {siblings} sibling import(s) sharing the template's prefix");

Console.WriteLine($"  export:   {newName}  (ok={nameOk})");
Console.WriteLine($"  imports:  {back.Imports.Count}  (preserved={importsOk})");
Console.WriteLine($"  identity: clean");
Console.WriteLine($"  softpath: {newPkg}.{newName}");
return nameOk && importsOk ? 0 : 1;
