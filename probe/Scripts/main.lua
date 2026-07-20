-- CMSF Probe v3 — SAFE. Read-only reflection plus one proven property write.
--
-- WHY v2 CRASHED THE CLIENT (EXCEPTION_ACCESS_VIOLATION reading 0x70, stack entirely
-- inside UE4SS.dll): v2 called the native UFunction SetNewSkin with whatever LoadAsset
-- returned — most likely a UPackage rather than the USkeletalMesh the parameter expects.
-- The native side dereferenced it as a mesh and read a member at +0x70 that was not there.
--
-- The mistake behind the mistake: `pcall` was treated as making that safe. It is not.
-- pcall catches LUA errors. It cannot catch a C++ access violation — by the time the
-- native function dereferences a bad pointer, the process is already gone.
--
-- RULES THIS FILE NOW FOLLOWS:
--   1. Never invoke a native UFunction that takes an object/struct parameter unless the
--      argument's class has been verified first. Currently: never, full stop.
--   2. Never call :set() on a hooked return value. Constructing/replacing a TArray return
--      from Lua is exactly the kind of unchecked native write that crashed us.
--   3. Property writes of PLAIN types (bool, number) are fine — proven repeatedly by
--      cmsfunlock and by FWStealth, and they cannot type-confuse a native call.
--
-- What remains is genuinely useful: a persistent, safe version of the unlock. cmsfunlock
-- was proven to work (2 -> 7 skins); it just did not survive reopening the menu. Polling
-- for a selector whose flag has come back true and re-applying is the same proven
-- operation, automated — the FWStealth/TFWQuestItemTag pattern already used on this game.

local WIDGET = "WBP_SkinSelection_C"
local AUTO = true     -- toggle with `cmsfauto`

local function log(s) print("[CMSF] " .. tostring(s) .. "\n") end

local function findSkinComp()
    local comps = FindAllOf("FWSkinChangeComponent")
    if not comps then return nil end
    for _, c in pairs(comps) do
        if c:IsValid() then
            local n = ""
            pcall(function() n = c:GetFullName() end)
            if not n:find("Default__", 1, true) then return c end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------------------
-- The useful part: keep the selector unfiltered, safely.
-- Only ever writes a bool and calls a no-arg UFunction the game itself calls constantly.
local applied = 0
local function enforceUnlocked()
    if not AUTO then return end
    local found = FindAllOf(WIDGET)
    if not found then return end
    for _, w in pairs(found) do
        if w:IsValid() then
            local locked = false
            local ok = pcall(function() locked = w.SelectLockedSkinsOnly end)
            if ok and locked == true then
                pcall(function() w.SelectLockedSkinsOnly = false end)
                pcall(function() w:Init() end)
                applied = applied + 1
                if applied <= 5 then log("AUTO: cleared SelectLockedSkinsOnly + rebuilt") end
            end
        end
    end
end

-- 1s poll. FindAllOf is an object-array scan so this is not free, but it is the same
-- cadence TFWQuestItemTag uses on this game, and it only acts when the flag is actually
-- true — i.e. once per menu open, not continuously.
LoopAsync(1000, function()
    pcall(enforceUnlocked)
    return false
end)

RegisterConsoleCommandHandler("cmsfauto", function()
    AUTO = not AUTO
    log("AUTO: " .. (AUTO and "ON — selector will stay unfiltered" or "OFF"))
    return true
end)

-- ---------------------------------------------------------------------------------------
-- Read-only diagnostics. Nothing below writes anything.

local function dumpTable(label, t)
    if type(t) ~= "table" then log(string.format("TBL: %s is %s", label, type(t))) return end
    log(string.format("TBL: %s n=%d", label, #t))
    for i = 1, #t do
        local v, desc, extra = t[i], type(t[i]), ""
        pcall(function() if type(v) == "userdata" then desc = v:type() end end)
        pcall(function()
            local g = v:get()
            extra = " get->" .. type(g)
            pcall(function() extra = extra .. " " .. g:GetFullName() end)
            pcall(function() extra = extra .. " class=" .. g:GetClass():GetFName():ToString() end)
        end)
        log(string.format("TBL:   [%d] %s%s", i, desc, extra))
    end
end

RegisterConsoleCommandHandler("cmsfskins", function()
    ExecuteInGameThread(function()
        local c = findSkinComp()
        if not c then log("no live FWSkinChangeComponent") return end
        log("COMP: " .. c:GetFullName())
        pcall(function() dumpTable("GetAvailableSkins", c:GetAvailableSkins()) end)
        pcall(function() dumpTable("GetUnlockedSkins", c:GetUnlockedSkins()) end)
        -- What class does the game itself store in SelectedSkin? This is the type any
        -- future SetNewSkin call would have to match, and knowing it is the precondition
        -- for ever making that call safely.
        pcall(function()
            local s = c.SelectedSkin
            log("COMP: SelectedSkin type=" .. type(s))
            pcall(function() log("COMP:   " .. s:GetFullName()) end)
            pcall(function() log("COMP:   class=" .. s:GetClass():GetFName():ToString()) end)
        end)
    end)
    return true
end)

local function dumpStruct(st, depth)
    if not st or not st:IsValid() then return end
    local n = "?"; pcall(function() n = st:GetFullName() end)
    log("  CLASS: " .. n)
    pcall(function() st:ForEachFunction(function(f)
        local fn = "?"; pcall(function() fn = f:GetFName():ToString() end)
        log("    fn   " .. fn)
    end) end)
    pcall(function() st:ForEachProperty(function(p)
        local pn, pt = "?", "?"
        pcall(function() pn = p:GetFName():ToString() end)
        pcall(function() pt = p:GetClass():GetFName():ToString() end)
        log(string.format("    prop %-32s %s", pn, pt))
    end) end)
    if depth <= 0 then return end
    local super; pcall(function() super = st:GetSuperStruct() end)
    if super and super:IsValid() then dumpStruct(super, depth - 1) end
end

RegisterConsoleCommandHandler("cmsfdump", function(fullCmd, params)
    local cls = params and params[1]
    if not cls or cls == "" then log("usage: cmsfdump <ClassName>") return true end
    ExecuteInGameThread(function()
        local o = FindFirstOf(cls)
        if not o or not o:IsValid() then log("DUMP: no live instance of " .. cls) return end
        log("DUMP: " .. o:GetFullName())
        local c; pcall(function() c = o:GetClass() end)
        dumpStruct(c, 3)
    end)
    return true
end)

log("CMSF Probe v3 (safe) — auto-unlock ON. cmsfauto | cmsfskins | cmsfdump <Class>")
