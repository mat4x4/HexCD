------------------------------------------------------------------------
-- HexCD: Dispel Tracker
-- Shows a rotation overlay when dispellable debuffs exist on group members.
-- Detects via UNIT_AURA + C_UnitAuras API (Midnight 12.0 safe).
--
-- States: HIDDEN (no debuffs) → ACTIVE (debuffs exist) → INACTIVE (cleared, 3s fade)
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.DispelTracker = {}

local DT = HexCD.DispelTracker
local Config = HexCD.Config
local Log = HexCD.DebugLog
local Util = HexCD.Util

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local DISPEL_SPELLS = {
    Druid   = { spellID = 88423,  name = "Nature's Cure",  cd = 8,  types = { Magic = true, Curse = true, Poison = true } },
    Evoker  = { spellID = 360823, name = "Naturalize",     cd = 8,  types = { Magic = true, Poison = true } },
    Priest  = { spellID = 527,    name = "Purify",         cd = 8,  types = { Magic = true, Disease = true } },
    Shaman  = { spellID = 77130,  name = "Purify Spirit",  cd = 8,  types = { Magic = true, Curse = true } },
    Paladin = { spellID = 4987,   name = "Cleanse",        cd = 8,  types = { Magic = true, Poison = true, Disease = true } },
    Monk    = { spellID = 115450, name = "Detox",          cd = 8,  types = { Magic = true, Poison = true, Disease = true } },
}

-- Reverse lookup: spellID → class
local DISPEL_SPELL_IDS = {}
for class, info in pairs(DISPEL_SPELLS) do
    DISPEL_SPELL_IDS[info.spellID] = class
end

--- Strip realm suffix from a player name ("Name-Realm" → "Name")
local function StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

local DISPELLER_BAR_POOL_SIZE = 6
local DEBUFF_ENTRY_POOL_SIZE = 8
local INACTIVE_FADE_SEC = 3
local ALERT_DEBOUNCE_SEC = 2
local UPDATE_THROTTLE = 0.2
local ADDON_MSG_PREFIX = "HexCD"
local commsRegistered = false

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local dispelRotation = {}       -- { {name, class, spellID, cd}, ... }
local currentIdx = 1            -- who's next in rotation
local activeDebuffs = {}        -- unit → { auraInstanceID → {name, dispelType, expirationTime} }
local dispelCDState = {}        -- rotationIdx → {lastTime, readyTime}
local visibilityState = "HIDDEN"
local inactiveTimer = nil
local lastAlertTime = 0
local totalDebuffCount = 0

-- Frame pools
local dispellerBars = {}        -- pre-allocated bar frames
local debuffEntries = {}        -- pre-allocated debuff text frames
local anchorFrame = nil
local headerText = nil
-- (allClearText removed — INACTIVE uses headerText)
local onUpdateFrame = nil
local onUpdateThrottle = 0

-- Group unit mapping
local groupUnits = {}           -- unit tokens for current group
local rotationUnitMap = {}      -- rotationIdx → unitToken

------------------------------------------------------------------------
-- Bar Creation (follows TimerBars.lua pattern)
------------------------------------------------------------------------

local function CreateDispellerBar(index)
    local bar = CreateFrame("StatusBar", "HexCDDispelBar" .. index, nil, "BackdropTemplate")
    bar:SetSize(200, 20)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    bar:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropColor(0.1, 0.1, 0.15, 0.85)
    bar:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.6)

    -- Background
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.9)
    bar.bg = bg

    -- CD/Ready text (right)
    local cdText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cdText:SetPoint("RIGHT", -6, 0)
    cdText:SetJustifyH("RIGHT")
    bar.cdText = cdText

    -- Number + name text (left, stretches to cdText)
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", 6, 0)
    nameText:SetPoint("RIGHT", cdText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    bar.nameText = nameText

    -- Gold border overlay (for #1 dispeller)
    local goldBorder = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    goldBorder:SetPoint("TOPLEFT", -3, 3)
    goldBorder:SetPoint("BOTTOMRIGHT", 3, -3)
    goldBorder:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
    })
    goldBorder:SetBackdropBorderColor(1.0, 0.84, 0.0, 1.0)
    goldBorder:Hide()
    bar.goldBorder = goldBorder

    bar._active = false
    bar._index = index
    return bar
end

local function CreateDebuffEntry(index)
    local f = CreateFrame("Frame", "HexCDDebuffEntry" .. index, nil)
    f:SetSize(200, 16)
    f:Hide()

    local text = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", 6, 0)
    text:SetPoint("RIGHT", -6, 0)
    text:SetJustifyH("LEFT")
    f.text = text

    f._active = false
    return f
end

------------------------------------------------------------------------
-- Anchor Frame
------------------------------------------------------------------------

local function CreateAnchor()
    local f = CreateFrame("Frame", "HexCDDispelAnchor", UIParent, "BackdropTemplate")
    f:SetSize(210, 24)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
    f:SetBackdropBorderColor(0.4, 0.3, 0.6, 0.8)

    -- Header text
    headerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerText:SetPoint("TOPLEFT", 8, -4)
    headerText:SetPoint("RIGHT", -8, 0)
    headerText:SetJustifyH("LEFT")
    headerText:SetText("|cFFCC88FFDISPEL|r")

    -- (allClearText removed — INACTIVE state uses headerText directly)

    -- Position from config
    local point = Config:Get("dispelAnchorPoint") or "CENTER"
    local x = Config:Get("dispelAnchorX") or 300
    local y = Config:Get("dispelAnchorY") or 0
    f:SetPoint(point, UIParent, point, x, y)

    -- Draggable (unlock/lock)
    f:SetMovable(true)
    f:EnableMouse(false) -- disabled by default (locked)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, px, py = self:GetPoint()
        Config:Set("dispelAnchorPoint", p)
        Config:Set("dispelAnchorX", px)
        Config:Set("dispelAnchorY", py)
    end)

    f:Hide()
    return f
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

function DT:Init()
    anchorFrame = CreateAnchor()

    -- Create bar pool (parented to anchor so they move together)
    for i = 1, DISPELLER_BAR_POOL_SIZE do
        dispellerBars[i] = CreateDispellerBar(i)
        dispellerBars[i]:SetParent(anchorFrame)
    end

    -- Create debuff entry pool (parented to anchor)
    for i = 1, DEBUFF_ENTRY_POOL_SIZE do
        debuffEntries[i] = CreateDebuffEntry(i)
        debuffEntries[i]:SetParent(anchorFrame)
    end

    -- Register addon message prefix for cross-client dispel sync
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, err = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_MSG_PREFIX)
        if ok then
            commsRegistered = true
            Log:Log("DEBUG", "DispelTracker: addon comms registered (prefix: " .. ADDON_MSG_PREFIX .. ")")
        else
            Log:Log("DEBUG", "DispelTracker: addon comms failed: " .. tostring(err))
        end
    end

    -- OnUpdate frame for CD ticking (only runs in ACTIVE state)
    onUpdateFrame = CreateFrame("Frame", "HexCDDispelOnUpdate")
    onUpdateFrame:Hide()
    onUpdateFrame:SetScript("OnUpdate", function(_, elapsed)
        onUpdateThrottle = onUpdateThrottle + elapsed
        if onUpdateThrottle < UPDATE_THROTTLE then return end
        onUpdateThrottle = 0
        DT:UpdateDisplay()
    end)

    -- Load rotation from saved config
    local saved = Config:Get("dispelRotation")
    if saved and #saved > 0 then
        DT:SetRotation(saved)
    end

    Log:Log("DEBUG", "DispelTracker initialized")
end

------------------------------------------------------------------------
-- Rotation Management
------------------------------------------------------------------------

function DT:SetRotation(names)
    dispelRotation = {}
    if type(names) == "string" then
        -- Parse comma-separated: "Hexastyle,Soandso,Thirdperson"
        for name in names:gmatch("[^,]+") do
            name = StripRealm(name:match("^%s*(.-)%s*$")) -- trim + strip realm
            table.insert(dispelRotation, { name = name, class = nil })
        end
    elseif type(names) == "table" then
        for _, entry in ipairs(names) do
            if type(entry) == "string" then
                table.insert(dispelRotation, { name = entry, class = nil })
            elseif type(entry) == "table" then
                table.insert(dispelRotation, entry)
            end
        end
    end

    -- Try to resolve class for each member
    DT:RebuildGroupMapping()

    currentIdx = 1
    wipe(dispelCDState)

    -- Save to config
    local saveData = {}
    for _, r in ipairs(dispelRotation) do
        table.insert(saveData, { name = r.name, class = r.class })
    end
    Config:Set("dispelRotation", saveData)

    local names_str = {}
    for _, r in ipairs(dispelRotation) do
        table.insert(names_str, r.name)
    end
    Log:Log("INFO", "Dispel rotation set: " .. table.concat(names_str, " > "))
    print("|cFFCC88FF[HexCD]|r Dispel rotation: " .. table.concat(names_str, " > "))
end

function DT:RebuildGroupMapping()
    wipe(groupUnits)
    wipe(rotationUnitMap)

    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    elseif IsInGroup() then
        prefix, count = "party", GetNumGroupMembers() - 1
        -- Include player
        groupUnits["player"] = true
    else
        groupUnits["player"] = true
        return
    end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            groupUnits[unit] = true
        end
    end

    -- Map rotation entries to unit tokens by name
    for i, entry in ipairs(dispelRotation) do
        for unit in pairs(groupUnits) do
            local ok, unitName = pcall(UnitName, unit)
            if ok and StripRealm(unitName) == entry.name then
                rotationUnitMap[i] = unit
                -- Resolve class if not set
                if not entry.class then
                    local _, className = UnitClass(unit)
                    if className and not issecretvalue(className) then
                        entry.class = className:sub(1,1):upper() .. className:sub(2):lower()
                    end
                end
                -- Resolve dispel spell info
                if entry.class and DISPEL_SPELLS[entry.class] then
                    local info = DISPEL_SPELLS[entry.class]
                    entry.spellID = info.spellID
                    entry.cd = info.cd
                    entry.dispelName = info.name
                end
                break
            end
        end
    end
end

------------------------------------------------------------------------
-- Aura Scanning
------------------------------------------------------------------------

local function IsDispellableAura(aura)
    if not aura then return false end
    if not aura.isHarmful then return false end
    -- Guard against secret values
    if issecretvalue and issecretvalue(aura.dispelName) then return false end
    return aura.dispelName ~= nil
end

local function ScanUnitAuras(unit)
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
    if not UnitExists(unit) then return end

    local unitDebuffs = activeDebuffs[unit]
    if not unitDebuffs then
        unitDebuffs = {}
        activeDebuffs[unit] = unitDebuffs
    end

    -- Full rescan (simpler than incremental for v1)
    wipe(unitDebuffs)

    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
        if not aura then break end

        if IsDispellableAura(aura) then
            unitDebuffs[aura.auraInstanceID] = {
                name = (not issecretvalue(aura.name)) and aura.name or "Debuff",
                dispelType = aura.dispelName or "Unknown",
                expirationTime = aura.expirationTime or 0,
                duration = aura.duration or 0,
            }
        end
    end
end

local function CountTotalDebuffs()
    local count = 0
    for _, unitDebuffs in pairs(activeDebuffs) do
        for _ in pairs(unitDebuffs) do
            count = count + 1
        end
    end
    return count
end

------------------------------------------------------------------------
-- Rotation Logic
------------------------------------------------------------------------

local function IsDispellerReady(idx)
    local state = dispelCDState[idx]
    if not state then return true, 0 end
    local remaining = state.readyTime - GetTime()
    if remaining <= 0 then return true, 0 end
    return false, remaining
end

local function GetNextAliveIdx(startIdx)
    if #dispelRotation == 0 then return nil end
    local idx = startIdx
    for _ = 1, #dispelRotation do
        local unit = rotationUnitMap[idx]
        if unit and UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            return idx
        end
        idx = (idx % #dispelRotation) + 1
    end
    return startIdx -- fallback: everyone dead, just return start
end

-- Pick the alive dispeller with the lowest readyTime (soonest off CD).
-- Tiebreaker: rotation order (lower index wins).
-- This is called after each dispel to lock in who goes next.
local function GetLowestCDIdx()
    if #dispelRotation == 0 then return 1 end
    local now = GetTime()
    local bestIdx = nil
    local bestReadyTime = math.huge

    for i = 1, #dispelRotation do
        local unit = rotationUnitMap[i]
        local alive = not unit or (UnitExists(unit) and not UnitIsDeadOrGhost(unit))
        if alive then
            local state = dispelCDState[i]
            local readyTime = state and state.readyTime or 0
            -- Clamp: all ready players (readyTime <= now) are equal at 0
            -- so rotation order (lower index) breaks the tie via strict <
            if readyTime <= now then readyTime = 0 end
            if readyTime < bestReadyTime then
                bestReadyTime = readyTime
                bestIdx = i
            end
        end
    end

    return bestIdx or 1
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

function DT:UpdateDisplay()
    if visibilityState == "HIDDEN" then return end
    if #dispelRotation == 0 then return end

    local now = GetTime()
    totalDebuffCount = CountTotalDebuffs()
    local barWidth = Config:Get("dispelBarWidth") or 200
    local barHeight = Config:Get("dispelBarHeight") or 20

    -- Active dispeller is locked after each dispel event (lowest CD wins)
    local activeIdx = currentIdx

    -- Update header: compact title with debuff count
    local nextName = (activeIdx and dispelRotation[activeIdx]) and dispelRotation[activeIdx].name or "?"
    if totalDebuffCount > 0 then
        headerText:SetText("|cFFCC88FFDISPEL|r  |cFFFFCC00" .. nextName .. "'s turn|r  |cFFFF8800[" .. totalDebuffCount .. "]|r")
    else
        headerText:SetText("|cFFCC88FFDISPEL|r  |cFFFFCC00" .. nextName .. "'s turn|r")
    end

    -- Layout: header (20px) + gap (4px) + bars + gap (4px) + debuff entries + padding (4px)
    local HEADER_HEIGHT = 20
    local GAP = 4
    local BAR_SPACING = barHeight + 4
    local ENTRY_HEIGHT = 18
    local yPos = -(HEADER_HEIGHT + GAP)
    for i = 1, DISPELLER_BAR_POOL_SIZE do
        local bar = dispellerBars[i]
        local entry = dispelRotation[i]

        if entry then
            local ready, remaining = IsDispellerReady(i)
            local unit = rotationUnitMap[i]
            local isDead = unit and UnitExists(unit) and UnitIsDeadOrGhost(unit)

            if isDead then
                bar:Hide()
                bar._active = false
            else
                bar._active = true
                bar:ClearAllPoints()
                bar:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 4, yPos)
                bar:SetSize(barWidth - 8, barHeight)
                bar:Show()
                yPos = yPos - BAR_SPACING

                -- Number + name
                local dispelSpellName = entry.dispelName or (entry.class and DISPEL_SPELLS[entry.class] and DISPEL_SPELLS[entry.class].name) or "Dispel"
                bar.nameText:SetText(string.format("|cFFFFFFFF%d|r  %s |cFF888888(%s)|r", i, entry.name or "?", dispelSpellName))

                -- Ready/CD text
                if ready then
                    bar.cdText:SetText("|cFF00FF00OK|r")
                    bar:SetStatusBarColor(0.15, 0.5, 0.15)
                    bar:SetValue(1)
                else
                    bar.cdText:SetText(string.format("|cFFFF4444%.0fs|r", remaining))
                    bar:SetStatusBarColor(0.5, 0.1, 0.1)
                    bar:SetValue(remaining / (entry.cd or 8))
                end

                -- Gold border for active dispeller (don't override CD color)
                if i == activeIdx then
                    bar.goldBorder:Show()
                    if ready then
                        bar:SetStatusBarColor(0.2, 0.7, 0.2)
                    end
                else
                    bar.goldBorder:Hide()
                end
            end
        else
            bar:Hide()
            bar._active = false
        end
    end

    -- Update debuff entries (positioned below bars)
    local entryIdx = 0
    yPos = yPos - GAP

    for unit, unitDebuffs in pairs(activeDebuffs) do
        for auraInstanceID, debuff in pairs(unitDebuffs) do
            entryIdx = entryIdx + 1
            if entryIdx > DEBUFF_ENTRY_POOL_SIZE then break end

            local entry = debuffEntries[entryIdx]
            entry._active = true
            entry:ClearAllPoints()
            entry:SetPoint("TOPLEFT", anchorFrame, "TOPLEFT", 4, yPos)
            entry:SetSize(barWidth - 8, 16)
            entry:Show()
            yPos = yPos - ENTRY_HEIGHT

            local unitName = "?"
            local ok, name = pcall(UnitName, unit)
            if ok and name and not issecretvalue(name) then
                unitName = name
            end

            local remaining = debuff.expirationTime > 0 and (debuff.expirationTime - now) or 0
            local timeStr = remaining > 0 and string.format("(%.0fs)", remaining) or ""
            local typeColor = debuff.dispelType == "Magic" and "FF3399FF"
                or debuff.dispelType == "Curse" and "FF9933FF"
                or debuff.dispelType == "Disease" and "FFCC9900"
                or debuff.dispelType == "Poison" and "FF33CC33"
                or "FFAAAAAA"

            entry.text:SetText(string.format("  |cFFFFCC00*|r %s - |c%s%s|r %s",
                unitName, typeColor, debuff.name, timeStr))
        end
        if entryIdx >= DEBUFF_ENTRY_POOL_SIZE then break end
    end

    -- Hide unused entries
    for i = entryIdx + 1, DEBUFF_ENTRY_POOL_SIZE do
        debuffEntries[i]:Hide()
        debuffEntries[i]._active = false
    end

    -- Resize anchor frame to fit all content
    local totalHeight = math.abs(yPos) + GAP
    anchorFrame:SetSize(barWidth, totalHeight)
end

------------------------------------------------------------------------
-- Visibility State Machine
------------------------------------------------------------------------

local function TransitionTo(newState)
    if newState == visibilityState then return end
    local old = visibilityState
    visibilityState = newState

    if newState == "HIDDEN" then
        anchorFrame:Hide()
        for _, bar in ipairs(dispellerBars) do bar:Hide(); bar._active = false end
        for _, entry in ipairs(debuffEntries) do entry:Hide(); entry._active = false end
        onUpdateFrame:Hide()

    elseif newState == "ACTIVE" then
        if inactiveTimer then inactiveTimer:Cancel(); inactiveTimer = nil end
        anchorFrame:Show()
        anchorFrame:SetAlpha(1.0)
        onUpdateFrame:Show()
        DT:UpdateDisplay()
        DT:CheckAlert()

    elseif newState == "INACTIVE" then
        anchorFrame:SetAlpha(0.4)
        headerText:SetText("|cFFCC88FFDISPEL|r  |cFF00FF00All clear|r")
        -- Hide bars and debuff entries — just show the header
        for _, bar in ipairs(dispellerBars) do bar:Hide(); bar._active = false end
        for _, entry in ipairs(debuffEntries) do entry:Hide(); entry._active = false end
        onUpdateFrame:Hide()
        anchorFrame:SetSize(Config:Get("dispelBarWidth") or 200, 24)
        inactiveTimer = C_Timer.NewTimer(INACTIVE_FADE_SEC, function()
            TransitionTo("HIDDEN")
        end)
    end

    Log:Log("DEBUG", string.format("DispelTracker: %s → %s", old, newState))
end

local function UpdateVisibility()
    totalDebuffCount = CountTotalDebuffs()

    if totalDebuffCount > 0 then
        TransitionTo("ACTIVE")
    elseif visibilityState == "ACTIVE" then
        TransitionTo("INACTIVE")
    end
    -- INACTIVE → HIDDEN handled by timer
end

------------------------------------------------------------------------
-- Alert Sound
------------------------------------------------------------------------

function DT:CheckAlert()
    if not Config:Get("dispelAlertEnabled") then return end
    if totalDebuffCount == 0 then return end
    if #dispelRotation == 0 then return end

    -- Am I the next dispeller? (locked after each dispel event)
    local activeIdx = currentIdx
    if not activeIdx then return end
    local entry = dispelRotation[activeIdx]
    if not entry then return end

    local playerName = UnitName("player")
    if entry.name ~= playerName then return end

    -- Debounce
    local now = GetTime()
    if now - lastAlertTime < ALERT_DEBOUNCE_SEC then return end
    lastAlertTime = now

    -- Play sound (built-in WoW sound, no external dependency)
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    Log:Log("INFO", "DispelTracker: ALERT — your turn to dispel!")
end

------------------------------------------------------------------------
-- Addon Comms (sync dispel rotation across group members running HexCD)
------------------------------------------------------------------------

local function GetAddonChannel()
    if IsInRaid() then return "RAID"
    elseif IsInGroup() then return "PARTY"
    end
    return nil
end

local function BroadcastDispelCast(casterName, spellID)
    if not commsRegistered then return end
    local channel = GetAddonChannel()
    if not channel then return end
    local msg = "DISPEL:" .. casterName .. ":" .. spellID
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        Log:Log("DEBUG", "DispelTracker: broadcast dispel from " .. casterName)
    else
        Log:Log("DEBUG", "DispelTracker: broadcast failed: " .. tostring(err))
    end
end

--- Broadcast the current dispel rotation to group members running HexCD
function DT:BroadcastRotation()
    if not commsRegistered then
        print("|cFFFF0000[HexCD]|r Comms not registered — are you in a group?")
        return
    end
    local channel = GetAddonChannel()
    if not channel then
        print("|cFFFF0000[HexCD]|r Not in a group — cannot broadcast.")
        return
    end
    local names = {}
    for _, r in ipairs(dispelRotation) do
        table.insert(names, r.name)
    end
    local msg = "ROTATION:" .. table.concat(names, ",")
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        print("|cFFCC88FF[HexCD]|r Dispel rotation broadcast to group.")
        Log:Log("INFO", "DispelTracker: broadcast rotation: " .. table.concat(names, " > "))
    else
        print("|cFFFF0000[HexCD]|r Broadcast failed: " .. tostring(err))
    end
end

local function HandleDispelByName(casterName, spellID)
    casterName = StripRealm(casterName)
    local now = GetTime()
    Log:Log("INFO", string.format("DispelTracker: %s used dispel (spell %s) at %.2f", casterName, tostring(spellID), now))

    -- Record CD for the caster regardless of whose turn it is
    for i, entry in ipairs(dispelRotation) do
        if entry.name == casterName then
            local cd = entry.cd or 8
            dispelCDState[i] = {
                lastTime = now,
                readyTime = now + cd,
            }
            Log:Log("DEBUG", string.format("  CD recorded: #%d %s → ready at %.2f (cd=%ds)", i, casterName, now + cd, cd))
            break
        end
    end

    -- Debug: dump CD states (only players with active CDs)
    for i, entry in ipairs(dispelRotation) do
        local s = dispelCDState[i]
        if s then
            local rem = s.readyTime - now
            Log:Log("DEBUG", string.format("  CDState[%d] %s: ready=%.2f rem=%.1fs %s", i, entry.name, s.readyTime, rem, rem > 0 and "ON CD" or "READY"))
        end
    end

    -- Recompute next: whoever has the lowest CD (soonest ready), locked until next dispel
    local prevIdx = currentIdx
    currentIdx = GetLowestCDIdx()
    -- Reset alert debounce when it becomes a new player's turn
    if currentIdx ~= prevIdx then
        lastAlertTime = 0
    end
    Log:Log("DEBUG", string.format("Dispel next locked to #%d (%s)",
        currentIdx, dispelRotation[currentIdx] and dispelRotation[currentIdx].name or "?"))
end

local function HandleAddonMessage(prefix, message, _, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end

    local senderShort = StripRealm(sender)

    -- Ignore our own broadcast — we already handled it locally
    local playerName = UnitName("player")
    if senderShort == playerName then return end

    -- Handle "ROTATION:Name1,Name2,Name3"
    local rotationNames = message:match("^ROTATION:(.+)$")
    if rotationNames then
        Log:Log("INFO", "DispelTracker: received rotation from " .. senderShort .. ": " .. rotationNames)
        Config:Set("dispelEnabled", true)
        DT:SetRotation(rotationNames)
        print(string.format("|cFFCC88FF[HexCD]|r Dispel rotation received from %s: %s", senderShort, rotationNames))
        return
    end

    -- Parse "DISPEL:PlayerName:spellID"
    local msgType, casterName, spellIDStr = message:match("^(%w+):(.+):(%d+)$")
    if msgType ~= "DISPEL" then return end

    local spellID = tonumber(spellIDStr)
    if not DISPEL_SPELL_IDS[spellID] then return end

    HandleDispelByName(casterName, spellID)
end

------------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "HexCDDispelTrackerFrame")

eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    -- CHAT_MSG_ADDON must be processed even if dispelEnabled is off
    -- (the prefix is only registered when dispelEnabled, so this is safe)
    if event == "CHAT_MSG_ADDON" then
        if Config:Get("dispelEnabled") then
            HandleAddonMessage(...)
        end
        return
    end

    if not Config:Get("dispelEnabled") then return end

    if event == "UNIT_AURA" then
        local unit = ...
        if not groupUnits[unit] and unit ~= "player" then return end
        ScanUnitAuras(unit)
        UpdateVisibility()

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        -- Only handle player's own casts (UNIT_SPELLCAST_SUCCEEDED doesn't
        -- fire reliably for other group members). Other players' dispels
        -- arrive via CHAT_MSG_ADDON from their HexCD instance.
        if unit == "player" and DISPEL_SPELL_IDS[spellID] then
            local playerName = UnitName("player")
            HandleDispelByName(playerName, spellID)
            BroadcastDispelCast(playerName, spellID)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        DT:RebuildGroupMapping()
    end
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function DT:GetRotationNames()
    local names = {}
    for _, r in ipairs(dispelRotation) do
        table.insert(names, r.name)
    end
    return names
end

function DT:Reset()
    wipe(activeDebuffs)
    wipe(dispelCDState)
    currentIdx = 1
    totalDebuffCount = 0
    TransitionTo("HIDDEN")
end

function DT:Unlock()
    if anchorFrame then
        anchorFrame:EnableMouse(true)
        anchorFrame:Show()
        anchorFrame:SetAlpha(1.0)
        print("|cFFCC88FF[HexCD]|r Dispel tracker unlocked — drag to reposition.")
    end
end

function DT:Lock()
    if anchorFrame then
        anchorFrame:EnableMouse(false)
        if visibilityState == "HIDDEN" then
            anchorFrame:Hide()
        end
        print("|cFFCC88FF[HexCD]|r Dispel tracker locked.")
    end
end

function DT:IsUnlocked()
    return anchorFrame and anchorFrame:IsMouseEnabled() or false
end

function DT:ToggleLock()
    if self:IsUnlocked() then self:Lock() else self:Unlock() end
end

--- Test helper: simulate debuffs for development
--- @param duration number|nil Duration in seconds (default 15)
--- @param count number|nil Number of debuffs to simulate (default 2)
function DT:SimulateDebuffs(duration, count)
    duration = duration or 15
    count = count or 2
    if count < 1 then count = 1 end
    if #dispelRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set dispel rotation first: /hexcd dispelorder Name1,Name2,Name3")
        return
    end

    local now = GetTime()
    wipe(activeDebuffs)

    -- Spread debuffs across available units
    local units = { "player", "party1", "party2", "party3", "party4" }
    for i = 1, count do
        local unit = units[((i - 1) % #units) + 1]
        if not activeDebuffs[unit] then activeDebuffs[unit] = {} end
        activeDebuffs[unit][100 + i] = {
            name = "Test Debuff " .. i,
            dispelType = "Magic",
            expirationTime = now + duration,
            duration = duration + 10,
        }
    end

    totalDebuffCount = count
    TransitionTo("ACTIVE")
    print(string.format("|cFFCC88FF[HexCD]|r Dispel test: %d simulated debuffs. Will auto-expire in %ds.", count, duration))

    -- Auto-clear after duration
    C_Timer.After(duration, function()
        wipe(activeDebuffs)
        totalDebuffCount = 0
        UpdateVisibility()
    end)
end

--- Test helper: simulate a specific player's dispel cast
function DT:SimulateCastFrom(name)
    if #dispelRotation == 0 then return end
    local playerName = UnitName("player")
    -- Find the entry for this name to get their spellID
    local spellID = 88423 -- fallback
    for _, entry in ipairs(dispelRotation) do
        if entry.name == name then
            spellID = entry.spellID or 88423
            break
        end
    end
    if name == playerName then
        HandleDispelByName(name, spellID)
    else
        local fakeMessage = "DISPEL:" .. name .. ":" .. spellID
        local fakeSender = name .. "-FakeRealm"
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end

    -- Remove one simulated debuff (real UNIT_AURA does this, but test mode has no aura events)
    local removed = false
    for unit, unitDebuffs in pairs(activeDebuffs) do
        for id in pairs(unitDebuffs) do
            unitDebuffs[id] = nil
            removed = true
            break
        end
        if removed then break end
    end
    totalDebuffCount = CountTotalDebuffs()
    UpdateVisibility()

    print(string.format("|cFFCC88FF[HexCD]|r Simulated %s dispel (%d debuffs left)", name, totalDebuffCount))
end

--- Test helper: simulate receiving an addon comm from another player's dispel
--- This lets you test the full rotation-advance + comms flow without a second client.
function DT:SimulateIncomingComms()
    if #dispelRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set dispel rotation first: /hexcd dispelorder Name1,Name2,Name3")
        return
    end

    -- Find the current active dispeller
    local activeIdx = GetNextAliveIdx(currentIdx)
    if not activeIdx then
        print("|cFFFF0000[HexCD]|r No active dispeller in rotation")
        return
    end

    local entry = dispelRotation[activeIdx]
    local playerName = UnitName("player")

    -- If the current dispeller is the player, simulate THEIR cast locally
    -- (in real play this fires via UNIT_SPELLCAST_SUCCEEDED)
    if entry.name == playerName then
        local spellID = entry.spellID or 88423 -- fallback to Nature's Cure
        print(string.format("|cFFCC88FF[HexCD]|r Simulating YOUR dispel cast (%s, spell %d)", entry.name, spellID))
        HandleDispelByName(entry.name, spellID)
        -- In real play we'd also broadcast, but skip that for solo test
    else
        -- Simulate receiving a CHAT_MSG_ADDON from the other player
        local spellID = entry.spellID or 88423
        local fakeMessage = "DISPEL:" .. entry.name .. ":" .. spellID
        local fakeSender = entry.name .. "-FakeRealm"
        print(string.format("|cFFCC88FF[HexCD]|r Simulating incoming comm: %s dispelled (spell %d)", entry.name, spellID))
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end

    -- Show who's next now
    local newActiveIdx = GetNextAliveIdx(currentIdx)
    if newActiveIdx and dispelRotation[newActiveIdx] then
        print(string.format("|cFFCC88FF[HexCD]|r Next dispeller: #%d %s", newActiveIdx, dispelRotation[newActiveIdx].name))
    end
end

--- Test helper: expose internal state for assertions
--- @return table { bars = dispellerBars, cdState = dispelCDState, currentIdx = number, rotation = dispelRotation }
function DT:_testGetState()
    return {
        bars = dispellerBars,
        cdState = dispelCDState,
        currentIdx = currentIdx,
        rotation = dispelRotation,
        visibilityState = visibilityState,
    }
end
