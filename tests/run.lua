-- AKForeverTooltip scenario tests. Run from the repo root:  lua tests/run.lua
-- Every scenario loads a fresh copy of the addon into the mock client and fails if the addon raised ANY
-- Lua error or did one of the things that taint Blizzard's tooltip (see tests/wowmock.lua).
package.path = "./tests/?.lua;" .. package.path
local Mock = require("wowmock")

local failures, passed = {}, 0

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

Mock.realPrint(string.format("\n%d passed, %d failed", passed, #failures))
if #failures > 0 then
    os.exit(1)
end
