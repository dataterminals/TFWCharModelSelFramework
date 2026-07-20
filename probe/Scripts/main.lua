-- CMSF Probe v2 — lean.
--
-- v1 accumulated dead experiments and, more importantly, a post-hook on
-- GetAvailableSkins. That function is queried by the selector UI (four player panels in the
-- ready room), and a UE4SS hook on a hot native function is not free — it is the prime
-- suspect for the client lag reported on the last run. It has served its purpose and is
-- gone. Nothing here hooks a per-frame function.
--
-- Established so far (see docs/00-findings.md):
--   * roster = FWSkinChangeComponent.SkinChoices / .LockedSkinChoices on BP_Player_<Char>
--   * DT_SkinUIData supplies name/icon; a row shows when its Skin path is in the roster
--   * GetAvailableSkins() -> 7 (all), GetUnlockedSkins() -> 2 (entitled)
--     SelectLockedSkinsOnly merely chooses WHICH getter the widget calls
--   * SetNewSkin takes an ObjectProperty — a loaded UObject, NOT a string or soft path
--     (v1 passed a string: "[push_objectproperty] Error")
--
-- Commands:
--   cmsfapply [path]   load a mesh and apply it via SetNewSkin + ForceUpdateSkin
--   cmsfmenu           arm the GetUnlockedSkins hook (see below)
--   cmsfdump <Class>   reflection dump of a live instance's class chain
--   cmsfunlock         one-shot: clear SelectLockedSkinsOnly on live selectors

local MESH = "/Game/Character/Scavengers/Female/Skins/OCT/SK_SCV_FL_OCT"
local WIDGET_CLASS = "/Game/FW/UI/MainMenu/UMG/Panels/WBP_SkinSelection.WBP_SkinSelection_C"
local COMP_FN = "/Script/FWGameCore.FWSkinChangeComponent"

local MENU_HOOK = false     -- armed by `cmsfmenu`

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

local function dumpTable(label, t)
    if type(t) ~= "table" then log(string.format("TBL: %s is %s", label, type(t))) return end
    log(string.format("TBL: %s n=%d", label, #t))
    for i = 1, #t do
        local v, desc, extra = t[i], type(t[i]), ""
        pcall(function() if type(v) == "userdata" then desc = v:type() end end)
        -- Elements arrive as RemoteUnrealParam; :get() is what unwraps them.
        pcall(function()
            local g = v:get()
            extra = " get->" .. type(g)
            pcall(function() extra = extra .. " " .. g:GetFullName() end)
        end)
        log(string.format("TBL:   [%d] %s%s", i, desc, extra))
    end
end

-- ---------------------------------------------------------------------------------------
-- TEST A — apply an arbitrary mesh at runtime.
-- SetNewSkin wants a UObject, so load the mesh first. If this works, a custom skin can be
-- applied with no pak override at all.
local function apply(pathArg)
    local c = findSkinComp()
    if not c then log("APPLY: no live FWSkinChangeComponent") return end
    local path = pathArg or MESH

    local mesh
    local okLoad = pcall(function() mesh = LoadAsset(path) end)
    log(string.format("APPLY: LoadAsset ok=%s type=%s", tostring(okLoad), type(mesh)))
    if mesh then pcall(function() log("APPLY:   " .. mesh:GetFullName()) end) end
    if not mesh then
        pcall(function() mesh = StaticFindObject(path .. "." .. path:match("([^/]+)$")) end)
        log("APPLY: fallback StaticFindObject type=" .. type(mesh))
    end
    if not mesh then log("APPLY: could not obtain the mesh object") return end

    local ok1, e1 = pcall(function() return c:SetNewSkin(mesh) end)
    log(string.format("APPLY: SetNewSkin(UObject) ok=%s %s", tostring(ok1), ok1 and "" or tostring(e1):sub(1, 120)))

    local ok2, e2 = pcall(function() return c:SetSelectedSkin(mesh) end)
    log(string.format("APPLY: SetSelectedSkin(UObject) ok=%s %s", tostring(ok2), ok2 and "" or tostring(e2):sub(1, 120)))

    local ok3 = pcall(function() c:ForceUpdateSkin() end)
    log("APPLY: ForceUpdateSkin ok=" .. tostring(ok3))
    log("APPLY: look at your character — did the skin change?")
end

-- ---------------------------------------------------------------------------------------
-- TEST B — make the selector show everything, permanently, without touching the flag.
-- SelectLockedSkinsOnly only decides whether the widget calls GetUnlockedSkins (2) or
-- GetAvailableSkins (7). So instead of fighting the flag on every menu open, hook the
-- narrow getter and hand back the wide list. Both are the same return type, and the wide
-- one can simply be called — nothing has to be constructed, which is what blocked every
-- previous attempt.
--
-- GetUnlockedSkins is called when the menu is built, not per frame, so this should not
-- carry the cost that the GetAvailableSkins hook did. Left opt-in via `cmsfmenu` anyway.
local hookedMenu = false
LoopAsync(3000, function()
    if hookedMenu then return true end
    local fn = StaticFindObject(COMP_FN .. ":GetUnlockedSkins")
    if not fn or not fn:IsValid() then return false end
    local ok = pcall(function()
        RegisterHook(COMP_FN .. ":GetUnlockedSkins", function() end, function(self, ret)
            if not MENU_HOOK then return end
            local okAll, all = pcall(function() return self:get():GetAvailableSkins() end)
            if not okAll or type(all) ~= "table" then return end
            local okSet, err = pcall(function() ret:set(all) end)
            if not MENU_REPORTED then
                MENU_REPORTED = true
                log(string.format("MENU: widen %d -> %d  set ok=%s %s",
                    -1, #all, tostring(okSet), okSet and "" or tostring(err):sub(1, 110)))
            end
        end)
    end)
    hookedMenu = ok
    log("HOOK: GetUnlockedSkins " .. (ok and "registered" or "FAILED"))
    return ok
end)

RegisterConsoleCommandHandler("cmsfmenu", function()
    MENU_HOOK = true
    MENU_REPORTED = false
    log("MENU: armed — reopen the skin menu; it should list every skin with no unlock command")
    return true
end)

RegisterConsoleCommandHandler("cmsfapply", function(fullCmd, params)
    local p = params and params[1]
    ExecuteInGameThread(function() apply(p ~= "" and p or nil) end)
    return true
end)

RegisterConsoleCommandHandler("cmsfskins", function()
    ExecuteInGameThread(function()
        local c = findSkinComp()
        if not c then log("no live FWSkinChangeComponent") return end
        pcall(function() dumpTable("GetAvailableSkins", c:GetAvailableSkins()) end)
        pcall(function() dumpTable("GetUnlockedSkins", c:GetUnlockedSkins()) end)
    end)
    return true
end)

-- Kept from v1: general reflection dump, and the one-shot manual unlock (the v1 post-Init
-- re-entry hack is gone — it never held across menu re-entry and was pure overhead).
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

RegisterConsoleCommandHandler("cmsfunlock", function()
    ExecuteInGameThread(function()
        local found = FindAllOf("WBP_SkinSelection_C")
        if not found then log("UNLOCK: no live selector") return end
        for _, w in pairs(found) do
            if w:IsValid() then
                pcall(function() w.SelectLockedSkinsOnly = false end)
                pcall(function() w:Init() end)
            end
        end
        log("UNLOCK: applied (one-shot; prefer cmsfmenu)")
    end)
    return true
end)

log("CMSF Probe v2 — cmsfapply | cmsfmenu | cmsfskins | cmsfdump <Class> | cmsfunlock")
