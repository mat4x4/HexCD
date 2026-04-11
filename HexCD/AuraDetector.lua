------------------------------------------------------------------------
-- HexCD: AuraDetector — Party defensive CD detection via UNIT_AURA
--
-- === 4-LAYER PARTY CD DETECTION ARCHITECTURE ===
--
-- Layer 1: AURA DETECTION (this file) — 0ms, no addon required, no secret values
--   State-machine approach (identical to MiniCC by Verz):
--     1. UNIT_AURA fires → scan BIG_DEFENSIVE / IMPORTANT / EXTERNAL_DEFENSIVE
--     2. New aura appears → record StartTime + evidence (cast, shield, flags)
--     3. Aura disappears → measure elapsed = now - StartTime
--     4. Match (class + elapsed duration + evidence) → start CD timer
--   Never reads secret fields (duration, spellId). Measures time ourselves.
--
-- Layer 2: DIRECT SPELLID (CommSync.lua) — 0ms, no addon required
-- Layer 3: TAINT LAUNDERING (CommSync.lua) — 0ms, no addon required
-- Layer 4: ADDON COMMS (CommSync.lua) — 100-500ms, requires HexCD on other player
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.AuraDetector = {}

local AD = HexCD.AuraDetector
local Log = HexCD.DebugLog
local Config = HexCD.Config

------------------------------------------------------------------------
-- Detection rules: class → list of { BuffDuration, Cooldown, SpellId, Evidence }
-- BuffDuration: expected buff duration (matched AFTER buff ends, measured by us)
-- MinDuration: if true, buff can be longer than BuffDuration (talent extensions)
-- CanCancelEarly: if true, buff can be shorter (player cancelled)
------------------------------------------------------------------------
local RULES = {
    DEATHKNIGHT = {
        { BuffDuration = 5,  Cooldown = 60,  SpellId = 48707,  Evidence = {"Cast", "Shield"} },  -- Anti-Magic Shell
        { BuffDuration = 7,  Cooldown = 60,  SpellId = 48707,  Evidence = {"Cast", "Shield"}, MinDuration = true },  -- AMS + Anti-Magic Barrier
        { BuffDuration = 8,  Cooldown = 120, SpellId = 48792,  Evidence = "Cast" },  -- Icebound Fortitude
        { BuffDuration = 10, Cooldown = 120, SpellId = 55233,  Evidence = "Cast", MinDuration = true },  -- Vampiric Blood
    },
    PALADIN = {
        { BuffDuration = 8,  Cooldown = 300, SpellId = 642,    Evidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Divine Shield
        { BuffDuration = 8,  Cooldown = 60,  SpellId = 498,    Evidence = "Cast" },  -- Divine Protection
        { BuffDuration = 8,  Cooldown = 180, SpellId = 31850,  Evidence = "Cast" },  -- Ardent Defender
        { BuffDuration = 12, Cooldown = 300, SpellId = 86659,  Evidence = "Cast" },  -- Guardian of Ancient Kings
    },
    WARRIOR = {
        { BuffDuration = 8,  Cooldown = 120, SpellId = 118038, Evidence = "Cast" },  -- Die by the Sword
        { BuffDuration = 8,  Cooldown = 180, SpellId = 871,    Evidence = "Cast" },  -- Shield Wall
        { BuffDuration = 8,  Cooldown = 120, SpellId = 184364, Evidence = "Cast" },  -- Enraged Regeneration
        { BuffDuration = 10, Cooldown = 180, SpellId = 97462,  Evidence = "Cast" },  -- Rallying Cry
    },
    MAGE = {
        { BuffDuration = 10, Cooldown = 240, SpellId = 45438,  Evidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Ice Block
        { BuffDuration = 10, Cooldown = 30,  SpellId = 342245, Evidence = "Cast" },  -- Alter Time
    },
    HUNTER = {
        { BuffDuration = 8,  Cooldown = 180, SpellId = 186265, Evidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Aspect of the Turtle
        { BuffDuration = 6,  Cooldown = 180, SpellId = 264735, Evidence = "Cast", MinDuration = true },  -- Survival of the Fittest
    },
    DRUID = {
        { BuffDuration = 8,  Cooldown = 60,  SpellId = 22812,  Evidence = "Cast", MinDuration = true },  -- Barkskin
        { BuffDuration = 8,  Cooldown = 180, SpellId = 740,    Evidence = "Cast" },  -- Tranquility (channel)
        { BuffDuration = 4,  Cooldown = 60,  SpellId = 391528, Evidence = "Cast" },  -- Convoke the Spirits
        { BuffDuration = 30, Cooldown = 180, SpellId = 33891,  Evidence = "Cast", MinDuration = true },  -- Incarnation: ToL
    },
    ROGUE = {
        { BuffDuration = 10, Cooldown = 120, SpellId = 5277,   Evidence = "Cast" },  -- Evasion
        { BuffDuration = 5,  Cooldown = 120, SpellId = 31224,  Evidence = "Cast", CanCancelEarly = true },  -- Cloak of Shadows
    },
    PRIEST = {
        { BuffDuration = 10, Cooldown = 120, SpellId = 19236,  Evidence = "Cast" },  -- Desperate Prayer
        { BuffDuration = 6,  Cooldown = 120, SpellId = 47585,  Evidence = "Cast" },  -- Dispersion (Shadow)
        { BuffDuration = 15, Cooldown = 120, SpellId = 15286,  Evidence = "Cast" },  -- Vampiric Embrace
        { BuffDuration = 8,  Cooldown = 180, SpellId = 64843,  Evidence = "Cast" },  -- Divine Hymn
        { BuffDuration = 20, Cooldown = 120, SpellId = 200183, Evidence = "Cast" },  -- Apotheosis
    },
    MONK = {
        { BuffDuration = 15, Cooldown = 180, SpellId = 115203, Evidence = "Cast" },  -- Fortifying Brew
        { BuffDuration = 25, Cooldown = 45,  SpellId = 322507, Evidence = {"Cast", "Shield"}, MinDuration = true },  -- Celestial Brew (Brewmaster, absorb shield)
    },
    DEMONHUNTER = {
        { BuffDuration = 10, Cooldown = 60,  SpellId = 198589, Evidence = "Cast" },  -- Blur
        { BuffDuration = 8,  Cooldown = 180, SpellId = 196718, Evidence = "Cast" },  -- Darkness
    },
    SHAMAN = {
        { BuffDuration = 12, Cooldown = 120, SpellId = 108271, Evidence = "Cast" },  -- Astral Shift
        { BuffDuration = 6,  Cooldown = 180, SpellId = 108280, Evidence = "Cast" },  -- Healing Tide Totem
    },
    WARLOCK = {
        { BuffDuration = 8,  Cooldown = 180, SpellId = 104773, Evidence = "Cast" },  -- Unending Resolve
    },
    EVOKER = {
        { BuffDuration = 12, Cooldown = 150, SpellId = 363916, Evidence = "Cast" },  -- Obsidian Scales
        { BuffDuration = 8,  Cooldown = 120, SpellId = 374227, Evidence = "Cast" },  -- Zephyr
        { BuffDuration = 4,  Cooldown = 90,  SpellId = 374349, Evidence = "Cast", MinDuration = true },  -- Renewing Blaze (initial, varies by talent)
    },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local TOLERANCE = 1.0           -- seconds tolerance for duration matching
local EVIDENCE_WINDOW = 0.20    -- seconds within which evidence must occur
local CD_DEDUP_WINDOW = 2.0     -- cross-layer dedup window
local eventFrame = nil

-- Evidence timestamps per unit
local lastCastTime = {}    -- unit → GetTime()
local lastShieldTime = {}  -- unit → GetTime()
local lastFlagsTime = {}   -- unit → GetTime()

-- Tracked aura state machine: auraInstanceID → { startTime, unit, evidence }
local trackedAuras = {}

------------------------------------------------------------------------
-- Evidence helpers
------------------------------------------------------------------------

local function BuildEvidence(unit, now)
    local ev = {}
    if lastCastTime[unit] and math.abs(lastCastTime[unit] - now) <= EVIDENCE_WINDOW then
        ev.Cast = true
    end
    if lastShieldTime[unit] and math.abs(lastShieldTime[unit] - now) <= EVIDENCE_WINDOW then
        ev.Shield = true
    end
    if lastFlagsTime[unit] and math.abs(lastFlagsTime[unit] - now) <= EVIDENCE_WINDOW then
        ev.Flags = true
    end
    return ev
end

local function EvidenceSatisfied(required, evidence)
    if not required then return true end
    if type(required) == "string" then
        return evidence[required] == true
    end
    if type(required) == "table" then
        for _, key in ipairs(required) do
            if not evidence[key] then return false end
        end
        return true
    end
    return true
end

------------------------------------------------------------------------
-- Rule matching (by measured elapsed duration, NOT by API duration field)
------------------------------------------------------------------------

local function MatchRule(classToken, measuredDuration, evidence)
    local classRules = RULES[classToken]
    if not classRules then return nil end

    local bestMatch = nil
    local bestDiff = math.huge

    for _, rule in ipairs(classRules) do
        if EvidenceSatisfied(rule.Evidence, evidence) then
            local durationOk = false
            if rule.MinDuration then
                durationOk = measuredDuration >= rule.BuffDuration - TOLERANCE
            elseif rule.CanCancelEarly then
                durationOk = measuredDuration <= rule.BuffDuration + TOLERANCE
                    and measuredDuration >= 1.0  -- ignore <1s flickers
            else
                durationOk = math.abs(measuredDuration - rule.BuffDuration) <= TOLERANCE
            end

            if durationOk then
                local diff = math.abs(measuredDuration - rule.BuffDuration)
                if diff < bestDiff then
                    bestDiff = diff
                    bestMatch = rule
                end
            end
        end
    end

    return bestMatch
end

------------------------------------------------------------------------
-- Aura state machine: track appearances and disappearances
------------------------------------------------------------------------

local function GetUnitInfo(unit)
    local unitName, classToken = nil, nil
    pcall(function()
        local n = UnitName(unit)
        if n and not (issecretvalue and issecretvalue(n)) then
            unitName = n:match("^([^-]+)") or n
        end
        local _, token = UnitClass(unit)
        if token and not (issecretvalue and issecretvalue(token)) then
            classToken = token
        end
    end)
    return unitName, classToken
end

--- Get current defensive aura IDs for a unit using Blizzard's filters.
local function GetCurrentDefensiveAuraIDs(unit)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return {} end

    local ids = {}
    local filters = { "HELPFUL|BIG_DEFENSIVE", "HELPFUL|EXTERNAL_DEFENSIVE", "HELPFUL|IMPORTANT" }
    for _, filter in ipairs(filters) do
        local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
        if ok and auras then
            for _, aura in ipairs(auras) do
                local id = aura.auraInstanceID
                if id and not (issecretvalue and issecretvalue(id)) and not ids[id] then
                    ids[id] = true
                end
            end
        end
    end
    return ids
end

local filterDiagOnce = {}  -- unit → true

--- Called on every UNIT_AURA: diff current auras against tracked to detect add/remove.
local function ProcessAuraChanges(unit)
    local now = GetTime()
    local unitName, classToken = GetUnitInfo(unit)
    if not unitName or not classToken then return end

    local CS = HexCD.CommSync
    if not CS then return end
    local partyCD = CS:GetPartyCD()
    if not partyCD[unitName] then return end

    -- Get currently active defensive aura IDs
    local currentIDs = GetCurrentDefensiveAuraIDs(unit)

    -- One-time diagnostic: log what each filter returns for this unit
    if not filterDiagOnce[unit] and Log then
        filterDiagOnce[unit] = true
        local count = 0
        for _ in pairs(currentIDs) do count = count + 1 end
        local filterCounts = {}
        for _, filter in ipairs({ "HELPFUL|BIG_DEFENSIVE", "HELPFUL|EXTERNAL_DEFENSIVE", "HELPFUL|IMPORTANT" }) do
            local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
            filterCounts[#filterCounts + 1] = string.format("%s=%d", filter:gsub("|", "+"), ok and #auras or -1)
        end
        Log:Log("DEBUG", string.format("AuraDetector: %s (%s %s) filter scan: %s, total unique=%d",
            unitName, unit, classToken, table.concat(filterCounts, ", "), count))
    end

    -- Detect NEW auras (in current but not tracked)
    local evidence = BuildEvidence(unit, now)
    for id in pairs(currentIDs) do
        if not trackedAuras[id] then
            trackedAuras[id] = {
                startTime = now,
                unit = unit,
                unitName = unitName,
                classToken = classToken,
                evidence = evidence,
            }
            -- Deferred evidence backfill (cast/shield events may arrive slightly after UNIT_AURA)
            if C_Timer then
                local capturedId = id
                C_Timer.After(EVIDENCE_WINDOW, function()
                    local tracked = trackedAuras[capturedId]
                    if tracked then
                        local lateEv = BuildEvidence(unit, now)
                        if lateEv then
                            for k in pairs(lateEv) do tracked.evidence[k] = true end
                        end
                    end
                end)
            end
            if Log then
                local evStr = ""
                for k in pairs(evidence) do evStr = evStr .. k .. " " end
                Log:Log("DEBUG", string.format("AuraDetector: %s NEW defensive aura id=%s ev={%s}",
                    unitName, id, evStr))
            end
        end
    end

    -- Detect REMOVED auras (in tracked but not current)
    for id, tracked in pairs(trackedAuras) do
        if tracked.unit == unit and not currentIDs[id] then
            local elapsed = now - tracked.startTime
            trackedAuras[id] = nil  -- stop tracking

            -- Match rule by measured elapsed duration
            local rule = MatchRule(tracked.classToken, elapsed, tracked.evidence)
            if rule and partyCD[tracked.unitName] and partyCD[tracked.unitName][rule.SpellId] then
                if not AD:IsDuplicate(tracked.unitName, rule.SpellId) then
                    partyCD[tracked.unitName][rule.SpellId] = {
                        readyTime = tracked.startTime + rule.Cooldown,
                        effectiveCD = rule.Cooldown,
                        castTime = tracked.startTime,
                    }
                    if Log then
                        Log:Log("DEBUG", string.format(
                            "AuraDetector: %s — %d CD %ds (measured %.1fs, rule %.1fs) [aura]",
                            tracked.unitName, rule.SpellId, rule.Cooldown,
                            elapsed, rule.BuffDuration))
                    end
                end
            elseif not rule and elapsed > 1.0 and Log then
                local evStr = ""
                for k in pairs(tracked.evidence) do evStr = evStr .. k .. " " end
                Log:Log("DEBUG", string.format(
                    "AuraDetector: %s — no rule matched (measured %.1fs, class=%s, ev={%s}) [aura]",
                    tracked.unitName, elapsed, tracked.classToken, evStr))
            end
        end
    end
end

------------------------------------------------------------------------
-- Event handling
------------------------------------------------------------------------

local auraEventOnce = {}  -- unit → true (log first UNIT_AURA per unit per combat)

local function IsPartyUnit(unit)
    return unit == "party1" or unit == "party2" or unit == "party3" or unit == "party4"
end

local function OnEvent(self, event, ...)
    if event == "UNIT_AURA" then
        local unit = ...
        if not IsPartyUnit(unit) then return end
        -- Trace: confirm UNIT_AURA fires for each party member
        if not auraEventOnce[unit] and Log then
            auraEventOnce[unit] = true
            local uname = "?"
            pcall(function()
                local n = UnitName(unit)
                if n and not (issecretvalue and issecretvalue(n)) then uname = n end
            end)
            Log:Log("DEBUG", string.format("AuraDetector: UNIT_AURA first fire for %s (%s)", unit, uname))
        end
        ProcessAuraChanges(unit)

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit = ...
        if IsPartyUnit(unit) then
            lastCastTime[unit] = GetTime()
        end

    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        local unit = ...
        if IsPartyUnit(unit) then
            lastShieldTime[unit] = GetTime()
        end

    elseif event == "UNIT_FLAGS" then
        local unit = ...
        if IsPartyUnit(unit) then
            lastFlagsTime[unit] = GetTime()
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        AD:RegisterPartyUnits()
    end
end

------------------------------------------------------------------------
-- Cross-layer dedup
------------------------------------------------------------------------
function AD:IsDuplicate(playerName, spellID)
    local CS = HexCD.CommSync
    if not CS then return false end
    local partyCD = CS:GetPartyCD()
    local entry = partyCD[playerName] and partyCD[playerName][spellID]
    if not entry or not entry.castTime then return false end
    return (GetTime() - entry.castTime) < CD_DEDUP_WINDOW
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function AD:RegisterPartyUnits()
    if not eventFrame then return end
    eventFrame:UnregisterAllEvents()
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")

    -- Use global event registration — RegisterUnitEvent only supports 1-2 units
    -- per call and replaces previous registrations on the same frame.
    -- We filter by unit token in the event handler instead.
    eventFrame:RegisterEvent("UNIT_AURA")
    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("UNIT_FLAGS")

    if Log then
        local names = {}
        for i = 1, 4 do
            local uid = "party" .. i
            if UnitExists(uid) then
                local name = "?"
                pcall(function()
                    local n = UnitName(uid)
                    if n and not (issecretvalue and issecretvalue(n)) then name = n end
                end)
                names[#names + 1] = uid .. "=" .. name
            end
        end
        Log:Log("DEBUG", "AuraDetector: registered global events, party: " .. (#names > 0 and table.concat(names, ", ") or "none"))
    end
end

function AD:Init()
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then
        if Log then
            Log:Log("DEBUG", "AuraDetector: C_UnitAuras not available — disabled")
        end
        return
    end

    if eventFrame then return end

    eventFrame = CreateFrame("Frame", "HexCDAuraDetectorFrame")
    eventFrame:SetScript("OnEvent", OnEvent)
    AD:RegisterPartyUnits()

    if Log then
        Log:Log("DEBUG", "AuraDetector: initialized — state-machine aura tracking")
    end
end

function AD:Reset()
    wipe(trackedAuras)
    wipe(lastCastTime)
    wipe(lastShieldTime)
    wipe(lastFlagsTime)
    wipe(filterDiagOnce)
    wipe(auraEventOnce)
end
