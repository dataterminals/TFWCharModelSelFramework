-- CMSFUnlock — make the skin selector list every skin the character actually has.
--
-- WHY THIS IS NEEDED
-- The Forever Winter's skin selector only offers entitlement-gated DLC skins. The shipped
-- base skins are not selectable there at all: pick a DLC skin and there is no way back to a
-- base one until you die in a raid, at which point the game randomly reassigns you.
--
-- The mechanism is a single bool on WBP_SkinSelection, SelectLockedSkinsOnly, which decides
-- whether the widget calls GetUnlockedSkins (entitled only) or GetAvailableSkins
-- (everything). Measured live: 2 entries vs 7. Clearing it and rebuilding gives the full
-- list — including any skin CMSF appended to the roster.
--
-- v0.1.1 — THE BUG THAT MADE v0.1 DO NOTHING
-- v0.1 called its enforcement directly from LoopAsync. LoopAsync runs on its own thread,
-- and UObject property writes / UFunction calls made off the game thread do not reliably
-- take — the mod loaded, logged, and silently changed nothing. The manual command that had
-- worked during development wrapped the same code in ExecuteInGameThread; that wrapper was
-- lost when this was packaged from the probe, and the polled path was never verified
-- in-game before release.
--
-- RULE: every line that touches a UObject runs inside ExecuteInGameThread. No exceptions.
--
-- SAFETY RULES (each learned by breaking something)
--   * Never invoke a native UFunction taking an object or struct parameter. `pcall` does
--     NOT protect against a C++ access violation — it catches Lua errors only, and the
--     process is gone before Lua sees the fault. Passing LoadAsset's result to SetNewSkin
--     crashed the client outright.
--   * Never hook a per-frame function. A post-hook on GetAvailableSkins, which the selector
--     queries across four ready-room panels, caused visible frame drops.
--   * A plain bool write plus a NO-ARGUMENT UFunction call is safe: neither can
--     type-confuse a native call. That is all this file does.

local WIDGET = "WBP_SkinSelection_C"
local POLL_MS = 1000

local enabled = true
local quiet = false          -- set once the first successful apply has been reported

local function log(s) print("[CMSFUnlock] " .. tostring(s) .. "\n") end

-- Returns applied, seen. MUST be called on the game thread.
local function apply(verbose)
    local found = FindAllOf(WIDGET)
    if not found then
        if verbose then log("no skin selector in memory — open the skin menu first") end
        return 0, 0
    end

    local applied, seen = 0, 0
    for _, w in pairs(found) do
        if w:IsValid() then
            seen = seen + 1
            local locked, readOk = nil, false
            readOk = pcall(function() locked = w.SelectLockedSkinsOnly end)

            -- Act when it is filtered, and also when the flag cannot be read — being
            -- permissive here is harmless (clearing an already-clear flag is a no-op) and
            -- avoids the failure mode where an unreadable property silently disables the
            -- whole mod, which is close to what v0.1 did.
            if (not readOk) or locked ~= false then
                pcall(function() w.SelectLockedSkinsOnly = false end)
                pcall(function() w:Init() end)
                applied = applied + 1
            end

            -- Always report the list size when asked, not only when something changed.
            -- The poll usually gets there first, so the earlier "only on change" version
            -- printed nothing on a manual run and left the count to be eyeballed off a
            -- screenshot. This number is the actual verification: vanilla Scav Girl
            -- unfiltered is 7, so anything above that is an appended CMSF skin.
            if verbose then
                local n = -1
                pcall(function()
                    local kids = w.SkinOptions:GetAllChildren()
                    n = kids and #kids or -1
                end)
                if n >= 0 then
                    log(string.format("selector lists %d skin(s)%s", n,
                        n > 0 and "" or "  (open the skin menu, then re-run)"))
                end
            end
        end
    end
    if verbose and seen > 0 and applied == 0 then
        log(string.format("%d selector(s) were already unfiltered", seen))
    end
    return applied, seen
end

LoopAsync(POLL_MS, function()
    if enabled then
        -- The wrapper that v0.1 was missing.
        ExecuteInGameThread(function()
            local applied = apply(false)
            if applied > 0 and not quiet then
                quiet = true
                log("selector unfiltered (will keep it that way)")
            end
        end)
    end
    return false      -- never stop
end)

-- Applies immediately AND reports, so running it always does something visible. v0.1 made
-- this a bare toggle, which looked broken because it produced no effect on its own.
RegisterConsoleCommandHandler("cmsfunlock", function()
    enabled = true
    ExecuteInGameThread(function()
        local applied, seen = apply(true)
        log(string.format("apply: %d changed / %d selector(s) found", applied, seen))
    end)
    return true
end)

RegisterConsoleCommandHandler("cmsfoff", function()
    enabled = false
    log("OFF — vanilla behaviour (DLC skins only) until `cmsfunlock`")
    return true
end)

log("loaded — selector will list every skin. `cmsfunlock` to force + report, `cmsfoff` to disable.")
