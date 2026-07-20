-- CMSF Probe — read the LIVE DT_SkinUIData and the LIVE skin-selection widget.
--
-- Answers the one question the character-select menu cannot: did our pak actually reach
-- the runtime table? A skin that does not appear is ambiguous between "the pak never
-- mounted" and "the pak mounted but the UI filters the row out", and those have opposite
-- fixes. This separates them.
--
--   live rows == 35 (ScavGirl5 + CMSF.Girl.TEST present) -> pak mounted, UI is filtering
--   live rows == 33                                      -> pak never mounted; deployment bug
--
-- Console: `cmsfprobe`.  Also auto-runs on a delay after ClientRestart.
-- Output goes to UE4SS.log, every line prefixed [CMSF] so it greps cleanly.
--
-- Reading a UDataTable's RowMap is not directly reachable from Lua (raw uint8* rows, not
-- reflected), so this goes through the reflected static UFunction
-- UDataTableFunctionLibrary::GetDataTableRowNames instead. UE4SS's handling of TArray out
-- params varies by build, so each call shape is tried in turn and the one that worked is
-- logged — the same defensive style as TFWQuestItemTag's three-way FText fallback.

-- SelectLockedSkinsOnly (a CDO property on WBP_SkinSelection_C, default TRUE) is the
-- prime suspect for why appended rows never show. Sylvia reports the selector only ever
-- offers entitlement-gated DLC skins — the shipped base skins are NOT selectable there,
-- they only turn up via the random skin roll on respawn in the tunnels. That matches a
-- filter that keeps "locked"/entitled rows and drops everything else, which would reject
-- an appended row no matter what it is named. `cmsfunlock` flips it and rebuilds.

local TABLE_PATH = "/Game/FW/Player/Data/DT_SkinUIData.DT_SkinUIData"
local WIDGET_CLASS = "/Game/FW/UI/MainMenu/UMG/Panels/WBP_SkinSelection.WBP_SkinSelection_C"
local WANT = { ["ScavGirl5"] = true, ["CMSF.Girl.TEST"] = true }

local UNLOCK = false   -- set by `cmsfunlock`; applied on the next widget Init

local function log(s) print("[CMSF] " .. tostring(s) .. "\n") end

local function findTable()
    local dt = StaticFindObject(TABLE_PATH)
    if dt and dt:IsValid() then return dt, "StaticFindObject" end
    local ok, loaded = pcall(function() return LoadAsset(TABLE_PATH) end)
    if ok and loaded and loaded:IsValid() then return loaded, "LoadAsset" end
    -- Last resort: the table may be loaded under a different outer.
    local found = FindAllOf("DataTable")
    if found then
        for _, t in pairs(found) do
            if t:IsValid() and t:GetFullName():find("DT_SkinUIData", 1, true) then
                return t, "FindAllOf"
            end
        end
    end
    return nil, nil
end

local function rowNames(dt)
    local lib = StaticFindObject("/Script/Engine.Default__DataTableFunctionLibrary")
    if not lib or not lib:IsValid() then return nil, "no DataTableFunctionLibrary" end

    -- Shape A: out param returned
    local ok, res = pcall(function() return lib:GetDataTableRowNames(dt) end)
    if ok and type(res) == "table" and #res > 0 then return res, "returned" end

    -- Shape B: out param filled in a passed table
    local out = {}
    local ok2 = pcall(function() lib:GetDataTableRowNames(dt, out) end)
    if ok2 and #out > 0 then return out, "filled" end

    return nil, string.format("both shapes failed (A ok=%s type=%s) (B ok=%s n=%d)",
        tostring(ok), type(res), tostring(ok2), #out)
end

local function probeTable()
    local dt, how = findTable()
    if not dt then
        log("TABLE: NOT FOUND — it may simply not be loaded yet; open the skin menu, then rerun `cmsfprobe`")
        return
    end
    log(string.format("TABLE: found via %s -> %s", how, dt:GetFullName()))

    local names, why = rowNames(dt)
    if not names then
        log("TABLE: could not enumerate rows: " .. tostring(why))
        return
    end

    -- UE4SS hands back FName objects, not strings. tostring() on one yields a userdata
    -- repr, not the name — which silently turned every lookup below into a false ABSENT
    -- on the first run even though the row count proved the rows were there. Always
    -- :ToString() an FName before comparing.
    local function nameStr(n)
        if type(n) == "string" then return n end
        local ok, s = pcall(function() return n:ToString() end)
        if ok and type(s) == "string" then return s end
        return tostring(n)
    end

    local seen, total, sample = {}, 0, {}
    for _, n in ipairs(names) do
        local s = nameStr(n)
        total = total + 1
        seen[s] = true
        if total <= 3 then sample[#sample + 1] = s end
    end
    log(string.format("TABLE: %d rows (via %s)", total, why))
    log("TABLE: first rows = " .. table.concat(sample, ", "))   -- sanity-check the conversion

    for want, _ in pairs(WANT) do
        log(string.format("TABLE:   %-16s %s", want, seen[want] and "PRESENT" or "ABSENT"))
    end

    -- Every ScavGirl-ish row, so we can see what the base sequence actually looks like live.
    local girls = {}
    for s, _ in pairs(seen) do
        if s:lower():find("scavgirl") or s:lower():find("girl") then girls[#girls + 1] = s end
    end
    table.sort(girls)
    log("TABLE: girl rows = " .. table.concat(girls, ", "))
end

local function probeWidget()
    local found = FindAllOf("WBP_SkinSelection_C")
    if not found or #found == 0 then
        log("WIDGET: no live WBP_SkinSelection_C (open the skin menu, then rerun `cmsfprobe`)")
        return
    end
    for _, w in pairs(found) do
        if w:IsValid() then
            log("WIDGET: " .. w:GetFullName())
            local ok = pcall(function()
                local box = w.SkinOptions
                if box and box:IsValid() then
                    local kids = box:GetAllChildren()
                    log(string.format("WIDGET:   SkinOptions children = %d", kids and #kids or -1))
                end
            end)
            if not ok then log("WIDGET:   could not read SkinOptions") end
            pcall(function()
                log("WIDGET:   SelectLockedSkinsOnly = " .. tostring(w.SelectLockedSkinsOnly))
            end)
        end
    end
end

local function probe()
    log("==== probe start ====")
    probeTable()
    probeWidget()
    log("==== probe end ====")
end

-- Flip SelectLockedSkinsOnly on every live selector and force it to rebuild.
-- Init is what populates SkinOptions, so the flag has to be false BEFORE it runs; setting
-- it on an already-built widget does nothing until the list is regenerated.
local function unlockLive()
    local found = FindAllOf("WBP_SkinSelection_C")
    if not found or #found == 0 then
        log("UNLOCK: no live selector — open the skin menu first, then rerun `cmsfunlock`")
        return
    end
    for _, w in pairs(found) do
        if w:IsValid() then
            local before = "?"
            pcall(function() before = tostring(w.SelectLockedSkinsOnly) end)
            local ok = pcall(function() w.SelectLockedSkinsOnly = false end)
            local after = "?"
            pcall(function() after = tostring(w.SelectLockedSkinsOnly) end)
            log(string.format("UNLOCK: set ok=%s  %s -> %s", tostring(ok), before, after))
            -- Rebuild. Init's signature is unknown, so try no-arg then give up loudly.
            local rebuilt = pcall(function() w:Init() end)
            log("UNLOCK: Init() rebuild " .. (rebuilt and "called" or "FAILED (needs args?) — reopen the menu instead"))
        end
    end
    probeWidget()
end

-- The BP class is not in memory at script load, so RegisterHook would fail with "no
-- UFunction with the specified name was found" (the TFWQuestItemTag lesson). Poll until
-- the class exists, register once, then stop.
-- Clearing the flag before Init is NOT enough: the unlock has to be re-run on every menu
-- re-entry, which means Init's own body re-asserts it — the caller almost certainly passes
-- it in. Corroborating: calling Init() with NO arguments yields the unlocked list, i.e. the
-- missing parameter defaults to false.
--
-- So we let Init run, and if it comes back locked we flip the flag and re-enter Init bare,
-- guarded against recursion. Crude but it uses the one call already proven to rebuild
-- unfiltered. The real framework should override the parameter instead of re-entering —
-- `cmsfsig` dumps Init's signature so that can be done properly.
local reentry = false

local function onInitPost(self)
    if not UNLOCK or reentry then return end
    local ok, w = pcall(function() return self:get() end)
    if not ok or not w then return end
    local locked = true
    pcall(function() locked = w.SelectLockedSkinsOnly end)
    if not locked then return end          -- already unfiltered, nothing to do
    reentry = true
    pcall(function() w.SelectLockedSkinsOnly = false end)
    local rebuilt = pcall(function() w:Init() end)
    reentry = false
    log("UNLOCK: re-asserted after Init (rebuild " .. (rebuilt and "ok" or "FAILED") .. ")")
end

local hooked = false
LoopAsync(2000, function()
    if hooked then return true end     -- true stops the loop
    local cls = StaticFindObject(WIDGET_CLASS)
    if not cls or not cls:IsValid() then return false end
    local ok = pcall(function()
        RegisterHook(WIDGET_CLASS .. ":Init",
            function(self)   -- pre
                if not UNLOCK or reentry then return end
                pcall(function() self:get().SelectLockedSkinsOnly = false end)
            end,
            onInitPost)
    end)
    hooked = ok
    log("HOOK: WBP_SkinSelection_C:Init " .. (ok and "registered (pre+post)" or "registration failed"))
    return ok
end)

-- Dump Init's parameter list, so the framework can override the argument rather than
-- re-entering the function.
RegisterConsoleCommandHandler("cmsfsig", function()
    ExecuteInGameThread(function()
        local fn = StaticFindObject(WIDGET_CLASS .. ":Init")
        if not fn or not fn:IsValid() then log("SIG: Init UFunction not found") return end
        log("SIG: " .. fn:GetFullName())
        local ok = pcall(function()
            fn:ForEachProperty(function(prop)
                log(string.format("SIG:   %s : %s", prop:GetFName():ToString(), prop:GetClass():GetFName():ToString()))
            end)
        end)
        if not ok then log("SIG: ForEachProperty unavailable on this UE4SS build") end
    end)
    return true
end)

-- The actual skin roster is NOT DT_SkinUIData. It lives on the pawn Blueprint, in an
-- FWSkinChangeComponent holding two reflected arrays:
--   SkinChoices        TArray<FSoftObjectPath>            the free / random-respawn pool
--   LockedSkinChoices  TMap<FGameplayTag, FSoftObjectPath> the entitlement-gated menu
-- SelectLockedSkinsOnly picks which one feeds the selector. DT_SkinUIData only supplies
-- display name + icon. These are ordinary UPROPERTYs, so unlike a DataTable RowMap they
-- are reachable from Lua — which is what makes a pure-Lua framework plausible.
local OCT = "/Game/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT.SK_SCV_FL_OCT"

local function findSkinComp()
    local comps = FindAllOf("FWSkinChangeComponent")
    if not comps then return nil end
    for _, c in pairs(comps) do
        if c:IsValid() then
            local owner = "?"
            pcall(function() owner = c:GetFullName() end)
            if owner:find("Girl", 1, true) or owner:find("Default__", 1, true) == nil then
                return c, owner
            end
        end
    end
    return nil
end

local function pathOf(v)
    local out = "?"
    pcall(function()
        if v.AssetPath then
            out = tostring(v.AssetPath.PackageName:ToString())
        elseif v.AssetPathName then
            out = tostring(v.AssetPathName:ToString())
        else
            out = tostring(v)
        end
    end)
    return out
end

local function dumpComp()
    local c, owner = findSkinComp()
    if not c then log("COMP: no live FWSkinChangeComponent (be in a match / ready room)") return end
    log("COMP: " .. tostring(owner))

    local ok = pcall(function()
        local arr = c.SkinChoices
        local n = #arr
        log(string.format("COMP: SkinChoices n=%d", n))
        for i = 1, n do
            log(string.format("COMP:   [%d] %s", i, pathOf(arr[i])))
        end
    end)
    if not ok then log("COMP: could not read SkinChoices") end

    pcall(function()
        local m = c.LockedSkinChoices
        log("COMP: LockedSkinChoices type=" .. type(m))
    end)
end

-- Prove the linkage: make an existing free slot point at the cut OCT mesh. If the selector
-- then shows "October" (the DT_SkinUIData row we appended for exactly that mesh path), the
-- whole model is confirmed — roster array drives availability, table drives presentation.
-- Overwrite in place rather than append, because mutating an existing element is far more
-- likely to work from Lua than growing a TArray of structs.
local function addOct()
    local c, owner = findSkinComp()
    if not c then log("ADD: no live FWSkinChangeComponent") return end

    local before, after, okw = "?", "?", false
    pcall(function()
        local arr = c.SkinChoices
        local n = #arr
        if n < 1 then log("ADD: SkinChoices empty") return end
        before = pathOf(arr[n])
        -- Shape A: assign the whole soft path via its string field
        okw = pcall(function() arr[n].AssetPath.PackageName = FName(OCT:match("^(.*)%.")) end)
        if not okw then
            -- Shape B: some builds expose AssetPathName directly
            okw = pcall(function() arr[n].AssetPathName = FName(OCT) end)
        end
        after = pathOf(arr[n])
    end)
    log(string.format("ADD: slot write ok=%s  %s -> %s", tostring(okw), before, after))
    log("ADD: now reopen the skin menu (run cmsfunlock first if you have not)")
end

-- ---------------------------------------------------------------------------------------
-- Reflection dumper. Deciding static-vs-runtime hinges on whether FWSkinChangeComponent
-- exposes a callable function for adding/changing a skin: if it does, the runtime design
-- works and nothing needs pak-overriding. Written generically (dump any class by name)
-- because every previous single-purpose probe cost a full game launch to learn one fact.
--
--   cmsfdump FWSkinChangeComponent
--   cmsfdump WBP_SkinSelection_C
--   cmsfdump WBP_PlayerStatusWidget_C
--   cmsfelem                          deep introspection of one SkinChoices element

local function try(label, fn)
    local ok, res = pcall(fn)
    if ok then
        if res ~= nil then log(string.format("    %-28s = %s", label, tostring(res))) end
        return true, res
    end
    log(string.format("    %-28s ! %s", label, tostring(res):sub(1, 90)))
    return false, nil
end

local function dumpStruct(st, depth)
    if not st or not st:IsValid() then return end
    local name = "?"
    pcall(function() name = st:GetFullName() end)
    log("  CLASS: " .. name)

    local nf = 0
    local okF = pcall(function()
        st:ForEachFunction(function(f)
            nf = nf + 1
            local fname = "?"
            pcall(function() fname = f:GetFName():ToString() end)
            log("    fn   " .. fname)
        end)
    end)
    if not okF then log("    (ForEachFunction unavailable)") end
    if okF and nf == 0 then log("    (no functions on this class)") end

    local okP = pcall(function()
        st:ForEachProperty(function(p)
            local pname, ptype = "?", "?"
            pcall(function() pname = p:GetFName():ToString() end)
            pcall(function() ptype = p:GetClass():GetFName():ToString() end)
            log(string.format("    prop %-32s %s", pname, ptype))
        end)
    end)
    if not okP then log("    (ForEachProperty unavailable)") end

    if depth <= 0 then return end
    local super = nil
    pcall(function() super = st:GetSuperStruct() end)
    if super == nil then pcall(function() super = st:GetSuper() end) end
    if super and super:IsValid() then dumpStruct(super, depth - 1) end
end

local function dumpClass(className)
    local obj = FindFirstOf(className)
    if not obj or not obj:IsValid() then
        log("DUMP: no live instance of " .. className)
        local cls = StaticFindObject("/Script/FWGameCore." .. className)
        if cls and cls:IsValid() then log("DUMP: (class object exists though: " .. cls:GetFullName() .. ")") end
        return
    end
    log("DUMP: instance " .. obj:GetFullName())
    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    dumpStruct(cls, 3)   -- walk a few supers; the useful function may be inherited
end

-- Everything about writing the roster from Lua failed with the accessors guessed so far.
-- Rather than guess again, enumerate what an element actually responds to.
local function dumpElem()
    local c = findSkinComp()
    if not c then log("ELEM: no live FWSkinChangeComponent") return end
    local arr = nil
    if not select(1, try("SkinChoices", function() arr = c.SkinChoices; return type(arr) end)) then return end
    try("#SkinChoices", function() return #arr end)

    local e = nil
    if not select(1, try("elem[1] lua type", function() e = arr[1]; return type(e) end)) then return end

    try("elem[1] tostring", function() return tostring(e) end)
    try("elem[1]:type()", function() return e:type() end)
    try("elem[1]:GetFullName()", function() return e:GetFullName() end)
    try("elem[1]:get()", function() return tostring(e:get()) end)
    try("elem[1].AssetPath", function() return tostring(e.AssetPath) end)
    try("elem[1].AssetPathName", function() return tostring(e.AssetPathName) end)
    try("elem[1].SubPathString", function() return tostring(e.SubPathString) end)
    try("elem[1] ForEachProperty", function()
        e:ForEachProperty(function(p) log("      member " .. p:GetFName():ToString()) end)
        return "ok"
    end)
end

RegisterConsoleCommandHandler("cmsfdump", function(fullCmd, params)
    local cls = params and params[1]
    if not cls or cls == "" then
        log("usage: cmsfdump <ClassName>   e.g. cmsfdump FWSkinChangeComponent")
        return true
    end
    ExecuteInGameThread(function() dumpClass(cls) end)
    return true
end)

RegisterConsoleCommandHandler("cmsfelem", function()
    ExecuteInGameThread(dumpElem)
    return true
end)

-- Auto-run the two that decide the architecture, so a launch is useful even without
-- reaching the console (which the skin menu draws over anyway).
ExecuteWithDelay(25000, function()
    ExecuteInGameThread(function()
        log("==== auto reflection dump ====")
        dumpClass("FWSkinChangeComponent")
        dumpElem()
        log("==== auto reflection end ====")
    end)
end)

RegisterConsoleCommandHandler("cmsfcomp", function()
    ExecuteInGameThread(dumpComp)
    return true
end)

RegisterConsoleCommandHandler("cmsfadd", function()
    ExecuteInGameThread(addOct)
    return true
end)

RegisterConsoleCommandHandler("cmsfunlock", function()
    UNLOCK = true
    log("UNLOCK: armed — reopening the skin menu will rebuild it unfiltered")
    ExecuteInGameThread(unlockLive)
    return true
end)

RegisterConsoleCommandHandler("cmsfprobe", function()
    ExecuteInGameThread(probe)
    return true
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(4000, function() ExecuteInGameThread(probe) end)
end)

ExecuteWithDelay(20000, function() ExecuteInGameThread(probe) end)
log("CMSF Probe loaded — console command: cmsfprobe")
