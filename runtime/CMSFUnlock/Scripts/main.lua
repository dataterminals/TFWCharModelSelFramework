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
-- RULE: every line that reads, writes, or CALLS a UObject runs inside ExecuteInGameThread.
-- No exceptions. (v0.2.0–v0.2.1 carved out one — an off-thread FindAllOf presence gate; field
-- test #2 measured an asset template keeping that gate permanently true, so it bought nothing
-- and cost a second 35 ms walk per scan. v0.2.2 removed it and the rule is absolute again.)
--
-- WHY THE GATE EXISTED (v0.2.0 — removed in v0.2.2, see that stratum below).
-- FindAllOf is a full walk of the object array. Running the whole poll
-- body inside ExecuteInGameThread paid for that walk ON THE GAME THREAD every second forever,
-- which is a frame hitch at the poll cadence whether or not a skin menu is anywhere near — the
-- selector only exists in the ready room, not in a raid. The gate keeps the game thread idle
-- until there is genuinely a selector to act on.
--
-- v0.2.1 — THE GATE WAS NOT ENOUGH. Player report against v0.2.0: the hitch was clearly
-- better, and clearly still there — in raids as well as the ready room. So "on the game
-- thread" was never the whole cost. FindAllOf walks the ENTIRE object array, and doing that
-- once a second forever evicts a lot of cache and contends with the game thread even from
-- off it. The gate removed the on-thread walk where no selector exists. It did not remove
-- the walk.
--
-- So the idle poll now BACKS OFF. The interval between scans doubles every time no selector
-- is found, up to IDLE_MAX_TICKS, and snaps back to every tick the moment one appears. A raid
-- settles at one walk per 8 s rather than 60 per minute. What that costs is up to 8 s before a
-- freshly-entered ready room gets unfiltered — which self-corrects on the first scan that does
-- land, long before anyone has navigated to the skin menu, and the manual `cmsfunlock` is
-- still there if it ever does not.
--
-- STILL OUTSTANDING (as of v0.2.1). A ready room with a selector resident still pays one
-- on-thread walk per second, because apply() must re-run FindAllOf on the game thread.
-- Removing that needs an event to replace the poll entirely — a map-load hook or
-- NotifyOnNewObject — neither of which has been verified against this UE4SS build. Do not
-- ship one on reasoning alone: that is precisely how v0.1 shipped a path that did nothing.
-- `cmsfscan` in the CMSFTime dev mod measures what a single walk actually costs, so the next
-- move can be sized off a number instead of an argument.
--
-- v0.2.2 — FIELD TEST #2 PUT NUMBERS AND NAMES ON ALL OF IT (docs/09-stutter.md).
--   * One walk costs ~35 ms ON the game thread on the dev rig — two-plus dropped frames at
--     60 fps every time one lands. The cadence was never the whole story; the walk is too
--     expensive to run routinely at all.
--   * FindAllOf finds FIVE selectors in the frontend: four live panels (GameInstance-owned,
--     built at the MAIN MENU ~7 s after boot, surviving into the hub with stable identities,
--     destroyed on raid entry) and one that is none of those — the WidgetTree TEMPLATE inside
--     the WBP_PlayerStatusWidget asset, resident from menu load to process exit. THAT held
--     the v0.2.0/v0.2.1 gate open everywhere, raids included, and disarmed the backoff within
--     seconds of boot. "The selector only exists in the ready room" was wrong twice over.
-- So v0.2.2: (1) live handles are CACHED — obtained on the game thread during a walk, then
-- revalidated with IsValid() on every pass, so the frontend steady state walks ZERO times;
-- (2) the backoff keys on "no LIVE selector" — the template no longer counts — so a raid pays
-- at worst one walk per IDLE_MAX_TICKS seconds; (3) the off-thread gate is REMOVED (see RULE).
-- The one genuinely new assumption: a cached handle whose object died reads as
-- IsValid() == false instead of detonating. Everything is pcall'd, and the next field test
-- exists to catch that before a player does. UNVERIFIED IN-GAME as written — house rule:
-- say so until it is loaded. The endgame is still v0.3 event-driven construction hooks,
-- which the CMSFTime probe interrogates on this build.
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

-- Logged on load, because the only channel for a stutter report is someone reading it off
-- their console — and "better but not gone" against v0.2.0 was nearly attributed to the wrong
-- build. A tester should never have to guess which one they are running.
-- v0.2.3 — THE STUTTER WAS prune(), AND IT WAS NEVER THE POLL (field test #4, 2026-07-27).
-- Measured, finally, instead of argued. Three states felt at the frontend: `cmsfoff` quiet,
-- `cmsfunlock` stuttering, `cmsfnoprune` quiet again. That third state leaves the poll, the
-- enforcement and the 1 Hz cadence all running and disables only the tile inspection — so the
-- object-array walk that v0.2.0, v0.2.1 and v0.2.2 each went after is EXONERATED at the frontend,
-- and every one of those three fixes was aimed at the wrong function.
--
-- The cost: enforceOne calls prune(w) unconditionally every pass, and prune called slotState on
-- every tile, whose icon chain is four wrapped reads plus a GetFullName() string build. Four
-- panels x 32 CMSF tiles = ~640 reflective operations and 128 GetFullName() calls PER SECOND on
-- the game thread. Verbose enforcement measured ~18 ms per panel, ~72 ms for the set — twice
-- field test #2's 35 ms walk, and nobody had ever measured it.
--
-- Why it hid for four versions: prune reports counts, and the loop logs `hid N` only when N > 0,
-- i.e. only when a visibility actually CHANGED. Steady state changes nothing, so 128 tile
-- inspections per second printed absolutely nothing. Field test #3 read that silence as proof the
-- per-pass path was cheap. This file's own "suspect nobody has ruled out" note predicted exactly
-- this failure mode and named Init() — one line above the function that was really doing it.
--
-- The fix below caches the VERDICT by row name. See the note over verdictByRow for what is
-- deliberately not cached, and why a tile-handle cache is NOT used (pooling).
local VERSION = "0.2.3"

local WIDGET = "WBP_SkinSelection_C"
local POLL_MS = 1000         -- the tick; the object-array scan runs on a backoff MULTIPLE of it
local IDLE_MAX_TICKS = 8     -- ceiling on that backoff, so an idle raid walks once per 8 s

local enabled = true
local quiet = false          -- set once the first successful apply has been reported
local pruning = true         -- rung 9; `cmsfnoprune` to disable

local function log(s) print("[CMSFUnlock] " .. tostring(s) .. "\n") end

-- ---------------------------------------------------------------------------------------
-- Rung 9 — collapse the tiles of CMSF slots no author has claimed.
--
-- THE CLAIM SIGNAL. A tile is WBP_SkinButton_C. Two of its properties matter:
--   SkinRow   an FDataTableRowHandle — SkinRow.RowName is the tile's exact DataTable row
--   SkinIcon  a UImage whose Brush.ResourceObject is the texture actually resolved
--
-- A CMSF slot's icon path is frozen: row CMSF.Girl.00 means /Game/CMSF/Girl/00/T_CMSF_Girl_00.
-- An author claims the slot by shipping a package there, so:
--   claimed    the icon resolves to that path        -> leave the tile alone
--   unclaimed  nothing is shipped there, and the icon resolves to something unrelated
--              entirely — measured 2026-07-21, unclaimed slots came back holding another
--              character's portrait, because WBP_SkinButton_C instances are POOLED across
--              the four ready-room panels and a failed resolve leaves the previous brush in
--              place. So the test is "does it match", never "is it null".
-- The expected path is derived from the row name, so this needs no slot table, no manifest,
-- and no author filename convention.
--
-- FAIL OPEN. Prune only on a positive reading: the row must parse AND the icon must be
-- readable AND it must not match. Anything unreadable leaves the tile visible. A stray
-- placeholder tile is always preferable to a hidden real skin.
--
-- v0.1 SAFETY. v0.1 rows are CMSF.<Char>.<folder-id>, which cannot match the two-digit slot
-- pattern below, so a registered v0.1 skin is never touched. v0.1's own --pool placeholders
-- ARE CMSF.<Char>.<NN>, and pruning those is what cmsf_build.py already expects.
--
-- SAFETY OF THE WRITE. SetVisibility takes one uint8 enum BY VALUE. It cannot type-confuse a
-- pointer dereference the way the object parameter that crashed probe v2 did — the same risk
-- class as the bool write above. The plain Visibility PROPERTY write was tried first and is a
-- silent no-op: it updates the UPROPERTY without Slate ever noticing.

local VIS_COLLAPSED = 1      -- ESlateVisibility::Collapsed, which also surrenders layout space
-- Restoring means SelfHitTestInvisible, NOT Visible(0): that is what these tiles read as
-- when the game builds them, so anything else would be this mod inventing a state.
local VIS_DEFAULT = 4        -- ESlateVisibility::SelfHitTestInvisible

-- This UE4SS build hands struct members and array elements back as RemoteUnrealParam
-- WRAPPERS. Calling a UObject method on one throws; indexing further into one silently
-- yields NIL, which reads as a confident wrong answer rather than an error. :get() unwraps.
-- (:get() is a read. :set() on a hooked return is the banned one, and is not used.)
local function unwrap(v)
    if v == nil then return nil end
    local out
    if pcall(function() out = v:get() end) and out ~= nil then return out end
    return v
end

local function tostr(v)
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    if pcall(function() s = tostring(v) end) and type(s) == "string" then return s end
    return nil
end

-- Returns the icon path a claimed slot MUST resolve to, or nil if this is not a CMSF slot row.
local function expectedIcon(row)
    local char, slot = row:match("^CMSF%.(%a+)%.(%d%d)$")
    if not char then return nil end
    return string.format("/Game/CMSF/%s/%s/T_CMSF_%s_%s", char, slot, char, slot)
end

-- Tri-state, and the third state is load-bearing:
--   true   positively an UNCLAIMED CMSF slot   -> hide
--   false  positively a CLAIMED CMSF slot      -> show
--   nil    not a CMSF slot, or cannot tell yet -> leave alone
--
-- `nil` on an unresolved icon is the whole fix for the claim race. An author's texture is
-- not necessarily resolved on the menu's first population: measured 2026-07-21, the first
-- pass hid all 32 Girl slots including the one Octogirl had claimed, and a panel rebuilt
-- ~6 s later got it right. Treating "not loaded yet" as "nothing shipped here" hides a real
-- skin, which is the exact failure the fail-open rule exists to prevent.
--
-- v0.2.3 — DERIVED ONCE PER ROW, NOT ONCE PER PASS. This is the stutter fix; see the v0.2.3
-- stratum at the top of the file for the measurement that found it.
--
-- The saving rests on the verdict being STABLE for the session: row CMSF.Girl.00 either has a
-- package at /Game/CMSF/Girl/00/T_CMSF_Girl_00 or it does not, and a pak cannot mount mid-session.
-- A resolved answer is therefore cached by row name and the icon chain — three wrapped reads and
-- a GetFullName() string build, the expensive part — never runs for that row again.
--
-- WHAT IS DELIBERATELY NOT CACHED: a nil verdict. nil means "cannot tell YET" — the claim race
-- where an author's texture has not resolved on the menu's first population (measured 2026-07-21:
-- the first pass misread all 32 Girl slots, a rebuild ~6 s later got it right). Caching nil would
-- freeze a real skin as hidden for the rest of the session, which is precisely the failure the
-- fail-open rule exists to prevent. Absence from this table IS the retry.
--
-- WHY NOT CACHE PER TILE, which would also skip the Visibility read: WBP_SkinButton_C instances
-- are POOLED across the four ready-room panels (see the rung 9 note above), so a tile handle does
-- not identify a slot — the same object turns up later holding a different SkinRow. The row must
-- be re-read every pass to know what a tile currently IS. A handle-keyed cache would also depend
-- on unwrap() returning a stable Lua key for the same UObject across passes, which has never been
-- measured. Not shipping that on reasoning; measure it first, then consider it for v0.3.
local verdictByRow = {}

-- The expensive half, run only for a row whose verdict is not yet known.
local function deriveVerdict(t, row)
    local want = expectedIcon(row)
    if not want then return nil end             -- vanilla row: bails before touching a brush

    local img, brush, res, name
    pcall(function() img = unwrap(t.SkinIcon) end)
    if img == nil then return nil end
    pcall(function() brush = unwrap(img.Brush) end)
    if brush == nil then return nil end
    pcall(function() res = unwrap(brush.ResourceObject) end)
    if res == nil then return nil end           -- not resolved YET — do not read as unclaimed
    pcall(function() name = tostr(res:GetFullName()) end)
    if not name then return nil end
    return name:find(want, 1, true) == nil
end

-- Caching is ASYMMETRIC, because the two possible errors are not equally bad.
--
-- The nil guard in deriveVerdict handles the claim race where a texture has not resolved at all.
-- It does NOT handle the other pooling hazard this file already documents: a failed or pending
-- resolve leaves the PREVIOUS brush in place, so a claimed slot can briefly read as a confident,
-- non-nil, WRONG "unclaimed". Under the old derive-every-pass code that was self-healing — prune
-- drives tiles bidirectionally, so the next pass restored the tile. Cache it and the self-heal
-- never comes: a real skin stays hidden for the session. That is the one outcome rung 9 must
-- never produce.
--
-- So: "claimed" (show) is cached on sight, because showing is the fail-open direction and a
-- wrong show costs a stray placeholder tile. "unclaimed" (hide) must read the same way
-- HIDE_CONFIRM times before it is trusted forever; a transient foreign brush will not survive
-- that, and a genuinely empty slot converges in three passes and then costs nothing again.
local HIDE_CONFIRM = 3
local hideStreak = {}

local function slotState(t)
    local row
    pcall(function() row = tostr(t.SkinRow.RowName) end)
    if not row then return nil end

    local cached = verdictByRow[row]
    if cached ~= nil then return cached end       -- false is a real answer here, hence ~= nil

    local st = deriveVerdict(t, row)
    if st == false then
        verdictByRow[row] = false                -- fail-open direction: trust it immediately
        hideStreak[row] = nil
    elseif st == true then
        local streak = (hideStreak[row] or 0) + 1
        hideStreak[row] = streak
        if streak >= HIDE_CONFIRM then verdictByRow[row] = true end
    else
        hideStreak[row] = nil                    -- unreadable: the streak starts over
    end
    return st
end

-- Returns hidden, restored. MUST be called on the game thread.
local function prune(w)
    if not pruning then return 0, 0 end
    local kids
    if not pcall(function() kids = w.SkinOptions:GetAllChildren() end) then return 0, 0 end
    if not kids then return 0, 0 end
    local n, restored = 0, 0
    for _, raw in pairs(kids) do
        local t = unwrap(raw)
        local ok = false
        pcall(function() ok = t:IsValid() end)
        if ok then
            local st = slotState(t)
            if st ~= nil then
                -- BIDIRECTIONAL on purpose. An earlier version only ever collapsed, so a
                -- tile misread once — during the claim race above — stayed hidden for the
                -- rest of the session. Driving the tile to its correct state every pass
                -- makes a transient misread self-correct on the next poll.
                local want = st and VIS_COLLAPSED or VIS_DEFAULT
                local vis
                pcall(function() vis = t.Visibility end)
                if vis ~= want and pcall(function() t:SetVisibility(want) end) then
                    if st then n = n + 1 else restored = restored + 1 end
                end
            end
        end
    end
    return n, restored
end

-- Auto-report the populated list size when it changes. SkinOptions has no children until the
-- skin panel is actually opened, and the panel draws OVER the UE4SS console — so asking for a
-- manual command at the right moment does not work in practice; reporting on change means
-- opening the menu is the whole interaction and the log records the number by itself.
--
-- Takes a selector the caller ALREADY has in hand. This used to re-run FindAllOf (a second
-- full object-array scan every poll); folded into apply()'s existing walk so the poll scans
-- once, not twice. MUST be called on the game thread.
local lastCount = -1
local function reportCountForWidget(w)
    local n = -1
    pcall(function()
        local kids = w.SkinOptions:GetAllChildren()
        n = kids and #kids or -1
    end)
    -- Only populated selectors are interesting, and only when the number moves.
    if n > 0 and n ~= lastCount then
        lastCount = n
        log(string.format("skin menu open: %d skin(s) listed", n))
    end
end

-- The per-widget enforcement body, shared by the walk path and the cached path.
-- MUST be called on the game thread. Returns appliedDelta, prunedDelta, restoredDelta.
local function enforceOne(w, verbose)
    local applied = 0
    local locked, readOk = nil, false
    readOk = pcall(function() locked = w.SelectLockedSkinsOnly end)

    -- Act when it is filtered, and also when the flag cannot be read — being
    -- permissive here is harmless (clearing an already-clear flag is a no-op) and
    -- avoids the failure mode where an unreadable property silently disables the
    -- whole mod, which is close to what v0.1 did.
    if (not readOk) or locked ~= false then
        pcall(function() w.SelectLockedSkinsOnly = false end)
        pcall(function() w:Init() end)
        applied = 1
    end

    -- After Init(), which rebuilds the tiles and so undoes any earlier prune.
    -- Runs on every pass, not only when the filter changed: reopening the menu
    -- repopulates the WrapBox without necessarily re-setting the flag.
    local h, r = prune(w)

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
    else
        -- Poll path: report the count on change, reusing this same widget rather
        -- than a fresh FindAllOf.
        reportCountForWidget(w)
    end
    return applied, h, r
end

-- ---------------------------------------------------------------------------------------
-- v0.2.2 — live instances versus the asset template.
--
-- Field test #2 named everything FindAllOf returns here: four live panels rooted under
-- /Engine/Transient (runtime-constructed, GameInstance-owned), plus ONE object rooted under
-- /Game/ — the WidgetTree template stored inside the WBP_PlayerStatusWidget asset. A /Game/
-- root means asset-resident by definition: runtime widgets are constructed into transient
-- outers, never into a cooked package. The template must not count as "a selector is
-- present" — it is resident from menu load to process exit, and counting it is what held
-- every earlier gate open. An unreadable name fails OPEN (treated as live): wrongly polling
-- for a template costs a hitch, wrongly ignoring a real selector makes the mod do nothing,
-- and v0.1 already demonstrated which of those is worse.
local function isLiveInstance(w)
    local nm
    pcall(function() nm = w:GetFullName() end)
    if nm ~= nil and type(nm) ~= "string" then nm = tostr(nm) end
    if not nm then return true end
    return nm:find(" /Game/", 1, true) == nil
end

-- Game-thread handles from the last walk. Revalidated with IsValid() before EVERY use; one
-- stale entry dumps the lot and forces a walk. The handles were obtained on the game thread
-- and are only ever touched on the game thread, so the RULE holds — this cache is what lets
-- the frontend run walk-free at steady state.
local liveCache = {}

-- Returns applied, seen, pruned, restored, live. MUST be called on the game thread.
-- This is the WALK path: one full FindAllOf (~35 ms on the dev rig — field test #2), then
-- enforcement on everything found, and the live cache is rebuilt as a side effect. The
-- template IS still enforced here (a cleared flag on the template is inherited by future
-- instances, which is welcome) — but only once per walk, no longer once per second.
local function apply(verbose)
    liveCache = {}
    local found = FindAllOf(WIDGET)
    if not found then
        if verbose then log("no skin selector in memory — open the skin menu first") end
        return 0, 0, 0, 0, 0
    end

    local applied, seen, pruned, restored, live = 0, 0, 0, 0, 0
    for _, w in pairs(found) do
        if w:IsValid() then
            seen = seen + 1
            if isLiveInstance(w) then
                live = live + 1
                liveCache[#liveCache + 1] = w
            end
            local a, h, r = enforceOne(w, verbose)
            applied, pruned, restored = applied + a, pruned + h, restored + r
        end
    end
    if verbose and seen > 0 and applied == 0 then
        log(string.format("%d selector(s) were already unfiltered", seen))
    end
    return applied, seen, pruned, restored, live
end

-- One poll pass. MUST be called on the game thread. The cached path costs a handful of
-- property reads on four widgets — microseconds; the walk path costs the full ~35 ms scan.
-- Steady state in the frontend is the cached path every time: the four panels are
-- GameInstance-owned and keep their identities from the main menu through the hub (measured,
-- field test #2), so the cache lives until a raid load tears the frontend down. Returns the
-- aggregates the loop logs, plus live for the backoff decision.
local function pollOnce()
    if #liveCache > 0 then
        local allValid = true
        for _, w in ipairs(liveCache) do
            local ok = false
            pcall(function() ok = w:IsValid() end)
            if not ok then
                allValid = false
                break
            end
        end
        if allValid then
            local applied, pruned, restored = 0, 0, 0
            for _, w in ipairs(liveCache) do
                local a, h, r = enforceOne(w, false)
                applied, pruned, restored = applied + a, pruned + h, restored + r
            end
            return applied, pruned, restored, #liveCache
        end
        -- Something in the cache died — a map change. Fall through to a walk, which either
        -- refills the cache (back in the frontend) or reports zero live (raid), and the
        -- backoff takes it from there.
        liveCache = {}
    end
    local applied, _, pruned, restored, live = apply(false)
    return applied, pruned, restored, live
end

-- Backoff state. `scanEvery` is in ticks, not milliseconds, because LoopAsync's interval is
-- fixed at registration — so the tick stays at 1 Hz and we simply skip most of them. Skipping
-- is the entire saving: waking the timer thread is free, and walking the object array is not.
local scanEvery = 1
local ticksWaited = 0

LoopAsync(POLL_MS, function()
    if not enabled then return false end

    -- Most ticks end here, having touched nothing at all.
    ticksWaited = ticksWaited + 1
    if ticksWaited < scanEvery then return false end
    ticksWaited = 0

    -- Everything UObject happens on the game thread — the wrapper v0.1 was missing, and the
    -- RULE, exception-free since v0.2.2. scanEvery is written in there and read out here;
    -- UE4SS serialises access to the one Lua state, and the worst a stale read could cost is
    -- a single early or late scan.
    ExecuteInGameThread(function()
        local applied, pruned, restored, live = pollOnce()

        if live > 0 then
            -- Live panels on hand: enforce at full cadence. prune() in particular has to
            -- stay quick behind Init(), which rebuilds the tiles and undoes the previous
            -- pass — and at 1 Hz the work is the CACHED path, property reads, not a walk.
            scanEvery = 1
        else
            -- No live selector — a raid, a load screen, the first seconds of boot. Ask again
            -- on the doubling schedule. The asset template alone no longer holds the cadence
            -- at 1 Hz; counting it is what kept v0.2.0/v0.2.1 walking every second
            -- everywhere, raids included (field test #2).
            scanEvery = math.min(scanEvery * 2, IDLE_MAX_TICKS)
        end

        if applied > 0 and not quiet then
            quiet = true
            log("selector unfiltered (will keep it that way)")
        end
        -- Tiles, not slots: the ready room holds four selector panels, so each slot
        -- accounts for four tiles and the number is a multiple of what is on screen.
        if pruned > 0 then
            log(string.format("hid %d unclaimed CMSF tile(s)", pruned))
        end
        -- Worth its own line: a restore means a slot was hidden while its author's
        -- texture was still resolving, and the next pass corrected it.
        if restored > 0 then
            log(string.format("restored %d claimed CMSF tile(s)", restored))
        end
    end)
    return false      -- never stop
end)

-- Applies immediately AND reports, so running it always does something visible. v0.1 made
-- this a bare toggle, which looked broken because it produced no effect on its own.
RegisterConsoleCommandHandler("cmsfunlock", function()
    enabled = true
    -- Re-arm the poll at full speed. Running this by hand means someone is standing at the
    -- menu right now, and leaving the backoff wherever an idle raid parked it would make the
    -- next automatic pass up to IDLE_MAX_TICKS late.
    scanEvery, ticksWaited = 1, 0
    ExecuteInGameThread(function()
        local applied, seen, pruned, restored, live = apply(true)
        log(string.format("apply: %d changed / %d selector(s) found (%d live), %d slot(s) hidden",
            applied, seen, live, pruned))
        if restored > 0 then log(string.format("  restored %d claimed tile(s)", restored)) end
    end)
    return true
end)

RegisterConsoleCommandHandler("cmsfoff", function()
    enabled = false
    log("OFF — vanilla behaviour (DLC skins only) until `cmsfunlock`")
    return true
end)

-- An escape hatch that does not require reinstalling: if pruning ever hides something it
-- should not, this brings it back on the next menu open without touching the unlock.
RegisterConsoleCommandHandler("cmsfnoprune", function()
    pruning = false
    log("pruning OFF — unclaimed CMSF slots will show. Reopen the skin menu.")
    return true
end)

-- THE MISSING COUNTERPART, and it cost a session's worth of confusion (field test #4).
-- `cmsfnoprune` was one-way: nothing in this file ever set `pruning` back to true, and
-- `cmsfunlock` re-arms only the POLL. So once a tester ran cmsfnoprune, pruning stayed off for
-- the rest of the process — through every later cmsfunlock, through a raid, through everything.
-- A tester cycling "off / rearmed / noprune" in good faith was comparing three prune-OFF states
-- against nothing, and reasonably reported no difference anywhere. The single prune-ON sample in
-- that whole session was ten seconds wide, which is far too thin to hang a diagnosis on.
--
-- The caches are cleared on the way in so each toggle-on is a COLD measurement rather than a warm
-- one — otherwise a re-test silently benefits from verdicts derived before the switch, which is
-- exactly the confound v0.2.3 is supposed to be measured against.
RegisterConsoleCommandHandler("cmsfprune", function()
    pruning = true
    verdictByRow, hideStreak = {}, {}
    log("pruning ON, verdict cache cleared — reopen the skin menu, give it ~5 s, then judge")
    return true
end)

log("v" .. VERSION .. " loaded — selector will list every skin, and unclaimed CMSF slots are hidden.")
log("  `cmsfunlock` force + report   `cmsfoff` disable")
log("  `cmsfnoprune` / `cmsfprune` toggle tile pruning — the A/B for the stutter")
