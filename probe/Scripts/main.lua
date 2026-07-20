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

local TABLE_PATH = "/Game/FW/Player/Data/DT_SkinUIData.DT_SkinUIData"
local WANT = { ["ScavGirl5"] = true, ["CMSF.Girl.TEST"] = true }

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

    local seen, total = {}, 0
    for _, n in ipairs(names) do
        local s = tostring(n)
        total = total + 1
        seen[s] = true
    end
    log(string.format("TABLE: %d rows (via %s)", total, why))

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

RegisterConsoleCommandHandler("cmsfprobe", function()
    ExecuteInGameThread(probe)
    return true
end)

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ExecuteWithDelay(4000, function() ExecuteInGameThread(probe) end)
end)

ExecuteWithDelay(20000, function() ExecuteInGameThread(probe) end)
log("CMSF Probe loaded — console command: cmsfprobe")
