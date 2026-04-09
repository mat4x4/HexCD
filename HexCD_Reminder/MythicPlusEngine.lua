-- MythicPlusEngine.lua — M+ dungeon state machine
-- Boss pulls: detected via ENCOUNTER_START → loads fixed boss section from plan.
-- Trash pulls: detected via PLAYER_REGEN_DISABLED → DynamicTrashPlanner scans
--   pull composition (UnitClassBase/UnitClassification/UnitLevel) and assigns CDs
--   based on danger tier. Route-independent.

local Engine = HexCDReminder.TimerEngine
local Config = HexCDReminder.Config
local Log    = HexCDReminder.DebugLog

local MP = {}
HexCDReminder.MythicPlus = MP

-- ============================================================
-- State
-- ============================================================
MP.inMythicPlus        = false
MP.challengeMapID      = nil
MP.dungeonPlan         = nil   -- DungeonCDPlan table (from bundled or imported)
MP.activeBossEncounterID = nil -- set during ENCOUNTER_START within M+
MP.inCombat            = false
MP.currentSectionId    = nil
MP.matchedSections     = {}    -- track which boss sections have been matched
MP.cdLedger            = {}    -- spellID → { readyAt = GetTime() + remaining }
MP.trashPullCount      = 0     -- counter for dynamic trash pull IDs

--- Get tracked spell IDs from CooldownTracker's active spec table.
local function GetTrackedSpellIDs()
    local tracker = HexCDReminder.CooldownTracker
    if not tracker then return {} end
    local tracked = tracker:GetTrackedCDs()
    local ids = {}
    for spellID in pairs(tracked) do
        ids[#ids + 1] = spellID
    end
    return ids
end

-- ============================================================
-- CD Availability Ledger
-- Persists across sections to inform dynamic scheduling.
-- ============================================================

--- Snapshot current CD state from CooldownTracker into the ledger.
function MP:SnapshotCDState()
    local tracker = HexCDReminder.CooldownTracker
    if not tracker then return end

    local now = GetTime()
    for _, spellID in ipairs(GetTrackedSpellIDs()) do
        local ready, remaining = tracker:IsReady(spellID)
        if not ready and remaining > 0 then
            self.cdLedger[spellID] = { readyAt = now + remaining }
            Log:Log("DEBUG", string.format("CD Ledger: %d on CD, ready in %.1fs", spellID, remaining))
        else
            self.cdLedger[spellID] = nil
        end
    end
end

--- Get current CD availability as { [spellID] = remainingSec }.
--- Returns only CDs that are still on cooldown.
function MP:GetCDAvailability()
    local result = {}
    local now = GetTime()
    for spellID, entry in pairs(self.cdLedger) do
        local remaining = entry.readyAt - now
        if remaining > 0 then
            result[spellID] = remaining
        end
    end
    return result
end

-- ============================================================
-- Boss Section Lookup
-- ============================================================

--- Find a boss section by encounterID within the dungeon plan.
local function FindBossSection(encounterID, plan)
    for i, section in ipairs(plan.sections) do
        if section.type == "boss" and section.encounterID == encounterID then
            return i
        end
    end
    return nil
end

-- ============================================================
-- Plan Adapter: section → HealingCDPlan shape for TimerEngine
-- ============================================================

local function SectionToPlan(section, dungeonPlan)
    return {
        encounterID      = section.encounterID or 0,
        difficulty        = 8, -- M+ difficulty constant
        fightDurationSec  = section.durationSec or 0,
        damageTimeline    = section.damageEvents or {},
        healerAssignments = {
            {
                className  = dungeonPlan.className,
                specName   = dungeonPlan.specName,
                playerName = dungeonPlan.playerName,
                assignments = section.assignments,
            },
        },
        patchVersion = dungeonPlan.patchVersion,
    }
end

-- ============================================================
-- Nameplate Rescan (for delayed nameplate registration)
-- Nameplates appear 0-1s after PLAYER_REGEN_DISABLED.
-- Polls every 0.5s for up to 3s, re-attempts dynamic planning.
-- ============================================================

local rescanFrame = nil
local rescanDeadline = 0
local RESCAN_INTERVAL = 0.5
local RESCAN_DURATION = 3

local function StopRescan()
    if rescanFrame then
        rescanFrame:SetScript("OnUpdate", nil)
    end
end

local function StartRescan()
    if not rescanFrame then
        rescanFrame = CreateFrame("Frame")
    end
    rescanDeadline = GetTime() + RESCAN_DURATION
    local lastScan = 0

    rescanFrame:SetScript("OnUpdate", function(self, elapsed)
        local now = GetTime()
        if now > rescanDeadline then
            StopRescan()
            if not MP.currentSectionId then
                Log:Log("INFO", "MythicPlus: Rescan timed out — no hostiles found. Addon idle for this pull.")
            end
            return
        end
        if now - lastScan < RESCAN_INTERVAL then return end
        lastScan = now

        -- Already planned? Stop.
        if MP.currentSectionId then
            StopRescan()
            return
        end

        -- Re-scan composition
        local Planner = HexCDReminder.DynamicTrashPlanner
        local scan = Planner:ScanComposition()

        Log:Log("DEBUG", string.format("MythicPlus: Rescan at %.1fs — %d hostiles",
            now - (rescanDeadline - RESCAN_DURATION), scan.hostileCount))

        if scan.hostileCount > 0 and MP.dungeonPlan then
            -- Attempt dynamic planning
            local adapted = Planner:Plan(scan, MP.dungeonPlan, MP.cdLedger)
            if adapted then
                MP:LoadDynamicPlan(adapted)
                StopRescan()
            end
        end
    end)
end

-- ============================================================
-- Section / Dynamic Plan Loading
-- ============================================================

--- Load a fixed boss section by index.
function MP:LoadSection(sectionIndex)
    local section = self.dungeonPlan.sections[sectionIndex]
    if not section then return end

    -- Snapshot CD state BEFORE stopping the old engine
    self:SnapshotCDState()

    self.currentSectionId = section.sectionId
    self.matchedSections[section.sectionId] = true

    local adapted = SectionToPlan(section, self.dungeonPlan)

    -- Pass dynamic scheduling metadata to the engine
    adapted._useDynamicScheduling = true
    adapted._cdAvailability = self:GetCDAvailability()
    adapted._maxCDs = section.maxCDs

    Log:Log("INFO", string.format(
        "MythicPlus: Loading boss section [%s] '%s' (%d CDs)",
        section.sectionId, section.label, #section.assignments
    ))
    Log:Log("INFO", string.format("SECTION MATCHED: %s — %d CDs (boss)",
        section.label, #section.assignments))

    -- Stop any active timer before starting new one
    if Engine:IsActive() then
        Engine:Stop()
    end

    Engine:Start(adapted, section.encounterID or 0)
end

--- Load a dynamically-generated trash plan.
function MP:LoadDynamicPlan(adapted)
    -- Snapshot CD state BEFORE stopping the old engine
    self:SnapshotCDState()

    self.trashPullCount = self.trashPullCount + 1
    self.currentSectionId = "dynamic-trash-" .. self.trashPullCount

    local tier = adapted._dynamicTier or 0
    local tierLabel = adapted._dynamicTierLabel or "unknown"
    local cdCount = 0
    if adapted.healerAssignments and adapted.healerAssignments[1] then
        cdCount = #adapted.healerAssignments[1].assignments
    end

    Log:Log("INFO", string.format(
        "MythicPlus: Dynamic trash plan [%s] — Tier %d (%s), %d CDs",
        self.currentSectionId, tier, tierLabel, cdCount
    ))

    -- Stop any active timer before starting new one
    if Engine:IsActive() then
        Engine:Stop()
    end

    Engine:Start(adapted, 0)
end

-- ============================================================
-- Event Handlers (called from Core.lua)
-- ============================================================

function MP:OnChallengeModeStart()
    local mapID = C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then
        Log:Log("INFO", "MythicPlus: CHALLENGE_MODE_START but no mapID available")
        return
    end

    self.challengeMapID = mapID
    local plan, source = Config:GetDungeonPlan(mapID)

    if not plan then
        Log:Log("INFO", string.format("MythicPlus: No dungeon CD plan for mapID %d — addon idle", mapID))
        return
    end

    self.inMythicPlus   = true
    self.dungeonPlan    = plan
    self.matchedSections = {}
    self.currentSectionId = nil
    self.activeBossEncounterID = nil
    self.cdLedger       = {}
    self.trashPullCount = 0

    -- Detect actual key level from WoW API (plan.keyLevel is just the design target)
    local actualKeyLevel = 0
    if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
        actualKeyLevel = C_ChallengeMode.GetActiveKeystoneInfo() or 0
    end
    self.keyLevel = actualKeyLevel

    -- Start session-level debug log
    Log:OnSessionStart(plan.dungeonName, mapID, actualKeyLevel)

    -- Determine planning mode
    local hasDynamic = plan.trashCDTiers and plan.mobProfile
    local planMode = hasDynamic and "DYNAMIC" or "LEGACY (fixed sections)"

    Log:Log("INFO", string.format(
        "MythicPlus: Key started! %s (mapID=%d, source=%s, %d boss sections, keyLevel=%d, trash=%s)",
        plan.dungeonName, mapID, source or "unknown",
        #plan.sections, actualKeyLevel, planMode
    ))

    -- Log boss sections
    for i, section in ipairs(plan.sections) do
        if section.type == "boss" then
            Log:Log("INFO", string.format("  Boss[%d] '%s': %d CDs, encID=%s",
                i, section.label or "?",
                #(section.assignments or {}),
                tostring(section.encounterID or "-")
            ))
        end
    end

    -- Log dynamic trash tier summary if available
    if hasDynamic then
        local mp = plan.mobProfile
        Log:Log("INFO", string.format("  Mob profile: caster=%dk, melee=%dk, lt=%dk, trivial=%dk DPS",
            math.floor(mp.casterEliteDPS / 1000),
            math.floor(mp.meleeEliteDPS / 1000),
            math.floor(mp.lieutenantDPS / 1000),
            math.floor(mp.trivialDPS / 1000)))
        for _, tierName in ipairs({"tier0", "tier1", "tier2", "tier3"}) do
            local t = plan.trashCDTiers[tierName]
            if t then
                local names = {}
                for _, cd in ipairs(t) do names[#names + 1] = cd.abilityName end
                Log:Log("INFO", string.format("  %s: [%s]", tierName, table.concat(names, ", ")))
            end
        end
    end
end

function MP:OnChallengeModeEnd(completed)
    if not self.inMythicPlus then return end

    Log:Log("INFO", string.format("MythicPlus: Key ended — %d dynamic trash pulls, %d boss sections loaded",
        self.trashPullCount,
        (function() local n = 0; for _ in pairs(self.matchedSections) do n = n + 1 end; return n end)()
    ))

    -- List boss section status
    if self.dungeonPlan then
        for i, section in ipairs(self.dungeonPlan.sections) do
            if section.type == "boss" then
                local status = self.matchedSections[section.sectionId] and "MATCHED" or "MISSED"
                Log:Log("INFO", string.format("  Boss[%d] '%s': %s",
                    i, section.label or "?", status))
            end
        end
    end

    if Engine:IsActive() then
        Engine:Stop()
    end

    -- Save session log
    Log:OnSessionEnd(completed or false)

    self.inMythicPlus   = false
    self.challengeMapID = nil
    self.dungeonPlan    = nil
    self.currentSectionId = nil
    self.activeBossEncounterID = nil
    self.matchedSections = {}
    self.cdLedger       = {}
    self.inCombat       = false
    self.trashPullCount = 0
end

function MP:OnCombatStart()
    if not self.inMythicPlus or not self.dungeonPlan then return end
    self.inCombat = true

    -- Snapshot CD state for accurate availability
    self:SnapshotCDState()

    -- Use DynamicTrashPlanner to scan composition and assign CDs
    local Planner = HexCDReminder.DynamicTrashPlanner
    local scan = Planner:ScanComposition()

    Log:Log("INFO", string.format("MythicPlus: Combat started — %d hostiles detected (%d casters, %d melee, %d lt, %d trivial)",
        scan.hostileCount, scan.casterCount, scan.meleeCount, scan.lieutenantCount, scan.trivialCount))

    if scan.hostileCount == 0 then
        -- Nameplates not registered yet — start rescan
        Log:Log("INFO", "MythicPlus: No hostiles at combat start — starting rescan timer")
        StartRescan()
        return
    end

    -- Dynamic planning
    local adapted = Planner:Plan(scan, self.dungeonPlan, self.cdLedger)
    if adapted then
        self:LoadDynamicPlan(adapted)
    else
        -- No plan generated (no tiers configured, or all CDs on cooldown)
        Log:Log("INFO", "MythicPlus: Dynamic planner returned no plan — addon idle for this pull")
    end
end

function MP:OnCombatEnd()
    if not self.inMythicPlus then return end
    self.inCombat = false

    -- Stop nameplate rescan
    StopRescan()

    if self.currentSectionId then
        local engineActive = Engine:IsActive()
        local fightElapsed = engineActive and Engine:GetFightElapsed() or 0
        Log:Log("INFO", string.format("MythicPlus: Combat ended (section: %s, engine=%s, elapsed=%.1fs)",
            self.currentSectionId,
            engineActive and "active" or "idle",
            fightElapsed))
    else
        Log:Log("INFO", "MythicPlus: Combat ended (no plan was loaded)")
    end

    -- Snapshot CD state BEFORE stopping the engine
    self:SnapshotCDState()

    if Engine:IsActive() then
        Engine:Stop()
    end

    self.currentSectionId = nil
end

--- Called from Core.lua when ENCOUNTER_START fires and encounterID
--- matches one of our dungeon's boss IDs.
function MP:OnBossStart(encounterID, encounterName, difficultyID)
    self.activeBossEncounterID = encounterID

    -- Snapshot CD state before stopping trash timer
    self:SnapshotCDState()

    -- Stop any active trash timer
    if Engine:IsActive() then
        Engine:Stop()
    end

    -- Find matching boss section
    local idx = FindBossSection(encounterID, self.dungeonPlan)
    if idx then
        Log:Log("INFO", string.format("MythicPlus: Boss section found by encounterID → section[%d] '%s'",
            idx, self.dungeonPlan.sections[idx].label or "?"))
        self:LoadSection(idx)
    else
        Log:Log("INFO", string.format(
            "MythicPlus: Boss %s (id=%d) started but NO matching section found — addon idle for this boss",
            encounterName or "?", encounterID
        ))
    end
end

function MP:OnBossEnd(encounterID, encounterName, difficultyID, groupSize, success)
    local isKill = (success == true or success == 1)
    local result = isKill and "KILL" or "WIPE"
    Log:Log("INFO", string.format(
        "MythicPlus: Boss %s %s (id=%d)",
        result, encounterName or "?", encounterID
    ))

    -- Snapshot CD state before stopping
    self:SnapshotCDState()

    if Engine:IsActive() then
        Engine:Stop()
    end

    self.activeBossEncounterID = nil
    self.currentSectionId = nil
end

--- Check if a given encounterID belongs to the loaded dungeon plan.
function MP:IsOurBoss(encounterID)
    if not self.dungeonPlan then return false end
    for _, eid in ipairs(self.dungeonPlan.bossEncounterIDs or {}) do
        if eid == encounterID then return true end
    end
    for _, section in ipairs(self.dungeonPlan.sections) do
        if section.type == "boss" and section.encounterID and section.encounterID > 0
           and section.encounterID == encounterID then
            return true
        end
    end
    return false
end
