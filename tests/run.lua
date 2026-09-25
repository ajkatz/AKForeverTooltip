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

scenario("a player's name and the health bar take the class colour; creatures keep Blizzard's colours", function()
    local ns = start()
    Mock.showUnitTooltip("rogue")
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 0.96 0.41", "rogue yellow")
    equal(color(GameTooltipStatusBar, "__barColor"), "1.00 0.96 0.41")
    equal(GameTooltip.__anchorType, "ANCHOR_CURSOR_RIGHT", "and it is at the mouse")
    Mock.showUnitTooltip("shaman")
    equal(color(GameTooltipTextLeft1, "__textColor"), "0.00 0.44 0.87", "shaman blue")

    Mock.showUnitTooltip("boar") -- (its class is a SECRET: not player-controlled)
    equal(color(GameTooltipTextLeft1, "__textColor"), "1.00 1.00 1.00", "Blizzard's colour stands")
    equal(color(GameTooltipStatusBar, "__barColor"), "0.00 1.00 0.00", "the bar is green again")
    equal(ns.Tooltip.stats.coloured, 2); equal(ns.Tooltip.stats.notPlayers, 1)

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

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
if #failures > 0 then
    os.exit(1)
end
