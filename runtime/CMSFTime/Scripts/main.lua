-- CMSF timing harness — how much does a deep slot pool cost the skin menu?
--
-- Slot paths under /Game/CMSF/ are a permanent public ABI, so pool depth has to be chosen
-- once and lived with. Download size stopped mattering when sentinel portraits went away
-- (~1 KB/slot), and menu clutter stopped mattering when rung 9 landed. What is left is
-- whether the selector gets slower, and that was a guess. This measures it.
--
-- WHAT IS BEING TIMED. WBP_SkinSelection.Init() is the rebuild: 00-findings.md established
-- that the selector iterates DT_SkinUIData rows and shows a row when its Skin mesh path is
-- in the character's roster. So the cost scales with TOTAL row count across all six
-- characters, not with the depth of the one being viewed — which is why the stress pak
-- fills every character rather than just Scav Girl.
--
-- HOW TO READ IT. Run `cmsftime` with the stress pak on, then again with it off (the
-- `CMSFUnlock ONLY (control)` mod is exactly this baseline). Vanilla Scav Girl unfiltered
-- lists 7. The delta between the two Init() figures is what a deep pool costs, every time
-- the player opens the menu.
--
-- SAFETY. Init() is a no-arg UFunction the game itself calls constantly, and CMSFUnlock has
-- called it on every poll since v0.1.1. Everything here is game-thread wrapped and pcall'd.
-- Nothing is written.

local WIDGET = "WBP_SkinSelection_C"
local REPS = 5      -- Init() is fast enough that one sample is mostly scheduler noise

local function log(s) print("[CMSFTime] " .. tostring(s) .. "\n") end

local function firstSelector()
    local found = FindAllOf(WIDGET)
    if not found then return nil end
    for _, w in pairs(found) do
        if w:IsValid() then
            -- Only a populated selector is worth timing; an empty one skips the work.
            local n = 0
            pcall(function()
                local kids = w.SkinOptions:GetAllChildren()
                n = kids and #kids or 0
            end)
            if n > 0 then return w, n end
        end
    end
    return nil
end

RegisterConsoleCommandHandler("cmsftime", function()
    ExecuteInGameThread(function()
        local w, tiles = firstSelector()
        if not w then
            log("no populated skin selector — open the skin menu first, then re-run")
            return
        end

        local t0 = os.clock()
        local ok = true
        for _ = 1, REPS do
            if not pcall(function() w:Init() end) then ok = false break end
        end
        local ms = (os.clock() - t0) * 1000 / REPS

        if not ok then
            log("Init() threw — measurement abandoned")
            return
        end
        log(string.format("Init() over %d tile(s): %.2f ms  (mean of %d)", tiles, ms, REPS))
        log("  now run again with the stress pak DISABLED for the baseline")
    end)
    return true
end)

-- ---------------------------------------------------------------------------------------
-- What does ONE FindAllOf walk cost?
--
-- CMSFUnlock's poll is built out of this call, and every decision about it so far has been
-- made on reasoning rather than a number. v0.2.0 moved the walk off the game thread on the
-- theory that on-thread was the cost; a player reported the hitch was better but still there,
-- in raids too, so the walk itself is not free wherever it runs. v0.2.1 backs the idle poll
-- off to one walk per 8 s. Whether 8 s is right, generous, or nowhere near enough depends on
-- a figure nobody has measured.
--
-- HOW TO READ IT. Run it twice, and the second run is the important one:
--   * in the READY ROOM, where the selector is resident and the walk finds something
--   * in a RAID, where it finds nothing and therefore cannot early-out — this is the case
--     the backoff exists for, and the one the player is complaining about
-- A walk that costs a fraction of a millisecond means the backoff is over-cautious and the
-- remaining hitch is somewhere else entirely. A walk in the multiple-milliseconds range is a
-- dropped frame every time it lands, and says the poll has to go away completely rather than
-- merely slow down.
--
-- SAFETY. FindAllOf is a read. This constructs nothing, writes nothing, and calls no method
-- on anything it finds — the same read-only presence check CMSFUnlock's gate already does,
-- just timed. It runs on the game thread because that is the number that matters: what the
-- walk costs where it can actually cause a hitch.
local SCAN_REPS = 20

RegisterConsoleCommandHandler("cmsfscan", function()
    ExecuteInGameThread(function()
        local t0 = os.clock()
        local last
        for _ = 1, SCAN_REPS do last = FindAllOf(WIDGET) end
        local ms = (os.clock() - t0) * 1000 / SCAN_REPS

        -- #found is unreliable on the table UE4SS hands back; count it by walking.
        local n = 0
        if last then for _ in pairs(last) do n = n + 1 end end

        log(string.format("FindAllOf(%s): %.3f ms/walk  (%d found, mean of %d)",
            WIDGET, ms, n, SCAN_REPS))
        if n == 0 then
            log("  0 found — this is the raid case, the one the idle backoff is sized against")
        else
            log("  now run it again in a raid, where the walk cannot early-out")
        end
    end)
    return true
end)

log("loaded.  `cmsftime` Init() cost (open a skin menu first)   `cmsfscan` FindAllOf cost")
