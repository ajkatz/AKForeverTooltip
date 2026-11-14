-- AKForeverTooltip - how many of an item you have: every character of yours on this realm, in its bags
-- and its bank (the user, 2026-11-13: "display how many of an item you have in your inventory + your
-- bank/any possible storage"; his choices: all characters, bags + bank).
--
-- What each character carries is saved with its profile (cdb.counts) when it changes:
--   * the bags (the reagent bag too): after every bag change (BAG_UPDATE_DELAYED) and at login;
--   * the bank: only while the bank is open - Forever's bank is tabs (C_Bank.FetchPurchasedBankTabIDs,
--     wow-ui-source forever branch, Camelot/BankFrame.lua); an older client's bank (-1 and its bags) if not.
--     The account bank's tabs belong to every character: kept once, account-wide (db.accountBank).
-- A character whose bank was never opened with this addon simply has no bank count yet. Anything the
-- client answers with a secret leaves the saved count as it was - never a wrong number.
local _, ns = ...

local Counts = {}
ns.Counts = Counts
Counts.stats = { bagScans = 0, bankScans = 0, keptOld = 0, lines = 0 }
Counts.bankOpen = false

local BANK_CONTAINER = -1
local LEGACY_BANK_BAGS = 7

local function equippedBags()
    if type(NUM_TOTAL_EQUIPPED_BAG_SLOTS) == "number" then
        return NUM_TOTAL_EQUIPPED_BAG_SLOTS -- the backpack's four bags + the reagent bag (id 5)
    end
    return (type(NUM_BAG_SLOTS) == "number" and NUM_BAG_SLOTS or 4) + 1
end

-- one container's items added into `into`; false if the client would not say
local function readContainer(bag, into)
    if type(C_Container) ~= "table" then
        return false
    end
    local slots = ns.Readable(C_Container.GetContainerNumSlots, bag)
    slots = slots and slots[1]
    if type(slots) ~= "number" then
        return false
    end
    for slot = 1, slots do
        local answer = ns.Readable(C_Container.GetContainerItemInfo, bag, slot)
        if answer == nil then
            return false -- an error or a secret
        end
        local info = answer[1]
        if type(info) == "table" then
            local id, count = info.itemID, info.stackCount
            if ns.IsSecret(id) or ns.IsSecret(count) then
                return false
            end
            if type(id) == "number" and type(count) == "number" and count > 0 then
                into[id] = (into[id] or 0) + count
            end
        end
    end
    return true
end

local function readAll(bags)
    local into = {}
    for _, bag in ipairs(bags) do
        if not readContainer(bag, into) then
            Counts.stats.keptOld = Counts.stats.keptOld + 1
            return nil
        end
    end
    return into
end

local function bankTabs(kind)
    if type(C_Bank) ~= "table" or type(C_Bank.FetchPurchasedBankTabIDs) ~= "function" or not (Enum and Enum.BankType) then
        return nil
    end
    local answer = ns.Readable(C_Bank.FetchPurchasedBankTabIDs, Enum.BankType[kind])
    local ids = answer and answer[1]
    if type(ids) ~= "table" then
        return nil
    end
    local list = {}
    for _, id in ipairs(ids) do
        if type(id) == "number" and not ns.IsSecret(id) then
            list[#list + 1] = id
        end
    end
    return list
end

local function profile()
    if not ns.characterKey or type(ns.cdb) ~= "table" then
        return nil -- before PLAYER_LOGIN: the profile is a stand-in
    end
    local counts = ns.cdb.counts
    if type(counts) ~= "table" then
        counts = {}
        ns.cdb.counts = counts
    end
    local class = ns.Readable(UnitClass, "player")
    if class and type(class[2]) == "string" then
        counts.class = class[2]
    end
    return counts
end

function Counts.ScanBags()
    local counts = profile()
    if not counts then
        return
    end
    local bags = {}
    for bag = 0, equippedBags() do
        bags[#bags + 1] = bag
    end
    local items = readAll(bags)
    if items then
        counts.bags = items
        Counts.stats.bagScans = Counts.stats.bagScans + 1
    end
end

function Counts.ScanBank()
    local counts = profile()
    if not counts or not Counts.bankOpen then
        return
    end
    local tabs = bankTabs("Character")
    if not tabs then
        tabs = { BANK_CONTAINER }
        for i = 1, LEGACY_BANK_BAGS do
            tabs[#tabs + 1] = equippedBags() + i
        end
    end
    local items = readAll(tabs)
    if items then
        counts.bank = items
        Counts.stats.bankScans = Counts.stats.bankScans + 1
    end
    local account = bankTabs("Account")
    if account and #account > 0 and type(ns.db) == "table" then
        local shared = readAll(account)
        if shared then
            ns.db.accountBank = { items = shared }
        end
    end
end

------------------------------------------------------------------------
-- The tooltip lines
------------------------------------------------------------------------
local LINE_COLOR = { 0.85, 0.85, 0.85 }

local function realmOf(key)
    return type(key) == "string" and string.match(key, " %- (.+)$") or nil
end

local function shortName(key)
    return string.match(key, "^(.-) %- ") or key -- the whole name, "First Last": alts can share a first name
end

-- { { name, class, bags, bank, total, me }, ... } for the item, the character you are on first
function Counts.Holders(itemID)
    local out = {}
    local chars = type(ns.db) == "table" and ns.db.chars
    local realm = realmOf(ns.characterKey)
    if type(chars) ~= "table" or not realm then
        return out
    end
    for key, cdb in pairs(chars) do
        local counts = type(cdb) == "table" and cdb.counts
        if type(counts) == "table" and realmOf(key) == realm then
            local bags = type(counts.bags) == "table" and counts.bags[itemID] or 0
            local bank = type(counts.bank) == "table" and counts.bank[itemID] or 0
            if bags + bank > 0 then
                out[#out + 1] = { name = shortName(key), class = counts.class, bags = bags, bank = bank, total = bags + bank, me = key == ns.characterKey }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.me ~= b.me then
            return a.me
        end
        if a.total ~= b.total then
            return a.total > b.total
        end
        return a.name < b.name
    end)
    return out
end

local function where(h)
    if h.bags > 0 and h.bank > 0 then
        return string.format("%d  (bags %d, bank %d)", h.total, h.bags, h.bank)
    elseif h.bank > 0 then
        return string.format("%d  (bank)", h.bank)
    end
    return string.format("%d  (bags)", h.bags)
end

-- the lines: { { text, r, g, b }, ... }
function Counts.Lines(itemID)
    local lines, total = {}, 0
    for _, h in ipairs(Counts.Holders(itemID)) do
        local c = h.class and type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[h.class]
        local r, g, b = LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3]
        if type(c) == "table" then
            r, g, b = c.r, c.g, c.b
        end
        lines[#lines + 1] = { h.name .. ": " .. where(h), r, g, b }
        total = total + h.total
    end
    local account = type(ns.db) == "table" and type(ns.db.accountBank) == "table" and ns.db.accountBank.items
    local shared = type(account) == "table" and account[itemID] or 0
    if shared > 0 then
        lines[#lines + 1] = { "Account bank: " .. shared, LINE_COLOR[1], LINE_COLOR[2], LINE_COLOR[3] }
        total = total + shared
    end
    if #lines > 1 then
        lines[#lines + 1] = { "Total: " .. total, 1, 0.82, 0 }
    end
    return lines
end

function Counts.Add(tooltip, data)
    if tooltip ~= GameTooltip or not ns:GetOption("counts") then
        return
    end
    local id = type(data) == "table" and data.id or nil
    if ns.IsSecret(id) or type(id) ~= "number" then
        return
    end
    local lines = Counts.Lines(id)
    if #lines == 0 then
        return
    end
    ns.BeginTrace("item counts", tooltip)
    ns.Step("count lines")
    for _, line in ipairs(lines) do
        tooltip:AddLine(line[1], line[2], line[3], line[4])
    end
    Counts.stats.lines = Counts.stats.lines + 1
end

------------------------------------------------------------------------
-- Wiring
------------------------------------------------------------------------
local function isBanker(kind)
    local types = Enum and Enum.PlayerInteractionType
    return types ~= nil and kind ~= nil and (kind == types.Banker or kind == types.AccountBanker)
end

local function bankOpened()
    Counts.bankOpen = true
    Counts.ScanBank()
end

local function bankClosed()
    Counts.bankOpen = false
end

ns:Listen("LOGIN", function()
    Counts.ScanBags()
end)
ns:On("BAG_UPDATE_DELAYED", function()
    Counts.ScanBags()
    Counts.ScanBank()
end)
ns:On("BANKFRAME_OPENED", bankOpened)
ns:On("BANKFRAME_CLOSED", bankClosed)
ns:On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(_, kind)
    if isBanker(kind) then bankOpened() end
end)
ns:On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(_, kind)
    if isBanker(kind) then bankClosed() end
end)
for _, event in ipairs({ "PLAYERBANKSLOTS_CHANGED", "BANK_TABS_CHANGED" }) do
    ns:On(event, function() Counts.ScanBank() end)
end
