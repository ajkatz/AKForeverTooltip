-- AKForeverTooltip core: namespace, safe calls, event dispatch, message bus, saved variables,
-- session log and slash commands. (Same skeleton as AKForeverActionBars.)
--
-- House rules for this addon (see Tooltip.lua for the why):
--   * the game tooltip is never cleared, re-owned, shown or hidden from here (SetOwner, ClearLines, Show,
--     Hide): each of those runs Blizzard's tooltip scripts as addon code, which writes tainted values
--     into the tooltip - and a tainted tooltip cannot show secret lines (enemies in a fight).
--   * no field is ever written on Blizzard's frames; what we need to remember lives in our own tables.
--   * whatever Blizzard's API answers may be a secret value: it is checked with ns.IsSecret before it
--     is looked at, and "unreadable" always means "hands off".
local ADDON_NAME, ns = ...

ns.name = ADDON_NAME

local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.version = (getMetadata and getMetadata(ADDON_NAME, "Version")) or "dev"

local PRINT_PREFIX = "|cffd9b3ffAKForeverTooltip|r: "

function ns:Print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    print(PRINT_PREFIX .. table.concat(parts, " "))
end

------------------------------------------------------------------------
-- Secret values. WoW: Forever runs the Midnight-era API, where some
-- values handed to addons may be held but not inspected.
------------------------------------------------------------------------
local issecret = type(issecretvalue) == "function" and issecretvalue or nil

function ns.IsSecret(value)
    if issecret then
        return issecret(value) and true or false
    end
    return false
end

function ns.AnySecret(...)
    for i = 1, select("#", ...) do
        if ns.IsSecret((select(i, ...))) then
            return true
        end
    end
    return false
end

-- The results of a getter as a list - or nil when the call failed or any result is secret.
function ns.Readable(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, a, b, c, d, e = pcall(fn, ...)
    if not ok or ns.AnySecret(a, b, c, d, e) then
        return nil
    end
    return { a, b, c, d, e }
end

-- Human readable dump that never touches a secret value.
function ns.Describe(value, depth)
    depth = depth or 0
    if ns.IsSecret(value) then
        return "<secret>"
    end
    if type(value) ~= "table" then
        return tostring(value)
    end
    if depth >= 3 then
        return "{...}"
    end
    local parts = {}
    for k, v in pairs(value) do
        parts[#parts + 1] = tostring(k) .. "=" .. ns.Describe(v, depth + 1)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ", ") .. "}"
end

------------------------------------------------------------------------
-- Safe calls: every distinct error is kept for /ftt diag.
------------------------------------------------------------------------
ns.errors = {}

local function onError(err)
    err = tostring(err)
    local seen = ns.errors[err]
    ns.errors[err] = (seen or 0) + 1
    if not seen then
        local handler = geterrorhandler and geterrorhandler()
        if handler then
            handler(err)
        end
    end
    return err
end

function ns.SafeCall(fn, ...)
    return xpcall(fn, onError, ...)
end

------------------------------------------------------------------------
-- Session log (ring buffer), saved with /ftt diag and on logout
------------------------------------------------------------------------
local LOG_MAX = 300
ns.sessionLog = {}
ns.debug = false

function ns:Log(kind, data)
    local log = ns.sessionLog
    log[#log + 1] = {
        t = math.floor(GetTime() * 1000) / 1000,
        k = kind,
        c = InCombatLockdown() and 1 or nil,
        d = data,
    }
    if #log > LOG_MAX then
        table.remove(log, 1)
    end
    if ns.debug then
        ns:Print("|cff888888[" .. kind .. "]|r", ns.Describe(data))
    end
end

------------------------------------------------------------------------
-- Internal message bus
------------------------------------------------------------------------
local listeners = {}

function ns:Listen(message, fn)
    listeners[message] = listeners[message] or {}
    table.insert(listeners[message], fn)
end

function ns:Fire(message, ...)
    local list = listeners[message]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], message, ...)
    end
end

------------------------------------------------------------------------
-- Game events. Registration is pcall'd so an event that a future client
-- drops shows up in /ftt diag instead of breaking the addon at load.
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}
ns.unknownEvents = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then
        return
    end
    for i = 1, #list do
        ns.SafeCall(list[i], event, ...)
    end
end)

function ns:On(event, fn)
    if not eventHandlers[event] then
        eventHandlers[event] = {}
        if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
            ns.unknownEvents[event] = true
        end
    end
    table.insert(eventHandlers[event], fn)
end

------------------------------------------------------------------------
-- Blocked actions: the client stops the call without a Lua error and shows the "has been blocked"
-- dialog. These events name the function; kept so /ftt diag can say exactly what it was.
------------------------------------------------------------------------
ns.blockedActions = {}

-- THE TRACE. Each hook or post-call opens one - which tooltip, whose, in combat or not - and every
-- frame-touching step it takes is appended by name. A blocked-action event arrives after the handler
-- that caused it has returned, so when one comes the whole trace of the tooltip in progress (and the few
-- before it) is attached: the blocked call is one of those steps, which is a short list to check against
-- the client's taint log rather than a guess.
ns.trace = { steps = {}, tooltip = "?", owner = "?", combat = false }
ns.recentTraces = {}

local function nameOf(frame)
    if type(frame) ~= "table" then
        return type(frame)
    end
    local name = ns.Readable(frame.GetName, frame)
    return (name and type(name[1]) == "string") and name[1] or "(unnamed)"
end

function ns.BeginTrace(what, tooltip)
    local previous = ns.trace
    if previous and #previous.steps > 0 then
        ns.recentTraces[#ns.recentTraces + 1] = previous
        while #ns.recentTraces > 6 do
            table.remove(ns.recentTraces, 1)
        end
    end
    local owner = type(tooltip) == "table" and ns.Readable(tooltip.GetOwner, tooltip)
    ns.trace = {
        what = what, steps = {},
        tooltip = nameOf(tooltip),
        owner = owner and nameOf(owner[1]) or "(owner unreadable)",
        combat = InCombatLockdown() and true or false,
    }
end

function ns.Step(step)
    local trace = ns.trace
    trace.steps[#trace.steps + 1] = step
end

local function flatten(trace)
    if not trace then
        return nil
    end
    return string.format("%s on %s (owner %s, %s): %s", trace.what or "?", trace.tooltip, trace.owner,
        trace.combat and "combat" or "no combat", table.concat(trace.steps, " > "))
end

local function onActionBlocked(event, addonName, functionName)
    if addonName ~= ADDON_NAME then
        return
    end
    local entry = { event = event, fn = tostring(functionName), combat = InCombatLockdown() and true or false,
        trace = flatten(ns.trace), before = {} }
    for index = #ns.recentTraces, 1, -1 do
        entry.before[#entry.before + 1] = flatten(ns.recentTraces[index])
    end
    ns.blockedActions[#ns.blockedActions + 1] = entry
    ns:Log("action_blocked", entry)
end

ns:On("ADDON_ACTION_FORBIDDEN", onActionBlocked)
ns:On("ADDON_ACTION_BLOCKED", onActionBlocked)

------------------------------------------------------------------------
-- Saved variables: ONE account-wide table, per-character data under db.chars["Name - Realm"].
-- One file is what lets the beta workaround (tools/Install-SavedStateBridge.ps1) restore it: the
-- 1.60.1 client writes SavedVariables but never reads them back.
------------------------------------------------------------------------
local OPTION_DEFAULTS = {
    anchor = "right",    -- where "default" tooltips go: "right" / "left" of the cursor, "cursor" (centred above it), "default" (Blizzard's corner)
    offsetX = 16,        -- ... and how far from the cursor ("right" / "left" only)
    offsetY = 8,
    classColors = true,  -- a player's name in the colour of their class
    -- ... but NOT the tooltip's health bar by default: Blizzard repaints that bar green on every refresh,
    -- and a unit frame under the mouse refreshes its tooltip several times a second, so a coloured bar
    -- flickers green there (seen 2026-09-25 on the player frame). /ftt class bar on, for those who want it.
    classBar = false,
    health = true,       -- a health line on unit tooltips (see Tooltip.lua: a secret one is HANDED over, never read)
    targetOfTarget = true, -- who the unit is hitting ("Targeting: YOU")
    range = true,        -- roughly how far away they are, in the bands the client will answer
    rangeSpell = false,  -- ... and, for one spell you name, whether it would actually reach
    petMood = true,      -- your own pet's happiness and loyalty
    ids = true,          -- the spell or item id on a spell / item tooltip
}

-- The realm is squeezed ("Classic Beta PvE" -> "ClassicBetaPvE"): on a fresh login UnitFullName has no
-- realm yet and GetRealmName() gives the spaced display name, after a /reload UnitFullName gives the
-- normalized one. Unsqueezed, that would be two profiles for one character.
local function squeezeRealm(realm)
    return (string.gsub(realm, "[%s%-]", ""))
end

local function characterKey()
    local name, realm
    if UnitFullName then
        name, realm = UnitFullName("player")
    end
    if not name then
        name = UnitName("player")
    end
    if not realm or realm == "" then
        realm = GetRealmName and GetRealmName()
    end
    return (name or "Unknown") .. " - " .. squeezeRealm(realm or "Unknown")
end

local function initDB()
    local bridge = AKForeverTooltip_SavedStateBridge
    if type(AKForeverTooltipDB) ~= "table" then
        AKForeverTooltipDB = {}
        ns.savedStateSource = "none (first run, or the client did not load it)"
    elseif type(bridge) == "table" and bridge.table == AKForeverTooltipDB then
        ns.savedStateSource = "bridge addon"
    else
        ns.savedStateSource = "client"
    end
    local db = AKForeverTooltipDB

    db.schema = db.schema or 1
    db.loads = (db.loads or 0) + 1
    db.chars = db.chars or {}
    db.options = db.options or {}

    local key = characterKey()
    if type(db.chars[key]) ~= "table" then
        db.chars[key] = {}
    end
    local cdb = db.chars[key]
    cdb.options = cdb.options or {}

    ns.characterKey = key
    ns.db, ns.cdb = db, cdb
end

-- (account-wide: where the tooltip goes is a matter of taste, not of the character)
function ns:GetOption(key)
    local options = ns.db and ns.db.options
    local value = options and options[key]
    if value == nil then
        return OPTION_DEFAULTS[key]
    end
    return value
end

function ns:SetOption(key, value)
    ns.db.options[key] = value
    ns:Fire("OPTION_CHANGED", key, value)
end

------------------------------------------------------------------------
-- Slash commands: modules register their own sub-commands
------------------------------------------------------------------------
local commands, commandOrder = {}, {}

function ns:RegisterCommand(name, help, fn)
    commands[name] = { help = help, fn = fn }
    commandOrder[#commandOrder + 1] = name
end

SLASH_AKFOREVERTOOLTIP1 = "/akforevertooltip"
SLASH_AKFOREVERTOOLTIP2 = "/ftt"
SLASH_AKFOREVERTOOLTIP3 = "/ftip"
SlashCmdList["AKFOREVERTOOLTIP"] = function(message)
    local name, rest = string.match(message or "", "^%s*(%S*)%s*(.-)%s*$")
    local command = commands[string.lower(name or "")]
    if command then
        ns.SafeCall(command.fn, rest or "")
        return
    end
    ns:Print("v" .. ns.version .. " commands:")
    for _, commandName in ipairs(commandOrder) do
        print("   |cffffd100/ftt " .. commandName .. "|r - " .. commands[commandName].help)
    end
end

ns:RegisterCommand("debug", "toggle verbose logging to chat", function()
    ns.debug = not ns.debug
    ns:Print("debug logging", ns.debug and "on" or "off")
end)

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
ns.inCombat = false

ns:On("ADDON_LOADED", function(_, addonName)
    if addonName ~= ADDON_NAME then
        return
    end
    initDB()
    ns:Fire("DB_READY")
end)

ns:On("PLAYER_LOGIN", function()
    ns.inCombat = InCombatLockdown() and true or false
    ns:Log("login", {
        version = ns.version,
        character = ns.characterKey,
        loads = ns.db and ns.db.loads,
        savedState = ns.savedStateSource,
    })
    ns:Fire("LOGIN")
end)

ns:On("PLAYER_REGEN_DISABLED", function()
    ns.inCombat = true
    ns:Fire("COMBAT_START")
end)

ns:On("PLAYER_REGEN_ENABLED", function()
    ns.inCombat = false
    ns:Fire("COMBAT_END")
end)
