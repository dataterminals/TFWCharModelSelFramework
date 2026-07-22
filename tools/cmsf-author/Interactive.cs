// Making the exe behave like an exe.
//
// The audience for this tool is skin modders, not people who live in a shell. Their instinct
// on seeing a .exe is to double-click it, or to drag something onto it — and both were broken
// in opposite ways:
//
//   * DOUBLE-CLICK printed usage, errored "a skin directory is required", and Windows closed
//     the window before any of it could be read. A flash, and nothing.
//   * DRAG-AND-DROP a skin folder onto the icon actually WORKED — Windows passes the dropped
//     path as argv[1], which is exactly the positional argument the tool wants — but the
//     window still vanished before "done" or any error was visible. It worked and looked
//     like it had done nothing.
//
// So the fix is mostly not to add a mode; it is to stop throwing away the output.
using System.Runtime.InteropServices;

static class Interactive
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern uint GetConsoleProcessList(uint[] processList, uint count);

    static bool? _owns;

    /// <summary>
    /// True when this process is the ONLY one attached to its console — which means Windows
    /// created the window for us, i.e. Explorer launched it by double-click or drag-and-drop.
    /// Run from a shell, the shell is attached to the same console and the count is >= 2.
    ///
    /// This is what distinguishes "the window will disappear when I return" from "the user is
    /// sitting in a terminal and would find a pause prompt obnoxious".
    /// </summary>
    public static bool OwnsConsole
    {
        get
        {
            if (_owns == null)
            {
                try
                {
                    var buf = new uint[8];
                    _owns = GetConsoleProcessList(buf, (uint)buf.Length) <= 1;
                }
                catch { _owns = false; }   // no console at all (redirected/CI): never pause
            }
            return _owns.Value;
        }
    }

    /// <summary>Set when the menu exited because the user chose to quit. They have already
    /// said they are done, so a further "press Enter" is one keystroke of nagging.</summary>
    public static bool ExitedCleanly;

    /// <summary>Hold the window open so the result is readable. Matters most on FAILURE —
    /// that is exactly when there is something to read.</summary>
    public static void PauseIfOwned()
    {
        if (!OwnsConsole || ExitedCleanly) return;
        Console.WriteLine();
        Console.Write("Press Enter to close...");
        try { Console.ReadLine(); } catch { /* no stdin; nothing to wait for */ }
    }

    /// <summary>
    /// Prompt and read a line, trimmed. Returns NULL on end-of-input, and callers must treat
    /// that as "stop asking" — collapsing it to "" makes a menu loop forever the moment stdin
    /// closes, spinning on an unanswerable prompt.
    /// </summary>
    public static string Ask(string prompt)
    {
        Console.Write(prompt);
        return Console.ReadLine()?.Trim();
    }

    /// <summary>
    /// Ask for the skin folder. Dropping a folder into a console window pastes its path, and
    /// Windows quotes it when it contains spaces, so the quotes come off here rather than
    /// becoming a baffling "does not exist".
    /// </summary>
    public static string AskForSkinFolder()
    {
        Console.WriteLine("  Drag your skin folder into this window and press Enter, or paste its path.");
        Console.WriteLine("  It needs to contain a skin.json.");
        Console.WriteLine();
        var line = Ask("  skin folder> ");
        if (line == null) return null;                       // EOF
        if (line.Length >= 2 && line.StartsWith('"') && line.EndsWith('"'))
            line = line.Substring(1, line.Length - 2);
        Console.WriteLine();
        return line.Trim();
    }
}
