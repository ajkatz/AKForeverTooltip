-- Spell: on a spell's tooltip, how much it does for the mana it costs - "Damage per mana: 0.84" on a
-- Frostbolt, "Heal per mana: 1.75" on a Lesser Heal (the user, 2026-11-07: "can we get offensive/healing
-- spells to calculate the heal/mana cost and damage/mana cost") - and under it what one cast lands, a
-- row for a normal hit and a row for a crit ("i'd also like to see the value for a normal hit and a crit").
--
-- Both numbers come from the client, for your character and the rank under the mouse:
--   * the cost from C_Spell.GetSpellPowerCost (the mana entry), else a "35 Mana" line of the tooltip;
--   * the amount from the spell's own words (C_Spell.GetSpellDescription, else the tooltip's lines):
--     "causing 20 to 22 Frost damage" counts 21, "Heals ... for 47 to 58" counts 52.5, damage or healing
--     over time counts in full ("and an additional 12 Arcane damage over 9 sec"), "26 Arcane damage each
--     second for 3 sec" counts 78. A spell that both hurts and heals (Holy Nova) gets both lines.
-- A crit is the direct part times 1.5 (a spell's crit, damage or heal); what lands over time never crits.
-- What the words leave out stays out: bonus damage and healing from gear, talents, extra targets.
-- A shield's absorb is not a heal. No mana cost, or no amount in the words: no line - never a guess.
local _, ns = ...

local Spell = {}
ns.Spell = Spell
Spell.stats = { seen = 0, lines = 0, noCost = 0, noAmount = 0, macros = 0, macroSpells = 0 }
-- the spells that got no line, for the report: [id] = { why, words, costs } - the words the parser could
-- not read are how it learns Forever's wording (Flame and Earth Shock, 2026-11-07)
Spell.misses = {}
local MAX_MISSES = 16
local CRIT = 1.5       -- a spell's crit
local MELEE_CRIT = 2   -- a weapon's

local MANA = (Enum and Enum.PowerType and Enum.PowerType.Mana) or 0
local COLOR = {
    damage = { 1.00, 0.62, 0.35 },
    heal = { 0.45, 0.95, 0.45 },
    rows = { 0.85, 0.85, 0.85 },
}
local LABEL = { damage = "Damage per mana", heal = "Heal per mana" }

local function number(text)
    return tonumber((string.gsub(text or "", ",", "")))
end

local function readable(value)
    return value ~= nil and not ns.IsSecret(value)
end

-- the readable texts of the tooltip's lines, left then right
local function textsOf(lines)
    local out = {}
    for _, line in ipairs(lines or {}) do
        if type(line) == "table" then
            for _, t in ipairs({ line.leftText, line.rightText }) do
                if readable(t) and type(t) == "string" and t ~= "" then
                    out[#out + 1] = t
                end
            end
        end
    end
    return out
end

local function miss(id, why, text, lines)
    if Spell.misses[id] then
        return
    end
    local count = 0
    for _ in pairs(Spell.misses) do count = count + 1 end
    if count >= MAX_MISSES then
        return
    end
    local costs = {}
    local answer = type(C_Spell) == "table" and ns.Readable(C_Spell.GetSpellPowerCost, id)
    for _, entry in ipairs(answer and type(answer[1]) == "table" and answer[1] or {}) do
        if type(entry) == "table" then
            local copy = {}
            for k, v in pairs(entry) do
                if not ns.IsSecret(v) and (type(v) == "number" or type(v) == "string" or type(v) == "boolean") then
                    copy[k] = v
                end
            end
            costs[#costs + 1] = copy
        end
    end
    Spell.misses[id] = { why = why, description = text, lines = textsOf(lines), costs = costs }
end

-- the spell's name, or nil
local function spellInfoName(id)
    if type(C_Spell) ~= "table" or type(C_Spell.GetSpellName) ~= "function" then
        return nil
    end
    local answer = ns.Readable(C_Spell.GetSpellName, id)
    return answer and type(answer[1]) == "string" and answer[1] or nil
end

-- the mana the spell costs, or nil
function Spell.ManaCost(id, lines)
    local costs = type(C_Spell) == "table" and ns.Readable(C_Spell.GetSpellPowerCost, id)
    costs = costs and costs[1]
    if type(costs) == "table" then
        for _, entry in ipairs(costs) do
            if type(entry) == "table" and readable(entry.type) and readable(entry.cost)
                and (entry.type == MANA or entry.name == "MANA") and type(entry.cost) == "number" and entry.cost > 0 then
                return entry.cost
            end
        end
    end
    -- the tooltip's own cost line: "35 Mana"
    for _, text in ipairs(textsOf(lines)) do
        local cost = number(string.match(text, "^%s*([%d,]+) Mana%s*$"))
        if cost and cost > 0 then
            return cost
        end
    end
    return nil
end

-- after an amount, how many times it lands: "each second for 3 sec", "every 2 sec for 10 sec",
-- "every 1 sec. Lasts 5 sec" (in the same sentence)
local function ticks(after)
    local duration = string.match(after, "^[^%.]-each second for (%d+) sec")
    if duration then
        return tonumber(duration)
    end
    local every, rest = string.match(after, "^[^%.]-every (%d+) sec(.*)$")
    if every then
        local lasts = string.match(rest, "^[^%d]-for (%d+) sec") or string.match(rest, "^[^%d]-[Ll]asts (%d+) sec")
        if lasts and tonumber(every) > 0 then
            return tonumber(lasts) / tonumber(every)
        end
    end
    return 1
end

-- The damage and the healing the spell's words promise: { damage = n, heal = n } (either may be nil), and
-- in .detail[kind] what one cast lands: { low, high } of the direct part and .overTime.
-- Each amount is a number or "a to b" (the middle); what kind it is comes from the words around it:
--   * followed by "<school> damage" or "damage": damage - unless its own clause speaks of healing
--     ("Heals the target of 45 damage over 15 sec" is a heal);
--   * after "for" or "of" in a clause that speaks of healing: a heal ("Heal your target for 47 to 58");
--   * after "another" or "additional": more of what came before ("... for 93 to 107 and another 98 over 21 sec");
--   * anything else is not an amount: yards, seconds, percentages, ranks, levels.
-- An amount followed by "over N sec", or landing in ticks, is over time. A clause that speaks of
-- absorbing counts nothing.
function Spell.Amounts(text)
    if type(text) ~= "string" or text == "" then
        return nil
    end
    local totals, detail, previous, from = {}, {}, nil, 1
    local position = 1
    while true do
        local s, e, low, high = string.find(text, "(%d[%d,]*) to (%d[%d,]*)", position)
        local s1, e1, single = string.find(text, "(%d[%d,]*)", position)
        if not s1 then
            break
        end
        local amount, lo, hi
        if s and s == s1 then
            lo, hi = number(low), number(high)
            amount = (lo + hi) / 2
        else
            s, e, amount = s1, e1, number(single)
            lo, hi = amount, amount
        end
        local before = string.lower(string.sub(text, from, s - 1))
        local after = string.sub(text, e + 1, e + 80)
        local afterLower = string.lower(after)
        local kind
        local damageWords = string.match(afterLower, "^%s+%a+%s+damage") or string.match(afterLower, "^%s+damage")
        -- "heal", "heals", "healing" - but not "health" (a totem "with 5 health", 2026-11-07)
        local healClause = string.find((string.gsub(before, "health", "")), "heal", 1, true)
        if string.find(before, "absorb", 1, true) then
            kind = nil
        elseif damageWords then
            kind = healClause and "heal" or "damage"
        elseif healClause and (string.match(before, "for%s*$") or string.match(before, "of%s*$")) then
            kind = "heal"
        elseif previous and (string.match(before, "another%s*$") or string.match(before, "additional%s*$")) then
            kind = previous
        end
        -- a percentage, seconds or yards are never an amount, whatever came before
        if kind and (string.match(after, "^%%") or string.match(afterLower, "^%s*sec") or string.match(afterLower, "^%s*yard") or string.match(afterLower, "^%s*min") or string.match(afterLower, "^%s*hour")) then
            kind = nil
        end
        if kind and amount then
            local stop = e + (damageWords and #damageWords or 0)
            local rest = string.sub(text, stop + 1, stop + 80)
            local times = ticks(rest)
            amount = amount * times
            totals[kind] = (totals[kind] or 0) + amount
            local d = detail[kind] or { low = 0, high = 0, overTime = 0 }
            detail[kind] = d
            if times > 1 or string.match(string.lower(rest), "^%s*over %d+ sec") then
                d.overTime = d.overTime + amount
            else
                d.low, d.high = d.low + lo, d.high + hi
            end
            previous = kind
            from = stop + 1
        end
        position = e + 1
    end
    if not totals.damage and not totals.heal then
        return nil
    end
    -- charges: "Surrounds the caster with 3 balls of lightning" - each strikes once (Lightning Shield,
    -- 2026-11-07: "seems to only calculate for one hit instead of 3"); the rows stay per strike
    local charges = tonumber(string.match(text, "(%d+) balls? of") or string.match(text, "(%d+) charges?"))
    if charges and charges > 1 then
        for kind, value in pairs(totals) do
            totals[kind] = value * charges
            detail[kind].charges = charges
        end
    end
    totals.detail = detail
    return totals
end

local function format(value)
    if value >= 100 or value == math.floor(value) then
        return string.format("%d", math.floor(value + 0.5))
    end
    return string.format("%.1f", value)
end

local function whole(value)
    return string.format("%d", math.floor(value + 0.5))
end

local function span(low, high)
    if whole(low) == whole(high) then
        return whole(low)
    end
    return whole(low) .. " to " .. whole(high)
end

-- the hit and crit rows of one kind: "  Hit: 20 to 22", "  Crit: 30 to 33" (+ what lands over time);
-- over time only: one row, it cannot crit
function Spell.Rows(d)
    local over = d.overTime > 0 and (" + " .. whole(d.overTime) .. " over time") or ""
    if d.high <= 0 then
        return { "  Over time: " .. whole(d.overTime) .. " (no crit)" }
    end
    local crit = d.crit or CRIT
    local each = d.charges and string.format(" each, %d charges", d.charges) or ""
    return { "  Hit: " .. span(d.low, d.high) .. over .. each, "  Crit: " .. span(d.low * crit, d.high * crit) .. over .. each }
end

-- A STRIKE OFF YOUR WEAPON: "Instantly strike for 150% weapon damage" (Forever's Stormstrike, 2026-11-07)
-- names no number of its own - the percentage of your main hand, as your character sheet gives it
-- (UnitDamage: the swing with your attack power in it). A melee crit is double. UnitDamage is secret
-- while your stats are restricted (likely in a fight): then no line.
function Spell.WeaponStrike(text, totals)
    local percent = type(text) == "string" and tonumber(string.match(text, "(%d+)%% weapon damage"))
    if not percent then
        return totals
    end
    local damage = ns.Readable(_G.UnitDamage, "player")
    local low, high = damage and damage[1], damage and damage[2]
    if type(low) ~= "number" or type(high) ~= "number" or high <= 0 then
        Spell.stats.weaponUnreadable = (Spell.stats.weaponUnreadable or 0) + 1
        return totals
    end
    low, high = low * percent / 100, high * percent / 100
    totals = totals or { detail = {} }
    totals.detail = totals.detail or {}
    local d = totals.detail.damage or { low = 0, high = 0, overTime = 0 }
    d.low, d.high, d.crit = d.low + low, d.high + high, MELEE_CRIT
    totals.detail.damage = d
    totals.damage = (totals.damage or 0) + (low + high) / 2
    return totals
end

-- AUTO ATTACKS: "Attack" (your weapon) and "Shoot" (your wand) cost no mana, so they get the hit and crit
-- rows with damage per second instead (the user, 2026-11-07: "the same tooltip to show on 'attack' and
-- 'shoot' as well for attack and wand"). From the character sheet: UnitDamage + UnitAttackSpeed for the
-- swing (and the off hand when there is one), UnitRangedDamage for the wand. A melee crit is double, a
-- wand's x1.5. All secret while your stats are restricted (likely in a fight): then no lines.
local AUTO = { [6603] = "melee", [5019] = "wand" }
local AUTO_NAMES = { Attack = "melee", Shoot = "wand" }
local WAND_CRIT = 1.5
local DUAL_WIELDERS = { WARRIOR = true, HUNTER = true, ROGUE = true }

local function autoKind(id, lines)
    if AUTO[id] then
        return AUTO[id]
    end
    local name = spellInfoName(id) or textsOf(lines)[1]
    return name and AUTO_NAMES[name] or nil
end

local function swingRows(label, low, high, speed, crit)
    local c = COLOR.damage
    local perSecond = (type(speed) == "number" and speed > 0) and string.format("  (%.1f per sec, every %.1f sec)", (low + high) / 2 / speed, speed) or ""
    return {
        { label .. span(low, high) .. perSecond, c[1], c[2], c[3] },
        { "  Crit: " .. span(low * crit, high * crit), COLOR.rows[1], COLOR.rows[2], COLOR.rows[3] },
    }
end

function Spell.AutoLines(kind)
    local out = {}
    if kind == "melee" then
        local damage = ns.Readable(_G.UnitDamage, "player")
        local speed = ns.Readable(_G.UnitAttackSpeed, "player")
        if not damage or type(damage[1]) ~= "number" or type(damage[2]) ~= "number" or damage[2] <= 0 then
            Spell.stats.weaponUnreadable = (Spell.stats.weaponUnreadable or 0) + 1
            return nil
        end
        for _, row in ipairs(swingRows("Hit: ", damage[1], damage[2], speed and speed[1], MELEE_CRIT)) do
            out[#out + 1] = row
        end
        -- the off hand only for the classes that dual wield (the user, 2026-11-07: a shaman got an off-hand row)
        local class = ns.Readable(_G.UnitClass, "player")
        class = class and class[2]
        if DUAL_WIELDERS[class] and type(damage[3]) == "number" and type(damage[4]) == "number" and damage[4] > 0 then
            for _, row in ipairs(swingRows("Off hand: ", damage[3], damage[4], speed and speed[2], MELEE_CRIT)) do
                out[#out + 1] = row
            end
        end
    else
        local wand = ns.Readable(_G.UnitRangedDamage, "player")
        if not wand or type(wand[2]) ~= "number" or type(wand[3]) ~= "number" or wand[3] <= 0 then
            Spell.stats.weaponUnreadable = (Spell.stats.weaponUnreadable or 0) + 1
            return nil
        end
        out = swingRows("Hit: ", wand[2], wand[3], wand[1], WAND_CRIT)
    end
    return out
end

-- the lines for one spell: { { text, r, g, b }, ... } or nil
function Spell.Lines(id, lines)
    local auto = autoKind(id, lines)
    if auto then
        return ns:GetOption("hitRows") ~= false and Spell.AutoLines(auto) or nil
    end
    local cost = Spell.ManaCost(id, lines)
    if not cost then
        Spell.stats.noCost = Spell.stats.noCost + 1
        miss(id, "no mana cost", nil, lines)
        return nil
    end
    local text
    local description = type(C_Spell) == "table" and ns.Readable(C_Spell.GetSpellDescription, id)
    if description and type(description[1]) == "string" and description[1] ~= "" then
        text = description[1]
    end
    -- totems: no line (the user, 2026-11-07: "maybe just take that off of totems in general") - what a
    -- totem does depends on how long it stands and what comes near it, not on one cast
    local name = spellInfoName(id)
    local words = table.concat(textsOf(lines), " ") .. " " .. (text or "") .. " " .. (name or "")
    if string.find(words, "Totem", 1, true) then
        Spell.stats.totems = (Spell.stats.totems or 0) + 1
        return nil
    end
    local totals = text and Spell.Amounts(text)
    if not totals then
        -- the tooltip's own words: the longest readable line is the description
        local longest
        for _, t in ipairs(textsOf(lines)) do
            if not longest or #t > #longest then
                longest = t
            end
        end
        totals = longest and Spell.Amounts(longest)
        text = text or longest
    end
    totals = Spell.WeaponStrike(text, totals)
    if not totals then
        Spell.stats.noAmount = Spell.stats.noAmount + 1
        miss(id, "no amount in the words", text, lines)
        return nil
    end
    local out = {}
    for _, kind in ipairs({ "damage", "heal" }) do
        local amount = totals[kind]
        if amount and amount > 0 then
            local c = COLOR[kind]
            out[#out + 1] = { string.format("%s: %.2f  (%s / %s mana)", LABEL[kind], amount / cost, format(amount), format(cost)), c[1], c[2], c[3] }
            if ns:GetOption("hitRows") ~= false then
                for _, row in ipairs(Spell.Rows(totals.detail[kind])) do
                    out[#out + 1] = { row, COLOR.rows[1], COLOR.rows[2], COLOR.rows[3] }
                end
            end
        end
    end
    return #out > 0 and out or nil
end

function Spell.Add(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("efficiency") then
        return
    end
    local id = type(data) == "table" and data.id or nil
    if ns.IsSecret(id) or type(id) ~= "number" then
        return
    end
    Spell.stats.seen = Spell.stats.seen + 1
    local lines = Spell.Lines(id, type(data.lines) == "table" and data.lines or nil)
    if not lines then
        return
    end
    ns.BeginTrace("spell post-call", tooltip)
    ns.Step("efficiency line")
    for _, line in ipairs(lines) do
        tooltip:AddLine(line[1], line[2], line[3], line[4])
        Spell.stats.lines = Spell.stats.lines + 1
    end
end

------------------------------------------------------------------------
-- Macros
------------------------------------------------------------------------
-- A MACRO on an action button (#showtooltip) is its own kind of tooltip, not a spell one (the user,
-- 2026-11-07: "not seeing it on spells that have macro #showtooltip"). The first report (17:59) showed
-- the data's id is a small number (2) - a macro index or an action slot - with no slot on the button and
-- an empty first line. So every route offers a candidate spell, and the first one the tooltip's own lines
-- confirm wins (its name or its description is one of them):
--   * the button's action (GetActionInfo: a "spell" subtype carries the spell's id, else the macro's
--     index for GetMacroSpell);
--   * the data's id as a macro index (GetMacroSpell), and as an action slot (GetActionInfo);
--   * a line that is a spell's name.
-- When the lines say nothing readable, the first candidate stands. Each route's answer is kept for the
-- report (Spell.lastMacro).
local function call(name, ...)
    local answer = ns.Readable(_G[name], ...)
    return answer and answer[1], answer and answer[2], answer and answer[3]
end

local function slotOf(owner)
    if type(owner) ~= "table" then
        return nil
    end
    local slot = rawget(owner, "action")
    if type(slot) ~= "number" and type(owner.GetAttribute) == "function" then
        local attribute = ns.Readable(owner.GetAttribute, owner, "action")
        slot = attribute and tonumber(attribute[1])
    end
    return type(slot) == "number" and slot or nil
end

-- the spell an action slot holds: a macro's (by subtype or GetMacroSpell) or a plain spell
local function spellOfSlot(slot, trace, label)
    local kind, actionID, subType = call("GetActionInfo", slot)
    trace[label] = { kind = kind, id = actionID, subType = subType }
    if kind == "macro" and type(actionID) == "number" then
        if subType == "spell" then
            return actionID
        end
        local spellID = call("GetMacroSpell", actionID)
        return type(spellID) == "number" and spellID or nil
    elseif kind == "spell" and type(actionID) == "number" then
        return actionID
    end
    return nil
end

local function spellInfo(which)
    if type(C_Spell) ~= "table" or type(C_Spell.GetSpellInfo) ~= "function" then
        return nil
    end
    local info = ns.Readable(C_Spell.GetSpellInfo, which)
    info = info and info[1]
    return type(info) == "table" and type(info.spellID) == "number" and info or nil
end

-- do the tooltip's lines speak of this spell (its name or its words)?
local function confirmed(spellID, texts)
    local info = spellInfo(spellID)
    local description = type(C_Spell) == "table" and ns.Readable(C_Spell.GetSpellDescription, spellID)
    description = description and description[1]
    for _, t in ipairs(texts) do
        if (info and t == info.name) or (type(description) == "string" and description ~= "" and t == description) then
            return true
        end
    end
    return false
end

function Spell.MacroSpell(tooltip, data)
    local trace = {}
    Spell.lastMacro = trace
    local id = type(data) == "table" and data.id or nil
    id = readable(id) and type(id) == "number" and id or nil
    local texts = textsOf(type(data) == "table" and data.lines or nil)
    trace.dataID, trace.lines = id, { texts[1], texts[2], texts[3], texts[4] }
    local owner = ns.Readable(tooltip.GetOwner, tooltip)
    owner = owner and owner[1]
    if type(owner) == "table" and type(owner.GetName) == "function" then
        local name = ns.Readable(owner.GetName, owner)
        trace.owner = name and name[1]
    end

    local candidates = {}
    local function offer(route, spellID)
        if type(spellID) == "number" then
            candidates[#candidates + 1] = { route = route, id = spellID }
        end
    end
    local slot = slotOf(owner)
    trace.slot = slot
    if slot then
        offer("button", spellOfSlot(slot, trace, "button"))
    end
    if id then
        local spellID = call("GetMacroSpell", id)
        trace.macroSpell = spellID
        offer("macro index", spellID)
        offer("action slot", spellOfSlot(id, trace, "dataSlot"))
    end
    for _, t in ipairs(texts) do
        local info = #t <= 40 and spellInfo(t)
        if info then
            offer("name", info.spellID)
            break
        end
    end
    trace.candidates = #candidates
    for _, c in ipairs(candidates) do
        if confirmed(c.id, texts) then
            trace.route = c.route
            return c.id
        end
    end
    if #texts == 0 and candidates[1] then
        trace.route = candidates[1].route .. " (unconfirmed)"
        return candidates[1].id
    end
    trace.route = "none"
    return nil
end

function Spell.AddMacro(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("efficiency") then
        return
    end
    Spell.stats.macros = Spell.stats.macros + 1
    local spellID = Spell.MacroSpell(tooltip, data)
    if not spellID then
        return
    end
    Spell.stats.macroSpells = Spell.stats.macroSpells + 1
    Spell.Add(tooltip, { id = spellID, lines = type(data) == "table" and data.lines or nil })
end
