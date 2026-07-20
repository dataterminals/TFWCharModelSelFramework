-- CMSFUnlock — make the skin selector list every skin the character actually has.
--
-- WHY THIS IS NEEDED
-- The Forever Winter's skin selector only offers entitlement-gated DLC skins. The shipped
-- base skins are not selectable there at all: pick a DLC skin and there is no way back to a
-- base one until you die in a raid, at which point the game randomly reassigns you.
--
-- The mechanism is a single bool on WBP_SkinSelection, SelectLockedSkinsOnly, which decides
-- whether the widget calls the component's GetUnlockedSkins (entitled only) or
-- GetAvailableSkins (everything). Measured live: 2 entries vs 7. Clearing it and rebuilding
-- gives the full list — including any skin CMSF appended to the roster.
--
-- So this mod is what makes CMSF-added skins reachable. It is also worth having on its own:
-- it fixes the base-skins-are-unreachable annoyance even with no custom skins installed.
--
-- WHY IT IS WRITTEN THIS CONSERVATIVELY
-- An earlier version crashed the client (EXCEPTION_ACCESS_VIOLATION, stack inside
-- UE4SS.dll) by calling the native SetNewSkin with a wrongly-typed object, and another
-- version caused frame drops by hooking GetAvailableSkins, which the selector queries
-- across four ready-room player panels.
--
-- The rules that came out of that, and that this file obeys:
--   * Never invoke a native UFunction taking an object or struct parameter. `pcall` does
--     NOT protect against a C++ access violation — it catches Lua errors only, and the
--     process is gone before Lua ever sees the fault.
--   * Never hook a per-frame function.
--   * Writing a PLAIN property (a bool) and calling a NO-ARGUMENT UFunction the game calls
--     constantly are both safe: neither can type-confuse a native call.
--
-- Everything below is one bool write plus Init(), which is the exact operation observed
-- working in testing.

local WIDGET = "WBP_SkinSelection_C"
local POLL_MS = 1000

local enabled = true
local reported = 0

local function log(s) print("[CMSFUnlock] " .. tostring(s) .. "\n") end

local function enforce()
    if not enabled then return end
    local found = FindAllOf(WIDGET)
    if not found then return end
    for _, w in pairs(found) do
        if w:IsValid() then
            local locked = false
            local ok = pcall(function() locked = w.SelectLockedSkinsOnly end)
            -- Only act when the flag has actually come back true, i.e. once per menu
            -- build. Without this check the list would be rebuilt every tick.
            if ok and locked == true then
                pcall(function() w.SelectLockedSkinsOnly = false end)
                pcall(function() w:Init() end)
                if reported < 3 then
                    reported = reported + 1
                    log("selector unfiltered")
                end
            end
        end
    end
end

LoopAsync(POLL_MS, function()
    pcall(enforce)
    return false      -- never stop
end)

RegisterConsoleCommandHandler("cmsfunlock", function()
    enabled = not enabled
    log(enabled and "ON — selector will list every skin"
                or "OFF — vanilla behaviour (DLC skins only)")
    return true
end)

log("loaded — selector will list every skin for the character. Toggle with `cmsfunlock`.")
