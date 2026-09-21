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
local HEALTH_GREEN = { 0, 1, 0 } -- the bar's own colour (GameTooltipStatusBar's BarColor)

Tooltip.stats = { anchored = 0, anchorPath = "not used yet", coloured = 0, notPlayers = 0, unreadable = 0 }
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

local function onUnitTooltip(tooltip)
    if tooltip ~= GameTooltip then
        return
    end
    if not ns:GetOption("classColors") then
        restoreBar(tooltip)
        return
    end
    local unit = unitOf(tooltip)
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
