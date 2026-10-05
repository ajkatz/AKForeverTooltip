-- Camp: what a camp object brings, on its tooltip - the item in your bags, the blueprint that teaches it,
-- and the object standing at the fire.
--
-- Forever's campfires: a cook builds one, players add objects from their professions, and whoever sits by
-- the fire for a minute keeps their buffs for an hour. An object's own tooltip names its buff only at the
-- first tier ("gain 32 increased melee Attack Power, mutually exclusive with Blessing of Might"); the
-- upgrades that stand on it say "provides all the benefits of a Lodestone" and no more. This adds one line
-- to every camp object: the buff as it is AT YOUR LEVEL (the client resolves the first-tier item's Use
-- text for your character; it is read through GetItemSpell and C_Spell.GetSpellDescription), the most it
-- gives at level 60, and the class buff it stands in for - a camp buff and the class buff it copies do not
-- stack.
--
-- The objects are known by their item ids (Forever's item database, build 1.60.1.70205) and, standing at
-- a camp, by their names; the level-60 values are ForeverChanges' reading of the same build. Blizzard's
-- tooltip data hands the id and the lines over directly: nothing is read from the tooltip, nothing secret
-- is looked at.
local _, ns = ...

local Camp = {}
ns.Camp = Camp

local LINE_COLOR = { 0.62, 0.86, 0.60 }
local DIM = "|cff9d9d9d"

-- the first-tier objects: what they give, the most of it (level 60), the class buff they stand in for
local BUFFS = {
    ["Mana Well"]        = { gives = "29 Mana every 5 sec", scales = true, copies = "Blessing of Wisdom", profession = "Alchemy" },
    ["Sharpening Wheel"] = { gives = "34 Strength", scales = true, copies = "Strength of Earth Totem", profession = "Blacksmithing" },
    ["Enchanted Lute"]   = { gives = "308 Armor, 13 to all stats and 22 to all resistances", scales = true, copies = "Mark of the Wild", profession = "Enchanting" },
    ["Reagent Bot"]      = { does = "a reagent vendor for everyone at camp", profession = "Engineering" },
    ["Camp Tent"]        = { does = "rested experience up to 5% of a level, once an hour", profession = "Leatherworking" },
    ["Faction Banner"]   = { gives = "32 Spirit, for your own faction only", scales = true, copies = "Divine Spirit", profession = "Tailoring" },
    ["Lodestone"]        = { gives = "90 melee Attack Power", scales = true, copies = "Blessing of Might", profession = "Mining" },
    ["Incense Candle"]   = { gives = "25 Intellect", scales = true, copies = "Arcane Intellect", profession = "Herbalism" },
    ["Camp Chair"]       = { gives = "2% critical strike chance", copies = "Moonkin Aura", profession = "Skinning" },
    ["Fish Bowl"]        = { gives = "8% to all stats", copies = "Blessing of Kings", profession = "Fishing" },
    ["First Aid Kit"]    = { gives = "56 Stamina", scales = true, copies = "Power Word: Fortitude", profession = "First Aid" },
}

-- every object by item id: its name, the skill it asks (20, 140, 300), the first-tier object whose buff it
-- keeps (`base`), and what it does besides
local OBJECTS = {
    -- tier one (skill 20)
    [279956] = { name = "Mana Well", skill = 20 },
    [279944] = { name = "Sharpening Wheel", skill = 20 },
    [279976] = { name = "Enchanted Lute", skill = 20 },
    [279950] = { name = "Reagent Bot", skill = 20 },
    [279978] = { name = "Camp Tent", skill = 20 },
    [279973] = { name = "Faction Banner", skill = 20 },   -- the Alliance's
    [279972] = { name = "Faction Banner", skill = 20 },   -- the Horde's
    [279960] = { name = "Lodestone", skill = 20 },
    [279962] = { name = "Incense Candle", skill = 20 },
    [279979] = { name = "Camp Chair", skill = 20 },
    [279967] = { name = "Fish Bowl", skill = 20 },
    [279968] = { name = "First Aid Kit", skill = 20 },
    -- tier two (skill 140)
    [279970] = { name = "Fermenter", skill = 140, base = "Mana Well", does = "makes certain Alchemy reagents" },
    [279988] = { name = "Anvil", skill = 140, base = "Sharpening Wheel", does = "an anvil at camp" },
    [279985] = { name = "Arcane Salvager", skill = 140, base = "Enchanted Lute", does = "disenchants more efficiently" },
    [279949] = { name = "Repair Bot", skill = 140, base = "Reagent Bot", does = "sells reagents and repairs gear" },
    [279941] = { name = "Tanning Rack", skill = 140, base = "Camp Tent", does = "makes certain Leatherworking reagents" },
    [279943] = { name = "Spinning Wheel", skill = 140, base = "Faction Banner", does = "makes certain Tailoring reagents" },
    [279948] = { name = "Rock Garden", skill = 140, base = "Lodestone", does = "spawns a common mining node over time" },
    [279964] = { name = "Greenhouse", skill = 140, base = "Incense Candle", does = "grows herbs over time from planted seeds" },
    [279969] = { name = "Field Guide", skill = 140, base = "Camp Chair", does = "Track Beasts to whoever reads it" },
    [279957] = { name = "Cookie's Feast", skill = 140, does = "Stamina food for everyone at camp", profession = "Cooking" },
    [279965] = { name = "Fishing Rack", skill = 140, base = "Fish Bowl", does = "uncommon fish for an hour, and Fishing Skill lures" },
    [279940] = { name = "Toxin Study", skill = 140, base = "First Aid Kit", does = "healing potions and anti-venom" },
    -- tier three (skill 300)
    [279990] = { name = "Alchemy Laboratory", skill = 300, base = "Mana Well", does = "for the most advanced Alchemy recipes" },
    [279955] = { name = "Master Forge", skill = 300, base = "Sharpening Wheel", does = "for the most advanced Blacksmithing recipes" },
    [279987] = { name = "Arcane Forge", skill = 300, base = "Enchanted Lute", does = "for the most advanced Enchanting recipes" },
    [279989] = { name = "Anarchist's Workbench", skill = 300, does = "for the most advanced Engineering recipes", profession = "Engineering" },
    [279945] = { name = "Sewing Machine", skill = 300, base = "Camp Tent", does = "for the most advanced Leatherworking recipes" },
    [279959] = { name = "Loom", skill = 300, base = "Faction Banner", does = "for the most advanced Tailoring recipes" },
    [279952] = { name = "Molten Foundry", skill = 300, base = "Lodestone", does = "for the recipes that ask for it" },
    [279947] = { name = "Seed Hybridizer", skill = 300, base = "Incense Candle", does = "multiplies seeds, or combines them into rarer tiers" },
    [279938] = { name = "Trapper's Workbench", skill = 300, base = "Camp Chair", does = "holds one trap" },
    [279982] = { name = "Iron Oven", skill = 300, does = "for the most advanced Cooking recipes", profession = "Cooking" },
    [279966] = { name = "Fishing Hut", skill = 300, base = "Fish Bowl", does = "rare fish for an hour, and Fishing Skill lures" },
    [279951] = { name = "Plague Doctor's Laboratory", skill = 300, base = "First Aid Kit", does = "healing potions and poultices" },
    -- the campfires themselves, as kits: a cook builds them, the objects stand around them
    [279981] = { name = "Basic Campfire", kit = true, room = 3 },
    [279961] = { name = "Journeyman Campfire", kit = true, room = 5 },
    [279974] = { name = "Expert Campfire", kit = true, room = 10 },
}

-- the blueprints that teach the upgrades and the bigger campfires
local BLUEPRINTS = {
    [273085] = 279970, [273086] = 279988, [273103] = 279985, [273092] = 279949, [273096] = 279941, [273099] = 279943,
    [273097] = 279948, [273106] = 279964, [273098] = 279969, [273102] = 279957, [273141] = 279965, [273105] = 279940,
    [273112] = 279990, [273113] = 279955, [273116] = 279987, [273117] = 279989, [273121] = 279945, [273124] = 279959,
    [273122] = 279952, [273120] = 279947, [273109] = 279938, [273115] = 279982, [273119] = 279966, [273118] = 279951,
    [273087] = 279961, [273101] = 279974,
}

Camp.OBJECTS, Camp.BUFFS, Camp.BLUEPRINTS = OBJECTS, BUFFS, BLUEPRINTS

-- names as keys: lower case, letters only - "Camp Chair", "camp chair" and "Camp-Chair" are one thing
local function key(name)
    return (string.lower(string.gsub(name, "[^%a]", "")))
end

-- the objects by name, for the ones standing at a camp (the first-tier item for a first-tier name)
local BY_KEY = {}
for id, object in pairs(OBJECTS) do
    local k = key(object.name)
    if not BY_KEY[k] or (OBJECTS[BY_KEY[k]].base and not object.base) then
        BY_KEY[k] = id
    end
end
local BASE_ID = {}
for id, object in pairs(OBJECTS) do
    if not object.base and not object.kit then
        BASE_ID[object.name] = BASE_ID[object.name] or id
    end
end

-- a string the addon may look at: not empty, not a secret value
local function readableString(value)
    if type(value) ~= "string" or value == "" or ns.IsSecret(value) then
        return nil
    end
    return value
end

------------------------------------------------------------------------
-- The buff at your level: the first-tier item's Use spell, whose words the client resolves for your
-- character ("... to gain 32 increased melee Attack Power, mutually exclusive with ..."). Not loaded yet
-- on a first look (an empty description): asked for, and there the next time.
------------------------------------------------------------------------
local PATTERNS = { "to gain (.-), mu", "to regenerate (.-), mu", "nearby (.-), mu" }
local requested = {}

local function useSpellOf(itemID)
    local getter = (type(C_Item) == "table" and type(C_Item.GetItemSpell) == "function" and C_Item.GetItemSpell) or (type(GetItemSpell) == "function" and GetItemSpell) or nil
    local answer = getter and ns.Readable(getter, itemID)
    local spellID = answer and answer[2]
    if type(spellID) == "number" then
        return spellID
    end
    return nil
end

function Camp.Now(baseItemID)
    if not baseItemID or type(C_Spell) ~= "table" or type(C_Spell.GetSpellDescription) ~= "function" then
        return nil
    end
    local spellID = useSpellOf(baseItemID)
    if not spellID then
        return nil
    end
    local answer = ns.Readable(C_Spell.GetSpellDescription, spellID)
    local text = answer and readableString(answer[1])
    if not text then
        if not requested[spellID] and type(C_Spell.RequestLoadSpellData) == "function" then
            requested[spellID] = true
            pcall(C_Spell.RequestLoadSpellData, spellID)
        end
        return nil
    end
    for _, pattern in ipairs(PATTERNS) do
        local found = string.match(text, pattern)
        if found then
            return (string.gsub(found, "%s+", " "))
        end
    end
    return nil
end

------------------------------------------------------------------------
-- The words
------------------------------------------------------------------------
function Camp.Words(id)
    local taught = BLUEPRINTS[id]
    local object = OBJECTS[taught or id]
    if not object then
        return nil
    end
    local text
    if object.kit then
        text = "Camp: a campfire with room for " .. object.room .. " camp objects - whoever sits by it a minute keeps the camp buffs for an hour"
    else
        local baseName = object.base or object.name
        local buff = BUFFS[baseName]
        if buff and buff.gives then
            -- a stat buff: whose, how much now and at most, and the class buff it stands in for
            local now = buff.scales and Camp.Now(BASE_ID[baseName]) or nil
            text = "Camp buff" .. (object.base and (" (the " .. object.base .. "'s)") or "") .. ": "
            if now then
                text = text .. "now " .. now .. " - " .. buff.gives .. " at 60"
            else
                text = text .. buff.gives .. (buff.scales and " at 60, less at lower levels" or "")
            end
            if buff.copies then
                text = text .. " - " .. DIM .. "instead of " .. buff.copies .. " - the two do not stack|r"
            end
            if object.does then
                text = text .. " - " .. DIM .. object.does .. "|r"
            end
        elseif buff and buff.does then
            -- the tent and the bot, and what stands on them
            text = "Camp: " .. buff.does .. (object.does and (" - " .. object.does) or "")
        elseif object.does then
            text = "Camp: " .. object.does
        else
            return nil
        end
    end
    if taught then
        text = "Teaches the " .. object.name .. (object.skill and (" (skill " .. object.skill .. ")") or "") .. ". " .. text
    end
    return text
end

------------------------------------------------------------------------
-- The post-calls
------------------------------------------------------------------------
Camp.stats = { items = 0, objects = 0, lines = 0, last = {}, unmatched = {} }

local function remember(list, what, limit)
    list[#list + 1] = what
    if #list > (limit or 12) then
        table.remove(list, 1)
    end
end

local function addLine(tooltip, words)
    ns.Step("camp line")
    tooltip:AddLine(words, LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], true)
    Camp.stats.lines = Camp.stats.lines + 1
end

-- on an item tooltip: the id arrives in the data, as Blizzard hands it over
function Camp.Add(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("camp") then
        return
    end
    Camp.stats.items = Camp.stats.items + 1
    local id = type(data) == "table" and data.id or nil
    if ns.IsSecret(id) or type(id) ~= "number" then
        return
    end
    local words = Camp.Words(id)
    if not words then
        return
    end
    ns.BeginTrace("camp post-call", tooltip)
    remember(Camp.stats.last, { item = id })
    addLine(tooltip, words)
end

-- the object a world object's name means: the name itself, or a longer name that holds one of ours whole
local function objectByName(name)
    local k = key(name)
    if BY_KEY[k] then
        return BY_KEY[k]
    end
    for known, id in pairs(BY_KEY) do
        if #known >= 8 and string.find(k, known, 1, true) then
            return id
        end
    end
    return nil
end
Camp.ObjectByName = objectByName

-- on a world object's tooltip - the tent, the lute, the kit standing at a camp: the data carries the
-- lines Blizzard built, the first being the object's name; the name is matched, nothing else is read
function Camp.AddObject(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("camp") then
        return
    end
    Camp.stats.objects = Camp.stats.objects + 1
    local lines = type(data) == "table" and data.lines or nil
    local first = type(lines) == "table" and lines[1] or nil
    local name = type(first) == "table" and readableString(first.leftText) or nil
    if not name then
        return
    end
    local id = objectByName(name)
    if not id then
        local seen = false
        for _, known in ipairs(Camp.stats.unmatched) do
            if known == name then
                seen = true
            end
        end
        if not seen then
            remember(Camp.stats.unmatched, name, 20)
        end
        return
    end
    local words = Camp.Words(id)
    if not words then
        return
    end
    ns.BeginTrace("camp object post-call", tooltip)
    remember(Camp.stats.last, { object = name })
    addLine(tooltip, words)
end

function Camp.Describe()
    local known = 0
    for _ in pairs(OBJECTS) do
        known = known + 1
    end
    return { items = Camp.stats.items, objects = Camp.stats.objects, lines = Camp.stats.lines, last = Camp.stats.last, unmatched = Camp.stats.unmatched, known = known }
end
