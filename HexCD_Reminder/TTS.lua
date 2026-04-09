------------------------------------------------------------------------
-- HexCD: Text-to-Speech + Sound System
--
-- Countdown via PlaySoundFile with pre-recorded .ogg number files
-- (CC0 Public Domain, from BigWigs project).
--
-- Voice roles:
--   Jim (.ogg)  → ALL countdowns (5,4,3,2,1)
--   Amy (TTS)   → Spell/ramp announcements after countdown
--   Default TTS → Fallback if Amy voice not found
--
-- C_VoiceChat.SpeakText has a known out-of-order queue bug, so we
-- NEVER queue multiple TTS calls. Countdown uses PlaySoundFile which
-- has no ordering issues.
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.TTS = {}

local TTS = HexCDReminder.TTS
local Config = HexCDReminder.Config
local Log = HexCDReminder.DebugLog

local DEDUP_WINDOW = 4.0
local lastSpeakTime = 0
local lastSpeakText = ""

-- Sound file paths (bundled .ogg, 1-5) — Jim voice for ALL countdowns
local SOUND_BASE = "Interface\\AddOns\\HexCD\\Sounds\\"

local COUNTDOWN_SOUNDS = {
    [1] = SOUND_BASE .. "Jim\\1.ogg",
    [2] = SOUND_BASE .. "Jim\\2.ogg",
    [3] = SOUND_BASE .. "Jim\\3.ogg",
    [4] = SOUND_BASE .. "Jim\\4.ogg",
    [5] = SOUND_BASE .. "Jim\\5.ogg",
}

-- Sequence ID for Jim countdown sounds (increments on each new countdown — cancels
-- overlapping number sounds so only the latest "5,4,3,2,1" plays cleanly)
local countdownSeqID = 0
-- Separate sequence ID for Amy announcements (only increments on Stop — so that
-- a new countdown does NOT cancel a pending spell name announcement from an earlier CD)
local announceSeqID = 0

-- Amy voice ID cache (resolved once on first use)
local amyVoiceID = nil
local amyVoiceResolved = false
local defaultVoiceID = nil

------------------------------------------------------------------------
-- Voice resolution
------------------------------------------------------------------------

--- Find a TTS voice by name pattern (case-insensitive)
---@param pattern string  e.g. "Amy"
---@return number|nil voiceID
local function FindVoiceByName(pattern)
    if not (C_VoiceChat and C_VoiceChat.GetTtsVoices) then return nil end
    local voices = C_VoiceChat.GetTtsVoices()
    if not voices then return nil end
    local lowerPattern = pattern:lower()
    for _, v in ipairs(voices) do
        if v.name and v.name:lower():find(lowerPattern) then
            Log:Log("DEBUG", string.format("TTS voice found: '%s' (id=%d) for pattern '%s'", v.name, v.voiceID, pattern))
            return v.voiceID
        end
    end
    return nil
end

--- Get the default TTS voice ID
---@return number
local function GetDefaultVoice()
    if defaultVoiceID then return defaultVoiceID end
    local id = 0
    if C_TTSSettings and C_TTSSettings.GetVoiceOptionID then
        id = C_TTSSettings.GetVoiceOptionID(0) or 0
    end
    if id == 0 and C_VoiceChat and C_VoiceChat.GetTtsVoices then
        local voices = C_VoiceChat.GetTtsVoices()
        if voices and #voices > 0 then
            id = voices[1].voiceID or 0
        end
    end
    defaultVoiceID = id
    return id
end

--- Get Amy's voice ID (cached after first lookup)
---@return number voiceID  (falls back to default if Amy not found)
local function GetAmyVoice()
    if not amyVoiceResolved then
        amyVoiceResolved = true
        amyVoiceID = FindVoiceByName("Amy")
        if amyVoiceID then
            Log:Log("INFO", string.format("Amy voice resolved: id=%d", amyVoiceID))
        else
            Log:Log("INFO", "Amy voice not found — using default TTS voice for announcements")
        end
    end
    return amyVoiceID or GetDefaultVoice()
end

------------------------------------------------------------------------
-- TTS (voice announcements)
------------------------------------------------------------------------

--- Direct TTS call with a specific voice ID + optional raid warning
---@param text string
---@param voiceID number
---@param showRaidWarning boolean|nil (default true)
local function SpeakWithVoice(text, voiceID, showRaidWarning)
    if showRaidWarning == nil then showRaidWarning = true end
    local spoke = false

    if C_VoiceChat and C_VoiceChat.SpeakText then
        local rate = Config:Get("ttsRate") or 3
        local volume = Config:Get("ttsVolume") or 100

        local ok, err = pcall(function()
            C_VoiceChat.SpeakText(voiceID, text, rate, volume, true)
        end)
        if ok then
            spoke = true
        else
            Log:Log("DEBUG", "TTS API error: " .. tostring(err))
        end
    end

    if showRaidWarning then
        local color = "|cFFFF8800"
        if text:find("Ramp") then
            color = "|cFFFFCC00"
        elseif text:find("Cat") then
            color = "|cFF44EE44"
        end
        RaidNotice_AddMessage(RaidWarningFrame, color .. ">> " .. text .. " <<|r", ChatTypeInfo["RAID_WARNING"])
    end

    if spoke then
        Log:Log("TRACE", "TTS spoke: " .. text)
    else
        Log:Log("DEBUG", "TTS chat-only: " .. text)
    end

    lastSpeakTime = GetTime()
    lastSpeakText = text
end

--- Direct TTS call — sends text to the default voice engine + raid warning
---@param text string
---@param showRaidWarning boolean|nil (default true)
function TTS:SpeakDirect(text, showRaidWarning)
    SpeakWithVoice(text, GetDefaultVoice(), showRaidWarning)
end

--- Announce via Amy voice — used for spell/ramp announcements after countdown
---@param text string
---@param showRaidWarning boolean|nil (default true)
function TTS:Announce(text, showRaidWarning)
    SpeakWithVoice(text, GetAmyVoice(), showRaidWarning)
end

--- Speak text with dedup (uses default voice)
---@param text string
---@param cd table|nil optional CD entry for override lookup
function TTS:Speak(text, cd)
    if not Config:Get("ttsEnabled") then return end
    if not text or text == "" then return end

    if cd then
        local override = Config:GetCDOverride(
            cd.encounterID or 0,
            cd.timeSec or 0,
            cd.abilityGameID or 0
        )
        if override then
            if override.enabled == false then
                Log:Log("DEBUG", string.format("TTS:Speak blocked by override: '%s' (disabled)", text))
                return
            end
            if override.ttsText and override.ttsText ~= "" then
                Log:Log("DEBUG", string.format("TTS:Speak override: '%s' → '%s'", text, override.ttsText))
                text = override.ttsText
            end
        end
    end

    local now = GetTime()
    if text == lastSpeakText and (now - lastSpeakTime) < DEDUP_WINDOW then
        Log:Log("TRACE", string.format("TTS:Speak dedup: '%s' (%.1fs since last)", text, now - lastSpeakTime))
        return
    end

    self:Announce(text, true)
end

------------------------------------------------------------------------
-- Sound countdown (PlaySoundFile — no ordering issues)
------------------------------------------------------------------------

--- Start a countdown: raid warning + "5","4","3","2","1" sound files (Jim voice)
--- followed by Amy TTS announcing the spell name.
---
---@param label string  ability name e.g. "Ramp" or "Convoke the Spirits"
---@param seconds number  countdown from (max 5)
---@param cd table|nil  optional CD entry for override check
function TTS:Countdown(label, seconds, cd)
    if not Config:Get("ttsEnabled") then return end
    seconds = math.min(seconds, 5)

    -- Check per-CD override
    if cd then
        local override = Config:GetCDOverride(
            cd.encounterID or 0,
            cd.timeSec or 0,
            cd.abilityGameID or 0
        )
        if override and override.enabled == false then
            Log:Log("DEBUG", string.format("Countdown blocked by override: '%s' @ %ds (disabled)", label, cd.timeSec or 0))
            return
        end
    end

    countdownSeqID = countdownSeqID + 1

    local mySeqID = countdownSeqID

    -- Show ability name on raid warning frame (visual only, no TTS voice yet)
    local color = "|cFFFF8800"
    if label:find("Ramp") then color = "|cFFFFCC00"
    elseif label:find("Cat") then color = "|cFF44EE44" end
    RaidNotice_AddMessage(RaidWarningFrame, color .. ">> " .. label .. " <<|r", ChatTypeInfo["RAID_WARNING"])
    Log:Log("INFO", string.format("COUNTDOWN: '%s' %d→1 [Jim] (seqID=%d)",
        label, seconds, mySeqID))

    -- Play first number immediately (e.g. "5")
    local path = COUNTDOWN_SOUNDS[seconds]
    if path then
        PlaySoundFile(path, "Master")
        Log:Log("TRACE", string.format("  PlaySound: %s (%d)", path, seconds))
    end

    -- Schedule remaining numbers on 1-second intervals
    for i = 1, seconds - 1 do
        local num = seconds - i  -- 4, 3, 2, 1
        C_Timer.After(i, function()
            if countdownSeqID ~= mySeqID then
                Log:Log("TRACE", string.format("  Countdown stale: seqID %d vs current %d — skipping %d",
                    mySeqID, countdownSeqID, num))
                return
            end
            local p = COUNTDOWN_SOUNDS[num]
            if p then PlaySoundFile(p, "Master") end
        end)
    end

    -- After countdown: Amy announces the spell name via TTS
    -- Uses announceSeqID (not countdownSeqID) so a newer countdown's Jim sounds
    -- don't cancel this CD's spell announcement.
    if Config:Get("announceEnabled") ~= false then
        local myAnnounceSeqID = announceSeqID
        C_Timer.After(seconds, function()
            if announceSeqID ~= myAnnounceSeqID then return end
            TTS:Announce(label, true)
            Log:Log("INFO", string.format("ANNOUNCE [Amy]: '%s'", label))
        end)
    end
end

------------------------------------------------------------------------
-- Stop
------------------------------------------------------------------------

--- Stop TTS playback and cancel all pending countdowns
function TTS:Stop()
    countdownSeqID = countdownSeqID + 1
    announceSeqID = announceSeqID + 1
    if C_VoiceChat and C_VoiceChat.StopSpeakingText then
        C_VoiceChat.StopSpeakingText()
    end
    Log:Log("DEBUG", "TTS:Stop — all countdowns cancelled")
end
