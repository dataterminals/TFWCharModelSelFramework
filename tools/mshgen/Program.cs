using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

// mshgen — clone a cooked package to a CMSF slot path with a NEW package identity.
//
// Named for its first use but package-generic: it only needs an export matching the file
// stem, so it clones SkeletalMesh, MaterialInstance, Texture2D and anything else the same way.
// It is how tools/cmsf_author.py (the Python reference) reaches the clone step.
//
// It LINKS tools/cmsf-author/Identity.cs and Clone.cs rather than carrying its own copy of the
// identity rule, so the Python reference and cmsf-author.exe clone with the same code and
// produce the same package. The copy it used to carry could only ever drift.
//
// tools/mshprobe was the probe-2 harness and answered "do the imports survive a round
// trip". It renames the export but leaves the package identity alone, which is fine for a
// probe and WRONG for anything shipped: the clone keeps claiming to be its template, so its
// FPackageId collides and the loader serves it in the template's place. Probes 3-5 shipped
// exactly that. See docs/05-v2-distribution.md §"The identity rule".
//
// Usage:
//   mshgen <in.uasset> <usmap> <out.uasset> <NewObjectName> [--relink <map.json>]
//       clone; --relink repoints references to other shipped packages ({"old": "new", ...})
//   mshgen --package-path <in.uasset> <usmap>
//       print the /Game/ path the package says it lives at
//   mshgen --imports <in.uasset> <usmap>
//       print the /Game/ packages it imports, one per line
//   mshgen --bake-portrait <image> <template.uasset>
//       write an image over a cooked portrait texture, in place (Portrait.cs)
//   mshgen --portrait-template <Character>
//       print the /Game/ path of that character's portrait template
//   mshgen --skeleton-warning <mesh.uasset> <usmap> <Character>
//       print a warning if the mesh is bound to another skeleton than the character's

try
{
    if (args.Length >= 3 && args[0] == "--package-path")
    {
        var a = new UAsset(args[1], EngineVersion.VER_UE5_4, new Usmap(args[2]));
        Console.WriteLine(Identity.PackagePathOf(a, Path.GetFileNameWithoutExtension(args[1])));
        return 0;
    }
    if (args.Length >= 3 && args[0] == "--imports")
    {
        var a = new UAsset(args[1], EngineVersion.VER_UE5_4, new Usmap(args[2]));
        foreach (var p in Identity.PackageImports(a)) Console.WriteLine(p);
        return 0;
    }
    if (args.Length >= 3 && args[0] == "--bake-portrait")
    {
        Console.WriteLine(Portrait.Bake(args[1], args[2]));
        return 0;
    }
    if (args.Length >= 4 && args[0] == "--skeleton-warning")
    {
        var w = Identity.SkeletonWarning(new UAsset(args[1], EngineVersion.VER_UE5_4, new Usmap(args[2])), args[3]);
        if (w != null) Console.WriteLine(w);
        return 0;
    }
    if (args.Length >= 2 && args[0] == "--portrait-template")
    {
        Console.WriteLine(Portrait.TemplateFor(args[1]));
        return 0;
    }
    if (args.Length < 4)
    {
        Console.Error.WriteLine("usage: mshgen <in.uasset> <usmap> <out.uasset> <NewObjectName> [--relink <map.json>]\n" +
                                "       mshgen --package-path|--imports <in.uasset> <usmap>\n" +
                                "       mshgen --bake-portrait <image> <template.uasset>\n" +
                                "       mshgen --portrait-template <Character>");
        return 2;
    }

    string inPath = args[0], usmapPath = args[1], outPath = args[2], newName = args[3];
    Dictionary<string, string> relink = null;
    if (args.Length >= 6 && args[4] == "--relink")
        relink = System.Text.Json.JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(args[5]));

    var id = Clone.Package(inPath, new Usmap(usmapPath), outPath, newName, relink);
    Console.WriteLine($"package: {id.TemplatePackage} -> {id.NewPackage}");
    Console.WriteLine($"softpath: {id.NewPackage}.{newName}");
    return 0;
}
catch (BuildError e)
{
    Console.Error.WriteLine("!! " + e.Message);
    return 1;
}
