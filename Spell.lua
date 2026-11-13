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
-- A crit is times 1.5 (a spell's crit, damage or heal) - what lands over time crits too on Forever (the
-- user, 2026-11-13: "dots can crit", "hots do crit") - raised by talents that raise crit size (see EffectiveLine).
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
    if not every then
        rest = string.match(after, "^[^%.]-every second(.*)$")
        every = rest and "1"
    end
    if every then
        local lasts = string.match(rest, "^[^%d]-for (%d+) sec") or string.match(rest, "^[^%d]-[Ll]asts (%d+) sec")
        if lasts and tonumber(every) > 0 then
            return tonumber(lasts) / tonumber(every)
        end
    end
    return 1
end

-- the words of a spell that takes health from its target
local DRAIN_WORDS = { "transfer", "drain", "steal", "siphon", "leech", "from the target", "from your target", "from an enemy" }
Spell.DRAIN_WORDS = DRAIN_WORDS

-- The damage and the healing the spell's words promise: { damage = n, heal = n } (either may be nil), and
-- in .detail[kind] what one cast lands: { low, high } of the direct part and .overTime.
-- Each amount is a number or "a to b" (the middle); what kind it is comes from the words around it:
--   * followed by "<school> damage" or "damage": damage - unless its own clause speaks of healing
--     ("Heals the target of 45 damage over 15 sec" is a heal);
--   * after "for" or "of" in a clause that speaks of healing: a heal ("Heal your target for 47 to 58");
--   * after "another" or "additional": more of what came before ("... for 93 to 107 and another 98 over 21 sec");
--   * followed by "health" in a clause that takes it from the target - transfers, drains, steals, siphons,
--     leeches ("Transfers 10 health every 1 sec from the target to the caster", Drain Life; the user,
--     2026-11-13: "drain life should have a dps value as well" ... "and spells in that category"): damage.
--     Health given ("Gives 12 health to the caster's pet", Health Funnel) is not;
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
        local drained = false
        if not damageWords and string.match(afterLower, "^%s+health") then
            local clause = before .. (string.match(afterLower, "^[^%.]*") or "")
            for _, word in ipairs(DRAIN_WORDS) do
                if string.find(clause, word, 1, true) then
                    drained = true
                end
            end
            if drained then
                damageWords = string.match(afterLower, "^%s+health")
            end
        end
        -- "heal", "heals", "healing" - but not "health" (a totem "with 5 health", 2026-11-07)
        local healClause = string.find((string.gsub(before, "health", "")), "heal", 1, true)
        if string.find(before, "absorb", 1, true) then
            kind = nil
        elseif damageWords then
            kind = (healClause and not drained) and "heal" or "damage"
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
    if value >= 100 or math.abs(value - math.floor(value + 0.5)) < 0.05 then -- 24.0000001 is 24
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

-- the hit and crit rows of one kind: "  Hit: 20 to 22", "  Crit: 30 to 33" (+ what lands over time).
-- d.critOver set (the user, 2026-11-13: "dots can crit", "hots do crit"): what lands over time crits by it
-- too; unset (Rows asked on its own): it does not, and over time alone is one row
function Spell.Rows(d)
    local over = d.overTime > 0 and (" + " .. whole(d.overTime) .. " over time") or ""
    local overCrit = d.overTime > 0 and d.critOver and (" + " .. whole(d.overTime * d.critOver) .. " over time") or over
    if d.high <= 0 then
        if d.critOver then
            return { "  Over time: " .. whole(d.overTime), "  Crit: " .. whole(d.overTime * d.critOver) .. " over time" }
        end
        return { "  Over time: " .. whole(d.overTime) .. " (no crit)" }
    end
    local crit = d.crit or CRIT
    local each = d.charges and string.format(" each, %d charges", d.charges) or ""
    return { "  Hit: " .. span(d.low, d.high) .. over .. each, "  Crit: " .. span(d.low * crit, d.high * crit) .. overCrit .. each }
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
    d.low, d.high, d.crit, d.melee = d.low + low, d.high + high, MELEE_CRIT, true
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

-- Damage per second (the user, 2026-11-13: "damage / seconds = damage / seconds cast so a 3s shadow bolt is
-- 3s cast, an instant is 1.5s * haste (GCD)"). The whole cast's damage - over time included, as the per
-- mana line counts it - over the seconds the cast takes you:
--   * a channel ("Channeled" on the tooltip): the seconds its words give ("each second for 3 sec");
--   * a cast time from C_Spell.GetSpellInfo (milliseconds, your haste already in it), else the
--     tooltip's "3 sec cast";
--   * an instant: the global cooldown, 1.5 sec shortened by your spell haste (UnitSpellHaste, a percent),
--     never below 1 sec.
local GCD, GCD_FLOOR = 1.5, 1.0

local function seconds(value)
    if value == math.floor(value) then
        return string.format("%d", value)
    end
    return (string.gsub(string.format("%.2f", value), "0$", ""))
end

local function hasteFactor()
    local haste = ns.Readable(_G.UnitSpellHaste, "player")
    haste = haste and haste[1]
    if type(haste) ~= "number" or haste <= -100 then
        return 1
    end
    return 1 + haste / 100
end

-- the seconds one cast takes and what they are ("cast", "channel", "GCD"), or nil
function Spell.CastSeconds(id, lines, text)
    local texts = textsOf(lines)
    for _, t in ipairs(texts) do
        if t == "Channeled" or t == "Channeled (Interruptible)" then
            local duration = text and (string.match(text, "for (%d+%.?%d*) sec") or string.match(text, "over (%d+%.?%d*) sec")
                or string.match(text, "[Ll]asts (%d+%.?%d*) sec"))
            duration = tonumber(duration)
            return duration and duration > 0 and duration or nil, "channel"
        end
    end
    local info = type(C_Spell) == "table" and type(C_Spell.GetSpellInfo) == "function" and ns.Readable(C_Spell.GetSpellInfo, id)
    info = info and info[1]
    local castTime = type(info) == "table" and info.castTime
    if type(castTime) == "number" and castTime > 0 then
        return castTime / 1000, "cast"
    end
    local instant = type(castTime) == "number" and castTime == 0
    for _, t in ipairs(texts) do
        local cast = tonumber(string.match(t, "^%s*(%d+%.?%d*) sec cast"))
        if cast and cast > 0 then
            return cast, "cast"
        end
        if t == "Instant" or t == "Instant cast" then
            instant = true
        end
    end
    if instant then
        return math.max(GCD / hasteFactor(), GCD_FLOOR), "GCD"
    end
    return nil
end

-- EFFECTIVE damage per second (the user, 2026-11-13: "i want the dps to be the EFFECTIVE dps so also take in
-- crit rate and for dots keep in mind that dots can crit and for warlocks they can get a talent that
-- increases crit damage on dots and regular spells and other classes as well"):
--   damage = direct x (1 + chance x (size - 1)) + over time x (1 + chance x (overSize - 1))
-- chance = GetSpellCritChance(school) (a percent; the school from the words: "13 to 18 Shadow damage"),
-- GetCritChance for a strike off the weapon; unreadable: no crit counted, and the line says so.
-- size = x1.5 for a spell (x2 for the weapon), its bonus raised by YOUR talents whose words say they raise
-- critical strike damage ("Increases the critical strike damage bonus of your Destruction spells by
-- 100%" = x2): read from your own talent tree (C_Traits, the active config), so a talent new to Forever
-- counts by its own words. A talent that names a school counts for that school's spells, one that speaks
-- of periodic damage / damage over time for the part over time only, one that names a tree for that
-- tree's spells (TREE_SPELLS), one that names spells for those. A talent whose scope cannot be read is
-- not counted - never a guess - and goes to the report (/ftt diag: spell.critTalents).
local SCHOOLS = { physical = 1, holy = 2, fire = 3, nature = 4, frost = 5, shadow = 6, arcane = 7 }
local TREE_SPELLS = {
    destruction = { "Shadow Bolt", "Immolate", "Searing Pain", "Soul Fire", "Conflagrate", "Shadowburn", "Hellfire", "Rain of Fire", "Incinerate", "Shadowfury" },
    affliction = { "Corruption", "Curse of Agony", "Curse of Doom", "Siphon Life", "Drain Life", "Drain Soul", "Unstable Affliction", "Death Coil", "Seed of Corruption" },
    elemental = { "Lightning Bolt", "Chain Lightning", "Earth Shock", "Flame Shock", "Frost Shock", "Lava Burst" },
    balance = { "Wrath", "Starfire", "Moonfire", "Insect Swarm", "Hurricane", "Starsurge" },
}
local OTHER_TREES = { "arms", "fury", "protection", "retribution", "beast mastery", "marksmanship", "survival", "assassination",
    "combat", "subtlety", "discipline", "enhancement", "restoration", "demonology", "feral" }

function Spell.SchoolOf(text)
    if type(text) ~= "string" then
        return nil
    end
    local lower = string.lower(text)
    for word in string.gmatch(lower, "(%a+) damage") do
        if SCHOOLS[word] then
            return word
        end
    end
    if string.find(lower, "health", 1, true) then
        for _, word in ipairs(DRAIN_WORDS) do
            if string.find(lower, word, 1, true) then
                return "shadow" -- a drain names no school: they are Shadow
            end
        end
    end
    return nil
end

-- one talent's words -> what it raises, or nil (no crit damage in them); { percent, schools, periodic, spells, unread }
function Spell.ParseCritTalent(text)
    if type(text) ~= "string" then
        return nil
    end
    for sentence in string.gmatch(text .. ".", "([^%.]+)%.") do
        local lower = string.lower(sentence)
        local heals = string.find(lower, "heal", 1, true) ~= nil
        local size = string.find(lower, "critical strike damage", 1, true) or string.find(lower, "critical damage", 1, true)
            or string.find(lower, "critical strike bonus", 1, true)
            or (heals and string.find(lower, "critical", 1, true) and string.find(lower, "bonus", 1, true))
        if size and not string.find(lower, "chance", 1, true) then
            local percent = tonumber(string.match(lower, "(%d+)%%"))
            if percent then
                local t = { percent = percent, schools = {}, spells = {}, text = sentence, kind = heals and "heal" or "damage" }
                for school in pairs(SCHOOLS) do
                    if string.find(lower, school, 1, true) then
                        t.schools[school] = true
                    end
                end
                t.periodic = (string.find(lower, "periodic", 1, true) or string.find(lower, "over time", 1, true)) and true or false
                local named = false
                for tree, list in pairs(TREE_SPELLS) do
                    if string.find(lower, tree, 1, true) then
                        named = true
                        for _, name in ipairs(list) do t.spells[name] = true end
                    end
                end
                for _, tree in ipairs(OTHER_TREES) do
                    if string.find(lower, tree, 1, true) then
                        t.unread = "names the " .. tree .. " tree"
                    end
                end
                -- melee and ranged attacks are not spells
                if (string.find(lower, "melee", 1, true) or string.find(lower, "ranged", 1, true) or string.find(lower, "attacks", 1, true))
                    and not string.find(lower, "spell", 1, true) then
                    t.unread = "melee or ranged"
                end
                t.named = named
                return t
            end
        end
    end
    return nil
end

-- the talents you have that raise crit damage (cached until the talents change); the report keeps them all
Spell.critTalents = { read = false }
local talentCache

local function field(value)
    return readable(value) and value or nil
end

local function readTalents()
    local found = {}
    local report = { read = false, talents = 0, crit = {} }
    Spell.critTalents = report
    if type(C_ClassTalents) ~= "table" or type(C_Traits) ~= "table" then
        report.why = "no talent API"
        return found
    end
    local config = ns.Readable(C_ClassTalents.GetActiveConfigID)
    config = config and field(config[1])
    local info = config and ns.Readable(C_Traits.GetConfigInfo, config)
    info = info and info[1]
    local tree = type(info) == "table" and type(info.treeIDs) == "table" and field(info.treeIDs[1])
    local nodes = tree and ns.Readable(C_Traits.GetTreeNodes, tree)
    nodes = nodes and nodes[1]
    if type(nodes) ~= "table" then
        report.why = "no talent tree"
        return found
    end
    report.read = true
    for _, nodeID in ipairs(nodes) do
        local node = ns.Readable(C_Traits.GetNodeInfo, config, nodeID)
        node = node and node[1]
        local rank = type(node) == "table" and (field(node.ranksPurchased) or field(node.activeRank)) or 0
        if type(rank) == "number" and rank > 0 then
            report.talents = report.talents + 1
            local entry = (type(node.activeEntry) == "table" and field(node.activeEntry.entryID))
                or (type(node.entryIDs) == "table" and field(node.entryIDs[1]))
            local text = entry and ns.Readable(C_Traits.GetTraitDescription, entry, rank)
            text = text and field(text[1])
            local parsed = Spell.ParseCritTalent(text)
            if parsed then
                local name
                local entryInfo = type(C_Traits.GetEntryInfo) == "function" and ns.Readable(C_Traits.GetEntryInfo, config, entry)
                entryInfo = entryInfo and entryInfo[1]
                local definition = type(entryInfo) == "table" and field(entryInfo.definitionID)
                definition = definition and type(C_Traits.GetDefinitionInfo) == "function" and ns.Readable(C_Traits.GetDefinitionInfo, definition)
                definition = definition and definition[1]
                local spellID = type(definition) == "table" and field(definition.spellID)
                name = spellID and spellInfoName(spellID)
                parsed.name = name or ("talent " .. tostring(nodeID))
                parsed.rank = rank
                report.crit[#report.crit + 1] = { name = parsed.name, rank = rank, percent = parsed.percent, kind = parsed.kind, text = parsed.text, unread = parsed.unread }
                if not parsed.unread then
                    found[#found + 1] = parsed
                end
            end
        end
    end
    return found
end

function Spell.CritTalents()
    if not talentCache then
        talentCache = readTalents()
    end
    return talentCache
end

function Spell.ForgetTalents()
    talentCache = nil
end

for _, event in ipairs({ "TRAIT_CONFIG_UPDATED", "PLAYER_TALENT_UPDATE", "ACTIVE_PLAYER_SPECIALIZATION_CHANGED", "TRAIT_NODE_CHANGED", "PLAYER_ENTERING_WORLD" }) do
    ns:On(event, Spell.ForgetTalents)
end

-- does a talent count for this spell's part ("direct" or "over")?
local function counts(t, spellName, school, part)
    if t.periodic and part ~= "over" then
        return false
    end
    if t.named then
        return spellName ~= nil and t.spells[spellName] == true
    end
    if next(t.schools) then
        return school ~= nil and t.schools[school] == true
    end
    return true -- "your spells"
end

-- the crit sizes of a spell's two parts and the talents counted: direct, over, names
function Spell.CritSizes(spellName, school, kind)
    local direct, over, names = 0, 0, { direct = {}, over = {} }
    for _, t in ipairs(Spell.CritTalents()) do
        local mine = t.kind == (kind or "damage")
        local d, o = mine and counts(t, spellName, school, "direct"), mine and counts(t, spellName, school, "over")
        if d then direct = direct + t.percent / 100; table.insert(names.direct, t.name) end
        if o then over = over + t.percent / 100; table.insert(names.over, t.name) end
    end
    local bonus = CRIT - 1
    return 1 + bonus * (1 + direct), 1 + bonus * (1 + over), names
end

-- a heal's school, its words naming none: Holy for a priest or paladin, Nature for a druid or shaman
local HEAL_SCHOOL = { PRIEST = "holy", PALADIN = "holy", DRUID = "nature", SHAMAN = "nature" }

function Spell.HealSchool()
    local class = ns.Readable(_G.UnitClass, "player")
    class = class and class[2]
    return HEAL_SCHOOL[class] or "holy"
end

-- the crit chance (0 to 1) for a school, or nil when the client does not say
function Spell.CritChance(school, melee)
    local answer
    if melee then
        answer = ns.Readable(_G.GetCritChance)
    else
        answer = ns.Readable(_G.GetSpellCritChance, SCHOOLS[school or ""] or 2)
    end
    local percent = answer and answer[1]
    if type(percent) ~= "number" or percent < 0 then
        return nil
    end
    return math.min(percent, 100) / 100
end

-- the line: "Damage per second: 5.7", "Heal per second: 22.4" (what went into it: /ftt diag). Heals the same
-- way (the user, 2026-11-13: "do healing spells also have the same thing" ... "hots do crit").
local PER_SECOND = { damage = "Damage per second", heal = "Heal per second" }

function Spell.EffectiveLine(id, lines, text, totals, kind)
    kind = kind or "damage"
    local d = totals.detail and totals.detail[kind]
    if not d then
        return nil
    end
    local castSeconds, what = Spell.CastSeconds(id, lines, text)
    if not castSeconds then
        return nil
    end
    local charges = d.charges or 1
    local overTotal = d.overTime * charges
    local directTotal = totals[kind] - overTotal
    local school = kind == "heal" and Spell.HealSchool() or Spell.SchoolOf(text)
    local chance = Spell.CritChance(school, d.melee)
    local name = spellInfoName(id) or textsOf(lines)[1]
    local directSize, overSize
    if d.melee then
        directSize, overSize = d.crit or MELEE_CRIT, CRIT
    else
        directSize, overSize = Spell.CritSizes(name, school, kind)
    end
    local amount = totals[kind] -- the crit chance unreadable: the plain amount
    if chance then
        amount = directTotal * (1 + chance * (directSize - 1)) + overTotal * (1 + chance * (overSize - 1))
    else
        Spell.stats.dpsNoCrit = (Spell.stats.dpsNoCrit or 0) + 1
    end
    Spell.stats.dps = (Spell.stats.dps or 0) + 1
    -- the user, 2026-11-13: "display it more as damage / cast time and then get rid of all of the text at the end"
    return string.format("%s: %.1f", PER_SECOND[kind], amount / castSeconds), directSize, overSize
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
            do
                local d = totals.detail[kind]
                local line, directSize, overSize
                if ns:GetOption(kind == "heal" and "hps" or "dps") ~= false then
                    line, directSize, overSize = Spell.EffectiveLine(id, lines, text, totals, kind)
                    if line then
                        out[#out + 1] = { line, c[1], c[2], c[3] }
                    end
                end
                -- the crit row by the same sizes: talents counted, and what lands over time crits too
                if not directSize and not d.melee then
                    directSize, overSize = Spell.CritSizes(spellInfoName(id) or textsOf(lines)[1],
                        kind == "heal" and Spell.HealSchool() or Spell.SchoolOf(text), kind)
                end
                if not d.melee then
                    d.crit = directSize
                end
                d.critOver = overSize or CRIT
            end
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
