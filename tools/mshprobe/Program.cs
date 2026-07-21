using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// Probe 2 — can UAssetAPI clone a cooked SkeletalMesh to a CMSF slot path with its
// skeleton/material imports intact?
//
// Unlike probe 1's string table, a mesh carries hard imports (Skeleton, Materials,
// PhysicsAsset). Those are what the "unattended repathing" rejection in
// docs/05-v2-distribution.md says go null when the full game is not mounted. This asks
// whether an in-place rename — the pattern the rest of the toolchain already uses — keeps
// them resolvable.
//
// Usage: mshprobe <in.uasset> <usmap> <out.uasset> <NewObjectName>

if (args.Length < 4)
{
    Console.Error.WriteLine("usage: mshprobe <in.uasset> <usmap> <out.uasset> <NewObjectName>");
    return 2;
}
string inPath = args[0], usmapPath = args[1], outPath = args[2], newName = args[3];

Console.WriteLine("== LOAD ==");
Usmap mappings = new Usmap(usmapPath);
var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, mappings);
Console.WriteLine($"  exports: {asset.Exports.Count}  imports: {asset.Imports.Count}  names: {asset.GetNameMapIndexList().Count}");

Console.WriteLine("\n== EXPORTS ==");
foreach (var e in asset.Exports)
    Console.WriteLine($"  {e.ObjectName}  type={e.GetType().Name}  class={e.GetExportClassType()?.Value?.Value}");

Console.WriteLine("\n== IMPORTS (the thing at risk) ==");
for (int i = 0; i < asset.Imports.Count; i++)
{
    var imp = asset.Imports[i];
    Console.WriteLine($"  [{-(i + 1)}] {imp.ClassName}  {imp.ObjectName}  outer={imp.OuterIndex.Index}");
}

Console.WriteLine("\n== RENAME EXPORT ==");
// The probe-1 gotcha: renaming the FILE does not rename the export object, and a soft path
// is /Package/Path.ObjectName — so the object name is load-bearing.
string oldStem = Path.GetFileNameWithoutExtension(inPath);
int renamed = 0;
foreach (var e in asset.Exports)
{
    if (e.ObjectName.ToString() == oldStem)
    {
        Console.WriteLine($"  {e.ObjectName} -> {newName}");
        e.ObjectName = new FName(asset, newName);
        renamed++;
    }
}
Console.WriteLine($"  renamed {renamed} export(s)");
if (renamed == 0) Console.Error.WriteLine($"  !! no export named '{oldStem}' — soft paths would break");

Console.WriteLine("\n== SAVE ==");
Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(outPath)));
asset.Write(outPath);
foreach (var ext in new[] { ".uexp", ".ubulk" })
{
    string s = Path.ChangeExtension(inPath, ext), d = Path.ChangeExtension(outPath, ext);
    if (File.Exists(d)) Console.WriteLine($"  wrote {Path.GetFileName(d)}  {new FileInfo(d).Length:N0} B");
    else if (File.Exists(s)) Console.WriteLine($"  !! {ext} not emitted by Write() (source has one)");
}
Console.WriteLine($"  wrote {Path.GetFileName(outPath)}  {new FileInfo(outPath).Length:N0} B");

Console.WriteLine("\n== RELOAD (verify round-trip) ==");
var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
Console.WriteLine($"  exports: {back.Exports.Count}  imports: {back.Imports.Count}");
foreach (var e in back.Exports)
    Console.WriteLine($"  export: {e.ObjectName}  class={e.GetExportClassType()?.Value?.Value}");

// Imports must match one-for-one, or the mesh has lost its skeleton or its materials.
bool importsOk = back.Imports.Count == asset.Imports.Count;
for (int i = 0; i < Math.Min(back.Imports.Count, asset.Imports.Count); i++)
{
    string a = $"{asset.Imports[i].ClassName}/{asset.Imports[i].ObjectName}";
    string b = $"{back.Imports[i].ClassName}/{back.Imports[i].ObjectName}";
    if (a != b) { Console.Error.WriteLine($"  !! import [{i}] changed: {a} -> {b}"); importsOk = false; }
}
Console.WriteLine($"  imports preserved: {importsOk}");

bool nameOk = back.Exports.Any(e => e.ObjectName.ToString() == newName);
Console.WriteLine($"  export carries new name: {nameOk}");

Console.WriteLine($"\nPROBE 2 (offline half) RESULT: {(importsOk && nameOk ? "PASS" : "FAIL")}");
return importsOk && nameOk ? 0 : 1;
