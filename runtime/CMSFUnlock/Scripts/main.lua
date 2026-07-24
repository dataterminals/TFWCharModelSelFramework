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
-- The single thing allowed off the game thread is a read-only FindAllOf presence check that
-- gates whether to hop on at all (see anySelectorResident below). It constructs nothing,
-- reads no property and calls no method, so the v0.1.1 failure — off-thread writes silently
-- not taking — cannot apply to it. Every actual read/write/call still runs on the game thread.
--
-- WHY THE GATE EXISTS. FindAllOf is a full walk of the object array. Running the whole poll
-- body inside ExecuteInGameThread paid for that walk ON THE GAME THREAD every second forever,
-- which is a frame hitch at the poll cadence whether or not a skin menu is anywhere near — the
-- selector only exists in the ready room, not in a raid. The gate keeps the game thread idle
-- until there is genuinely a selector to act on.
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
local function slotState(t)
    local row
    pcall(function() row = tostr(t.SkinRow.RowName) end)
    if not row then return nil end
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

-- Returns applied, seen, hidden, restored. MUST be called on the game thread.
local function apply(verbose)
    local found = FindAllOf(WIDGET)
    if not found then
        if verbose then log("no skin selector in memory — open the skin menu first") end
        return 0, 0, 0
    end

    local applied, seen, pruned, restored = 0, 0, 0, 0
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

            -- After Init(), which rebuilds the tiles and so undoes any earlier prune.
            -- Runs on every pass, not only when the filter changed: reopening the menu
            -- repopulates the WrapBox without necessarily re-setting the flag.
            local h, r = prune(w)
            pruned, restored = pruned + h, restored + r

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
                -- than a fresh FindAllOf. (The old standalone reportCount() is gone.)
                reportCountForWidget(w)
            end
        end
    end
    if verbose and seen > 0 and applied == 0 then
        log(string.format("%d selector(s) were already unfiltered", seen))
    end
    return applied, seen, pruned, restored
end

-- The off-thread presence gate. FindAllOf here is the ONE UObject read allowed off the game
-- thread (see the RULE at the top): it reads no property and calls no method, so it cannot hit
-- the v0.1.1 off-thread-write failure — it only asks the object array whether a selector even
-- exists yet. When it does not (a raid, a load screen, anywhere but the ready room) the poll
-- returns without ever touching the game thread, which is the whole fix for the 1 Hz hitch.
-- Every read/write/call that follows still happens on the game thread inside apply().
local function anySelectorResident()
    local found = FindAllOf(WIDGET)
    return found ~= nil and next(found) ~= nil
end

LoopAsync(POLL_MS, function()
    -- Cheap off-thread check first; only hop onto the game thread when there is a selector to
    -- act on. apply() re-runs FindAllOf on the game thread (its handles must be game-thread
    -- ones) and folds the count report in — so a resident menu costs one on-thread scan, and
    -- an absent one costs zero.
    if enabled and anySelectorResident() then
        -- The wrapper that v0.1 was missing.
        ExecuteInGameThread(function()
            local applied, _, pruned, restored = apply(false)
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
    end
    return false      -- never stop
end)

-- Applies immediately AND reports, so running it always does something visible. v0.1 made
-- this a bare toggle, which looked broken because it produced no effect on its own.
RegisterConsoleCommandHandler("cmsfunlock", function()
    enabled = true
    ExecuteInGameThread(function()
        local applied, seen, pruned, restored = apply(true)
        log(string.format("apply: %d changed / %d selector(s) found, %d slot(s) hidden",
            applied, seen, pruned))
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

log("loaded — selector will list every skin, and unclaimed CMSF slots are hidden.")
log("  `cmsfunlock` force + report   `cmsfoff` disable   `cmsfnoprune` show unclaimed slots")
