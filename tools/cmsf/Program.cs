// cmsf — Character Model Selection Framework builder.
//
// Regenerates a single pak that adds every registered skin to The Forever Winter's
// character-select screen. Run it after installing or removing a skin mod.
//
// WHY A GENERATOR RATHER THAN A FIXED FRAMEWORK PAK
// A pak override replaces a WHOLE asset, so DT_SkinUIData and the BP_Player_* Blueprints can
// only have one owner — if every skin mod shipped its own edit, the last to load would
// silently erase the rest. Regenerating one combined pak sidesteps that entirely: real
// per-skin names, unlimited skins, and no reserved-slot pool with empty entries that are
// (as tested) both visible AND selectable.
//
// WHY THE .usmap IS NOT BUNDLED
// It is decoded from the game's own type layout — copyright-derived data. Shipping it would
// mean redistributing part of the game. Users dump their own from their own copy; the tool
// explains how. They already run UE4SS for CMSFUnlock, so the dependency is not new.
using System.Diagnostics;
using System.Text.Json;

static class Program
{
    const string AES = "0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795";

    // Load order: for a "*_P.pak", the token between the LAST TWO underscores is parsed as
    // the chunk version (N -> N+1; PakOrder += 100 * CVN). A numeric PREFIX is inert.
    const string PakName = "CMSF_9_P";

    // The six playable characters. "Mech Trooper" does not exist — the sixth is MaskMan.
    static readonly Dictionary<string, string> Characters = new(StringComparer.OrdinalIgnoreCase)
    {
        ["BagMan"] = "BP_Player_BagMan",
        ["Girl"] = "BP_Player_Girl",
        ["Gunhead"] = "BP_Player_Gunhead",
        ["MaskMan"] = "BP_Player_MaskMan",
        ["OldMan"] = "BP_Player_OldMan",
        ["Shaman"] = "BP_Player_Shaman",
    };

    const string BpDir = @"ForeverWinter\Content\FW\Player\Class";
    const string TableRel = @"ForeverWinter\Content\FW\Player\Data\DT_SkinUIData.uasset";

    sealed class Skin
    {
        public string character { get; set; }
        public string id { get; set; }
        public string name { get; set; }
        public string description { get; set; }
        public string mesh { get; set; }
        public string icon { get; set; }
        public string Source;
        public string Row => $"CMSF.{character}.{id}";
    }

    static string ExeDir => AppContext.BaseDirectory.TrimEnd('\\');
    static bool interactive;

    static int Main(string[] args)
    {
        Console.WriteLine("CMSF — Character Model Selection Framework builder\n");

        var extraDirs = new List<string>();
        bool listOnly = false;
        foreach (var a in args)
        {
            if (a is "--list" or "-l") listOnly = true;
            else if (a is "--help" or "-h" or "/?") { Help(); return Done(0); }
            else if (Directory.Exists(a)) extraDirs.Add(a);
            else if (File.Exists(a)) extraDirs.Add(Path.GetDirectoryName(a));
            else Console.WriteLine($"  (ignoring unknown argument: {a})");
        }
        // No arguments almost always means it was double-clicked, so keep the window open
        // and confirm before doing anything.
        interactive = args.Length == 0;

        try { return Run(extraDirs, listOnly); }
        catch (Exception ex)
        {
            Console.WriteLine();
            Console.WriteLine("ERROR: " + ex.Message);
            return Done(1);
        }
    }

    static void Help()
    {
        Console.WriteLine("""
            Usage:
              cmsf.exe                 auto-detect everything and build
              cmsf.exe <folder> ...    also scan these folders for *.cmsf.json manifests
                                       (drag a mods folder onto the exe)
              cmsf.exe --list          show what was found, build nothing

            Put skin manifests either in a "skins" folder next to this exe, or as
            *.cmsf.json files anywhere under a folder you pass in.

            Needs, alongside this exe:
              retoc.exe                   https://github.com/trumank/retoc  (MIT)
              ForeverWinter-*.usmap       dump your own: Ctrl+Numpad6 in UE4SS
            """);
    }

    static int Done(int code)
    {
        if (interactive)
        {
            Console.WriteLine();
            Console.WriteLine("Press Enter to close...");
            Console.ReadLine();
        }
        return code;
    }

    static string FindBeside(params string[] names)
    {
        foreach (var n in names)
        {
            var p = Path.Combine(ExeDir, n);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    static int Run(List<string> extraDirs, bool listOnly)
    {
        // ---- inputs --------------------------------------------------------------------
        var game = Steam.Find();
        if (game == null)
            throw new Exception(
                "could not find The Forever Winter via Steam.\n" +
                "  Drag the game folder onto this exe, or run it from inside the game folder.");
        Console.WriteLine($"  game    {game.Root}");
        if (game.BuildId != null) Console.WriteLine($"  build   {game.BuildId}");
        if (game.UpdatePending)
            Console.WriteLine("  WARNING Steam reports an update in progress — build after it finishes.");

        var skins = LoadSkins(extraDirs);
        if (skins.Count == 0)
        {
            Console.WriteLine("""

                No skins found.

                Put a manifest in a "skins" folder next to this exe:

                  skins\my-skin\skin.json
                  {
                    "character": "Girl",
                    "name": "Ash Runner",
                    "mesh": "/Game/MyMod/Skins/Ash/SK_Ash.SK_Ash",
                    "icon": "/Game/MyMod/Skins/Ash/T_Ash.T_Ash"
                  }

                ...or drag a folder containing *.cmsf.json manifests onto this exe.
                """);
            return Done(0);
        }

        var byChar = skins.GroupBy(s => s.character, StringComparer.OrdinalIgnoreCase)
                          .ToDictionary(g => g.Key, g => g.ToList(), StringComparer.OrdinalIgnoreCase);
        Console.WriteLine($"\n  {skins.Count} skin(s) across {byChar.Count} character(s):");
        foreach (var (ch, items) in byChar.OrderBy(k => k.Key))
            foreach (var s in items)
                Console.WriteLine($"    {ch,-8} {s.name,-24} {s.mesh}");

        if (listOnly) return Done(0);

        var retoc = FindBeside("retoc.exe")
            ?? throw new Exception("retoc.exe not found next to this exe.\n" +
                                   "  Download it from https://github.com/trumank/retoc (MIT) and put it here.");
        var usmap = Directory.EnumerateFiles(ExeDir, "*.usmap").FirstOrDefault()
            ?? throw new Exception(
                "no .usmap found next to this exe.\n" +
                "  CMSF cannot bundle one — it is decoded from the game's own data, so\n" +
                "  shipping it would mean redistributing part of the game.\n" +
                "\n" +
                "  Dump your own, once per game version, with UE4SS (experimental build):\n" +
                "    press Ctrl+Numpad6 in game (the default Dump Mappings keybind),\n" +
                "    or call DumpUSMAP() from a Lua mod.\n" +
                "  It lands next to the game exe as ForeverWinter-<ver>-....usmap.\n" +
                "  Copy it here.");
        Console.WriteLine($"\n  retoc   {Path.GetFileName(retoc)}");
        Console.WriteLine($"  usmap   {Path.GetFileName(usmap)}");

        if (interactive)
        {
            Console.Write("\nBuild now? [Y/n] ");
            var k = Console.ReadLine();
            if (!string.IsNullOrEmpty(k) && !k.StartsWith("y", StringComparison.OrdinalIgnoreCase))
                return Done(0);
        }

        // ---- extract from the LIVE cook ------------------------------------------------
        // Never from a committed snapshot: a stale override would revert rows a game patch
        // added, and would drift from the current asset layout.
        var work = Path.Combine(Path.GetTempPath(), "cmsf-build");
        if (Directory.Exists(work)) Directory.Delete(work, true);
        string src = Path.Combine(work, "src"), staged = Path.Combine(work, "staged");
        Directory.CreateDirectory(src);
        Directory.CreateDirectory(staged);

        Console.WriteLine("\n==> extracting from the installed game");
        foreach (var f in byChar.Keys.Select(c => Characters[c]).Append("DT_SkinUIData"))
            Exec(retoc, ["-a", AES, "to-legacy", "--version", "UE5_4", "-f", f, game.Paks, src]);

        // ---- patch ---------------------------------------------------------------------
        foreach (var (ch, items) in byChar.OrderBy(k => k.Key))
        {
            var rel = Path.Combine(BpDir, Characters[ch] + ".uasset");
            if (!File.Exists(Path.Combine(src, rel)))
                throw new Exception($"the game did not yield {Characters[ch]} — was it renamed in an update?");
            Directory.CreateDirectory(Path.Combine(staged, BpDir));
            int n = Patcher.AddToRoster(Path.Combine(src, rel), usmap, Path.Combine(staged, rel),
                                        items.Select(s => s.mesh));
            Console.WriteLine($"==> {Characters[ch]}: +{n} to the roster");
        }

        if (!File.Exists(Path.Combine(src, TableRel)))
            throw new Exception("the game did not yield DT_SkinUIData");
        Directory.CreateDirectory(Path.Combine(staged, Path.GetDirectoryName(TableRel)!));
        int rowsAdded = Patcher.AddRows(Path.Combine(src, TableRel), usmap, Path.Combine(staged, TableRel),
            skins.Select(s => new Patcher.Row(s.Row, s.name, s.description ?? "", s.icon, s.mesh)));
        Console.WriteLine($"==> DT_SkinUIData: +{rowsAdded} row(s)");

        // ---- repack --------------------------------------------------------------------
        var outDir = Path.Combine(ExeDir, "out");
        if (Directory.Exists(outDir)) Directory.Delete(outDir, true);
        Directory.CreateDirectory(outDir);
        Console.WriteLine("==> repacking");
        Exec(retoc, ["to-zen", "--version", "UE5_4", staged, Path.Combine(outDir, PakName + ".utoc")]);

        // ---- verify by decoding the BUILT pak back out ---------------------------------
        // A pak that installs cleanly and does nothing is indistinguishable in-game from
        // "the approach does not work". Verify rather than assume the writes landed.
        Console.WriteLine("==> verifying");
        string vsrc = Path.Combine(work, "vsrc"), vout = Path.Combine(work, "vout");
        Directory.CreateDirectory(vsrc);
        foreach (var g in new[] { "global.utoc", "global.ucas" })   // mod pak has no ScriptObjects chunk
            File.Copy(Path.Combine(game.Paks, g), Path.Combine(vsrc, g));
        foreach (var f in Directory.EnumerateFiles(outDir))
            File.Copy(f, Path.Combine(vsrc, Path.GetFileName(f)));
        Exec(retoc, ["to-legacy", "--version", "UE5_4", vsrc, vout]);

        var problems = new List<string>();
        foreach (var (ch, items) in byChar)
        {
            var roster = Patcher.RosterPaths(Path.Combine(vout, BpDir, Characters[ch] + ".uasset"), usmap);
            foreach (var s in items)
                if (!roster.Any(p => p.Contains(s.mesh.Split('.')[0], StringComparison.OrdinalIgnoreCase)))
                    problems.Add($"{Characters[ch]}: mesh missing after repack — {s.mesh}");
        }
        var rowNames = Patcher.RowNames(Path.Combine(vout, TableRel), usmap);
        foreach (var s in skins)
            if (!rowNames.Contains(s.Row)) problems.Add($"DT_SkinUIData: row missing after repack — {s.Row}");

        if (problems.Count > 0)
        {
            Console.WriteLine("\nVERIFY FAILED:");
            foreach (var p in problems) Console.WriteLine("  " + p);
            return Done(2);
        }
        Console.WriteLine($"    ok — {skins.Count} skin(s) present in the built pak");

        Console.WriteLine($"""

            Built:  {outDir}

            Install the .pak/.utoc/.ucas trio into:
              {Path.Combine(game.Root, @"Windows\ForeverWinter\Content\Paks\Mods")}
            (or as an MO2 mod, with the trio under a "Mods" folder)

            You also need the CMSFUnlock UE4SS mod — without it the selector only ever
            shows entitlement-gated DLC skins, and none of these will appear.
            """);
        return Done(0);
    }

    static List<Skin> LoadSkins(List<string> extraDirs)
    {
        var files = new List<string>();

        var local = Path.Combine(ExeDir, "skins");
        if (Directory.Exists(local))
            files.AddRange(Directory.EnumerateFiles(local, "skin.json", SearchOption.AllDirectories));
        foreach (var d in extraDirs)
            files.AddRange(Directory.EnumerateFiles(d, "*.cmsf.json", SearchOption.AllDirectories));

        var skins = new List<Skin>();
        var opts = new JsonSerializerOptions { PropertyNameCaseInsensitive = true, AllowTrailingCommas = true };
        foreach (var f in files.Distinct())
        {
            Skin s;
            try { s = JsonSerializer.Deserialize<Skin>(File.ReadAllText(f), opts); }
            catch (JsonException e) { throw new Exception($"{f}: invalid JSON — {e.Message}"); }
            if (s == null) continue;
            s.Source = f;

            if (string.IsNullOrWhiteSpace(s.character) || string.IsNullOrWhiteSpace(s.name) ||
                string.IsNullOrWhiteSpace(s.mesh))
                throw new Exception($"{f}: 'character', 'name' and 'mesh' are all required");
            if (!Characters.ContainsKey(s.character))
                throw new Exception($"{f}: unknown character '{s.character}' — expected one of " +
                                    string.Join(", ", Characters.Keys));
            s.character = Characters.Keys.First(k => k.Equals(s.character, StringComparison.OrdinalIgnoreCase));
            s.id ??= Path.GetFileName(Path.GetDirectoryName(f));
            // Falling back to a stock portrait keeps an icon-less skin from rendering as a
            // blank tile — an unresolvable soft path is NOT skipped by the game.
            s.icon ??= "/Game/UI/Textures/MainMenu/Menu/T_Menu_PickCharacter_Portrait_ScavGirl." +
                       "T_Menu_PickCharacter_Portrait_ScavGirl";
            skins.Add(s);
        }

        foreach (var dup in skins.GroupBy(s => s.Row, StringComparer.OrdinalIgnoreCase).Where(g => g.Count() > 1))
            throw new Exception($"two manifests claim the same id '{dup.Key}':\n    " +
                                string.Join("\n    ", dup.Select(d => d.Source)));
        return skins;
    }

    static void Exec(string exe, string[] argv)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in argv) psi.ArgumentList.Add(a);   // list argv, so nothing re-parses /Game/... paths
        using var p = Process.Start(psi)!;
        string so = p.StandardOutput.ReadToEnd(), se = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0)
            throw new Exception($"{Path.GetFileName(exe)} failed (exit {p.ExitCode})\n{so}\n{se}");
    }
}
