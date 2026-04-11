------------------------------------------------------------------------
-- HexCD: Shared Utilities
------------------------------------------------------------------------
local ADDON_NAME = ...
HexCD = HexCD or {}
HexCD.Util = {}

local Util = HexCD.Util

------------------------------------------------------------------------
-- Group state helpers (consistent across party / instance group / raid)
-- WoW has two group categories:
--   LE_PARTY_CATEGORY_HOME     (1 or nil) — normal invite
--   LE_PARTY_CATEGORY_INSTANCE (2)        — LFG / M+ / instance
-- IsInGroup() without args only checks HOME. M+ uses INSTANCE.
------------------------------------------------------------------------

--- True if the player is in any group (party, instance, or raid).
function Util.IsInAnyGroup()
    return (IsInGroup and (IsInGroup() or IsInGroup(2))) and true or false
end

--- True if the player is in a raid-sized group.
function Util.IsInRaid()
    return (IsInRaid and IsInRaid()) and true or false
end

--- Returns the addon message channel for the current group, or nil if solo.
--- Pre-formed M+ groups use PARTY even inside the instance.
--- LFG/matchmaking groups may need INSTANCE_CHAT.
--- Prefer PARTY first since it works for both normal and pre-formed M+ groups.
function Util.GetGroupChannel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    if IsInGroup and IsInGroup(2) then return "INSTANCE_CHAT" end
    return nil
end

--- Returns the unit prefix ("raid" or "party") and max count for iterating group members.
function Util.GetGroupUnitInfo()
    if IsInRaid and IsInRaid() then
        return "raid", 40
    else
        return "party", 4
    end
end

------------------------------------------------------------------------
-- Formatting helpers
------------------------------------------------------------------------

--- Format seconds into "M:SS" string
---@param sec number
---@return string
function Util.FormatTime(sec)
    if not sec or sec < 0 then return "0:00" end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    return string.format("%d:%02d", m, s)
end

--- Format seconds into "Xs" or "M:SS" depending on magnitude
---@param sec number
---@return string
function Util.FormatCountdown(sec)
    if not sec or sec < 0 then return "0" end
    if sec < 60 then
        return string.format("%.0f", sec)
    end
    return Util.FormatTime(sec)
end

--- Marker spell IDs per spec. Markers are planning-only signals (not real CDs).
--- Specs without markers use an empty table — all abilities are "burn".
Util.SPEC_MARKERS = {
    ["Druid:Restoration"] = {
        [774] = "fullRamp",   -- Ramp entry (pre-HoT setup window)
        [768] = "catWeave",   -- Cat Weave (mana recovery downtime)
    },
    -- Evoker:Preservation has no ramp markers — all CDs are direct burns
}

--- Current spec's marker table (set by SetSpecMarkers)
local activeMarkers = Util.SPEC_MARKERS["Druid:Restoration"] or {}

--- Switch active markers to match the player's spec.
---@param className string
---@param specName string
function Util.SetSpecMarkers(className, specName)
    local key = Util.NormalizeClassName(className) .. ":" .. specName
    activeMarkers = Util.SPEC_MARKERS[key] or {}
end

--- Detect ramp type from ability ID (source of truth)
--- Returns "fullRamp", "catWeave", or "burn" depending on current spec's markers.
---@param abilityGameID number
---@return string "fullRamp"|"burn"|"catWeave"
function Util.DetectRampType(abilityGameID)
    return activeMarkers[abilityGameID] or "burn"
end

--- Check if a spell ID is a marker (not a real CD) for the current spec.
---@param abilityGameID number
---@return boolean
function Util.IsMarkerSpell(abilityGameID)
    return activeMarkers[abilityGameID] ~= nil
end

--- Get ramp display label
---@param rampType string
---@return string
function Util.RampLabel(rampType)
    if rampType == "fullRamp" then
        return "RAMP"
    elseif rampType == "burn" then
        return "BURN"
    elseif rampType == "catWeave" then
        return "CAT"
    end
    return ""
end

--- Get player class and spec
---@return string className, string specName
function Util.GetPlayerSpec()
    local _, className = UnitClass("player")
    local specIndex = GetSpecialization()
    local specName = ""
    if specIndex then
        local _, name = GetSpecializationInfo(specIndex)
        specName = name or ""
    end
    return className, specName
end

--- Normalize class name for plan matching (e.g., "DRUID" → "Druid")
---@param className string
---@return string
function Util.NormalizeClassName(className)
    if not className then return "" end
    return className:sub(1, 1):upper() .. className:sub(2):lower()
end

--- Class colors for bar tinting
Util.CLASS_COLORS = {
    Druid   = { r = 1.00, g = 0.49, b = 0.04 },
    Shaman  = { r = 0.00, g = 0.44, b = 0.87 },
    Paladin = { r = 0.96, g = 0.55, b = 0.73 },
    Priest  = { r = 1.00, g = 1.00, b = 1.00 },
    Monk    = { r = 0.00, g = 1.00, b = 0.59 },
    Evoker  = { r = 0.20, g = 0.58, b = 0.50 },
}

--- Deep copy a table
---@param t table
---@return table
function Util.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = Util.DeepCopy(v)
    end
    return copy
end

------------------------------------------------------------------------
-- TTS Helper (simplified from HexCD_Reminder's TTS.lua)
------------------------------------------------------------------------

local ttsVoiceID = nil
local ttsVoiceResolved = false
local ttsVoiceConfigName = nil  -- tracks config to detect changes

--- Resolve TTS voice by name preference
local function ResolveTTSVoice()
    local Config = HexCD.Config
    local preferredName = Config and Config:Get("ttsVoiceName") or ""

    -- Re-resolve if config changed
    if ttsVoiceResolved and preferredName == ttsVoiceConfigName then return end
    ttsVoiceResolved = true
    ttsVoiceConfigName = preferredName
    ttsVoiceID = nil

    if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return end
    local voices = C_VoiceChat.GetTtsVoices()
    if not voices or #voices == 0 then return end

    -- Try user-configured voice first
    if preferredName and preferredName ~= "" then
        local lower = preferredName:lower()
        for _, v in ipairs(voices) do
            if v.name and v.name:lower():find(lower) then
                ttsVoiceID = v.voiceID
                return
            end
        end
    end

    -- Fallback: try Amy, then first available
    for _, v in ipairs(voices) do
        if v.name and v.name:lower():find("amy") then
            ttsVoiceID = v.voiceID
            return
        end
    end
    ttsVoiceID = voices[1].voiceID
end

--- Get list of available TTS voices (for GUI dropdown)
---@return table { {name, voiceID}, ... }
function Util.GetTTSVoices()
    local result = {}
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        local voices = C_VoiceChat.GetTtsVoices()
        if voices then
            for _, v in ipairs(voices) do
                table.insert(result, { name = v.name, voiceID = v.voiceID })
            end
        end
    end
    return result
end

--- Speak text via WoW TTS + show raid warning frame text
---@param text string
function Util.SpeakTTS(text)
    if not text or text == "" then return end

    ResolveTTSVoice()

    local Config = HexCD.Config
    local rate = Config and Config:Get("ttsRate") or 3
    local volume = Config and Config:Get("ttsVolume") or 100

    -- Speak via C_VoiceChat
    local Log = HexCD.DebugLog
    if C_VoiceChat and C_VoiceChat.SpeakText and ttsVoiceID ~= nil then
        local ok, err = pcall(C_VoiceChat.SpeakText, ttsVoiceID, text, rate, volume, true)
        if Log then Log:Log("DEBUG", string.format("TTS: voice=%d text='%s' rate=%d vol=%d ok=%s",
            ttsVoiceID, text, rate, volume, tostring(ok))) end
    else
        if Log then Log:Log("DEBUG", string.format("TTS SKIPPED: C_VoiceChat=%s SpeakText=%s voiceID=%s",
            tostring(C_VoiceChat ~= nil), tostring(C_VoiceChat and C_VoiceChat.SpeakText ~= nil), tostring(ttsVoiceID))) end
    end

    -- Also show raid warning text (visual fallback)
    if RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame,
            "|cFFFF8800>> " .. text .. " <<|r",
            ChatTypeInfo["RAID_WARNING"])
    end
end

------------------------------------------------------------------------
-- Rotation Advance Logic (shared between Dispel/Kick trackers)
------------------------------------------------------------------------

--- Advance rotation after a cast. Only advances if caster is the current person.
--- Starts a 5s inactivity timer to reset to position 1 silently.
---@param gs table Group state with .rotation, .currentIdx, .cdState, ._resetGeneration
---@param casterName string Name of the person who cast
---@param getNextAliveIdx function(startIdx) Returns next alive index
---@param backwardCompatUpdate function(gs) Optional: update backward-compat aliases
---@param trackerName string "Dispel" or "Kick" for logging
--- Returns: didAdvance (boolean) — true if currentIdx changed
function Util.AdvanceRotation(gs, casterName, getNextAliveIdx, backwardCompatUpdate, trackerName, checkAlertFn)
    local Log = HexCD.DebugLog

    -- Find caster's index
    local casterIdx = nil
    for i, entry in ipairs(gs.rotation) do
        if entry.name == casterName then casterIdx = i; break end
    end

    local prevIdx = gs.currentIdx
    -- Only advance if caster IS the current person
    if casterIdx == gs.currentIdx then
        local nextIdx = (gs.currentIdx % #gs.rotation) + 1
        gs.currentIdx = getNextAliveIdx(nextIdx) or 1
        if gs.currentIdx ~= casterIdx then
            gs.lastAlertTime = 0
        end
    end

    local didAdvance = (gs.currentIdx ~= prevIdx)
    if backwardCompatUpdate then backwardCompatUpdate(gs) end
    if Log then
        Log:Log("DEBUG", string.format("%s next locked to #%d (%s)",
            trackerName, gs.currentIdx, gs.rotation[gs.currentIdx] and gs.rotation[gs.currentIdx].name or "?"))
    end

    -- 5-second inactivity reset
    gs._resetGeneration = (gs._resetGeneration or 0) + 1
    local gen = gs._resetGeneration
    C_Timer.After(15, function()
        if gs._resetGeneration ~= gen then return end
        if gs.currentIdx ~= 1 then
            gs.currentIdx = getNextAliveIdx(1) or 1
            if backwardCompatUpdate then backwardCompatUpdate(gs) end
            if Log then
                Log:Log("DEBUG", string.format("%sTracker: 5s inactivity reset → #%d (%s)",
                    trackerName, gs.currentIdx, gs.rotation[gs.currentIdx] and gs.rotation[gs.currentIdx].name or "?"))
            end
            -- Silent reset — do NOT alert (user requested no TTS on reset)
        end
    end)

    return didAdvance
end

------------------------------------------------------------------------
-- Group Composition Helpers
------------------------------------------------------------------------

--- Classes that have healer dispels (magic)
local DISPEL_CLASSES = {
    DRUID = true, PRIEST = true, PALADIN = true, SHAMAN = true, MONK = true, EVOKER = true,
}

--- Classes that have interrupts
local INTERRUPT_CLASSES = {
    DRUID = true, MAGE = true, ROGUE = true, WARRIOR = true, DEATHKNIGHT = true,
    PALADIN = true, MONK = true, SHAMAN = true, DEMONHUNTER = true, EVOKER = true,
    HUNTER = false, WARLOCK = false, PRIEST = false,  -- no baseline interrupt
}

--- Scan group members and return lists for auto-enrollment.
--- @return table { dispellers = {name,...}, kickers = {name,...}, healers = {name,...}, isRaid = bool }
function Util.ScanGroupComposition()
    local result = { dispellers = {}, kickers = {}, healers = {}, isRaid = false }

    result.isRaid = Util.IsInRaid()

    local units = {}
    local prefix, maxCount = Util.GetGroupUnitInfo()
    if result.isRaid then
        for i = 1, maxCount do
            local unit = prefix .. i
            if UnitExists(unit) then table.insert(units, unit) end
        end
    else
        table.insert(units, "player")
        for i = 1, maxCount do
            local unit = prefix .. i
            if UnitExists(unit) then table.insert(units, unit) end
        end
    end

    for _, unit in ipairs(units) do
        -- Skip NPC followers/companions (follower dungeons)
        local isPlayer = (unit == "player")
        if not isPlayer then pcall(function() isPlayer = UnitIsPlayer(unit) end) end
        if isPlayer then
        local ok, name = pcall(UnitName, unit)
        if ok and name and name ~= "" and not (issecretvalue and issecretvalue(name)) then
            local shortName = name:match("^([^-]+)") or name
            local className
            pcall(function()
                local _, c = UnitClass(unit)
                if c and not issecretvalue(c) then className = c:upper() end
            end)
            -- Fallback: try UnitClassBase which returns just the token
            if not className then
                pcall(function()
                    local c = UnitClassBase and UnitClassBase(unit)
                    if c and not issecretvalue(c) then className = c:upper() end
                end)
            end
            if className then

                -- Check role
                local role = nil
                pcall(function()
                    role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
                end)
                local hasRole = role and role ~= "NONE" and role ~= ""

                local isHealer = (role == "HEALER")
                local isTank = (role == "TANK")

                if hasRole then
                    -- Roles are assigned (M+ queue, raid)
                    if isHealer and DISPEL_CLASSES[className] then
                        table.insert(result.dispellers, shortName)
                    end
                    if isHealer then
                        table.insert(result.healers, shortName)
                    end
                    if (isTank or not isHealer) and INTERRUPT_CLASSES[className] then
                        table.insert(result.kickers, shortName)
                    end
                else
                    -- No roles set (manual invite, open world)
                    -- Enroll everyone with the capability
                    if DISPEL_CLASSES[className] then
                        table.insert(result.dispellers, shortName)
                    end
                    if INTERRUPT_CLASSES[className] then
                        table.insert(result.kickers, shortName)
                    end
                end
            end
        end
        end -- if isPlayer
    end

    return result
end

------------------------------------------------------------------------
-- Shared Tracker UI Helpers
------------------------------------------------------------------------

--- Create a movable anchor frame for a tracker overlay.
---@param name string Global frame name
---@param bgColor table {r, g, b, a}
---@param borderColor table {r, g, b, a}
---@param defaultPoint string
---@param defaultX number
---@param defaultY number
---@param savedPointKey string Config key for saved position
---@param savedXKey string
---@param savedYKey string
---@return Frame
function Util.CreateTrackerAnchor(name, bgColor, borderColor, defaultPoint, defaultX, defaultY, savedPointKey, savedXKey, savedYKey)
    local Config = HexCD.Config
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(210, 80)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(bgColor[1], bgColor[2], bgColor[3], bgColor[4] or 0.9)
    f:SetBackdropBorderColor(borderColor[1], borderColor[2], borderColor[3], borderColor[4] or 0.8)
    f:SetMovable(true)
    f:EnableMouse(false)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, _, px, py = self:GetPoint()
        if Config then
            Config:Set(savedPointKey, p)
            Config:Set(savedXKey, px)
            Config:Set(savedYKey, py)
        end
    end)

    -- Restore saved position
    local savedP = Config and Config:Get(savedPointKey)
    if savedP then
        f:ClearAllPoints()
        f:SetPoint(savedP, UIParent, savedP,
            Config:Get(savedXKey) or defaultX,
            Config:Get(savedYKey) or defaultY)
    else
        f:SetPoint(defaultPoint, UIParent, defaultPoint, defaultX, defaultY)
    end

    f:Hide()
    return f
end

--- Create a status bar for a tracker rotation entry.
---@param name string Global frame name
---@return StatusBar
function Util.CreateTrackerBar(name)
    local bar = CreateFrame("StatusBar", name, nil, "BackdropTemplate")
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

    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.08, 0.9)
    bar.bg = bg

    local cdText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    cdText:SetPoint("RIGHT", -6, 0)
    cdText:SetJustifyH("RIGHT")
    bar.cdText = cdText

    local nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nameText:SetPoint("LEFT", 6, 0)
    nameText:SetPoint("RIGHT", cdText, "LEFT", -4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetWordWrap(false)
    nameText:SetMaxLines(1)
    bar.nameText = nameText

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
    return bar
end
