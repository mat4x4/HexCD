------------------------------------------------------------------------
-- HexCD: Kick Tracker
-- Shows an interrupt rotation overlay during combat.
-- Detects own kicks via UNIT_SPELLCAST_SUCCEEDED, others via addon comms.
--
-- States: HIDDEN (out of combat) → ACTIVE (in combat with rotation set)
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.KickTracker = {}

local KT = HexCD.KickTracker
local Config = HexCD.Config
local Log = HexCD.DebugLog

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local KICK_SPELLS = {
    ["Death Knight"] = { spellID = 47528,  name = "Mind Freeze",       cd = 15 },
    ["Demon Hunter"] = { spellID = 183752, name = "Disrupt",           cd = 15 },
    ["Druid"]        = { spellID = 106839, name = "Skull Bash",        cd = 15 },
    ["Evoker"]       = { spellID = 351338, name = "Quell",             cd = 40 },
    ["Hunter"]       = { spellID = 147362, name = "Counter Shot",      cd = 24 },
    ["Mage"]         = { spellID = 2139,   name = "Counterspell",      cd = 24 },
    ["Monk"]         = { spellID = 116705, name = "Spear Hand Strike", cd = 15 },
    ["Paladin"]      = { spellID = 96231,  name = "Rebuke",            cd = 15 },
    ["Priest"]       = { spellID = 15487,  name = "Silence",           cd = 45 },
    ["Rogue"]        = { spellID = 1766,   name = "Kick",              cd = 15 },
    ["Shaman"]       = { spellID = 57994,  name = "Wind Shear",        cd = 12 },
    ["Warlock"]      = { spellID = 119910, name = "Spell Lock",        cd = 24 },
    ["Warrior"]      = { spellID = 6552,   name = "Pummel",            cd = 15 },
}

-- Secondary interrupts (long CD) — tracked if used but not the primary rotation spell
local KICK_SPELLS_SECONDARY = {
    [78675]  = { class = "Druid",   name = "Solar Beam",        cd = 60 },
    [187707] = { class = "Hunter",  name = "Muzzle",            cd = 15 },
    [386071] = { class = "Warrior", name = "Disrupting Shout",  cd = 90 },
}

-- Reverse lookup: spellID → { class, name, cd }
local KICK_SPELL_IDS = {}
for class, info in pairs(KICK_SPELLS) do
    KICK_SPELL_IDS[info.spellID] = { class = class, name = info.name, cd = info.cd }
end
for spellID, info in pairs(KICK_SPELLS_SECONDARY) do
    KICK_SPELL_IDS[spellID] = info
end

--- Strip realm suffix from a player name ("Name-Realm" → "Name")
local function StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

local BAR_POOL_SIZE = 6
local ALERT_DEBOUNCE_SEC = 2
local UPDATE_THROTTLE = 0.2
local ADDON_MSG_PREFIX = "HexCD"
local commsRegistered = false

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------

local kickRotation = {}         -- { {name, class, spellID, cd, kickName}, ... }
local currentIdx = 1            -- who's next in rotation
local kickCDState = {}          -- rotationIdx → {lastTime, readyTime}
local visibilityState = "HIDDEN"
local lastAlertTime = 0
local inCombat = false

-- Frame pools
local kickerBars = {}           -- pre-allocated bar frames
local anchorFrame = nil
local headerText = nil
local onUpdateFrame = nil
local onUpdateThrottle = 0

-- Group unit mapping
local groupUnits = {}           -- unit tokens for current group
local rotationUnitMap = {}      -- rotationIdx → unitToken

------------------------------------------------------------------------
-- Bar Creation
------------------------------------------------------------------------

local function CreateKickerBar(index)
    local bar = CreateFrame("StatusBar", "HexCDKickBar" .. index, nil, "BackdropTemplate")
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

    -- Number + name text (left)
    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", 6, 0)
    nameText:SetPoint("RIGHT", cdText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    bar.nameText = nameText

    -- Gold border for active kicker
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

------------------------------------------------------------------------
-- Anchor Frame
------------------------------------------------------------------------

local function CreateAnchor()
    local f = CreateFrame("Frame", "HexCDKickAnchor", UIParent, "BackdropTemplate")
    f:SetSize(210, 24)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.08, 0.08, 0.12, 0.9)
    f:SetBackdropBorderColor(0.3, 0.5, 0.7, 0.8)

    headerText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    headerText:SetPoint("TOPLEFT", 8, -4)
    headerText:SetPoint("RIGHT", -8, 0)
    headerText:SetJustifyH("LEFT")
    headerText:SetText("|cFF88CCFFKICK|r")

    -- Position from config
    local point = Config:Get("kickAnchorPoint") or "CENTER"
    local x = Config:Get("kickAnchorX") or -300
    local y = Config:Get("kickAnchorY") or 0
    f:SetPoint(point, UIParent, point, x, y)

    -- Draggable
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, px, py = self:GetPoint()
        Config:Set("kickAnchorPoint", p)
        Config:Set("kickAnchorX", px)
        Config:Set("kickAnchorY", py)
    end)

    f:Hide()
    return f
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

function KT:Init()
    anchorFrame = CreateAnchor()

    for i = 1, BAR_POOL_SIZE do
        kickerBars[i] = CreateKickerBar(i)
        kickerBars[i]:SetParent(anchorFrame)
    end

    -- Register addon message prefix (idempotent — DispelTracker may have already done this)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, err = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_MSG_PREFIX)
        if ok then
            commsRegistered = true
            Log:Log("DEBUG", "KickTracker: addon comms registered (prefix: " .. ADDON_MSG_PREFIX .. ")")
        else
            -- Already registered by DispelTracker — that's fine
            commsRegistered = true
            Log:Log("DEBUG", "KickTracker: addon comms prefix already registered")
        end
    end

    -- OnUpdate frame for CD ticking (only runs in ACTIVE state)
    onUpdateFrame = CreateFrame("Frame", "HexCDKickOnUpdate")
    onUpdateFrame:Hide()
    onUpdateFrame:SetScript("OnUpdate", function(_, elapsed)
        onUpdateThrottle = onUpdateThrottle + elapsed
        if onUpdateThrottle < UPDATE_THROTTLE then return end
        onUpdateThrottle = 0
        KT:UpdateDisplay()
    end)

    -- Load rotation from saved config
    local saved = Config:Get("kickRotation")
    if saved and #saved > 0 then
        KT:SetRotation(saved)
    end

    Log:Log("DEBUG", "KickTracker initialized")
end

------------------------------------------------------------------------
-- Rotation Management
------------------------------------------------------------------------

function KT:SetRotation(names)
    kickRotation = {}
    if type(names) == "string" then
        for name in names:gmatch("[^,]+") do
            name = StripRealm(name:match("^%s*(.-)%s*$"))
            table.insert(kickRotation, { name = name, class = nil })
        end
    elseif type(names) == "table" then
        for _, entry in ipairs(names) do
            if type(entry) == "string" then
                table.insert(kickRotation, { name = entry, class = nil })
            elseif type(entry) == "table" then
                table.insert(kickRotation, entry)
            end
        end
    end

    KT:RebuildGroupMapping()

    currentIdx = 1
    wipe(kickCDState)

    -- Save to config
    local saveData = {}
    for _, r in ipairs(kickRotation) do
        table.insert(saveData, { name = r.name, class = r.class })
    end
    Config:Set("kickRotation", saveData)

    local names_str = {}
    for _, r in ipairs(kickRotation) do
        table.insert(names_str, r.name)
    end
    Log:Log("INFO", "Kick rotation set: " .. table.concat(names_str, " > "))
    print("|cFF88CCFF[HexCD]|r Kick rotation: " .. table.concat(names_str, " > "))
end

function KT:RebuildGroupMapping()
    wipe(groupUnits)
    wipe(rotationUnitMap)

    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    elseif IsInGroup() then
        prefix, count = "party", GetNumGroupMembers() - 1
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

    for i, entry in ipairs(kickRotation) do
        for unit in pairs(groupUnits) do
            local ok, unitName = pcall(UnitName, unit)
            if ok and StripRealm(unitName) == entry.name then
                rotationUnitMap[i] = unit
                if not entry.class then
                    local _, className = UnitClass(unit)
                    if className and not issecretvalue(className) then
                        entry.class = className:sub(1,1):upper() .. className:sub(2):lower()
                    end
                end
                -- Resolve kick spell info
                if entry.class and KICK_SPELLS[entry.class] then
                    local info = KICK_SPELLS[entry.class]
                    entry.spellID = info.spellID
                    entry.cd = info.cd
                    entry.kickName = info.name
                end
                break
            end
        end
    end
end

------------------------------------------------------------------------
-- Rotation Logic
------------------------------------------------------------------------

local function IsKickerReady(idx)
    local state = kickCDState[idx]
    if not state then return true, 0 end
    local remaining = state.readyTime - GetTime()
    if remaining <= 0 then return true, 0 end
    return false, remaining
end

local function GetNextAliveIdx(startIdx)
    if #kickRotation == 0 then return nil end
    local idx = startIdx
    for _ = 1, #kickRotation do
        local unit = rotationUnitMap[idx]
        if unit and UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            return idx
        end
        idx = (idx % #kickRotation) + 1
    end
    return startIdx
end

-- Pick the alive kicker with the lowest readyTime (soonest off CD).
-- Tiebreaker: rotation order (lower index wins).
-- Called after each kick to lock in who goes next.
local function GetLowestCDIdx()
    if #kickRotation == 0 then return 1 end
    local now = GetTime()
    local bestIdx = nil
    local bestReadyTime = math.huge

    for i = 1, #kickRotation do
        local unit = rotationUnitMap[i]
        local alive = not unit or (UnitExists(unit) and not UnitIsDeadOrGhost(unit))
        if alive then
            local state = kickCDState[i]
            local readyTime = state and state.readyTime or 0
            -- Clamp: all ready players are equal at 0, rotation order breaks tie
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

function KT:UpdateDisplay()
    if visibilityState == "HIDDEN" then return end
    if #kickRotation == 0 then return end

    local now = GetTime()
    local barWidth = Config:Get("kickBarWidth") or 210
    local barHeight = Config:Get("kickBarHeight") or 20

    -- Active kicker is locked after each kick event (lowest CD wins)
    local activeIdx = currentIdx

    -- Update header
    local nextName = (activeIdx and kickRotation[activeIdx]) and kickRotation[activeIdx].name or "?"
    headerText:SetText("|cFF88CCFFKICK|r  |cFFFFCC00" .. nextName .. "'s turn|r")

    local HEADER_HEIGHT = 20
    local GAP = 4
    local BAR_SPACING = barHeight + 4
    local yPos = -(HEADER_HEIGHT + GAP)
    for i = 1, BAR_POOL_SIZE do
        local bar = kickerBars[i]
        local entry = kickRotation[i]

        if entry then
            local ready, remaining = IsKickerReady(i)
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

                local kickSpellName = entry.kickName or (entry.class and KICK_SPELLS[entry.class] and KICK_SPELLS[entry.class].name) or "Interrupt"
                bar.nameText:SetText(string.format("|cFFFFFFFF%d|r  %s |cFF888888(%s)|r", i, entry.name or "?", kickSpellName))

                if ready then
                    bar.cdText:SetText("|cFF00FF00OK|r")
                    bar:SetStatusBarColor(0.15, 0.4, 0.55)
                    bar:SetValue(1)
                else
                    bar.cdText:SetText(string.format("|cFFFF4444%.0fs|r", remaining))
                    bar:SetStatusBarColor(0.5, 0.1, 0.1)
                    bar:SetValue(remaining / (entry.cd or 15))
                end

                -- Gold border for active kicker (don't override CD color)
                if i == activeIdx then
                    bar.goldBorder:Show()
                    if ready then
                        bar:SetStatusBarColor(0.2, 0.5, 0.7)
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

    -- Resize anchor
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
        for _, bar in ipairs(kickerBars) do bar:Hide(); bar._active = false end
        onUpdateFrame:Hide()

    elseif newState == "ACTIVE" then
        anchorFrame:Show()
        anchorFrame:SetAlpha(1.0)
        onUpdateFrame:Show()
        KT:UpdateDisplay()
        KT:CheckAlert()
    end

    Log:Log("DEBUG", string.format("KickTracker: %s → %s", old, newState))
end

------------------------------------------------------------------------
-- Alert Sound
------------------------------------------------------------------------

function KT:CheckAlert()
    if not Config:Get("kickAlertEnabled") then return end
    if #kickRotation == 0 then return end

    -- Active kicker is locked after each kick event
    local activeIdx = currentIdx
    local entry = kickRotation[activeIdx]
    if not entry then return end

    local playerName = UnitName("player")
    if entry.name ~= playerName then return end

    local now = GetTime()
    if now - lastAlertTime < ALERT_DEBOUNCE_SEC then return end
    lastAlertTime = now

    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    Log:Log("INFO", "KickTracker: ALERT — your turn to kick!")
end

------------------------------------------------------------------------
-- Addon Comms
------------------------------------------------------------------------

local function GetAddonChannel()
    if IsInRaid() then return "RAID"
    elseif IsInGroup() then return "PARTY"
    end
    return nil
end

local function BroadcastKickCast(casterName, spellID)
    if not commsRegistered then return end
    local channel = GetAddonChannel()
    if not channel then return end
    local msg = "KICK:" .. casterName .. ":" .. spellID
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        Log:Log("DEBUG", "KickTracker: broadcast kick from " .. casterName)
    else
        Log:Log("DEBUG", "KickTracker: broadcast failed: " .. tostring(err))
    end
end

function KT:BroadcastRotation()
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
    for _, r in ipairs(kickRotation) do
        table.insert(names, r.name)
    end
    local msg = "KICKROTATION:" .. table.concat(names, ",")
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        print("|cFF88CCFF[HexCD]|r Kick rotation broadcast to group.")
        Log:Log("INFO", "KickTracker: broadcast rotation: " .. table.concat(names, " > "))
    else
        print("|cFFFF0000[HexCD]|r Broadcast failed: " .. tostring(err))
    end
end

local function HandleKickByName(casterName, spellID)
    casterName = StripRealm(casterName)
    Log:Log("INFO", string.format("KickTracker: %s used kick (spell %s)", casterName, tostring(spellID)))

    -- Look up actual CD from spell database (handles varied CDs)
    local spellInfo = KICK_SPELL_IDS[spellID]
    local spellCD = spellInfo and spellInfo.cd or 15

    -- Record CD for the caster regardless of whose turn it is
    for i, entry in ipairs(kickRotation) do
        if entry.name == casterName then
            kickCDState[i] = {
                lastTime = GetTime(),
                readyTime = GetTime() + spellCD,
            }
            break
        end
    end

    -- Recompute next: whoever has the lowest CD (soonest ready), locked until next kick
    local prevIdx = currentIdx
    currentIdx = GetLowestCDIdx()
    if currentIdx ~= prevIdx then
        lastAlertTime = 0
    end
    Log:Log("DEBUG", string.format("Kick next locked to #%d (%s)",
        currentIdx, kickRotation[currentIdx] and kickRotation[currentIdx].name or "?"))
end

local function HandleAddonMessage(prefix, message, _, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end

    local senderShort = StripRealm(sender)

    local playerName = UnitName("player")
    if senderShort == playerName then return end

    -- Handle "KICKROTATION:Name1,Name2,Name3"
    local rotationNames = message:match("^KICKROTATION:(.+)$")
    if rotationNames then
        Log:Log("INFO", "KickTracker: received rotation from " .. senderShort .. ": " .. rotationNames)
        Config:Set("kickEnabled", true)
        KT:SetRotation(rotationNames)
        print(string.format("|cFF88CCFF[HexCD]|r Kick rotation received from %s: %s", senderShort, rotationNames))
        return
    end

    -- Parse "KICK:PlayerName:spellID"
    local msgType, casterName, spellIDStr = message:match("^(%w+):(.+):(%d+)$")
    if msgType ~= "KICK" then return end

    local spellID = tonumber(spellIDStr)
    if not KICK_SPELL_IDS[spellID] then return end

    HandleKickByName(casterName, spellID)
end

------------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "HexCDKickTrackerFrame")

eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        if Config:Get("kickEnabled") then
            HandleAddonMessage(...)
        end
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        if Config:Get("kickEnabled") and #kickRotation > 0 then
            TransitionTo("ACTIVE")
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        TransitionTo("HIDDEN")
        return
    end

    if not Config:Get("kickEnabled") then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" and KICK_SPELL_IDS[spellID] then
            local playerName = UnitName("player")
            HandleKickByName(playerName, spellID)
            BroadcastKickCast(playerName, spellID)
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        KT:RebuildGroupMapping()
    end
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function KT:GetRotationNames()
    local names = {}
    for _, r in ipairs(kickRotation) do
        table.insert(names, r.name)
    end
    return names
end

function KT:Reset()
    wipe(kickCDState)
    currentIdx = 1
    TransitionTo("HIDDEN")
end

function KT:Unlock()
    if anchorFrame then
        anchorFrame:EnableMouse(true)
        anchorFrame:Show()
        anchorFrame:SetAlpha(1.0)
        print("|cFF88CCFF[HexCD]|r Kick tracker unlocked — drag to reposition.")
    end
end

function KT:Lock()
    if anchorFrame then
        anchorFrame:EnableMouse(false)
        if visibilityState == "HIDDEN" then
            anchorFrame:Hide()
        end
        print("|cFF88CCFF[HexCD]|r Kick tracker locked.")
    end
end

function KT:IsUnlocked()
    return anchorFrame and anchorFrame:IsMouseEnabled() or false
end

function KT:ToggleLock()
    if self:IsUnlocked() then self:Lock() else self:Unlock() end
end

--- Test helper: show the kick UI for a duration (default 15s)
--- @param duration number|nil Duration in seconds
function KT:SimulateKicks(duration, _count)
    duration = duration or 15
    if #kickRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set kick rotation first: /hexcd kickorder Name1,Name2,Name3")
        return
    end
    TransitionTo("ACTIVE")
    print(string.format("|cFF88CCFF[HexCD]|r Kick test: UI shown for %ds.", duration))

    C_Timer.After(duration, function()
        if not inCombat then
            TransitionTo("HIDDEN")
        end
    end)
end

--- Test helper: simulate a specific player's kick cast
function KT:SimulateCastFrom(name)
    if #kickRotation == 0 then return end
    local playerName = UnitName("player")
    local spellID = 6552 -- fallback to Pummel
    for _, entry in ipairs(kickRotation) do
        if entry.name == name then
            spellID = entry.spellID or 6552
            break
        end
    end
    if name == playerName then
        HandleKickByName(name, spellID)
    else
        local fakeMessage = "KICK:" .. name .. ":" .. spellID
        local fakeSender = name .. "-FakeRealm"
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end
    print(string.format("|cFF88CCFF[HexCD]|r Simulated %s kick", name))
end

--- Test helper: simulate an incoming kick from the current active kicker
function KT:SimulateIncomingComms()
    if #kickRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set kick rotation first: /hexcd kickorder Name1,Name2,Name3")
        return
    end

    local activeIdx = GetNextAliveIdx(currentIdx)
    if not activeIdx then
        print("|cFFFF0000[HexCD]|r No active kicker in rotation")
        return
    end

    local entry = kickRotation[activeIdx]
    local playerName = UnitName("player")

    if entry.name == playerName then
        local spellID = entry.spellID or 6552
        print(string.format("|cFF88CCFF[HexCD]|r Simulating YOUR kick (%s, spell %d)", entry.name, spellID))
        HandleKickByName(entry.name, spellID)
    else
        local spellID = entry.spellID or 6552
        local fakeMessage = "KICK:" .. entry.name .. ":" .. spellID
        local fakeSender = entry.name .. "-FakeRealm"
        print(string.format("|cFF88CCFF[HexCD]|r Simulating incoming comm: %s kicked (spell %d)", entry.name, spellID))
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end

    if kickRotation[currentIdx] then
        print(string.format("|cFF88CCFF[HexCD]|r Next kicker: #%d %s", currentIdx, kickRotation[currentIdx].name))
    end
end
