using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// Probe 1 — can UAssetAPI read, modify and re-save a cooked UStringTable?
// Usage: stprobe <in.uasset> <usmap> <out.uasset>

if (args.Length < 3) { Console.Error.WriteLine("usage: stprobe <in.uasset> <usmap> <out.uasset>"); return 2; }
string inPath = args[0], usmapPath = args[1], outPath = args[2];

Console.WriteLine("== LOAD ==");
Usmap mappings = new Usmap(usmapPath);
var asset = new UAsset(inPath, EngineVersion.VER_UE5_4, mappings);
Console.WriteLine($"  exports: {asset.Exports.Count}  imports: {asset.Imports.Count}  names: {asset.GetNameMapIndexList().Count}");

foreach (var e in asset.Exports)
    Console.WriteLine($"  export: {e.ObjectName}  type={e.GetType().Name}  class={e.GetExportClassType()?.Value?.Value}");

var st = asset.Exports.OfType<StringTableExport>().FirstOrDefault();
if (st == null) { Console.Error.WriteLine("!! no StringTableExport — UAssetAPI did not resolve this as a string table"); return 1; }

Console.WriteLine("\n== READ ==");
Console.WriteLine($"  namespace: '{st.Table?.TableNamespace}'");
Console.WriteLine($"  entries: {st.Table?.Count}");
int shown = 0;
foreach (var kv in st.Table)
{
    Console.WriteLine($"    {kv.Key} = {kv.Value}");
    if (++shown >= 6) { Console.WriteLine("    ..."); break; }
}

Console.WriteLine("\n== MODIFY ==");
// Clear and write our own entries, the way an author's generated table would.
st.Table.Clear();
st.Table.TableNamespace = new FString("CMSF.Girl.05");
st.Table.Add(new FString("Name"), new FString("Ash Runner"));
st.Table.Add(new FString("Desc"), new FString("Scav Girl, kitted for the ash flats."));
Console.WriteLine($"  namespace -> '{st.Table.TableNamespace}'  entries -> {st.Table.Count}");

Console.WriteLine("\n== SAVE ==");
asset.Write(outPath);
Console.WriteLine($"  wrote {outPath}");

Console.WriteLine("\n== RELOAD (verify round-trip) ==");
var back = new UAsset(outPath, EngineVersion.VER_UE5_4, mappings);
var st2 = back.Exports.OfType<StringTableExport>().FirstOrDefault();
if (st2 == null) { Console.Error.WriteLine("!! reload lost the StringTableExport"); return 1; }
Console.WriteLine($"  namespace: '{st2.Table?.TableNamespace}'  entries: {st2.Table?.Count}");
foreach (var kv in st2.Table) Console.WriteLine($"    {kv.Key} = {kv.Value}");

Console.WriteLine("\nPROBE 1 RESULT: PASS — read, modified, saved and reloaded a cooked UStringTable.");
return 0;
