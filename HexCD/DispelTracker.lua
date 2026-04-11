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
-- Per-Group State (2 groups for raid use)
------------------------------------------------------------------------

local MAX_GROUPS = 2

local function NewGroupState()
    return {
        rotation = {},          -- { {name, class, spellID, cd}, ... }
        currentIdx = 1,
        cdState = {},           -- rotationIdx → {lastTime, readyTime}
        unitMap = {},           -- rotationIdx → unitToken
        visibilityState = "HIDDEN",
        inactiveTimer = nil,
        lastAlertTime = 0,
        -- UI (created lazily)
        bars = {},
        debuffEntries = {},
        anchorFrame = nil,
        headerText = nil,
        onUpdateFrame = nil,
        onUpdateThrottle = 0,
    }
end

local groups = { NewGroupState(), NewGroupState() }
local myGroupIdx = nil          -- which group the local player is in (nil = none)

-- Shared state (not per-group)
local activeDebuffs = {}        -- unit → { auraInstanceID → {name, dispelType, expirationTime} }
local totalDebuffCount = 0
local groupUnits = {}           -- unit tokens for current group

-- Backward-compat aliases — point to group 1 for code that hasn't been refactored yet
local dispelRotation = groups[1].rotation
local currentIdx = groups[1].currentIdx
local dispelCDState = groups[1].cdState
local dispellerBars = groups[1].bars
local debuffEntries = groups[1].debuffEntries
local anchorFrame = groups[1].anchorFrame
local headerText = groups[1].headerText
local visibilityState = groups[1].visibilityState
local inactiveTimer = groups[1].inactiveTimer
local lastAlertTime = groups[1].lastAlertTime
local onUpdateFrame = groups[1].onUpdateFrame
local onUpdateThrottle = groups[1].onUpdateThrottle
local rotationUnitMap = groups[1].unitMap

------------------------------------------------------------------------
-- Bar Creation (follows TimerBars.lua pattern)
------------------------------------------------------------------------

local function CreateDispellerBar(index)
    return Util.CreateTrackerBar("HexCDDispelBar" .. index)
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

local dispelAnchorCount = 0
local function CreateAnchor(pointKey, xKey, yKey, defaultX, defaultY)
    dispelAnchorCount = dispelAnchorCount + 1
    pointKey = pointKey or "dispelAnchorPoint"
    xKey = xKey or "dispelAnchorX"
    yKey = yKey or "dispelAnchorY"
    defaultX = defaultX or 300
    defaultY = defaultY or 0
    return Util.CreateTrackerAnchor("HexCDDispelAnchor" .. dispelAnchorCount, {0.08, 0.08, 0.12}, {0.4, 0.3, 0.6}, "CENTER", defaultX, defaultY, pointKey, xKey, yKey)
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

function DT:Init()
    -- Create UI for both groups
    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        local suffix = gi == 1 and "" or "2"
        local defY = gi == 1 and 0 or -80
        gs.anchorFrame = CreateAnchor("dispelAnchorPoint" .. suffix, "dispelAnchorX" .. suffix, "dispelAnchorY" .. suffix, 300, defY)

        gs.bars = {}
        for i = 1, DISPELLER_BAR_POOL_SIZE do
            gs.bars[i] = CreateDispellerBar(i)
            gs.bars[i]:SetParent(gs.anchorFrame)
        end

        gs.debuffEntries = {}
        for i = 1, DEBUFF_ENTRY_POOL_SIZE do
            gs.debuffEntries[i] = CreateDebuffEntry(i)
            gs.debuffEntries[i]:SetParent(gs.anchorFrame)
        end

        gs.headerText = gs.anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gs.headerText:SetPoint("TOP", 0, -2)
    end

    -- Backward compat aliases
    anchorFrame = groups[1].anchorFrame
    dispellerBars = groups[1].bars
    debuffEntries = groups[1].debuffEntries
    headerText = groups[1].headerText

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
    if onUpdateFrame then onUpdateFrame:Hide() end
    onUpdateFrame:SetScript("OnUpdate", function(_, elapsed)
        onUpdateThrottle = onUpdateThrottle + elapsed
        if onUpdateThrottle < UPDATE_THROTTLE then return end
        onUpdateThrottle = 0
        DT:UpdateDisplay()
    end)

    -- Load rotation from saved config, or auto-enroll
    local saved = Config:Get("dispelRotation")
    if saved and #saved > 0 then
        DT:SetRotation(saved)
    end
    local saved2 = Config:Get("dispelRotation2")
    if saved2 and #saved2 > 0 then
        DT:SetRotation(saved2, 2)
    end
    DT:AutoEnroll()

    Log:Log("DEBUG", "DispelTracker initialized")
end

------------------------------------------------------------------------
-- Rotation Management
------------------------------------------------------------------------

--- Helper to get config key for a group (group 1 uses base key, group 2 appends "2")
local function CfgKey(base, gi)
    if gi == 1 or not gi then return base end
    return base .. tostring(gi)
end

--- Resolve which group the local player is in
local function ResolveMyGroup()
    local playerName = StripRealm(UnitName("player") or "")
    for gi = 1, MAX_GROUPS do
        for _, entry in ipairs(groups[gi].rotation) do
            if entry.name == playerName then
                myGroupIdx = gi
                return
            end
        end
    end
    myGroupIdx = nil
end

function DT:SetRotation(names, groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    gs.rotation = {}

    if type(names) == "string" then
        for name in names:gmatch("[^,]+") do
            name = StripRealm(name:match("^%s*(.-)%s*$"))
            table.insert(gs.rotation, { name = name, class = nil })
        end
    elseif type(names) == "table" then
        for _, entry in ipairs(names) do
            if type(entry) == "string" then
                table.insert(gs.rotation, { name = entry, class = nil })
            elseif type(entry) == "table" then
                table.insert(gs.rotation, entry)
            end
        end
    end

    -- Keep backward-compat alias for group 1
    if groupIdx == 1 then dispelRotation = gs.rotation end

    DT:RebuildGroupMapping()

    gs.currentIdx = 1
    wipe(gs.cdState)
    if groupIdx == 1 then currentIdx = 1; dispelCDState = gs.cdState end

    -- Save to config
    local saveData = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(saveData, { name = r.name, class = r.class })
    end
    Config:Set(CfgKey("dispelRotation", groupIdx), saveData)

    ResolveMyGroup()

    local names_str = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names_str, r.name)
    end
    local groupLabel = groupIdx > 1 and (" (group " .. groupIdx .. ")") or ""
    Log:Log("INFO", "Dispel rotation set" .. groupLabel .. ": " .. table.concat(names_str, " > "))
    print("|cFFCC88FF[HexCD]|r Dispel rotation" .. groupLabel .. ": " .. table.concat(names_str, " > "))
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

    -- Map rotation entries to unit tokens by name (all groups)
    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        wipe(gs.unitMap)
        for i, entry in ipairs(gs.rotation) do
            for unit in pairs(groupUnits) do
                local ok, unitName = pcall(UnitName, unit)
                if ok and StripRealm(unitName) == entry.name then
                    gs.unitMap[i] = unit
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
    -- Keep backward-compat alias
    rotationUnitMap = groups[1].unitMap
end

------------------------------------------------------------------------
-- Aura Scanning
------------------------------------------------------------------------

local function IsDispellableAura(aura)
    if not aura then return false end
    if not aura.isHarmful then return false end
    -- In Midnight, dispelName may be a secret value — that's OK, it means
    -- the debuff IS dispellable (Blizzard only secrets the value, not its existence).
    -- A nil dispelName means not dispellable. A non-nil (even secret) means dispellable.
    if aura.dispelName == nil then return false end
    return true
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
            local auraName = "Debuff"
            pcall(function() if not issecretvalue(aura.name) then auraName = aura.name end end)
            local dispelType = "Magic"
            pcall(function() if not issecretvalue(aura.dispelName) then dispelType = aura.dispelName end end)
            unitDebuffs[aura.auraInstanceID] = {
                name = auraName,
                dispelType = dispelType,
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
    local now = GetTime()
    totalDebuffCount = CountTotalDebuffs()
    local barWidth = Config:Get("dispelBarWidth") or 200
    local barHeight = Config:Get("dispelBarHeight") or 20

    -- Determine which group shows debuff entries (player's group, or group 1)
    local debuffGroupIdx = myGroupIdx or 1

    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        if not gs.anchorFrame then break end

        if gs.visibilityState == "HIDDEN" or #gs.rotation == 0 then
            if gs.anchorFrame then gs.anchorFrame:Hide() end
            for _, bar in ipairs(gs.bars) do bar:Hide(); bar._active = false end
            for _, entry in ipairs(gs.debuffEntries) do entry:Hide(); entry._active = false end
        else
            gs.anchorFrame:Show()

            local activeIdx = gs.currentIdx
            local nextName = (activeIdx and gs.rotation[activeIdx]) and gs.rotation[activeIdx].name or "?"
            local groupTag = gi > 1 and (" G" .. gi) or ""
            if totalDebuffCount > 0 and gi == debuffGroupIdx then
                gs.headerText:SetText("|cFFCC88FFDISPEL" .. groupTag .. "|r  |cFFFFCC00" .. nextName .. "'s turn|r  |cFFFF8800[" .. totalDebuffCount .. "]|r")
            else
                gs.headerText:SetText("|cFFCC88FFDISPEL" .. groupTag .. "|r  |cFFFFCC00" .. nextName .. "'s turn|r")
            end

            local HEADER_HEIGHT = 20
            local GAP = 4
            local BAR_SPACING = barHeight + 4
            local ENTRY_HEIGHT = 18
            local yPos = -(HEADER_HEIGHT + GAP)

            for i = 1, DISPELLER_BAR_POOL_SIZE do
                local bar = gs.bars[i]
                local entry = gs.rotation[i]

                if entry then
                    local ready = true
                    local remaining = 0
                    local state = gs.cdState[i]
                    if state then
                        remaining = math.max(0, state.readyTime - now)
                        ready = remaining <= 0
                    end
                    local unit = gs.unitMap[i]
                    local isDead = unit and UnitExists(unit) and UnitIsDeadOrGhost(unit)

                    if isDead then
                        bar:Hide()
                        bar._active = false
                    else
                        bar._active = true
                        bar:ClearAllPoints()
                        bar:SetPoint("TOPLEFT", gs.anchorFrame, "TOPLEFT", 4, yPos)
                        bar:SetSize(barWidth - 8, barHeight)
                        bar:Show()
                        yPos = yPos - BAR_SPACING

                        local dispelSpellName = entry.dispelName or (entry.class and DISPEL_SPELLS[entry.class] and DISPEL_SPELLS[entry.class].name) or "Dispel"
                        bar.nameText:SetText(string.format("|cFFFFFFFF%d|r  %s |cFF888888(%s)|r", i, entry.name or "?", dispelSpellName))

                        if ready then
                            bar.cdText:SetText("|cFF00FF00OK|r")
                            bar:SetStatusBarColor(0.15, 0.5, 0.15)
                            bar:SetValue(1)
                        else
                            bar.cdText:SetText(string.format("|cFFFF4444%.0fs|r", remaining))
                            bar:SetStatusBarColor(0.5, 0.1, 0.1)
                            bar:SetValue(remaining / (entry.cd or 8))
                        end

                        if i == activeIdx then
                            bar.goldBorder:Show()
                            if ready then bar:SetStatusBarColor(0.2, 0.7, 0.2) end
                        else
                            bar.goldBorder:Hide()
                        end
                    end
                else
                    bar:Hide()
                    bar._active = false
                end
            end

            -- Hide debuff entries (rotation bars are sufficient)
            for _, de in ipairs(gs.debuffEntries) do de:Hide(); de._active = false end

            local totalHeight = math.abs(yPos) + GAP
            gs.anchorFrame:SetSize(barWidth, totalHeight)
        end
    end
end

------------------------------------------------------------------------
-- Visibility State Machine
------------------------------------------------------------------------

local function TransitionTo(newState)
    if newState == visibilityState then return end
    local old = visibilityState
    visibilityState = newState
    for gi = 1, MAX_GROUPS do
        groups[gi].visibilityState = newState
    end

    if newState == "HIDDEN" then
        for gi = 1, MAX_GROUPS do
            local gs = groups[gi]
            if gs.anchorFrame then gs.anchorFrame:Hide() end
            for _, bar in ipairs(gs.bars) do bar:Hide(); bar._active = false end
            for _, entry in ipairs(gs.debuffEntries) do entry:Hide(); entry._active = false end
        end
        if onUpdateFrame then onUpdateFrame:Hide() end

    elseif newState == "ACTIVE" then
        if inactiveTimer then inactiveTimer:Cancel(); inactiveTimer = nil end
        for gi = 1, MAX_GROUPS do
            local gs = groups[gi]
            if gs.anchorFrame and #gs.rotation > 0 then
                gs.anchorFrame:Show()
                gs.anchorFrame:SetAlpha(1.0)
            end
        end
        if onUpdateFrame then onUpdateFrame:Show() end
        DT:UpdateDisplay()
        -- Do NOT CheckAlert on combat entry — only alert on actual dispel events

    elseif newState == "INACTIVE" then
        for gi = 1, MAX_GROUPS do
            local gs = groups[gi]
            if gs.anchorFrame then
                gs.anchorFrame:SetAlpha(0.4)
                if gs.headerText then
                    local groupTag = gi > 1 and (" G" .. gi) or ""
                    gs.headerText:SetText("|cFFCC88FFDISPEL" .. groupTag .. "|r  |cFF00FF00All clear|r")
                end
                for _, bar in ipairs(gs.bars) do bar:Hide(); bar._active = false end
                for _, entry in ipairs(gs.debuffEntries) do entry:Hide(); entry._active = false end
                gs.anchorFrame:SetSize(Config:Get("dispelBarWidth") or 200, 24)
            end
        end
        if onUpdateFrame then onUpdateFrame:Hide() end
        inactiveTimer = C_Timer.NewTimer(INACTIVE_FADE_SEC, function()
            TransitionTo("HIDDEN")
        end)
    end

    Log:Log("DEBUG", string.format("DispelTracker: %s → %s", old, newState))
end

local function UpdateVisibility()
    totalDebuffCount = CountTotalDebuffs()
    -- Visibility is now combat-driven (PLAYER_REGEN_DISABLED/ENABLED).
    -- This function just updates the debuff count for display purposes.
end

------------------------------------------------------------------------
-- Alert Sound
------------------------------------------------------------------------

function DT:CheckAlert()
    if not Config:Get("dispelAlertEnabled") then return end
    if visibilityState ~= "ACTIVE" then return end
    if #dispelRotation == 0 then return end

    -- Am I the next dispeller? (locked after each dispel event)
    local activeIdx = currentIdx
    if not activeIdx then return end
    local entry = dispelRotation[activeIdx]
    if not entry then return end

    local playerName = UnitName("player")
    if entry.name ~= playerName then return end

    -- Only alert if CD is ready
    local ready, remaining = IsDispellerReady(activeIdx)
    if not ready then
        Log:Log("DEBUG", string.format("DispelTracker: alert skipped — CD not ready (%.1fs remaining)", remaining))
        return
    end

    -- Debounce
    local now = GetTime()
    if now - lastAlertTime < ALERT_DEBOUNCE_SEC then return end
    lastAlertTime = now

    -- Play multiple sounds to ensure audibility
    local alertText = Config:Get("dispelAlertText") or "Dispel"
    Util.SpeakTTS(alertText)
    Log:Log("INFO", "DispelTracker: ALERT — TTS: " .. alertText)
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

local function BroadcastDispelCast(casterName, spellID, groupIdx)
    if not commsRegistered then return end
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end

    local channel = GetAddonChannel()
    if not channel then return end
    local tag = "DISPEL" .. (groupIdx or 1)
    local msg = tag .. ":" .. casterName .. ":" .. spellID
    local ok, ret = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok and ret ~= 0 then
        Log:Log("DEBUG", "DispelTracker: broadcast dispel from " .. casterName .. " (group " .. (groupIdx or 1) .. ")")
        return
    end

    -- Fallback: whisper each member individually
    for i = 1, GetNumGroupMembers() do
        local unit = (IsInRaid() and "raid" or "party") .. i
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local target = realm and realm ~= "" and (name .. "-" .. realm) or name
            pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, "WHISPER", target)
        end
    end
end

--- Broadcast the current dispel rotation to group members running HexCD
function DT:BroadcastRotation(groupIdx)
    groupIdx = groupIdx or 1
    if not commsRegistered then
        print("|cFFFF0000[HexCD]|r Comms not registered — are you in a group?")
        return
    end
    local channel = GetAddonChannel()
    if not channel then
        print("|cFFFF0000[HexCD]|r Not in a group — cannot broadcast.")
        return
    end
    local gs = groups[groupIdx]
    local names = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names, r.name)
    end
    local tag = "ROTATION" .. groupIdx
    local msg = tag .. ":" .. table.concat(names, ",")
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        local groupLabel = groupIdx > 1 and (" (group " .. groupIdx .. ")") or ""
        print("|cFFCC88FF[HexCD]|r Dispel rotation" .. groupLabel .. " broadcast to group.")
        Log:Log("INFO", "DispelTracker: broadcast rotation" .. groupLabel .. ": " .. table.concat(names, " > "))
    else
        print("|cFFFF0000[HexCD]|r Broadcast failed: " .. tostring(err))
    end
end

local function HandleDispelByName(casterName, spellID, groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    casterName = StripRealm(casterName)
    local now = GetTime()
    Log:Log("INFO", string.format("DispelTracker: %s used dispel (spell %s) group %d at %.2f", casterName, tostring(spellID), groupIdx, now))

    -- Record CD for the caster regardless of whose turn it is
    for i, entry in ipairs(gs.rotation) do
        if entry.name == casterName then
            local cd = entry.cd or 8
            gs.cdState[i] = {
                lastTime = now,
                readyTime = now + cd,
            }
            Log:Log("DEBUG", string.format("  CD recorded: #%d %s → ready at %.2f (cd=%ds)", i, casterName, now + cd, cd))
            break
        end
    end

    -- Advance rotation (shared logic: only if current person cast, 15s inactivity reset)
    local didAdvance = Util.AdvanceRotation(gs, casterName, GetNextAliveIdx, function(g)
        if groupIdx == 1 then currentIdx = g.currentIdx; dispelCDState = g.cdState end
    end, "Dispel", function() DT:CheckAlert() end)

    -- Only re-alert if rotation actually changed (avoid duplicate TTS on out-of-order casts)
    if didAdvance then
        DT:CheckAlert()
    end

    -- Schedule a re-check when the player's CD expires
    local playerName = StripRealm(UnitName("player") or "")
    local myEntry = gs.rotation[gs.currentIdx]
    if myEntry and myEntry.name == playerName then
        local state = gs.cdState[gs.currentIdx]
        if state and state.readyTime then
            local remaining = state.readyTime - GetTime()
            if remaining > 0 then
                C_Timer.After(remaining + 0.1, function()
                    Log:Log("DEBUG", "DispelTracker: CD expired timer — re-checking alert")
                    DT:CheckAlert()
                end)
            end
        end
    end
end

local function HandleAddonMessage(prefix, message, _, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end

    local senderShort = StripRealm(sender)

    -- Ignore our own broadcast — we already handled it locally
    local playerName = UnitName("player")
    if senderShort == playerName then return end

    -- Handle "ROTATION1:Name1,Name2" or "ROTATION2:Name1,Name2" or legacy "ROTATION:Name1,Name2"
    local rotGi, rotationNames = message:match("^ROTATION(%d?):(.+)$")
    if rotationNames then
        local gi = tonumber(rotGi) or 1
        Log:Log("INFO", string.format("DispelTracker: received rotation group %d from %s: %s", gi, senderShort, rotationNames))
        Config:Set("dispelEnabled", true)
        DT:SetRotation(rotationNames, gi)
        local groupLabel = gi > 1 and (" (group " .. gi .. ")") or ""
        print(string.format("|cFFCC88FF[HexCD]|r Dispel rotation%s received from %s: %s", groupLabel, senderShort, rotationNames))
        return
    end

    -- Parse "DISPEL1:Name:spellID" or "DISPEL2:Name:spellID" or legacy "DISPEL:Name:spellID"
    local dispGi, casterName, spellIDStr = message:match("^DISPEL(%d?):(.+):(%d+)$")
    if casterName and spellIDStr then
        local gi = tonumber(dispGi) or 1
        local spellID = tonumber(spellIDStr)
        if not DISPEL_SPELL_IDS[spellID] then return end
        HandleDispelByName(casterName, spellID, gi)
    end
end

------------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "HexCDDispelTrackerFrame")

eventFrame:RegisterEvent("UNIT_AURA")
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
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
            ResolveMyGroup()
            local gi = myGroupIdx or 1
            HandleDispelByName(playerName, spellID, gi)
            BroadcastDispelCast(playerName, spellID, gi)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Entering combat — show tracker
        local hasRotation = false
        for gi = 1, MAX_GROUPS do
            if #groups[gi].rotation > 0 then hasRotation = true; break end
        end
        if hasRotation then
            TransitionTo("ACTIVE")
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Leaving combat — hide tracker
        TransitionTo("HIDDEN")

    elseif event == "GROUP_ROSTER_UPDATE" then
        DT:RebuildGroupMapping()
        DT:AutoEnroll()
    end
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Auto-enroll dispellers based on group composition.
--- Only sets rotation if no manual rotation exists for group 1.
--- Party: all healer-spec dispellers. Raid: all healers.
function DT:AutoEnroll()
    if not IsInGroup() then return end

    local comp = Util.ScanGroupComposition()
    if #comp.dispellers == 0 then return end

    -- Build set of current group members
    local groupMemberSet = {}
    for _, n in ipairs(comp.dispellers) do groupMemberSet[n] = true end
    for _, n in ipairs(comp.kickers or {}) do groupMemberSet[n] = true end
    -- Also add all names from the scan
    for _, n in ipairs(comp.healers or {}) do groupMemberSet[n] = true end

    -- Always clean up stale group 2 (old party/test data)
    local g2names = self:GetRotationNames(2)
    for _, n in ipairs(g2names) do
        if not groupMemberSet[n] then
            groups[2].rotation = {}
            groups[2].currentIdx = 1
            wipe(groups[2].cdState)
            Config:Set("dispelRotation2", {})
            Log:Log("DEBUG", "DispelTracker: cleared stale group 2")
            break
        end
    end

    -- Check if group 1 rotation is stale
    local currentNames = self:GetRotationNames(1)
    local stale = (#currentNames == 0)
    if not stale then
        for _, n in ipairs(currentNames) do
            if not groupMemberSet[n] then stale = true; break end
        end
    end

    if stale then

        DT:SetRotation(comp.dispellers, 1)
        Log:Log("INFO", "DispelTracker: auto-enrolled " .. #comp.dispellers .. " dispellers")
    end
end

function DT:GetRotationNames(groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    local names = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names, r.name)
    end
    return names
end

function DT:GetMyGroup()
    ResolveMyGroup()
    return myGroupIdx
end

function DT:Reset()
    wipe(activeDebuffs)
    wipe(dispelCDState)
    currentIdx = 1
    totalDebuffCount = 0
    TransitionTo("HIDDEN")
end

function DT:Unlock()
    for gi = 1, MAX_GROUPS do
        local af = groups[gi].anchorFrame
        if af then af:EnableMouse(true); af:Show(); af:SetAlpha(1.0) end
    end
    print("|cFFCC88FF[HexCD]|r Dispel tracker unlocked — drag to reposition.")
end

function DT:Lock()
    for gi = 1, MAX_GROUPS do
        local af = groups[gi].anchorFrame
        if af then
            af:EnableMouse(false)
            if visibilityState == "HIDDEN" then af:Hide() end
        end
    end
    print("|cFFCC88FF[HexCD]|r Dispel tracker locked.")
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
    local playerName = UnitName("player")
    -- Find which group this player is in and their spellID
    local spellID = 88423
    local targetGroup = 1
    for gi = 1, MAX_GROUPS do
        for _, entry in ipairs(groups[gi].rotation) do
            if entry.name == name then
                spellID = entry.spellID or 88423
                targetGroup = gi
                break
            end
        end
    end

    if name == playerName then
        HandleDispelByName(name, spellID, targetGroup)
    else
        local tag = "DISPEL" .. targetGroup
        local fakeMessage = tag .. ":" .. name .. ":" .. spellID
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
--- @param groupIdx number|nil (default 1)
--- @return table
function DT:_testGetState(groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    return {
        bars = gs.bars,
        cdState = gs.cdState,
        currentIdx = gs.currentIdx,
        rotation = gs.rotation,
        visibilityState = gs.visibilityState,
    }
end

--- Test helper: get current rotation state for assertions
function DT:_testGetQueueState()
    local gs = groups[1]
    return {
        currentIdx = gs.currentIdx,
        rotation = gs.rotation,
        cdState = gs.cdState,
    }
end

--- Test helper: directly handle a dispel cast for a specific group
function DT:_testHandleDispel(name, spellID, groupIdx)
    HandleDispelByName(name, spellID, groupIdx or 1)
end

--- Test helper: inject an addon message
function DT:_testInjectMessage(msg, sender)
    HandleAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY", sender or "Test-Realm")
end
