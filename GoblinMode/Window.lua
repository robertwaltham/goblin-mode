local addonName, addon = ...

local coinIcon = "Interface\\Icons\\INV_Misc_Coin_01"
local rowHeight, visibleRows = 26, 12
local gold = { 0.96, 0.78, 0.41 }
local muted = { 0.65, 0.71, 0.67 }
local window
local sortKey, ascending = "name", true
local columns = {
    { key = "name", label = "Item", x = 0, width = 277, justify = "LEFT" },
    { key = "count", label = "Count", x = 277, width = 63, justify = "RIGHT" },
    { key = "value", label = "Est. value", x = 340, width = 158, justify = "RIGHT" },
}

local function fill(frame, layer, r, g, b, a)
    local texture = frame:CreateTexture(nil, layer)
    texture:SetAllPoints()
    texture:SetColorTexture(r, g, b, a or 1)
    return texture
end

local function label(frame, font, text, color)
    local result = frame:CreateFontString(nil, "OVERLAY", font)
    result:SetText(text)
    if color then
        result:SetTextColor(unpack(color))
    end
    return result
end

local function money(value, size)
    return C_CurrencyInfo.GetCoinTextureString(value, size or 12)
end

local function showRowTooltip(button)
    local row = button.item
    if not row then
        return
    end
    local quality = ITEM_QUALITY_COLORS[row.quality]
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine(row.name, quality and quality.r or 1, quality and quality.g or 1, quality and quality.b or 1)
    GameTooltip:AddDoubleLine("Total count", BreakUpLargeNumbers(row.count), 1, 1, 1, 1, 1, 1)

    if row.usesVendorPrice then
        GameTooltip:AddDoubleLine("Vendor sell price per item", money(row.unitPrice), unpack(muted))
    elseif row.unitPrice then
        GameTooltip:AddDoubleLine("Auctionator per item", money(row.unitPrice), unpack(muted))
        local api = addon.GetAuctionatorAPI()
        local age = api and api.GetAuctionAgeByItemID and api.GetAuctionAgeByItemID(addonName, row.id)
        if age then
            local observed = string.format("Observed %d %s ago", age, age == 1 and "day" or "days")
            GameTooltip:AddLine(age == 0 and "Observed today" or observed, unpack(muted))
        end
    else
        GameTooltip:AddLine("No auction or vendor sell price", unpack(muted))
    end

    local owners = {}
    for _, owner in pairs(row.owners) do
        owners[#owners + 1] = owner
    end
    table.sort(owners, function(a, b) return a.name < b.name end)

    for _, owner in ipairs(owners) do
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(owner.name, unpack(gold))
        for _, location in ipairs(addon.locations) do
            if owner[location] then
                GameTooltip:AddDoubleLine(addon.locationNames[location], BreakUpLargeNumbers(owner[location]), 0.76, 0.82, 0.78, 1, 1, 1)
            end
        end
    end
    GameTooltip:Show()
end

local function renderRows()
    local offset = math.floor(window.scrollbar:GetValue() + 0.5)
    for index, button in ipairs(window.rows) do
        local row = window.filtered[offset + index]
        local ownsTooltip = GameTooltip:IsOwned(button)
        button.item = row
        button:SetShown(row ~= nil)
        if row then
            local quality = ITEM_QUALITY_COLORS[row.quality]
            button.icon:SetTexture(row.icon)
            button.name:SetText(row.name)
            button.name:SetTextColor(quality and quality.r or 1, quality and quality.g or 1, quality and quality.b or 1)
            button.count:SetText(BreakUpLargeNumbers(row.count))
            button.value:SetText(row.value and money(row.value) or "No price")
            button.value:SetTextColor(unpack(row.value and gold or muted))
        end
        if ownsTooltip then
            if row then
                showRowTooltip(button)
            else
                GameTooltip:Hide()
            end
        end
    end
end

local function showFilteredRows(resetScroll)
    local query = window.search:GetText():lower():match("^%s*(.-)%s*$")
    local filtered = {}
    for _, row in ipairs(window.items) do
        if row.name:lower():find(query, 1, true) then
            filtered[#filtered + 1] = row
        end
    end
    table.sort(filtered, function(a, b)
        local first, second = a[sortKey], b[sortKey]
        if first == second then
            if a.name == b.name then
                return a.id < b.id
            end
            return a.name < b.name
        elseif first == nil or second == nil then
            return second == nil
        elseif ascending then
            return first < second
        end
        return first > second
    end)
    window.filtered = filtered

    for _, column in ipairs(columns) do
        local active = column.key == sortKey
        column.text:SetText(column.label .. (active and (ascending and "  ^" or "  v") or ""))
        column.text:SetTextColor(unpack(active and gold or muted))
    end

    local maxOffset = math.max(0, #filtered - visibleRows)
    local offset = resetScroll and 0 or math.min(window.scrollbar:GetValue(), maxOffset)
    window.scrollbar:SetMinMaxValues(0, math.max(1, maxOffset))
    window.scrollbar:SetValue(offset)
    window.scrollbar:SetShown(maxOffset > 0)
    renderRows()

    if #window.items == 0 then
        window.empty:SetText(window.emptyMessage)
    else
        window.empty:SetText("No matching items.")
    end
    window.empty:SetShown(#filtered == 0)
end

function addon.RefreshWindow()
    local items, stats = addon.GetHoldings()
    window.items = items
    window.emptyMessage = "No tracked items in the scanned storage."
    if stats.loading > 0 then
        window.emptyMessage = "Loading item data..."
    elseif stats.unavailable > 0 then
        window.emptyMessage = "Item data is unavailable."
    end
    window.total:SetText(stats.value and money(stats.value, 14) or "Unavailable")

    local priceStatus = ""
    if stats.unpriced > 0 then
        priceStatus = string.format("%d without a price", stats.unpriced)
    elseif stats.vendorPriced == #items and stats.vendorPriced > 0 then
        priceStatus = "Vendor sell prices"
    elseif stats.vendorPriced > 0 then
        priceStatus = "Auctionator + vendor sell prices"
    elseif stats.value then
        priceStatus = "Auctionator cached prices"
    end
    window.priceStatus:SetText(priceStatus)

    local coverage = string.format("%d %s tracked", stats.characters, stats.characters == 1 and "character" or "characters")
    if stats.missingInventories > 0 then
        local scans = stats.missingInventories == 1 and "bag scan" or "bag scans"
        coverage = coverage .. string.format("  |  %d %s needed", stats.missingInventories, scans)
    end
    local gaps = {}
    if stats.missingBanks > 0 then
        gaps[#gaps + 1] = string.format("%d %s to visit", stats.missingBanks, stats.missingBanks == 1 and "bank" or "banks")
    end
    if stats.missingMail > 0 then
        gaps[#gaps + 1] = string.format("%d %s to open", stats.missingMail, stats.missingMail == 1 and "mailbox" or "mailboxes")
    end
    if stats.partialMail > 0 then
        gaps[#gaps + 1] = string.format("%d incomplete %s", stats.partialMail, stats.partialMail == 1 and "inbox" or "inboxes")
    end
    if stats.loading > 0 then
        gaps[#gaps + 1] = "Loading item data"
    elseif stats.unavailable > 0 then
        gaps[#gaps + 1] = "Some item data is unavailable"
    end
    window.coverage:SetText(coverage)
    window.scanStatus:SetText(table.concat(gaps, "  |  "))
    showFilteredRows(false)
end

local function createWindow()
    window = CreateFrame("Frame", "GoblinModeWindow", UIParent)
    addon.window = window
    window:SetSize(550, 502)
    window:SetPoint("CENTER", 28, 0)
    window:SetFrameStrata("DIALOG")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:Hide()
    tinsert(UISpecialFrames, window:GetName())

    fill(window, "BACKGROUND", 0.36, 0.30, 0.18)
    local interior = window:CreateTexture(nil, "BORDER")
    interior:SetPoint("TOPLEFT", 1, -1)
    interior:SetPoint("BOTTOMRIGHT", -1, 1)
    interior:SetColorTexture(0.06, 0.085, 0.074, 0.98)

    local header = CreateFrame("Frame", nil, window)
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(69)
    fill(header, "BACKGROUND", 0.11, 0.16, 0.12)
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() window:StartMoving() end)
    header:SetScript("OnDragStop", function() window:StopMovingOrSizing() end)

    local icon = header:CreateTexture(nil, "ARTWORK")
    icon:SetSize(36, 36)
    icon:SetPoint("LEFT", 17, 0)
    icon:SetTexture(coinIcon)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local title = label(header, "GameFontNormalHuge", "Goblin Mode", gold)
    title:SetPoint("TOPLEFT", 65, -16)
    local subtitle = label(header, "GameFontHighlightSmall", "Reagents and consumables", muted)
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)

    local close = CreateFrame("Button", nil, header, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() window:Hide() end)

    local totalLabel = label(header, "GameFontHighlightSmall", "Estimated stash value", muted)
    totalLabel:SetPoint("TOPRIGHT", -42, -13)
    window.total = label(header, "GameFontHighlightLarge", "", gold)
    window.total:SetPoint("TOPRIGHT", totalLabel, "BOTTOMRIGHT", 0, -3)
    window.priceStatus = label(header, "GameFontHighlightSmall", "", muted)
    window.priceStatus:SetPoint("TOPRIGHT", window.total, "BOTTOMRIGHT", 0, -4)

    window.search = CreateFrame("EditBox", nil, window, "SearchBoxTemplate")
    window.search:SetPoint("TOPLEFT", 20, -81)
    window.search:SetSize(255, 21)
    window.search:SetAutoFocus(false)
    window.search:SetMaxLetters(100)
    window.search:HookScript("OnTextChanged", function() showFilteredRows(true) end)

    local columnBar = CreateFrame("Frame", nil, window)
    columnBar:SetPoint("TOPLEFT", 16, -113)
    columnBar:SetSize(502, 24)
    fill(columnBar, "BACKGROUND", 0.15, 0.19, 0.15)
    for _, column in ipairs(columns) do
        local key = column.key
        local button = CreateFrame("Button", nil, columnBar)
        button:SetPoint("TOPLEFT", column.x, 0)
        button:SetSize(column.width, 24)
        local highlight = fill(button, "HIGHLIGHT", 1, 1, 1, 0.07)
        button:SetHighlightTexture(highlight)
        column.text = label(button, "GameFontHighlightSmall", column.label, muted)
        column.text:SetPoint(column.justify, column.justify == "LEFT" and 9 or -10, 0)
        button:SetScript("OnClick", function()
            if sortKey == key then
                ascending = not ascending
            else
                sortKey, ascending = key, key == "name"
            end
            showFilteredRows(true)
        end)
    end

    local list = CreateFrame("Frame", nil, window)
    list:SetPoint("TOPLEFT", columnBar, "BOTTOMLEFT")
    list:SetSize(502, visibleRows * rowHeight)
    list:EnableMouseWheel(true)
    window.rows = {}
    for index = 1, visibleRows do
        local button = CreateFrame("Button", nil, list)
        button:SetPoint("TOPLEFT", 0, -(index - 1) * rowHeight)
        button:SetSize(502, rowHeight)
        local shade = index % 2 == 0 and 0.086 or 0.067
        fill(button, "BACKGROUND", shade, shade + 0.022, shade + 0.01)
        local highlight = fill(button, "HIGHLIGHT", 0.61, 0.75, 0.51, 0.18)
        button:SetHighlightTexture(highlight)

        button.icon = button:CreateTexture(nil, "ARTWORK")
        button.icon:SetSize(20, 20)
        button.icon:SetPoint("LEFT", 8, 0)
        button.icon:SetTexCoord(0.06, 0.94, 0.06, 0.94)
        button.name = label(button, "GameFontHighlight")
        button.name:SetPoint("LEFT", 36, 0)
        button.name:SetWidth(234)
        button.name:SetJustifyH("LEFT")
        button.name:SetMaxLines(1)
        button.count = label(button, "GameFontHighlight")
        button.count:SetPoint("RIGHT", button, "LEFT", 330, 0)
        button.value = label(button, "GameFontHighlight")
        button.value:SetPoint("RIGHT", -14, 0)

        button:SetScript("OnEnter", showRowTooltip)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
        button:Hide()
        window.rows[index] = button
    end

    local scrollbar = CreateFrame("Slider", nil, window)
    window.scrollbar = scrollbar
    scrollbar:SetPoint("TOPLEFT", list, "TOPRIGHT", 6, 0)
    scrollbar:SetSize(10, visibleRows * rowHeight)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetMinMaxValues(0, 1)
    scrollbar:SetValueStep(1)
    scrollbar:SetObeyStepOnDrag(true)
    scrollbar:SetValue(0)
    fill(scrollbar, "BACKGROUND", 0.12, 0.15, 0.12)
    local thumb = scrollbar:CreateTexture(nil, "ARTWORK")
    thumb:SetSize(8, 25)
    thumb:SetColorTexture(0.49, 0.55, 0.39, 1)
    scrollbar:SetThumbTexture(thumb)
    scrollbar:SetScript("OnValueChanged", renderRows)

    local function scroll(_, delta)
        if scrollbar:IsShown() then
            scrollbar:SetValue(scrollbar:GetValue() - delta * 3)
        end
    end
    list:SetScript("OnMouseWheel", scroll)
    scrollbar:EnableMouseWheel(true)
    scrollbar:SetScript("OnMouseWheel", scroll)

    window.empty = label(list, "GameFontHighlight", "", muted)
    window.empty:SetPoint("CENTER")
    window.coverage = label(window, "GameFontHighlightSmall", "", gold)
    window.coverage:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 1, -11)
    window.scanStatus = label(window, "GameFontHighlightSmall", "", muted)
    window.scanStatus:SetPoint("TOPLEFT", window.coverage, "BOTTOMLEFT", 0, -5)

    window:SetScript("OnShow", addon.RefreshWindow)
    window:SetScript("OnHide", function()
        window.search:ClearFocus()
        for _, button in ipairs(window.rows) do
            if GameTooltip:IsOwned(button) then
                GameTooltip:Hide()
                break
            end
        end
    end)
end

local function toggleWindow()
    if not window then
        createWindow()
    end
    window:SetShown(not window:IsShown())
end

function addon.CreateMinimapButton()
    local button = CreateFrame("Button", "GoblinModeMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    button:RegisterForClicks("LeftButtonUp")
    button:RegisterForDrag("RightButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetSize(20, 20)
    background:SetPoint("CENTER")

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(coinIcon)
    icon:SetSize(19, 19)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("TOPLEFT", -1, 1)

    local function position()
        local angle = addon.db.minimapAngle or math.rad(225)
        button:ClearAllPoints()
        button:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * (Minimap:GetWidth() / 2 + 5),
            math.sin(angle) * (Minimap:GetHeight() / 2 + 5))
    end
    button:SetScript("OnClick", toggleWindow)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Goblin Mode", unpack(gold))
        GameTooltip:AddLine("Click to open. Right-drag to move.", unpack(muted))
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            if mx and my then
                local x, y = GetCursorPosition()
                local scale = Minimap:GetEffectiveScale()
                addon.db.minimapAngle = math.atan2(y / scale - my, x / scale - mx)
                position()
            end
        end)
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    Minimap:HookScript("OnSizeChanged", position)
    position()

    SLASH_GOBLINMODE1 = "/goblinmode"
    SlashCmdList.GOBLINMODE = toggleWindow
end
