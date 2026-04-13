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
-- Detection rules (MiniCC-compatible schema)
--
-- Rule fields:
--   SpellId              (number, required)       canonical CD id to record
--   BuffDuration         (number, required)       expected buff elapsed, matched AFTER buff ends
--   Cooldown             (number, required)       CD to start on match
--   RequiresEvidence     (string | string[])      evidence key(s): "Cast","Shield","Flags","Debuff"
--   MinDuration          (bool)                   buff may be longer (talent extension)
--   CanCancelEarly       (bool)                   buff may be shorter (player cancelled)
--   BigDefensive         (bool)                   aura surfaces under BIG_DEFENSIVE filter
--   ExternalDefensive    (bool)                   aura surfaces under EXTERNAL_DEFENSIVE filter
--   Important            (bool)                   aura surfaces under IMPORTANT filter
--   RequiresTalent       (number | number[])      rule only active when this talent picked
--   ExcludeIfTalent      (number | number[])      rule suppressed when this talent picked
--   CastableOnOthers     (bool)                   informational — external CD targeted at other
--   CastOnly             (bool)                   skip aura-scan; only fires via UNIT_SPELLCAST
--                                                 fast-path (raid CDs with no caster buff:
--                                                 Spirit Link Totem, Barrier, Revival, etc.)
--
-- Back-compat: `Evidence` field is accepted as an alias for RequiresEvidence.
------------------------------------------------------------------------
-- Rules are keyed by specID first (BySpec, preferred — highest precision), then
-- by class token (ByClass, fallback for when spec is unknown or no spec rule
-- matched). MatchRule tries BySpec first; if no match, falls back to ByClass.
--
-- Primary rule source is `HexCD.AuraRules` (AuraRules.lua) — the ~96 ported
-- MiniCC rules. This inline RULES table is kept as a minimal fallback used
-- only if AuraRules.lua failed to load. Any content in AuraRules.lua
-- REPLACES the inline RULES at init time.
local RULES = {
    BySpec = {},
    ByClass = {
        DEATHKNIGHT = {
            { BuffDuration = 5,  Cooldown = 60,  SpellId = 48707,  RequiresEvidence = {"Cast", "Shield"} },  -- Anti-Magic Shell
            { BuffDuration = 7,  Cooldown = 60,  SpellId = 48707,  RequiresEvidence = {"Cast", "Shield"}, MinDuration = true },  -- AMS + Anti-Magic Barrier
            { BuffDuration = 8,  Cooldown = 120, SpellId = 48792,  RequiresEvidence = "Cast" },  -- Icebound Fortitude
            { BuffDuration = 10, Cooldown = 120, SpellId = 55233,  RequiresEvidence = "Cast", MinDuration = true },  -- Vampiric Blood
        },
        PALADIN = {
            { BuffDuration = 8,  Cooldown = 300, SpellId = 642,    RequiresEvidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Divine Shield
            { BuffDuration = 8,  Cooldown = 60,  SpellId = 498,    RequiresEvidence = "Cast" },  -- Divine Protection
            { BuffDuration = 8,  Cooldown = 180, SpellId = 31850,  RequiresEvidence = "Cast" },  -- Ardent Defender
            { BuffDuration = 12, Cooldown = 300, SpellId = 86659,  RequiresEvidence = "Cast" },  -- Guardian of Ancient Kings
        },
        WARRIOR = {
            { BuffDuration = 8,  Cooldown = 120, SpellId = 118038, RequiresEvidence = "Cast" },  -- Die by the Sword
            { BuffDuration = 8,  Cooldown = 180, SpellId = 871,    RequiresEvidence = "Cast" },  -- Shield Wall
            { BuffDuration = 8,  Cooldown = 120, SpellId = 184364, RequiresEvidence = "Cast" },  -- Enraged Regeneration
            { BuffDuration = 10, Cooldown = 180, SpellId = 97462,  RequiresEvidence = "Cast" },  -- Rallying Cry
        },
        MAGE = {
            { BuffDuration = 10, Cooldown = 240, SpellId = 45438,  RequiresEvidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Ice Block
            { BuffDuration = 10, Cooldown = 30,  SpellId = 342245, RequiresEvidence = "Cast" },  -- Alter Time
        },
        HUNTER = {
            { BuffDuration = 8,  Cooldown = 180, SpellId = 186265, RequiresEvidence = {"Cast", "Flags"}, CanCancelEarly = true },  -- Aspect of the Turtle
            { BuffDuration = 6,  Cooldown = 180, SpellId = 264735, RequiresEvidence = "Cast", MinDuration = true },  -- Survival of the Fittest
        },
        DRUID = {
            { BuffDuration = 8,  Cooldown = 60,  SpellId = 22812,  RequiresEvidence = "Cast", MinDuration = true },  -- Barkskin
            { BuffDuration = 8,  Cooldown = 180, SpellId = 740,    RequiresEvidence = "Cast" },  -- Tranquility (channel)
            { BuffDuration = 4,  Cooldown = 60,  SpellId = 391528, RequiresEvidence = "Cast" },  -- Convoke the Spirits
            { BuffDuration = 30, Cooldown = 180, SpellId = 33891,  RequiresEvidence = "Cast", MinDuration = true },  -- Incarnation: ToL
        },
        ROGUE = {
            { BuffDuration = 10, Cooldown = 120, SpellId = 5277,   RequiresEvidence = "Cast" },  -- Evasion
            { BuffDuration = 5,  Cooldown = 120, SpellId = 31224,  RequiresEvidence = "Cast", CanCancelEarly = true },  -- Cloak of Shadows
        },
        PRIEST = {
            { BuffDuration = 10, Cooldown = 120, SpellId = 19236,  RequiresEvidence = "Cast" },  -- Desperate Prayer
            { BuffDuration = 6,  Cooldown = 120, SpellId = 47585,  RequiresEvidence = "Cast" },  -- Dispersion (Shadow)
            { BuffDuration = 15, Cooldown = 120, SpellId = 15286,  RequiresEvidence = "Cast" },  -- Vampiric Embrace
            { BuffDuration = 8,  Cooldown = 180, SpellId = 64843,  RequiresEvidence = "Cast" },  -- Divine Hymn
            { BuffDuration = 20, Cooldown = 120, SpellId = 200183, RequiresEvidence = "Cast" },  -- Apotheosis
        },
        MONK = {
            { BuffDuration = 15, Cooldown = 180, SpellId = 115203, RequiresEvidence = "Cast" },  -- Fortifying Brew
            { BuffDuration = 25, Cooldown = 45,  SpellId = 322507, RequiresEvidence = {"Cast", "Shield"}, MinDuration = true },  -- Celestial Brew (Brewmaster, absorb shield)
        },
        DEMONHUNTER = {
            { BuffDuration = 10, Cooldown = 60,  SpellId = 198589, RequiresEvidence = "Cast" },  -- Blur
            { BuffDuration = 8,  Cooldown = 180, SpellId = 196718, RequiresEvidence = "Cast" },  -- Darkness
        },
        SHAMAN = {
            { BuffDuration = 12, Cooldown = 120, SpellId = 108271, RequiresEvidence = "Cast" },  -- Astral Shift
            { BuffDuration = 6,  Cooldown = 180, SpellId = 108280, RequiresEvidence = "Cast" },  -- Healing Tide Totem
        },
        WARLOCK = {
            { BuffDuration = 8,  Cooldown = 180, SpellId = 104773, RequiresEvidence = "Cast" },  -- Unending Resolve
        },
        EVOKER = {
            { BuffDuration = 12, Cooldown = 150, SpellId = 363916, RequiresEvidence = "Cast" },  -- Obsidian Scales
            { BuffDuration = 8,  Cooldown = 120, SpellId = 374227, RequiresEvidence = "Cast" },  -- Zephyr
            { BuffDuration = 4,  Cooldown = 90,  SpellId = 374349, RequiresEvidence = "Cast", MinDuration = true },  -- Renewing Blaze (initial, varies by talent)
        },
    },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local TOLERANCE = 1.0           -- seconds tolerance for duration matching
local EVIDENCE_WINDOW = 0.20    -- seconds within which evidence must occur
local CD_DEDUP_WINDOW = 2.0     -- cross-layer dedup window
local MAX_AURA_DWELL = 60.0     -- evict tracked auras older than this
-- Auras with instanceIDs in the upper half of uint32 are reserved /
-- synthetic / cleanup markers from Blizzard's end-of-combat flush.
-- Real auraInstanceIDs start at 1 and monotonically increment — they
-- never approach 2^31 in a normal session. Any ID with the top bit set
-- is bogus. (Previous threshold of 0xFFFFFF00 was too tight; observed
-- synthetic IDs in the 4294966995..4294967031 range leaked through.)
local AURA_ID_RESERVED = 0x80000000  -- 2147483648 — reject IDs >= this
local eventFrame = nil

-- Evidence timestamps per unit
local lastCastTime = {}    -- unit → GetTime()
local lastShieldTime = {}  -- unit → GetTime()
local lastFlagsTime = {}   -- unit → GetTime()
local lastDebuffTime = {}  -- unit → GetTime() (Forbearance, Weakened Soul, etc.)
local lastFeignTime = {}   -- unit → GetTime() (Hunter Feign Death toggle)
local lastFeignState = {}  -- unit → bool (last observed UnitIsFeignDeath state)

-- Known "consequence debuffs" applied to the unit when an external CD lands.
-- Used for the Debuff evidence key — disambiguates e.g. Blessing of Protection
-- from a self-buff of similar duration.
local DEBUFF_CONSEQUENCE_IDS = {
    [25771]  = true, -- Forbearance (Blessing of Protection / Lay on Hands / Divine Shield)
    [6788]   = true, -- Weakened Soul (Power Word: Shield)
    [159916] = true, -- Amplification (Legendary?)
}

-- Tracked aura state machine: auraInstanceID → { startTime, unit, evidence }
local trackedAuras = {}

-- Cast fast-path: maps cast spell ID → rule (Cast-only, non-talent-gated
-- rules that can stamp the CD immediately on UNIT_SPELLCAST_SUCCEEDED
-- without waiting for the UNIT_AURA lifecycle). Populated at load time
-- after AuraRules.lua is available; forward-declared here so OnEvent's
-- closure captures it.
local castFastPath = {}

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
    if lastDebuffTime[unit] and math.abs(lastDebuffTime[unit] - now) <= EVIDENCE_WINDOW then
        ev.Debuff = true
    end
    if lastFeignTime[unit] and math.abs(lastFeignTime[unit] - now) <= EVIDENCE_WINDOW then
        ev.FeignDeath = true
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

--- Rule has `ExcludeIfEvidence = { FeignDeath = true, ... }` and any of
--- those keys is present in the live evidence set → reject.
local function EvidenceNotExcluded(rule, evidence)
    local xe = rule.ExcludeIfEvidence
    if not xe then return true end
    for k in pairs(xe) do
        if evidence[k] then return false end
    end
    return true
end

------------------------------------------------------------------------
-- Rule matching (by measured elapsed duration, NOT by API duration field)
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Talent-gate helpers
--
-- Delegates to `HexCD.TalentCache` which reads C_Traits for the local player
-- and inspected party members. Returns `{ [talentSpellID] = rank }`; gates
-- in TalentPresent/TalentGateOk treat any rank > 0 as "present".
-- If TalentCache hasn't been initialised (e.g. early unit tests that load
-- AuraDetector standalone), returns empty — equivalent to the old stub.
------------------------------------------------------------------------

local function GetUnitTalents(unit)
    if HexCD.TalentCache and HexCD.TalentCache.GetTalentsForUnit then
        return HexCD.TalentCache:GetTalentsForUnit(unit) or {}
    end
    return {}
end

-- Is any of `requiredOrList` present in the talent set? Accepts number or
-- number[]. nil required → always true (no requirement).
local function TalentPresent(required, talentSet)
    if required == nil then return true end
    -- A talent is "present" if it's in the set with truthy/non-zero value.
    -- Accepts {[id]=true} for tests or {[id]=rank} from TalentCache.
    local function hasTalent(id)
        local v = talentSet[id]
        if v == nil or v == false then return false end
        if type(v) == "number" and v <= 0 then return false end
        return true
    end
    if type(required) == "number" then return hasTalent(required) end
    if type(required) == "table" then
        for _, id in ipairs(required) do
            if hasTalent(id) then return true end
        end
        return false
    end
    return true
end

-- Given a rule and the unit's talent set, is the rule allowed to match?
--
-- Talent gates are strict when `talentSet._source` is "live" or "inspect"
-- (we actually know what talents are picked). When source is "default"
-- (TalentDefaults guess for a party member we can't inspect directly —
-- Midnight restriction), we can't be sure what they picked, so gates go
-- permissive: RequiresTalent always passes, ExcludeIfTalent never fires.
-- Duration + evidence still discriminate between talent variants, so
-- false matches are rare in practice.
local function TalentGateOk(rule, talentSet)
    local source = talentSet and talentSet._source
    local permissive = (source == "default")

    if rule.RequiresTalent ~= nil
            and not permissive
            and not TalentPresent(rule.RequiresTalent, talentSet) then
        return false
    end
    if rule.ExcludeIfTalent ~= nil
            and not permissive
            and TalentPresent(rule.ExcludeIfTalent, talentSet) then
        return false
    end
    return true
end

-- Per-rule filter-kind gate. A rule flagged `BigDefensive=true` is only
-- considered when filterKind == "BIG_DEFENSIVE", and similarly for the other
-- two buckets. A rule with none of the three flags set is considered
-- universal (legacy behaviour — e.g. unported inline fallback rules).
local function FilterKindMatches(rule, filterKind)
    if filterKind == nil then return true end  -- no filter gating requested
    local hasFlag = rule.BigDefensive or rule.ExternalDefensive or rule.Important
    if not hasFlag then return true end  -- legacy rule, allow through
    if filterKind == "BIG_DEFENSIVE" and rule.BigDefensive then return true end
    if filterKind == "EXTERNAL_DEFENSIVE" and rule.ExternalDefensive then return true end
    if filterKind == "IMPORTANT" and rule.Important then return true end
    return false
end

--- Given a unit name, return a lookup `{[spellID]=entry}` that describes
--- spells currently on CD (effective CD hasn't expired). Nil-safe.
local function ActiveCooldownsForName(name)
    if not name then return nil end
    local CS = HexCD.CommSync
    if not CS then return nil end
    local partyCD = CS:GetPartyCD()
    return partyCD and partyCD[name] or nil
end

--- Is `spellID` currently on cooldown for the given party-name entry?
local function SpellOnCooldown(activeCDs, spellID)
    if not activeCDs or not spellID then return false end
    local entry = activeCDs[spellID]
    if not entry or not entry.readyTime then return false end
    local now = GetTime and GetTime() or 0
    return entry.readyTime > now
end

-- Scan a rule list for the best match. MiniCC-style decision logic:
--   1. Skip rules that fail filter/talent/evidence gates.
--   2. Compute talent-adjusted expected duration via DurationModifiers.
--   3. Apply duration match (MinDuration / CanCancelEarly / exact).
--   4. Honour MinCancelDuration floor when CanCancelEarly is true.
--   5. If the rule's spell is already on CD for this unit, save it as a
--      fallback and keep scanning — prefer a not-on-CD match.
--   6. Return best (smallest duration diff) non-on-CD match, or fallback.
local function ScanRules(ruleList, measuredDuration, evidence, filterKind, talentSet, activeCDs, classToken, specID)
    if not ruleList then return nil end
    local DM = HexCD.DurationModifiers
    local bestMatch, bestDiff = nil, math.huge
    local bestExpected = nil
    local fallbackMatch, fallbackDiff = nil, math.huge
    local fallbackExpected = nil
    for _, rule in ipairs(ruleList) do
        if not rule.CastOnly
                and FilterKindMatches(rule, filterKind)
                and TalentGateOk(rule, talentSet or {})
                and EvidenceSatisfied(rule.RequiresEvidence or rule.Evidence, evidence)
                and EvidenceNotExcluded(rule, evidence) then
            local expected = rule.BuffDuration
            if DM and DM.AdjustDuration then
                expected = DM:AdjustDuration(classToken, specID, talentSet or {}, rule.SpellId, rule.BuffDuration)
            end
            local durationOk = false
            if rule.MinDuration then
                durationOk = measuredDuration >= expected - TOLERANCE
            elseif rule.CanCancelEarly then
                durationOk = measuredDuration <= expected + TOLERANCE
                    and measuredDuration >= 1.0  -- ignore <1s flickers
                if durationOk and rule.MinCancelDuration then
                    if measuredDuration < rule.MinCancelDuration then
                        durationOk = false
                    end
                end
            else
                durationOk = math.abs(measuredDuration - expected) <= TOLERANCE
            end
            if durationOk then
                local diff = math.abs(measuredDuration - expected)
                local onCd = SpellOnCooldown(activeCDs, rule.SpellId)
                if onCd then
                    if diff < fallbackDiff then
                        fallbackDiff, fallbackMatch, fallbackExpected = diff, rule, expected
                    end
                else
                    if diff < bestDiff then
                        bestDiff, bestMatch, bestExpected = diff, rule, expected
                    end
                end
            end
        end
    end
    local chosen = bestMatch or fallbackMatch
    local expectedOut = bestMatch and bestExpected or fallbackExpected
    return chosen, expectedOut
end

-- MatchRule: try BySpec[specID] first (higher precision), fall back to
-- ByClass[classToken]. Any arg except measuredDuration/evidence can be nil.
-- `talentSet` is a `{[talentID] = true}` map used to gate RequiresTalent /
-- ExcludeIfTalent rules. Defaults to empty (no talents → RequiresTalent rules
-- skipped, ExcludeIfTalent rules always pass).
local function MatchRule(specID, classToken, measuredDuration, evidence, filterKind, talentSet, activeCDs)
    -- BySpec lookup (preferred)
    if specID and RULES.BySpec then
        local hit, expected = ScanRules(RULES.BySpec[specID], measuredDuration, evidence, filterKind, talentSet, activeCDs, classToken, specID)
        if hit then return hit, expected end
    end
    -- ByClass fallback
    if classToken and RULES.ByClass then
        return ScanRules(RULES.ByClass[classToken], measuredDuration, evidence, filterKind, talentSet, activeCDs, classToken, specID)
    end
    return nil
end

------------------------------------------------------------------------
-- Aura state machine: track appearances and disappearances
------------------------------------------------------------------------

local function GetUnitInfo(unit)
    local unitName, classToken, specID = nil, nil, nil
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
    -- Spec detection (may fail without inspect data; rules still work via class fallback)
    if GetInspectSpecialization then
        pcall(function()
            local s = GetInspectSpecialization(unit)
            if s and s ~= 0 and not (issecretvalue and issecretvalue(s)) then
                specID = s
            end
        end)
    end
    return unitName, classToken, specID
end

--- Scan harmful auras on `targetUnit` for known "consequence debuffs" applied
--- by an external CD (e.g. Forbearance from BoP). When one is found whose
--- spellID is in DEBUFF_CONSEQUENCE_IDS, stamp `lastDebuffTime[sourceUnit]`
--- so the next BuildEvidence() call from that source sees ev.Debuff = true.
local consequenceSeen = {}  -- [targetUnit..auraInstanceID] = true

local function ScanConsequenceDebuffs(targetUnit)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end
    local now = GetTime()
    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, targetUnit, "HARMFUL")
    if not ok or not auras then return end
    for _, aura in ipairs(auras) do
        local id = aura.spellId
        local aid = aura.auraInstanceID
        local src = aura.sourceUnit
        local key = targetUnit .. ":" .. tostring(aid)
        -- Gate on secret-value BEFORE indexing DEBUFF_CONSEQUENCE_IDS[id]:
        -- Midnight's sandbox throws "table index is secret" if id is a
        -- secret value, so the secret check must come first.
        if id and not (issecretvalue and issecretvalue(id))
                and DEBUFF_CONSEQUENCE_IDS[id]
                and src and not (issecretvalue and issecretvalue(src))
                and not consequenceSeen[key] then
            consequenceSeen[key] = true
            lastDebuffTime[src] = now
            if Log then
                Log:Log("DEBUG", string.format(
                    "AuraDetector: consequence debuff %d on %s from %s — Debuff evidence stamped",
                    id, targetUnit, src))
            end
        end
    end
end

--- Get current defensive aura IDs for a unit, mapped to the filter kind
--- that surfaced them. Returns { [auraInstanceID] = "BIG_DEFENSIVE" |
--- "EXTERNAL_DEFENSIVE" | "IMPORTANT" }. Precedence on duplicates: first filter
--- seen wins (BigDefensive → External → Important).
local function GetCurrentDefensiveAuraIDs(unit)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return {} end

    local ids = {}
    local filters = {
        { "HELPFUL|BIG_DEFENSIVE",      "BIG_DEFENSIVE" },
        { "HELPFUL|EXTERNAL_DEFENSIVE", "EXTERNAL_DEFENSIVE" },
        { "HELPFUL|IMPORTANT",          "IMPORTANT" },
    }
    for _, entry in ipairs(filters) do
        local filter, kind = entry[1], entry[2]
        local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, filter)
        if ok and auras then
            for _, aura in ipairs(auras) do
                local id = aura.auraInstanceID
                -- Reject: missing, secret, or in the reserved high range
                -- (Midnight's end-of-combat flush emits synthetic IDs
                -- near UINT32_MAX that don't map to real buffs).
                if id and not (issecretvalue and issecretvalue(id))
                        and type(id) == "number" and id < AURA_ID_RESERVED
                        and not ids[id] then
                    ids[id] = kind
                end
            end
        end
    end
    return ids
end

--- Sweep trackedAuras and evict entries older than MAX_AURA_DWELL seconds.
--- Prevents tracked-aura accumulation across combat boundaries (Midnight
--- synthetic IDs + combat-end buff flurries would otherwise leak memory).
local function SweepStaleTracked()
    local now = GetTime()
    local evicted = 0
    for id, tracked in pairs(trackedAuras) do
        if (now - (tracked.startTime or 0)) > MAX_AURA_DWELL then
            trackedAuras[id] = nil
            evicted = evicted + 1
        end
    end
    if evicted > 0 and Log then
        Log:Log("DEBUG", string.format(
            "AuraDetector: swept %d stale tracked auras (dwell>%ds)",
            evicted, MAX_AURA_DWELL))
    end
end

local filterDiagOnce = {}  -- unit → true

--- Called on every UNIT_AURA: diff current auras against tracked to detect add/remove.
local function ProcessAuraChanges(unit)
    local now = GetTime()
    local unitName, classToken, specID = GetUnitInfo(unit)
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
    for id, filterKind in pairs(currentIDs) do
        if not trackedAuras[id] then
            trackedAuras[id] = {
                startTime = now,
                unit = unit,
                unitName = unitName,
                classToken = classToken,
                specID = specID,
                filterKind = filterKind,
                talentSet = GetUnitTalents(unit),  -- stubbed: always {} in v1
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
                Log:Log("DEBUG", string.format(
                    "AuraDetector: %s NEW defensive aura id=%s kind=%s ev={%s}",
                    unitName, id, filterKind or "?", evStr))
            end
        end
    end

    -- Detect REMOVED auras (in tracked but not current)
    for id, tracked in pairs(trackedAuras) do
        if tracked.unit == unit and not currentIDs[id] then
            local elapsed = now - tracked.startTime
            trackedAuras[id] = nil  -- stop tracking

            -- Match rule by measured elapsed duration (filter-kind + talent
            -- gated + on-CD tiebreaker using current partyCD state). `expected`
            -- is the talent-adjusted buff duration the matcher accepted.
            local activeCDs = ActiveCooldownsForName(tracked.unitName)
            local rule, expected = MatchRule(tracked.specID, tracked.classToken,
                elapsed, tracked.evidence, tracked.filterKind, tracked.talentSet,
                activeCDs)
            -- Live observation proves the player has this CD — auto-create
            -- the partyCD entry if it wasn't pre-populated (spec-gated or
            -- talent-gated spells skip pre-population).
            if rule and partyCD[tracked.unitName] then
                if not AD:IsDuplicate(tracked.unitName, rule.SpellId) then
                    local created = not partyCD[tracked.unitName][rule.SpellId]
                    -- Talent-adjusted cooldown (e.g. Unbreakable Spirit -30%)
                    local DM = HexCD.DurationModifiers
                    local adjCD = rule.Cooldown
                    if DM and DM.AdjustCooldown then
                        adjCD = DM:AdjustCooldown(tracked.classToken, tracked.specID,
                            tracked.talentSet or {}, rule.SpellId, rule.Cooldown, elapsed)
                    end
                    partyCD[tracked.unitName][rule.SpellId] = {
                        readyTime = tracked.startTime + adjCD,
                        effectiveCD = adjCD,
                        castTime = tracked.startTime,
                    }
                    if Log then
                        Log:Log("DEBUG", string.format(
                            "AuraDetector: %s — %d CD %ds (measured %.1fs, rule %.1fs, kind=%s%s) [aura]",
                            tracked.unitName, rule.SpellId, rule.Cooldown,
                            elapsed, rule.BuffDuration, tracked.filterKind or "?",
                            created and ", NEW entry" or ""))
                    end
                end
            elseif not rule and elapsed > 3.5 and elapsed < 35 and Log then
                -- Log "no rule matched" only for plausibly-defensive durations
                -- (3.5..35s). Short auras (<3.5s) are almost always proc
                -- flickers; long auras (>35s) are passive/long-term buffs
                -- like Battle Shout or weapon enchants that are never
                -- tracked as CDs. The 30s upper bound catches the longest
                -- real defensives (Incarnation: ToL 30s) with a little slack.
                local evStr = ""
                for k in pairs(tracked.evidence) do evStr = evStr .. k .. " " end
                Log:Log("DEBUG", string.format(
                    "AuraDetector: %s — no rule matched (measured %.1fs, class=%s, kind=%s, ev={%s}) [aura]",
                    tracked.unitName, elapsed, tracked.classToken,
                    tracked.filterKind or "?", evStr))
            end
        end
    end
end

------------------------------------------------------------------------
-- Event handling
------------------------------------------------------------------------

local auraEventOnce = {}  -- unit → true (log first UNIT_AURA per unit per combat)

-- Accept party1..4 AND raid1..40 — raid membership is relevant when
-- HexCD is running during 10/20/40-man raids (raid1..40 tokens
-- replace party1..4 there, and some externals land on raid members
-- that aren't in our subgroup).
local function IsPartyUnit(unit)
    local Util = HexCD.Util
    if Util and Util.IsOtherGroupMemberUnit then
        return Util.IsOtherGroupMemberUnit(unit)
    end
    -- fallback for early load before Util is available
    return unit == "party1" or unit == "party2" or unit == "party3" or unit == "party4"
end

local function IsNameplateUnit(unit)
    if type(unit) ~= "string" then return false end
    return unit:match("^nameplate%d+$") ~= nil
end

-- Resolve a unit token (e.g. "player", "party2") to a short player name,
-- respecting secret-value guards. Returns nil if it can't be resolved to a
-- party-member name we're tracking.
local function UnitTokenToPartyName(unit)
    if type(unit) ~= "string" then return nil end
    if unit ~= "player" and not IsPartyUnit(unit) then return nil end
    local name = nil
    pcall(function()
        local n = UnitName(unit)
        if n and not (issecretvalue and issecretvalue(n)) then
            name = n:match("^([^-]+)") or n
        end
    end)
    return name
end

-- MiniCC-style nameplate aura scan: when an enemy nameplate's UNIT_AURA
-- fires, walk its HARMFUL auras and look for CC debuffs applied by a party
-- member. Stamp partyCD for that caster as a redundant source alongside
-- the cast fast-path (which can fail when Midnight redacts spellIDs on
-- UNIT_SPELLCAST_SUCCEEDED). Dedup via AD:IsDuplicate so we don't double-
-- stamp when both events fire for the same cast.
local function ScanNameplateForPartyCC(unit)
    if not C_UnitAuras or not C_UnitAuras.GetUnitAuras then return end
    local DB = HexCD.SpellDB
    local CS = HexCD.CommSync
    if not DB or not CS then return end
    local ok, auras = pcall(C_UnitAuras.GetUnitAuras, unit, "HARMFUL")
    if not ok or not auras then return end

    local partyCD = CS:GetPartyCD()
    local now = GetTime()

    -- Wrap the per-aura scan in pcall so a single tainted field doesn't
    -- erupt into hundreds of error spam lines when the UI rapidly cycles
    -- nameplates during a big pull.
    pcall(function()
        for _, a in ipairs(auras) do
            local spellID = a.spellId
            -- IMPORTANT: check issecretvalue BEFORE any arithmetic /
            -- comparison. Midnight's nameplate auras often return secret-
            -- valued spell IDs; `type() == "number"` returns true for them
            -- but `spellID > 0` taints. Short-circuit left-to-right so
            -- the order matters.
            if type(spellID) == "number"
               and not (issecretvalue and issecretvalue(spellID))
               and spellID > 0 then
                local info = DB:GetSpell(spellID)
                if info and info.category == "CC"
                   and type(info.cd) == "number" and info.cd > 0 then
                    local src = a.sourceUnit
                    -- sourceUnit may also be a secret value or nil on
                    -- restricted nameplates — UnitTokenToPartyName returns
                    -- nil for both cases, so no extra guard needed here.
                    local sourceName = UnitTokenToPartyName(src)
                    if sourceName and partyCD[sourceName]
                       and not AD:IsDuplicate(sourceName, spellID) then
                        partyCD[sourceName][spellID] = {
                            readyTime   = now + info.cd,
                            effectiveCD = info.cd,
                            castTime    = now,
                        }
                        if Log then
                            Log:Log("DEBUG", string.format(
                                "AuraDetector: nameplate-CC stamp — %s cast %s (%d) on %s, cd=%ds",
                                sourceName, tostring(info.name), spellID, unit, info.cd))
                        end
                    end
                end
            end
        end
    end)
end

local function OnEvent(self, event, ...)
    if event == "UNIT_AURA" then
        local unit, updateInfo = ...
        if unit == "player" or IsPartyUnit(unit) then
            -- Scan for consequence debuffs (Forbearance etc) on this unit,
            -- stamping the caster's Debuff evidence timestamp. Runs on player
            -- too so we catch e.g. BoP cast on us.
            ScanConsequenceDebuffs(unit)
        end
        -- Nameplate aura scan: enemy nameplates carry party-cast CC debuffs
        -- and this is a secondary stamp source for when UNIT_SPELLCAST_SUCCEEDED
        -- didn't deliver a clean spellID (Midnight sandbox redactions).
        if IsNameplateUnit(unit) then
            ScanNameplateForPartyCC(unit)
            return
        end
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
        -- Differential scan gate: when updateInfo is present and informative,
        -- skip the full ProcessAuraChanges unless something relevant changed.
        -- Relevant = isFullUpdate, any addedAuras (might be a defensive), or a
        -- removedAuraInstanceID that matches a tracked aura. Updates to
        -- existing auras (duration/stack changes) don't trigger our state
        -- machine, so they can be skipped.
        local force = HexCDDB and HexCDDB.forceFullAuraScan
        if updateInfo and type(updateInfo) == "table" and not force then
            if updateInfo.isFullUpdate then
                ProcessAuraChanges(unit)
            else
                local relevant = false
                if updateInfo.addedAuras and #updateInfo.addedAuras > 0 then
                    relevant = true
                elseif updateInfo.removedAuraInstanceIDs then
                    for _, aid in ipairs(updateInfo.removedAuraInstanceIDs) do
                        if trackedAuras[aid] and trackedAuras[aid].unit == unit then
                            relevant = true; break
                        end
                    end
                end
                if relevant then ProcessAuraChanges(unit) end
            end
        else
            ProcessAuraChanges(unit)
        end

    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if IsPartyUnit(unit) then
            lastCastTime[unit] = GetTime()
            -- Cast fast-path: if the cast spell ID has a direct non-secret
            -- mapping to a Cast-only rule, stamp partyCD immediately without
            -- waiting for UNIT_AURA to surface the buff. Skip when spellID
            -- is a secret value (Midnight 12.0 locks down party casts).
            if spellID and type(spellID) == "number"
                    and not (issecretvalue and issecretvalue(spellID)) then
                local rule = castFastPath[spellID]
                if rule then
                    local CS = HexCD.CommSync
                    if CS then
                        local partyCD = CS:GetPartyCD()
                        local unitName = UnitName and UnitName(unit)
                        if unitName then
                            unitName = unitName:match("^([^-]+)") or unitName
                        end
                        if unitName and partyCD[unitName] then
                            if not AD:IsDuplicate(unitName, rule.SpellId) then
                                local now = GetTime()
                                -- Fast-path has no measured duration yet
                                -- (the buff just started), so PostBuff-type
                                -- talents fall back to baseCooldown. Simple
                                -- add/mult still applies here.
                                local DM = HexCD.DurationModifiers
                                local talents = GetUnitTalents(unit) or {}
                                local classToken, specID = nil, nil
                                pcall(function()
                                    local _, c = UnitClass(unit)
                                    if c and not (issecretvalue and issecretvalue(c)) then classToken = c end
                                end)
                                if HexCD.SpecCache and HexCD.SpecCache.Get then
                                    specID = HexCD.SpecCache:Get(unitName)
                                end
                                local adjCD = rule.Cooldown
                                if DM and DM.AdjustCooldown then
                                    adjCD = DM:AdjustCooldown(classToken, specID, talents, rule.SpellId, rule.Cooldown, 0)
                                end
                                partyCD[unitName][rule.SpellId] = {
                                    readyTime = now + adjCD,
                                    effectiveCD = adjCD,
                                    castTime = now,
                                }
                                if Log then
                                    Log:Log("DEBUG", string.format(
                                        "AuraDetector: %s — %d CD %ds [cast-fastpath]",
                                        unitName, rule.SpellId, adjCD))
                                end
                            end
                        end
                    end
                end
            end
        end

    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        local unit = ...
        if IsPartyUnit(unit) then
            lastShieldTime[unit] = GetTime()
        end

    elseif event == "UNIT_FLAGS" then
        local unit = ...
        if IsPartyUnit(unit) then
            -- Distinguish Hunter Feign Death flag toggles from all other flag
            -- changes. UnitIsFeignDeath(unit) returns the current state; if it
            -- differs from what we last saw, this UNIT_FLAGS fire is the feign
            -- event and we stamp FeignDeath instead of Flags. Otherwise it's
            -- a generic flag change (e.g. Turtle's immune flag) and we stamp
            -- Flags as before.
            local now = GetTime()
            local curFeign = false
            if UnitIsFeignDeath then
                local ok, v = pcall(UnitIsFeignDeath, unit)
                if ok then curFeign = v and true or false end
            end
            if curFeign ~= (lastFeignState[unit] or false) then
                lastFeignTime[unit] = now
                lastFeignState[unit] = curFeign
            else
                lastFlagsTime[unit] = now
            end
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        AD:RegisterPartyUnits()

    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Combat ended — sweep stale tracked auras after a short settle
        -- period so the end-of-combat aura flurry (soulstone / feast /
        -- Midnight's synthetic high-ID auras) gets evicted rather than
        -- accumulating for the rest of the session.
        if C_Timer and C_Timer.After then
            C_Timer.After(3, SweepStaleTracked)
        else
            SweepStaleTracked()
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- A CC might already be on the mob when its nameplate appears.
        -- Scan immediately to catch that case.
        local unit = ...
        if IsNameplateUnit(unit) then
            ScanNameplateForPartyCC(unit)
        end
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
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    -- Nameplate add/remove events ensure UNIT_AURA fires reliably for
    -- nameplateN units. NAME_PLATE_UNIT_ADDED also lets us do an initial
    -- aura sweep if a CC is already applied when the nameplate appears.
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_REMOVED")

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
    wipe(lastDebuffTime)
    wipe(lastFeignTime)
    wipe(lastFeignState)
    wipe(consequenceSeen)
    wipe(filterDiagOnce)
    wipe(auraEventOnce)
end

-- `castFastPath` is forward-declared above OnEvent so the event handler's
-- closure captures this local correctly. Populated by BuildCastFastPath at
-- load time below.
local function BuildCastFastPath(rules)
    wipe(castFastPath)
    local function scanList(list)
        if not list then return end
        for _, rule in ipairs(list) do
            local ev = rule.RequiresEvidence or rule.Evidence
            -- Fast-path eligible: "Cast" only evidence, no talent gates
            -- (which would require a talent check before firing). MiniCC
            -- allowed more categories; we keep the conservative cut.
            local castOnly = (ev == "Cast")
                or (type(ev) == "table" and #ev == 1 and ev[1] == "Cast")
            if castOnly and not rule.RequiresTalent and not rule.ExcludeIfTalent then
                local sid = rule.SpellId
                if sid and not castFastPath[sid] then
                    castFastPath[sid] = rule
                end
            end
        end
    end
    if rules.BySpec then
        for _, list in pairs(rules.BySpec) do scanList(list) end
    end
    if rules.ByClass then
        for _, list in pairs(rules.ByClass) do scanList(list) end
    end

    -- SpellDB-backed fallback: any tracked spell with cd > 0 gets a synthetic
    -- Cast-only rule if no explicit AuraRules entry covers it. This makes
    -- SpellDB the single source of truth for "track a CD on cast" — without
    -- needing a hand-written rule per CC / UTILITY / offensive spell. Explicit
    -- rules (with buff-duration matching, talent gates, etc.) still win since
    -- we only fill gaps via `not castFastPath[sid]`.
    --
    -- Entries with cd = 0 (no baseline CD like Polymorph, Banish, Fear) are
    -- skipped — nothing to stamp. PvP-talent entries are skipped — they
    -- never pre-pop and shouldn't surface unless explicitly rule-matched.
    local DB = HexCD.SpellDB
    if DB and DB.GetAllSpells then
        for sid, info in pairs(DB:GetAllSpells()) do
            if not castFastPath[sid]
               and type(info.cd) == "number" and info.cd > 0
               and not info.pvpTalent then
                castFastPath[sid] = {
                    SpellId = sid,
                    Cooldown = info.cd,
                    RequiresEvidence = "Cast",
                    CastOnly = true,
                    Important = true,
                    -- No BuffDuration — the fast-path doesn't need it.
                    -- No RequiresTalent — the cast event proves the player
                    -- has the spell (client refuses to cast untalented).
                    _synthetic = true,  -- marker for debugging / tests
                }
            end
        end
    end
end

-- Prefer the richer rule database from AuraRules.lua (ported from MiniCC).
-- If AuraRules.lua was loaded before this file, its table replaces the inline
-- fallback. Runs at file load so tests and runtime both see the ported set.
if HexCD and HexCD.AuraRules then
    RULES = HexCD.AuraRules
    BuildCastFastPath(RULES)
    if Log then
        local specCount, classCount = 0, 0
        if RULES.BySpec then for _ in pairs(RULES.BySpec) do specCount = specCount + 1 end end
        if RULES.ByClass then for _ in pairs(RULES.ByClass) do classCount = classCount + 1 end end
        Log:Log("DEBUG", string.format(
            "AuraDetector: loaded HexCD.AuraRules (%d specs, %d classes)",
            specCount, classCount))
    end
end

------------------------------------------------------------------------
-- Public API — spell lookup by ID and class/spec iteration
--
-- Replaces SpellDB as the CD source of truth. Callers pass their known
-- talents (via TalentCache or explicit) when they want talent-adjusted
-- cooldowns; without talents the base rule.Cooldown is returned.
------------------------------------------------------------------------

--- Find the first rule whose SpellId matches. Scans BySpec then ByClass.
--- When multiple variants exist (talent-gated duplicates) this returns
--- whichever appears first — good enough for CD lookup since Cooldown
--- is usually constant across variants.
--- @param spellID number
--- @return table|nil  rule
function AD:GetRuleBySpellID(spellID)
    if not spellID then return nil end
    if RULES.BySpec then
        for _, list in pairs(RULES.BySpec) do
            for _, rule in ipairs(list) do
                if rule.SpellId == spellID then return rule end
            end
        end
    end
    if RULES.ByClass then
        for _, list in pairs(RULES.ByClass) do
            for _, rule in ipairs(list) do
                if rule.SpellId == spellID then return rule end
            end
        end
    end
    return nil
end

--- Get deduplicated rules applicable to a (class, spec) player. Honours
--- talent gates (RequiresTalent / ExcludeIfTalent) — rules that can't
--- apply to this talent set are skipped. Used for pre-populating the
--- partyCD map with all possible CDs for a class+spec.
--- @param classToken string e.g. "PALADIN"
--- @param specID number? spec ID (nil → class baseline only)
--- @param talentSet table? {[talentSpellID] = rank}
--- @return table[]  deduplicated list of rules, keyed by SpellId
function AD:GetRulesForClassSpec(classToken, specID, talentSet)
    local out = {}
    local seen = {}
    talentSet = talentSet or {}

    local function consider(rule)
        if not rule.SpellId or seen[rule.SpellId] then return end
        -- Apply talent gate using the internal helper (closes over the
        -- same TalentPresent/TalentGateOk used at runtime).
        if rule.RequiresTalent ~= nil and not TalentPresent(rule.RequiresTalent, talentSet) then
            return
        end
        if rule.ExcludeIfTalent ~= nil and TalentPresent(rule.ExcludeIfTalent, talentSet) then
            return
        end
        seen[rule.SpellId] = true
        out[#out + 1] = rule
    end

    if specID and RULES.BySpec and RULES.BySpec[specID] then
        for _, rule in ipairs(RULES.BySpec[specID]) do consider(rule) end
    end
    if classToken and RULES.ByClass and RULES.ByClass[classToken] then
        for _, rule in ipairs(RULES.ByClass[classToken]) do consider(rule) end
    end
    return out
end

-- Test-only accessors (avoid exposing internals in addon code)
function AD:_testGetRules()
    return RULES
end

function AD:_testMatchRule(specID, classToken, measuredDuration, evidence, filterKind, talentSet, activeCDs)
    return MatchRule(specID, classToken, measuredDuration, evidence, filterKind, talentSet, activeCDs)
end

function AD:_testBuildEvidence(unit, now)
    return BuildEvidence(unit, now)
end

function AD:_testStampDebuff(unit, when)
    lastDebuffTime[unit] = when
end

function AD:_testGetLastDebuffTime(unit)
    return lastDebuffTime[unit]
end

function AD:_testStampFlags(unit, when)
    lastFlagsTime[unit] = when
end

function AD:_testStampFeign(unit, when)
    lastFeignTime[unit] = when
end

function AD:_testStampCast(unit, when)
    lastCastTime[unit] = when
end

--- Drive UNIT_FLAGS through the real event path. Used in tests to verify
--- the feign-vs-flags routing works on a live flag toggle.
function AD:_testFireUnitFlags(unit)
    OnEvent(nil, "UNIT_FLAGS", unit)
end

-- Force a consequence-debuff scan of `targetUnit`. Used in tests in lieu of
-- firing UNIT_AURA events.
function AD:_testScanConsequenceDebuffs(targetUnit)
    ScanConsequenceDebuffs(targetUnit)
end

function AD:_testKnownConsequenceIDs()
    return DEBUFF_CONSEQUENCE_IDS
end

function AD:_testFastPathFor(spellID)
    return castFastPath[spellID]
end

function AD:_testFireCast(unit, spellID)
    OnEvent(nil, "UNIT_SPELLCAST_SUCCEEDED", unit, nil, spellID)
end

function AD:_testFireUnitAura(unit, updateInfo)
    OnEvent(nil, "UNIT_AURA", unit, updateInfo)
end

function AD:_testGetTrackedAurasCount()
    local n = 0
    for _ in pairs(trackedAuras) do n = n + 1 end
    return n
end

function AD:_testInjectTrackedAura(auraInstanceID, data)
    trackedAuras[auraInstanceID] = data
end

function AD:_testFireRegenEnabled()
    OnEvent(nil, "PLAYER_REGEN_ENABLED")
end

function AD:_testSweepStale()
    SweepStaleTracked()
end
