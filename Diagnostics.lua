-- /ftt diag: a report of what this client did with our two hooks, saved with the settings
-- (ForeverTooltipDB.diag) so that it can be read from the SavedVariables file after a /reload or logout.
-- Read-only on Blizzard's side; nothing here looks at a value before ns.IsSecret cleared it.
local _, ns = ...

local Diagnostics = {}
ns.Diagnostics = Diagnostics

local function sanitize(value, depth)
    depth = depth or 0
    if ns.IsSecret(value) then
        return "<secret>"
    end
    local kind = type(value)
    if kind == "table" then
        if depth >= 6 then
            return "<too deep>"
        end
        local copy = {}
        for k, v in pairs(value) do
            local key = k
            if ns.IsSecret(k) then
                key = "<secret key>"
            elseif type(k) ~= "string" and type(k) ~= "number" then
                key = tostring(k)
            end
            copy[key] = sanitize(v, depth + 1)
        end
        return copy
    elseif kind == "string" or kind == "number" or kind == "boolean" then
        return value
    elseif kind == "nil" then
        return nil
    end
    return "<" .. kind .. ">"
end

-- One getter's first result - "<secret>", "n/a" (no such function) or "error: ..." instead of a surprise.
local function ask(fn, ...)
    if type(fn) ~= "function" then
        return "n/a"
    end
    local ok, value = pcall(fn, ...)
    if not ok then
        return "error: " .. tostring(value)
    end
    return sanitize(value)
end

function Diagnostics:Collect()
    local tooltip = _G.GameTooltip
    local report = {
        capturedAt = date and date("%Y-%m-%d %H:%M:%S") or "?",
        addonVersion = ns.version,
        character = ns.characterKey,
        savedStateSource = ns.savedStateSource,
        savedVariableLoads = ns.db and ns.db.loads,
        inCombat = InCombatLockdown() and true or false,
        options = {
            anchor = ns:GetOption("anchor"), offsetX = ns:GetOption("offsetX"), offsetY = ns:GetOption("offsetY"),
            classColors = ns:GetOption("classColors"), classBar = ns:GetOption("classBar"),
        },
        hooks = ns.Tooltip.hooks,
        stats = ns.Tooltip.stats,
        samples = ns.Tooltip.samples,
        client = {
            setAnchorType = type(tooltip) == "table" and type(tooltip.SetAnchorType),
            anchorTypeNow = type(tooltip) == "table" and ask(tooltip.GetAnchorType, tooltip) or "no GameTooltip",
            postCalls = type(TooltipDataProcessor) == "table" and type(TooltipDataProcessor.AddTooltipPostCall) or "no TooltipDataProcessor",
            unitDataType = Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit,
            classColorTable = type(RAID_CLASS_COLORS),
        },
        errors = {},
        blockedActions = ns.blockedActions,
        unknownEvents = ns.unknownEvents,
        log = ns.sessionLog,
    }
    if GetBuildInfo then
        local version, build, buildDate, toc = GetBuildInfo()
        report.build = { version = version, build = build, date = buildDate, toc = toc }
    end
    for message, count in pairs(ns.errors) do
        report.errors[#report.errors + 1] = { message = message, count = count }
    end
    return sanitize(report)
end

function Diagnostics:Save()
    if ns.db then
        ns.db.diag = self:Collect()
    end
end

ns:RegisterCommand("diag", "save a report into the settings file (then /reload, so that it is written to disk)", function()
    Diagnostics:Save()
    ns:Print("report saved - /reload (or log out) writes it to disk.")
end)

ns:On("PLAYER_LOGOUT", function()
    Diagnostics:Save()
end)
