-- AKForeverTooltip scenario tests. Run from the repo root:  lua tests/run.lua
-- Every scenario loads a fresh copy of the addon into the mock client and fails if the addon raised ANY
-- Lua error or did one of the things that taint Blizzard's tooltip (see tests/wowmock.lua).
package.path = "./tests/?.lua;" .. package.path
local Mock = require("wowmock")

local failures, passed = {}, 0

local function near(actual, expected, tolerance, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        error((what or "value") .. ": expected about " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function check(condition, message)
    if not condition then
        error(message or "check failed", 2)
    end
end

local function equal(actual, expected, what)
    if actual ~= expected then
        error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local function scenario(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok and #Mock.errors > 0 then
        ok, err = false, "addon raised errors:\n      " .. table.concat(Mock.errors, "\n      ")
    end
    if ok and #Mock.taintViolations > 0 then
        ok, err = false, "taint risk: " .. table.concat(Mock.taintViolations, ", ")
    end
    if ok then
        passed = passed + 1
        Mock.realPrint("  ok    " .. name)
    else
        failures[#failures + 1] = name
        Mock.realPrint("  FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
    end
end

local function printed(text)
    for _, line in ipairs(Mock.printed) do
        if line:find(text, 1, true) then
            return true
        end
    end
    return false
end

local function start(options)
    local ns, state = Mock.install(options)
    state.units.rogue = { name = "Purr Rogie", player = true, class = "ROGUE" }
    state.units.shaman = { name = "Purrdee", player = true, class = "SHAMAN" }
    state.units.boar = { name = "Mottled Boar", player = false }
    return ns, state
end

local function color(widget, field)
    local c = widget[field]
    return c and string.format("%.2f %.2f %.2f", c[1], c[2], c[3]) or "none"
end

Mock.realPrint("AKForeverTooltip tests")

scenario("a tooltip sent to Blizzard's corner follows the mouse instead - by changing its anchor type only", function()
    local ns = start()
    Mock.asBlizzard(function() GameTooltip_SetDefaultAnchor(GameTooltip, UIParent) end) -- what Blizzard's UI calls
    equal(GameTooltip.__owner, UIParent, "Blizzard's own SetOwner stands: we never re-own the tooltip")
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR_RIGHT"); equal(GameTooltip.__offsetX, 16); equal(GameTooltip.__offsetY, 8)
    equal(ns.Tooltip.stats.anchorPath, "SetAnchorType"); equal(ns.Tooltip.stats.anchored, 1)

    SlashCmdList.AKFOREVERTOOLTIP("anchor cursor")
    Mock.asBlizzard(function() GameTooltip_SetDefaultAnchor(GameTooltip, UIParent) end)
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR"); equal(GameTooltip.__offsetX, 0, "centred above the mouse: no offsets")
    SlashCmdList.AKFOREVERTOOLTIP("anchor left")
    SlashCmdList.AKFOREVERTOOLTIP("offset 30 -4")
    Mock.asBlizzard(function() GameTooltip_SetDefaultAnchor(GameTooltip, UIParent) end)
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR_LEFT"); equal(GameTooltip.__offsetX, 30); equal(GameTooltip.__offsetY, -4)

    SlashCmdList.AKFOREVERTOOLTIP("anchor default")
    Mock.asBlizzard(function() GameTooltip_SetDefaultAnchor(GameTooltip, UIParent) end)
    equal(GameTooltip.__anchorType, "ANCHOR_NONE", "Blizzard's corner, untouched")
    check(printed("Blizzard's corner"))
    SlashCmdList.AKFOREVERTOOLTIP("anchor sideways"); check(printed("usage: /ftt anchor"))
    SlashCmdList.AKFOREVERTOOLTIP("offset lots"); check(printed("usage: /ftt offset"))
    equal(ns:GetOption("anchor"), "default")
    -- (the runner fails this scenario if SetOwner / ClearLines / Show / Hide were ever called by the addon)
end)

scenario("a player's name takes the class colour, the health bar only when asked; creatures keep Blizzard's colours", function()
    local ns = start()
    Mock.showUnitTooltip("rogue")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 0.96 0.41", "rogue yellow")
    equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00",
        "the bar stays Blizzard's green by default: recoloured, it flickers under a unit frame (Blizzard repaints it green on every refresh)")
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR_RIGHT", "and it is at the mouse")

    SlashCmdList.AKFOREVERTOOLTIP("class bar on") -- for those who want it anyway
    Mock.showUnitTooltip("rogue")
    equal(color(GameTooltipStatusBar, "__barColor"), "1.00 0.96 0.41", "asked for: the bar takes the class colour")
    Mock.showUnitTooltip("shaman")
    equal(color(GameTooltipTextLeft1, "__textColor"), "0.00 0.44 0.87", "shaman blue")

    Mock.showUnitTooltip("boar") -- (its class is a SECRET: not player-controlled)
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00", "Blizzard's colour stands")
    equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00", "the bar is green again")
    equal(ns.Tooltip.stats.coloured, 3, "the rogue twice (green bar, then coloured) and the shaman"); equal(ns.Tooltip.stats.notPlayers, 1)

    -- another tooltip showing a unit is not ours to colour: "the unit under the mouse" says nothing about it
    Mock.showUnitTooltip("rogue", ItemRefTooltip)
    equal(color(ItemRefTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00")
    equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00", "and the game tooltip's bar is left as it was")

    SlashCmdList.AKFOREVERTOOLTIP("class bar off")
    Mock.showUnitTooltip("rogue")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 0.96 0.41"); equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00")
    SlashCmdList.AKFOREVERTOOLTIP("class off")
    Mock.showUnitTooltip("shaman")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00", "switched off: Blizzard's colour")
    SlashCmdList.AKFOREVERTOOLTIP("class on"); SlashCmdList.AKFOREVERTOOLTIP("class nonsense")
    check(printed("usage: /ftt class"))
end)

scenario("secret answers (a fight, a stricter client) mean no colour - never an error", function()
    local ns, state = start()
    Mock.setCombat(true)
    for _, name in ipairs({ "UnitExists", "UnitIsPlayer", "UnitClass" }) do
        state.secretAnswers = { [name] = true, GetUnit = true }
        Mock.showUnitTooltip("rogue")
        equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00", name .. " secret: Blizzard's colour stands")
        equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00")
    end
    state.secretAnswers = {}
    Mock.showUnitTooltip("rogue")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 0.96 0.41", "readable again (players are, in a fight too)")
    Mock.setCombat(false)

    state.units.warlock = { name = "Someone", player = true, class = "WARLOCK" } -- no colour known for that class
    Mock.showUnitTooltip("warlock")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00")
    equal(ns.Tooltip.stats.unreadable, 4, "three secret answers + one unknown class - each counted as unreadable, none as a creature")
end)

scenario("clients that lack a piece: no SetAnchorType, no post calls, no tooltip at all - the rest still works, nothing breaks", function()
    local ns = start({ noSetAnchorType = true })
    Mock.showUnitTooltip("rogue")
    equal(GameTooltip.__anchorType, "ANCHOR_NONE", "left in Blizzard's corner rather than re-owned")
    check(ns.Tooltip.stats.anchorPath:find("no SetAnchorType", 1, true))
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 0.96 0.41", "class colours still work")

    ns = start({ noPostCalls = true })
    equal(ns.Tooltip.hooks.unit, false); equal(ns.Tooltip.hooks.anchor, true)
    Mock.asBlizzard(function() GameTooltip_SetDefaultAnchor(GameTooltip, UIParent) end)
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR_RIGHT")

    ns = start({ noTooltip = true })
    equal(ns.Tooltip.hooks.anchor, false)
end)

scenario("settings are account-wide and come back next session; diagnostics are SavedVariables-safe", function()
    local db = { options = { anchor = "cursor", classBar = false } }
    local ns = start({ db = db, bridge = { table = db } })
    equal(ns.savedStateSource, "bridge addon")
    Mock.showUnitTooltip("rogue")
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR"); equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00")

    SlashCmdList.AKFOREVERTOOLTIP("debug"); SlashCmdList.AKFOREVERTOOLTIP("debug"); SlashCmdList.AKFOREVERTOOLTIP("")
    check(printed("/ftt anchor"))
    SlashCmdList.AKFOREVERTOOLTIP("diag")
    Mock.fire("PLAYER_LOGOUT")
    local function assertPlain(value, path)
        local kind = type(value)
        if kind == "table" then
            check(getmetatable(value) == nil, path .. ": a frame (or other object) got into the report")
            for k, v in pairs(value) do
                check(type(k) == "string" or type(k) == "number", path .. ": bad key type " .. type(k))
                assertPlain(v, path .. "." .. tostring(k))
            end
        else
            check(kind == "string" or kind == "number" or kind == "boolean", path .. ": " .. kind)
        end
    end
    local report = AKForeverTooltipDB.diag
    assertPlain(report, "diag")
    equal(report.hooks.anchor, true); equal(report.hooks.unit, true)
    equal(report.stats.coloured, 1); equal(report.samples[1].class, "ROGUE"); equal(report.client.setAnchorType, "function")
    equal(#report.errors, 0); equal(#report.blockedActions, 0)
end)

scenario("health on a unit tooltip: the full line when both numbers can be read", function()
    local ns, state = start()
    state.units.me = { name = "Purr Gola", player = true, class = "SHAMAN",
        health = 700, healthMax = 1000, power = 30, powerMax = 3000, powerToken = "MANA" }
    Mock.showUnitTooltip("me")
    local lines = GameTooltip.__lines or {}
    equal(#lines, 2, "what it has, and what it runs on")
    equal(lines[1].text, "700 hp (-300)", "the number, and what is missing from it")
    equal(lines[2].text, "30 mana (-2970)", "power too")
    equal(lines[2].r, 0.35, "mana is blue"); equal(lines[2].b, 1.00)
    equal(ns.Tooltip.stats.healthRead, 2, "two lines read outright")
    equal(ns.Tooltip.stats.healthHanded, 0)

    -- health is coloured by how much is left, not by one fixed colour. (Each look below reads the unit
    -- again, so the counts above are checked before this and not after.)
    local function healthColorAt(value)
        state.units.me.health = value
        GameTooltip.__lines = nil
        Mock.showUnitTooltip("me")
        local line = GameTooltip.__lines[1]
        return line.r, line.g, line.b
    end
    local r, g = healthColorAt(1000)
    near(r, 0.55, 0.01, "whole: green"); near(g, 0.85, 0.01)
    r, g = healthColorAt(500)
    near(r, 0.95, 0.01, "half: amber"); near(g, 0.80, 0.01)
    r, g = healthColorAt(100)
    near(r, 0.90, 0.01, "nearly gone: red"); near(g, 0.25, 0.01)
    check(select(1, healthColorAt(700)) > 0.55, "and it moves between them rather than jumping")
    state.units.me.health = 700
end)

scenario("a power type the client will not name gets no line: a label would be a guess", function()
    local ns, state = start()
    state.units.me = { name = "Purr Gola", player = true, class = "SHAMAN",
        health = 700, healthMax = 1000, power = 30, powerMax = 3000, powerToken = "MANA" }
    state.secretAnswers.UnitPowerType = true
    Mock.showUnitTooltip("me")
    equal(#(GameTooltip.__lines or {}), 1, "health only")
    equal((GameTooltip.__lines or {})[1].text, "700 hp (-300)")
end)

scenario("a creature with no power bar gets no second line", function()
    local ns, state = start()
    state.units.boar2 = { name = "Mottled Boar", player = false, health = 40, healthMax = 40 }
    Mock.showUnitTooltip("boar2")
    equal(#(GameTooltip.__lines or {}), 1)
    equal((GameTooltip.__lines or {})[1].text, "40 hp", "at full there is nothing missing to show")
end)

scenario("RUNIC_POWER reads as 'runic power'", function()
    local ns, state = start()
    state.units.dk = { name = "Grim", player = true, class = "WARRIOR",
        health = 10, healthMax = 100, power = 50, powerMax = 100, powerToken = "RUNIC_POWER" }
    Mock.showUnitTooltip("dk")
    equal((GameTooltip.__lines or {})[2].text, "50 runic power (-50)")
end)

scenario("health the client keeps SECRET is handed to the line's font string, never read", function()
    local ns, state = start()
    state.secretFormatting = false -- the stricter world: the bare route is all a client like that leaves
    state.units.them = { name = "Launcelot", player = true, class = "ROGUE",
        health = Mock.SECRET, healthMax = Mock.SECRET }
    Mock.showUnitTooltip("them")

    local lines = GameTooltip.__lines or {}
    equal(#lines, 1, "a line was still added")
    equal(lines[1].text, " ", "added EMPTY: nothing secret goes anywhere near AddLine")
    equal(lines[1].right, nil, "and no right-hand label: that column is flung to the tooltip s far edge")
    equal(_G["GameTooltipTextLeft" .. #lines].__text, Mock.SECRET, "the secret itself, handed straight over")
    equal(ns.Tooltip.stats.healthHanded, 1)
    equal(ns.Tooltip.stats.healthRead, 0, "nothing was read, so no percentage was claimed")
end)

scenario("a secret current with a readable maximum is still never divided", function()
    -- measured on a pet: the current is secret, the maximum is not
    local ns, state = start()
    state.units.pet = { name = "Wolf", player = false, health = Mock.SECRET, healthMax = 587 }
    Mock.showUnitTooltip("pet")
    equal(ns.Tooltip.stats.healthHanded, 1)
    equal(ns.Tooltip.stats.healthRead, 0)
end)

-- The three rungs. Which one this client is on is not something the tests can settle - only the game
-- can - so the addon asks, and all three answers have to come out right.
-- measured in the game: this is the rung this client is actually on
scenario("... the maximum beside it where sums are refused but the maximum can be read", function()
    local ns, state = start()
    state.secretFormatting = true -- but secretArithmetic stays false
    state.units.me = { name = "Purrdee", player = true, class = "SHAMAN",
        health = Mock.SECRET, healthMax = 1000 }
    Mock.showUnitTooltip("me")

    equal(_G["GameTooltipTextLeft" .. #(GameTooltip.__lines or {})].__text, "<SECRET> / 1000 hp",
        "no subtraction anywhere: both numbers on the line, and the sum left to the reader")
    equal(ns.Tooltip.stats.healthOfMax, 1)
end)

scenario("... its label alone when the maximum is secret too", function()
    local ns, state = start()
    state.secretFormatting = true
    state.units.them = { name = "Launcelot", player = true, class = "ROGUE",
        health = Mock.SECRET, healthMax = Mock.SECRET }
    Mock.showUnitTooltip("them")

    equal(_G["GameTooltipTextLeft" .. #(GameTooltip.__lines or {})].__text, "<SECRET> hp")
    equal(ns.Tooltip.stats.healthLabelled, 1)
    equal(ns.Tooltip.stats.healthOfMax, 0, "there was no maximum to put beside it")
end)

scenario("... and the bare number where it allows neither, exactly as before", function()
    local ns, state = start()
    state.secretFormatting = false -- the stricter world, deliberately
    state.units.me = { name = "Purrdee", player = true, class = "SHAMAN",
        health = Mock.SECRET, healthMax = 1000 }
    Mock.showUnitTooltip("me")

    equal(_G["GameTooltipTextLeft" .. #(GameTooltip.__lines or {})].__text, Mock.SECRET,
        "handed straight over, as it always was")
    equal(ns.Tooltip.stats.healthHanded, 1)
end)

scenario("a maximum that is ALSO secret gets the label but never a made-up deficit", function()
    local ns, state = start()
    state.secretArithmetic, state.secretFormatting = true, true
    state.units.them = { name = "Launcelot", player = true, class = "ROGUE",
        health = Mock.SECRET, healthMax = Mock.SECRET }
    Mock.showUnitTooltip("them")

    equal(_G["GameTooltipTextLeft" .. #(GameTooltip.__lines or {})].__text, "<SECRET> hp")
    equal(ns.Tooltip.stats.healthOfMax, 0, "and nothing to put beside it either")
end)

scenario("the client is asked what it allows once, not once per tooltip", function()
    local ns, state = start()
    state.secretFormatting = true
    state.units.them = { name = "Launcelot", player = true, class = "ROGUE",
        health = Mock.SECRET, healthMax = Mock.SECRET }

    -- a secret maximum cannot answer the deficit question, so it stays open ...
    Mock.showUnitTooltip("them")
    local asked = 0
    local made = UIParent.CreateFontString
    UIParent.CreateFontString = function(...) asked = asked + 1; return made(...) end

    -- ... and a readable one closes it, after which nothing is asked again
    state.units.pet = { name = "Wolf", player = false, health = Mock.SECRET, healthMax = 587 }
    for _ = 1, 5 do Mock.showUnitTooltip("pet") end
    equal(asked, 0, "the font string it asks on is made once and kept")
    equal(ns.Tooltip.stats.healthLabelled + ns.Tooltip.stats.healthOfMax, 6)
    equal(#Mock.errors, 0, "and nothing raised along the way")
end)

scenario("what the client answered about secrets reaches the saved file, and is plain enough to save", function()
    local ns, state = start()
    state.secretFormatting = true -- this client will format a secret, but will not do sums on one
    state.units.pet = { name = "Wolf", player = false, health = Mock.SECRET, healthMax = 587 }

    equal(ns.Tooltip.secretRules.formatsASecret, "not asked yet", "nothing is claimed before a secret turns up")
    Mock.showUnitTooltip("pet")
    equal(ns.Tooltip.secretRules.formatsASecret, "yes")


    -- and it survives into the snapshot, as strings: a nil would simply vanish from the saved file
    SlashCmdList.AKFOREVERTOOLTIP("diag")
    equal(AKForeverTooltipDB.diag.client.secretRules.formatsASecret, "yes")

end)

scenario("a blocked action arrives with the trace of the tooltip that caused it: which one, whose, which steps", function()
    local ns, state = start()
    state.units.me = { name = "Purr Gola", player = true, class = "SHAMAN", health = 300, healthMax = 1000 }
    state.inCombat = true
    Mock.showUnitTooltip("me")

    -- the client speaks up after the handler has returned, naming only the addon and "UNKNOWN()"
    Mock.fire("ADDON_ACTION_BLOCKED", "AKForeverTooltip", "UNKNOWN()")

    local entry = ns.blockedActions[1]
    check(entry, "recorded")
    check(entry.trace:find("unit post-call on GameTooltip (owner UIParent, combat)", 1, true), entry.trace)
    check(entry.trace:find("name colour", 1, true), "the colour step is in it")
    check(entry.trace:find("health AddLine", 1, true), "and the health line")
    check(entry.before[1] and entry.before[1]:find("default anchor", 1, true), "the anchor hook ran just before it")

    -- and it is plain enough to save
    SlashCmdList.AKFOREVERTOOLTIP("diag")
    check(AKForeverTooltipDB.diag.blockedActions[1].trace:find("unit post-call", 1, true))
end)

scenario("no arithmetic on a secret, anywhere, ever - a refused one is a blocked action, dialog and all", function()
    -- the mock's SECRET raises on arithmetic like the game does; here it also COUNTS the attempts
    local ns, state = start()
    local attempts = 0
    local meta = getmetatable(Mock.SECRET)
    local originalSub = meta.__sub
    meta.__sub = function(...) attempts = attempts + 1; return originalSub(...) end
    state.secretFormatting = true

    -- every shape of unit the addon ever meets, hovered twice each
    state.units.me = { name = "Purrdee", player = true, class = "SHAMAN", health = Mock.SECRET, healthMax = 1000 }
    state.units.them = { name = "Launcelot", player = true, class = "ROGUE", health = Mock.SECRET, healthMax = Mock.SECRET }
    state.units.pet = { name = "Wolf", player = false, health = Mock.SECRET, healthMax = 587 }
    for _ = 1, 2 do
        for _, unit in ipairs({ "me", "them", "pet" }) do Mock.showUnitTooltip(unit) end
    end
    meta.__sub = originalSub

    equal(attempts, 0, "not once, not even inside pcall, not even to find out")
    equal(#Mock.errors, 0)
end)

scenario("health can be switched off, and then nothing is added at all", function()
    local ns, state = start()
    SlashCmdList.AKFOREVERTOOLTIP("health off")
    state.units.me = { name = "Purr Gola", player = true, class = "SHAMAN", health = 300, healthMax = 1000 }
    Mock.showUnitTooltip("me")
    equal(#(GameTooltip.__lines or {}), 0)
    equal(ns.Tooltip.stats.healthRead + ns.Tooltip.stats.healthHanded, 0)
end)

local function textsOf(tooltip)
    local out = {}
    for _, line in ipairs((tooltip or GameTooltip).__lines or {}) do
        out[#out + 1] = tostring(line.text)
    end
    return table.concat(out, " | ")
end

-- the same without the inline icons
local function plainTexts(tooltip)
    return (textsOf(tooltip):gsub("|T[^|]*|t ?", ""))
end

scenario("who they are hitting: YOU stands out, somebody else is named, and silence when the client will not say", function()
    local ns, state = start()
    state.units.you = { name = "Purr Gola", player = true, class = "SHAMAN", health = 10, healthMax = 10 }
    state.units.boar = { name = "Mottled Boar", player = false, health = 40, healthMax = 40 }
    state.units.player = state.units.you -- UnitIsUnit(x, "player") compares the tables

    state.units.boar.target = state.units.you
    Mock.showUnitTooltip("boar")
    check(textsOf():find("Targeting: YOU", 1, true), textsOf())

    -- somebody else, by name
    state.units.other = { name = "Launcelot", player = true, class = "ROGUE" }
    state.units.boar.target = state.units.other
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(textsOf():find("Targeting: Launcelot", 1, true), textsOf())

    -- a name the client keeps to itself: no line rather than "Targeting: somebody"
    state.secretAnswers.UnitName = true
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not textsOf():find("Targeting", 1, true), "no guess: " .. textsOf())
    state.secretAnswers.UnitName = nil

    -- and nothing at all when they are hitting nobody
    state.units.boar.target = nil
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not textsOf():find("Targeting", 1, true))
end)

scenario("how far away, in the bands the client is willing to answer", function()
    local ns, state = start()
    state.units.player = { name = "Purr Gola", player = true }
    state.units.boar = { name = "Mottled Boar", player = false, yards = 8 }

    local function bandAt(yards)
        state.units.boar.yards = yards
        GameTooltip.__lines = nil
        Mock.showUnitTooltip("boar")
        return textsOf()
    end
    check(bandAt(8):find("within 10 yd", 1, true), bandAt(8))
    check(bandAt(10.5):find("within 11 yd", 1, true), bandAt(10.5))
    check(bandAt(20):find("within 28 yd", 1, true), bandAt(20))
    check(bandAt(40):find("over 28 yd", 1, true), bandAt(40))

    -- a client that will not measure says nothing, rather than "further than 28"
    state.units.boar.yards = nil
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not textsOf():find("yd", 1, true), "silence, not a guess: " .. textsOf())

    -- and it never asks how far you are from yourself
    state.units.me = state.units.player
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("me")
    check(not textsOf():find("yd", 1, true))
end)

scenario("in a fight the range bands are not asked for at all - that call is a blocked action", function()
    local ns, state = start()
    state.units.boar = { name = "Mottled Boar", player = false, yards = 5 }

    Mock.showUnitTooltip("boar")
    local function rangeLines()
        local n = 0
        for _, line in ipairs(GameTooltip.__lines or {}) do
            if type(line.text) == "string" and line.text:find(" yd", 1, true) then n = n + 1 end
        end
        return n
    end
    check(rangeLines() > 0, "out of a fight the band line is there")
    equal(#Mock.taintViolations, 0)

    state.inCombat = true
    GameTooltip.__lines = {} -- the mock keeps lines across hovers; the game rebuilds the tooltip
    Mock.showUnitTooltip("boar")
    equal(rangeLines(), 0, "in a fight it is simply absent")
    equal(#Mock.taintViolations, 0, "and the client was never asked")
    equal(ns.Tooltip.stats.rangeSkippedInCombat, 1)
    equal(#Mock.errors, 0)
end)

scenario("your own pet's mood, and only your own pet's", function()
    local ns, state = start()
    state.units.wolf = { name = "Wolf", player = false, health = 500, healthMax = 500 }
    state.units.pet = state.units.wolf
    state.petHappiness, state.petLoyalty = 3, 6
    Mock.showUnitTooltip("wolf")
    check(textsOf():find("happy", 1, true), textsOf())
    check(textsOf():find("loyalty 6", 1, true), textsOf())

    state.petHappiness = 1
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("wolf")
    check(textsOf():find("unhappy", 1, true), textsOf())

    -- somebody else's pet is not your pet
    state.units.pet = nil
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("wolf")
    check(not textsOf():find("happy", 1, true), textsOf())

    -- a client without the call at all: no line, nothing broken
    state.units.pet = state.units.wolf
    state.petHappiness = nil
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("wolf")
    check(not textsOf():find("happy", 1, true))
end)

scenario("the id on a spell and on an item, and never on a unit", function()
    local ns, state = start()
    Mock.showSpellTooltip(2643)
    check(textsOf():find("spell 2643", 1, true), textsOf())

    GameTooltip.__lines = nil
    Mock.showItemTooltip(6529)
    check(textsOf():find("item 6529", 1, true), textsOf())

    -- switched off
    SlashCmdList.AKFOREVERTOOLTIP("lines ids off")
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(2643)
    check(not textsOf():find("spell", 1, true), textsOf())
end)

scenario("a spell's words and its mana: damage per mana, heal per mana - ranges by their middle, over time in full, ticks counted; yards, seconds, percentages and absorbs are no amounts", function()
    local ns = start()
    local A = ns.Spell.Amounts
    local function amounts(text)
        local t = A(text)
        return t and string.format("%s/%s", tostring(t.damage), tostring(t.heal)) or "none"
    end
    -- Frostbolt: a range, then a slow with a percentage and seconds
    equal(amounts("Launches a bolt of frost at the enemy, causing 20 to 22 Frost damage and slowing movement speed by 40% for 5 sec."), "21.0/nil")
    -- Fireball: direct plus over time
    equal(amounts("Hurls a fiery ball that causes 14 to 22 Fire damage and an additional 2 Fire damage over 4 sec."), "20.0/nil")
    -- Shadow Word: Pain, Corruption: over time only
    equal(amounts("A word of darkness that causes 30 Shadow damage over 18 sec."), "30/nil")
    -- Immolate
    equal(amounts("Burns the enemy for 11 Fire damage and then an additional 20 Fire damage over 15 sec."), "31/nil")
    -- Arcane Missiles: per second, for three seconds
    equal(amounts("Launches Arcane Missiles at the enemy, causing 26 Arcane damage each second for 3 sec."), "78/nil")
    -- every 2 sec for 10 sec
    equal(amounts("Deals 12 Nature damage every 2 sec for 10 sec."), "60.0/nil")
    -- heals
    equal(amounts("Heal your target for 47 to 58."), "nil/52.5")
    equal(amounts("Heals a friendly target for 36 to 47."), "nil/41.5")
    -- Renew: "damage" in a heal's clause is a heal
    equal(amounts("Heals the target of 45 damage over 15 sec."), "nil/45")
    -- Regrowth: direct, and another over time
    equal(amounts("Heals a friendly target for 93 to 107 and another 98 over 21 sec."), "nil/198.0")
    -- Holy Nova: both
    equal(amounts("Causes an explosion of holy light around the caster, causing 29 to 34 Holy damage to all enemy targets within 10 yards and healing all party members within 10 yards for 52 to 60."), "31.5/56.0")
    -- Chain Heal: the first target only; "3 total targets" and "50%" are no amounts
    equal(amounts("Heals the friendly target for 332 to 381, then jumps to heal additional nearby targets. Each jump reduces the effectiveness of the heal by 50%. Heals 3 total targets."), "nil/356.5")
    -- a shield absorbs; a buff and nothing at all count nothing (a drain is damage since 2026-11-13)
    equal(amounts("Draws on the soul of the party member to shield them, absorbing 48 damage. Lasts 30 sec."), "none")
    equal(amounts("Increases the target's Intellect by 7 for 30 min."), "none")
    equal(amounts("Transfers 10 health every 1 sec from the target to the caster. Lasts 5 sec."), "50.0/nil")
    equal(amounts(""), "none")
    equal(amounts("Increases armor by 1,200 for 30 min."), "none")
    equal(amounts("Heals a friendly target for 1,020 to 1,180."), "nil/1100.0")
    -- "health" is no heal, and minutes are no amount (the totems' words, 2026-11-07)
    equal(amounts("Summons a Magma Totem with 5 health at the feet of the caster for 20 sec that causes 22 Fire damage to creatures within 8 yards every 2 seconds."), "22/nil")
    equal(amounts("Summons a Healing Stream Totem with 5 health at the feet of the caster for 1 min that heals group members within 20 yards for 6 every 2 seconds."), "nil/6")
end)

scenario("damage per second: the damage over the seconds the cast takes - a cast time, a channel's length, an instant's global cooldown shortened by haste", function()
    local ns, state = start()
    state.spellCrit = 0 -- no crit here: the seconds alone (the next scenario counts the crits)
    -- Shadow Bolt, a 3 sec cast: 3 sec
    state.spellDescriptions[686] = "Sends a shadowy bolt at the enemy, causing 13 to 18 Shadow damage."
    state.spellCosts = { [686] = 25 }
    state.castTimes = { [686] = 3000 }
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 5.2 |", 1, true), textsOf())
    for _, line in ipairs(GameTooltip.__lines) do
        if tostring(line.text):find("per second", 1, true) then equal(line.text, "Damage per second: 5.2", "nothing after the number") end
    end
    -- the line sits right under the per mana line
    local texts = {}
    for _, line in ipairs(GameTooltip.__lines) do texts[#texts + 1] = line.text or line[1] end
    for i, t in ipairs(texts) do
        if tostring(t):find("Damage per mana", 1, true) then
            check(tostring(texts[i + 1]):find("Damage per second", 1, true), "right under: " .. tostring(texts[i + 1]))
        end
    end
    -- a cast time the client shortened (haste is in it already): 2.5 sec
    state.castTimes[686] = 2500
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 6.2 |", 1, true), textsOf())
    -- an instant: the global cooldown, 1.5 sec ...
    state.spellDescriptions[8042] = "Instantly shocks the target with concussive force, causing 19 to 22 Nature damage."
    state.spellCosts[8042] = 30
    state.castTimes[8042] = 0
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(8042)
    check(textsOf():find("Damage per second: 13.7 |", 1, true), textsOf())
    -- ... shortened by 25% spell haste: 1.2 sec
    state.spellHaste = 25
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(8042)
    check(textsOf():find("Damage per second: 17.1 |", 1, true), textsOf())
    -- ... never below 1 sec; a secret haste counts as none
    state.spellHaste = 100
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(8042)
    check(textsOf():find("Damage per second: 20.5 |", 1, true), textsOf())
    state.spellHaste = Mock.SECRET
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(8042)
    check(textsOf():find("Damage per second: 13.7 |", 1, true), textsOf())
    state.spellHaste = nil
    -- a channel: its length from the words, not the GCD
    state.spellDescriptions[5143] = "Launches Arcane Missiles at the enemy, causing 26 Arcane damage each second for 3 sec."
    state.spellCosts[5143] = 85
    state.castTimes[5143] = 0
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(5143, nil, { { leftText = "Arcane Missiles" }, { leftText = "85 Mana" }, { leftText = "Channeled" },
        { leftText = "Launches Arcane Missiles at the enemy, causing 26 Arcane damage each second for 3 sec." } })
    check(textsOf():find("Damage per second: 26.0 |", 1, true), textsOf())
    -- no cast time from the client: the tooltip's "1.5 sec cast"
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(403, nil, { { leftText = "Lightning Bolt", rightText = "Rank 1" }, { leftText = "15 Mana", rightText = "30 yd range" },
        { leftText = "1.5 sec cast" }, { leftText = "Casts a bolt of lightning at the target for 15 to 17 Nature damage." } })
    check(textsOf():find("Damage per second: 10.7 |", 1, true), textsOf())
    -- a heal: no damage per second (its own heal per second, next scenario); switched off by /ftt lines dps off
    state.spellDescriptions[2050] = "Heal your target for 47 to 58."
    state.spellCosts[2050] = 30
    state.castTimes[2050] = 1500
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(2050)
    check(not textsOf():find("Damage per second", 1, true), textsOf())
    SlashCmdList.AKFOREVERTOOLTIP("lines dps off")
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per mana", 1, true) and not textsOf():find("Damage per second", 1, true), textsOf())
    SlashCmdList.AKFOREVERTOOLTIP("lines dps on")
    equal(#Mock.errors, 0, Mock.errors[1])
end)

scenario("effective damage per second: crit chance by school, crits over time too, crit size raised by your own talents by their words", function()
    local ns, state = start()
    state.spellNames = { [686] = "Shadow Bolt", [172] = "Corruption", [133] = "Fireball", [8050] = "Flame Shock" }
    state.spellDescriptions[686] = "Sends a shadowy bolt at the enemy, causing 13 to 18 Shadow damage."
    state.spellDescriptions[172] = "Corrupts the target, causing 40 Shadow damage over 12 sec."
    state.spellDescriptions[133] = "Hurls a fiery ball that causes 14 to 22 Fire damage and an additional 2 Fire damage over 4 sec."
    state.spellCosts = { [686] = 25, [172] = 35, [133] = 30 }
    state.castTimes = { [686] = 3000, [172] = 0, [133] = 1500 }
    -- 10% crit for Shadow (school 6), 20% for Fire (3): Shadow Bolt 15.5 x (1 + 0.1 x 0.5) = 16.3 over 3 sec
    state.spellCrit = { [6] = 10, [3] = 20 }
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 5.4 |", 1, true), textsOf())
    -- a dot crits: Corruption 40 x 1.05 = 42 over the GCD
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(172)
    check(textsOf():find("Damage per second: 28.0 |", 1, true), textsOf())
    check(textsOf():find("Crit: 60 over time", 1, true), "the crit row: over time crits " .. textsOf())
    -- Fire: its own school's chance - (18 + 2) x 1.1 = 22
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(133)
    check(textsOf():find("Damage per second: 14.7 |", 1, true), textsOf())

    -- Ruin-like: the Destruction tree's crits x2 (Shadow Bolt, not Corruption)
    state.talents = { { rank = 1, text = "Increases the critical strike damage bonus of your Destruction spells by 100%.", spell = 17959 } }
    state.spellNames[17959] = "Ruin"
    ns.Spell.ForgetTalents()
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    -- 15.5 x (1 + 0.1 x 1) = 17.05
    check(textsOf():find("Damage per second: 5.7 |", 1, true), textsOf())
    check(textsOf():find("Crit: 26 to 36", 1, true), "the crit row by the talent's size: " .. textsOf())
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(172)
    check(textsOf():find("Damage per second: 28.0 |", 1, true), "Corruption is no Destruction spell: " .. textsOf())

    -- a dot talent: periodic crits of Shadow spells +50% (x1.75), the direct part untouched
    state.talents[2] = { rank = 2, text = "Your Shadow spells' periodic damage critical strikes deal 50% more critical strike damage.", spell = 900002 }
    state.spellNames[900002] = "Dark Pact of Rot"
    ns.Spell.ForgetTalents()
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(172)
    -- 40 x (1 + 0.1 x 0.75) = 43
    check(textsOf():find("Damage per second: 28.7 |", 1, true), textsOf())
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 5.7 |", 1, true), "the dot talent is not on a direct hit: " .. textsOf())

    -- a school talent (Ice Shards-like) counts for its school only; a melee talent and a tree we do not know are not counted - and reported
    state.talents = {
        { rank = 5, text = "Increases the critical strike damage bonus of your Fire spells by 100%.", spell = 900003 },
        { rank = 1, text = "Increases the critical strike damage bonus of your melee attacks by 30%.", spell = 900004 },
        { rank = 1, text = "Increases the critical strike damage of your Demonology spells by 20%.", spell = 900005 },
        { rank = 3, text = "Increases your spell critical strike chance by 3%." },
    }
    state.spellNames[900003] = "Fire Shards"
    ns.Spell.ForgetTalents()
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(133)
    -- direct 18 x (1 + 0.2 x 1) + 2 x (1 + 0.2 x 1) = 24
    check(textsOf():find("Damage per second: 16.0 |", 1, true), textsOf())
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 5.4 |", 1, true), "Shadow is no Fire: " .. textsOf())
    local report = ns.Spell.critTalents
    equal(report.read, true); equal(report.talents, 4); equal(#report.crit, 3, "the three that speak of crit damage")
    equal(report.crit[2].unread, "melee or ranged"); equal(report.crit[3].unread, "names the demonology tree")

    -- the crit chance secret or missing: the plain damage, and the line says so
    state.spellCrit = Mock.SECRET
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(686)
    check(textsOf():find("Damage per second: 5.2 |", 1, true), textsOf())
    equal(#Mock.errors, 0, Mock.errors[1])
end)

scenario("heal per second: the heal with your crits in it (heals over time crit too), the class's healing school's chance, heal crit talents by their words", function()
    local ns, state = start()
    state.units.player = { name = "You", player = true, class = "PRIEST" }
    state.spellNames = { [2050] = "Lesser Heal", [139] = "Renew", [5185] = "Healing Touch" }
    state.spellDescriptions[2050] = "Heal your target for 47 to 58."
    state.spellDescriptions[139] = "Heals the target of 45 damage over 15 sec."
    state.spellCosts = { [2050] = 30, [139] = 30 }
    state.castTimes = { [2050] = 1500, [139] = 0 }
    -- Holy (school 2) 10%, Nature (4) 30%: a priest heals by Holy - 52.5 x 1.05 = 55.1 over 1.5 sec
    state.spellCrit = { [2] = 10, [4] = 30 }
    Mock.showSpellTooltip(2050)
    check(textsOf():find("Heal per second: 36.8 |", 1, true), textsOf())
    check(not textsOf():find("Damage per second", 1, true), textsOf())
    -- a HoT crits: 45 x 1.05 = 47.25 over the GCD
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(139)
    check(textsOf():find("Heal per second: 31.5 |", 1, true), textsOf())
    check(textsOf():find("Crit: 68 over time", 1, true), "the HoT's crit row: " .. textsOf())
    -- a heal crit talent counts for heals, not for damage; a damage one not for heals
    state.talents = {
        { rank = 2, text = "Increases the critical effect bonus of your healing spells by 50%.", spell = 900010 },
        { rank = 1, text = "Increases the critical strike damage bonus of your spells by 100%.", spell = 900011 },
    }
    ns.Spell.ForgetTalents()
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(2050)
    -- size 1 + 0.5 x 1.5 = 1.75: 52.5 x (1 + 0.1 x 0.75) = 56.4 -> 37.6
    check(textsOf():find("Heal per second: 37.6 |", 1, true), textsOf())
    check(textsOf():find("Crit: 82 to 102", 1, true), "the heal's crit row by the talent: " .. textsOf())
    equal(ns.Spell.critTalents.crit[1].kind, "heal"); equal(ns.Spell.critTalents.crit[2].kind, "damage")
    -- a druid heals by Nature: 30% - Healing Touch 2 sec, 100 x 1.15 ... with no talents
    state.talents = {}
    ns.Spell.ForgetTalents()
    state.units.player = { name = "You", player = true, class = "DRUID" }
    state.spellDescriptions[5185] = "Heals a friendly target for 100."
    state.spellCosts[5185] = 25
    state.castTimes[5185] = 2000
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(5185)
    check(textsOf():find("Heal per second: 57.5 |", 1, true), textsOf())
    -- /ftt lines hps off
    SlashCmdList.AKFOREVERTOOLTIP("lines hps off")
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(5185)
    check(textsOf():find("Heal per mana", 1, true) and not textsOf():find("Heal per second", 1, true), textsOf())
    SlashCmdList.AKFOREVERTOOLTIP("lines hps on")
    equal(#Mock.errors, 0, Mock.errors[1])
end)

scenario("a drain is damage: health taken from the target (Drain Life), over its channel's length; health given (Health Funnel) is not", function()
    local ns, state = start()
    state.spellCrit = { [6] = 10, [2] = 50 }
    local drain = "Transfers 10 health every 1 sec from the target to the caster. Lasts 5 sec."
    local amounts = ns.Spell.Amounts(drain)
    equal(amounts and amounts.damage, 50, "5 ticks of 10")
    equal(amounts.heal, nil, "the caster's health is no heal line")
    equal(amounts.detail.damage.overTime, 50, "over time")
    equal(ns.Spell.Amounts("Transfers 15 health every second from the target to the caster for 5 sec.").damage, 75)
    equal(ns.Spell.Amounts("Drains 20 health from the target every 3 sec. Lasts 15 sec.").damage, 100)
    equal(ns.Spell.Amounts("Gives 12 health to the caster's pet every second for 10 sec as long as the caster channels."), nil, "Health Funnel")
    equal(ns.Spell.Amounts("Totem with 5 health that heals party members."), nil)
    equal(ns.Spell.Amounts("Heals the caster by draining 8 health from the target every 1 sec. Lasts 5 sec.").damage, 40, "a drain that heals you is still damage")
    equal(ns.Spell.SchoolOf(drain), "shadow")
    state.spellDescriptions[689] = drain
    state.spellCosts = { [689] = 55 }
    state.castTimes = { [689] = 0 }
    Mock.showSpellTooltip(689, nil, { { leftText = "Drain Life" }, { leftText = "55 Mana" }, { leftText = "Channeled" }, { leftText = drain } })
    -- 50 x (1 + 0.1 x 0.5) = 52.5 over the 5 sec channel; Shadow's 10%, not Holy's 50%
    check(textsOf():find("Damage per second: 10.5 |", 1, true), textsOf())
    check(textsOf():find("Damage per mana", 1, true), textsOf())
    equal(#Mock.errors, 0, Mock.errors[1])
end)

scenario("the efficiency lines on a spell tooltip: cost from the client (else the tooltip's '35 Mana'), words from the description (else the tooltip's lines); no mana or no amount, no line; switched off by /ftt lines efficiency off", function()
    local ns, state = start()
    state.spellDescriptions[116] = "Launches a bolt of frost at the enemy, causing 20 to 22 Frost damage and slowing movement speed by 40% for 5 sec."
    state.spellCosts = { [116] = 25 }
    Mock.showSpellTooltip(116)
    check(textsOf():find("Damage per mana: 0.84  (21 / 25 mana)", 1, true), textsOf())
    check(textsOf():find("spell 116", 1, true), "the id line still comes")
    check(not textsOf():find("Damage per second", 1, true), "no cast time known: no per second line - never a guess")

    -- a heal
    state.spellDescriptions[2050] = "Heal your target for 47 to 58."
    state.spellCosts[2050] = 30
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(2050)
    check(textsOf():find("Heal per mana: 1.75  (52.5 / 30 mana)", 1, true), textsOf())
    check(not textsOf():find("Damage per mana", 1, true), textsOf())

    -- both lines on Holy Nova
    state.spellDescriptions[15237] = "Causes an explosion of holy light around the caster, causing 29 to 34 Holy damage to all enemy targets within 10 yards and healing all party members within 10 yards for 52 to 60."
    state.spellCosts[15237] = 185
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(15237)
    check(textsOf():find("Damage per mana: 0.17", 1, true) and textsOf():find("Heal per mana: 0.30", 1, true), textsOf())

    -- no cost from the API: the tooltip's own cost line; no description: the tooltip's longest line
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(403, nil, { { leftText = "Lightning Bolt", rightText = "Rank 1" }, { leftText = "15 Mana", rightText = "30 yd range" },
        { leftText = "1.5 sec cast" }, { leftText = "Casts a bolt of lightning at the target for 15 to 17 Nature damage." } })
    check(textsOf():find("Damage per mana: 1.07  (16 / 15 mana)", 1, true), textsOf())

    -- a strike off the weapon: 150% of the character sheet's swing, a melee crit doubles
    state.spellDescriptions[17364] = "Instantly strike for 150% weapon damage and increase the damage you deal to the target with your next Lightning Bolt, Chain Lightning, or Earth Shock spell by 20% for 12 sec."
    state.spellCosts[17364] = 43
    state.unitDamage = { 40, 60 }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(17364)
    check(textsOf():find("Damage per mana: 1.74  (75 / 43 mana)", 1, true), textsOf())
    check(textsOf():find("Hit: 60 to 90", 1, true) and textsOf():find("Crit: 120 to 180", 1, true), textsOf())
    -- the swing secret (a fight): no line
    state.unitDamage = Mock.SECRET
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(17364)
    check(not textsOf():find("per mana", 1, true), textsOf())
    equal(ns.Spell.stats.weaponUnreadable, 1)

    -- Attack: the swing, per second, and a doubled crit; the off hand when there is one - for a class that dual wields
    state.units.player = { name = "Purrdee", player = true, class = "SHAMAN" }
    state.unitDamage = { 40, 60 }
    state.attackSpeed = { 2.5 }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(6603)
    check(textsOf():find("Hit: 40 to 60  (20.0 per sec, every 2.5 sec)", 1, true) and textsOf():find("Crit: 80 to 120", 1, true), textsOf())
    check(not textsOf():find("per mana", 1, true), textsOf())
    state.unitDamage = { 40, 60, 20, 30 }
    state.attackSpeed = { 2.5, 1.5 }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(6603)
    check(not textsOf():find("Off hand", 1, true), "a shaman: no off-hand row, whatever the client says - " .. textsOf())
    state.units.player.class = "ROGUE"
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(6603)
    check(textsOf():find("Off hand: 20 to 30  (16.7 per sec, every 1.5 sec)", 1, true), textsOf())
    state.units.player.class = "SHAMAN"
    -- Shoot with a wand: x1.5 crit; known by name too
    state.rangedDamage = { 1.6, 20, 30 }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(99999, nil, { { leftText = "Shoot" } })
    check(textsOf():find("Hit: 20 to 30  (15.6 per sec, every 1.6 sec)", 1, true) and textsOf():find("Crit: 30 to 45", 1, true), textsOf())
    -- no wand: no lines
    state.rangedDamage = { 0, 0, 0 }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(5019)
    check(not textsOf():find("Hit:", 1, true), textsOf())

    -- a totem: no line at all, whatever its words say
    state.spellDescriptions[8190] = "Summons a Magma Totem with 5 health at the feet of the caster for 20 sec that causes 22 Fire damage to creatures within 8 yards every 2 seconds."
    state.spellCosts[8190] = 230
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(8190)
    check(not textsOf():find("per mana", 1, true), textsOf())
    equal(ns.Spell.stats.totems, 1)

    -- a rage or energy spell, a spell with no mana at all: no line
    state.spellDescriptions[78] = "A strong attack that increases melee damage by 11."
    state.spellCosts[78] = { { type = 1, name = "RAGE", cost = 15 } }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(78)
    check(not textsOf():find("per mana", 1, true), textsOf())
    -- mana, but no amount in the words (a buff)
    state.spellDescriptions[1459] = "Increases the target's Intellect by 7 for 30 min."
    state.spellCosts[1459] = 60
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(1459)
    check(not textsOf():find("per mana", 1, true), textsOf())
    equal(ns.Spell.stats.noCost >= 1, true); equal(ns.Spell.stats.noAmount >= 1, true)
    -- a spell the parser could not read keeps its words for the report, the tooltip's lines too
    GameTooltip.__lines = nil
    state.spellDescriptions[8042] = "Instantly shocks the target for a lot."
    state.spellCosts[8042] = 45
    Mock.showSpellTooltip(8042, nil, { { leftText = "Earth Shock", rightText = "Rank 1" }, { leftText = "45 Mana" } })
    equal(ns.Spell.misses[8042].why, "no amount in the words")
    equal(ns.Spell.misses[8042].description, "Instantly shocks the target for a lot.")
    equal(ns.Spell.misses[8042].lines[1], "Earth Shock"); equal(ns.Spell.misses[8042].lines[3], "45 Mana")
    equal(ns.Spell.misses[8042].costs[1].cost, 45)

    -- a secret description or cost (a stricter client): no line, no error
    state.spellCosts[116] = { { type = 0, name = "MANA", cost = Mock.SECRET } }
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(116)

    -- switched off
    state.spellCosts[116] = 25
    SlashCmdList.AKFOREVERTOOLTIP("lines efficiency off")
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(116)
    check(not textsOf():find("per mana", 1, true), textsOf())
    equal(next(ns.errors), nil, "no errors")
    equal(ns.Spell.stats.lines >= 4, true)
end)

scenario("under the per-mana line, a row for a normal hit and a row for a crit (x1.5; what lands over time crits too); /ftt lines hits off drops the rows", function()
    local ns, state = start()
    local R = function(text, kind)
        local d = ns.Spell.Amounts(text).detail[kind or "damage"]
        d.critOver = 1.5 -- over time crits, damage and heal (Lines sets it so)
        return table.concat(ns.Spell.Rows(d), " | ")
    end
    equal(R("causing 20 to 22 Frost damage and slowing movement speed by 40% for 5 sec."), "  Hit: 20 to 22 |   Crit: 30 to 33")
    equal(R("Hurls a fiery ball that causes 14 to 22 Fire damage and an additional 2 Fire damage over 4 sec."), "  Hit: 14 to 22 + 2 over time |   Crit: 21 to 33 + 3 over time")
    equal(R("A word of darkness that causes 30 Shadow damage over 18 sec."), "  Over time: 30 |   Crit: 45 over time")
    equal(R("Launches Arcane Missiles at the enemy, causing 26 Arcane damage each second for 3 sec."), "  Over time: 78 |   Crit: 117 over time")
    equal(R("Heal your target for 47 to 58.", "heal"), "  Hit: 47 to 58 |   Crit: 71 to 87")
    equal(R("Heals the target of 45 damage over 15 sec.", "heal"), "  Over time: 45 |   Crit: 68 over time")
    equal(R("Heals a friendly target for 93 to 107 and another 98 over 21 sec.", "heal"), "  Hit: 93 to 107 + 98 over time |   Crit: 140 to 161 + 147 over time")
    equal(R("Burns the enemy for 11 Fire damage and then an additional 20 Fire damage over 15 sec."), "  Hit: 11 + 20 over time |   Crit: 17 + 30 over time")
    -- Lightning Shield: three balls, each strikes once - the total counts all three, the rows one strike
    local shield = "Surrounds the caster with 3 balls of lightning. When a spell, melee or ranged attack hits the caster, the attacker will be struck for 13 Nature damage. This expends one lightning ball. Only one ball will fire every few seconds. Lasts 10 min."
    equal(ns.Spell.Amounts(shield).damage, 39)
    equal(R(shield), "  Hit: 13 each, 3 charges |   Crit: 20 each, 3 charges")
    -- on the tooltip, under its own line
    state.spellDescriptions[116] = "Launches a bolt of frost at the enemy, causing 20 to 22 Frost damage and slowing movement speed by 40% for 5 sec."
    state.spellCosts = { [116] = 25 }
    Mock.showSpellTooltip(116)
    local lines = GameTooltip.__lines
    equal(lines[1].text, "Damage per mana: 0.84  (21 / 25 mana)")
    equal(lines[2].text, "  Hit: 20 to 22"); equal(lines[3].text, "  Crit: 30 to 33")
    SlashCmdList.AKFOREVERTOOLTIP("lines hits off")
    GameTooltip.__lines = nil
    Mock.showSpellTooltip(116)
    check(textsOf():find("per mana", 1, true) and not textsOf():find("Hit:", 1, true), textsOf())
end)

scenario("a #showtooltip macro on a button: its own kind of tooltip - the spell is found by the button's action (a 'spell' subtype, else GetMacroSpell), else by the first line's name; the same line as on the spell", function()
    local ns, state = start()
    state.spellNames = { [8050] = "Flame Shock", [403] = "Lightning Bolt", [8056] = "Frost Shock" }
    state.spellDescriptions[8050] = "Instantly sears the target with fire, causing 25 Fire damage immediately and 28 Fire damage over 12 sec."
    state.spellCosts = { [8050] = 55, [403] = 15, [8056] = 115 }
    state.spellDescriptions[403] = "Casts a bolt of lightning at the target for 15 to 17 Nature damage."
    state.spellDescriptions[8056] = "Instantly shocks the target with frost, causing 95 to 101 Frost damage and slowing movement speed to 50% of normal. Lasts 8 sec."
    -- GetActionInfo hands the spell's id with a 'spell' subtype
    state.actions[1] = { "macro", 8050, "spell" }
    Mock.showMacroTooltip({ action = 1 }, { { leftText = "Flame Shock" } })
    check(textsOf():find("Damage per mana: 0.96  (53 / 55 mana)", 1, true), textsOf())
    equal(ns.Spell.lastMacro.route, "button")
    check(textsOf():find("Hit: 25 + 28 over time", 1, true) and textsOf():find("Crit: 38 + 42 over time", 1, true), textsOf())
    -- the macro's index: GetMacroSpell names the spell
    state.actions[2] = { "macro", 7 }
    state.macroSpells[7] = 403
    GameTooltip.__lines = nil
    Mock.showMacroTooltip({ action = 2 }, { { leftText = "Lightning Bolt" } })
    check(textsOf():find("Damage per mana: 1.07", 1, true), textsOf())
    equal(ns.Spell.lastMacro.route, "button")
    -- what the client gave in game (2026-11-07): no slot on the button, the data's id a macro index
    state.macroSpells[2] = 8050
    GameTooltip.__lines = nil
    Mock.showMacroTooltip({}, { { leftText = "" }, { leftText = "Flame Shock" } }, 2)
    check(textsOf():find("Damage per mana: 0.96", 1, true), textsOf())
    equal(ns.Spell.lastMacro.route, "macro index")
    -- a candidate the lines do not confirm is passed over: macro 2 now names Lightning Bolt, the tooltip shows Frost Shock
    state.macroSpells[2] = 403
    GameTooltip.__lines = nil
    Mock.showMacroTooltip({}, { { leftText = "Frost Shock" } }, 2)
    equal(ns.Spell.lastMacro.route, "name")
    check(textsOf():find("Damage per mana: 0.85", 1, true), textsOf())
    -- no button to ask: the first line's name
    GameTooltip.__lines = nil
    Mock.showMacroTooltip(nil, { { leftText = "Frost Shock" } })
    check(textsOf():find("Damage per mana: 0.85", 1, true), textsOf())
    equal(ns.Spell.lastMacro.route, "name")
    -- a macro with no spell (a /say): nothing
    state.actions[3] = { "macro", 9 }
    GameTooltip.__lines = nil
    Mock.showMacroTooltip({ action = 3 }, { { leftText = "Hello" } })
    check(not textsOf():find("per mana", 1, true), textsOf())
    equal(ns.Spell.lastMacro.route, "none")
    equal(next(ns.errors), nil, "no errors")
end)

scenario("a camp object's tooltip says the buff it brings; an upgrade names the buff it keeps; a blueprint says what it teaches", function()
    local ns, state = start()
    -- a first-tier object: its buff, the most of it, the class buff it stands in for - each its own line
    Mock.showItemTooltip(279960) -- Lodestone
    check(plainTexts():find("Camp buff: 90 melee Attack Power at 60 (less at your level) | Does not stack with: Blessing of Might | item 279960", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279967) -- Fish Bowl: a percentage, the same at every level
    check(plainTexts():find("Camp buff: 8% to all stats | Does not stack with: Blessing of Kings", 1, true) and not plainTexts():find("less at your", 1, true), plainTexts())
    -- an upgrade: the first-tier buff it keeps, and its own work
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279943) -- Spinning Wheel
    check(plainTexts():find("Camp buff (the Faction Banner's): 32 Spirit, for your own faction only at 60 (less at your level) | Does not stack with: Divine Spirit | Also: makes certain Tailoring reagents", 1, true), plainTexts())
    -- one that keeps no buff
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279957) -- Cookie's Feast
    check(plainTexts():find("Camp: Stamina food for everyone at camp | item", 1, true) and not plainTexts():find("Does not stack", 1, true), plainTexts())
    -- the tent and the bot: what they do, no class buff
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279949) -- Repair Bot
    check(plainTexts():find("Camp: a reagent vendor for everyone at camp | Also: sells reagents and repairs gear", 1, true), plainTexts())
    -- a blueprint
    GameTooltip.__lines = nil
    Mock.showItemTooltip(273099) -- Blueprint: Spinning Wheel
    check(plainTexts():find("Teaches the Spinning Wheel (skill 140) | Camp buff (the Faction Banner's)", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showItemTooltip(273101)
    check(plainTexts():find("Teaches the Expert Campfire | Camp: a campfire with room for 10 camp objects | Sit by it a minute", 1, true), plainTexts())
    -- any other item: nothing; the id line still comes
    GameTooltip.__lines = nil
    Mock.showItemTooltip(6529)
    check(not plainTexts():find("Camp", 1, true) and plainTexts():find("item 6529", 1, true), plainTexts())
    -- the object standing at a camp: its tooltip is a world object's, known by its name
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Camp Tent")
    check(plainTexts():find("Camp: rested experience up to 5% of a level, once an hour", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Enchanted Lute")
    check(plainTexts():find("Camp buff: 308 Armor, 13 to all stats and 22 to all resistances at 60 (less at your level) | Does not stack with: Mark of the Wild", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Copper Vein")
    check(not plainTexts():find("Camp", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip(Mock.SECRET)
    check(not plainTexts():find("Camp", 1, true), "a secret name is not looked at")
    equal(ns.Camp.Describe().objects, 4); check(ns.Camp.Describe().lines >= 2)
    -- the report keeps a campfire's whole tooltip (what the client writes on it is the open question), the
    -- same tooltip once, a secret line marked; and the buffs on you, by name and spell id
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Basic Campfire", nil, { { leftText = "Camp objects: 2/3", rightText = "15 min" }, { leftText = Mock.SECRET } })
    Mock.showObjectTooltip("Basic Campfire", nil, { { leftText = "Camp objects: 2/3", rightText = "15 min" }, { leftText = Mock.SECRET } })
    local kept = ns.Camp.Describe().objectLines
    equal(#kept, 5, "four objects before it, the campfire twice kept once"); equal(kept[5].name, "Basic Campfire")
    equal(kept[5].lines[2], "Camp objects: 2/3 | 15 min"); equal(kept[5].lines[3], "<secret>", "a secret line is marked, never read")
    equal(kept[4].name, "<secret name>")
    Mock.state.auras = { player = { { name = "Lodestone", spellId = 1234, duration = 3600, applications = 1 }, { name = Mock.SECRET, spellId = Mock.SECRET, duration = Mock.SECRET } } }
    local buffs = ns.Camp.Describe().buffs
    equal(#buffs, 2); equal(buffs[1], "Lodestone #1234 3600s x1"); equal(buffs[2], "<secret> #? ?s x1")
    Mock.state.auras = nil
    -- the camp chair: the world calls it just "Chair" (seen 2026-10-06), and that name is known
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Chair")
    check(plainTexts():find("Camp buff: 2% critical strike chance", 1, true) and plainTexts():find("Moonkin Aura", 1, true), plainTexts())
    check(#Mock.errors == 0, table.concat(Mock.errors, "\n"))
    -- the campfires: the kit in the bag, the fire in the world, the blueprint
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279981)
    check(plainTexts():find("Camp: a campfire with room for 3 camp objects", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Expert Campfire")
    check(plainTexts():find("room for 10 camp objects", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showItemTooltip(273087)
    check(plainTexts():find("Teaches the Journeyman Campfire | Camp: a campfire with room for 5 camp objects", 1, true), plainTexts())
    -- a world object whose name holds ours, the chair the world calls just "Chair" (seen 2026-10-06), and a
    -- stranger, written down for the report
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Camp Chair (Bu's)")
    check(plainTexts():find("Camp buff: 2% critical strike chance", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Chair")
    check(plainTexts():find("Camp buff: 2% critical strike chance", 1, true) and plainTexts():find("Moonkin Aura", 1, true), "the chair at the camp: " .. plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Mailbox")
    check(not plainTexts():find("Camp", 1, true), "a mailbox is no camp object")
    check(ns.Camp.Describe().unmatched[1] == "Copper Vein" and ns.Camp.Describe().unmatched[2] == "Mailbox", table.concat(ns.Camp.Describe().unmatched, ","))
    equal(ns.Camp.ObjectByName("camp-chair"), 279979); equal(ns.Camp.ObjectByName("Lodestone"), 279960)
    -- a chair is a seat, which the client may hand over as a creature: the unit tooltip matches the name too
    state.units.chair = { name = "Camp Chair", player = false }
    state.units.boar = { name = "Mottled Boar", player = false }
    state.units.rogue = { name = "Purr Rogie", player = true, class = "ROGUE" }
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("chair")
    check(plainTexts():find("Camp buff: 2% critical strike chance | Does not stack with: Moonkin Aura", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not plainTexts():find("Camp", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("rogue")
    check(not plainTexts():find("Camp", 1, true), "a player is never looked at")
    check(ns.Camp.Describe().unitNames[1] == "Mottled Boar" and #ns.Camp.Describe().unitNames == 1, table.concat(ns.Camp.Describe().unitNames, ","))
    -- switched off
    SlashCmdList.AKFOREVERTOOLTIP("lines camp off")
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(not plainTexts():find("Camp", 1, true), plainTexts())
    -- every object, kit and blueprint has words; the Faction Banner twice over, one a side
    local count = 0
    for id in pairs(ns.Camp.OBJECTS) do check(ns.Camp.Words(id), "no words for " .. id); count = count + 1 end
    equal(count, 39)
    for id in pairs(ns.Camp.BLUEPRINTS) do check(ns.Camp.Words(id), "no words for blueprint " .. id) end
end)

scenario("the buff at your level: the first-tier item's Use spell, as the client words it for this character", function()
    local ns, state = start()
    state.itemSpells[279960] = { "Lodestone", 1255260 }
    state.itemSpells[279956] = { "Mana Well", 1255256 }
    state.itemSpells[279944] = { "Sharpening Wheel", 1255244 }
    state.itemSpells[279976] = { "Enchanted Lute", 1255276 }
    -- not loaded yet: the level-60 words, and the spell asked for
    Mock.showItemTooltip(279960)
    check(plainTexts():find("Camp buff: 90 melee Attack Power at 60 (less at your level)", 1, true), plainTexts())
    equal(state.requestedSpells[1], 1255260)
    -- loaded: your level's line, then the level-60 line
    state.spellDescriptions[1255260] = "Erects a lodestone that allows you and others sitting nearby to gain 32 increased melee Attack Power, mutually exclusive with Blessing of Might. Requires a Campfire nearby."
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(plainTexts():find("Camp buff: 32 increased melee Attack Power at level 30 | At 60: 90 melee Attack Power | Does not stack with: Blessing of Might", 1, true), plainTexts())
    -- the upgrade shows the base's buff at your level too, then its own work
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279948) -- Rock Garden
    check(plainTexts():find("Camp buff (the Lodestone's): 32 increased melee Attack Power at level 30 | At 60: 90 melee Attack Power | Does not stack with: Blessing of Might | Also: spawns a common mining node over time", 1, true), plainTexts())
    -- the other wordings the client uses
    state.spellDescriptions[1255256] = "Constructs a mana well that allows you and others sitting nearby to regenerate 24 Mana every 5 sec, muutally exclusive with Blessing of Wisdom. Requires a Campfire nearby."
    state.spellDescriptions[1255244] = "Constructs a sharpening wheel that grants you and others sitting nearby 20 increased Strength, mutually exclusive with Strength of Earth Totem. Requires a Campfire nearby."
    state.spellDescriptions[1255276] = "Summons an enchanted lute that allows you and others sitting nearby to gain 163 Armor, and 9 increase to all stats, and 12 increase to all resistances, mutually exclusive with Mark of the Wild."
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279970) -- Fermenter, the Mana Well's
    check(plainTexts():find("24 Mana every 5 sec at level 30 | At 60: 29 Mana every 5 sec", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279944)
    check(plainTexts():find("20 increased Strength at level 30 | At 60: 34 Strength", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showObjectTooltip("Arcane Forge")
    check(plainTexts():find("163 Armor, and 9 increase to all stats, and 12 increase to all resistances at level 30 | At 60: 308 Armor", 1, true), plainTexts())
    -- a percentage does not scale: one line, no level
    state.itemSpells[279967] = { "Fish Bowl", 1255254 }
    state.spellDescriptions[1255254] = "Places a small fish bowl that allows you and others sitting nearby to gain 8% increased stats, mutually exclusive with Blessing of Kings."
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279967)
    check(plainTexts():find("Camp buff: 8% to all stats | Does not stack with:", 1, true) and not plainTexts():find("at level", 1, true), plainTexts())
    -- a secret description is not looked at
    state.spellDescriptions[1255260] = Mock.SECRET
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(plainTexts():find("90 melee Attack Power at 60 (less at your level)", 1, true), plainTexts())
    -- at the game's highest level the level lines are gone: just the buff
    state.spellDescriptions[1255260] = "Erects a lodestone that allows you and others sitting nearby to gain 90 increased melee Attack Power, mutually exclusive with Blessing of Might."
    state.level = 60
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(plainTexts():find("Camp buff: 90 melee Attack Power | Does not stack with: Blessing of Might", 1, true) and not plainTexts():find("At 60", 1, true) and not plainTexts():find("at level", 1, true), plainTexts())
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279948)
    check(plainTexts():find("Camp buff (the Lodestone's): 90 melee Attack Power | Does not stack with:", 1, true), plainTexts())
    -- the class buff's icon: the client's texture for its spell, the icon file when the client has none
    check(textsOf():find("Does not stack with: |TInterface\\Icons\\Spell_Holy_FistOfJustice:16:16:0:0:64:64:4:60:4:60|t Blessing of Might", 1, true), textsOf())
    state.spellTextures[19740] = 135906
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(textsOf():find("Does not stack with: |T135906:16:16:0:0:64:64:4:60:4:60|t Blessing of Might", 1, true), textsOf())
    state.spellTextures[19740] = Mock.SECRET
    GameTooltip.__lines = nil
    Mock.showItemTooltip(279960)
    check(textsOf():find("|TInterface\\Icons\\Spell_Holy_FistOfJustice", 1, true), "a secret texture: the file instead")
end)

scenario("one spell, exactly: in range or out, and silence when the question does not apply", function()
    local ns, state = start()
    state.units.player = { name = "You", player = true }
    state.units.boar = { name = "Boar", player = false, health = 10, healthMax = 10, yards = 30 }
    state.spellRanges = { ["Auto Shot"] = 35, ["Earth Shock"] = 20 }
    SlashCmdList.AKFOREVERTOOLTIP("range spell Auto Shot")

    Mock.showUnitTooltip("boar")
    check(textsOf():find("Auto Shot: in range", 1, true), textsOf())
    check(textsOf():find("over 28 yd", 1, true), "the band is still there, and still says 28: " .. textsOf())

    -- a shorter spell on the same target
    SlashCmdList.AKFOREVERTOOLTIP("range spell Earth Shock")
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(textsOf():find("Earth Shock: out of range", 1, true), textsOf())

    -- a spell the client knows nothing about: no line rather than a guess
    SlashCmdList.AKFOREVERTOOLTIP("range spell Moonfire")
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not textsOf():find("Moonfire", 1, true), textsOf())

    SlashCmdList.AKFOREVERTOOLTIP("range spell none")
    GameTooltip.__lines = nil
    Mock.showUnitTooltip("boar")
    check(not textsOf():find("in range", 1, true), "named none: just the bands")
end)

-- The character's profile ------------------------------------------------------------------------------------
-- Since client build 1.60.1.70170 (Oct 1 2026) the surname sits where the realm used to be: UnitFullName("player")
-- answers "Purrdee", "Bubson" instead of "Purrdee Bubson", "ClassicBetaPvE". The profile key must not care.
scenario("one profile per character: the full name and the realm, the same on the old client and on build 70170", function()
    equal(start({ surname = "Bubson" }).characterKey, "Purrdee Bubson - TestRealm", "the old client: the name slot full, the realm slot the realm")
    equal(start({ surname = "Bubson", freshLogin = true }).characterKey, "Purrdee Bubson - TestRealm", "a fresh login on the old client: no realm slot yet")
    local ns = start({ surname = "Bubson", build70170 = true })
    equal(ns.characterKey, "Purrdee Bubson - TestRealm", "build 70170: the surname in the realm slot")
    equal(ns.cdb, AKForeverTooltipDB.chars["Purrdee Bubson - TestRealm"], "the profile sits in the account-wide table")
    equal(start({ surname = "Bubson", build70170 = true, normalizedRealm = false }).characterKey, "Purrdee Bubson - TestRealm", "no GetNormalizedRealmName: GetRealmName() squeezed")
    equal(start().characterKey, "Purrdee - TestRealm", "no surname: name and realm")
end)

scenario("a cold login: no name when the addon loads; the profile is bound at PLAYER_LOGIN and never saved as Unknown", function()
    local ns = start({ surname = "Bubson", build70170 = true, coldLogin = true })
    equal(ns.characterKey, "Purrdee Bubson - TestRealm")
    equal(ns.cdb, AKForeverTooltipDB.chars["Purrdee Bubson - TestRealm"], "bound to the saved table")
    local keys = {}
    for key in pairs(AKForeverTooltipDB.chars) do
        keys[#keys + 1] = key
    end
    equal(#keys, 1, "one profile and no 'Unknown - TestRealm': " .. table.concat(keys, ", "))
end)

scenario("profiles under older spellings are adopted once: this profile keeps its values, the others fill its gaps and go", function()
    local db = { chars = {
        ["Purrdee Bubson - TestRealm"] = { options = { fromOld = "old" }, place = { x = 1 } },
        ["Purrdee - Bubson"] = { options = { fromOld = "new", fromNew = "new" }, place = { x = 2, y = 2 } },
        ["Purrdee Bubson - Test Realm"] = { options = { fromOld = "spaced", fromNew = "spaced", fromSpaced = "spaced" }, place = { w = 4 } },
        ["Unknown - TestRealm"] = { options = { fromOld = "cold", fromNew = "cold", fromCold = "cold" }, place = { y = 3, z = 3 }, extra = { deep = true } },
    } }
    local ns = start({ surname = "Bubson", build70170 = true, db = db })
    equal(ns.characterKey, "Purrdee Bubson - TestRealm")
    local cdb = ns.cdb
    equal(cdb, db.chars["Purrdee Bubson - TestRealm"])
    equal(cdb.options.fromOld, "old", "the long-standing profile wins")
    equal(cdb.options.fromNew, "new", "the build-70170 profile fills gaps before the others")
    equal(cdb.options.fromSpaced, "spaced"); equal(cdb.options.fromCold, "cold")
    equal(cdb.place.x, 1); equal(cdb.place.y, 2); equal(cdb.place.w, 4); equal(cdb.place.z, 3, "filled down into nested tables")
    equal(cdb.extra.deep, true)
    equal(db.chars["Purrdee - Bubson"], nil, "the older spellings are gone")
    equal(db.chars["Purrdee Bubson - Test Realm"], nil); equal(db.chars["Unknown - TestRealm"], nil)
    local logged
    for _, entry in ipairs(ns.sessionLog) do
        if entry.k == "profile" then
            logged = entry.d
        end
    end
    check(logged and logged.key == "Purrdee Bubson - TestRealm", "the adoption is in the session log")
    equal(logged.adopted[1], "Purrdee - Bubson"); equal(logged.adopted[2], "Purrdee Bubson - Test Realm"); equal(logged.adopted[3], "Unknown - TestRealm")

    -- a character first seen on build 70170 keeps that profile, under the full key
    local alt = start({ playerName = "Stabby", surname = "Bubson", build70170 = true,
        db = { chars = { ["Stabby - Bubson"] = { options = { fromNew = "new" } } } } })
    equal(alt.characterKey, "Stabby Bubson - TestRealm")
    equal(alt.cdb.options.fromNew, "new"); equal(AKForeverTooltipDB.chars["Stabby - Bubson"], nil)

    -- an alt logging in afterwards finds nothing to adopt and leaves the first character's profile alone
    local other = start({ playerName = "Stabby", surname = "Bubson", build70170 = true, db = db })
    equal(other.characterKey, "Stabby Bubson - TestRealm")
    equal(next(other.cdb.options), nil, "an empty profile of its own")
    equal(db.chars["Purrdee Bubson - TestRealm"].options.fromOld, "old")
end)

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
if #failures > 0 then
    os.exit(1)
end
