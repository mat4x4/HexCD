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

local function CreateSettingsCheckbox(parent, label, configKey, yOffset, onChange)
    local cb = CreateFrame("CheckButton", "HexCD_" .. configKey, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    t:SetText(label)
    cb:SetChecked(Config:Get(configKey) and true or false)
    cb:SetScript("OnClick", function(self)
        local v = self:GetChecked() and true or false
        Config:Set(configKey, v)
        if onChange then onChange(v) end
    end)
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

------------------------------------------------------------------------
-- Per-Tracker TTS/Alert Section (used by Kicks + Dispels panels)
------------------------------------------------------------------------

local function BuildTrackerAlertSection(scrollChild, trackerSlug, y)
    local globalEnabled = Config:Get("hexcd_tts_enabled")
    local dimSuffix = globalEnabled and "" or "  |cFF666666(TTS disabled globally)|r"

    CreateSectionHeader(scrollChild, "Alerts" .. dimSuffix, y)
    y = y - 25

    local localKey = "hexcd_" .. trackerSlug .. "_ttsEnabled"
    local localCb = CreateSettingsCheckbox(scrollChild, "TTS alert when your turn", localKey, y)
    if not globalEnabled then localCb:Disable() end
    y = y - 25

    local alertBox = CreateSettingsEditBox(scrollChild, "Alert text:",
        Config:Get("hexcd_" .. trackerSlug .. "_alertText") or "", 200, y)
    y = y - 50

    local voiceNames = { "" }
    local voices = HexCD.Util and HexCD.Util.GetTTSVoices and HexCD.Util.GetTTSVoices() or {}
    for _, v in ipairs(voices) do table.insert(voiceNames, v.name) end
    CreateSettingsDropdown(scrollChild, "Voice override (empty = global)", "hexcd_" .. trackerSlug .. "_ttsVoice", voiceNames, y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Rate override (0 = global)", 0, 10, 1, "hexcd_" .. trackerSlug .. "_ttsRate", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Volume override (0 = global)", 0, 100, 5, "hexcd_" .. trackerSlug .. "_ttsVolume", y)
    y = y - 55

    local saveBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
    saveBtn:SetSize(100, 24)
    saveBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 16, y)
    saveBtn:SetText("Save & Test")
    saveBtn:SetScript("OnClick", function()
        Config:Set("hexcd_" .. trackerSlug .. "_alertText", alertBox._editBox:GetText())
        if HexCD.Util and HexCD.Util.SpeakTTS and globalEnabled then
            HexCD.Util.SpeakTTS(alertBox._editBox:GetText())
        end
    end)
    y = y - 35

    return y
end

------------------------------------------------------------------------
-- Dispel Tab
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
    CreateAnchorToggle(scrollChild, "Dispel Tracker Position", "40CCCC", y,
        function() return DT:IsUnlocked() end, function() DT:ToggleLock() end)
    y = y - 35
    CreateSettingsSlider(scrollChild, "Bar Width", 100, 400, 10, "dispelBarWidth", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Height", 14, 40, 2, "dispelBarHeight", y)
    y = y - 60
    y = CreateRotationControls(scrollChild, y, DT, "dispel", "SimulateDebuffs", "CC88FF")
    y = BuildTrackerAlertSection(scrollChild, "dispels", y)
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
    CreateAnchorToggle(scrollChild, "Kick Tracker Position", "CC4040", y,
        function() return KT:IsUnlocked() end, function() KT:ToggleLock() end)
    y = y - 35
    CreateSettingsSlider(scrollChild, "Bar Width", 100, 400, 10, "kickBarWidth", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Height", 14, 40, 2, "kickBarHeight", y)
    y = y - 60
    y = CreateRotationControls(scrollChild, y, KT, "kick", "SimulateKicks", "88CCFF")
    y = BuildTrackerAlertSection(scrollChild, "kicks", y)
    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
end

------------------------------------------------------------------------
-- Personal CD Tab
------------------------------------------------------------------------

local function PopulatePartyCDTab(scrollChild)
    local PCD = HexCD.PartyCDDisplay
    local CS = HexCD.CommSync
    local y = 0

    -- ── Header + Test ──
    CreateSectionHeader(scrollChild, "Personal Defensives", y)

    -- Enable toggle for the entire Personal Defensives display.
    -- Hides unit-frame icons immediately when unchecked.
    CreateSettingsCheckbox(scrollChild, "Show Personal Defensives on unit frames",
        "hexcd_personal_enabled", y - 22,
        function() if PCD and PCD.RefreshVisibility then PCD:RefreshVisibility() end end)

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

    y = y - 55  -- room for the section header + enable checkbox row

    -- ── Position ──
    CreateSectionHeader(scrollChild, "Position", y)
    y = y - 25

    CreateSettingsDropdown(scrollChild, "Anchor Side", "hexcd_personal_anchorSide", {
        "RIGHT", "LEFT", "TOP", "BOTTOM"
    }, y)
    y = y - 55

    CreateSettingsDropdown(scrollChild, "Growth Direction", "hexcd_personal_growth", {
        "RIGHT", "LEFT", "DOWN", "UP"
    }, y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Offset X", -100, 100, 1, "hexcd_personal_ofsX", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Offset Y", -100, 100, 1, "hexcd_personal_ofsY", y)
    y = y - 55

    -- ── Layout ──
    CreateSectionHeader(scrollChild, "Layout", y)
    y = y - 25

    CreateSettingsSlider(scrollChild, "Icon Size", 16, 48, 1, "hexcd_personal_iconSize", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Icon Padding", 0, 10, 1, "hexcd_personal_iconPadding", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Icons Per Row", 1, 10, 1, "hexcd_personal_maxIconsPerRow", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "Max Rows", 1, 3, 1, "hexcd_personal_maxRows", y)
    y = y - 55

    -- ── Appearance ──
    CreateSectionHeader(scrollChild, "Appearance", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Desaturate On Cooldown", "hexcd_personal_desaturate", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Show Cooldown Text", "hexcd_personal_showText", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Show Ready Glow", "hexcd_personal_showGlow", y)
    y = y - 25

    CreateSettingsCheckbox(scrollChild, "Hide When Ready", "hexcd_personal_hideReady", y)
    y = y - 30

    CreateSettingsSlider(scrollChild, "Ready Opacity", 0.2, 1.0, 0.1, "hexcd_personal_readyAlpha", y)
    y = y - 55

    CreateSettingsSlider(scrollChild, "On-CD Opacity", 0.2, 1.0, 0.1, "hexcd_personal_activeCDAlpha", y)
    y = y - 55

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

    -- Non-secure close button (UIPanelCloseButton is secure and blocks during combat)
    local close = CreateFrame("Button", nil, f)
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
    close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
    close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
    close:SetScript("OnClick", function() f:Hide() end)

    -- Escape to close (works during combat — non-secure)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f:EnableKeyboard(true)

    -- Header spacing (lock/unlock moved into per-tracker panels)
    local headerY = -38

    -- ================================================================
    -- TOP-LEVEL TABS: Trackers | Spell Filters | Settings
    -- ================================================================
    local activeTopTab = "trackers"
    local activeTracker = "personal"  -- sidebar selection within Trackers tab

    local function CreateTopTab(label, tabKey, xOff)
        local btn = CreateFrame("Button", nil, f, "BackdropTemplate")
        btn:SetSize(140, 24)
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

    local trackersTabBtn = CreateTopTab("|cFF88FFCCTrackers|r", "trackers", 16)
    local filtersTabBtn = CreateTopTab("|cFFFFCC88Spell Filters|r", "filters", 170)
    local settingsTabBtn = CreateTopTab("|cFFAAAAAASettings|r", "settings", 330)

    local topTabBtns = { trackersTabBtn, filtersTabBtn, settingsTabBtn }
    local topTabColors = {
        trackers = { active = {0.05, 0.15, 0.1, 0.9}, border = {0.5, 1.0, 0.8, 1.0}, label = "|cFF88FFCCTrackers|r", dim = "|cFF888888Trackers|r" },
        filters  = { active = {0.15, 0.1, 0.05, 0.9}, border = {1.0, 0.8, 0.5, 1.0}, label = "|cFFFFCC88Spell Filters|r", dim = "|cFF888888Spell Filters|r" },
        settings = { active = {0.1, 0.1, 0.1, 0.9}, border = {0.6, 0.6, 0.6, 1.0}, label = "|cFFAAAAAASettings|r", dim = "|cFF888888Settings|r" },
    }

    local function UpdateTopTabVisuals()
        for _, btn in ipairs(topTabBtns) do
            local c = topTabColors[btn._tabKey]
            if btn._tabKey == activeTopTab then
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

    -- ================================================================
    -- SIDEBAR (visible only on Trackers + Spell Filters tabs)
    -- ================================================================
    local SIDEBAR_WIDTH = 90
    local SIDEBAR_TRACKERS = {
        { key = "personal",  label = "Personal Def", color = {1, 0.8, 0.25} },
        { key = "external",  label = "External Def", color = {0.25, 0.8, 0.25} },
        { key = "utility",   label = "Utility",     color = {0.53, 0.67, 0.8} },
        { key = "healing",   label = "Healing",     color = {0.25, 0.53, 0.8} },
        { key = "offensive", label = "Offensive",   color = {1.0, 0.53, 0.25} },
        { key = "kicks",     label = "Kicks",       color = {0.8, 0.25, 0.25} },
        { key = "cc",        label = "CC",           color = {0.8, 0.25, 0.8} },
        { key = "dispels",   label = "Dispels",     color = {0.25, 0.8, 0.8} },
    }

    -- Map sidebar key → SpellDB category
    local SIDEBAR_TO_CATEGORY = {
        personal = "PERSONAL", external = "EXTERNAL_DEFENSIVE",
        utility = "UTILITY", healing = "HEALING", offensive = "OFFENSIVE",
        kicks = "KICK", cc = "CC", dispels = "DISPEL",
    }

    local sidebarFrame = CreateFrame("Frame", nil, f)
    sidebarFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, headerY)
    sidebarFrame:SetSize(SIDEBAR_WIDTH, 400)
    local sidebarBtns = {}

    for i, info in ipairs(SIDEBAR_TRACKERS) do
        local btn = CreateFrame("Button", nil, sidebarFrame, "BackdropTemplate")
        btn:SetSize(SIDEBAR_WIDTH - 4, 22)
        btn:SetPoint("TOPLEFT", sidebarFrame, "TOPLEFT", 0, -(i - 1) * 24)
        btn:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        btn:EnableMouse(true)
        btn:RegisterForClicks("AnyUp")
        btn._label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        btn._label:SetPoint("LEFT", 6, 0)
        btn._label:SetText(info.label)
        btn._key = info.key
        btn._color = info.color

        -- Accent bar on left edge
        local accent = btn:CreateTexture(nil, "OVERLAY")
        accent:SetWidth(2)
        accent:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        btn._accent = accent

        sidebarBtns[#sidebarBtns + 1] = btn
    end

    -- Lock All / Unlock All buttons below sidebar
    local sidebarBottomY = -(#SIDEBAR_TRACKERS) * 24 - 10
    local unlockAllBtn = CreateFrame("Button", nil, sidebarFrame, "BackdropTemplate")
    unlockAllBtn:SetSize(SIDEBAR_WIDTH - 4, 20)
    unlockAllBtn:SetPoint("TOPLEFT", sidebarFrame, "TOPLEFT", 0, sidebarBottomY)
    unlockAllBtn:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    unlockAllBtn:SetBackdropColor(0.15, 0.12, 0.02, 0.9)
    unlockAllBtn:SetBackdropBorderColor(1.0, 0.8, 0.0, 0.7)
    unlockAllBtn:EnableMouse(true)
    unlockAllBtn:RegisterForClicks("AnyUp")
    local unlockLbl = unlockAllBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    unlockLbl:SetPoint("CENTER")
    unlockLbl:SetText("|cFFFFCC00Unlock All|r")
    unlockAllBtn:SetScript("OnClick", function()
        local DT = HexCD.DispelTracker
        local KT = HexCD.KickTracker
        local PCD = HexCD.PartyCDDisplay
        if DT then DT:Unlock() end
        if KT then KT:Unlock() end
        if PCD then PCD:Unlock() end
    end)

    local lockAllBtn = CreateFrame("Button", nil, sidebarFrame, "BackdropTemplate")
    lockAllBtn:SetSize(SIDEBAR_WIDTH - 4, 20)
    lockAllBtn:SetPoint("TOPLEFT", sidebarFrame, "TOPLEFT", 0, sidebarBottomY - 22)
    lockAllBtn:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    lockAllBtn:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
    lockAllBtn:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.7)
    lockAllBtn:EnableMouse(true)
    lockAllBtn:RegisterForClicks("AnyUp")
    local lockLbl = lockAllBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lockLbl:SetPoint("CENTER")
    lockLbl:SetText("|cFF888888Lock All|r")
    lockAllBtn:SetScript("OnClick", function()
        local DT = HexCD.DispelTracker
        local KT = HexCD.KickTracker
        local PCD = HexCD.PartyCDDisplay
        if DT then DT:Lock() end
        if KT then KT:Lock() end
        if PCD then PCD:Lock() end
    end)

    local function UpdateSidebarVisuals()
        for _, btn in ipairs(sidebarBtns) do
            if btn._key == activeTracker then
                btn:SetBackdropColor(0.15, 0.15, 0.15, 0.9)
                btn:SetBackdropBorderColor(btn._color[1], btn._color[2], btn._color[3], 0.8)
                btn._accent:SetColorTexture(btn._color[1], btn._color[2], btn._color[3], 1)
                btn._label:SetTextColor(btn._color[1], btn._color[2], btn._color[3])
            else
                btn:SetBackdropColor(0.06, 0.06, 0.08, 0.7)
                btn:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.5)
                btn._accent:SetColorTexture(0, 0, 0, 0)
                btn._label:SetTextColor(0.5, 0.5, 0.5)
            end
        end
    end

    -- ================================================================
    -- CONTENT AREA (right of sidebar, or full width for Settings)
    -- ================================================================
    local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    f._scrollChild = scrollChild
    f._scrollFrame = scrollFrame

    local function PositionScrollFrame(hasSidebar)
        scrollFrame:ClearAllPoints()
        if hasSidebar then
            scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10 + SIDEBAR_WIDTH + 4, headerY)
        else
            scrollFrame:SetPoint("TOPLEFT", f, "TOPLEFT", 10, headerY)
        end
        scrollFrame:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 10)
        scrollChild:SetWidth(scrollFrame:GetWidth() - 20)
        scrollChild:SetHeight(1)
        scrollFrame:SetScrollChild(scrollChild)
    end

    -- ================================================================
    -- POPULATE FUNCTIONS
    -- ================================================================

    local function PopulateTrackerContent(scrollChild)
        -- Clear
        for _, child in ipairs({ scrollChild:GetChildren() }) do child:Hide(); child:SetParent(nil) end
        for _, region in ipairs({ scrollChild:GetRegions() }) do region:Hide() end

        -- Map tracker key to panel type
        local panelC = { kicks = true, dispels = true }  -- rotation overlay trackers

        if activeTracker == "personal" then
            -- For now, reuse existing PopulatePartyCDTab which handles Personal settings
            PopulatePartyCDTab(scrollChild)
        elseif panelC[activeTracker] then
            -- Rotation overlay trackers (Kicks, Dispels)
            if activeTracker == "kicks" then
                PopulateKickTab(scrollChild)
            else
                PopulateDispelTab(scrollChild)
            end
        else
            -- Floating bar trackers (Panel B)
            local info = nil
            for _, s in ipairs(SIDEBAR_TRACKERS) do
                if s.key == activeTracker then info = s; break end
            end
            local label = info and info.label or activeTracker
            local category = SIDEBAR_TO_CATEGORY[activeTracker] or "PERSONAL"
            local slug = activeTracker  -- config key prefix: hexcd_{slug}_*
            local PCD = HexCD.PartyCDDisplay

            local y = 0
            CreateSectionHeader(scrollChild, label, y)
            y = y - 25

            -- Enable toggle per bar. Hides this bar immediately when unchecked.
            -- Key format matches Config.lua defaults: hexcd_<slug>_enabled.
            CreateSettingsCheckbox(scrollChild, "Show this bar",
                "hexcd_" .. slug .. "_enabled", y,
                function() if PCD and PCD.RefreshVisibility then PCD:RefreshVisibility() end end)
            y = y - 28

            -- Lock/Unlock (color matches sidebar)
            if PCD then
                local c = info and info.color or {0.25, 0.8, 0.25}
                local colorHex = string.format("%02x%02x%02x", c[1]*255, c[2]*255, c[3]*255)
                CreateAnchorToggle(scrollChild, label .. " Position", colorHex, y,
                    function() return PCD:IsUnlocked(category) end,
                    function() PCD:ToggleLock(category) end)
                y = y - 35
            end

            -- Layout
            CreateSectionHeader(scrollChild, "Layout", y)
            y = y - 25

            CreateSettingsSlider(scrollChild, "Icon Size", 16, 48, 1, "hexcd_" .. slug .. "_iconSize", y)
            y = y - 55

            CreateSettingsSlider(scrollChild, "Icon Padding", 0, 10, 1, "hexcd_" .. slug .. "_iconPadding", y)
            y = y - 55

            CreateSettingsSlider(scrollChild, "Max Icons Per Player", 1, 10, 1, "hexcd_" .. slug .. "_maxIcons", y)
            y = y - 55

            CreateSettingsSlider(scrollChild, "Name Width", 30, 120, 5, "hexcd_" .. slug .. "_nameWidth", y)
            y = y - 55

            CreateSettingsCheckbox(scrollChild, "Hide Bar Title", "hexcd_" .. slug .. "_hideTitle", y)
            y = y - 30

            -- Appearance
            CreateSectionHeader(scrollChild, "Appearance", y)
            y = y - 25

            CreateSettingsCheckbox(scrollChild, "Desaturate On Cooldown", "hexcd_" .. slug .. "_desaturate", y)
            y = y - 25

            CreateSettingsCheckbox(scrollChild, "Show Cooldown Text", "hexcd_" .. slug .. "_showText", y)
            y = y - 25

            CreateSettingsCheckbox(scrollChild, "Show Tooltips", "hexcd_" .. slug .. "_showTooltips", y)
            y = y - 25

            CreateSettingsCheckbox(scrollChild, "Hide When Ready", "hexcd_" .. slug .. "_hideReady", y)
            y = y - 30

            CreateSettingsSlider(scrollChild, "Bar Opacity", 0.0, 1.0, 0.05, "hexcd_" .. slug .. "_barAlpha", y)
            y = y - 55

            scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
        end
    end

    local function PopulateSpellFiltersContent(scrollChild)
        -- Clear
        for _, child in ipairs({ scrollChild:GetChildren() }) do child:Hide(); child:SetParent(nil) end
        for _, region in ipairs({ scrollChild:GetRegions() }) do region:Hide() end

        -- Reuse existing spell filter from PopulatePartyCDTab's sub-tab system
        -- but scoped to the selected sidebar category
        local category = SIDEBAR_TO_CATEGORY[activeTracker]
        if not category then category = "PERSONAL" end

        local DB = HexCD.SpellDB
        local y = 0
        CreateSectionHeader(scrollChild, (DB.CATEGORY_LABELS and DB.CATEGORY_LABELS[category]) or category, y)
        y = y - 25

        -- Class color map
        local CLASS_COLORS = {
            DEATHKNIGHT = {0.77, 0.12, 0.23}, DEMONHUNTER = {0.64, 0.19, 0.79},
            DRUID = {1, 0.49, 0.04}, EVOKER = {0.2, 0.58, 0.5},
            HUNTER = {0.67, 0.83, 0.45}, MAGE = {0.25, 0.78, 0.92},
            MONK = {0, 1, 0.6}, PALADIN = {0.96, 0.55, 0.73},
            PRIEST = {1, 1, 1}, ROGUE = {1, 0.96, 0.41},
            SHAMAN = {0, 0.44, 0.87}, WARLOCK = {0.53, 0.53, 0.93},
            WARRIOR = {0.78, 0.61, 0.43},
        }
        local CLASS_ORDER = {
            "DEATHKNIGHT", "DEMONHUNTER", "DRUID", "EVOKER", "HUNTER",
            "MAGE", "MONK", "PALADIN", "PRIEST", "ROGUE",
            "SHAMAN", "WARLOCK", "WARRIOR",
        }
        local CLASS_NAMES = {
            DEATHKNIGHT = "Death Knight", DEMONHUNTER = "Demon Hunter", DRUID = "Druid",
            EVOKER = "Evoker", HUNTER = "Hunter", MAGE = "Mage", MONK = "Monk",
            PALADIN = "Paladin", PRIEST = "Priest", ROGUE = "Rogue",
            SHAMAN = "Shaman", WARLOCK = "Warlock", WARRIOR = "Warrior",
        }

        local spells = DB and DB:GetByCategory(category) or {}
        -- Collect all IDs for Enable/Disable All
        local allIDs = {}
        local byClass = {}
        for id, info in pairs(spells) do
            allIDs[#allIDs + 1] = id
            byClass[info.class] = byClass[info.class] or {}
            table.insert(byClass[info.class], { id = id, info = info })
        end

        -- Enable All / Disable All buttons
        local enableBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
        enableBtn:SetSize(80, 20)
        enableBtn:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 16, y)
        enableBtn:SetText("Enable All")
        enableBtn:SetScript("OnClick", function()
            for _, sid in ipairs(allIDs) do Config:Set("partyCDSpell_" .. sid, true) end
            PopulateSpellFiltersContent(scrollChild)
        end)

        local disableBtn = CreateFrame("Button", nil, scrollChild, "UIPanelButtonTemplate")
        disableBtn:SetSize(80, 20)
        disableBtn:SetPoint("LEFT", enableBtn, "RIGHT", 6, 0)
        disableBtn:SetText("Disable All")
        disableBtn:SetScript("OnClick", function()
            for _, sid in ipairs(allIDs) do Config:Set("partyCDSpell_" .. sid, false) end
            PopulateSpellFiltersContent(scrollChild)
        end)
        y = y - 28

        -- Render class groups
        for _, cls in ipairs(CLASS_ORDER) do
            local group = byClass[cls]
            if group and #group > 0 then
                table.sort(group, function(a, b) return a.info.name < b.info.name end)
                local cc = CLASS_COLORS[cls] or {0.7, 0.7, 0.7}
                local clsLabel = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                clsLabel:SetPoint("TOPLEFT", 16, y)
                clsLabel:SetText(string.format("|cFF%02x%02x%02x%s|r", cc[1]*255, cc[2]*255, cc[3]*255, CLASS_NAMES[cls] or cls))
                y = y - 18

                local col = 0
                for _, spell in ipairs(group) do
                    local configKey = "partyCDSpell_" .. spell.id
                    local xOff = col == 0 and 24 or 290
                    local cb = CreateSettingsCheckbox(scrollChild, spell.info.name, configKey, y)
                    cb:ClearAllPoints()
                    cb:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", xOff + 20, y)
                    cb:SetChecked(Config:Get(configKey) ~= false)
                    cb:SetScript("OnClick", function(self)
                        Config:Set(configKey, self:GetChecked() and true or false)
                    end)
                    -- Spell icon
                    local icon = scrollChild:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(16, 16)
                    icon:SetPoint("RIGHT", cb, "LEFT", -2, 0)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    pcall(function()
                        local tex = nil
                        if C_Spell and C_Spell.GetSpellTexture then
                            tex = C_Spell.GetSpellTexture(spell.id)
                        elseif GetSpellTexture then
                            tex = GetSpellTexture(spell.id)
                        end
                        icon:SetTexture(tex or "Interface\\Icons\\INV_Misc_QuestionMark")
                    end)
                    col = col + 1
                    if col >= 2 then col = 0; y = y - 22 end
                end
                if col ~= 0 then y = y - 22 end
                y = y - 6
            end
        end

        scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
    end

    local function PopulateSettingsContent(scrollChild)
        -- Clear
        for _, child in ipairs({ scrollChild:GetChildren() }) do child:Hide(); child:SetParent(nil) end
        for _, region in ipairs({ scrollChild:GetRegions() }) do region:Hide() end

        local y = 0

        -- Detection Layers
        CreateSectionHeader(scrollChild, "Detection Layers", y)
        y = y - 25
        CreateSettingsCheckbox(scrollChild, "Aura Detection (UNIT_AURA + evidence)", "hexcd_layer_aura", y)
        y = y - 22
        CreateSettingsCheckbox(scrollChild, "Direct SpellID (UNIT_SPELLCAST_SUCCEEDED)", "hexcd_layer_direct", y)
        y = y - 22
        CreateSettingsCheckbox(scrollChild, "Taint Laundering (StatusBar unwrap)", "hexcd_layer_launder", y)
        y = y - 22
        CreateSettingsCheckbox(scrollChild, "Addon Comms (CDCAST sync)", "hexcd_layer_comms", y)
        y = y - 30

        -- TTS Global Settings
        CreateSectionHeader(scrollChild, "TTS (Text-to-Speech) — Global", y)
        y = y - 25

        CreateSettingsCheckbox(scrollChild, "Enable TTS alerts (master toggle)", "hexcd_tts_enabled", y)
        y = y - 25

        local note = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        note:SetPoint("TOPLEFT", 40, y)
        note:SetText("|cFF888888Per-tracker alert text and voice overrides are in each tracker's settings.|r")
        y = y - 20

        -- Default voice/rate/volume
        local voiceNames = { "" }
        local voices = HexCD.Util and HexCD.Util.GetTTSVoices and HexCD.Util.GetTTSVoices() or {}
        for _, v in ipairs(voices) do table.insert(voiceNames, v.name) end
        CreateSettingsDropdown(scrollChild, "Default Voice (empty = auto)", "ttsVoiceName", voiceNames, y)
        y = y - 55
        CreateSettingsSlider(scrollChild, "Default Rate", 1, 10, 1, "ttsRate", y)
        y = y - 55
        CreateSettingsSlider(scrollChild, "Default Volume", 0, 100, 5, "ttsVolume", y)
        y = y - 55

        -- Debug
        CreateSectionHeader(scrollChild, "Debug", y)
        y = y - 25
        CreateSettingsDropdown(scrollChild, "Log Level", "logLevel", { "OFF", "ERRORS", "INFO", "DEBUG", "TRACE" }, y)
        y = y - 55
        CreateSettingsCheckbox(scrollChild, "Auto-open log after encounters", "autoOpenLog", y)
        y = y - 30

        scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
    end

    -- ================================================================
    -- REFRESH: wire everything together
    -- ================================================================

    local function RefreshContent()
        local hasSidebar = (activeTopTab == "trackers" or activeTopTab == "filters")
        sidebarFrame:SetShown(hasSidebar)
        PositionScrollFrame(hasSidebar)

        if activeTopTab == "trackers" then
            PopulateTrackerContent(scrollChild)
        elseif activeTopTab == "filters" then
            PopulateSpellFiltersContent(scrollChild)
        elseif activeTopTab == "settings" then
            PopulateSettingsContent(scrollChild)
        end

        UpdateTopTabVisuals()
        UpdateSidebarVisuals()
    end

    for _, btn in ipairs(topTabBtns) do
        btn:SetScript("OnClick", function()
            activeTopTab = btn._tabKey
            RefreshContent()
        end)
    end

    for _, btn in ipairs(sidebarBtns) do
        btn:SetScript("OnClick", function()
            activeTracker = btn._key
            RefreshContent()
        end)
    end

    f._refresh = RefreshContent
    UpdateTopTabVisuals()
    UpdateSidebarVisuals()
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
