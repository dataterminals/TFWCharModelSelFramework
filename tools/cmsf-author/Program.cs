// cmsf-author — turn one skin into one ordinary pak trio.
//
// A C# port of tools/cmsf_author.py, for the reason spelled out in cmsf-author.csproj: Nexus
// accepts .exe and authors should not need Python. The Python remains the reference
// implementation and still works from a clone; the two are expected to produce the same pak.
//
// An author claims a slot by shipping three packages at that slot's frozen paths, at a
// higher load order than the framework:
//
//     /Game/CMSF/<Char>/<NN>/SK_CMSF_<Char>_<NN>     the mesh
//     /Game/CMSF/<Char>/<NN>/T_CMSF_<Char>_<NN>      the portrait
//     /Game/CMSF/<Char>/<NN>/ST_CMSF_<Char>_<NN>     the name and description
//
// plus, optionally, their own cooked materials/textures/etc. ("assets" in skin.json), which
// ship INSIDE the same slot directory — the claimant owns it, so this keeps two skins apart
// exactly as the frozen three do. Every reference between shipped packages is repointed into
// the slot. NEVER DT_SkinUIData, NEVER BP_Player_*, never anything outside the slot directory
// — that is the whole trick, and the verify pass fails the build if it is broken.
//
// THE PORTRAIT IS MANDATORY. CMSFUnlock decides a slot is unclaimed by checking whether its
// icon resolves to the slot's own path, so a claim shipping no portrait is not merely plain —
// it is pruned, invisible, indistinguishable from not being installed. That is the one
// authoring mistake that yields a clean build and a missing skin, so it is a hard error here.
using System.Text.Json;
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

static class Program
{
    static readonly string[] Characters =
        { "BagMan", "Girl", "Gunhead", "MaskMan", "OldMan", "Shaman" };

    // Must match tools/cmsf_framework.py exactly: the framework's row references this
    // namespace and these two keys, and an override only lands if all three agree.
    const string StKeyName = "Name", StKeyDesc = "Desc";

    // The framework ships at _9_P. A claim has to load above it or it never wins.
    // NOTE: under MO2 this token is discarded — ForeverWinterMO2Support renames every pak
    // _<N>_P from left-pane priority. It still decides the outcome for a manual install,
    // which is the baseline (docs: manual install first, MO2 is a compat check).
    const int PakOrder = 11;

    static int Main(string[] rawArgs)
    {
        try { return Run(rawArgs); }
        catch (BuildError e) { Console.Error.WriteLine($"\nERROR: {e.Message}"); return 1; }
        // Launched from Explorer, the window closes the instant this returns and takes the
        // result with it. Pause on success AND failure — failure is when there is most to read.
        finally { Interactive.PauseIfOwned(); }
    }

    static int Run(string[] rawArgs)
    {
        Banner.Write();

        var a = Args.Parse(rawArgs);
        if (a.Help) { Usage(); return 0; }

        // Double-clicked with nothing to go on. Someone who reached this by double-clicking an
        // exe has no terminal to type a command into, so hand them a menu rather than usage
        // text describing commands they cannot run. --menu forces the same thing from a shell,
        // which is also the only way to exercise it without driving a console window.
        if (a.Menu || (a.ListFree == null && a.SkinDir == null && Interactive.OwnsConsole))
            return Menu(a);

        if (a.ListFree != null) { ListFree(a, a.ListFree); return 0; }

        if (a.SkinDir == null)
        {
            Usage();
            throw new BuildError("a skin directory is required (or use --list-free CHAR)");
        }

        Build(a);
        return 0;
    }

    /// <summary>
    /// The double-click experience: drive the whole tool from the window that just opened.
    /// Loops, so one launch can build several skins and check slots in between; a failed
    /// action prints and returns to the menu instead of taking the window down with it.
    /// </summary>
    static int Menu(Args a)
    {
        while (true)
        {
            Console.WriteLine("  What would you like to do?");
            Console.WriteLine();
            Console.WriteLine("    1   Build a skin");
            Console.WriteLine("    2   Show free slots for a character");
            Console.WriteLine("    3   Show help");
            Console.WriteLine("    Q   Quit");
            Console.WriteLine();

            var choice = Interactive.Ask("  > ")?.ToLowerInvariant();
            // Null is end-of-input, not a bad answer. Re-prompting on it loops forever.
            if (choice == null) { Interactive.ExitedCleanly = true; return 0; }
            Console.WriteLine();

            try
            {
                switch (choice)
                {
                    case "1":
                        var dir = Interactive.AskForSkinFolder();
                        if (string.IsNullOrWhiteSpace(dir)) { Console.WriteLine("  Nothing entered."); break; }
                        a.SkinDir = dir;
                        Build(a);
                        break;

                    case "2":
                        var ch = Interactive.Ask($"  Character ({string.Join(", ", Characters)})> ");
                        if (ch == null) { Interactive.ExitedCleanly = true; return 0; }
                        Console.WriteLine();
                        if (!string.IsNullOrWhiteSpace(ch)) ListFree(a, ch);
                        break;

                    case "3":
                        Usage();
                        break;

                    case "q" or "quit" or "exit":
                        Interactive.ExitedCleanly = true;
                        return 0;

                    default:
                        Console.WriteLine("  Enter 1, 2, 3 or Q.");
                        break;
                }
            }
            catch (BuildError e)
            {
                // A bad path or an unclaimable slot is an ordinary mistake at a prompt, not a
                // reason to close the window they are working in.
                Console.Error.WriteLine($"ERROR: {e.Message}");
            }

            Console.WriteLine();
            Banner.Rule();
            Console.WriteLine();
        }
    }

    static void ListFree(Args a, string character)
    {
        var ch = Characters.FirstOrDefault(c => c.Equals(character, StringComparison.OrdinalIgnoreCase))
                 ?? throw new BuildError($"unknown character '{character}'; known: {string.Join(", ", Characters)}");
        var reg = SlotRegistry.Load(a.Registry ?? SlotRegistry.DefaultUrl, Characters, out var regNote);
        if (regNote != null) Console.WriteLine($"    NOTE  {regNote}");

        var free = SlotRegistry.FreeSlots(ch, a.PoolSlots, reg);
        Console.WriteLine($"{ch}: pool 00..{(a.PoolSlots - 1):D2}, public 00..{(SlotRegistry.PrivateFrom - 1):D2}, " +
                          $"private {SlotRegistry.PrivateFrom:D2}..31");
        Console.WriteLine($"  free   {(free.Count > 0 ? string.Join(", ", free) : "(none)")}");
        foreach (var kv in (reg ?? new()).Where(k => k.Key.StartsWith(ch + "/", StringComparison.OrdinalIgnoreCase))
                                         .OrderBy(k => k.Key, StringComparer.Ordinal))
            Console.WriteLine($"  {kv.Key.Split('/')[1]}     {kv.Value.Id}  -  {kv.Value.Skin} by {kv.Value.Author}");
    }

    static void Build(Args a)
    {
        int pool = a.PoolSlots;
        string registrySource = a.Registry ?? SlotRegistry.DefaultUrl;

        // ---- skin.json --------------------------------------------------------------------
        var skinDir = Path.GetFullPath(a.SkinDir);
        var jf = Path.Combine(skinDir, "skin.json");
        if (!File.Exists(jf)) throw new BuildError($"no skin.json in {skinDir}");

        using var doc = JsonDocument.Parse(File.ReadAllText(jf));
        var root = doc.RootElement;
        string Str(string k) => root.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

        var character = Characters.FirstOrDefault(c => c.Equals(Str("character"), StringComparison.OrdinalIgnoreCase))
            ?? throw new BuildError($"character must be one of {string.Join(", ", Characters)} — got '{Str("character")}'");

        var slot = a.Slot ?? Str("slot")
            ?? throw new BuildError("no slot claimed — put \"slot\": \"00\" in skin.json or pass --slot");
        slot = slot.PadLeft(2, '0');
        if (slot.Length != 2 || !slot.All(char.IsDigit))
            throw new BuildError($"slot must be two digits — got '{slot}'");
        if (int.Parse(slot) >= pool)
            throw new BuildError($"slot {slot} is outside the installed pool of {pool} " +
                                 $"(00..{(pool - 1):D2}); nothing would reference it");

        var ident = Str("id") ?? new DirectoryInfo(skinDir).Name;
        var name = Str("name") ?? throw new BuildError("skin.json needs a \"name\"");
        var desc = Str("description") ?? "";
        var meshSrcValue = Str("mesh") ?? throw new BuildError("skin.json needs a \"mesh\"");
        var iconSrcValue = Str("icon") ?? throw new BuildError(
            "skin.json needs an \"icon\". A claim with no portrait is HIDDEN, not just plain: " +
            "CMSFUnlock treats an icon that does not resolve to the slot's own path as proof " +
            "the slot is unclaimed, and prunes the tile.");

        // Optional: the author's own cooked packages the mesh needs — materials, textures, a
        // physics asset. Files or folders, relative to the skin folder.
        var assetValues = new List<string>();
        if (root.TryGetProperty("assets", out var av))
        {
            if (av.ValueKind != JsonValueKind.Array)
                throw new BuildError("\"assets\" must be a list of files or folders, e.g. [\"Materials\", \"Textures\"]");
            foreach (var e in av.EnumerateArray())
                assetValues.Add(e.ValueKind == JsonValueKind.String ? e.GetString()
                    : throw new BuildError("every \"assets\" entry must be a path in quotes"));
        }

        // ---- registry ---------------------------------------------------------------------
        // Taking someone else's slot is an error. Building on an unregistered public slot is
        // only a note, so nobody is blocked waiting on a merge to test locally. The private
        // range is not policed at all.
        var claims = SlotRegistry.Load(registrySource, Characters, out var note);
        if (note != null) Console.WriteLine($"    NOTE  {note}");
        if (claims != null && claims.TryGetValue($"{character}/{slot}", out var held) &&
            !held.Id.Equals(ident, StringComparison.OrdinalIgnoreCase))
        {
            var free = SlotRegistry.FreeSlots(character, pool, claims);
            throw new BuildError(
                $"{character}/{slot} is registered to '{held.Id}' ({held.Skin} by {held.Author}) — " +
                "claiming it would make one of the two skins invisible.\n" +
                $"  free public slots for {character}: {(free.Count > 0 ? string.Join(", ", free) : "(none — the public range is full)")}\n" +
                $"  see docs/slots.md, or use {SlotRegistry.PrivateFrom:D2}..31 for a private skin");
        }
        if (claims != null && !claims.ContainsKey($"{character}/{slot}") &&
            int.Parse(slot) < SlotRegistry.PrivateFrom && !a.Unregistered)
            Console.WriteLine($"    NOTE  {character}/{slot} is not in the registry. Fine for testing; claim it " +
                              $"before publishing, or use {SlotRegistry.PrivateFrom:D2}..31 for a private skin.");

        // ---- locate the toolchain ---------------------------------------------------------
        // The AES key first: it is the game's own decryption key, so a missing one should stop
        // the build before anything spawns, and --list-free never reaches here.
        Tools.Aes = Tools.FindAes(a.Aes);
        Retoc.Exe = Tools.FindRetoc(a.Retoc);
        // Before the usmap, so a missing-usmap error can inspect the author's UE4SS install
        // and say whether the Keybinds mod that owns Ctrl+Numpad6 is actually enabled.
        var paks = Tools.FindPaks(a.Game);
        var usmapPath = Tools.FindUsmap(a.Usmap, paks);

        var meshObj = $"SK_CMSF_{character}_{slot}";
        var texObj = $"T_CMSF_{character}_{slot}";
        var stObj = $"ST_CMSF_{character}_{slot}";
        var slotDir = $"ForeverWinter/Content/CMSF/{character}/{slot}";
        var pak = $"CMSF_{character}{slot}_{ident}_{PakOrder}_P";

        Console.WriteLine($"==> '{name}' claims {character}/{slot}");

        var outDir = Path.GetFullPath(a.Out ?? Path.Combine("dist", ident));
        // The work tree sits beside the output so it lands on the author's own drive, and so
        // the verify mount can hardlink the game's paks when they share a volume.
        var build = Path.Combine(Path.GetDirectoryName(outDir.TrimEnd(Path.DirectorySeparatorChar)) ?? ".",
                                 ".cmsf-build", ident);
        var src = Path.Combine(build, "src");
        var stage = Path.Combine(build, "stage");

        // stage is ours, under .cmsf-build, so wiping it is safe.
        if (Directory.Exists(stage)) Directory.Delete(stage, true);

        // outDir is NOT ours -- it is whatever --out was pointed at. Deleting it recursively
        // turned `--out .` into "erase the folder I am standing in", so only our own previous
        // pak trio is removed and anything else in there is left alone.
        Directory.CreateDirectory(outDir);
        foreach (var stale in Directory.GetFiles(outDir, pak + ".*")) File.Delete(stale);
        Directory.CreateDirectory(src);

        var mappings = new Usmap(usmapPath);

        Console.WriteLine("==> resolving sources");
        var meshSrc = ResolveSource(meshSrcValue, skinDir, src, paks, "mesh");
        string iconSrc, iconNote = null;
        if (Portrait.IsImage(iconSrcValue))
            (iconSrc, iconNote) = BakePortrait(iconSrcValue, skinDir, src, build, paks, character);
        else
            iconSrc = ResolveSource(iconSrcValue, skinDir, src, paks, "icon");
        var extras = ResolveAssets(assetValues, skinDir, new[] { meshObj, texObj, stObj }, meshSrc, iconSrc);
        Console.WriteLine($"      mesh  {Path.GetFileName(meshSrc)}");
        Console.WriteLine(iconNote == null
            ? $"      icon  {Path.GetFileName(iconSrc)}"
            : $"      icon  {iconSrcValue}, baked into {Path.GetFileNameWithoutExtension(iconSrc)} ({iconNote})");
        foreach (var x in extras) Console.WriteLine($"      +     {x.Rel}");

        // Where every shipped package claims to live now, and where it lives in the slot. The
        // mesh's material import, the material's texture import and so on are repointed with
        // this; without it a shipped material would sit in the slot while the mesh went on
        // loading the one at the old path (the game's, or nothing).
        var slotPkg = $"/Game/CMSF/{character}/{slot}";
        var relink = new Dictionary<string, string>(StringComparer.Ordinal);
        void Claim(string file, string newPkg)
        {
            var old = Identity.PackagePathOf(new UAsset(file, EngineVersion.VER_UE5_4, mappings),
                                             Path.GetFileNameWithoutExtension(file));
            if (relink.TryGetValue(old, out var prev) && prev != newPkg)
                throw new BuildError($"two of your packages both say they are '{old}' — cook them at different paths");
            relink[old] = newPkg;
        }
        Claim(meshSrc, $"{slotPkg}/{meshObj}");
        Claim(iconSrc, $"{slotPkg}/{texObj}");
        foreach (var x in extras) Claim(x.Src, $"{slotPkg}/{x.Rel}");

        Console.WriteLine($"==> cloning to {slotPkg}/");
        Clone.Package(meshSrc, mappings, Path.Combine(stage, slotDir, meshObj + ".uasset"), meshObj, relink);
        Clone.Package(iconSrc, mappings, Path.Combine(stage, slotDir, texObj + ".uasset"), texObj, relink);
        foreach (var x in extras)
            Clone.Package(x.Src, mappings, Path.Combine(stage, slotDir, x.Rel + ".uasset"),
                          Path.GetFileName(x.Rel), relink);

        // The string table is cloned from the game's own, never from the author's assets.
        var stTpl = Path.Combine(src, "ForeverWinter/Content/FW/UI/StringTables/ST_FW_UI_Skins.uasset");
        if (!File.Exists(stTpl)) Retoc.ToLegacy("ST_FW_UI_Skins", paks, src);
        if (!File.Exists(stTpl)) throw new BuildError("could not extract ST_FW_UI_Skins from the cook");
        Clone.StringTable(stTpl, mappings, Path.Combine(stage, slotDir, stObj + ".uasset"),
                          $"CMSF.{character}.{slot}", stObj,
                          new[] { (StKeyName, name), (StKeyDesc, desc) });

        Console.WriteLine("==> packing");
        Retoc.ToZen(stage, Path.Combine(outDir, pak + ".utoc"));
        long size = Directory.GetFiles(outDir, pak + ".*").Sum(f => new FileInfo(f).Length);
        Console.WriteLine($"    {pak}   {size / 1024.0 / 1024.0:F2} MB");

        Verify(build, outDir, stage, paks, pak, slotDir, character, mappings,
               extras.Select(x => x.Rel).ToList(), meshObj, texObj, stObj);

        Console.WriteLine($"\ndone -> {outDir}\n");
        Console.WriteLine($"Install alongside the framework. This pak MUST load ABOVE it " +
                          $"(_{PakOrder}_P beats _9_P; under MO2, higher priority wins).");
        Console.WriteLine($"Expect {character} slot {slot} to show '{name}' with this portrait and mesh.");
    }

    /// <summary>
    /// An image portrait: extract the character's base portrait from the cook, and write the
    /// image over a copy of it. The copy lives in the build tree, never in the extraction cache,
    /// so a later build that clones the real game portrait gets the game's pixels.
    /// </summary>
    static (string, string) BakePortrait(string value, string skinDir, string src, string build,
                                         string paks, string character)
    {
        var image = Path.GetFullPath(Path.Combine(skinDir, value));
        if (!File.Exists(image)) throw new BuildError($"icon: {image} does not exist");
        var tpl = ResolveSource(Portrait.TemplateFor(character), skinDir, src, paks, "icon template");
        var dir = Path.Combine(build, "portrait");
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        Directory.CreateDirectory(dir);
        var copy = Path.Combine(dir, Path.GetFileName(tpl));
        File.Copy(tpl, copy);
        File.Copy(Path.ChangeExtension(tpl, ".uexp"), Path.ChangeExtension(copy, ".uexp"));
        return (copy, Portrait.Bake(image, copy));
    }

    /// <summary>A /Game/ value is cloned out of the live cook; anything else is a path
    /// relative to the skin directory, which is how an author ships their own cooked assets.</summary>
    static string ResolveSource(string value, string skinDir, string src, string paks, string kind)
    {
        if (value.StartsWith("/Game/", StringComparison.Ordinal))
        {
            var obj = value.Split('.').Last();
            Retoc.ToLegacy(obj, paks, src);
            var pkg = value.Split('.')[0];
            var rel = "ForeverWinter/Content/" + pkg.Substring("/Game/".Length) + ".uasset";
            var f = Path.Combine(src, rel.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(f))
                throw new BuildError($"{kind}: nothing named '{obj}' came out of the cook for '{value}'");
            return f;
        }
        var local = Path.GetFullPath(Path.Combine(skinDir, value));
        if (!File.Exists(local)) throw new BuildError($"{kind}: {local} does not exist");
        if (Path.GetExtension(local) != ".uasset")
            throw new BuildError($"{kind}: expected a .uasset, got {Path.GetFileName(local)}");
        return local;
    }

    /// <summary>
    /// Expand skin.json "assets" into (source file, path under the slot). Folders take every
    /// .uasset beneath them; the layout under the skin folder becomes the layout under the
    /// slot, so Materials/M_X.uasset ships as /Game/CMSF/Char/NN/Materials/M_X.
    /// </summary>
    static List<(string Src, string Rel)> ResolveAssets(List<string> values, string skinDir,
                                                        string[] reserved, params string[] exclude)
    {
        var skip = exclude.Select(Path.GetFullPath).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var found = new List<(string, string)>();
        foreach (var v in values)
        {
            if (v.StartsWith("/Game/", StringComparison.Ordinal))
                throw new BuildError(
                    $"assets: '{v}' is a game path. Reference game assets from your mesh or material " +
                    "directly — everyone already has them. List only packages you cooked yourself.");
            var full = Path.GetFullPath(Path.Combine(skinDir, v));
            var files = Directory.Exists(full) ? Directory.GetFiles(full, "*.uasset", SearchOption.AllDirectories)
                      : File.Exists(full) ? new[] { full }
                      : throw new BuildError($"assets: {full} does not exist");
            foreach (var f in files.OrderBy(f => f, StringComparer.Ordinal))
            {
                if (Path.GetExtension(f) != ".uasset")
                    throw new BuildError($"assets: expected a .uasset, got {Path.GetFileName(f)}");
                var rel = Path.GetRelativePath(skinDir, f).Replace('\\', '/');
                if (rel.StartsWith("../", StringComparison.Ordinal) || Path.IsPathRooted(rel))
                    throw new BuildError($"assets: {f} is outside the skin folder. Keep your cooked files " +
                                         "inside it — their layout there becomes their layout in the slot.");
                if (skip.Contains(Path.GetFullPath(f)) || !seen.Add(rel)) continue;
                rel = rel[..^".uasset".Length];
                if (reserved.Contains(rel, StringComparer.OrdinalIgnoreCase))
                    throw new BuildError($"assets: '{rel}' would overwrite one of the slot's own packages; rename it");
                found.Add((Path.GetFullPath(f), rel));
            }
        }
        return found;
    }

    /// <summary>Decode the built pak back out and prove it holds the slot packages and
    /// nothing else, and that nothing in it points at a package that will not be there.
    /// "Authors never ship DT_SkinUIData or BP_Player_*" is enforced here rather than
    /// remembered.</summary>
    static void Verify(string build, string outDir, string stage, string paks, string pak,
                       string slotDir, string character, Usmap mappings, List<string> extras,
                       params string[] objects)
    {
        Console.WriteLine("==> verifying (decode the built pak back out)");
        var vsrc = Path.Combine(build, "vsrc");
        var vout = Path.Combine(build, "vout");
        foreach (var d in new[] { vsrc, vout }) if (Directory.Exists(d)) Directory.Delete(d, true);
        Directory.CreateDirectory(vsrc);

        // to-legacy on a mod pak needs global.utoc/global.ucas staged beside it — NOT the
        // whole game. That is 2.9 MB against 45 GB, it needs no hardlinks so the work tree can
        // live on any volume, and it makes the "must not ship" check below into a real
        // assertion: with only our own pak mounted, anything that comes out came from us.
        // tools/cmsf_author.py mounts the entire cook and therefore cannot tell the
        // difference between our DT_SkinUIData and the game's.
        foreach (var f in Directory.GetFiles(paks, "global.*"))
            File.Copy(f, Path.Combine(vsrc, Path.GetFileName(f)), true);
        foreach (var f in Directory.GetFiles(outDir, pak + ".*"))
            File.Copy(f, Path.Combine(vsrc, Path.GetFileName(f)), true);

        var extraNames = extras.Select(r => r.Split('/').Last());
        foreach (var filter in objects.Concat(extraNames).Distinct()
                                      .Concat(new[] { "DT_SkinUIData", $"BP_Player_{character}" }))
            Retoc.ToLegacy(filter, vsrc, vout);

        var problems = new List<string>();
        foreach (var rel in objects.Concat(extras))
            if (!File.Exists(Path.Combine(vout, slotDir.Replace('/', Path.DirectorySeparatorChar),
                                          rel.Replace('/', Path.DirectorySeparatorChar) + ".uasset")))
                problems.Add($"missing from the pak: {rel}");

        // Nothing but our pak is mounted, so either of these appearing means we shipped it —
        // and shipping either is what makes two CMSF skins clobber each other.
        foreach (var forbidden in new[] { "DT_SkinUIData", $"BP_Player_{character}" })
            if (Directory.EnumerateFiles(vout, forbidden + ".uasset", SearchOption.AllDirectories).Any())
                problems.Add($"pak ships {forbidden}, which authors must never own");

        var allowed = objects.Concat(extras).Select(o => $"{slotDir}/{o}.uasset").ToHashSet(StringComparer.OrdinalIgnoreCase);
        var shipped = Directory.GetFiles(stage, "*.uasset", SearchOption.AllDirectories)
            .Select(p => Path.GetRelativePath(stage, p).Replace('\\', '/'))
            .OrderBy(p => p, StringComparer.Ordinal).ToList();
        foreach (var f in shipped)
            if (!allowed.Contains(f)) problems.Add($"pak ships something it must not: {f}");

        // Every package reference must land on something: a package this pak ships, or one the
        // game already has. Anything else is a material that silently falls back, or a mesh
        // that loads as nothing — clean build, broken skin. Checked on the staged packages,
        // whose name maps are what to-zen turns into import IDs.
        var slotPkg = "/Game/" + slotDir["ForeverWinter/Content/".Length..];
        var ours = shipped.Select(f => "/Game/" + f["ForeverWinter/Content/".Length..^".uasset".Length])
                          .ToHashSet(StringComparer.Ordinal);
        var gameRefs = new SortedSet<string>(StringComparer.Ordinal);
        var probe = Path.Combine(build, "probe");
        foreach (var f in shipped)
        {
            var a = new UAsset(Path.Combine(stage, f), EngineVersion.VER_UE5_4, mappings);
            var who = Path.GetFileNameWithoutExtension(f);
            foreach (var imp in Identity.PackageImports(a))
            {
                if (ours.Contains(imp)) continue;
                if (imp.StartsWith(slotPkg + "/", StringComparison.Ordinal))
                    problems.Add($"{who} references {imp} inside your slot, but nothing ships there");
                else if (imp.StartsWith("/Game/CMSF/", StringComparison.Ordinal))
                    problems.Add($"{who} references {imp}, which belongs to another CMSF slot");
                else if (!InGame(imp, paks, probe))
                    problems.Add($"{who} references {imp}, which is neither in this pak nor in the game — " +
                                 "it would load as nothing. Add its cooked package to \"assets\" in skin.json.");
                else gameRefs.Add(imp);
            }
        }

        Console.WriteLine($"    mesh={objects[0]}  icon={objects[1]}  table={objects[2]}" +
                          (extras.Count > 0 ? $"  +{extras.Count} asset(s)" : ""));
        Console.WriteLine($"    shipped {shipped.Count} package(s), all inside {slotPkg}/");
        if (gameRefs.Count > 0)
            Console.WriteLine($"    uses {gameRefs.Count} game package(s): " +
                              string.Join(", ", gameRefs.Select(g => g.Split('/').Last())));

        var skel = Identity.SkeletonWarning(
            new UAsset(Path.Combine(stage, slotDir, objects[0] + ".uasset"), EngineVersion.VER_UE5_4, mappings),
            character);
        if (skel != null) Console.WriteLine($"\n    WARNING  {skel}");

        if (problems.Count > 0)
            throw new BuildError("VERIFY FAILED:\n  " + string.Join("\n  ", problems));
    }

    static readonly Dictionary<string, bool> inGame = new(StringComparer.Ordinal);

    /// <summary>Does the installed game ship this package? One filtered extract, ~0.6 s, cached.</summary>
    static bool InGame(string pkg, string paks, string probe)
    {
        if (inGame.TryGetValue(pkg, out var known)) return known;
        try { Retoc.ToLegacy(pkg.Split('/').Last(), paks, probe); }
        catch (BuildError) { /* nothing matched is an answer, not a failure */ }
        var f = Path.Combine(probe, "ForeverWinter", "Content",
                             pkg["/Game/".Length..].Replace('/', Path.DirectorySeparatorChar) + ".uasset");
        return inGame[pkg] = File.Exists(f);
    }

    static void Usage() => Console.WriteLine("""
        cmsf-author — build one CMSF skin into one pak trio.

          cmsf-author <skin-dir> [--slot NN]
          cmsf-author --list-free <Character>

        Options:
          --slot NN          claimed slot, two digits (overrides skin.json)
          --pool-slots N     depth of the installed framework, for a sanity check (default 32)
          --unregistered     silence the note about an unregistered public slot
          --out DIR          where to write the pak trio (default ./dist/<id>)
          --aes KEY          game pak AES key; default is FW_AES_KEY, then fw_aes.txt beside the exe
          --usmap PATH       the .usmap; default is any *.usmap beside this exe
          --game PATH        the game folder; default is Steam auto-detection
          --retoc PATH       retoc.exe; default is beside this exe, then PATH
          --registry PATH    a local slots.md instead of fetching the published one
          --menu             the interactive menu (automatic when double-clicked)
          -h, --help         this

        skin.json:
          { "character": "Girl", "slot": "00", "name": "Octogirl",
            "description": "...",
            "mesh": "/Game/... .SK_X",   a cooked path to clone, OR a local .uasset
            "icon": "portrait.png",      REQUIRED, a claim with no portrait is hidden. An image
                                         (.png .jpg .bmp .tga) is fitted to the game's portrait
                                         size; a /Game/ path or a local .uasset also works
            "assets": ["Materials", "Textures"]
                                         optional: your own cooked packages the mesh uses,
                                         files or folders; they ship inside your slot
          }
        """);

    class Args
    {
        public string SkinDir, Slot, ListFree, Out, Usmap, Game, Retoc, Registry, Aes;
        public int PoolSlots = 32;
        public bool Unregistered, Help, Menu;

        public static Args Parse(string[] argv)
        {
            var a = new Args();
            for (int i = 0; i < argv.Length; i++)
            {
                string Next(string flag) => ++i < argv.Length ? argv[i]
                    : throw new BuildError($"{flag} needs a value");
                switch (argv[i])
                {
                    case "--slot": a.Slot = Next("--slot"); break;
                    case "--pool-slots":
                        if (!int.TryParse(Next("--pool-slots"), out a.PoolSlots) || a.PoolSlots < 1)
                            throw new BuildError("--pool-slots needs a positive integer");
                        break;
                    case "--list-free": a.ListFree = Next("--list-free"); break;
                    case "--unregistered": a.Unregistered = true; break;
                    case "--out": a.Out = Next("--out"); break;
                    case "--usmap": a.Usmap = Next("--usmap"); break;
                    case "--game": a.Game = Next("--game"); break;
                    case "--retoc": a.Retoc = Next("--retoc"); break;
                    case "--aes": a.Aes = Next("--aes"); break;
                    case "--registry": a.Registry = Next("--registry"); break;
                    case "--menu": a.Menu = true; break;
                    case "-h" or "--help": a.Help = true; break;
                    default:
                        if (argv[i].StartsWith('-')) throw new BuildError($"unknown option {argv[i]}");
                        a.SkinDir ??= argv[i];
                        break;
                }
            }
            return a;
        }
    }
}
