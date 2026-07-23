// Finding the things this tool must not ship, and driving the one it can.
//
// Everything game-derived is discovered or supplied by the author, never bundled — the rule
// the whole project follows (docs/04-authoring.md §"What ships, and what must not"):
//   * the pak AES key        — the game's own decryption key. Supply it with FW_AES_KEY,
//     --aes, or an fw_aes.txt beside the exe. UE4SS can dump it; CMSF never ships it.
//   * ForeverWinter-*.usmap  — decoded from the game's own type layout. Shipping it
//     redistributes part of the game. Authors dump their own with UE4SS, once per version.
//   * oo2core_9_win64.dll    — proprietary Oodle. retoc provisions this itself, which is why
//     the first run may need a connection.
// retoc.exe itself is MIT and CAN ship beside this tool, with attribution.
using System.Diagnostics;

static class Tools
{
    /// <summary>The game's pak AES key. Resolved by FindAes and set once at the start of a build.</summary>
    public static string Aes;

    /// <summary>
    /// Resolve the game's pak AES key without CMSF ever shipping it — it is the game's own
    /// decryption key, no more redistributable than the usmap. Order: --aes, then FW_AES_KEY,
    /// then an fw_aes.txt / aes.txt an author drops beside the exe (the same bring-it-once
    /// model as the usmap). Not needed for --list-free, so it is resolved only inside a build.
    /// </summary>
    public static string FindAes(string overrideKey)
    {
        var key = overrideKey;
        if (string.IsNullOrWhiteSpace(key))
            key = Environment.GetEnvironmentVariable("FW_AES_KEY");
        if (string.IsNullOrWhiteSpace(key) && Directory.Exists(ExeDir))
            foreach (var name in new[] { "fw_aes.txt", "aes.txt", "aes.key" })
            {
                var f = Path.Combine(ExeDir, name);
                if (File.Exists(f)) { key = File.ReadAllText(f).Trim(); if (!string.IsNullOrWhiteSpace(key)) break; }
            }

        key = key?.Trim();
        if (string.IsNullOrWhiteSpace(key))
            throw new BuildError(
                "No game AES key, and CMSF does not ship it — it is the game's own pak decryption\n" +
                "  key, the same reason CMSF does not ship a usmap. Supply it once, any one of:\n" +
                "    * put it in fw_aes.txt next to cmsf-author.exe, or\n" +
                "    * set the FW_AES_KEY environment variable, or\n" +
                "    * pass --aes <key>.\n" +
                "  UE4SS can dump it, or take it from the usual community key database for your build.\n" +
                "  It is 0x followed by 64 hex digits.");

        if (!key.StartsWith("0x", StringComparison.OrdinalIgnoreCase)) key = "0x" + key;
        var hex = key[2..];
        if (hex.Length != 64 || !hex.All(Uri.IsHexDigit))
            throw new BuildError($"the AES key looks wrong: expected 0x + 64 hex digits, got '{key}'");
        return key;
    }

    /// <summary>
    /// The directory holding the running exe. NOT AppContext.BaseDirectory — under
    /// PublishSingleFile that points at the extraction temp dir, so "beside the exe" lookups
    /// would silently miss the retoc and usmap an author dropped next to it.
    /// </summary>
    public static string ExeDir =>
        Path.GetDirectoryName(Environment.ProcessPath ?? Environment.GetCommandLineArgs()[0]);

    public static string FindRetoc(string overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            if (!File.Exists(overridePath)) throw new BuildError($"--retoc: {overridePath} does not exist");
            return overridePath;
        }
        var beside = Path.Combine(ExeDir, "retoc.exe");
        if (File.Exists(beside)) return beside;
        var onPath = FromPath("retoc.exe");
        if (onPath != null) return onPath;

        throw new BuildError(
            "retoc.exe not found. Put it next to cmsf-author.exe, or pass --retoc <path>.\n" +
            "  retoc is MIT-licensed and ships with CMSF; if you built from source, it is not in the repo.\n" +
            "  Its first run may need an internet connection to fetch Oodle.");
    }

    /// <summary>
    /// A note about UE4SS's built-in Keybinds mod, which owns Ctrl+Numpad6 — it registers
    /// DumpUSMAP, so with it disabled the keystroke does nothing and an author is stuck at the
    /// one step they cannot skip.
    ///
    /// ADVISORY ONLY, and deliberately so. Under MO2 the whole ue4ss tree is virtualised and
    /// exists in the real game folder only while the game is running, so a missing mods.txt
    /// proves nothing. It must never be reported as "UE4SS is not installed".
    /// </summary>
    static string KeybindHint(string paks)
    {
        const string enableIt =
            "  If Ctrl+Numpad6 does nothing, UE4SS's Keybinds mod is off. In\n" +
            "  Binaries\\Win64\\ue4ss\\Mods\\mods.txt set `Keybinds : 1`, editing the line where it\n" +
            "  sits — it is last on purpose (\"do not move up\"), so that legacy binding mods win.\n" +
            "  Either way DumpUSMAP() from Lua does not depend on the bind at all.";
        try
        {
            // paks is <game>\Windows\ForeverWinter\Content\Paks
            var fw = Directory.GetParent(paks)?.Parent?.FullName;
            if (fw == null) return enableIt;
            var modsTxt = Path.Combine(fw, "Binaries", "Win64", "ue4ss", "Mods", "mods.txt");
            if (!File.Exists(modsTxt)) return enableIt;

            foreach (var line in File.ReadAllLines(modsTxt))
            {
                var t = line.Trim();
                if (t.StartsWith(';') || !t.StartsWith("Keybinds", StringComparison.OrdinalIgnoreCase)) continue;
                var parts = t.Split(':');
                if (parts.Length < 2) continue;
                return parts[1].Trim() == "1"
                    ? "  Your UE4SS Keybinds mod is enabled, so Ctrl+Numpad6 should work as-is."
                    : "  YOUR UE4SS KEYBINDS MOD IS DISABLED, so Ctrl+Numpad6 will do nothing. Set\n" +
                      "  `Keybinds : 1` in the file below, editing the line where it sits — it is last\n" +
                      "  on purpose (\"do not move up\"). Or just call DumpUSMAP() from Lua instead.\n" +
                      $"    {modsTxt}";
            }
        }
        catch { /* advisory only — never fail the build over a diagnostic */ }
        return enableIt;
    }

    public static string FindUsmap(string overridePath, string paks = null)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            if (!File.Exists(overridePath)) throw new BuildError($"--usmap: {overridePath} does not exist");
            return overridePath;
        }
        var beside = Directory.Exists(ExeDir)
            ? Directory.GetFiles(ExeDir, "*.usmap").OrderBy(f => f, StringComparer.Ordinal).ToList()
            : new List<string>();

        if (beside.Count == 1) return beside[0];

        // NEVER guess between several. The obvious tie-breaks are both wrong: sorting by name
        // picks ForeverWinter-5.4.2 over 5.5.0, i.e. the STALE one, exactly when an author has
        // just re-dumped after a patch; and mtime lies about which cook a file describes. A
        // stale usmap does not fail loudly — it misreads the new type layout and yields a bad
        // package, so this refuses rather than picking.
        if (beside.Count > 1)
            throw new BuildError(
                $"{beside.Count} .usmap files sit next to cmsf-author.exe and I will not guess between them:\n" +
                string.Join("\n", beside.Select(f => "    " + Path.GetFileName(f))) + "\n" +
                "  Pass --usmap <path>, or leave only the one matching your installed game version.\n" +
                "  A usmap from a different version does not error — it silently builds a bad package.");

        throw new BuildError(
            "No .usmap found. Put one next to cmsf-author.exe, or pass --usmap <path>.\n" +
            "  CMSF cannot ship it: a usmap is decoded from the game's own type layout, so\n" +
            "  distributing it would redistribute part of the game. Dump your own once per\n" +
            "  game version with UE4SS, which you already run for CMSFUnlock:\n" +
            "    Ctrl+Numpad6 in-game, or a DumpUSMAP() call from Lua.\n" +
            (paks != null ? KeybindHint(paks) : ""));
    }

    public static string FindPaks(string overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath))
        {
            // Accept either the game root or the Paks directory itself.
            var direct = Path.Combine(overridePath, "Windows", "ForeverWinter", "Content", "Paks");
            if (Directory.Exists(direct)) return direct;
            if (Directory.Exists(overridePath)) return overridePath;
            throw new BuildError($"--game: {overridePath} is not a Forever Winter install or Paks directory");
        }
        var found = Steam.Find();
        if (found != null) return found.Paks;

        throw new BuildError(
            "Could not locate The Forever Winter via Steam. Pass --game <path to the game folder>.");
    }

    static string FromPath(string exe)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            string candidate;
            try { candidate = Path.Combine(dir.Trim(), exe); } catch { continue; }
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}

static class Retoc
{
    public static string Exe;

    /// <summary>Extract packages matching <paramref name="filter"/> out of a mounted set.</summary>
    public static void ToLegacy(string filter, string source, string dest) =>
        Run("-a", Tools.Aes, "to-legacy", "--version", "UE5_4", "-f", filter, source, dest);

    /// <summary>Pack a staging tree into a utoc/ucas/pak trio.</summary>
    public static void ToZen(string stage, string utoc) =>
        Run("to-zen", "--version", "UE5_4", stage, utoc);

    public static string Run(params string[] args)
    {
        var psi = new ProcessStartInfo(Exe)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = Process.Start(psi);
        string stdout = p.StandardOutput.ReadToEnd();
        string stderr = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0)
            throw new BuildError($"retoc {string.Join(' ', args)}\n{stdout}\n{stderr}".Trim());
        return stdout;
    }
}
