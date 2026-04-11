------------------------------------------------------------------------
-- HexCD: ConfigGUI — Settings for Dispel/Kick tracker
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.ConfigGUI = {}

local GUI = HexCD.ConfigGUI
local Config = HexCD.Config
local Log = HexCD.DebugLog

local mainFrame = nil

------------------------------------------------------------------------
-- GUI Helpers
------------------------------------------------------------------------

local function CreateSectionHeader(parent, text, yOffset)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", 16, yOffset)
    h:SetText("|cFFFFCC00" .. text .. "|r")
    return h
end

local function CreateSettingsSlider(parent, label, min, max, step, configKey, yOffset)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(280, 50)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)

    local t = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("TOPLEFT", 0, 0)
    t:SetText(label)

    local slider = CreateFrame("Slider", "HexCD_" .. configKey, container, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", 0, -16)
    slider:SetWidth(200)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    slider:SetValue(Config:Get(configKey) or min)

    local v = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    v:SetPoint("LEFT", slider, "RIGHT", 8, 0)
    v:SetText(tostring(Config:Get(configKey) or min))

    slider:SetScript("OnValueChanged", function(self, value)
        value = math.floor(value / step + 0.5) * step
        Config:Set(configKey, value)
        v:SetText(tostring(value))
    end)
    return container
end

local function CreateSettingsCheckbox(parent, label, configKey, yOffset)
    local cb = CreateFrame("CheckButton", "HexCD_" .. configKey, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    t:SetText(label)
    cb:SetChecked(Config:Get(configKey) and true or false)
    cb:SetScript("OnClick", function(self) Config:Set(configKey, self:GetChecked() and true or false) end)
    return cb
end

local function CreateSettingsDropdown(parent, label, configKey, options, yOffset)
    local frame = CreateFrame("Frame", "HexCD_" .. configKey, parent, "UIDropDownMenuTemplate")
    frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    local t = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 20, 2)
    t:SetText(label)
    UIDropDownMenu_SetWidth(frame, 150)
    UIDropDownMenu_SetText(frame, Config:Get(configKey) or options[1])
    UIDropDownMenu_Initialize(frame, function(self, level)
        for _, opt in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = opt
            info.func = function()
                Config:Set(configKey, opt)
                UIDropDownMenu_SetText(frame, opt)
            end
            info.checked = (Config:Get(configKey) == opt)
            UIDropDownMenu_AddButton(info)
        end
    end)
    return frame
end

local function CreateSettingsEditBox(parent, label, defaultText, width, yOffset, xOffset)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(width + 20, 45)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", (xOffset or 0) + 16, yOffset)

    local t = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("TOPLEFT", 0, 0)
    t:SetText(label)

    local eb = CreateFrame("EditBox", nil, container, "BackdropTemplate")
    eb:SetSize(width, 24)
    eb:SetPoint("TOPLEFT", 0, -14)
    eb:SetAutoFocus(false)
    eb:SetFontObject(ChatFontNormal)
    eb:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    eb:SetBackdropColor(0, 0, 0, 0.8)
    eb:SetText(defaultText or "")
    eb:SetCursorPosition(0)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    container._editBox = eb
    return container
end

local function CreateAnchorToggle(parent, label, colorHex, yOffset, isUnlockedFn, toggleFn)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(280, 28)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    btn:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    btn.label:SetPoint("LEFT", btn, "LEFT", 8, 0)
    btn.status = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.status:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    btn:EnableMouse(true)
    btn:RegisterForClicks("AnyUp")

    local function UpdateVisual()
        local unlocked = isUnlockedFn()
        if unlocked then
            btn:SetBackdropColor(0.3, 0.25, 0.05, 0.9)
            btn:SetBackdropBorderColor(1.0, 0.8, 0.0, 0.9)
            btn.label:SetText("|cFF" .. colorHex .. label .. "|r")
            btn.status:SetText("|cFFFFCC00UNLOCKED|r")
        else
            btn:SetBackdropColor(0.1, 0.1, 0.12, 0.9)
            btn:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.7)
            btn.label:SetText("|cFF" .. colorHex .. label .. "|r")
            btn.status:SetText("|cFF666666locked|r")
        end
    end

    btn:SetScript("OnClick", function() toggleFn(); UpdateVisual() end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 1, 1, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(isUnlockedFn() and "Click to lock position" or "Click to unlock and drag")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self) UpdateVisual(); GameTooltip:Hide() end)
    btn._update = UpdateVisual
    UpdateVisual()
    return btn
end

------------------------------------------------------------------------
-- Rotation Controls (shared by Dispel + Kick tabs)
------------------------------------------------------------------------

local function CreateRotationControls(parent, yOffset, tracker, configPrefix, simulateFnName, colorHex)
    local y = yOffset

    CreateSectionHeader(parent, "Rotation", y)
    y = y - 22

    -- Build initial text from saved config: "Group1Names ; Group2Names"
    local function BuildNameStr()
        local parts = {}
        for gi = 1, 2 do
            local key = gi == 1 and (configPrefix .. "Rotation") or (configPrefix .. "Rotation2")
            local saved = Config:Get(key) or {}
            if #saved > 0 then
                local names = {}
                for _, r in ipairs(saved) do table.insert(names, r.name or r) end
                table.insert(parts, table.concat(names, ","))
            end
        end
        return table.concat(parts, " ; ")
    end

    local helpText = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    helpText:SetPoint("TOPLEFT", 16, y)
    helpText:SetText("|cFF888888Format: Group1Names ; Group2Names   (semicolon separates groups)|r")
    y = y - 16

    local namesBox = CreateSettingsEditBox(parent, "Names:", BuildNameStr(), 450, y)
    y = y - 50

    local function MakeBtn(label, width, xOff, onClick)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(width, 24)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, y)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    -- Parse "A,B,C ; D,E,F" into two group strings
    local function ParseGroups(text)
        local g1, g2 = "", ""
        local semicolonPos = text:find(";")
        if semicolonPos then
            g1 = text:sub(1, semicolonPos - 1):match("^%s*(.-)%s*$") or ""
            g2 = text:sub(semicolonPos + 1):match("^%s*(.-)%s*$") or ""
        else
            g1 = text:match("^%s*(.-)%s*$") or ""
        end
        return g1, g2
    end

    local function ApplyRotation()
        local text = namesBox._editBox:GetText()
        if text == "" then return end
        local g1, g2 = ParseGroups(text)
        Config:Set(configPrefix .. "Enabled", true)
        if g1 ~= "" then tracker:SetRotation(g1, 1) end
        if g2 ~= "" then
            tracker:SetRotation(g2, 2)
        end
    end

    -- Labels for each group's current rotation
    local rotLabel1 = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rotLabel1:SetJustifyH("LEFT")
    local rotLabel2 = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rotLabel2:SetJustifyH("LEFT")

    local simBtnContainer = CreateFrame("Frame", nil, parent)
    simBtnContainer:SetSize(560, 60)
    local simButtons = {}

    local function RebuildSimButtons()
        for _, btn in ipairs(simButtons) do
            if btn.Hide then btn:Hide() end
            if btn.SetParent then btn:SetParent(nil) end
        end
        wipe(simButtons)

        local totalHeight = 0
        for gi = 1, 2 do
            local names = tracker.GetRotationNames and tracker:GetRotationNames(gi) or {}
            local label = gi == 1 and rotLabel1 or rotLabel2
            if #names > 0 then
                local groupTag = gi > 1 and " (G2)" or ""
                label:SetText("|cFF" .. colorHex .. "Group " .. gi .. ":|r " .. table.concat(names, " > "))
                label:Show()

                -- Simulate buttons for this group
                local xOff = 16
                for _, name in ipairs(names) do
                    local btnW = math.max(60, #name * 7 + 12)
                    local btn = CreateFrame("Button", nil, simBtnContainer, "UIPanelButtonTemplate")
                    btn:SetSize(btnW, 20)
                    btn:SetPoint("TOPLEFT", simBtnContainer, "TOPLEFT", xOff, -totalHeight)
                    btn:SetText(name)
                    btn:SetScript("OnClick", function()
                        if tracker.SimulateCastFrom then
                            Config:Set(configPrefix .. "Enabled", true)
                            tracker:SimulateCastFrom(name)
                        end
                    end)
                    table.insert(simButtons, btn)
                    xOff = xOff + btnW + 3
                end
                totalHeight = totalHeight + 24
            else
                label:SetText("|cFF888888Group " .. gi .. ": not set|r")
                label:Show()
                totalHeight = totalHeight + 16
            end
        end
        simBtnContainer:SetHeight(math.max(totalHeight, 4))
        return totalHeight
    end

    -- Operational buttons
    MakeBtn("Set Rotation", 110, 16, function()
        ApplyRotation()
        RebuildSimButtons()
    end)
    MakeBtn("Broadcast All", 100, 132, function()
        if tracker.BroadcastRotation then
            tracker:BroadcastRotation(1)
            local g2names = tracker.GetRotationNames and tracker:GetRotationNames(2) or {}
            if #g2names > 0 then tracker:BroadcastRotation(2) end
        end
    end)
    y = y - 30

    rotLabel1:ClearAllPoints()
    rotLabel1:SetPoint("TOPLEFT", 16, y)
    y = y - 16
    rotLabel2:ClearAllPoints()
    rotLabel2:SetPoint("TOPLEFT", 16, y)
    y = y - 20

    -- Testing section
    CreateSectionHeader(parent, "Testing", y)
    y = y - 22

    local isDispel = (configPrefix == "dispel")
    local durBox = CreateSettingsEditBox(parent, "Duration (sec):", "15", 80, y)
    local countBox = CreateSettingsEditBox(parent, isDispel and "# Debuffs:" or "# Events:", "4", 60, y, 200)
    y = y - 50

    MakeBtn("Start Test", 90, 16, function()
        ApplyRotation()
        RebuildSimButtons()
        local dur = tonumber(durBox._editBox:GetText()) or 15
        local count = tonumber(countBox._editBox:GetText()) or 4
        tracker[simulateFnName](tracker, dur, count)
    end)
    y = y - 30

    simBtnContainer:ClearAllPoints()
    simBtnContainer:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    local simHeight = RebuildSimButtons()
    y = y - math.max(simHeight, 4) - 4

    return y
end

------------------------------------------------------------------------
-- Tab Content
------------------------------------------------------------------------

local function PopulateDispelTab(scrollChild)
    local DT = HexCD.DispelTracker
    if not DT then
        local msg = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        msg:SetPoint("CENTER", 0, 0)
        msg:SetText("Dispel Tracker module not loaded.")
        scrollChild:SetHeight(100)
        return
    end
    local y = 0
    CreateSectionHeader(scrollChild, "Dispel Tracker Settings", y)
    y = y - 25
    CreateSettingsCheckbox(scrollChild, "Enable Dispel Tracker", "dispelEnabled", y)
    y = y - 30
    CreateSettingsCheckbox(scrollChild, "Alert Sound (your turn)", "dispelAlertEnabled", y)
    y = y - 35
    CreateSettingsSlider(scrollChild, "Bar Width", 100, 400, 10, "dispelBarWidth", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Height", 14, 40, 2, "dispelBarHeight", y)
    y = y - 60
    y = CreateRotationControls(scrollChild, y, DT, "dispel", "SimulateDebuffs", "CC88FF")
    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
end

local function PopulateKickTab(scrollChild)
    local KT = HexCD.KickTracker
    if not KT then
        local msg = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
        msg:SetPoint("CENTER", 0, 0)
        msg:SetText("Kick Tracker module not loaded.")
        scrollChild:SetHeight(100)
        return
    end
    local y = 0
    CreateSectionHeader(scrollChild, "Kick Tracker Settings", y)
    y = y - 25
    CreateSettingsCheckbox(scrollChild, "Enable Kick Tracker", "kickEnabled", y)
    y = y - 30
    CreateSettingsCheckbox(scrollChild, "Alert Sound (your turn)", "kickAlertEnabled", y)
    y = y - 35
    CreateSettingsSlider(scrollChild, "Bar Width", 100, 400, 10, "kickBarWidth", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Height", 14, 40, 2, "kickBarHeight", y)
    y = y - 60
    y = CreateRotationControls(scrollChild, y, KT, "kick", "SimulateKicks", "88CCFF")
    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
end

------------------------------------------------------------------------
-- Party CD Tab
------------------------------------------------------------------------

local function PopulatePartyCDTab(scrollChild)
    local PCD = HexCD.PartyCDDisplay
    local CS = HexCD.CommSync
    local y = 0

    -- ── Header + Test ──
    CreateSectionHeader(scrollChild, "Party CD Tracker", y)

    -- Test / Clear button
    local testActive = false
    local testBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    testBtn:SetSize(80, 22)
    testBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 250, y)
    testBtn:SetText("Test")
    testBtn:SetScript("OnClick", function()
        if not CS then return end
        if testActive then
            CS:ClearSimulation()
            testBtn:SetText("Test")
            testActive = false
        else
            CS:SimulateParty()
            testBtn:SetText("Clear")
            testActive = true
        end
    end)

    y = y - 30

    -- ── Position ──
    CreateSectionHeader(scrollChild, "Position", y)
    y = y - 25

    -- Anchor side dropdown
    CreateSettingsDropdown(scrollChild, "Anchor To", "partyCDAnchorSide", {
        "RIGHT", "LEFT", "TOP", "BOTTOM"
    }, y)
    y = y - 55

    -- Offset X
    CreateSettingsSlider(scrollChild, "Offset X", -50, 50, 1, "partyCDOfsX", y)
    y = y - 55

    -- Offset Y
    CreateSettingsSlider(scrollChild, "Offset Y", -50, 50, 1, "partyCDOfsY", y)
    y = y - 55

    -- Growth direction
    CreateSettingsDropdown(scrollChild, "Growth Direction", "partyCDGrowth", {
        "RIGHT", "LEFT", "DOWN", "UP"
    }, y)
    y = y - 55

    -- ── Icons ──
    CreateSectionHeader(scrollChild, "Icons", y)
    y = y - 25

    CreateSettingsSlider(scrollChild, "Icon Size", 16, 40, 1, "partyCDIconSize", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Icon Padding", 0, 10, 1, "partyCDIconPadding", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Ready Opacity", 0.2, 1.0, 0.1, "partyCDReadyAlpha", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "On-CD Opacity", 0.2, 1.0, 0.1, "partyCDActiveAlpha", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Swipe Opacity", 0.0, 1.0, 0.1, "partyCDSwipeAlpha", y)
    y = y - 55

    CreateSettingsCheckbox(scrollChild, "Desaturate On Cooldown", "partyCDDesaturate", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Show Ready Glow", "partyCDShowGlow", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Show Cooldown Text", "partyCDShowText", y)
    y = y - 30

    -- ── Tracker Sub-Tabs + Spell Lists ──
    local DB = HexCD.SpellDB
    local trackers = {
        { category = "PERSONAL",      label = "Personal",  color = {1, 0.8, 0.25} },
        { category = "PARTY_RANGED",  label = "Ranged",    color = {0.25, 0.8, 0.25} },
        { category = "PARTY_STACKED", label = "Stacked",   color = {0.8, 0.53, 0.25} },
        { category = "HEALING",       label = "Healing",   color = {0.25, 0.53, 0.8} },
    }

    -- Class color map (WoW class colors)
    local CLASS_COLORS = {
        DEATHKNIGHT = "FFC41E3A", DEMONHUNTER = "FFA330C9", DRUID = "FFFF7C0A",
        EVOKER = "FF33937F", HUNTER = "FFAAD372", MAGE = "FF3FC7EB",
        MONK = "FF00FF98", PALADIN = "FFF48CBA", PRIEST = "FFFFFFFF",
        ROGUE = "FFFFF468", SHAMAN = "FF0070DD", WARLOCK = "FF8788EE",
        WARRIOR = "FFC69B6D",
    }

    -- Spell icon helper
    local function GetIcon(spellID)
        local icon = nil
        pcall(function()
            if C_Spell and C_Spell.GetSpellInfo then
                local info = C_Spell.GetSpellInfo(spellID)
                if info and info.iconID then icon = info.iconID end
            end
        end)
        if not icon then
            pcall(function()
                if GetSpellTexture then icon = GetSpellTexture(spellID) end
            end)
        end
        return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
    end

    CreateSectionHeader(scrollChild, "Spell Filters", y)
    y = y - 25

    -- Sub-tab buttons
    local activeSubTab = trackers[1].category
    local spellContainer = CreateFrame("Frame", nil, scrollChild)
    spellContainer:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, y - 28)
    spellContainer:SetSize(560, 400)

    local subTabBtns = {}
    local subTabXOfs = 16
    for i, t in ipairs(trackers) do
        local btn = CreateFrame("Button", nil, scrollChild, "BackdropTemplate")
        btn:SetSize(100, 22)
        btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", subTabXOfs, y)
        btn:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:EnableMouse(true)
        btn:RegisterForClicks("AnyUp")
        btn._label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn._label:SetPoint("CENTER")
        btn._label:SetText(t.label)
        btn._category = t.category
        btn._color = t.color
        subTabBtns[i] = btn
        subTabXOfs = subTabXOfs + 104
    end

    y = y - 28  -- space for sub-tab row

    local function RefreshSpellList()
        -- Clear old children
        for _, child in ipairs({ spellContainer:GetChildren() }) do child:Hide(); child:SetParent(nil) end
        for _, region in ipairs({ spellContainer:GetRegions() }) do region:Hide() end

        -- Update sub-tab visuals
        for _, btn in ipairs(subTabBtns) do
            if btn._category == activeSubTab then
                btn:SetBackdropColor(btn._color[1] * 0.3, btn._color[2] * 0.3, btn._color[3] * 0.3, 0.9)
                btn:SetBackdropBorderColor(btn._color[1], btn._color[2], btn._color[3], 1)
            else
                btn:SetBackdropColor(0.08, 0.08, 0.12, 0.7)
                btn:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
            end
        end

        if not DB then return end

        local spells = DB:GetByCategory(activeSubTab)
        local sorted = {}
        for id, info in pairs(spells) do
            table.insert(sorted, { id = id, name = info.name, class = info.class, immune = info.immune })
        end
        table.sort(sorted, function(a, b)
            if a.class ~= b.class then return a.class < b.class end
            return a.name < b.name
        end)

        -- Enable All / Disable All buttons
        local enableAllBtn = CreateFrame("Button", nil, spellContainer, "UIPanelButtonTemplate")
        enableAllBtn:SetSize(75, 20)
        enableAllBtn:SetPoint("TOPLEFT", spellContainer, "TOPLEFT", 16, 0)
        enableAllBtn:SetText("All On")
        enableAllBtn:SetScript("OnClick", function()
            for _, spell in ipairs(sorted) do
                Config:Set("partyCDSpell_" .. spell.id, true)
            end
            RefreshSpellList()
        end)

        local disableAllBtn = CreateFrame("Button", nil, spellContainer, "UIPanelButtonTemplate")
        disableAllBtn:SetSize(75, 20)
        disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 4, 0)
        disableAllBtn:SetText("All Off")
        disableAllBtn:SetScript("OnClick", function()
            for _, spell in ipairs(sorted) do
                Config:Set("partyCDSpell_" .. spell.id, false)
            end
            RefreshSpellList()
        end)

        local sy = -26
        local lastClass = nil
        local col = 0  -- 0 = left column, 1 = right column
        local ROW_HEIGHT = 24
        local COL_WIDTH = 260

        for _, spell in ipairs(sorted) do
            -- Class separator
            if spell.class ~= lastClass then
                if col == 1 then sy = sy - ROW_HEIGHT; col = 0 end  -- new row if mid-column
                lastClass = spell.class
                local classColor = CLASS_COLORS[spell.class] or "FFAAAAAA"
                local className = spell.class:sub(1, 1) .. spell.class:sub(2):lower()
                -- Normalize class names
                if spell.class == "DEATHKNIGHT" then className = "Death Knight"
                elseif spell.class == "DEMONHUNTER" then className = "Demon Hunter"
                end

                local header = spellContainer:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                header:SetPoint("TOPLEFT", spellContainer, "TOPLEFT", 16, sy)
                header:SetText("|c" .. classColor .. className .. "|r")
                sy = sy - 18
                col = 0
            end

            local configKey = "partyCDSpell_" .. spell.id
            if Config:Get(configKey) == nil then Config:Set(configKey, true) end

            local xOfs = 24 + col * COL_WIDTH

            -- Checkbox
            local cb = CreateFrame("CheckButton", nil, spellContainer, "InterfaceOptionsCheckButtonTemplate")
            cb:SetPoint("TOPLEFT", spellContainer, "TOPLEFT", xOfs, sy)
            cb:SetChecked(Config:Get(configKey) and true or false)
            cb:SetScript("OnClick", function(self)
                Config:Set(configKey, self:GetChecked() and true or false)
            end)

            -- Spell icon
            local iconTex = spellContainer:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(18, 18)
            iconTex:SetPoint("LEFT", cb, "RIGHT", 0, 0)
            iconTex:SetTexture(GetIcon(spell.id))
            iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            -- Spell name
            local label = spellContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            label:SetPoint("LEFT", iconTex, "RIGHT", 4, 0)
            local classColor = CLASS_COLORS[spell.class] or "FFAAAAAA"
            local suffix = spell.immune and " |cFFFF4444(immune)|r" or ""
            label:SetText("|c" .. classColor .. spell.name .. "|r" .. suffix)

            col = col + 1
            if col >= 2 then
                col = 0
                sy = sy - ROW_HEIGHT
            end
        end
        if col == 1 then sy = sy - ROW_HEIGHT end

        spellContainer:SetHeight(math.max(1, math.abs(sy) + 10))
    end

    for _, btn in ipairs(subTabBtns) do
        btn:SetScript("OnClick", function()
            activeSubTab = btn._category
            RefreshSpellList()
        end)
    end

    RefreshSpellList()

    -- Account for spellContainer height in scrollChild
    y = y - 500  -- generous estimate; container handles its own height
    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
end

------------------------------------------------------------------------
-- Main Frame
------------------------------------------------------------------------

local function CreateMainFrame()
    local f = CreateFrame("Frame", "HexCDMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(620, 500)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("|cFF00CCFFHexCD|r")

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Anchor toggles header
    local DT = HexCD.DispelTracker
    local KT = HexCD.KickTracker
    local anchorToggles = {}
    local headerY = -40

    local lockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    lockBtn:SetSize(80, 22)
    lockBtn:SetPoint("TOPLEFT", 16, headerY)
    lockBtn:SetText("|cFF00FF00Lock All|r")

    local unlockBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    unlockBtn:SetSize(90, 22)
    unlockBtn:SetPoint("LEFT", lockBtn, "RIGHT", 4, 0)
    unlockBtn:SetText("|cFFFFCC00Unlock All|r")

    headerY = headerY - 28
    if DT then
        local t = CreateAnchorToggle(f, "Dispel Tracker", "CC88FF", headerY, function() return DT:IsUnlocked() end, function() DT:ToggleLock() end)
        t:SetSize(270, 26)
        anchorToggles[#anchorToggles+1] = t
    end
    if KT then
        local t = CreateAnchorToggle(f, "Kick Tracker", "88CCFF", headerY, function() return KT:IsUnlocked() end, function() KT:ToggleLock() end)
        t:ClearAllPoints()
        t:SetSize(270, 26)
        t:SetPoint("TOPLEFT", f, "TOPLEFT", 300, headerY)
        anchorToggles[#anchorToggles+1] = t
    end

    lockBtn:SetScript("OnClick", function()
        if DT and DT:IsUnlocked() then DT:Lock() end
        if KT and KT:IsUnlocked() then KT:Lock() end
        for _, t in ipairs(anchorToggles) do t._update() end
    end)
    unlockBtn:SetScript("OnClick", function()
        if DT and not DT:IsUnlocked() then DT:Unlock() end
        if KT and not KT:IsUnlocked() then KT:Unlock() end
        for _, t in ipairs(anchorToggles) do t._update() end
    end)

    headerY = headerY - 32

    -- Tab buttons
    local activeTab = "dispel"

    local function CreateTab(label, tabKey, xOff)
        local btn = CreateFrame("Button", nil, f, "BackdropTemplate")
        btn:SetSize(110, 24)
        btn:SetPoint("TOPLEFT", f, "TOPLEFT", xOff, headerY)
        btn:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:EnableMouse(true)
        btn:RegisterForClicks("AnyUp")
        btn._label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn._label:SetPoint("CENTER")
        btn._label:SetText(label)
        btn._tabKey = tabKey
        return btn
    end

    local dispelTabBtn = CreateTab("|cFFCC88FFDispel|r", "dispel", 16)
    local kickTabBtn = CreateTab("|cFF88CCFFKick|r", "kick", 130)
    local partyCDTabBtn = CreateTab("|cFF88FFCCParty CD|r", "partycd", 244)
    local settingsTabBtn = CreateTab("|cFFAAAAAASettings|r", "settings", 358)

    local tabBtns = { dispelTabBtn, kickTabBtn, partyCDTabBtn, settingsTabBtn }
    local tabColors = {
        dispel = { active = {0.15, 0.05, 0.2, 0.9}, border = {0.8, 0.5, 1.0, 1.0}, label = "|cFFCC88FFDispel|r", dim = "|cFF888888Dispel|r" },
        kick = { active = {0.05, 0.1, 0.2, 0.9}, border = {0.5, 0.8, 1.0, 1.0}, label = "|cFF88CCFFKick|r", dim = "|cFF888888Kick|r" },
        partycd = { active = {0.05, 0.15, 0.1, 0.9}, border = {0.5, 1.0, 0.8, 1.0}, label = "|cFF88FFCCParty CD|r", dim = "|cFF888888Party CD|r" },
        settings = { active = {0.1, 0.1, 0.1, 0.9}, border = {0.6, 0.6, 0.6, 1.0}, label = "|cFFAAAAAASettings|r", dim = "|cFF888888Settings|r" },
    }

    local function UpdateTabVisuals()
        for _, btn in ipairs(tabBtns) do
            local c = tabColors[btn._tabKey]
            if btn._tabKey == activeTab then
                btn:SetBackdropColor(unpack(c.active))
                btn:SetBackdropBorderColor(unpack(c.border))
                btn._label:SetText(c.label)
            else
                btn:SetBackdropColor(0.08, 0.08, 0.12, 0.7)
                btn:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
                btn._label:SetText(c.dim)
            end
        end
    end

    headerY = headerY - 30

    -- Scroll frame
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, headerY)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(scrollFrame:GetWidth() - 20)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    f._scrollChild = scrollChild
    f._scrollFrame = scrollFrame

    local function RefreshContent()
        for _, child in ipairs({ scrollChild:GetChildren() }) do child:Hide(); child:SetParent(nil) end
        for _, region in ipairs({ scrollChild:GetRegions() }) do region:Hide() end

        if activeTab == "dispel" then
            PopulateDispelTab(scrollChild)
        elseif activeTab == "kick" then
            PopulateKickTab(scrollChild)
        elseif activeTab == "partycd" then
            PopulatePartyCDTab(scrollChild)
        elseif activeTab == "settings" then
            local y = 0

            -- TTS Settings
            CreateSectionHeader(scrollChild, "TTS (Text-to-Speech)", y)
            y = y - 25

            -- Voice dropdown
            local voiceNames = { "" }  -- empty = auto-detect
            local voices = HexCD.Util and HexCD.Util.GetTTSVoices and HexCD.Util.GetTTSVoices() or {}
            for _, v in ipairs(voices) do
                table.insert(voiceNames, v.name)
            end
            CreateSettingsDropdown(scrollChild, "TTS Voice (empty = auto)", "ttsVoiceName", voiceNames, y)
            y = y - 55

            CreateSettingsSlider(scrollChild, "Speech Rate", 1, 10, 1, "ttsRate", y)
            y = y - 55

            CreateSettingsSlider(scrollChild, "Volume", 0, 100, 5, "ttsVolume", y)
            y = y - 55

            -- Alert text config
            CreateSectionHeader(scrollChild, "Alert Text", y)
            y = y - 25

            local dispelBox = CreateSettingsEditBox(scrollChild, "Dispel alert:", Config:Get("dispelAlertText") or "Dispel", 200, y)
            y = y - 50

            local kickBox = CreateSettingsEditBox(scrollChild, "Kick alert:", Config:Get("kickAlertText") or "Kick", 200, y)
            y = y - 50

            local function MakeBtn(label, width, xOff, onClick)
                local btn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
                btn:SetSize(width, 24)
                btn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", xOff, y)
                btn:SetText(label)
                btn:SetScript("OnClick", onClick)
                return btn
            end

            MakeBtn("Save & Test", 100, 16, function()
                Config:Set("dispelAlertText", dispelBox._editBox:GetText())
                Config:Set("kickAlertText", kickBox._editBox:GetText())
                if HexCD.Util and HexCD.Util.SpeakTTS then
                    HexCD.Util.SpeakTTS(dispelBox._editBox:GetText())
                end
            end)
            y = y - 35

            -- Debug
            CreateSectionHeader(scrollChild, "Debug", y)
            y = y - 25
            CreateSettingsDropdown(scrollChild, "Log Level", "logLevel", { "OFF", "ERRORS", "INFO", "DEBUG", "TRACE" }, y)
            y = y - 65
            scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
        end
        UpdateTabVisuals()
    end

    for _, btn in ipairs(tabBtns) do
        btn:SetScript("OnClick", function()
            activeTab = btn._tabKey
            RefreshContent()
        end)
    end

    f._refresh = RefreshContent
    UpdateTabVisuals()
    return f
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function GUI:Init()
    Log:Log("DEBUG", "ConfigGUI initialized")
end

function GUI:Open()
    if not mainFrame then
        mainFrame = CreateMainFrame()
    end
    mainFrame._refresh()
    mainFrame:Show()
end

function GUI:Toggle()
    if mainFrame and mainFrame:IsShown() then
        mainFrame:Hide()
    else
        self:Open()
    end
end

function GUI:OpenSettings()
    self:Open()
end

function GUI:RefreshContent()
    if mainFrame and mainFrame._refresh then
        mainFrame._refresh()
    end
end
