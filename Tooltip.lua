-- The game tooltip at the mouse, and players' names in their class colour.
--
-- 1. At the mouse. Every tooltip that has no place of its own - creatures and players in the world, and
--    everything in the UI that asks for "the default spot" - goes through Blizzard's
--    GameTooltip_SetDefaultAnchor(tooltip, parent), which owns it with ANCHOR_NONE and pins it to the
--    bottom right corner. A hooksecurefunc post-hook (ours runs after theirs, as addon code) then only
--    changes the ANCHOR TYPE to one that follows the cursor: tooltip:SetAnchorType(...).
--
--    Deliberately NOT tooltip:SetOwner(parent, "ANCHOR_CURSOR"), which is what tooltip addons usually do:
--    SetOwner clears the tooltip, which runs Blizzard's OnTooltipCleared script as addon code and writes
--    tainted values into the tooltip. On this client a tainted tooltip cannot show secret lines - Blizzard's
--    own GameTooltipDataMixin:SetWorldCursor says so ("... can result in the tooltip displaying no lines if
--    the new world cursor info ... has any secret line data"): enemies' tooltips in a fight would come up
--    empty. SetAnchorType runs no script at all. Same reason for never calling Show / Hide / ClearLines.
--
-- 2. Class colours. TooltipDataProcessor.AddTooltipPostCall is Blizzard's sanctioned hook for addons: it
--    runs us behind a taint barrier (forceinsecure + an attribute delegate) after a unit tooltip was
--    built. There the unit under the mouse is looked up and, for a PLAYER, the name line and the health
--    bar get the class colour - two widget calls with plain numbers; no tooltip text is read or written.
--    UnitClass is only secret for units that are not player-controlled (SecretWhenUnitIdentityRestricted),
--    and an unreadable answer simply means no colour.
local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local ANCHOR_TYPES = { right = "ANCHOR_CURSOR_RIGHT", left = "ANCHOR_CURSOR_LEFT", cursor = "ANCHOR_CURSOR" }

-- A colour per resource, keyed by the label. Blizzard's own PowerBarColor is darker than reads well on a
-- black tooltip (its MANA is flat 0,0,1), so these are lifted; anything not named here falls back to
-- PowerBarColor and then to plain light.
local RESOURCE_COLORS = {
    hp = { 0.90, 0.90, 0.90 },      -- light
    mana = { 0.35, 0.55, 1.00 },    -- blue
    energy = { 1.00, 0.96, 0.41 },  -- yellow
    rage = { 0.75, 0.15, 0.15 },    -- dark red
}
local PLAIN = { 0.90, 0.90, 0.90 }

-- There are half a dozen power tokens in the game and a tooltip fires every time the cursor crosses a
-- unit, so the label and the colour for a token are worked out ONCE and kept. Neither can change.
local labelCache, colorCache = {}, {}
local HEALTH_GREEN = { 0, 1, 0 } -- the bar's own colour (GameTooltipStatusBar's BarColor)

Tooltip.stats = { anchored = 0, anchorPath = "not used yet", coloured = 0, notPlayers = 0, unreadable = 0,
    healthRead = 0,      -- health lines written as text, both numbers readable
    healthHanded = 0,    -- ... and written by handing a SECRET straight to the font string
    healthRefused = 0,   -- ... and the times that was not allowed. See the note above addHealth.
}
Tooltip.samples = {} -- the last few unit tooltips, for /ftt diag
local barColoured = false

------------------------------------------------------------------------
-- 1. At the mouse
------------------------------------------------------------------------
local function onDefaultAnchor(tooltip)
    local anchorType = ANCHOR_TYPES[ns:GetOption("anchor")]
    if not anchorType or type(tooltip) ~= "table" then
        return -- "default": Blizzard's corner
    end
    if type(tooltip.SetAnchorType) ~= "function" then
        Tooltip.stats.anchorPath = "this client's tooltip has no SetAnchorType - left in Blizzard's corner"
        return
    end
    if anchorType == "ANCHOR_CURSOR" then
        tooltip:SetAnchorType(anchorType) -- (centred above the cursor: takes no offsets)
    else
        tooltip:SetAnchorType(anchorType, ns:GetOption("offsetX"), ns:GetOption("offsetY"))
    end
    Tooltip.stats.anchored = Tooltip.stats.anchored + 1
    Tooltip.stats.anchorPath = "SetAnchorType"
end

------------------------------------------------------------------------
-- 2. Class colours
------------------------------------------------------------------------
local function classColor(classFile)
    local colors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
    local color = type(colors) == "table" and colors[classFile] or nil
    if not color and C_ClassColor and C_ClassColor.GetClassColor then
        local answer = ns.Readable(C_ClassColor.GetClassColor, classFile)
        color = answer and answer[1] or nil
    end
    if type(color) == "table" and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
        return color.r, color.g, color.b
    end
    return nil
end

local function statusBarOf(tooltip)
    local bar = tooltip.StatusBar or _G[(tooltip.GetName and tooltip:GetName() or "") .. "StatusBar"]
    if type(bar) == "table" and type(bar.SetStatusBarColor) == "function" then
        return bar
    end
    return nil
end

local function restoreBar(tooltip)
    if barColoured then
        local bar = statusBarOf(tooltip)
        if bar then
            bar:SetStatusBarColor(HEALTH_GREEN[1], HEALTH_GREEN[2], HEALTH_GREEN[3])
        end
        barColoured = false
    end
end

local function remember(sample)
    sample.combat = InCombatLockdown() and true or false
    Tooltip.samples[#Tooltip.samples + 1] = sample
    if #Tooltip.samples > 12 then
        table.remove(Tooltip.samples, 1)
    end
end

-- The unit a tooltip is about: the one under the mouse (that also covers unit frames), else whatever the
-- tooltip itself says. nil when there is none, or the client would not say.
local function unitOf(tooltip)
    local exists = ns.Readable(UnitExists, "mouseover")
    if exists and exists[1] == true then
        return "mouseover"
    end
    local displayed = ns.Readable(tooltip.GetUnit, tooltip) -- name, unit token, guid
    if displayed and type(displayed[2]) == "string" then
        return displayed[2]
    end
    return nil
end

------------------------------------------------------------------------
-- 3. Health on the tooltip
--
-- A tooltip LINE IS A STRING, and a secret number cannot be put into one by any route on this client:
-- "12,345 / 20,000" needs concatenation and a percentage needs division, and both of those are READING.
-- That is as far as AKForeverHealthText can go, and why its tooltip says nothing about a player you
-- mouse over - both their current and maximum health are secret.
--
-- But a line is DRAWN BY A FONT STRING, and a font string takes a value straight from the API without
-- anybody looking at it - the same move the action bars use for a secret count in a fight. So the line
-- is added EMPTY (a plain string; nothing secret goes anywhere near AddLine) and the secret is then
-- handed to the font string Blizzard just made for it.
--
-- Whether this client allows that is written down nowhere, so it is attempted inside a pcall and the
-- answer is counted: `healthHanded` against `healthRefused` in '/ftt diag' says which, from a report
-- rather than from anybody's guess. Refused costs an empty line and nothing else.
--
-- (We are inside AddTooltipPostCall, which is Blizzard's sanctioned hook and runs behind their taint
-- barrier - the same reason the class colours are applied from here and not from a SetOwner hook.)
------------------------------------------------------------------------

-- The value itself, not ns.Readable's verdict on it: a secret is exactly what we want to keep here.
local function rawValue(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return nil
    end
    return value
end

-- One line of a resource: "700 hp (70%)" where the numbers can be read, and the number ALONE where they
-- cannot.
--
-- The label wants to come along for a secret unit too, and there is exactly one way to put it there: a
-- DOUBLE line, our label in the right column, the secret handed to the left. But a tooltip right-aligns
-- that column against its own edge, so the pair comes out flung to opposite sides of the tooltip -
-- "700 . . . . . . . . hp". There is no third option: a label in the SAME font string would have to be
-- concatenated onto the number, and concatenating is reading.
--
-- So a secret unit gets the bare number, in order: health first, then power. Ugly beats stretched -
-- and the COLOUR carries what the label cannot, which is why it is worth having.
-- A colour you set beats the one it ships with, always.
local function colorFor(label, token)
    local yours = ns.cdb and ns.cdb.colors and ns.cdb.colors[label]
    if type(yours) == "table" and #yours == 3 then
        return yours
    end
    local named = RESOURCE_COLORS[label]
    if named then
        return named
    end
    local key = token or label
    local cached = colorCache[key]
    if cached then
        return cached
    end
    local palette = _G.PowerBarColor -- focus, runic power, anything this client has that we have not named
    local color = (type(palette) == "table" and type(token) == "string") and palette[token] or nil
    if type(color) == "table" and type(color.r) == "number" and not ns.AnySecret(color.r, color.g, color.b) then
        colorCache[key] = { color.r, color.g, color.b }
    else
        colorCache[key] = PLAIN
    end
    return colorCache[key]
end

Tooltip.ColorFor = function(label, token) return colorFor(label, token) end

local function addResource(tooltip, unit, current, max, label, color)
    color = color or PLAIN
    if current == nil then
        return
    end

    -- `IsSecret` is asked before anything else: `max > 0` on a secret is itself the error
    if not ns.IsSecret(current) and not ns.IsSecret(max)
        and type(current) == "number" and type(max) == "number" and max > 0 then
        tooltip:AddLine(string.format("%s %s (%d%%)", BreakUpLargeNumbers(current), label,
            math.floor(current / max * 100 + 0.5)), color[1], color[2], color[3])
        Tooltip.stats.healthRead = Tooltip.stats.healthRead + 1
        return
    end

    -- added EMPTY, then the number goes onto the font string the tooltip just made for it. The line
    -- keeps the colour AddLine gave it, so a secret number is still told apart by it.
    tooltip:AddLine(" ", color[1], color[2], color[3])
    local lines = rawValue(tooltip.NumLines, tooltip)
    local fontString = type(lines) == "number" and _G[(tooltip:GetName() or "") .. "TextLeft" .. lines]
    if type(fontString) ~= "table" or type(fontString.SetText) ~= "function" then
        Tooltip.stats.healthRefused = Tooltip.stats.healthRefused + 1
        return
    end
    if pcall(fontString.SetText, fontString, current) then
        Tooltip.stats.healthHanded = Tooltip.stats.healthHanded + 1
    else
        Tooltip.stats.healthRefused = Tooltip.stats.healthRefused + 1
    end
end

-- What a unit runs on: "MANA" -> "mana", "RUNIC_POWER" -> "runic power". nil when the client will not
-- name it, because a label would then be a guess.
local function powerLabel(unit)
    local ok, _, token = pcall(UnitPowerType, unit)
    if not ok or ns.IsSecret(token) or type(token) ~= "string" or token == "" then
        return nil
    end
    local label = labelCache[token]
    if not label then
        label = (string.lower(token):gsub("_", " "))
        labelCache[token] = label
    end
    return label, token
end

local function addHealth(tooltip, unit)
    addResource(tooltip, unit, rawValue(UnitHealth, unit), rawValue(UnitHealthMax, unit), "hp",
        colorFor("hp"))

    local label, token = powerLabel(unit)
    if not label then
        return
    end
    local current, max = rawValue(UnitPower, unit), rawValue(UnitPowerMax, unit)
    -- most creatures have no power bar at all, and an empty one is not worth a line
    if not ns.IsSecret(max) and type(max) == "number" and max <= 0 then
        return
    end
    addResource(tooltip, unit, current, max, label, colorFor(label, token))
end

local function onUnitTooltip(tooltip)
    if tooltip ~= GameTooltip then
        return
    end
    local unit = unitOf(tooltip)
    if unit and ns:GetOption("health") then
        ns.SafeCall(addHealth, tooltip, unit)
    end
    if not ns:GetOption("classColors") then
        restoreBar(tooltip)
        return
    end
    local isPlayer = unit and ns.Readable(UnitIsPlayer, unit)
    if not isPlayer then
        Tooltip.stats.unreadable = Tooltip.stats.unreadable + 1
        restoreBar(tooltip)
        remember({ unit = unit or "none", result = "unreadable" })
        return
    end
    if isPlayer[1] ~= true then
        Tooltip.stats.notPlayers = Tooltip.stats.notPlayers + 1
        restoreBar(tooltip)
        return
    end
    local class = ns.Readable(UnitClass, unit) -- localized name, file name, id
    local r, g, b
    if class and type(class[2]) == "string" then
        r, g, b = classColor(class[2])
    end
    if not r then
        Tooltip.stats.unreadable = Tooltip.stats.unreadable + 1
        restoreBar(tooltip)
        remember({ unit = unit, result = class and "no colour for that class" or "class unreadable" })
        return
    end
    local name = _G[(tooltip:GetName() or "") .. "TextLeft1"]
    if type(name) == "table" and type(name.SetTextColor) == "function" then
        name:SetTextColor(r, g, b)
    end
    if ns:GetOption("classBar") then
        local bar = statusBarOf(tooltip)
        if bar then
            bar:SetStatusBarColor(r, g, b)
            barColoured = true
        end
    else
        restoreBar(tooltip)
    end
    Tooltip.stats.coloured = Tooltip.stats.coloured + 1
    remember({ unit = unit, result = "coloured", class = class[2] })
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
Tooltip.hooks = { anchor = false, unit = false }

ns:Listen("LOGIN", function()
    if type(hooksecurefunc) == "function" and type(_G.GameTooltip_SetDefaultAnchor) == "function" then
        hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip)
            ns.SafeCall(onDefaultAnchor, tooltip)
        end)
        Tooltip.hooks.anchor = true
    end
    local unitType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and unitType ~= nil then
        TooltipDataProcessor.AddTooltipPostCall(unitType, function(tooltip)
            ns.SafeCall(onUnitTooltip, tooltip)
        end)
        Tooltip.hooks.unit = true
    end
    ns:Log("hooks", Tooltip.hooks)
end)

------------------------------------------------------------------------
-- Commands
------------------------------------------------------------------------
local function describeAnchor()
    local mode = ns:GetOption("anchor")
    if mode == "default" then
        return "Blizzard's corner"
    elseif mode == "cursor" then
        return "centred above the mouse"
    end
    return mode .. " of the mouse, offset " .. ns:GetOption("offsetX") .. " / " .. ns:GetOption("offsetY")
end

ns:RegisterCommand("anchor", "'right' (default) / 'left' of the mouse, 'cursor' (centred above it) or 'default' (Blizzard's corner)", function(rest)
    local mode = string.lower(rest or "")
    if ANCHOR_TYPES[mode] or mode == "default" then
        ns:SetOption("anchor", mode)
    elseif mode ~= "" then
        ns:Print("usage: /ftt anchor right | left | cursor | default")
        return
    end
    ns:Print("tooltip:", describeAnchor() .. ".")
end)

ns:RegisterCommand("offset", "distance from the mouse for 'right' / 'left': /ftt offset <x> <y> (default 16 8)", function(rest)
    local x, y = string.match(rest or "", "^%s*(-?%d+)%s+(-?%d+)%s*$")
    if x then
        ns:SetOption("offsetX", tonumber(x))
        ns:SetOption("offsetY", tonumber(y))
    elseif (rest or "") ~= "" then
        ns:Print("usage: /ftt offset <x> <y>   e.g. /ftt offset 16 8")
        return
    end
    ns:Print("tooltip:", describeAnchor() .. ".")
end)

ns:RegisterCommand("health", "health on unit tooltips: 'on' (default) / 'off'. A unit whose health the client keeps secret shows the number alone - a percentage needs dividing, and dividing is reading", function(rest)
    local mode = string.lower(rest or "")
    if mode ~= "on" and mode ~= "off" then
        local stats = Tooltip.stats
        ns:Print("usage: /ftt health on | off   (now: " .. (ns:GetOption("health") and "on" or "off") .. ")")
        ns:Print(string.format("lines written: %d read outright, %d by handing over a secret, %d refused.",
            stats.healthRead, stats.healthHanded, stats.healthRefused))
        if stats.healthRefused > 0 and stats.healthHanded == 0 then
            ns:Print("this client will not take a secret on a tooltip line - |cffffd100/ftt health off|r stops it trying.")
        end
        return
    end
    ns:SetOption("health", mode == "on")
    ns:Print("health on tooltips: " .. mode .. ".")
end)

ns:RegisterCommand("class", "class colours: 'on' (default) / 'off'; 'bar on' / 'bar off' for the health bar", function(rest)
    local what, mode = string.match(string.lower(rest or ""), "^%s*(%S*)%s*(%S*)%s*$")
    if what == "on" or what == "off" then
        ns:SetOption("classColors", what == "on")
    elseif what == "bar" and (mode == "on" or mode == "off") then
        ns:SetOption("classBar", mode == "on")
    elseif what ~= "" then
        ns:Print("usage: /ftt class on | off | bar on | bar off")
        return
    end
    ns:Print("class colours:", ns:GetOption("classColors") and "on" or "off",
        "- health bar:", ns:GetOption("classBar") and "class colour" or "green")
end)

-- The colour of a line. "hp light" meant a pale grey here and something else to the person who asked
-- for it, which is the sort of thing worth settling with a command rather than another guess.
ns:RegisterCommand("color", "the colour of a line: /ftt color hp 66ff66, /ftt color mana 3388ff, or 'default'", function(rest)
    local which, value = string.match(rest or "", "^%s*(%S*)%s*(%S*)%s*$")
    which = string.lower(which or "")
    if which == "" then
        ns:Print("usage: |cffffd100/ftt color <hp | mana | energy | rage | ...> <hex, or default>|r")
        for _, key in ipairs({ "hp", "mana", "energy", "rage" }) do
            local c = ns.Tooltip.ColorFor(key)
            local hex = string.format("%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
            ns:Print(string.format("  %-8s |cff%s##%s|r%s", key, hex, hex,
                (ns.cdb.colors and ns.cdb.colors[key]) and "   (yours)" or ""))
        end
        return
    end
    ns.cdb.colors = ns.cdb.colors or {}
    if value == "" or string.lower(value) == "default" then
        ns.cdb.colors[which] = nil
        ns:Print(which .. ": back to the colour it ships with.")
        return
    end
    local hex = value:gsub("^#", "")
    if #hex == 3 then
        hex = hex:gsub("(%x)", "%1%1")
    end
    if #hex ~= 6 or hex:find("%X") then
        ns:Print("that is not a colour. A hex code, like |cffffd100" .. which .. " 66ff66|r.")
        return
    end
    ns.cdb.colors[which] = { tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255 }
    ns:Print(which .. " is now |cff" .. hex .. "##" .. hex .. "|r. Mouse over something to see it.")
end)
