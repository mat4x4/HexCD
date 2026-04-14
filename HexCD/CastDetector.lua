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
-- Log gating — short-circuit work when user isn't capturing cast data.
-- DebugLog filters DEBUG-level entries at INFO level anyway, but pulling
-- spell info / running pcall on every mob cast in a busy pull is enough
-- overhead to be worth gating up front.
------------------------------------------------------------------------
local function ShouldCapture()
    local lvl = HexCDDB and HexCDDB.logLevel or "INFO"
    return lvl == "DEBUG" or lvl == "TRACE"
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
------------------------------------------------------------------------
local function FormatLine(ev, unit, info, spellIDFromEvent)
    local spellID = (info and info.spellID) or spellIDFromEvent
    spellID = CleanSpellID(spellID)
    local name = (info and info.name) or SpellName(spellID)
    if name and issecretvalue and issecretvalue(name) then name = "?" end

    local dur = ""
    if info and info.startMS and info.endMS then
        dur = string.format(" dur=%d", info.endMS - info.startMS)
    end

    local nint = ""
    if info and info.notInterruptible ~= nil then
        nint = string.format(" nint=%s", tostring(info.notInterruptible))
    end

    local src = info and (" src=" .. info.source) or ""

    return string.format(
        "[CAST] ev=%s unit=%s spellID=%s name=%q%s%s%s",
        ev, unit, tostring(spellID or "?"), name or "?", dur, nint, src
    )
end

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

local function OnCastEvent(event, unit, _, spellIDFromEvent)
    if not IsNameplate(unit) then return end
    if not ShouldCapture() then return end

    local ev = handlers[event]
    if not ev then return end

    -- For START/CHANNEL_START we always try the rich casting API. For other
    -- events we try it too — UNIT_SPELLCAST_INTERRUPTIBLE/NOT_INTERRUPTIBLE
    -- have no spellID in the payload, and DELAYED/INTERRUPTED happen while
    -- the cast row is still queryable. SUCCEEDED/STOP/FAILED typically fire
    -- after the cast cleared; UnitCastingInfo returns nil and we fall back
    -- to the event's spellID arg.
    local info = ReadCastInfo(unit) or ReadChannelInfo(unit)

    Log:Log("DEBUG", FormatLine(ev, unit, info, spellIDFromEvent))
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
