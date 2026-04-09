------------------------------------------------------------------------
-- HexCD: Dynamic Trash Planner
-- Scans pull composition at runtime and assigns CDs based on danger tier.
-- Route-independent — works with any M+ route for a given dungeon.
--
-- Midnight (12.0) restrictions: UnitName/UnitGUID/UnitCreatureID are secret.
-- Non-secret APIs used: UnitClassBase, UnitClassification, UnitLevel.
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.DynamicTrashPlanner = {}

local Planner = HexCDReminder.DynamicTrashPlanner
local Log = HexCDReminder.DebugLog

-- ============================================================
-- Secret Value Safety
-- ============================================================

--- Safely extract a non-secret value from a pcall result.
--- Returns nil if the value is a Midnight secret.
local function SafeValue(ok, val)
    if not ok or val == nil then return nil end
    -- Test if the value is secret by attempting a comparison
    local cmpOk = pcall(function() return val == val end)
    if not cmpOk then return nil end
    return val
end

-- ============================================================
-- Composition Scanning
-- ============================================================

--- Scan hostile nameplates and build a composition histogram.
--- Returns: composition table, hostile count, raw breakdown.
--- Composition key format: "classification:level:classBase" (e.g. "elite:90:PALADIN")
function Planner:ScanComposition()
    local comp = {}       -- { ["elite:90:PALADIN"] = 3, ... }
    local hostileCount = 0
    local casterCount = 0
    local meleeCount = 0
    local lieutenantCount = 0
    local trivialCount = 0

    for i = 1, 40 do
        local unit = "nameplate" .. i
        if UnitExists(unit) and UnitCanAttack("player", unit) then
            local classification = SafeValue(pcall(UnitClassification, unit))
            local level = SafeValue(pcall(UnitLevel, unit))
            local classBase = SafeValue(pcall(function()
                if UnitClassBase then return UnitClassBase(unit) end
                return nil
            end))

            if classification and level and classBase then
                hostileCount = hostileCount + 1
                local key = classification .. ":" .. tostring(level) .. ":" .. classBase

                comp[key] = (comp[key] or 0) + 1

                -- Classify mob role
                local isCaster = (classBase == "PALADIN" or classBase == "MAGE")
                local isLieutenant = (tonumber(level) == 91)
                local isTrivial = (classification == "minus" or classification == "normal")

                if isLieutenant then
                    lieutenantCount = lieutenantCount + 1
                elseif isTrivial then
                    trivialCount = trivialCount + 1
                elseif isCaster then
                    casterCount = casterCount + 1
                else
                    meleeCount = meleeCount + 1
                end
            end
        end
    end

    return {
        histogram = comp,
        hostileCount = hostileCount,
        casterCount = casterCount,
        meleeCount = meleeCount,
        lieutenantCount = lieutenantCount,
        trivialCount = trivialCount,
    }
end

-- ============================================================
-- Danger Tier Classification
-- ============================================================

--- Classify a pull's danger tier based on composition.
--- Returns: tier number (0-3), tier label, estimated DPS.
function Planner:ClassifyTier(scan, mobProfile)
    local casters = scan.casterCount
    local melee = scan.meleeCount
    local lieutenants = scan.lieutenantCount
    local trivials = scan.trivialCount

    -- Estimate total party damage intake
    local estimatedDPS = 0
    if mobProfile then
        estimatedDPS = casters * mobProfile.casterEliteDPS
            + melee * mobProfile.meleeEliteDPS
            + lieutenants * mobProfile.lieutenantDPS
            + trivials * mobProfile.trivialDPS
    end

    -- Tier 3: massive — 3+ casters or overwhelming damage
    if casters >= 3 or (casters >= 2 and lieutenants >= 1) then
        return 3, "massive", estimatedDPS
    end

    -- Tier 2: heavy — 2+ casters OR any lieutenant
    if casters >= 2 or lieutenants >= 1 then
        return 2, "heavy", estimatedDPS
    end

    -- Tier 1: light — 1 caster OR 3+ melee
    if casters >= 1 or melee >= 3 then
        return 1, "light", estimatedDPS
    end

    -- Tier 0: trivial — all melee, small pull
    return 0, "trivial", estimatedDPS
end

-- ============================================================
-- CD Assignment Generation
-- ============================================================

--- Generate CD assignments from a tier's CD templates.
--- Filters out CDs that are still on cooldown (using the CD ledger).
--- Returns: assignments array compatible with TimerEngine, maxCDs count.
function Planner:GenerateAssignments(tierTemplates, cdLedger)
    if not tierTemplates then return {}, 0 end

    local assignments = {}
    local maxCDs = 0
    local now = GetTime()

    for _, template in ipairs(tierTemplates) do
        -- Check CD availability from the ledger
        local spellID = template.abilityGameID
        local available = true
        if cdLedger and cdLedger[spellID] then
            local readyAt = cdLedger[spellID].readyAt
            if readyAt and readyAt > now then
                local remaining = readyAt - now
                Log:Log("DEBUG", string.format(
                    "DynamicPlanner: %s (id=%d) on CD — %.0fs remaining, skipping",
                    template.abilityName, spellID, remaining))
                available = false
            end
        end

        -- Only include CDs that are available (or will be within a reasonable window)
        -- Always include markers (Cat Weave, Ramp) regardless of CD state
        local isMarker = (spellID == 768 or spellID == 774)
        if available or isMarker then
            local scheduling = nil
            if template.scheduling == "immediate" then
                scheduling = { mode = "immediate" }
            elseif template.scheduling == "sequential" then
                scheduling = {
                    mode = "sequential",
                    order = template.order or 1,
                    minDelaySec = template.delaySec or 5,
                }
            end

            assignments[#assignments + 1] = {
                timeSec = template.delaySec or 0,
                abilityGameID = spellID,
                abilityName = template.abilityName,
                rationale = "Dynamic trash plan",
                scheduling = scheduling,
                windowSec = template.windowSec,
            }

            -- Count real CDs (not markers)
            if not isMarker then
                maxCDs = maxCDs + 1
            end
        end
    end

    return assignments, maxCDs
end

-- ============================================================
-- Plan Entry Point
-- ============================================================

--- Plan CDs for a trash pull based on composition scan.
--- Called by MythicPlusEngine:OnCombatStart() when not in a boss encounter.
---
--- @param scan table — result from ScanComposition()
--- @param dungeonPlan table — the loaded DungeonCDPlan
--- @param cdLedger table — current CD availability { [spellID] = { readyAt } }
--- @return table|nil — adapted plan for TimerEngine:Start(), or nil if no plan
function Planner:Plan(scan, dungeonPlan, cdLedger)
    local mobProfile = dungeonPlan.mobProfile
    local tiers = dungeonPlan.trashCDTiers

    if not tiers then
        Log:Log("DEBUG", "DynamicPlanner: No trashCDTiers in plan — skipping dynamic planning")
        return nil
    end

    -- Classify the pull
    local tier, tierLabel, estimatedDPS = self:ClassifyTier(scan, mobProfile)

    -- Log composition and tier
    local compParts = {}
    for key, count in pairs(scan.histogram) do
        compParts[#compParts + 1] = count .. "x " .. key
    end
    table.sort(compParts)
    Log:Log("INFO", string.format(
        "DynamicPlanner: %d hostiles (%d casters, %d melee, %d lt, %d trivial) → Tier %d (%s), est. %dk DPS",
        scan.hostileCount, scan.casterCount, scan.meleeCount,
        scan.lieutenantCount, scan.trivialCount,
        tier, tierLabel, math.floor(estimatedDPS / 1000)))
    if #compParts > 0 then
        Log:Log("INFO", string.format("DynamicPlanner: Composition: [%s]", table.concat(compParts, ", ")))
    end

    -- Get the tier's CD templates
    local tierKey = "tier" .. tier
    local templates = tiers[tierKey]
    if not templates or #templates == 0 then
        Log:Log("INFO", string.format("DynamicPlanner: No CD templates for %s — idle", tierKey))
        return nil
    end

    -- Generate assignments, filtering by CD availability
    local assignments, maxCDs = self:GenerateAssignments(templates, cdLedger)

    if #assignments == 0 then
        Log:Log("INFO", "DynamicPlanner: All CDs on cooldown — no assignments")
        return nil
    end

    -- Build adapted plan for TimerEngine
    local adapted = {
        encounterID = 0,
        difficulty = 8, -- M+ constant
        fightDurationSec = 0,
        damageTimeline = {},
        healerAssignments = {
            {
                className = dungeonPlan.className,
                specName = dungeonPlan.specName,
                playerName = dungeonPlan.playerName,
                assignments = assignments,
            },
        },
        patchVersion = dungeonPlan.patchVersion,
        _useDynamicScheduling = true,
        _cdAvailability = {},
        _maxCDs = maxCDs,
        _dynamicTier = tier,
        _dynamicTierLabel = tierLabel,
    }

    -- Pass CD availability for sequential defer logic
    local now = GetTime()
    if cdLedger then
        for spellID, entry in pairs(cdLedger) do
            local remaining = entry.readyAt - now
            if remaining > 0 then
                adapted._cdAvailability[spellID] = remaining
            end
        end
    end

    Log:Log("INFO", string.format(
        "DynamicPlanner: Built plan — Tier %d (%s), %d CDs, maxCDs=%d",
        tier, tierLabel, #assignments, maxCDs))

    return adapted
end
