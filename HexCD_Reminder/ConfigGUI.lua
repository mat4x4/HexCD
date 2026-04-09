------------------------------------------------------------------------
-- HexCD_Reminder: Main GUI
-- Plan browser with test controls + integrated settings panel
-- /hexcd opens this directly
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.ConfigGUI = {}

local GUI = HexCDReminder.ConfigGUI
local Config = HexCDReminder.Config
local Engine = HexCDReminder.TimerEngine
local Bars = HexCDReminder.TimerBars
local TTS = HexCDReminder.TTS
local Log = HexCDReminder.DebugLog
local Util = HexCDReminder.Util

local mainFrame = nil
local testSpeed = 1       -- current test speed multiplier
local testRunning = false

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local DIFFICULTY_NAMES = {
    [1] = "LFR", [2] = "Flex", [3] = "Normal", [4] = "Heroic", [5] = "Mythic",
}

local function DifficultyName(diff)
    return DIFFICULTY_NAMES[diff] or ("D" .. (diff or "?"))
end

local function CountCDs(plan, playerClass, playerSpec)
    if not plan or not plan.healerAssignments then return 0, 0 end
    local total = 0
    local mine = 0
    local playerName = UnitName("player")
    for _, h in ipairs(plan.healerAssignments) do
        local count = #(h.assignments or {})
        total = total + count
        if h.playerName and h.playerName ~= "" then
            if h.playerName == playerName then
                mine = mine + count
            end
        elseif playerClass and h.className == playerClass and h.specName == playerSpec then
            mine = mine + count
        end
    end
    return total, mine
end

------------------------------------------------------------------------
-- Speed Control Buttons
------------------------------------------------------------------------

local function CreateSpeedButton(parent, label, speed, x, y)
    local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    btn:SetSize(50, 24)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    btn:SetText(label)
    btn:SetScript("OnClick", function()
        testSpeed = speed
        if parent._speedButtons then
            for _, sb in ipairs(parent._speedButtons) do
                if sb._speed == speed then
                    sb:SetNormalFontObject("GameFontHighlight")
                else
                    sb:SetNormalFontObject("GameFontNormal")
                end
            end
        end
    end)
    btn._speed = speed
    return btn
end

------------------------------------------------------------------------
-- Dungeon Plan -> Test Plan Adapter
------------------------------------------------------------------------

local function DungeonPlanToTestPlan(dp)
    local allAssignments = {}
    local allDamageEvents = {}
    local cumulativeTime = 0

    for _, section in ipairs(dp.sections or {}) do
        for _, a in ipairs(section.assignments or {}) do
            table.insert(allAssignments, {
                timeSec = cumulativeTime + a.timeSec,
                abilityGameID = a.abilityGameID,
                abilityName = a.abilityName,
                rationale = string.format("[%s] %s", section.label or "?", a.rationale or ""),
            })
        end
        for _, de in ipairs(section.damageEvents or {}) do
            table.insert(allDamageEvents, {
                timeSec = cumulativeTime + de.timeSec,
                description = string.format("[%s] %s", section.label or "?", de.description or ""),
                severity = de.severity,
                raidDamage = de.raidDamage,
                abilityGameIDs = de.abilityGameIDs,
            })
        end
        cumulativeTime = cumulativeTime + (section.durationSec or 30)
    end

    local bossCount, trashCount = 0, 0
    for _, section in ipairs(dp.sections or {}) do
        if section.type == "boss" then bossCount = bossCount + 1
        else trashCount = trashCount + 1 end
    end

    local adapter = {
        encounterID = dp.challengeMapID or 0,
        difficulty = 8,
        patchVersion = dp.patchVersion,
        fightDurationSec = dp.totalDurationSec,
        damageTimeline = allDamageEvents,
        healerAssignments = {
            {
                className = dp.className,
                specName = dp.specName,
                playerName = dp.playerName,
                assignments = allAssignments,
            },
        },
        notes = dp.notes,
        _dungeonMeta = {
            name = dp.dungeonName,
            keyLevel = dp.keyLevel,
            bossCount = bossCount,
            trashCount = trashCount,
            sectionCount = #(dp.sections or {}),
        },
    }
    return adapter
end

------------------------------------------------------------------------
-- Boss Name Lookup
------------------------------------------------------------------------

local ENCOUNTER_NAMES = {
    [3176] = "Imperator Averzian",
    [3177] = "Vorasius",
    [3178] = "Vaelgor and Ezzorak",
    [3179] = "Fallen-King Salhadaar",
    [3180] = "Vanguard Council",
    [3181] = "Crown of the Cosmos",
    [3182] = "Belo'ren, Child of Al'ar",
    [3183] = "L'ura",
    [3306] = "Chimaerus",
}

local function GetBossName(encounterID)
    if EJ_GetEncounterInfo then
        local name = EJ_GetEncounterInfo(encounterID)
        if name then return name end
    end
    return ENCOUNTER_NAMES[encounterID] or ("Boss " .. encounterID)
end

------------------------------------------------------------------------
-- Difficulty colors
------------------------------------------------------------------------

local DIFFICULTY_COLORS = {
    [1] = "FF999999",
    [2] = "FF999999",
    [3] = "FF00CC00",
    [4] = "FF8866FF",
    [5] = "FFFF8800",
}

local function DifficultyColor(diff)
    return DIFFICULTY_COLORS[diff] or "FFFFFFFF"
end

------------------------------------------------------------------------
-- Plan Rows -- Raid (boss-grouped, expandable)
------------------------------------------------------------------------

local expandedBosses = {}

local function CreateBossGroup(parent, encounterID, plans, yOffset, playerClass, playerSpec)
    local isExpanded = expandedBosses[encounterID]
    local bossName = GetBossName(encounterID)

    local totalMyCDs = 0
    local diffLabels = {}
    for _, entry in ipairs(plans) do
        local _, myCDs = CountCDs(entry.plan, playerClass, playerSpec)
        totalMyCDs = totalMyCDs + myCDs
        table.insert(diffLabels, string.format("|c%s%s|r", DifficultyColor(entry.diff), DifficultyName(entry.diff)))
    end

    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(40)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    row:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(0.12, 0.12, 0.18, 0.95)
    row:RegisterForClicks("AnyUp")

    local arrow = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    arrow:SetPoint("LEFT", 10, 0)
    arrow:SetText(isExpanded and "|cFFCCCCCC\226\150\188|r" or "|cFFCCCCCC\226\150\182|r")

    local titleText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("LEFT", 26, 0)
    titleText:SetText(bossName)

    local diffText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    diffText:SetPoint("LEFT", titleText, "RIGHT", 12, 0)
    diffText:SetText(table.concat(diffLabels, " "))

    row:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.18, 0.18, 0.25, 0.95)
    end)
    row:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.12, 0.12, 0.18, 0.95)
    end)

    row:SetScript("OnClick", function()
        expandedBosses[encounterID] = not expandedBosses[encounterID]
        GUI:RefreshContent()
    end)

    local y = yOffset - 44

    if isExpanded then
        for _, entry in ipairs(plans) do
            local plan = entry.plan
            local diff = entry.diff
            local totalCDs, myCDs = CountCDs(plan, playerClass, playerSpec)

            local subRow = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            subRow:SetHeight(52)
            subRow:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, y)
            subRow:SetPoint("RIGHT", parent, "RIGHT", -4, 0)
            subRow:SetBackdrop({
                bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 8,
                insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            subRow:SetBackdropColor(0.08, 0.08, 0.12, 0.9)

            local diffLabel = subRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            diffLabel:SetPoint("TOPLEFT", 10, -8)
            diffLabel:SetText(string.format("|c%s%s|r", DifficultyColor(diff), DifficultyName(diff)))

            local detailText = subRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            detailText:SetPoint("TOPLEFT", 10, -26)
            detailText:SetText(string.format(
                "%s  |  %d healers  |  %d CDs  |  %d for you  |  %s fight",
                plan.patchVersion or "?",
                #(plan.healerAssignments or {}),
                totalCDs,
                myCDs,
                Util.FormatTime(plan.fightDurationSec or 0)
            ))

            local bundledEntry = HexCDReminder.BundledPlans and HexCDReminder.BundledPlans[encounterID]
            local isBundled = false
            if bundledEntry then
                if bundledEntry.healerAssignments then
                    isBundled = true
                elseif bundledEntry[diff] then
                    isBundled = true
                end
            end
            local saved = Config:Get("plans") or {}
            local isSaved = saved[encounterID] ~= nil
            local sourceText = subRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            sourceText:SetPoint("RIGHT", subRow, "RIGHT", -100, 8)
            if isSaved then
                sourceText:SetText("|cFF00FF00imported|r")
            elseif isBundled then
                sourceText:SetText("|cFF8888FFbundled|r")
            end

            local testBtn = CreateFrame("Button", nil, subRow, "UIPanelButtonTemplate")
            testBtn:SetSize(70, 24)
            testBtn:SetPoint("RIGHT", subRow, "RIGHT", -10, 0)
            testBtn:SetText("Test")
            testBtn:SetScript("OnClick", function()
                if myCDs == 0 then
                    print("|cFFFF6600[HexCD]|r No CDs for your spec in this plan. Check class/spec match.")
                    return
                end
                if testRunning then
                    Engine:Stop()
                    testRunning = false
                    testBtn:SetText("Test")
                    print("|cFF00CCFF[HexCD]|r Test stopped.")
                    return
                end
                testRunning = true
                testBtn:SetText("Stop")
                Log:OnFightStart("TEST", plan.encounterID, plan.difficulty or 4)
                Engine:RunTest(plan, testSpeed)
                print(string.format("|cFF00CCFF[HexCD]|r Testing %s %s at %dx speed (%d CDs)",
                    bossName, DifficultyName(diff), testSpeed, myCDs))
                C_Timer.After((plan.fightDurationSec or 600) / testSpeed + 20 / testSpeed, function()
                    if testRunning then
                        testRunning = false
                        testBtn:SetText("Test")
                    end
                end)
            end)

            if plan.notes then
                local notesText = subRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                notesText:SetPoint("TOPLEFT", 10, -40)
                notesText:SetPoint("RIGHT", subRow, "RIGHT", -180, 0)
                notesText:SetJustifyH("LEFT")
                notesText:SetWordWrap(false)
                local preview = plan.notes:sub(1, 100)
                if #plan.notes > 100 then preview = preview .. "..." end
                notesText:SetText(preview)
                subRow:SetHeight(56)
                y = y - 60
            else
                y = y - 56
            end
        end
        y = y - 4
    end

    return y
end

------------------------------------------------------------------------
-- Plan Row -- M+ Dungeon
------------------------------------------------------------------------

local function CreateDungeonRow(parent, plan, yOffset, playerClass, playerSpec)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    row:SetHeight(70)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
    row:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    row:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    row:SetBackdropColor(0.05, 0.12, 0.05, 0.9)

    local totalCDs, myCDs = CountCDs(plan, playerClass, playerSpec)
    local dm = plan._dungeonMeta

    local titleText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOPLEFT", 10, -8)
    titleText:SetText(string.format("|cFF00FF00%s|r  |cFFFFCC00+%d  M+|r", dm.name, dm.keyLevel))

    local detailText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    detailText:SetPoint("TOPLEFT", 10, -28)
    detailText:SetText(string.format(
        "%s  |  %d sections (%d boss, %d trash)  |  %d CDs  |  %d for you  |  %s key",
        plan.patchVersion or "?",
        dm.sectionCount, dm.bossCount, dm.trashCount,
        totalCDs, myCDs,
        Util.FormatTime(plan.fightDurationSec or 0)
    ))

    if plan.notes then
        local notesText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        notesText:SetPoint("TOPLEFT", 10, -44)
        notesText:SetPoint("RIGHT", row, "RIGHT", -220, 0)
        notesText:SetJustifyH("LEFT")
        notesText:SetWordWrap(false)
        local preview = plan.notes:sub(1, 120)
        if #plan.notes > 120 then preview = preview .. "..." end
        notesText:SetText(preview)
    end

    local testBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    testBtn:SetSize(80, 26)
    testBtn:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    testBtn:SetText("Test")
    testBtn:SetScript("OnClick", function()
        if myCDs == 0 then
            print("|cFFFF6600[HexCD]|r No CDs for your spec in this plan. Check class/spec match.")
            return
        end
        if testRunning then
            Engine:Stop()
            testRunning = false
            testBtn:SetText("Test")
            print("|cFF00CCFF[HexCD]|r Test stopped.")
            return
        end
        testRunning = true
        testBtn:SetText("Stop")
        Log:OnFightStart("TEST", plan.encounterID, plan.difficulty or 4)
        Engine:RunTest(plan, testSpeed)
        print(string.format("|cFF00CCFF[HexCD]|r Testing %s at %dx speed (%d CDs for your spec)",
            dm.name, testSpeed, myCDs))
        C_Timer.After((plan.fightDurationSec or 600) / testSpeed + 20 / testSpeed, function()
            if testRunning then
                testRunning = false
                testBtn:SetText("Test")
            end
        end)
    end)

    return row
end

------------------------------------------------------------------------
-- Settings Tab Content
------------------------------------------------------------------------

local function CreateSettingsSlider(parent, label, min, max, step, configKey, yOffset)
    local container = CreateFrame("Frame", nil, parent)
    container:SetSize(280, 50)
    container:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)

    local t = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("TOPLEFT", 0, 0)
    t:SetText(label)

    local slider = CreateFrame("Slider", "HexCDR_" .. configKey, container, "OptionsSliderTemplate")
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
    local cb = CreateFrame("CheckButton", "HexCDR_" .. configKey, parent, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, yOffset)
    local t = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    t:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    t:SetText(label)
    cb:SetChecked(Config:Get(configKey) and true or false)
    cb:SetScript("OnClick", function(self) Config:Set(configKey, self:GetChecked() and true or false) end)
    return cb
end

local function CreateSettingsDropdown(parent, label, configKey, options, yOffset)
    local frame = CreateFrame("Frame", "HexCDR_" .. configKey, parent, "UIDropDownMenuTemplate")
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

local function CreateSectionHeader(parent, text, yOffset)
    local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", 16, yOffset)
    h:SetText("|cFFFFCC00" .. text .. "|r")
    return h
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

    btn:SetScript("OnClick", function()
        toggleFn()
        UpdateVisual()
    end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropBorderColor(1, 1, 1, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(isUnlockedFn() and "Click to lock position" or "Click to unlock and drag")
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        UpdateVisual()
        GameTooltip:Hide()
    end)

    btn._update = UpdateVisual
    UpdateVisual()
    return btn
end

------------------------------------------------------------------------
-- Settings: Persistent Header (anchors + lock/unlock + sub-tabs)
------------------------------------------------------------------------

local SETTINGS_HEADER_HEIGHT = 160  -- total fixed height above scroll

local function EnsureSettingsHeader(f)
    if rawget(f, "_shCreated") then return end
    rawset(f, "_shCreated", true)


    -- Header container (parented to main frame, not scroll child)
    local header = CreateFrame("Frame", nil, f)
    header:SetPoint("TOPLEFT", 10, -96)
    header:SetPoint("RIGHT", f, "RIGHT", -10, 0)
    header:SetHeight(SETTINGS_HEADER_HEIGHT)
    rawset(f, "_shFrame", header)

    -- Anchor layout section
    local anchorToggles = {}
    local y = 0

    -- Row 1: title + Lock/Unlock buttons
    local h = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", 6, y)
    h:SetText("|cFFFFCC00Bar Layout|r")

    local lockBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    lockBtn:SetSize(80, 22)
    lockBtn:SetPoint("TOPLEFT", 140, y + 2)
    lockBtn:SetText("|cFF00FF00Lock All|r")

    local unlockBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    unlockBtn:SetSize(90, 22)
    unlockBtn:SetPoint("LEFT", lockBtn, "RIGHT", 4, 0)
    unlockBtn:SetText("|cFFFFCC00Unlock All|r")

    y = y - 26

    -- Anchor toggles in 2 columns
    local COL1_X = 6
    local COL2_X = 300
    local TOGGLE_W = 270

    local function AddToggle(label, colorHex, col, row, isUnlockedFn, toggleFn)
        local xOff = col == 1 and COL1_X or COL2_X
        local yOff = y - (row * 30)
        local btn = CreateAnchorToggle(header, label, colorHex, yOff, isUnlockedFn, toggleFn)
        btn:ClearAllPoints()
        btn:SetSize(TOGGLE_W, 26)
        btn:SetPoint("TOPLEFT", header, "TOPLEFT", xOff, yOff)
        anchorToggles[#anchorToggles + 1] = btn
        return btn
    end

    AddToggle("Countdown Bars", "6699FF", 1, 0,
        function() return Bars:IsUnlocked() end,
        function() Bars:ToggleLock() end)
    AddToggle("Active Window Bars", "CC7711", 2, 0,
        function() return Bars:IsWindowUnlocked() end,
        function() Bars:ToggleWindowLock() end)
    AddToggle("Boss Abilities", "CC3333", 1, 1,
        function() return Engine:IsDmgUnlocked() end,
        function() Engine:ToggleDmgLock() end)

    lockBtn:SetScript("OnClick", function()
        if Bars:IsUnlocked() then Bars:Lock() end
        if Bars:IsWindowUnlocked() then Bars:LockWindow() end
        if Engine:IsDmgUnlocked() then Engine:LockDmgBars() end
        for _, t in ipairs(anchorToggles) do t._update() end
    end)
    unlockBtn:SetScript("OnClick", function()
        if not Bars:IsUnlocked() then Bars:Unlock() end
        if not Bars:IsWindowUnlocked() then Bars:UnlockWindow() end
        if not Engine:IsDmgUnlocked() then Engine:UnlockDmgBars() end
        if DT and not DT:IsUnlocked() then DT:Unlock() end
        if KT and not KT:IsUnlocked() then KT:Unlock() end
        for _, t in ipairs(anchorToggles) do t._update() end
    end)

    -- Separator
    local sep = header:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 0, y - 94)
    sep:SetPoint("RIGHT", header, "RIGHT", 0, 0)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.4)

    -- Sub-tab buttons
    if not rawget(f, "_activeSubTab") then rawset(f, "_activeSubTab", "cdreminder") end

    local function CreateSubTab(label, xOff)
        local btn = CreateFrame("Button", nil, header, "BackdropTemplate")
        btn:SetSize(110, 24)
        btn:SetPoint("TOPLEFT", header, "TOPLEFT", xOff, y - 100)
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
        return btn
    end

    local cdTab = CreateSubTab("CD Reminder", 6)

    local function UpdateSubTabVisuals()
        -- Only one sub-tab in Reminder addon
        cdTab:SetBackdropColor(0.2, 0.15, 0.0, 0.9)
        cdTab:SetBackdropBorderColor(1.0, 0.84, 0.0, 1.0)
        cdTab._label:SetText("|cFFFFCC00CD Reminder|r")
    end

    cdTab:SetScript("OnClick", function()
        rawset(f, "_activeSubTab", "cdreminder")
        UpdateSubTabVisuals()
        GUI:RefreshContent()
    end)

    rawset(f, "_updateSubTabVisuals", UpdateSubTabVisuals)
    UpdateSubTabVisuals()

    header:Hide()
end

------------------------------------------------------------------------
-- Settings: EditBox helper
------------------------------------------------------------------------

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

------------------------------------------------------------------------
-- Settings: Rotation controls (shared by Dispel + Kick)
------------------------------------------------------------------------

local function CreateRotationControls(parent, yOffset, tracker, configPrefix, simulateFnName, colorHex)
    local y = yOffset

    CreateSectionHeader(parent, "Rotation", y)
    y = y - 22

    -- Pre-fill from saved rotation
    local saved = Config:Get(configPrefix .. "Rotation") or {}
    local nameStr = ""
    if #saved > 0 then
        local names = {}
        for _, r in ipairs(saved) do
            table.insert(names, r.name or r)
        end
        nameStr = table.concat(names, ", ")
    end

    local namesBox = CreateSettingsEditBox(parent, "Names (comma-separated):", nameStr, 400, y)
    y = y - 50

    -- Helper for creating buttons at current y position
    local function MakeBtn(label, width, xOff, onClick)
        local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        btn:SetSize(width, 24)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", xOff, y)
        btn:SetText(label)
        btn:SetScript("OnClick", onClick)
        return btn
    end

    -- Current rotation label
    local rotLabel = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    rotLabel:SetPoint("TOPLEFT", 16, y)
    rotLabel:SetJustifyH("LEFT")

    -- Container for dynamic simulate buttons (rebuilt when rotation changes)
    local simBtnContainer = CreateFrame("Frame", nil, parent)
    simBtnContainer:SetSize(560, 30)
    simBtnContainer:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)

    local simButtons = {}

    local function RebuildSimButtons()
        for _, btn in ipairs(simButtons) do
            btn:Hide()
            btn:SetParent(nil)
        end
        wipe(simButtons)

        local names = tracker.GetRotationNames and tracker:GetRotationNames() or {}
        if #names == 0 then
            rotLabel:SetText("|cFF888888No rotation set|r")
            simBtnContainer:SetHeight(1)
            return 0
        end

        rotLabel:SetText("|cFF" .. colorHex .. "Current:|r " .. table.concat(names, " > "))

        local simLabel = simBtnContainer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        simLabel:SetPoint("TOPLEFT", 16, -4)
        simLabel:SetText("Simulate cast:")
        table.insert(simButtons, simLabel)

        local xOff = 100
        for _, name in ipairs(names) do
            local btnW = math.max(70, #name * 7 + 16)
            local btn = CreateFrame("Button", nil, simBtnContainer, "UIPanelButtonTemplate")
            btn:SetSize(btnW, 22)
            btn:SetPoint("TOPLEFT", simBtnContainer, "TOPLEFT", xOff, 0)
            btn:SetText(name)
            btn:SetScript("OnClick", function()
                if tracker.SimulateCastFrom then
                    Config:Set(configPrefix .. "Enabled", true)
                    tracker:SimulateCastFrom(name)
                end
            end)
            table.insert(simButtons, btn)
            xOff = xOff + btnW + 4
        end

        simBtnContainer:SetHeight(26)
        return 26
    end

    ----------------------------------------------------------------
    -- Operational buttons: Set Rotation, Broadcast
    ----------------------------------------------------------------
    MakeBtn("Set Rotation", 110, 16, function()
        local text = namesBox._editBox:GetText()
        if text == "" then
            print("|cFF" .. colorHex .. "[HexCD]|r Enter names first.")
            return
        end
        Config:Set(configPrefix .. "Enabled", true)
        tracker:SetRotation(text)
        RebuildSimButtons()
    end)

    MakeBtn("Broadcast", 90, 132, function()
        if not tracker.BroadcastRotation then return end
        tracker:BroadcastRotation()
    end)

    y = y - 30

    -- Rotation display
    rotLabel:ClearAllPoints()
    rotLabel:SetPoint("TOPLEFT", 16, y)
    y = y - 22

    ----------------------------------------------------------------
    -- Testing section
    ----------------------------------------------------------------
    CreateSectionHeader(parent, "Testing", y)
    y = y - 22

    local durBox = CreateSettingsEditBox(parent, "Duration (sec):", "15", 80, y)
    local countBox = CreateSettingsEditBox(parent, "# Debuffs:", "4", 60, y, 200)
    y = y - 50

    -- "Start Test" button — sets rotation + spawns simulated debuffs
    MakeBtn("Start Test", 90, 16, function()
        local text = namesBox._editBox:GetText()
        if text == "" then
            print("|cFF" .. colorHex .. "[HexCD]|r Enter names first.")
            return
        end
        local dur = tonumber(durBox._editBox:GetText()) or 15
        local count = tonumber(countBox._editBox:GetText()) or 4
        Config:Set(configPrefix .. "Enabled", true)
        tracker:SetRotation(text)
        RebuildSimButtons()
        tracker[simulateFnName](tracker, dur, count)
    end)

    y = y - 30

    -- Per-player simulate cast buttons
    simBtnContainer:ClearAllPoints()
    simBtnContainer:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
    local simHeight = RebuildSimButtons()
    y = y - math.max(simHeight, 4) - 4

    return y
end

------------------------------------------------------------------------
-- Settings: Sub-tab content
------------------------------------------------------------------------

local function PopulateCDReminderTab(scrollChild)
    local y = 0

    CreateSectionHeader(scrollChild, "General", y)
    y = y - 25
    CreateSettingsDropdown(scrollChild, "Timing Mode", "timingMode", { "bigwigs", "elapsed" }, y)
    y = y - 55

    CreateSectionHeader(scrollChild, "Text-to-Speech", y)
    y = y - 25
    CreateSettingsCheckbox(scrollChild, "Enable TTS", "ttsEnabled", y)
    y = y - 35
    CreateSettingsSlider(scrollChild, "TTS Rate", 1, 10, 1, "ttsRate", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "TTS Volume", 0, 100, 5, "ttsVolume", y)
    y = y - 55

    CreateSectionHeader(scrollChild, "Timer Bars", y)
    y = y - 25
    CreateSettingsSlider(scrollChild, "Bar Width", 100, 400, 10, "barWidth", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Height", 14, 40, 2, "barHeight", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Bar Scale", 0.5, 2.0, 0.1, "barScale", y)
    y = y - 55
    CreateSettingsSlider(scrollChild, "Show Window (sec)", 10, 60, 5, "barShowWindow", y)
    y = y - 55
    CreateSettingsDropdown(scrollChild, "Growth Direction", "barGrowDirection", { "UP", "DOWN" }, y)
    y = y - 55

    CreateSectionHeader(scrollChild, "Debug", y)
    y = y - 25
    CreateSettingsDropdown(scrollChild, "Log Level", "logLevel", { "OFF", "ERRORS", "INFO", "DEBUG", "TRACE" }, y)
    y = y - 65

    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))
end

local function PopulateSettingsSubTab(scrollChild, subTab)
    if subTab == "cdreminder" then
        PopulateCDReminderTab(scrollChild)
    end
end

------------------------------------------------------------------------
-- Main Frame
------------------------------------------------------------------------

local function CreateMainFrame()
    local f = CreateFrame("Frame", "HexCDReminderMainFrame", UIParent, "BackdropTemplate")
    f:SetSize(650, 500)
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

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -12)
    title:SetText("|cFF00CCFFHexCD Reminder|r")

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Player info
    local playerInfo = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    playerInfo:SetPoint("TOPRIGHT", -40, -16)
    playerInfo:SetJustifyH("RIGHT")
    f._playerInfo = playerInfo

    -- Speed controls (only visible on Raid/M+ tabs)
    local speedFrame = CreateFrame("Frame", nil, f)
    speedFrame:SetSize(300, 24)
    speedFrame:SetPoint("TOPLEFT", 14, -34)
    f._speedFrame = speedFrame

    local speedLabel = speedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    speedLabel:SetPoint("LEFT", 0, 0)
    speedLabel:SetText("Test Speed:")

    f._speedButtons = {}
    local speeds = { {"1x", 1}, {"2x", 2}, {"5x", 5}, {"10x", 10} }
    for i, s in ipairs(speeds) do
        local btn = CreateFrame("Button", nil, speedFrame, "UIPanelButtonTemplate")
        btn:SetSize(50, 24)
        btn:SetPoint("LEFT", 76 + (i-1) * 55, 0)
        btn:SetText(s[1])
        btn._speed = s[2]
        btn:SetScript("OnClick", function()
            testSpeed = s[2]
            for _, sb in ipairs(f._speedButtons) do
                if sb._speed == s[2] then
                    sb:SetNormalFontObject("GameFontHighlight")
                else
                    sb:SetNormalFontObject("GameFontNormal")
                end
            end
        end)
        table.insert(f._speedButtons, btn)
    end
    f._speedButtons[1]:SetNormalFontObject("GameFontHighlight")

    -- Separator
    local sep = f:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", 10, -62)
    sep:SetPoint("TOPRIGHT", -10, -62)
    sep:SetColorTexture(0.4, 0.4, 0.4, 0.6)

    -- Tab buttons (Raid / M+ / Settings)
    f._activeTab = "raid"

    local function CreateTabButton(parent, label, xOffset)
        local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
        btn:SetSize(80, 24)
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, -68)
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
        return btn
    end

    f._raidTab = CreateTabButton(f, "Raid", 14)
    f._mplusTab = CreateTabButton(f, "M+", 98)
    f._settingsTab = CreateTabButton(f, "Settings", 182)

    local function UpdateTabVisuals()
        -- Raid
        if f._activeTab == "raid" then
            f._raidTab:SetBackdropColor(0.2, 0.15, 0.0, 0.9)
            f._raidTab:SetBackdropBorderColor(1.0, 0.84, 0.0, 1.0)
            f._raidTab._label:SetText("|cFFFFCC00Raid|r")
        else
            f._raidTab:SetBackdropColor(0.08, 0.08, 0.12, 0.7)
            f._raidTab:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
            f._raidTab._label:SetText("|cFF888888Raid|r")
        end
        -- M+
        if f._activeTab == "mplus" then
            f._mplusTab:SetBackdropColor(0.0, 0.15, 0.05, 0.9)
            f._mplusTab:SetBackdropBorderColor(0.0, 1.0, 0.4, 1.0)
            f._mplusTab._label:SetText("|cFF00FF00M+|r")
        else
            f._mplusTab:SetBackdropColor(0.08, 0.08, 0.12, 0.7)
            f._mplusTab:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
            f._mplusTab._label:SetText("|cFF888888M+|r")
        end
        -- Settings
        if f._activeTab == "settings" then
            f._settingsTab:SetBackdropColor(0.15, 0.1, 0.2, 0.9)
            f._settingsTab:SetBackdropBorderColor(0.6, 0.5, 1.0, 1.0)
            f._settingsTab._label:SetText("|cFF9988FFSettings|r")
        else
            f._settingsTab:SetBackdropColor(0.08, 0.08, 0.12, 0.7)
            f._settingsTab:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.5)
            f._settingsTab._label:SetText("|cFF888888Settings|r")
        end
        -- Speed controls only on plan tabs
        if f._activeTab == "settings" then
            f._speedFrame:Hide()
        else
            f._speedFrame:Show()
        end
    end
    f._updateTabVisuals = UpdateTabVisuals

    f._raidTab:SetScript("OnClick", function()
        f._activeTab = "raid"
        UpdateTabVisuals()
        GUI:RefreshContent()
    end)
    f._mplusTab:SetScript("OnClick", function()
        f._activeTab = "mplus"
        UpdateTabVisuals()
        GUI:RefreshContent()
    end)
    f._settingsTab:SetScript("OnClick", function()
        f._activeTab = "settings"
        UpdateTabVisuals()
        GUI:RefreshContent()
    end)

    UpdateTabVisuals()

    -- Scrollable content area
    local scrollFrame = CreateFrame("ScrollFrame", "HexCDPlanScroll", f, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", 10, -96)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 50)

    local scrollChild = CreateFrame("Frame", "HexCDPlanScrollChild", scrollFrame)
    scrollChild:SetWidth(590)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)

    f._scrollFrame = scrollFrame
    f._scrollChild = scrollChild

    -- Bottom row: utility buttons
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 24)
    importBtn:SetPoint("BOTTOMLEFT", 14, 14)
    importBtn:SetText("Import Plan")
    importBtn:SetScript("OnClick", function()
        HexCDReminder.PlanImport:ShowFrame()
    end)

    local logBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    logBtn:SetSize(90, 24)
    logBtn:SetPoint("LEFT", importBtn, "RIGHT", 6, 0)
    logBtn:SetText("Debug Log")
    logBtn:SetScript("OnClick", function()
        HexCDReminder.DebugLog:ShowFrame()
    end)

    -- Fight log count
    local logCount = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    logCount:SetPoint("BOTTOMRIGHT", -14, 18)
    f._logCount = logCount

    return f
end

------------------------------------------------------------------------
-- Content Refresh (all tabs)
------------------------------------------------------------------------

function GUI:RefreshContent()
    if not mainFrame then return end

    local scrollChild = mainFrame._scrollChild
    -- Clear existing children
    for _, child in ipairs({ scrollChild:GetChildren() }) do
        child:Hide()
        child:SetParent(nil)
    end
    -- Clear font strings attached to scrollChild
    for _, region in ipairs({ scrollChild:GetRegions() }) do
        region:Hide()
    end

    local activeTab = mainFrame._activeTab or "raid"

    if activeTab == "settings" then
        EnsureSettingsHeader(mainFrame)
        rawget(mainFrame, "_shFrame"):Show()
        local updateVis = rawget(mainFrame, "_updateSubTabVisuals")
        if updateVis then updateVis() end
        -- Push scroll frame below the fixed header
        local sf = rawget(mainFrame, "_scrollFrame")
        sf:ClearAllPoints()
        sf:SetPoint("TOPLEFT", 10, -96 - SETTINGS_HEADER_HEIGHT)
        sf:SetPoint("BOTTOMRIGHT", -30, 50)
        local subTab = rawget(mainFrame, "_activeSubTab") or "cdreminder"
        PopulateSettingsSubTab(scrollChild, subTab)
        mainFrame._logCount:SetText("")
        return
    end

    -- Non-settings: hide header, restore scroll position
    if rawget(mainFrame, "_shCreated") then
        rawget(mainFrame, "_shFrame"):Hide()
    end
    local sf = rawget(mainFrame, "_scrollFrame")
    sf:ClearAllPoints()
    sf:SetPoint("TOPLEFT", 10, -96)
    sf:SetPoint("BOTTOMRIGHT", -30, 50)

    local playerClass, playerSpec = Util.GetPlayerSpec()
    playerClass = Util.NormalizeClassName(playerClass)
    mainFrame._playerInfo:SetText(string.format("%s %s", playerClass, playerSpec))

    local y = 0
    local count = 0

    if activeTab == "raid" then
        local allPlans = Config:GetAllPlans()
        local bossGroups = {}
        local bossOrder = {}

        for eid, diffMap in pairs(allPlans) do
            local group = {}
            for diff, plan in pairs(diffMap) do
                if type(diff) == "number" then
                    table.insert(group, { diff = diff, plan = plan })
                end
            end
            if #group > 0 then
                table.sort(group, function(a, b) return a.diff < b.diff end)
                bossGroups[eid] = group
                table.insert(bossOrder, eid)
            end
        end
        table.sort(bossOrder)

        for _, eid in ipairs(bossOrder) do
            y = CreateBossGroup(scrollChild, eid, bossGroups[eid], y, playerClass, playerSpec)
            count = count + 1
        end

        if count == 0 then
            local empty = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            empty:SetPoint("CENTER", 0, 0)
            empty:SetText("No raid plans loaded.\nUse 'Import Plan' or bundle a PlanData.lua file.")
        end

    else -- "mplus"
        local dungeonSources = {}
        if HexCDReminder.BundledDungeonPlans then
            for mapID, dp in pairs(HexCDReminder.BundledDungeonPlans) do
                dungeonSources[mapID] = { plan = dp, source = "bundled" }
            end
        end
        local savedDungeons = Config:Get("dungeonPlans") or {}
        for mapID, dp in pairs(savedDungeons) do
            dungeonSources[mapID] = { plan = dp, source = "imported" }
        end

        local sorted = {}
        for mapID, entry in pairs(dungeonSources) do
            table.insert(sorted, { mapID = mapID, entry = entry })
        end
        table.sort(sorted, function(a, b)
            return (a.entry.plan.dungeonName or "") < (b.entry.plan.dungeonName or "")
        end)

        for _, item in ipairs(sorted) do
            local dp = item.entry.plan
            local adapter = DungeonPlanToTestPlan(dp)
            CreateDungeonRow(scrollChild, adapter, y, playerClass, playerSpec)
            y = y - 78
            count = count + 1
        end

        if count == 0 then
            local empty = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontDisable")
            empty:SetPoint("CENTER", 0, 0)
            empty:SetText("No M+ dungeon plans loaded.\nBundle dungeon CD plans via the CLI.")
        end
    end

    scrollChild:SetHeight(math.max(1, math.abs(y) + 10))

    local fightLogs = Config:Get("fightLogs") or {}
    mainFrame._logCount:SetText(string.format("%d saved fight logs", #fightLogs))
end

-- Backward compat alias
function GUI:RefreshPlanList()
    self:RefreshContent()
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
    self:RefreshContent()
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
    if not mainFrame then
        mainFrame = CreateMainFrame()
    end
    mainFrame._activeTab = "settings"
    mainFrame._updateTabVisuals()
    self:RefreshContent()
    mainFrame:Show()
end
