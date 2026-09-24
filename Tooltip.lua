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
    hp = { 0.55, 0.85, 0.45 },      -- green: the whole-and-healthy end of the scale below
    mana = { 0.35, 0.55, 1.00 },    -- blue
    energy = { 1.00, 0.96, 0.41 },  -- yellow
    rage = { 0.75, 0.15, 0.15 },    -- dark red
}

-- HEALTH MOVES. Full reads green, hurt reads amber, nearly gone reads red - what a health bar does, so
-- the number is worth a glance rather than just being there. Three stops, mixed between, because two
-- stops (green straight to red) passes through a muddy brown in the middle.
--
-- It only works where the numbers can be READ: a fraction needs current divided by maximum. A unit whose
-- health the client keeps secret has no fraction to colour by, so it takes the whole-and-healthy end and
-- stays there - and the colour then carries no meaning it has not earned.
local HEALTH_SCALE = {
    { at = 1.00, color = { 0.55, 0.85, 0.45 } }, -- whole
    { at = 0.50, color = { 0.95, 0.80, 0.30 } }, -- amber
    { at = 0.15, color = { 0.90, 0.25, 0.25 } }, -- nearly gone
}

local function healthColor(fraction)
    if type(fraction) ~= "number" then
        return HEALTH_SCALE[1].color
    end
    fraction = math.max(0, math.min(1, fraction))
    for index = 1, #HEALTH_SCALE - 1 do
        local upper, lower = HEALTH_SCALE[index], HEALTH_SCALE[index + 1]
        if fraction >= lower.at then
            local span = upper.at - lower.at
            local mix = span > 0 and (fraction - lower.at) / span or 1
            return {
                lower.color[1] + (upper.color[1] - lower.color[1]) * mix,
                lower.color[2] + (upper.color[2] - lower.color[2]) * mix,
                lower.color[3] + (upper.color[3] - lower.color[3]) * mix,
            }
        end
    end
    return HEALTH_SCALE[#HEALTH_SCALE].color
end
local PLAIN = { 0.90, 0.90, 0.90 }

-- There are half a dozen power tokens in the game and a tooltip fires every time the cursor crosses a
-- unit, so the label and the colour for a token are worked out ONCE and kept. Neither can change.
local labelCache, colorCache = {}, {}
local HEALTH_GREEN = { 0, 1, 0 } -- the bar's own colour (GameTooltipStatusBar's BarColor)

Tooltip.stats = { anchored = 0, anchorPath = "not used yet", coloured = 0, notPlayers = 0, unreadable = 0,
    healthRead = 0,      -- health lines written as text, both numbers readable
    healthHanded = 0,    -- ... and written by handing a SECRET straight to the font string
    healthRefused = 0,   -- ... and the times that was not allowed. See the note above addHealth.
    targetLines = 0, rangeLines = 0, moodLines = 0, idLines = 0, spellRangeLines = 0,
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

-- `deficit`: also say how much is MISSING. Worth it for health, where it is the number you act on -
-- whether this is worth a heal, and how big a one. Not for a power bar: nobody topped anybody up by
-- 2,970 mana, and the line is longer for nothing.
local function addResource(tooltip, unit, current, max, label, color, deficit)
    color = color or PLAIN
    if current == nil then
        return
    end

    -- `IsSecret` is asked before anything else: `max > 0` on a secret is itself the error
    if not ns.IsSecret(current) and not ns.IsSecret(max)
        and type(current) == "number" and type(max) == "number" and max > 0 then
        -- what is MISSING, which is the number you act on: whether this is worth a heal, and how big a
        -- one. Left off at full, where "-0" is noise.
        local missing = max - current
        local text = string.format("%s %s (%d%%)", BreakUpLargeNumbers(current), label,
            math.floor(current / max * 100 + 0.5))
        if deficit and missing > 0 then
            text = text .. "  -" .. BreakUpLargeNumbers(missing)
        end
        tooltip:AddLine(text, color[1], color[2], color[3])
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
    local current, maximum = rawValue(UnitHealth, unit), rawValue(UnitHealthMax, unit)
    -- a colour you set yourself beats the scale: you asked for that one, it does not move
    local yours = ns.cdb and ns.cdb.colors and ns.cdb.colors.hp
    local color
    if type(yours) == "table" and #yours == 3 then
        color = yours
    elseif not ns.IsSecret(current) and not ns.IsSecret(maximum)
        and type(current) == "number" and type(maximum) == "number" and maximum > 0 then
        color = healthColor(current / maximum)
    else
        color = HEALTH_SCALE[1].color -- no fraction to go on: the healthy end, claiming nothing
    end
    addResource(tooltip, unit, current, maximum, "hp", color, true)

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

------------------------------------------------------------------------
-- 4. The other things Blizzard leaves out
------------------------------------------------------------------------
local YOU_COLOR = { 1.00, 0.35, 0.35 }   -- they are hitting YOU
local THEM_COLOR = { 0.75, 0.75, 0.78 }
local RANGE_COLOR = { 0.65, 0.70, 0.80 }
local IN_RANGE_COLOR = { 0.55, 0.85, 0.45 }
local OUT_OF_RANGE_COLOR = { 0.85, 0.45, 0.40 }
local MOOD_COLORS = { { 0.90, 0.25, 0.25 }, { 0.95, 0.80, 0.30 }, { 0.55, 0.85, 0.45 } }
local MOOD_NAMES = { "unhappy", "content", "happy" }

-- WHO THEY ARE HITTING. The most useful line a tooltip can carry in a fight - is that caster on you or
-- on the healer - and Blizzard's has nothing like it. A unit's target is another unit, so its name may
-- be secret the same way a player's class is; unreadable simply means no line.
local function addTargetOfTarget(tooltip, unit)
    local theirTarget = unit .. "target"
    local exists = ns.Readable(UnitExists, theirTarget)
    if not (exists and exists[1] == true) then
        return
    end
    local isYou = ns.Readable(UnitIsUnit, theirTarget, "player")
    if isYou and isYou[1] == true then
        tooltip:AddLine("Targeting: YOU", YOU_COLOR[1], YOU_COLOR[2], YOU_COLOR[3])
        Tooltip.stats.targetLines = Tooltip.stats.targetLines + 1
        return
    end
    local name = ns.Readable(UnitName, theirTarget)
    if not (name and type(name[1]) == "string" and name[1] ~= "") then
        return -- the client will not say who: better nothing than "Targeting: someone"
    end
    tooltip:AddLine("Targeting: " .. name[1], THEM_COLOR[1], THEM_COLOR[2], THEM_COLOR[3])
    Tooltip.stats.targetLines = Tooltip.stats.targetLines + 1
end

-- HOW FAR. CheckInteractDistance answers in bands rather than yards, and the bands are what the client
-- is willing to say - so that is what is shown, rather than a made-up number. No secret values are
-- involved at all, which makes this the one addition here that cannot be defeated by them.
-- No tilde: it sits high in this font and reads badly, and "within" already says the number is a
-- ceiling rather than a measurement. The ceilings are Blizzards own - duel 9.9, trade 11.11, inspect 28.
local RANGE_BANDS = {
    { check = 3, text = "within 10 yd" },  -- duel
    { check = 2, text = "within 11 yd" },  -- trade
    { check = 1, text = "within 28 yd" },  -- inspect
}

-- ONE SPELL, EXACTLY. The bands above are the most CheckInteractDistance will say, and its widest
-- ceiling is 28 yards - which tells a hunter nothing about a shot that reaches 35. IsSpellInRange answers
-- for the spell you name instead: in, out, or nothing at all when the question does not apply (no target,
-- a spell you do not know, a friendly unit for a hostile spell). Nothing here is secret.
-- The spells you named, in order. A shaman wants two - a heal that reaches forty yards and a shock
-- that reaches twenty - and which of them is in range is two different questions about the same unit.
local function namedSpells()
    local setting = ns:GetOption("rangeSpell")
    if type(setting) ~= "string" or setting == "" then
        return {}
    end
    local names = {}
    for part in setting:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$")
        if part ~= "" then
            names[#names + 1] = part
        end
    end
    return names
end

local function spellRange(unit, name)
    local answer = ns.Readable(_G.IsSpellInRange, name, unit)
    local value = answer and answer[1]
    if value == nil then
        local modern = C_Spell and C_Spell.IsSpellInRange
        answer = modern and ns.Readable(modern, name, unit)
        value = answer and answer[1]
    end
    if value == nil then
        return nil -- the question does not apply, and a made-up answer would be worse than none
    end
    return (value == true or value == 1)
end

local function addSpellRange(tooltip, unit)
    for _, name in ipairs(namedSpells()) do
        local inRange = spellRange(unit, name)
        if inRange ~= nil then
            local color = inRange and IN_RANGE_COLOR or OUT_OF_RANGE_COLOR
            tooltip:AddLine(name .. (inRange and ": in range" or ": out of range"), color[1], color[2], color[3])
            Tooltip.stats.spellRangeLines = Tooltip.stats.spellRangeLines + 1
        end
    end
end

local function addRange(tooltip, unit)
    if type(CheckInteractDistance) ~= "function" then
        return
    end
    local isYou = ns.Readable(UnitIsUnit, unit, "player")
    if isYou and isYou[1] == true then
        return -- how far away you are from yourself is not a question
    end
    -- nil is "I will not say", NOT "out of range": claiming a distance the client never gave would be
    -- worse than saying nothing. Only a definite false from every band earns the last line.
    local answered = false
    for _, band in ipairs(RANGE_BANDS) do
        local answer = ns.Readable(CheckInteractDistance, unit, band.check)
        local value = answer and answer[1]
        if value ~= nil then
            answered = true
        end
        if value == true then
            tooltip:AddLine(band.text, RANGE_COLOR[1], RANGE_COLOR[2], RANGE_COLOR[3])
            Tooltip.stats.rangeLines = Tooltip.stats.rangeLines + 1
            return
        end
    end
    if not answered then
        return
    end
    tooltip:AddLine("over 28 yd", RANGE_COLOR[1], RANGE_COLOR[2], RANGE_COLOR[3])
    Tooltip.stats.rangeLines = Tooltip.stats.rangeLines + 1
end

-- YOUR PET'S MOOD. Hunter-only, and GetPetHappiness is a Classic-era call that may simply not be here -
-- in which case there is no line and nothing is broken.
local function addPetMood(tooltip, unit)
    local isPet = ns.Readable(UnitIsUnit, unit, "pet")
    if not (isPet and isPet[1] == true) then
        return
    end
    local answer = ns.Readable(_G.GetPetHappiness)
    local happiness = answer and answer[1]
    if type(happiness) ~= "number" or happiness < 1 or happiness > 3 then
        return
    end
    local loyalty = answer and answer[3]
    local color = MOOD_COLORS[happiness]
    local text = MOOD_NAMES[happiness]
    if type(loyalty) == "number" and loyalty > 0 then
        text = text .. "  (loyalty " .. loyalty .. ")"
    end
    tooltip:AddLine(text, color[1], color[2], color[3])
    Tooltip.stats.moodLines = Tooltip.stats.moodLines + 1
end

local function onUnitTooltip(tooltip)
    if tooltip ~= GameTooltip then
        return
    end
    local unit = unitOf(tooltip)
    if unit then
        if ns:GetOption("health") then
            ns.SafeCall(addHealth, tooltip, unit)
        end
        if ns:GetOption("petMood") then
            ns.SafeCall(addPetMood, tooltip, unit)
        end
        if ns:GetOption("targetOfTarget") then
            ns.SafeCall(addTargetOfTarget, tooltip, unit)
        end
        if ns:GetOption("range") then
            ns.SafeCall(addRange, tooltip, unit)
            ns.SafeCall(addSpellRange, tooltip, unit)
        end
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

-- THE ID, on a spell or an item. Dull for a player and invaluable for anyone writing a macro or an
-- addon: half a day went into finding out by hand whether Multi-Shot casts, and the answer began with
-- knowing its id. Blizzard's tooltip data hands it over directly - no lookup, nothing secret.
local ID_COLOR = { 0.55, 0.55, 0.60 }

local function addID(tooltip, data, what)
    if tooltip ~= GameTooltip or not ns:GetOption("ids") then
        return
    end
    local id = type(data) == "table" and data.id or nil
    if ns.IsSecret(id) or type(id) ~= "number" then
        return
    end
    tooltip:AddLine(what .. " " .. id, ID_COLOR[1], ID_COLOR[2], ID_COLOR[3])
    Tooltip.stats.idLines = Tooltip.stats.idLines + 1
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
Tooltip.hooks = { anchor = false, unit = false, spell = false, item = false }

ns:Listen("LOGIN", function()
    if type(hooksecurefunc) == "function" and type(_G.GameTooltip_SetDefaultAnchor) == "function" then
        hooksecurefunc("GameTooltip_SetDefaultAnchor", function(tooltip)
            ns.SafeCall(onDefaultAnchor, tooltip)
        end)
        Tooltip.hooks.anchor = true
    end
    -- the id on a spell or an item, each its own kind of tooltip
    local kinds = Enum and Enum.TooltipDataType
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and kinds then
        for what, kind in pairs({ ["spell"] = kinds.Spell, ["item"] = kinds.Item }) do
            if kind ~= nil then
                TooltipDataProcessor.AddTooltipPostCall(kind, function(tooltip, data)
                    ns.SafeCall(addID, tooltip, data, what)
                end)
                Tooltip.hooks[what] = true
            end
        end
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

-- Which extra lines you want. Each is a plain on/off; nothing here changes what a line SAYS, only
-- whether it is there at all.
local LINES = { health = "the hp / power lines", targetofttarget = false,
    targetoftarget = "who they are hitting", range = "roughly how far away", petmood = "your pet's mood",
    ids = "the spell or item id" }
local LINE_OPTIONS = { health = "health", targetoftarget = "targetOfTarget", range = "range",
    petmood = "petMood", ids = "ids" }

ns:RegisterCommand("lines", "which extra lines to show: /ftt lines range off, /ftt lines ids on, or /ftt lines to list them", function(rest)
    local which, value = string.match(rest or "", "^%s*(%S*)%s*(%S*)%s*$")
    which = string.lower(which or ""):gsub("[%s-]", "")
    local option = LINE_OPTIONS[which]
    if not option then
        ns:Print("usage: |cffffd100/ftt lines <name> on|off|r")
        for key, description in pairs(LINE_OPTIONS) do
            ns:Print(string.format("  %-16s %-26s %s", key, LINES[key] or "", ns:GetOption(description) and "on" or "off"))
        end
        return
    end
    value = string.lower(value or "")
    if value ~= "on" and value ~= "off" then
        ns:Print(which .. " is " .. (ns:GetOption(option) and "on" or "off") .. ". |cffffd100/ftt lines " .. which .. " on|off|r to change it.")
        return
    end
    ns:SetOption(option, value == "on")
    ns:Print(which .. ": " .. value .. ".")
end)

ns:RegisterCommand("range", "the range lines: /ftt range spell Healing Wave, Earth Shock names spells to check exactly; none drops them", function(rest)
    local word, name = string.match(rest or "", "^%s*(%S*)%s*(.-)%s*$")
    if string.lower(word or "") ~= "spell" then
        local chosen = ns:GetOption("rangeSpell")
        ns:Print("bands: " .. (ns:GetOption("range") and "on" or "off")
            .. " (|cffffd100/ftt lines range on|off|r). The widest the client will answer is 28 yd.")
        ns:Print("exact spells: " .. (type(chosen) == "string" and chosen ~= "" and ("|cffffd100" .. chosen .. "|r") or "none")
            .. "  - |cffffd100/ftt range spell Healing Wave, Earth Shock|r to name them (commas between).")
        return
    end
    if name == "" or string.lower(name) == "none" then
        ns:SetOption("rangeSpell", false)
        ns:Print("no spell checked: just the bands.")
        return
    end
    ns:SetOption("rangeSpell", name)
    ns:Print("checking |cffffd100" .. name .. "|r. A spell you do not know, or one that does not apply to what "
        .. "you are looking at, simply shows no line - so a heal and an attack can both be named, and each "
        .. "shows only where it makes sense.")
end)
