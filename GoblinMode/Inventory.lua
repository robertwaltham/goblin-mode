local addonName, addon = ...

local bankType = Enum.BankType.Character
local itemClass = Enum.ItemClass
local itemQuality = Enum.ItemQuality
local bindOnEquip = Enum.ItemBind.OnEquip
local interaction = Enum.PlayerInteractionType
local backpack = Enum.BagIndex.Backpack
local lastBag = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS
local itemData, requestedItems = {}, {}
local mailItemRequests = {}
local character, bankOpen, mailOpen
local refreshPending, mailRetryPending

addon.locations = { "inventory", "bank", "mail" }
addon.locationNames = { inventory = "Inventory", bank = "Bank", mail = "Mail" }

local function addCount(items, id, count)
    items[id] = (items[id] or 0) + count
end

local function isRareOrEpic(quality)
    return quality == itemQuality.Rare or quality == itemQuality.Epic
end

local function isSoulboundBagItem(info, bagID, slot)
    if not info.isBound then
        return false
    end
    return not C_Item.IsItemBindToAccount(info.hyperlink or info.itemID)
        and not C_Item.IsBoundToAccountUntilEquip(ItemLocation:CreateFromBagAndSlot(bagID, slot))
end

local function scanBag(snapshot, bagID, requireSlots)
    local slots = C_Container.GetContainerNumSlots(bagID)
    if not slots or (requireSlots and slots == 0) then
        return false
    end

    for slot = 1, slots do
        local info = C_Container.GetContainerItemInfo(bagID, slot)
        if info and info.itemID and info.stackCount and info.stackCount > 0 then
            if not isSoulboundBagItem(info, bagID, slot) then
                addCount(snapshot.items, info.itemID, info.stackCount)
                if info.isBound == false and (not info.quality or info.quality < 0 or isRareOrEpic(info.quality)) then
                    addCount(snapshot.unboundItems, info.itemID, info.stackCount)
                end
            end
        elseif info or C_Container.GetContainerItemID(bagID, slot) then
            return false
        end
    end
    return true
end

local function scanInventory()
    local snapshot = { items = {}, unboundItems = {} }
    for bagID = backpack, lastBag do
        if not scanBag(snapshot, bagID, bagID == backpack) then
            return
        end
    end
    character.inventory = snapshot
end

local function scanBank()
    if not (bankOpen or (BankFrame and BankFrame:IsShown())) or not C_Bank.CanViewBank(bankType) then
        return
    end

    -- Forever exposes personal bank storage as container IDs, including the main bank.
    local tabs = C_Bank.FetchPurchasedBankTabIDs(bankType)
    if not tabs or #tabs == 0 or #tabs ~= C_Bank.FetchNumPurchasedBankTabs(bankType) then
        return
    end

    local snapshot = { items = {}, unboundItems = {} }
    for index, bagID in ipairs(tabs) do
        if not scanBag(snapshot, bagID, index == 1) then
            return
        end
    end
    character.bank = snapshot
end

local function isMailOpen()
    return mailOpen or (MailFrame and MailFrame:IsShown())
end

local function getAttachmentBinding(message, slot)
    local tooltip = C_TooltipInfo.GetInboxItem(message, slot)
    if not tooltip or tooltip.type ~= Enum.TooltipDataType.Item or not tooltip.lines or #tooltip.lines == 0 then
        return nil
    end
    local binding = false
    for _, line in ipairs(tooltip.lines) do
        if line.type == Enum.TooltipDataLineType.ItemBinding then
            if line.leftText == ITEM_SOULBOUND then
                return ITEM_SOULBOUND
            elseif line.leftText == ITEM_BIND_ON_EQUIP then
                binding = ITEM_BIND_ON_EQUIP
            end
        end
    end
    return binding
end

local function scanMail()
    local loaded, total = GetInboxNumItems()
    if not loaded then
        return
    end

    local now = GetServerTime()
    local messages = {}
    local incomplete = total and loaded < total
    for message = 1, loaded do
        local _, _, _, _, _, _, daysLeft = GetInboxHeaderInfo(message)
        local items, unboundItems = {}, {}
        for slot = 1, ATTACHMENTS_MAX_RECEIVE do
            if HasInboxItem(message, slot) then
                local name, id, _, count, _, _, isCurrency = GetInboxItem(message, slot)
                if not isCurrency then
                    if id and count and count > 0 then
                        local binding = name and getAttachmentBinding(message, slot)
                        if binding == nil then
                            incomplete = true
                            if mailItemRequests[id] == nil then
                                mailItemRequests[id] = true
                                C_Item.RequestLoadItemDataByID(id)
                            end
                        elseif binding ~= ITEM_SOULBOUND then
                            addCount(items, id, count)
                            if binding == ITEM_BIND_ON_EQUIP then
                                addCount(unboundItems, id, count)
                            end
                        end
                    else
                        incomplete = true
                    end
                end
            end
        end
        if next(items) then
            messages[#messages + 1] = {
                expires = daysLeft and (now + daysLeft * 86400),
                items = items,
                unboundItems = unboundItems,
            }
        end
    end
    character.mail = { messages = messages, incomplete = incomplete, bindingChecked = true }
end

local function positivePrice(price)
    if type(price) == "number" and price > 0 and price < math.huge then
        return price
    end
end

local function getTrackedItem(id)
    local data = itemData[id]
    if data ~= nil then
        return data
    end

    local name, _, quality, _, _, _, _, _, _, icon, sellPrice, classID, _, bindType, _, _, isReagent = C_Item.GetItemInfo(id)
    if not name then
        if not requestedItems[id] then
            requestedItems[id] = true
            C_Item.RequestLoadItemDataByID(id)
        end
        return
    end

    data = false
    local isBoE = isRareOrEpic(quality) and bindType == bindOnEquip
    if isBoE or isReagent or classID == itemClass.Tradegoods or classID == itemClass.Reagent
        or classID == itemClass.Consumable then
        data = { name = name, icon = icon, quality = quality, vendorSellPrice = positivePrice(sellPrice), isBoE = isBoE }
    end
    itemData[id] = data
    return data
end

function addon.GetAuctionatorAPI()
    return Auctionator and Auctionator.API and Auctionator.API.v1
end

function addon.GetHoldings()
    local rows, byID, unresolvedItems = {}, {}, {}
    local stats = { characters = {}, unpriced = 0, vendorPriced = 0, loading = 0, unavailable = 0 }
    local now = GetServerTime()

    local function addLocation(snapshot, key, name, location)
        for id, count in pairs(snapshot.items) do
            local data = getTrackedItem(id)
            -- Older snapshots cannot identify individual unbound BoE copies.
            if data and data.isBoE then
                count = snapshot.unboundItems and snapshot.unboundItems[id]
            end
            if data and count then
                local row = byID[id]
                if not row then
                    row = { id = id, name = data.name, icon = data.icon, quality = data.quality, count = 0, owners = {} }
                    byID[id] = row
                end
                local owner = row.owners[key]
                if not owner then
                    owner = { name = name }
                    row.owners[key] = owner
                end
                owner[location] = (owner[location] or 0) + count
                row.count = row.count + count
            elseif data == nil then
                unresolvedItems[id] = true
            end
        end
    end

    for key, record in pairs(addon.db.characters) do
        if record.money ~= nil then
            stats.cash = (stats.cash or 0) + record.money
        end
        local name = record.name
        local inventory = record.inventory and record.inventory.items and record.inventory
        local bank = record.bank and record.bank.items and record.bank
        local mail = record.mail and record.mail.bindingChecked and record.mail
        stats.characters[#stats.characters + 1] = {
            name = name,
            bagsScanned = inventory ~= nil,
            bankScanned = bank ~= nil,
            mailScanned = mail and true or false,
            mailIncomplete = mail and mail.incomplete,
            balanceRecorded = record.money ~= nil,
        }
        if inventory then
            addLocation(inventory, key, name, "inventory")
        end
        if bank then
            addLocation(bank, key, name, "bank")
        end
        if mail then
            for _, message in ipairs(mail.messages) do
                if not message.expires or message.expires > now then
                    addLocation(message, key, name, "mail")
                end
            end
        end
    end

    local api = addon.GetAuctionatorAPI()
    local hasAuctionPrice = api and type(api.GetAuctionPriceByItemID) == "function"
    for id, row in pairs(byID) do
        local vendorSellPrice = itemData[id].vendorSellPrice
        local price = hasAuctionPrice and positivePrice(api.GetAuctionPriceByItemID(addonName, id))
        if not price and vendorSellPrice then
            price = vendorSellPrice
            row.usesVendorPrice = true
            stats.vendorPriced = stats.vendorPriced + 1
        end
        if price then
            row.unitPrice = price
            row.value = price * row.count
            stats.value = (stats.value or 0) + row.value
        else
            stats.unpriced = stats.unpriced + 1
        end
        rows[#rows + 1] = row
    end
    for id in pairs(unresolvedItems) do
        if requestedItems[id] == "failed" then
            stats.unavailable = stats.unavailable + 1
        else
            stats.loading = stats.loading + 1
        end
    end
    if stats.cash or stats.value then
        stats.total = (stats.cash or 0) + (stats.value or 0)
    end
    return rows, stats
end

local function scheduleRefresh()
    if refreshPending or not addon.window or not addon.window:IsShown() then
        return
    end
    refreshPending = true
    C_Timer.After(0, function()
        refreshPending = false
        if addon.window:IsShown() then
            addon.RefreshWindow()
        end
    end)
end

local function retryMailScan()
    if mailRetryPending then
        return
    end
    mailRetryPending = true
    C_Timer.After(0, function()
        mailRetryPending = false
        if isMailOpen() then
            scanMail()
            scheduleRefresh()
        end
    end)
end

local function initialize()
    GoblinModeDB = GoblinModeDB or {}
    GoblinModeDB.characters = GoblinModeDB.characters or {}
    addon.db = GoblinModeDB

    local name, realm = UnitFullName("player")
    realm = realm and realm ~= "" and realm or GetRealmName()
    local key = UnitGUID("player")
    character = addon.db.characters[key] or {}
    character.name = realm and realm ~= "" and (name .. " - " .. realm) or name
    character.money = GetMoney()
    addon.db.characters[key] = character

    scanInventory()
    addon.CreateMinimapButton()

    local api = addon.GetAuctionatorAPI()
    if api and api.RegisterForDBUpdate then
        api.RegisterForDBUpdate(addonName, scheduleRefresh)
    end
end

local events = CreateFrame("Frame")
for _, event in ipairs({
    "PLAYER_LOGIN", "PLAYER_LOGOUT", "PLAYER_MONEY", "BAG_UPDATE_DELAYED", "BANK_TABS_CHANGED",
    "PLAYERBANKSLOTS_CHANGED", "BAG_CONTAINER_UPDATE", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "MAIL_SHOW", "MAIL_CLOSED",
    "MAIL_INBOX_UPDATE", "ITEM_CHANGED", "ITEM_DATA_LOAD_RESULT",
}) do
    events:RegisterEvent(event)
end

events:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "PLAYER_LOGIN" then
        initialize()
    elseif not character then
        return
    elseif event == "PLAYER_MONEY" then
        character.money = GetMoney()
    elseif event == "BAG_UPDATE_DELAYED" or event == "ITEM_CHANGED" or event == "PLAYER_LOGOUT" then
        scanInventory()
        scanBank()
    elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
        if arg1 ~= interaction.Banker and arg1 ~= interaction.CharacterBanker then
            return
        end
        bankOpen = event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW"
        if bankOpen then
            C_Timer.After(0, function()
                scanBank()
                scheduleRefresh()
            end)
        end
    elseif event == "BANK_TABS_CHANGED" or event == "PLAYERBANKSLOTS_CHANGED" or event == "BAG_CONTAINER_UPDATE" then
        scanBank()
    elseif event == "MAIL_SHOW" then
        mailOpen = true
    elseif event == "MAIL_CLOSED" then
        mailOpen = false
        mailItemRequests = {}
    elseif event == "MAIL_INBOX_UPDATE" and isMailOpen() then
        scanMail()
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        if mailItemRequests[arg1] then
            mailItemRequests[arg1] = false
            if arg2 then
                retryMailScan()
            end
        end
        if not requestedItems[arg1] then
            return
        end
        if arg2 then
            requestedItems[arg1] = nil
        else
            requestedItems[arg1] = "failed"
        end
    end
    scheduleRefresh()
end)
