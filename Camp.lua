-- Camp: what a camp object brings, on its tooltip.
--
-- Forever's campfires: a cook builds one, players add objects from their professions, and whoever sits by
-- the fire for a minute keeps their buffs for an hour. An object's own tooltip names its buff only at the
-- first tier ("gain 32 increased melee Attack Power, mutually exclusive with Blessing of Might"); the
-- upgrades that stand on it say "provides all the benefits of a Lodestone" and no more. This adds one line
-- to every camp object and to the blueprints that teach them: the buff, the most it gives at level 60,
-- and the class buff it stands in for - a camp buff and the class buff it copies do not stack.
--
-- The objects are known by their item ids (Forever's item database, build 1.60.1.70205); the values are
-- ForeverChanges' reading of the same build. Blizzard's tooltip data hands the id over directly: nothing is
-- read from the tooltip, nothing secret is looked at.
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

-- every object by item id: its name, tier (the skill it asks: 20, 140, 300), the first-tier object whose
-- buff it keeps (`base`), and what it does besides
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
}

-- the blueprints that teach the upgrades, and the bigger campfires
local BLUEPRINTS = {
    [273085] = 279970, [273086] = 279988, [273103] = 279985, [273092] = 279949, [273096] = 279941, [273099] = 279943,
    [273097] = 279948, [273106] = 279964, [273098] = 279969, [273102] = 279957, [273141] = 279965, [273105] = 279940,
    [273112] = 279990, [273113] = 279955, [273116] = 279987, [273117] = 279989, [273121] = 279945, [273124] = 279959,
    [273122] = 279952, [273120] = 279947, [273109] = 279938, [273115] = 279982, [273119] = 279966, [273118] = 279951,
}
local CAMPFIRES = {
    [273087] = "Journeyman Campfire: holds 5 camp objects",
    [273101] = "Expert Campfire: holds 10 camp objects",
}

Camp.OBJECTS, Camp.BUFFS, Camp.BLUEPRINTS = OBJECTS, BUFFS, BLUEPRINTS

-- the words for one object
function Camp.Words(id)
    local campfire = CAMPFIRES[id]
    if campfire then
        return "Camp: " .. campfire
    end
    local taught = BLUEPRINTS[id]
    local object = OBJECTS[taught or id]
    if not object then
        return nil
    end
    local buff = BUFFS[object.base or object.name]
    local text
    if buff and buff.gives then
        -- a stat buff: whose, how much at most, and the class buff it stands in for
        text = "Camp buff" .. (object.base and (" (the " .. object.base .. "'s)") or "") .. ": " .. buff.gives .. (buff.scales and " at 60, less at lower levels" or "")
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
    if taught then
        text = "Teaches the " .. object.name .. " (skill " .. object.skill .. "). " .. text
    end
    return text
end

-- the post-call on an item tooltip: the id arrives in the data, as Blizzard hands it over
function Camp.Add(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("camp") then
        return
    end
    local id = type(data) == "table" and data.id or nil
    if ns.IsSecret(id) or type(id) ~= "number" then
        return
    end
    local words = Camp.Words(id)
    if not words then
        return
    end
    ns.BeginTrace("camp post-call", tooltip)
    ns.Step("camp line")
    tooltip:AddLine(words, LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3], true)
    Camp.lines = (Camp.lines or 0) + 1
end
