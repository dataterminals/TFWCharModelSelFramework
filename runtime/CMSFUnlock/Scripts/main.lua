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

-- true only when the tile is positively identified as an UNCLAIMED CMSF slot.
local function isUnclaimed(t)
    local row
    pcall(function() row = tostr(t.SkinRow.RowName) end)
    if not row then return false end
    local want = expectedIcon(row)
    if not want then return false end

    local img, brush, res, name
    pcall(function() img = unwrap(t.SkinIcon) end)
    if img == nil then return false end
    pcall(function() brush = unwrap(img.Brush) end)
    if brush == nil then return false end
    pcall(function() res = unwrap(brush.ResourceObject) end)
    if res == nil then return true end          -- nothing resolved at all: unclaimed
    pcall(function() name = tostr(res:GetFullName()) end)
    if not name then return false end           -- unreadable -> fail open
    return name:find(want, 1, true) == nil
end

-- Returns how many tiles were newly collapsed. MUST be called on the game thread.
local function prune(w)
    if not pruning then return 0 end
    local kids
    if not pcall(function() kids = w.SkinOptions:GetAllChildren() end) then return 0 end
    if not kids then return 0 end
    local n = 0
    for _, raw in pairs(kids) do
        local t = unwrap(raw)
        local ok = false
        pcall(function() ok = t:IsValid() end)
        if ok then
            -- Cheap gate FIRST. This runs every poll for as long as the menu is open, and
            -- an already-collapsed tile needs no further work — so the steady state costs
            -- one byte read per tile instead of resolving every icon once a second. A
            -- visible vanilla tile is nearly as cheap: isUnclaimed bails at the row-name
            -- pattern, before it ever touches the brush.
            local vis
            pcall(function() vis = t.Visibility end)
            if vis ~= VIS_COLLAPSED and isUnclaimed(t) then
                if pcall(function() t:SetVisibility(VIS_COLLAPSED) end) then n = n + 1 end
            end
        end
    end
    return n
end

-- Returns applied, seen. MUST be called on the game thread.
local function apply(verbose)
    local found = FindAllOf(WIDGET)
    if not found then
        if verbose then log("no skin selector in memory — open the skin menu first") end
        return 0, 0, 0
    end

    local applied, seen, pruned = 0, 0, 0
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
            pruned = pruned + prune(w)

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
    return applied, seen, pruned
end

-- Auto-report the populated list size. SkinOptions has no children until the skin panel is
-- actually opened, and the panel draws OVER the UE4SS console — so asking for a manual
-- command at exactly the right moment does not work in practice. Reporting on change means
-- opening the menu is the whole interaction; the log records the number by itself.
local lastCount = -1
local function reportCount()
    local found = FindAllOf(WIDGET)
    if not found then return end
    for _, w in pairs(found) do
        if w:IsValid() then
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
    end
end

LoopAsync(POLL_MS, function()
    if enabled then
        -- The wrapper that v0.1 was missing.
        ExecuteInGameThread(function()
            local applied, _, pruned = apply(false)
            if applied > 0 and not quiet then
                quiet = true
                log("selector unfiltered (will keep it that way)")
            end
            -- Tiles, not slots: the ready room holds four selector panels, so each slot
            -- accounts for four tiles and the number is a multiple of what is on screen.
            if pruned > 0 then
                log(string.format("hid %d unclaimed CMSF tile(s)", pruned))
            end
            reportCount()
        end)
    end
    return false      -- never stop
end)

-- Applies immediately AND reports, so running it always does something visible. v0.1 made
-- this a bare toggle, which looked broken because it produced no effect on its own.
RegisterConsoleCommandHandler("cmsfunlock", function()
    enabled = true
    ExecuteInGameThread(function()
        local applied, seen, pruned = apply(true)
        log(string.format("apply: %d changed / %d selector(s) found, %d slot(s) hidden",
            applied, seen, pruned))
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
