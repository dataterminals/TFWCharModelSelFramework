// Locate The Forever Winter without asking the user to paste a path.
//
// Steam's install lives in the registry; libraries live in steamapps/libraryfolders.vdf;
// each library's appmanifest_<appid>.acf gives the install directory and build id. Walking
// that chain is the difference between a tool that works on a double-click and one that
// opens with a "please enter your game path" prompt.
using Microsoft.Win32;
using System.Text.RegularExpressions;

static class Steam
{
    public const string AppId = "2828860";           // The Forever Winter

    public record GameInfo(string Root, string Paks, string BuildId, bool UpdatePending);

    static string SteamRoot()
    {
        foreach (var (hive, key) in new[]
        {
            (Registry.CurrentUser,  @"SOFTWARE\Valve\Steam"),
            (Registry.LocalMachine, @"SOFTWARE\WOW6432Node\Valve\Steam"),
            (Registry.LocalMachine, @"SOFTWARE\Valve\Steam"),
        })
        {
            try
            {
                using var k = hive.OpenSubKey(key);
                var p = k?.GetValue("SteamPath") as string ?? k?.GetValue("InstallPath") as string;
                if (!string.IsNullOrWhiteSpace(p) && Directory.Exists(p)) return p.Replace('/', '\\');
            }
            catch { /* registry access can fail; fall through to the next candidate */ }
        }
        return null;
    }

    static IEnumerable<string> Libraries(string steamRoot)
    {
        yield return steamRoot;
        var vdf = Path.Combine(steamRoot, "steamapps", "libraryfolders.vdf");
        if (!File.Exists(vdf)) yield break;
        // "path"  "D:\\SteamLibrary"
        foreach (Match m in Regex.Matches(File.ReadAllText(vdf), "\"path\"\\s+\"([^\"]+)\""))
        {
            var p = m.Groups[1].Value.Replace(@"\\", @"\");
            if (Directory.Exists(p)) yield return p;
        }
    }

    /// <summary>Find the game, or null. `hint` (if given) is tried first as a game root.</summary>
    public static GameInfo Find(string hint = null)
    {
        if (!string.IsNullOrWhiteSpace(hint))
        {
            var g = FromRoot(hint);
            if (g != null) return g;
        }

        var steam = SteamRoot();
        if (steam == null) return null;

        foreach (var lib in Libraries(steam))
        {
            var acf = Path.Combine(lib, "steamapps", $"appmanifest_{AppId}.acf");
            if (!File.Exists(acf)) continue;
            var text = File.ReadAllText(acf);

            string Field(string name)
            {
                var m = Regex.Match(text, $"\"{name}\"\\s+\"([^\"]+)\"", RegexOptions.IgnoreCase);
                return m.Success ? m.Groups[1].Value : null;
            }

            var installDir = Field("installdir");
            if (installDir == null) continue;
            var root = Path.Combine(lib, "steamapps", "common", installDir);
            var g = FromRoot(root);
            if (g == null) continue;

            // StateFlags 4 == fully installed with no update bits. Mid-update the manifest
            // names the INCOMING build, so a build id read then would be a lie.
            int.TryParse(Field("StateFlags"), out var flags);
            return g with { BuildId = Field("buildid"), UpdatePending = flags != 4 };
        }
        return null;
    }

    static GameInfo FromRoot(string root)
    {
        if (string.IsNullOrWhiteSpace(root)) return null;
        var paks = Path.Combine(root, "Windows", "ForeverWinter", "Content", "Paks");
        if (!Directory.Exists(paks)) return null;
        return new GameInfo(root, paks, null, false);
    }
}
