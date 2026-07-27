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
-- FIELD TEST #1, 2026-07-26 (docs/09-stutter.md): the gate opened 7.5 s after launch, AT THE
-- MAIN MENU — the session never reached the hub — so something selector-classed is resident
-- from the frontend on, and it pins CMSFUnlock's poll at one on-thread walk per second. WHAT
-- it is decides the next fix, and a count cannot say. So this prints the NAME of everything
-- found:
--   Default__WBP_SkinSelection_C   the class-default object, mere collateral of the class
--                                  being loaded -> teach residency to ignore CDOs
--   anything else                  a real constructed widget at the menu -> the whole
--                                  absence-based gate design is wrong, not just its filter
--
-- SAFETY. FindAllOf is a read, and the name pass calls only GetFullName()/IsValid() — no-arg
-- calls of the same class rung 9 already relies on, all on the game thread, where the number
-- matters: what the walk costs where it can actually cause a hitch.
local SCAN_REPS = 20

-- GetFullName can hand back an FString-ish rather than a Lua string; coerce or admit failure.
local function fullname(o)
    local s
    if not pcall(function() s = o:GetFullName() end) then return "<GetFullName threw>" end
    if type(s) == "string" then return s end
    local t
    if pcall(function() t = s:ToString() end) and type(t) == "string" then return t end
    return tostring(s)
end

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

        -- Name everything: the fix hangs on asset-resident versus live (see header).
        local firstObj
        if last then
            local shown = 0
            for _, o in pairs(last) do
                if not firstObj then firstObj = o end
                shown = shown + 1
                if shown > 8 then log("  ... more not shown"); break end
                local ok = false
                pcall(function() ok = o:IsValid() end)
                log(string.format("  found: %s%s", fullname(o),
                    ok and "" or "   [IsValid()=false]"))
            end
        end

        -- The exact class path, for v0.3's NotifyOnNewObject registration — the repo never
        -- recorded it, and guessing package paths is how mods break across game patches.
        if firstObj then
            local cls
            pcall(function() cls = firstObj:GetClass() end)
            if cls ~= nil then log("  class: " .. fullname(cls)) end
        end

        if n == 0 then
            log("  0 found — the backoff is genuinely allowed to engage here")
        else
            log("  run this at the menu, in the hub, and in a raid — paste all three")
        end
    end)
    return true
end)

-- ---------------------------------------------------------------------------------------
-- v0.3 PROBE — can construction events replace the poll on THIS build (UE4SS 3.0.1-894)?
--
-- The endgame in docs/09-stutter.md is event-driven: no FindAllOf outside boot, ever. That
-- needs NotifyOnNewObject to actually fire here, which nobody has verified — and shipping an
-- unverified event path is the exact shape of the v0.1 failure. So: register on the UMG base
-- class (the selector's own BP class path was never recorded; cmsfscan now prints it), filter
-- by class name, and LOG ONLY. The object is mid-construction when this fires — the game has
-- not initialised it — so nothing here touches it beyond reading its name.
--
-- What the next session's log should show, if the mechanism works:
--   * a burst of NOTIFY lines with /Engine/Transient-rooted names when the frontend builds
--     its four panels (~7 s after boot), and again on every raid -> hub return
--   * possibly /Game/-rooted ones as the asset template loads — v0.3 must ignore those, the
--     same live-versus-template split CMSFUnlock v0.2.2 uses
-- Zero NOTIFY lines across a menu -> raid -> menu cycle = the mechanism is dead on this
-- build, and v0.3 falls back to gating on the hub map instead.
local notifySeen = 0
local okReg, errReg = pcall(function()
    NotifyOnNewObject("/Script/UMG.UserWidget", function(obj)
        local nm
        pcall(function() nm = obj:GetFullName() end)
        nm = tostring(nm)
        if nm:find("WBP_SkinSelection_C", 1, true) ~= nil then
            notifySeen = notifySeen + 1
            log(string.format("NOTIFY #%d: selector constructed: %s", notifySeen, nm))
        end
    end)
end)
if okReg then
    log("v0.3 probe armed: NotifyOnNewObject(/Script/UMG.UserWidget) registered")
else
    log("v0.3 probe DEAD on this build: " .. tostring(errReg))
end

log("loaded.  `cmsftime` Init() cost (open a skin menu first)   `cmsfscan` FindAllOf cost")
