// The slot registry, read over the network.
//
// tools/cmsf_author.py reads docs/slots.md off disk because it runs from a clone. An author
// running a published exe has no clone, so this fetches the same file from the repo.
//
// FETCHING BEATS BUNDLING. A snapshot compiled into the binary goes stale the moment anyone
// claims a slot, and a stale registry is wrong in both directions — it rejects slots that are
// free and clears slots that have since been taken. Neither failure is visible to the author.
//
// FAILING SOFT IS DELIBERATE. Offline, or behind a proxy, or before the repo is public, this
// degrades to "cannot check" and the build continues with a note. That matches the rule the
// registry already states: claiming someone else's slot is an error, but an UNREGISTERED slot
// is only a warning, so nobody is ever blocked waiting on a merge to test locally. Hard-
// failing here would also break the private 28-31 range, which by design is never registered.
using System.Net.Http;
using System.Text.RegularExpressions;

// Named SlotRegistry, not Registry: the linked Steam.cs needs Microsoft.Win32.Registry, and a
// global-namespace `Registry` here shadows it.
static class SlotRegistry
{
    // NOTE: the default branch is `master`, not `main`.
    public const string DefaultUrl =
        "https://raw.githubusercontent.com/dataterminals/TFWCharModelSelFramework/master/docs/slots.md";

    // Slots 28..31 are the private range: never registered, never policed, so a personal or
    // work-in-progress skin never has to touch the file and can never collide with a
    // published one. Must match PRIVATE_FROM in tools/cmsf_author.py.
    public const int PrivateFrom = 28;

    public record Claim(string Id, string Skin, string Author);

    // | Character | Slot | ID | Skin | Author |
    static readonly Regex Row = new(
        @"^\|\s*(\w+)\s*\|\s*(\d{2})\s*\|\s*([\w.-]+)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|",
        RegexOptions.Compiled);

    /// <summary>Parsed claims keyed by "Char/NN". Null means the registry was unreachable —
    /// distinct from an empty registry, which means it was read and holds no claims.</summary>
    public static Dictionary<string, Claim> Load(string source, IEnumerable<string> characters, out string note)
    {
        note = null;
        string text;
        try
        {
            if (File.Exists(source))
            {
                text = File.ReadAllText(source);
            }
            else
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
                http.DefaultRequestHeaders.UserAgent.ParseAdd("cmsf-author");
                text = http.GetStringAsync(source).GetAwaiter().GetResult();
            }
        }
        catch (Exception ex)
        {
            // Unwrap the aggregate so the author sees "No such host is known", not
            // "One or more errors occurred."
            var msg = (ex is AggregateException ag ? ag.GetBaseException() : ex).Message;
            note = $"could not read the slot registry ({msg}); treating every slot as unregistered";
            return null;
        }

        var known = new HashSet<string>(characters, StringComparer.Ordinal);
        var claims = new Dictionary<string, Claim>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in text.Split('\n'))
        {
            var m = Row.Match(line.Trim());
            if (!m.Success) continue;
            var ch = m.Groups[1].Value;
            if (!known.Contains(ch)) continue;   // skips the header and the |---|---| separator
            claims[$"{ch}/{m.Groups[2].Value}"] =
                new Claim(m.Groups[3].Value, m.Groups[4].Value, m.Groups[5].Value);
        }
        return claims;
    }

    /// <summary>Public slots (below the private range) with no registered claim.</summary>
    public static List<string> FreeSlots(string character, int pool, Dictionary<string, Claim> claims)
    {
        var free = new List<string>();
        for (int i = 0; i < Math.Min(pool, PrivateFrom); i++)
        {
            var slot = i.ToString("D2");
            if (claims == null || !claims.ContainsKey($"{character}/{slot}")) free.Add(slot);
        }
        return free;
    }
}
