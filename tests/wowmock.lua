-- Strict stand-in for the WoW client, enough to run AKForeverTooltip under a plain Lua interpreter.
-- What it models of Blizzard's side:
--
--  * GameTooltip_SetDefaultAnchor(tooltip, parent): owns the tooltip with ANCHOR_NONE and pins it to the
--    bottom right corner (SharedTooltipTemplates.lua);
--  * TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, fn): runs addon callbacks after a
--    unit tooltip was built;
--  * taint: on this client a tooltip that addon code cleared / re-owned / showed / hid cannot show secret
--    lines afterwards (GameTooltipDataMixin:SetWorldCursor says so) - SetOwner, ClearLines, Show, Hide and
--    any field written onto Blizzard's tooltip are recorded, and the test runner fails the scenario;
--  * secret values: the unit functions can be made to answer with a secret.
--
-- Not loaded by the game (not in the .toc).
local Mock = {}

local REAL_PRINT = print
local ADDON = "AKForeverTooltip"

Mock.SECRET = setmetatable({}, { __tostring = function() return "<SECRET>" end })

local function violation(text)
    Mock.taintViolations[#Mock.taintViolations + 1] = text
end

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
local methods = {}

function methods.SetScript(self, name, fn) self.__scripts[name] = fn end
function methods.RegisterEvent(self, event)
    if Mock.unknownEvents[event] then
        error("Attempt to register unknown event \"" .. event .. "\"")
    end
    self.__events[event] = true
end
function methods.GetName(self) return self.__name end
function methods.SetTextColor(self, r, g, b) self.__textColor = { r, g, b } end
function methods.SetStatusBarColor(self, r, g, b) self.__barColor = { r, g, b } end

local function newWidget(kind, name)
    return setmetatable({ __kind = kind, __name = name, __scripts = {}, __events = {} }, { __index = methods })
end

-- Blizzard's tooltip
local tooltipMethods = setmetatable({}, { __index = methods })
function tooltipMethods.SetOwner(self, owner, anchorType, x, y)
    if not Mock.blizzardCode then
        violation("addon code called SetOwner on Blizzard's tooltip (clears it: OnTooltipCleared runs tainted)")
    end
    self.__owner, self.__anchorType, self.__offsetX, self.__offsetY = owner, anchorType, x or 0, y or 0
end
function tooltipMethods.SetAnchorType(self, anchorType, x, y)
    self.__anchorType, self.__offsetX, self.__offsetY = anchorType, x or 0, y or 0
end
function tooltipMethods.GetAnchorType(self) return self.__anchorType end
function tooltipMethods.SetPoint(self, point, relativeTo) self.__point = { point, relativeTo } end
for _, name in ipairs({ "ClearLines", "Show", "Hide", "FadeOut", "SetUnit", "AddLine", "SetText" }) do
    tooltipMethods[name] = function(self)
        if not Mock.blizzardCode then
            violation("addon code called " .. name .. " on Blizzard's tooltip (its scripts would run tainted)")
        end
        self["__" .. name] = true
    end
end
function tooltipMethods.GetUnit(self)
    if Mock.state.secretAnswers.GetUnit then
        return Mock.SECRET, Mock.SECRET, Mock.SECRET
    end
    return self.__unitName, self.__unit, "Player-1-0001"
end

local function newBlizzardTooltip(name)
    local tooltip = { __kind = "GameTooltip", __name = name, __scripts = {}, __events = {} }
    return setmetatable(tooltip, {
        __index = tooltipMethods,
        __newindex = function(self, key, value)
            if not Mock.blizzardCode and not (type(key) == "string" and key:sub(1, 2) == "__") then
                violation("wrote field '" .. tostring(key) .. "' on Blizzard's " .. name)
            end
            rawset(self, key, value)
        end,
    })
end

-- Runs fn as Blizzard's own (secure) code.
function Mock.asBlizzard(fn, ...)
    local before = Mock.blizzardCode
    Mock.blizzardCode = true
    local ok, err = pcall(fn, ...)
    Mock.blizzardCode = before
    if not ok then
        error(err, 0)
    end
end

function Mock.fire(event, ...)
    for _, frame in ipairs(Mock.frames) do
        if frame.__events[event] and frame.__scripts.OnEvent then
            frame.__scripts.OnEvent(frame, event, ...)
        end
    end
end

function Mock.setCombat(inCombat)
    Mock.state.inCombat = inCombat
    Mock.fire(inCombat and "PLAYER_REGEN_DISABLED" or "PLAYER_REGEN_ENABLED")
end

------------------------------------------------------------------------
-- Install
------------------------------------------------------------------------
local function readToc(root)
    local files = {}
    for line in io.lines(root .. "/" .. ADDON .. ".toc") do
        line = line:gsub("\r", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            files[#files + 1] = (line:gsub("\\", "/"))
        end
    end
    return files
end

function Mock.install(options)
    options = options or {}
    local G = _G
    for _, name in ipairs(Mock.globalNames or {}) do
        G[name] = nil
    end
    Mock.globalNames = {}
    local function global(name, value)
        G[name] = value
        Mock.globalNames[#Mock.globalNames + 1] = name
    end

    Mock.now, Mock.frames = 1000, {}
    Mock.printed, Mock.errors, Mock.taintViolations = {}, {}, {}
    Mock.unknownEvents = options.unknownEvents or {}
    Mock.blizzardCode = false
    local state = {
        inCombat = false,
        secretAnswers = {}, -- [function name] = true: it answers with a secret
        units = {},         -- [token] = { name, player = true/false, class = "ROGUE" }
        playerName = options.playerName or "Purrdee",
    }
    Mock.state = state

    global("print", function(...)
        local parts = {}
        for i = 1, select("#", ...) do
            parts[i] = tostring((select(i, ...)))
        end
        Mock.printed[#Mock.printed + 1] = table.concat(parts, " ")
    end)
    global("issecretvalue", function(value) return value == Mock.SECRET end)
    global("geterrorhandler", function()
        return function(err)
            Mock.errors[#Mock.errors + 1] = tostring(err) .. debug.traceback("", 2):sub(1, 900)
        end
    end)
    global("GetTime", function() return Mock.now end)
    global("date", function() return "2026-09-20 12:00:00" end)
    global("InCombatLockdown", function() return state.inCombat end)
    global("GetBuildInfo", function() return "1.60.1", "69913", "Sep 17 2026", 16001 end)
    global("UnitName", function() return state.playerName end)
    global("UnitFullName", function() return state.playerName, "TestRealm" end)
    global("GetRealmName", function() return "Test Realm" end)
    global("SlashCmdList", {})
    global("C_AddOns", { GetAddOnMetadata = function() return "0.1.0-test" end })
    global("CreateFrame", function(kind, name)
        local frame = newWidget(kind, name)
        Mock.frames[#Mock.frames + 1] = frame
        return frame
    end)
    global("UIParent", newWidget("Frame", "UIParent"))

    -- Units ---------------------------------------------------------------
    local function unitAnswer(name, read)
        global(name, function(unit)
            if state.secretAnswers[name] then
                return Mock.SECRET, Mock.SECRET, Mock.SECRET
            end
            return read(state.units[unit])
        end)
    end
    unitAnswer("UnitExists", function(unit) return unit ~= nil end)
    unitAnswer("UnitIsPlayer", function(unit) return unit ~= nil and unit.player == true end)
    unitAnswer("UnitClass", function(unit)
        if not unit then
            return nil
        elseif not unit.player then
            return Mock.SECRET, Mock.SECRET, Mock.SECRET -- SecretWhenUnitIdentityRestricted: not player-controlled
        end
        return "Class", unit.class, 4
    end)
    global("RAID_CLASS_COLORS", {
        ROGUE = { r = 1.00, g = 0.96, b = 0.41 }, SHAMAN = { r = 0.00, g = 0.44, b = 0.87 }, MAGE = { r = 0.25, g = 0.78, b = 0.92 },
    })

    -- The tooltip -----------------------------------------------------------
    if not options.noTooltip then
        local tooltip = newBlizzardTooltip("GameTooltip")
        if options.noSetAnchorType then
            rawset(tooltip, "SetAnchorType", false)
        end
        global("GameTooltip", tooltip)
        global("GameTooltipTextLeft1", newWidget("FontString", "GameTooltipTextLeft1"))
        global("GameTooltipStatusBar", newWidget("StatusBar", "GameTooltipStatusBar"))
        G.GameTooltipStatusBar.__barColor = { 0, 1, 0 }
        global("GameTooltipDefaultContainer", newWidget("Frame", "GameTooltipDefaultContainer"))
        global("ItemRefTooltip", newBlizzardTooltip("ItemRefTooltip")) -- another tooltip that can show a unit
        global("ItemRefTooltipTextLeft1", newWidget("FontString", "ItemRefTooltipTextLeft1"))
        global("GameTooltip_SetDefaultAnchor", function(tip, parent) -- SharedTooltipTemplates.lua
            local before = Mock.blizzardCode
            Mock.blizzardCode = true
            tip:SetOwner(parent, "ANCHOR_NONE")
            tip:SetPoint("BOTTOMRIGHT", G.GameTooltipDefaultContainer)
            Mock.blizzardCode = before
        end)
    end
    if not options.noPostCalls then
        local postCalls = {}
        global("Enum", { TooltipDataType = { Item = 0, Spell = 1, Unit = 2 } })
        global("TooltipDataProcessor", {
            AddTooltipPostCall = function(dataType, fn)
                postCalls[dataType] = postCalls[dataType] or {}
                table.insert(postCalls[dataType], fn)
            end,
        })
        -- Blizzard shows a unit tooltip: default anchor (world units), build the lines, run the post calls
        function Mock.showUnitTooltip(unitToken, tooltip)
            tooltip = tooltip or G.GameTooltip
            state.units.mouseover = state.units[unitToken]
            Mock.asBlizzard(function()
                G.GameTooltip_SetDefaultAnchor(tooltip, G.UIParent)
                tooltip.__unit, tooltip.__unitName = unitToken, state.units[unitToken] and state.units[unitToken].name
                G[tooltip:GetName() .. "TextLeft1"]:SetTextColor(1, 1, 1) -- GameTooltip_UnitColor: Blizzard's own colour first
            end)
            for _, fn in ipairs(postCalls[G.Enum.TooltipDataType.Unit] or {}) do
                fn(tooltip, { type = G.Enum.TooltipDataType.Unit, guid = Mock.SECRET, lines = Mock.SECRET }) -- (forceinsecure: addon code)
            end
        end
    end

    -- The sanctioned way to run addon code after a Blizzard function
    global("hooksecurefunc", function(name, hook)
        assert(type(name) == "string" and type(G[name]) == "function", "hooksecurefunc: no global function " .. tostring(name))
        local original = G[name]
        G[name] = function(...)
            local results = { original(...) }
            local before = Mock.blizzardCode
            Mock.blizzardCode = false
            local ok, err = pcall(hook, ...)
            Mock.blizzardCode = before
            if not ok then
                Mock.errors[#Mock.errors + 1] = "in a secure hook: " .. tostring(err)
            end
            return (table.unpack or unpack)(results)
        end
    end)

    -- Saved variables, as the bridge addon leaves them
    G.AKForeverTooltipDB, G.AKForeverTooltip_SavedStateBridge = options.db, options.bridge
    Mock.globalNames[#Mock.globalNames + 1] = "AKForeverTooltipDB"
    Mock.globalNames[#Mock.globalNames + 1] = "AKForeverTooltip_SavedStateBridge"

    local root = options.root or "."
    local ns = {}
    for _, file in ipairs(readToc(root)) do
        local chunk = assert(loadfile(root .. "/" .. file))
        chunk(ADDON, ns)
    end
    for _, name in ipairs({ "SLASH_AKFOREVERTOOLTIP1", "SLASH_AKFOREVERTOOLTIP2", "SLASH_AKFOREVERTOOLTIP3" }) do
        Mock.globalNames[#Mock.globalNames + 1] = name
    end
    Mock.ns = ns
    Mock.fire("ADDON_LOADED", ADDON)
    Mock.fire("PLAYER_LOGIN")
    return ns, state
end

Mock.realPrint = REAL_PRINT

return Mock
