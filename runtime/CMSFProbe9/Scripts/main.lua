-- CMSF Probe 9 — the rung 9 (prune unclaimed tiles) dependency set, measured in one run.
--
-- Load this ALONGSIDE CMSFUnlock, which does the unfiltering. This file only looks, and
-- writes one byte when explicitly told to.
--
-- WHAT IT ANSWERS
--   Q2  is a tile's SkinIcon brush resource object readable, and NULL when the slot ships
--       no portrait?  That is the proposed claim signal: unclaimed slots ship no portrait,
--       so a null icon means unclaimed. No filename convention, nothing for a mod manager
--       to rewrite, nothing for an author to get wrong.
--   Q3  is tile.SkinRow.RowName readable live?  WBP_SkinButton_C.SkinRow is an
--       FDataTableRowHandle in the cook, so a tile should carry its own exact slot identity
--       and no text matching is needed anywhere.
--   Q4  does a plain Visibility byte write collapse a tile, and does it survive Init()?
--       CMSFUnlock calls Init() on every poll, so a prune that Init() undoes is no prune.
--
-- (Q1 — whether a portrait-less tile renders gracefully — is answered by looking at the
-- screen, not by this file.)
--
-- SAFETY — the rules from CMSFUnlock main.lua:23, which were each learned by breaking
-- something, and which this file does not relax:
--   * Every line touching a UObject runs inside ExecuteInGameThread.
--   * Never invoke a native UFunction taking an object or struct parameter. `pcall` does
--     NOT protect against a C++ access violation. The only UFunctions called here are
--     no-arg ones the game itself calls constantly (GetAllChildren, GetFullName).
--   * Never hook a per-frame function.
--   * Property writes of PLAIN types are safe. The one write here is a byte.
-- Reads of a struct property's members (SkinRow.RowName, Brush.ResourceObject) are reads,
-- not native calls — nothing is constructed and nothing is passed back into native code.

local WIDGET = "WBP_SkinSelection_C"
local POLL_MS = 1000

-- ESlateVisibility. Collapsed also surrenders the tile's layout space, which is what a
-- prune wants; Hidden would leave a gap in the WrapBox.
local VIS_VISIBLE, VIS_COLLAPSED = 0, 1
local VIS_NAME = { [0] = "Visible", [1] = "Collapsed", [2] = "Hidden",
                   [3] = "HitTestInvisible", [4] = "SelfHitTestInvisible" }

local PRUNE_TARGET = "CMSF.Girl.01"   -- 02 is identical and deliberately left alone

local function log(s) print("[CMSFP9] " .. tostring(s) .. "\n") end

-- Best-effort stringify of an FName/FString/whatever UE4SS hands back.
local function str(v)
    if v == nil then return nil end
    local s
    if pcall(function() s = v:ToString() end) and type(s) == "string" then return s end
    if pcall(function() s = tostring(v) end) and type(s) == "string" then return s end
    return nil
end

-- This build of UE4SS hands struct members and array elements back as RemoteUnrealParam
-- WRAPPERS, not the value itself. Calling a UObject method on one throws "attempt to call a
-- RemoteUnrealParam value", and indexing further into one silently yields nil — which is
-- what made the first icon read report null for every tile, vanilla portraits included.
-- :get() unwraps. CMSFUnlock never hit this because it only ever takes #kids.
-- (:get() is a read. :set() on a hooked return is the banned one, and is not used.)
local function unwrap(v)
    if v == nil then return nil end
    local out
    if pcall(function() out = v:get() end) and out ~= nil then return out end
    return v      -- already a plain value on whatever UE4SS build this is
end

-- Returns rowName, iconDesc, visibility for one tile. Any field may be nil, which is
-- itself a result: an unreadable signal means rung 9 must fail open and prune nothing.
local function readTile(t)
    local row, icon, vis

    pcall(function() row = str(t.SkinRow.RowName) end)

    -- UImage -> FSlateBrush -> UObject*, unwrapping at every hop. The object's IDENTITY is
    -- the measurement, not its address: a repeated read returns a fresh wrapper each time,
    -- so "UObject: <addr>" says nothing about what the texture actually is.
    local img, brush, res
    pcall(function() img = unwrap(t.SkinIcon) end)
    if img == nil then
        icon = nil                              -- could not even reach the Image widget
    else
        pcall(function() brush = unwrap(img.Brush) end)
        if brush == nil then
            icon = "<brush unreadable>"
        else
            pcall(function() res = unwrap(brush.ResourceObject) end)
            if res == nil then
                icon = "null"                   -- nothing shipped at the slot's icon path
            else
                local name, cls
                pcall(function() name = str(res:GetFullName()) end)
                pcall(function() cls = str(res:GetClass():GetFullName()) end)
                icon = name or ("<unnamed " .. (cls or "?") .. ">")
            end
        end
    end

    pcall(function() vis = t.Visibility end)
    return row, icon, vis
end

local function eachSelector(fn)
    local found = FindAllOf(WIDGET)
    if not found then return 0 end
    local n = 0
    for _, w in pairs(found) do
        if w:IsValid() then
            n = n + 1
            fn(w)
        end
    end
    return n
end

local function eachTile(w, fn)
    local kids
    if not pcall(function() kids = w.SkinOptions:GetAllChildren() end) then return end
    if not kids then return end
    for _, raw in pairs(kids) do
        local t = unwrap(raw)
        -- Guarded: the throw this replaces escaped eachTile, unwound setVis before its
        -- report line, and made a failed prune look like a silent one.
        local valid = false
        pcall(function() valid = t:IsValid() end)
        if valid then fn(t) end
    end
end

-- MUST be called on the game thread.
-- Only the FIRST populated selector is reported. The ready room holds four panels, so the
-- unfiltered version printed every tile four times and buried the result.
local function dump()
    local shown = false
    local sel = eachSelector(function(w)
        if shown then return end
        local n = 0
        eachTile(w, function(t)
            n = n + 1
            local row, icon, vis = readTile(t)
            local isCMSF = row and row:sub(1, 5) == "CMSF."
            -- Vanilla rows are logged too, as the control: if the icon read works for them
            -- and not for ours, that is a shipping problem, not an API problem.
            log(string.format("  %-2d %-18s icon=%-62s vis=%s%s",
                n,
                row or "<row unreadable>",
                icon or "<icon unreadable>",
                vis and (VIS_NAME[vis] or tostring(vis)) or "?",
                isCMSF and "   <- CMSF" or ""))
        end)
        if n > 0 then shown = true end
    end)
    if sel == 0 then log("no skin selector in memory — open the skin menu first")
    elseif not shown then log("  selector has no tiles yet — open the skin menu, then `cmsfp9`") end
end

-- Auto-dump once when the menu first populates. The skin panel draws OVER the UE4SS
-- console, so asking for a manual command at exactly the right moment does not work in
-- practice — the same reason CMSFUnlock reports its count on change.
local reported = false
LoopAsync(POLL_MS, function()
    if not reported then
        ExecuteInGameThread(function()
            local any = false
            eachSelector(function(w)
                eachTile(w, function() any = true end)
            end)
            if any then
                reported = true
                log("skin menu open — tiles as loaded:")
                dump()
                log("`cmsfprune` to collapse " .. PRUNE_TARGET .. " (02 is the control)")
            end
        end)
    end
    return false      -- never stop
end)

RegisterConsoleCommandHandler("cmsfp9", function()
    ExecuteInGameThread(function()
        log("tiles:")
        dump()
    end)
    return true
end)

RegisterConsoleCommandHandler("cmsfprune", function()
    ExecuteInGameThread(function() setVis(PRUNE_TARGET, VIS_COLLAPSED, "collapse", "prop") end)
    return true
end)

-- Run this only if `cmsfprune` reported writes but the tile stayed put — that is the
-- Slate-never-noticed case, and this is the lever that answers it.
RegisterConsoleCommandHandler("cmsfprunefn", function()
    ExecuteInGameThread(function() setVis(PRUNE_TARGET, VIS_COLLAPSED, "collapse", "fn") end)
    return true
end)

RegisterConsoleCommandHandler("cmsfunprune", function()
    ExecuteInGameThread(function() setVis(PRUNE_TARGET, VIS_VISIBLE, "restore", "fn") end)
    return true
end)

log("loaded. Open Scav Girl's skin menu; tiles dump automatically.")
log("  `cmsfp9` re-dump (the tile line now carries the resolved icon object)")
log("  `cmsfprune` byte write (known no-op)   `cmsfprunefn` SetVisibility() — this one works")
log("  `cmsfunprune` undo")
