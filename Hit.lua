-- AKForeverTooltip - your chance to hit the enemy mob under the mouse (the user, 2026-11-16: "for enemy
-- mobs to be able to see my % chance to hit on them based on their level and mine and my % hit"; his
-- choices: the kinds your character uses, and with two weapons both numbers).
--
--   Hit chance: melee 94.6% (swings 75.6%), spell 94%
--
-- WHERE THE NUMBERS COME FROM
--   * Your hit: what the character sheet's Hit Chance row shows, read the way the sheet reads it
--     (wow-ui-source forever, Blizzard_UIPanels_Game/Camelot/PaperDollFrameStats.lua, PaperDollFrame_SetHitChance):
--     GetCombatRatingBonus(CR_HIT_MELEE 6 / RANGED 7 / SPELL 8) + GetHitModifier / GetRangedHitModifier /
--     GetSpellHitModifier.
--   * The chance to miss a mob 0 to 3 levels over you: Blizzard's own table in the same file
--     (CharacterHitFrame_OnEnter): melee { 5.0, 5.2, 5.4, 9.0 }, spells { 4.0, 5.0, 6.0, 17.0 }.
--     Melee is the mob's defence (5 a level) against your weapon skill: 0.04% a point up to 10 points,
--     then 6% + 0.2% a point (15 points = 9%, the table's boss).
--   * Outside that table - a mob 4 levels or more over you, or one under you - the Classic rules, which
--     meet the table at its ends: melee by the same two lines, a spell 11% more a level over +3 and 1% less
--     a level under you, and one spell in a hundred always misses. NOT confirmed for Forever: over the table
--     the numbers carry a "~".
--   * Two weapons: swings (not abilities) miss 19% more - DUAL_WIELD_HIT_PENALTY in Camelot/PaperDollFrame.lua.
--   * A skull: its level is not told. At the top level it is a boss, three levels up; below that, no line.
--
-- DODGED, PARRIED, BLOCKED (the user, 2026-11-17: "can we also show the chance for your melee to be
-- dodged, blocked, parried"): a second line under the first, where there is a melee number.
--   * Dodge: Blizzard's own table in Camelot/PaperDollFrameStats.lua, BASE_ENEMY_DODGE_CHANCE
--     { 5.0, 5.5, 6.0, 6.5 } for a mob 0 to 3 levels over you = 5% + 0.1% a point of its defence over
--     your weapon skill.
--   * Parry and block are NOT in a Forever table (the file's parry table is a leftover of a later
--     game): the Classic rules - parry like dodge up to two levels over you and 14% from three; block
--     5% at most, less when your skill is over its defence. Both only from the front, and only some
--     mobs block at all, so the line says "from the front" and "up to".
--   * Expertise (GetExpertise, per cent) comes off the dodge, and what is left of it after the dodge
--     is gone comes off the parry - as Camelot/PaperDollFrame.lua's GetEnemyDodgeChance and
--     GetEnemyParryChance do it.
--
-- Nothing here is ever worked out from a secret: every answer goes through ns.Readable first, a weapon
-- skill's fields are looked at one by one, and a hit the client keeps to itself (in a fight, perhaps)
-- is replaced by the last one it told - or the kind is left out.
local _, ns = ...

local Hit = {}
ns.Hit = Hit
Hit.stats = {
    lines = 0,
    skulls = 0,       -- a skull below the top level: nothing said
    noLevel = 0,      -- the mob's level, or yours, not told
    noHit = 0,        -- your hit not told for any kind you use, and never told before
    remembered = 0,   -- kinds shown with the hit the client told earlier
    skillAssumed = 0, -- weapon skill not told: the level's worth stood in
    avoidLines = 0,   -- the dodged / parried / blocked line under it
    noExpertise = 0,  -- ... left out because expertise was not told, now or before
}
Hit.last = nil -- what the last line was made of, for /ftt diag

local SKILL_PER_LEVEL = 5
local DUAL_WIELD_PENALTY = 19
local SPELL_CAP = 99
local BOSS_PARRY = 14
local BLOCK_MOST = 5
local BOSS_LEVELS = 3
local TABLE_LEVELS = 3 -- Blizzard's table ends three levels over you
local MAIN_HAND, RANGED = 16, 18
local WEAPON_CLASS = 2
local UNARMED, FERAL = 162, 3014
local COLOR = { 0.80, 0.78, 0.62 }

-- item subclass (Enum.ItemWeaponSubclass) -> the weapon skill's line, as in Camelot/PaperDollFrameStats.lua
local SKILL_OF_SUBCLASS = {
    [0] = 44,   -- one-handed axes
    [1] = 172,  -- two-handed axes
    [2] = 45,   -- bows
    [3] = 46,   -- guns
    [4] = 54,   -- one-handed maces
    [5] = 160,  -- two-handed maces
    [6] = 229,  -- polearms
    [7] = 43,   -- one-handed swords
    [8] = 55,   -- two-handed swords
    [10] = 136, -- staves
    [13] = 162, -- fist weapons
    [15] = 173, -- daggers
    [16] = 176, -- thrown
    [18] = 226, -- crossbows
    [19] = 228, -- wands
}

local BOTH = { "melee", "spell" }
local KINDS = {
    WARRIOR = { "melee" }, ROGUE = { "melee" },
    HUNTER = { "ranged" },
    MAGE = { "spell" }, PRIEST = { "spell" }, WARLOCK = { "spell" },
    SHAMAN = BOTH, PALADIN = BOTH, DRUID = BOTH,
}

local SOURCES = {
    melee = { rating = 6, constant = "CR_HIT_MELEE", modifier = "GetHitModifier" },
    ranged = { rating = 7, constant = "CR_HIT_RANGED", modifier = "GetRangedHitModifier" },
    spell = { rating = 8, constant = "CR_HIT_SPELL", modifier = "GetSpellHitModifier" },
}

------------------------------------------------------------------------
-- The sums. Plain numbers in, plain numbers out.
------------------------------------------------------------------------

-- The chance (%) that a swing or shot misses a mob of that level, with that weapon skill.
function Hit.MeleeMiss(mobLevel, skill)
    local short = mobLevel * SKILL_PER_LEVEL - skill
    local miss
    if short > 10 then
        miss = 6 + short * 0.2
    else
        miss = 5 + short * 0.04
    end
    return math.max(0, math.min(100, miss))
end

-- The chance (%) that a spell misses a mob of that level.
function Hit.SpellMiss(playerLevel, mobLevel)
    local over = mobLevel - playerLevel
    local miss
    if over >= 3 then
        miss = 17 + (over - 3) * 11
    else
        miss = 4 + over
    end
    return math.max(100 - SPELL_CAP, math.min(100, miss))
end

-- The chance (%) that a mob of that level dodges a swing made with that weapon skill.
function Hit.Dodge(mobLevel, skill)
    return math.max(0, math.min(100, 5 + (mobLevel * SKILL_PER_LEVEL - skill) * 0.1))
end

-- ... parries it (from the front): like the dodge, and a flat 14% from three levels over you.
function Hit.Parry(playerLevel, mobLevel, skill)
    if mobLevel - playerLevel >= BOSS_LEVELS then
        return BOSS_PARRY
    end
    return Hit.Dodge(mobLevel, skill)
end

-- ... blocks it (from the front, a mob that blocks at all): 5% at most.
function Hit.Block(mobLevel, skill)
    return math.min(BLOCK_MOST, Hit.Dodge(mobLevel, skill))
end

-- The chance (%) to hit: what does not miss, your hit added on, between nothing and the cap.
function Hit.Chance(miss, hit, cap)
    return math.max(0, math.min(cap or 100, 100 - miss + hit))
end

------------------------------------------------------------------------
-- What the client tells
------------------------------------------------------------------------

-- One number from the client: the number, 0 where it answers with nothing, nil where it will not say.
local function told(fn, ...)
    local answer = ns.Readable(fn, ...)
    if not answer then
        return nil
    end
    local value = answer[1]
    if value == nil then
        return 0
    end
    return type(value) == "number" and value or nil
end

local function first(fn, ...)
    local answer = ns.Readable(fn, ...)
    return answer and answer[1]
end

local remembered = {}

-- Your expertise (per cent off the enemy's dodge): 0 on a client without it, the last one told where
-- the client keeps it to itself, nil when it never told.
local function expertise()
    if type(_G.GetExpertise) ~= "function" then
        return 0
    end
    local value = told(_G.GetExpertise)
    if value then
        remembered.expertise = value
        return value
    end
    return remembered.expertise
end

-- Your hit (%) for that kind, as the character sheet adds it up; nil when the client never told.
local function hitFor(kind)
    local source = SOURCES[kind]
    local bonus, modifier = _G.GetCombatRatingBonus, _G[source.modifier]
    if type(bonus) ~= "function" and type(modifier) ~= "function" then
        return nil -- a client with neither call: there is nothing to go on
    end
    local rating, extra = 0, 0 -- a call the client lacks adds nothing; one it will not answer leaves the sum unknown
    if type(bonus) == "function" then
        rating = told(bonus, type(_G[source.constant]) == "number" and _G[source.constant] or source.rating)
    end
    if type(modifier) == "function" then
        extra = told(modifier)
    end
    if rating and extra then
        remembered[kind] = rating + extra
        return remembered[kind]
    end
    if remembered[kind] then
        Hit.stats.remembered = Hit.stats.remembered + 1
        return remembered[kind]
    end
    return nil
end

-- The skill line of what is in that slot: nil when nothing there has one. `empty` = what an empty slot uses.
local function skillLine(slot, class, empty)
    if class == "DRUID" then
        local form = first(_G.GetShapeshiftForm)
        if type(form) == "number" and form ~= 0 then
            return FERAL
        end
    end
    local itemID = first(_G.GetInventoryItemID, "player", slot)
    if type(itemID) ~= "number" then
        return empty
    end
    local getter = type(C_Item) == "table" and C_Item.GetItemInfoInstant
    if type(getter) ~= "function" then
        return nil
    end
    -- id, type, subtype, equip location, icon, class, subclass (ns.Readable keeps five answers: not enough)
    local ok, _, _, _, _, _, class6, subclass = pcall(getter, itemID)
    if not ok or ns.IsSecret(class6) or ns.IsSecret(subclass) or class6 ~= WEAPON_CLASS then
        return nil
    end
    return SKILL_OF_SUBCLASS[subclass]
end

-- The skill itself, modifiers in; nil when the client will not tell.
local function skillOf(line)
    local getter = type(C_SkillInfo) == "table" and C_SkillInfo.GetSkillLineInfoByID
    local info = line and first(getter, line)
    if type(info) ~= "table" then
        return nil
    end
    local rank, modifier = info.rank, info.modifier
    if ns.IsSecret(rank) or ns.IsSecret(modifier) or type(rank) ~= "number" then
        return nil
    end
    return rank + (type(modifier) == "number" and modifier or 0)
end

local function weaponSkill(slot, class, level, empty)
    local skill = skillOf(skillLine(slot, class, empty))
    if not skill then
        Hit.stats.skillAssumed = Hit.stats.skillAssumed + 1
        return level * SKILL_PER_LEVEL, true
    end
    return skill, false
end

------------------------------------------------------------------------
-- The line
------------------------------------------------------------------------

local function percent(value)
    return (string.format("%.1f", value):gsub("%.0$", "")) .. "%"
end

-- One kind's part of the line and what it was made of; nil when there is no number to give.
local function part(kind, class, level, mobLevel)
    if kind == "ranged" then
        local itemID = first(_G.GetInventoryItemID, "player", RANGED)
        if type(itemID) ~= "number" then
            return nil, "no weapon" -- nothing to shoot with
        end
    end
    local hit = hitFor(kind)
    if not hit then
        return nil, "no hit"
    end
    local made = { hit = hit }
    if kind == "spell" then
        made.miss = Hit.SpellMiss(level, mobLevel)
        made.chance = Hit.Chance(made.miss, hit, SPELL_CAP)
        return made
    end
    made.skill, made.skillAssumed = weaponSkill(kind == "ranged" and RANGED or MAIN_HAND, class, level, kind == "melee" and UNARMED or nil)
    made.miss = Hit.MeleeMiss(mobLevel, made.skill)
    made.chance = Hit.Chance(made.miss, hit)
    if kind == "melee" and first(_G.IsDualWielding) == true then
        made.swings = Hit.Chance(made.miss + DUAL_WIELD_PENALTY, hit)
    end
    return made
end

-- Is this a mob of the enemy's that you can attack? Only a plain yes counts.
local function enemyMob(unit)
    if first(UnitIsPlayer, unit) ~= false then
        return false
    end
    if first(_G.UnitCanAttack, "player", unit) ~= true then
        return false
    end
    if first(_G.UnitIsDead, unit) == true or first(_G.UnitPlayerControlled, unit) == true then
        return false
    end
    return true
end

function Hit.AddUnit(tooltip, unit)
    if not enemyMob(unit) then
        return
    end
    local level, mobLevel = first(UnitLevel, "player"), first(UnitLevel, unit)
    if type(level) ~= "number" or type(mobLevel) ~= "number" or level < 1 or mobLevel == 0 or mobLevel < -1 then
        Hit.stats.noLevel = Hit.stats.noLevel + 1
        return
    end
    local boss = false
    if mobLevel == -1 then
        local top = first(_G.GetMaxLevelForPlayerExpansion)
        if level < (type(top) == "number" and top or 60) then
            Hit.stats.skulls = Hit.stats.skulls + 1
            return
        end
        boss, mobLevel = true, level + BOSS_LEVELS
    end
    local answer = ns.Readable(UnitClass, "player") -- localized name, file name, id
    local class = answer and answer[2]
    local rough = mobLevel - level > TABLE_LEVELS and "~" or ""
    local parts, last = {}, { you = level, mob = mobLevel, boss = boss, class = type(class) == "string" and class or "?" }
    local unarmed = false
    for _, kind in ipairs((type(class) == "string" and KINDS[class]) or BOTH) do
        local made, why = part(kind, class, level, mobLevel)
        unarmed = unarmed or why == "no weapon"
        if made then
            last[kind] = made
            local text = kind .. " " .. rough .. percent(made.chance)
            if made.swings and percent(made.swings) ~= percent(made.chance) then
                text = text .. " (swings " .. rough .. percent(made.swings) .. ")"
            end
            parts[#parts + 1] = text
        end
    end
    if #parts == 0 then
        if not unarmed then
            Hit.stats.noHit = Hit.stats.noHit + 1
        end
        return
    end
    Hit.last = last
    ns.Step("hit chance line")
    tooltip:AddLine((boss and "Hit chance on a boss: " or "Hit chance: ") .. table.concat(parts, ", "), COLOR[1], COLOR[2], COLOR[3])
    Hit.stats.lines = Hit.stats.lines + 1

    -- what the mob does to a swing that would have hit: under the melee number only
    local melee = last.melee
    if not melee or not ns:GetOption("avoidance") then
        return
    end
    local off = expertise()
    if not off then
        Hit.stats.noExpertise = Hit.stats.noExpertise + 1
        return
    end
    local dodge = Hit.Dodge(mobLevel, melee.skill)
    local parry = math.max(0, Hit.Parry(level, mobLevel, melee.skill) - math.max(0, off - dodge))
    last.avoid = { expertise = off, dodge = math.max(0, dodge - off), parry = parry, block = Hit.Block(mobLevel, melee.skill) }
    ns.Step("dodge line")
    tooltip:AddLine("Dodged " .. rough .. percent(last.avoid.dodge) .. "; from the front parried " .. rough .. percent(parry)
        .. ", blocked up to " .. rough .. percent(last.avoid.block), COLOR[1], COLOR[2], COLOR[3])
    Hit.stats.avoidLines = Hit.stats.avoidLines + 1
end
