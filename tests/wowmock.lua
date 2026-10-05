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

-- Arithmetic on a secret raises here, as it does in the game. But the game's message reads
-- "... while execution tainted by <addon>", which leaves open that it is allowed somewhere - so the
-- mock can be told to play the permissive world too, where a sum involving a secret gives a secret
-- back. Neither world is assumed by the addon; it finds out which one it is in.
local secretMeta = { __tostring = function() return "<SECRET>" end }
Mock.SECRET = setmetatable({}, secretMeta)
for _, op in ipairs({ "__add", "__sub", "__mul", "__div" }) do
    secretMeta[op] = function()
        if Mock.state and Mock.state.secretArithmetic then
            return Mock.SECRET
        end
        error("attempt to perform arithmetic on a secret number value", 2)
    end
end

local function violation(text)
    Mock.taintViolations[#Mock.taintViolations + 1] = text
end

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------
local newWidget -- defined below; the factory methods above it need the name
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
-- A font string takes whatever it is handed, secret or not, and never looks at it - which is the one
-- route a secret number has onto a tooltip line.
function methods.SetText(self, text) self.__text = text end
-- The formatting happens inside the widget, in C, so a secret never passes through a Lua string
-- operation on the way. Whether the client allows that is exactly what is in question, so the mock
-- can refuse it, or allow it - and allows it by default, because that is what the game was measured
-- to do (2026-09-24). A scenario that wants the stricter world says so.
function methods.SetFormattedText(self, format, ...)
    local count = select("#", ...)
    local args = { ... }
    for index = 1, count do
        if args[index] == Mock.SECRET and not (Mock.state and Mock.state.secretFormatting) then
            error("attempt to format a secret number value", 2)
        end
        args[index] = tostring(args[index])
    end
    self.__text = string.format(format, (table.unpack or unpack)(args, 1, count))
    self.__formatted = format
end
function methods.GetText(self) return self.__text end
-- A protected frame is a secure button or one of Blizzard's own; nothing the mock makes is, unless a
-- scenario says so. Two results, as the real one gives.
function methods.IsProtected(self) return self.__protected == true, self.__protected == true end
-- Enough of a frame to build a small on-screen readout: geometry and textures are recorded, not drawn.
function methods.SetSize(self, w, h) self.__width, self.__height = w, h end
function methods.SetPoint(self, ...) self.__point = { ... } end
function methods.SetAllPoints(self, target) self.__allPoints = target end
function methods.ClearAllPoints(self) self.__point = nil end
function methods.SetFrameStrata(self, strata) self.__strata = strata end
function methods.EnableMouse(self, on) self.__mouse = on end
function methods.SetColorTexture(self, r, g, b, a) self.__color = { r, g, b, a } end
function methods.SetHighlightTexture(self, texture) self.__highlight = texture end
function methods.RegisterForClicks(self, ...) self.__clicks = { ... } end
function methods.Show(self) self.__shown = true end
function methods.Hide(self) self.__shown = false end
function methods.IsShown(self) return self.__shown == true end
function methods.CreateTexture(self, name) return newWidget("Texture", name) end
function methods.CreateFontString(self, name) return newWidget("FontString", name) end
function methods.SetStatusBarColor(self, r, g, b) self.__barColor = { r, g, b } end

function newWidget(kind, name)
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
function tooltipMethods.GetOwner(self) return self.__owner end
function tooltipMethods.SetAnchorType(self, anchorType, x, y)
    self.__anchorType, self.__offsetX, self.__offsetY = anchorType, x or 0, y or 0
end
function tooltipMethods.GetAnchorType(self) return self.__anchorType end
function tooltipMethods.SetPoint(self, point, relativeTo) self.__point = { point, relativeTo } end
-- The dangerous ones are dangerous because each RUNS ONE OF THE TOOLTIP'S SCRIPTS as addon code -
-- OnTooltipCleared, OnShow, OnHide - and that is what writes tainted values into it.
for _, name in ipairs({ "ClearLines", "Show", "Hide", "FadeOut", "SetUnit", "SetText" }) do
    tooltipMethods[name] = function(self)
        if not Mock.blizzardCode then
            violation("addon code called " .. name .. " on Blizzard's tooltip (its scripts would run tainted)")
        end
        self["__" .. name] = true
    end
end

-- AddLine runs no script: it appends a line and lays the tooltip out again. Adding lines is the whole
-- purpose of TooltipDataProcessor.AddTooltipPostCall, so it is not grouped with the four above - but it
-- IS recorded, so a scenario can say what went onto the tooltip and in what order.
function tooltipMethods.AddLine(self, text, r, g, b)
    self.__lines = self.__lines or {}
    self.__lines[#self.__lines + 1] = { text = text, r = r, g = g, b = b }
    self.__AddLine = true
    local name = self:GetName()
    if name then
        local key = name .. "TextLeft" .. #self.__lines
        if not _G[key] then
            _G[key] = newWidget("FontString", key)
        end
        _G[key]:SetText(text)
    end
end

function tooltipMethods.AddDoubleLine(self, left, right, r, g, b)
    self.__lines = self.__lines or {}
    self.__lines[#self.__lines + 1] = { text = left, right = right, r = r, g = g, b = b }
    self.__AddLine = true
    local name = self:GetName()
    if name then
        for side, value in pairs({ Left = left, Right = right }) do
            local key = name .. "Text" .. side .. #self.__lines
            if not _G[key] then
                _G[key] = newWidget("FontString", key)
            end
            _G[key]:SetText(value)
        end
    end
end

function tooltipMethods.NumLines(self)
    return self.__lines and #self.__lines or 0
end

function tooltipMethods.ClearLineRecord(self)
    self.__lines = nil
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
        secretArithmetic = false, -- does a sum involving a secret give a secret, or raise?

        secretFormatting = true,  -- a widget formats a secret into its own text: MEASURED 2026-09-24, 876/876 lines
        healthPercentReadable = false, -- UnitHealthPercent: a plain number, or (as measured) a secret?
        healthPercentRaw = nil,        -- ... and the number it gives when readable
        units = {},         -- [token] = { name, player = true/false, class = "ROGUE" }
        playerName = options.playerName or "Purrdee",
        surname = options.surname,                 -- a WoW: Forever surname: "Purrdee Bubson"
        build70170 = options.build70170,           -- the surname in the realm slot, as the client does since Oct 1 2026
        freshLogin = options.freshLogin,           -- no realm slot yet (older clients, on a fresh login)
        coldLogin = options.coldLogin,             -- no name at all until PLAYER_LOGIN
        normalizedRealm = options.normalizedRealm, -- false: no GetNormalizedRealmName(), only the spaced GetRealmName()
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
    -- the NAME of whatever unit you asked about, not always the player s: "Targeting: <them>" is built
    -- on this, and a mock that ignores the unit token cannot tell the two apart
    -- The player's name as the client gives it: state.surname adds a WoW: Forever surname; state.build70170
    -- puts it in the realm slot, as the client does since Oct 1 2026 (UnitFullName("player") -> "Purrdee",
    -- "Bubson"; before: "Purrdee Bubson", "TestRealm"); state.freshLogin: no realm slot yet; state.coldLogin:
    -- no name at all until PLAYER_LOGIN.
    local function playerName()
        if state.coldLogin then
            return nil, nil
        end
        local name, slot = state.playerName, nil
        if state.surname and state.build70170 then
            slot = state.surname
        else
            if state.surname then
                name = name .. " " .. state.surname
            end
            if not state.freshLogin then
                slot = "TestRealm"
            end
        end
        return name, slot
    end
    global("UnitName", function(unitToken)
        if state.secretAnswers.UnitName then
            return Mock.SECRET
        end
        local unit = state.units[unitToken]
        if unit then
            return unit.name
        end
        local name, slot = playerName()
        if state.build70170 then
            return name, slot
        end
        return name
    end)
    global("UnitFullName", playerName)
    global("GetRealmName", function() return "Test Realm" end)
    global("GetNormalizedRealmName", function()
        if state.normalizedRealm == false then
            return nil -- a client without it: the spaced GetRealmName(), squeezed, must do
        end
        return "TestRealm"
    end)
    global("SlashCmdList", {})
    global("C_AddOns", { GetAddOnMetadata = function() return "0.1.0-test" end })
    global("CreateFrame", function(kind, name)
        local frame = newWidget(kind, name)
        Mock.frames[#Mock.frames + 1] = frame
        return frame
    end)
    global("UIParent", newWidget("Frame", "UIParent"))
    _G.UIParent.CreateFontString = function(_, name) return newWidget("FontString", name) end

    -- Units ---------------------------------------------------------------
    -- A value that is secret only behind the barrier. Outside it the plain number comes back, which
    -- is the whole of what is being tested.
    local function healthAnswer(name, read)
        global(name, function(unitToken)
            if state.secretAnswers[name] then
                return Mock.SECRET
            end
            local unit = state.units[unitToken]
            local value = read(unit)
            return value
        end)
    end

    local function unitAnswer(name, read)
        global(name, function(unit)
            if state.secretAnswers[name] then
                return Mock.SECRET, Mock.SECRET, Mock.SECRET
            end
            return read(state.units[unit])
        end)
    end
    unitAnswer("UnitExists", function(unit) return unit ~= nil end)
    -- health comes back SECRET for anyone but you, and for a pet the current is secret while the
    -- maximum is not: both shapes are in the error reports this was written from
    -- one creature, one name. Secret for units whose identity the client is protecting.
    global("UnitGUID", function(unitToken)
        if state.secretAnswers.UnitGUID then
            return Mock.SECRET
        end
        local unit = state.units[unitToken]
        return unit and ("GUID-" .. tostring(unit.name or unitToken)) or nil
    end)
    -- Percent of health, optionally through a curve of the caller's. Secret on this client unless a test
    -- says otherwise; the curve is ignored here until a rung is built on it.
    global("UnitHealthPercent", function(unit, usePredicted, curve)
        if state.healthPercentReadable then
            return state.healthPercentRaw or 90
        end
        return Mock.SECRET
    end)
    healthAnswer("UnitHealth", function(unit) return unit and unit.health end)
    healthAnswer("UnitHealthMax", function(unit) return unit and unit.healthMax end)
    -- is this unit that unit? (the token pair, not the table)
    global("UnitIsUnit", function(a, b)
        if state.secretAnswers.UnitIsUnit then
            return Mock.SECRET
        end
        local left, right = state.units[a], state.units[b]
        return left ~= nil and left == right
    end)
    -- the client answers range in BANDS, not yards: 1 inspect (~28), 2 trade (~11), 3 duel (~10)
    global("CheckInteractDistance", function(unitToken, index)
        if state.inCombat then
            -- MEASURED 2026-09-24: a blocked action in combat lockdown, dialog and all, pcall or not
            violation("CheckInteractDistance called in combat: a blocked action on this client")
            return nil
        end
        if state.secretAnswers.CheckInteractDistance then
            return Mock.SECRET
        end
        local unit = state.units[unitToken]
        local yards = unit and unit.yards
        if type(yards) ~= "number" then
            return nil
        end
        local limit = ({ [1] = 28, [2] = 11, [3] = 10 })[index]
        return limit ~= nil and yards <= limit
    end)
    -- happiness 1-3, damage %, loyalty
    -- 1 in range, 0 out, nil when the question does not apply (a spell you do not know, no target)
    global("IsSpellInRange", function(name, unitToken)
        local ranges = state.spellRanges or {}
        local reach = ranges[name]
        local unit = state.units[unitToken]
        if type(reach) ~= "number" or not unit or type(unit.yards) ~= "number" then
            return nil
        end
        return unit.yards <= reach and 1 or 0
    end)
    global("GetPetHappiness", function()
        if state.petHappiness == nil then
            return nil
        end
        return state.petHappiness, 100, state.petLoyalty
    end)
    global("BreakUpLargeNumbers", function(value) return tostring(value) end)
    unitAnswer("UnitPower", function(unit) return unit and unit.power end)
    unitAnswer("UnitPowerMax", function(unit) return unit and unit.powerMax end)
    -- (powerType, powerToken): a creature with no bar has neither
    global("UnitPowerType", function(unitToken)
        if state.secretAnswers.UnitPowerType then
            return Mock.SECRET, Mock.SECRET
        end
        local unit = state.units[unitToken]
        if not unit or not unit.powerToken then
            return nil, nil
        end
        return 0, unit.powerToken
    end)
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
        global("Enum", { TooltipDataType = { Item = 0, Spell = 1, Unit = 2, Object = 4 } })
        -- the character's level, and the game's highest
        global("UnitLevel", function(unit) return unit == "player" and (state.level or 30) or 0 end)
        global("GetMaxLevelForPlayerExpansion", function() return 60 end)
        -- an item's Use spell, and the words of a spell as the client resolves them for this character
        state.itemSpells = state.itemSpells or {}        -- [itemID] = { name, spellID }
        state.spellDescriptions = state.spellDescriptions or {} -- [spellID] = text ("" = not loaded yet)
        state.requestedSpells = {}
        global("GetItemSpell", function(itemID)
            local s = state.itemSpells[itemID]
            if not s then return nil end
            return s[1], s[2]
        end)
        state.spellTextures = state.spellTextures or {} -- [spellID] = file id
        global("C_Spell", {
            GetSpellDescription = function(spellID) return state.spellDescriptions[spellID] or "" end,
            RequestLoadSpellData = function(spellID) state.requestedSpells[#state.requestedSpells + 1] = spellID end,
            GetSpellTexture = function(spellID) return state.spellTextures[spellID] end,
        })
        global("TooltipDataProcessor", {
            AddTooltipPostCall = function(dataType, fn)
                postCalls[dataType] = postCalls[dataType] or {}
                table.insert(postCalls[dataType], fn)
            end,
        })
        -- Blizzard shows a unit tooltip: default anchor (world units), build the lines, run the post calls
        -- a spell or an item tooltip: the id arrives in the data, as Blizzard hands it over
        function Mock.showSpellTooltip(id, tooltip)
            tooltip = tooltip or G.GameTooltip
            for _, fn in ipairs(postCalls[G.Enum.TooltipDataType.Spell] or {}) do
                fn(tooltip, { type = G.Enum.TooltipDataType.Spell, id = id })
            end
        end

        function Mock.showItemTooltip(id, tooltip)
            tooltip = tooltip or G.GameTooltip
            for _, fn in ipairs(postCalls[G.Enum.TooltipDataType.Item] or {}) do
                fn(tooltip, { type = G.Enum.TooltipDataType.Item, id = id })
            end
        end

        -- a world object's tooltip: Blizzard's lines come with the data, the first being the name
        function Mock.showObjectTooltip(name, tooltip)
            tooltip = tooltip or G.GameTooltip
            for _, fn in ipairs(postCalls[G.Enum.TooltipDataType.Object] or {}) do
                fn(tooltip, { type = G.Enum.TooltipDataType.Object, lines = { { leftText = name } } })
            end
        end

        function Mock.showUnitTooltip(unitToken, tooltip)
            tooltip = tooltip or G.GameTooltip
            state.units.mouseover = state.units[unitToken]
            state.units.mouseovertarget = state.units[unitToken] and state.units[unitToken].target or nil
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
    state.coldLogin = false -- by PLAYER_LOGIN the client knows who you are
    Mock.fire("PLAYER_LOGIN")
    return ns, state
end

Mock.realPrint = REAL_PRINT

return Mock
