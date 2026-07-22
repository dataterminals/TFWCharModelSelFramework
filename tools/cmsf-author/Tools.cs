// Finding the three things this tool cannot ship, and driving the one it can.
//
// tools/cmsf_author.py hardcodes absolute paths for two development machines. That is fine
// for a script run from a clone and useless in an author's hands, so everything here is
// discovery plus an explicit override.
//
// WHAT MUST NOT BE REDISTRIBUTED (docs/04-authoring.md §"What ships, and what must not"):
//   * ForeverWinter-*.usmap  — decoded from the game's own type layout. Shipping it
//     redistributes part of the game. Authors dump their own with UE4SS, once per version.
//   * oo2core_9_win64.dll    — proprietary Oodle. retoc provisions this itself, which is why
//     the first run may need a connection.
// retoc.exe itself is MIT and CAN ship beside this tool, with attribution.
using System.Diagnostics;

static class Tools
{
    public const string Aes =
        "0x84B2244BE0AF90C22976D739FA0665569219F4CEA119CEA37C81F2D9ABEE4795";

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

    public static string FindUsmap(string overridePath)
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
            "  game version with UE4SS — a DumpUSMAP() call from Lua. You already run UE4SS\n" +
            "  for CMSFUnlock, so this is not a new dependency.");
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
