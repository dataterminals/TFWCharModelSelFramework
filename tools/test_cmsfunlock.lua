-- Executable check for runtime/CMSFUnlock/Scripts/main.lua.
--
-- WHY THIS EXISTS. v0.1 shipped an enforcement path that ran, logged, and changed nothing,
-- because the code was never executed outside the manual command it was adapted from. v0.2.4
-- fixes a defect of the same family: an Init() call that could not fire on the panels that
-- needed it. Nothing in this repo could have caught either one without launching the game, and
-- a field test costs a session and a volunteer.
--
-- So: stub the five UE4SS globals the mod touches, fake a widget tree, and drive the poll body
-- tick by tick. That is enough to exercise every branch of the enforcement, the pruner and the
-- two backoffs.
--
-- WHAT IT CANNOT PROVE, and the distinction matters on this file more than most: this is the
-- mod's control flow against a fake, not the game's behaviour. It cannot tell you whether the
-- game repopulates a panel, whether the widget pool resets visibility, or whether an Init() on
-- a live panel does what it is assumed to do. Those still need a log from a real session. What
-- it does buy is that a change to this file cannot silently stop hiding, stop restoring, start
-- collapsing vanilla tiles, or rebuild the asset template.
--
-- Usage (Lua 5.2+, for the loadfile environment parameter):
--     lua tools/test_cmsfunlock.lua [path/to/main.lua]

if _VERSION == "Lua 5.1" then
    io.stderr:write("needs Lua 5.2 or newer (loadfile's env parameter)\n")
    os.exit(1)
end

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
local SRC = (arg and arg[1]) or (here .. "/../runtime/CMSFUnlock/Scripts/main.lua")

-- ESlateVisibility, as the mod names them.
local COLLAPSED, DEFAULT = 1, 4

-- A WBP_SkinButton_C. `iconPath` is what the brush currently RESOLVES to, which is not
-- necessarily the slot's own path -- the pooling hazard the mod's claim race is about. Tests
-- mutate t.__icon to simulate an author's texture arriving late.
local function tile(row, vis, iconPath)
    local t = { SkinRow = { RowName = row }, Visibility = vis, __icon = iconPath }
    t.SkinIcon = iconPath and {
        Brush = { ResourceObject = {
            GetFullName = function() return "Texture2D " .. t.__icon end } }
    } or nil
    function t:IsValid() return true end
    function t:SetVisibility(v) self.Visibility = v end
    return t
end

-- A WBP_SkinSelection_C. `live` false makes GetFullName report a /Game/ root, which is how the
-- mod tells the WidgetTree template apart from a real panel. `populate` is what Init() fills
-- the box with; omit it and Init() leaves the panel empty, which is the backoff case.
local function panel(opts)
    local w = {
        SelectLockedSkinsOnly = opts.locked,
        __kids = opts.kids or {},
        __inits = 0,
        __live = opts.live ~= false,
    }
    w.SkinOptions = { GetAllChildren = function() return w.__kids end }
    function w:IsValid() return true end
    function w:Init()
        self.__inits = self.__inits + 1
        if opts.populate then self.__kids = opts.populate(self) end
    end
    function w:GetFullName()
        return "WBP_SkinSelection_C " .. (w.__live and "/Engine/Transient.Foo" or "/Game/Bar")
    end
    return w
end

-- A pristine copy of the mod per scenario, so one test's verdict cache cannot reach the next.
local function load(widgets)
    local env = setmetatable({}, { __index = _G })
    local out, loop, cmds = {}, nil, {}
    env.print = function(s) out[#out + 1] = (s:gsub("\n$", "")) end
    env.FindAllOf = function() return widgets end
    env.ExecuteInGameThread = function(fn) fn() end
    env.LoopAsync = function(_, fn) loop = fn end
    env.RegisterConsoleCommandHandler = function(name, fn) cmds[name] = fn end
    local chunk, err = loadfile(SRC, "t", env)
    if not chunk then
        io.stderr:write("could not load " .. SRC .. ": " .. tostring(err) .. "\n")
        os.exit(1)
    end
    chunk()
    return { out = out, tick = loop, cmd = cmds }
end

local fails = 0
local function check(label, got, want)
    if got ~= want then
        fails = fails + 1
        print(string.format("  FAIL  %-52s got %s, want %s", label, tostring(got), tostring(want)))
    else
        print(string.format("  ok    %-52s %s", label, tostring(got)))
    end
end

-- ---------------------------------------------------------------------------------------
print("A. a filtered panel: flag cleared, tiles rebuilt, vanilla rows left alone")
do
    local kids = {
        tile("ScavGirl0", DEFAULT), tile("ScavGirl1", DEFAULT), tile("Skin.Girl.MAY", DEFAULT),
        tile("CMSF.Girl.00", DEFAULT, "/Game/CMSF/Girl/99/T_CMSF_Girl_99"),   -- unclaimed
        tile("CMSF.Girl.01", DEFAULT, "/Game/CMSF/Girl/01/T_CMSF_Girl_01"),   -- claimed
    }
    local w = panel { locked = true, kids = kids }
    local h = load { w }
    h.tick()
    check("flag cleared", w.SelectLockedSkinsOnly, false)
    check("Init called once", w.__inits, 1)
    check("claimed CMSF visible immediately", kids[5].Visibility, DEFAULT)
    check("unclaimed hidden on the first pass", kids[4].Visibility, COLLAPSED)
    h.tick(); h.tick()
    check("and stays hidden", kids[4].Visibility, COLLAPSED)
    -- The regression that matters most: OTHER must never be read as "hide".
    check("vanilla row 1 untouched", kids[1].Visibility, DEFAULT)
    check("vanilla row 2 untouched", kids[2].Visibility, DEFAULT)
    check("dotted vanilla row untouched", kids[3].Visibility, DEFAULT)
    check("no further Init", w.__inits, 1)
end

print("B. v0.2.4: an empty live panel whose flag is ALREADY false is repopulated")
do
    -- The reported bug. The flag arrives false by inheritance from the template, so every
    -- version through v0.2.3 skipped the branch that held the only Init() call.
    local w = panel {
        locked = false, kids = {},
        populate = function() return { tile("MaskMan0", DEFAULT), tile("MaskMan1", DEFAULT) } end,
    }
    local h = load { w }
    h.tick()
    check("Init forced despite flag already false", w.__inits, 1)
    check("panel populated", #w.__kids, 2)
    h.tick(); h.tick()
    check("no repeated Init once populated", w.__inits, 1)
end

print("C. the asset template is never rebuilt")
do
    local w = panel { locked = false, kids = {}, live = false }
    local h = load { w }
    for _ = 1, 6 do h.tick() end
    check("template Init count", w.__inits, 0)
end

print("D. a panel that stays empty backs off instead of rebuilding every second")
do
    local w = panel { locked = false, kids = {} }   -- Init() never fills it
    local h = load { w }
    for _ = 1, 16 do h.tick() end
    check("Inits over 16 ticks (fires at 1,3,7,15)", w.__inits, 4)
    for _ = 1, 32 do h.tick() end
    check("and converges to one per 16 ticks", w.__inits, 6)
end

print("E. the claim race: a transient wrong brush is not cached, so the tile comes back")
do
    -- Measured 2026-07-21: the first population read a pooled tile still holding another
    -- character's portrait, and a rebuild ~6 s later got it right.
    local t = tile("CMSF.Girl.00", DEFAULT, "/Game/CMSF/BagMan/03/T_CMSF_BagMan_03")
    local w = panel { locked = false, kids = { tile("ScavGirl0", DEFAULT), t } }
    local h = load { w }
    h.tick()
    check("misread as unclaimed and hidden", t.Visibility, COLLAPSED)
    t.__icon = "/Game/CMSF/Girl/00/T_CMSF_Girl_00"      -- the author's texture resolves
    h.tick()
    check("restored once the real brush resolves", t.Visibility, DEFAULT)
end

print("F. blank-menu guard: every tile collapsed, the game's own ones come back")
do
    local kids = {
        tile("Bagman0", COLLAPSED), tile("Bagman1", COLLAPSED),
        tile("CMSF.BagMan.00", COLLAPSED, "/Game/CMSF/BagMan/77/T_CMSF_BagMan_77"),
    }
    local w = panel { locked = false, kids = kids }
    local h = load { w }
    h.tick()
    check("vanilla tile 1 restored", kids[1].Visibility, DEFAULT)
    check("vanilla tile 2 restored", kids[2].Visibility, DEFAULT)
    check("unclaimed CMSF tile stays hidden", kids[3].Visibility, COLLAPSED)
    check("no forced Init (panel was not empty)", w.__inits, 0)
    local said = false
    for _, l in ipairs(h.out) do if l:find("blank menu guarded") then said = true end end
    check("guard logged", said, true)
end

print("G. the guard does not fire while anything at all is visible")
do
    local kids = {
        tile("OldMan0", DEFAULT), tile("OldMan1", COLLAPSED),
        tile("CMSF.OldMan.00", COLLAPSED, "/Game/CMSF/OldMan/77/T_CMSF_OldMan_77"),
    }
    local w = panel { locked = false, kids = kids }
    local h = load { w }
    h.tick(); h.tick(); h.tick()
    check("collapsed vanilla tile left alone", kids[2].Visibility, COLLAPSED)
end

print("H. cmsfnoprune restores what was already hidden, cmsfprune puts it back")
do
    local kids = {
        tile("Shaman0", DEFAULT),
        tile("CMSF.Shaman.00", DEFAULT, "/Game/CMSF/Shaman/77/T_CMSF_Shaman_77"),
    }
    local w = panel { locked = true, kids = kids }
    local h = load { w }
    h.tick(); h.tick(); h.tick()
    check("unclaimed hidden by pruning", kids[2].Visibility, COLLAPSED)
    h.cmd["cmsfnoprune"]()
    h.tick()
    check("cmsfnoprune brought it back", kids[2].Visibility, DEFAULT)
    h.tick(); h.tick()
    check("and pruning stays off", kids[2].Visibility, DEFAULT)
    h.cmd["cmsfprune"]()
    h.tick(); h.tick(); h.tick()
    check("cmsfprune hides it again", kids[2].Visibility, COLLAPSED)
end

print("I. an unreadable child list is not an empty one")
do
    local w = panel { locked = false, kids = {} }
    w.SkinOptions = { GetAllChildren = function() error("boom") end }
    local h = load { w }
    for _ = 1, 5 do h.tick() end
    check("no Init on an unreadable panel", w.__inits, 0)
end

print("")
print(fails == 0 and "ALL PASS" or (fails .. " FAILURE(S)"))
os.exit(fails == 0 and 0 or 1)
