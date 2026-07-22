// The banner.
//
// Gold is rgb(200, 154, 71) — not picked by eye, it is the field colour from
// assets/make_icon.py, so the tool matches the mod icon.
//
// Three things have to be true or a banner is worse than none:
//   * REDIRECTED OUTPUT GETS NOTHING. Piping --list-free into a script must stay parseable,
//     so if stdout is not a console this writes nothing at all — not even uncoloured art.
//   * LEGACY CONSOLES NEED ASKING. Windows Terminal handles ANSI out of the box; conhost
//     does not until ENABLE_VIRTUAL_TERMINAL_PROCESSING is set. Without that, an escape
//     sequence prints as literal garbage across the top of the window.
//   * NO_COLOR IS HONOURED. https://no-color.org — set it and the art still draws, plain.
using System.Runtime.InteropServices;

static class Banner
{
    const string Gold  = "[38;2;200;154;71m";
    const string Dim   = "[38;2;120;95;50m";
    const string Reset = "[0m";

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetConsoleMode(IntPtr handle, uint mode);

    const int STD_OUTPUT_HANDLE = -11;
    const uint ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;

    static bool TryEnableAnsi()
    {
        try
        {
            var h = GetStdHandle(STD_OUTPUT_HANDLE);
            if (h == IntPtr.Zero || h == new IntPtr(-1)) return false;
            if (!GetConsoleMode(h, out uint mode)) return false;
            if ((mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0) return true;
            return SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
        }
        catch { return false; }
    }

    static readonly string[] Art =
    {
        @"   _____ __  ___ ____   ____",
        @"  / ___//  |/  // __/  / __/",
        @" / /__ / /|_/ /_\ \   / _/",
        @" \___//_/  /_//___/  /_/",
    };

    public static void Write()
    {
        if (Console.IsOutputRedirected) return;

        bool colour = TryEnableAnsi()
                      && string.IsNullOrEmpty(Environment.GetEnvironmentVariable("NO_COLOR"));

        Console.WriteLine();
        for (int i = 0; i < Art.Length; i++)
        {
            // The subtitle rides the last line rather than taking one of its own.
            bool last = i == Art.Length - 1;
            string line = last ? Art[i].PadRight(30) + "Character Model Selection Framework" : Art[i];
            if (!colour) { Console.WriteLine(line); continue; }

            if (last)
                Console.WriteLine(Gold + Art[i].PadRight(30) + Reset +
                                  Dim + "Character Model Selection Framework" + Reset);
            else
                Console.WriteLine(Gold + Art[i] + Reset);
        }
        Console.WriteLine();
    }
}
