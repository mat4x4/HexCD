------------------------------------------------------------------------
-- HexCD: Cast Detector (Phase 1 — observation only)
--
-- Listens to UNIT_SPELLCAST_* events on hostile nameplates and writes a
-- structured line per event into HexCD.DebugLog. Goal: validate whether
-- mob cast detection is reliable enough in M+ and raid contexts to drive
-- a "kick when interruptable" alert (Phase 3).
--
-- This module is observation-only. It does NOT influence kick TTS,
-- rotation highlights, or any user-facing behavior.
--
-- Gating: Logs only when HexCDDB.logLevel == "DEBUG" or "TRACE". Default
-- INFO suppresses all cast lines, so enabling the detector in a raid run
-- has zero cost unless the user explicitly opts in via Settings.
--
-- Log line format (greppable, machine-parseable):
--   [CAST] ev=START unit=nameplate3 spellID=12345 name="Heal" \
--          dur=2500 nint=false src=cast
--
-- Fields:
--   ev      START | CHANNEL_START | STOP | CHANNEL_STOP |
--           SUCCEEDED | INTERRUPTED | FAILED | DELAYED | INTERRUPTIBLE |
--           NOT_INTERRUPTIBLE
--   unit    nameplate1..40
--   spellID Clean numeric ID (laundered through StatusBar trick if tainted)
--   name    Quoted spell name from C_Spell.GetSpellInfo, or "?" if secret
--   dur     Cast duration in milliseconds (START/CHANNEL_START only)
--   nint    notInterruptible raw flag from UnitCastingInfo (UNRELIABLE in
--           Midnight per MIDNIGHT-API-RESTRICTIONS.md:36 — captured for
--           verification, not as a gating signal)
--   src     "cast" or "channel" (which API the data came from)
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.CastDetector = {}

local CD = HexCD.CastDetector
local Log = HexCD.DebugLog

------------------------------------------------------------------------
-- Taint laundering (same trick as KickTracker:SafeGetKickData).
-- spellID from UNIT_SPELLCAST_* on nameplates may be a "secret value" in
-- Midnight 12.0 — passing it through StatusBar:SetValue causes the C++
-- side to re-emit a clean numeric value via OnValueChanged.
------------------------------------------------------------------------
local launderBar = CreateFrame("StatusBar")
launderBar:SetMinMaxValues(0, 9999999)
local _launderedID = nil
launderBar:SetScript("OnValueChanged", function(_, v) _launderedID = v end)

local function CleanSpellID(spellID)
    if not spellID then return nil end
    -- Direct read first (cheap path when not tainted)
    local ok, val = pcall(function() return spellID + 0 end)
    if ok and type(val) == "number" then return val end
    -- Launder through StatusBar
    _launderedID = nil
    pcall(launderBar.SetValue, launderBar, 0)
    pcall(launderBar.SetValue, launderBar, spellID)
    return _launderedID
end

local function SpellName(spellID)
    if not spellID then return "?" end
    local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
    if ok and info and info.name and not (issecretvalue and issecretvalue(info.name)) then
        return info.name
    end
    return "?"
end

local function IsNameplate(unit)
    if not unit then return false end
    return unit:match("^nameplate%d+$") ~= nil
end

------------------------------------------------------------------------
-- Cast info readers (cast vs channel return the same shape but live on
-- different APIs in retail).
------------------------------------------------------------------------
local function ReadCastInfo(unit)
    if not UnitCastingInfo then return nil end
    local ok, name, _, _, startMS, endMS, _, _, notInt, spellID =
        pcall(UnitCastingInfo, unit)
    if not ok or not name then return nil end
    return {
        name = name,
        startMS = startMS,
        endMS = endMS,
        notInterruptible = notInt,
        spellID = spellID,
        source = "cast",
    }
end

local function ReadChannelInfo(unit)
    if not UnitChannelInfo then return nil end
    local ok, name, _, _, startMS, endMS, _, notInt, spellID =
        pcall(UnitChannelInfo, unit)
    if not ok or not name then return nil end
    return {
        name = name,
        startMS = startMS,
        endMS = endMS,
        notInterruptible = notInt,
        spellID = spellID,
        source = "channel",
    }
end

------------------------------------------------------------------------
-- Core formatter — single point for the structured log line.
--
-- Guards: nameplate spellIDs in Midnight 12.0 can arrive as "secret values"
-- which break string.format/%s/tostring with silent throws at the frame
-- script boundary. Every untrusted field goes through a laundering pass
-- or the issecretvalue gate before hitting string.format.
------------------------------------------------------------------------
-- Every field from UnitCastingInfo / UnitChannelInfo on nameplates may be a
-- "secret value" in Midnight 12.0 — including startMS/endMS/spellID/name.
-- Any arithmetic, tostring, or %s format on a secret value throws AND taints
-- the caller. Filter through IsSecret BEFORE touching the value.
local function IsSecret(v)
    if v == nil then return false end
    if not issecretvalue then return false end
    local ok, res = pcall(issecretvalue, v)
    return ok and res == true
end

local function SafeStr(v)
    if v == nil then return "?" end
    if IsSecret(v) then return "secret" end
    local ok, s = pcall(tostring, v)
    if ok and type(s) == "string" then return s end
    return "?"
end

local function FormatLine(ev, unit, info, spellIDFromEvent)
    local rawID = (info and info.spellID) or spellIDFromEvent
    local spellID = (rawID ~= nil) and CleanSpellID(rawID) or nil

    local name = info and info.name
    if name == nil or IsSecret(name) then
        name = spellID and SpellName(spellID) or "?"
    end
    if type(name) ~= "string" then name = "?" end

    -- Duration: skip if either endpoint is secret or non-numeric.
    local dur = ""
    if info and info.startMS and info.endMS
        and not IsSecret(info.startMS) and not IsSecret(info.endMS)
        and type(info.startMS) == "number" and type(info.endMS) == "number"
    then
        local ok, v = pcall(function() return info.endMS - info.startMS end)
        if ok and type(v) == "number" then
            dur = string.format(" dur=%d", v)
        end
    end

    local nint = ""
    if info and info.notInterruptible ~= nil and not IsSecret(info.notInterruptible) then
        nint = " nint=" .. SafeStr(info.notInterruptible)
    end

    local src = ""
    if info and type(info.source) == "string" then
        src = " src=" .. info.source
    end

    return string.format(
        "[CAST] ev=%s unit=%s spellID=%s name=%q%s%s%s",
        SafeStr(ev), SafeStr(unit),
        (spellID and not IsSecret(spellID)) and tostring(spellID) or "?",
        name, dur, nint, src
    )
end

-- Events that matter for kickable-state decisions. Other events (SUCCEEDED,
-- STOP, CHANNEL_STOP, FAILED, DELAYED) still update the state machine but
-- are logged only at TRACE level to keep DEBUG logs focused on actionable
-- transitions.
local IMPORTANT_EVENTS = {
    START = true,
    CHANNEL_START = true,
    INTERRUPTED = true,
    INTERRUPTIBLE = true,
    NOT_INTERRUPTIBLE = true,
}

------------------------------------------------------------------------
-- Event handler
------------------------------------------------------------------------
local handlers = {
    UNIT_SPELLCAST_START          = "START",
    UNIT_SPELLCAST_CHANNEL_START  = "CHANNEL_START",
    UNIT_SPELLCAST_STOP           = "STOP",
    UNIT_SPELLCAST_CHANNEL_STOP   = "CHANNEL_STOP",
    UNIT_SPELLCAST_SUCCEEDED      = "SUCCEEDED",
    UNIT_SPELLCAST_INTERRUPTED    = "INTERRUPTED",
    UNIT_SPELLCAST_FAILED         = "FAILED",
    UNIT_SPELLCAST_DELAYED        = "DELAYED",
    UNIT_SPELLCAST_INTERRUPTIBLE      = "INTERRUPTIBLE",
    UNIT_SPELLCAST_NOT_INTERRUPTIBLE  = "NOT_INTERRUPTIBLE",
}

------------------------------------------------------------------------
-- Kickable state machine (Phase 3 pivot).
--
-- In Midnight 12.0, nameplate cast events arrive with spellID as a secret
-- value that survives all known laundering tricks. We cannot identify what
-- is being cast. But we CAN tell whether it's currently kickable via the
-- state transitions Blizzard still exposes:
--
--   START / CHANNEL_START → cast active, kickable = true (default assumption)
--   NOT_INTERRUPTIBLE     → shield went up, kickable = false
--   INTERRUPTIBLE         → shield dropped, kickable = true
--   STOP/SUCCEEDED/INTERRUPTED/FAILED/CHANNEL_STOP → cast ended, remove
--
-- Consumers (KickTracker) poll HasActiveKickableCast() when deciding whether
-- to fire a "kick now" TTS, and register a listener via OnKickableStart to
-- get a push notification the moment a fresh kickable cast begins.
------------------------------------------------------------------------
local activeCasts = {}   -- [unitToken] = { kickable = bool, startTime = n }
local listeners = {}     -- ordered list of {owner, callback} for kickable starts
local STALE_CAST_SEC = 30  -- discard entries that never got a matching STOP

local function NotifyKickableStart(unit)
    for _, entry in ipairs(listeners) do
        local ok, err = pcall(entry.callback, unit)
        if not ok then
            Log:Log("ERRORS", string.format(
                "CastDetector listener %s threw: %s",
                tostring(entry.owner), tostring(err)))
        end
    end
end

local function SetKickable(unit, kickable, reason)
    local entry = activeCasts[unit]
    if not entry then
        -- Implicit START: INTERRUPTIBLE/NOT_INTERRUPTIBLE can fire before the
        -- first START event we see (e.g. we joined combat mid-cast). Create
        -- a lazy entry so the state survives until STOP.
        activeCasts[unit] = { kickable = kickable, startTime = GetTime() }
        if kickable then NotifyKickableStart(unit) end
        return
    end
    local prev = entry.kickable
    entry.kickable = kickable
    if kickable and not prev then
        NotifyKickableStart(unit)
    end
    _ = reason  -- reserved for future debug
end

local function ClearCast(unit)
    activeCasts[unit] = nil
end

-- Drop stale entries (mob left nameplate range, we never got a STOP).
local function ReapStale()
    local now = GetTime()
    for unit, entry in pairs(activeCasts) do
        if now - (entry.startTime or 0) > STALE_CAST_SEC then
            activeCasts[unit] = nil
        end
    end
end

--- True if any hostile nameplate currently has an active cast marked kickable.
function CD:HasActiveKickableCast()
    ReapStale()
    for _, entry in pairs(activeCasts) do
        if entry.kickable then return true end
    end
    return false
end

--- Subscribe to "a nameplate cast just became kickable" events.
--- callback(unit) — fires on fresh STARTs and on INTERRUPTIBLE transitions.
function CD:OnKickableStart(owner, callback)
    for _, e in ipairs(listeners) do
        if e.owner == owner then e.callback = callback; return end
    end
    table.insert(listeners, { owner = owner, callback = callback })
end

function CD:ClearListeners(owner)
    for i = #listeners, 1, -1 do
        if owner == nil or listeners[i].owner == owner then
            table.remove(listeners, i)
        end
    end
end

-- Attempt to read notInterruptible without tripping taint. Returns a boolean
-- or nil if the field is secret/unavailable. Used at START to set the initial
-- kickable state — most non-kickable casts also get a NOT_INTERRUPTIBLE event
-- right after, but reading it here avoids a single-frame false-positive TTS.
local function SafeReadNotInterruptible(info)
    if not info or info.notInterruptible == nil then return nil end
    if IsSecret(info.notInterruptible) then return nil end
    if info.notInterruptible == true then return true end
    if info.notInterruptible == false then return false end
    return nil
end

local function UpdateStateMachine(ev, unit, info)
    if ev == "START" or ev == "CHANNEL_START" then
        local notInt = SafeReadNotInterruptible(info)
        -- Default to kickable=true when we can't read the flag; NOT_INTERRUPTIBLE
        -- will correct within a frame for shielded casts.
        local kickable = (notInt == nil) and true or (not notInt)
        local entry = activeCasts[unit]
        local wasKickable = entry and entry.kickable
        activeCasts[unit] = { kickable = kickable, startTime = GetTime() }
        if kickable and not wasKickable then
            NotifyKickableStart(unit)
        end
    elseif ev == "NOT_INTERRUPTIBLE" then
        SetKickable(unit, false, "NOT_INTERRUPTIBLE")
    elseif ev == "INTERRUPTIBLE" then
        SetKickable(unit, true, "INTERRUPTIBLE")
    elseif ev == "STOP" or ev == "CHANNEL_STOP"
        or ev == "SUCCEEDED" or ev == "INTERRUPTED" or ev == "FAILED"
    then
        ClearCast(unit)
    end
end

local function OnCastEvent(event, unit, _, spellIDFromEvent)
    if not IsNameplate(unit) then return end

    local ev = handlers[event]
    if not ev then return end

    -- For START/CHANNEL_START we always try the rich casting API. For other
    -- events we try it too — UNIT_SPELLCAST_INTERRUPTIBLE/NOT_INTERRUPTIBLE
    -- have no spellID in the payload, and DELAYED/INTERRUPTED happen while
    -- the cast row is still queryable. SUCCEEDED/STOP/FAILED typically fire
    -- after the cast cleared; UnitCastingInfo returns nil and we fall back
    -- to the event's spellID arg.
    local info = ReadCastInfo(unit) or ReadChannelInfo(unit)

    -- State machine runs unconditionally — KickTracker depends on it even
    -- when log level is INFO (verbose cast logging is gated separately below).
    local smOk, smErr = pcall(UpdateStateMachine, ev, unit, info)
    if not smOk then
        Log:Log("ERRORS", "CastDetector state machine: " .. tostring(smErr))
    end

    -- Log only kickable-relevant events at DEBUG. The rest (SUCCEEDED, STOP,
    -- FAILED, etc.) flood the buffer with ~10x more lines than START events
    -- — noisy in M+ pulls, not useful for diagnosing kick behavior. TRACE
    -- level still surfaces them when explicitly requested.
    local cfgLevel = HexCDDB and HexCDDB.logLevel or "INFO"
    local isImportant = IMPORTANT_EVENTS[ev] or false
    local shouldLog = (cfgLevel == "TRACE") or (cfgLevel == "DEBUG" and isImportant)
    if not shouldLog then return end

    -- Wrap FormatLine + Log:Log in pcall. In Midnight, nameplate spellIDs can
    -- arrive as "secret values" that break string.format %s / tostring deep
    -- inside Blizzard's C code. Without this guard, a single tainted event
    -- throws at the OnEvent boundary and the whole emit is silently dropped.
    local ok, line = pcall(FormatLine, ev, unit, info, spellIDFromEvent)
    if ok and line then
        Log:Log("DEBUG", line)
    else
        Log:Log("DEBUG", string.format(
            "[CAST] ev=%s unit=%s (format-err: secret value)", ev, tostring(unit)))
    end
end

------------------------------------------------------------------------
-- Init / event registration
------------------------------------------------------------------------
local eventFrame = nil

function CD:Init()
    if eventFrame then return end -- idempotent
    eventFrame = CreateFrame("Frame")
    for evName in pairs(handlers) do
        eventFrame:RegisterEvent(evName)
    end
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        OnCastEvent(event, ...)
    end)
    Log:Log("INFO", "CastDetector: ready (gated on logLevel=DEBUG)")
end

------------------------------------------------------------------------
-- Test helpers
------------------------------------------------------------------------
function CD:_testEmit(event, unit, spellID)
    OnCastEvent(event, unit, nil, spellID)
end

function CD:_testFormatLine(ev, unit, info, spellIDFromEvent)
    return FormatLine(ev, unit, info, spellIDFromEvent)
end

function CD:_testCleanSpellID(spellID)
    return CleanSpellID(spellID)
end

function CD:_testResetState()
    activeCasts = {}
    listeners = {}
end

function CD:_testActiveCasts()
    return activeCasts
end
