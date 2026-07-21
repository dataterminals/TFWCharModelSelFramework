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

log("loaded. Open a skin menu, then run `cmsftime`.")
