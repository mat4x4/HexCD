------------------------------------------------------------------------
-- HexCD: TalentCache — per-unit talent set lookup
--
-- Maintains a cache of { [talentSpellID] = activeRank } per player, keyed by
-- name-realm (so cache survives unit-token churn). Data is sourced from
-- `C_Traits` for the local player immediately, and for inspected party members
-- after INSPECT_READY fires.
--
-- Consumers (AuraDetector.GetUnitTalents) call `TalentCache:GetTalentsForUnit(unit)`
-- which returns the cached set, or an empty table if unknown. Rules gated on
-- `RequiresTalent` / `ExcludeIfTalent` use this set to decide whether to match.
--
-- Invalidation:
--   * PLAYER_TALENT_UPDATE  → refresh local player
--   * INSPECT_READY guid    → refresh the unit that just came back (name resolved)
--   * GROUP_ROSTER_UPDATE   → drop entries for players no longer in group
------------------------------------------------------------------------

HexCD = HexCD or {}
HexCD.TalentCache = {}

local TC = HexCD.TalentCache
local Log = HexCD.DebugLog

-- name-realm → { [talentSpellID]=rank, _source="live"|"default", _at=<timestamp> }
local cache = {}

-- Event frame
local eventFrame = nil

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Strip realm from a unit name (e.g. "Hexastyle-Area52" → "Hexastyle").
--- Consumers key the cache by name-only today; switching to full name-realm
--- is a one-line change here.
local function KeyForName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

--- Read talents from WoW's C_Traits API for the given configID.
--- Returns `{[spellID]=rank}` or `nil` if the API chain didn't yield data.
local function ReadTalentsFromConfig(configID)
    if not configID or configID == 0 then return nil end
    if not C_Traits or not C_Traits.GetConfigInfo then return nil end

    local configInfo = C_Traits.GetConfigInfo(configID)
    if not configInfo or not configInfo.treeIDs then return nil end

    local out = {}
    for _, treeID in ipairs(configInfo.treeIDs) do
        local nodes = C_Traits.GetTreeNodes and C_Traits.GetTreeNodes(treeID)
        if nodes then
            for _, nodeID in ipairs(nodes) do
                local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
                -- activeRank > 0 means the talent is purchased
                if nodeInfo and nodeInfo.activeRank and nodeInfo.activeRank > 0 and nodeInfo.activeEntry then
                    local entryID = nodeInfo.activeEntry.entryID
                    local entryInfo = C_Traits.GetEntryInfo(configID, entryID)
                    if entryInfo and entryInfo.definitionID then
                        local defInfo = C_Traits.GetDefinitionInfo(entryInfo.definitionID)
                        if defInfo and defInfo.spellID then
                            local sid = defInfo.spellID
                            if not (issecretvalue and issecretvalue(sid)) then
                                out[sid] = nodeInfo.activeRank
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

--- Read talents from the API for a given unit token.
--- Local player: via `C_ClassTalents.GetActiveConfigID()`.
--- Inspected party: via `C_ClassTalents.GetInspectClassConfigID(unit)`.
--- Returns `{[spellID]=rank}` or `nil` if the inspect/config isn't ready yet.
local function ReadTalentsForUnit(unit)
    if not C_ClassTalents then return nil end
    local configID = nil
    if unit == "player" then
        if C_ClassTalents.GetActiveConfigID then
            configID = C_ClassTalents.GetActiveConfigID()
        end
    else
        if C_ClassTalents.GetInspectClassConfigID then
            configID = C_ClassTalents.GetInspectClassConfigID(unit)
        end
    end
    return ReadTalentsFromConfig(configID)
end

------------------------------------------------------------------------
-- Cache ops
------------------------------------------------------------------------

--- Put `talents` into the cache under `name`, tagging source.
--- `source` is "live" (read from C_Traits) or "default" (Phase 2 fallback).
local function Store(name, talents, source)
    local key = KeyForName(name)
    if not key then return end
    cache[key] = talents or {}
    cache[key]._source = source or "live"
    cache[key]._at = GetTime and GetTime() or 0
    if Log then
        local n = 0
        for k in pairs(talents or {}) do
            if type(k) == "number" then n = n + 1 end
        end
        Log:Log("DEBUG", string.format(
            "TalentCache: stored %d talents for %s (source=%s)",
            n, key, source or "live"))
    end
end

--- Refresh the local player's talent set. Safe to call anytime.
local function RefreshPlayer()
    local name = UnitName and UnitName("player") or nil
    if not name then return end
    local talents = ReadTalentsForUnit("player")
    if talents then
        Store(name, talents, "live")
    end
end

--- Refresh a party member's talent set. Call after INSPECT_READY for that unit.
--- `unit` is the unit token (e.g. "party1"); we resolve its name internally.
local function RefreshUnit(unit)
    if unit == nil then return end
    if unit == "player" then return RefreshPlayer() end
    local name = UnitName and UnitName(unit) or nil
    if not name then return end
    local talents = ReadTalentsForUnit(unit)
    if talents then
        Store(name, talents, "live")
    end
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Resolve class/spec for a unit without depending on CommSync's cache.
--- Returns (classToken, specID) — either may be nil.
local function ResolveClassAndSpec(unit)
    local classToken, specID = nil, nil
    pcall(function()
        local _, ct = UnitClass(unit)
        if ct and not (issecretvalue and issecretvalue(ct)) then
            classToken = ct
        end
        if unit == "player" then
            if GetSpecialization and GetSpecializationInfo then
                local idx = GetSpecialization()
                if idx and idx > 0 then
                    local sid = GetSpecializationInfo(idx)
                    if sid and sid ~= 0 and not (issecretvalue and issecretvalue(sid)) then
                        specID = sid
                    end
                end
            end
        else
            if GetInspectSpecialization then
                local sid = GetInspectSpecialization(unit)
                if sid and sid ~= 0 and not (issecretvalue and issecretvalue(sid)) then
                    specID = sid
                end
            end
        end
    end)
    return classToken, specID
end

--- Get the talent set for a unit. Returns `{[spellID]=rank}`, never nil.
--- Lookup order:
---   1. Cache hit by UnitName(unit) → return stored talents (live or default).
---   2. Attempt lazy API read for the local player (covers boot race).
---   3. Fallback to TalentDefaults.Compose(class, spec) — the canonical PvE
---      "assumed talents" set from MiniCC. Cached under the "default" source
---      tag so repeated lookups don't recompose.
---   4. Still nothing resolvable → empty table.
function TC:GetTalentsForUnit(unit)
    if not unit then return {} end
    local name = UnitName and UnitName(unit) or nil
    local key = KeyForName(name)
    if key and cache[key] then
        return cache[key]
    end
    -- Lazy populate
    if unit == "player" then
        RefreshPlayer()
        if key and cache[key] then return cache[key] end
    end
    -- Defaults fallback — canonical PvE builds
    if HexCD.TalentDefaults and HexCD.TalentDefaults.Compose and key then
        local classToken, specID = ResolveClassAndSpec(unit)
        if classToken or specID then
            local defaults = HexCD.TalentDefaults:Compose(classToken, specID)
            -- Only cache under "default" if we actually produced something
            local has = false
            for _ in pairs(defaults) do has = true; break end
            if has then
                Store(name, defaults, "default")
                return cache[key]
            end
        end
    end
    return {}
end

--- Invalidate a unit's cache entry (forces next GetTalentsForUnit to re-read).
function TC:Invalidate(unit)
    local name = UnitName and UnitName(unit) or nil
    local key = KeyForName(name)
    if key then cache[key] = nil end
end

--- Remove cache entries whose player is no longer in the group (except player).
function TC:PruneAbsent()
    local keep = {}
    if UnitName then
        local n = UnitName("player")
        local k = KeyForName(n)
        if k then keep[k] = true end
        for i = 1, 4 do
            local uid = "party" .. i
            if UnitExists and UnitExists(uid) then
                local pn = UnitName(uid)
                local pk = KeyForName(pn)
                if pk then keep[pk] = true end
            end
        end
    end
    for k in pairs(cache) do
        if not keep[k] then cache[k] = nil end
    end
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local function OnEvent(self, event, ...)
    if event == "PLAYER_TALENT_UPDATE" or event == "TRAIT_CONFIG_UPDATED" then
        RefreshPlayer()
    elseif event == "INSPECT_READY" then
        -- INSPECT_READY fires with a GUID. Map GUID → unit token.
        local guid = ...
        for i = 1, 4 do
            local uid = "party" .. i
            if UnitExists and UnitExists(uid) and UnitGUID and UnitGUID(uid) == guid then
                RefreshUnit(uid)
                return
            end
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        TC:PruneAbsent()
    elseif event == "PLAYER_ENTERING_WORLD" then
        RefreshPlayer()
    end
end

function TC:Init()
    if eventFrame then return end
    eventFrame = CreateFrame("Frame", "HexCDTalentCacheFrame")
    eventFrame:SetScript("OnEvent", OnEvent)
    eventFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
    eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
    eventFrame:RegisterEvent("INSPECT_READY")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    RefreshPlayer()
    if Log then
        Log:Log("DEBUG", "TalentCache: initialized")
    end
end

------------------------------------------------------------------------
-- Test-only accessors
------------------------------------------------------------------------

--- Inject a talent set directly for a given name (bypasses API chain).
--- Used by tests to simulate inspected/known-talent states without threading
--- a full C_Traits mock chain.
function TC:_testSetTalents(name, talents, source)
    Store(name, talents or {}, source or "live")
end

function TC:_testClear()
    cache = {}
end

function TC:_testGetCacheEntry(name)
    return cache[KeyForName(name)]
end

--- Force-drive OnEvent from tests.
function TC:_testFireEvent(event, ...)
    OnEvent(nil, event, ...)
end

--- Expose the (private) C_Traits reader path for coverage tests.
function TC:_testReadTalentsForUnit(unit)
    return ReadTalentsForUnit(unit)
end
