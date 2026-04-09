------------------------------------------------------------------------
-- HexCD: Timer Engine
-- Manages CD queue, OnUpdate scheduling, BigWigs drift adjustments
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.TimerEngine = {}

local Engine = HexCDReminder.TimerEngine
local Config = HexCDReminder.Config
local Bars = HexCDReminder.TimerBars
local TTS = HexCDReminder.TTS
local Util = HexCDReminder.Util
local Log = HexCDReminder.DebugLog

-- State
local queue = {}                 -- sorted array of CDEntry
local active = false
local fightStartTime = 0
local encounterID = 0
local throttle = 0
local updateFrame = nil
local statusDumpInterval = 10    -- dump status every N sim-seconds
local lastStatusDumpSec = -999   -- last sim-second we dumped status
local isTestMode = false         -- true when running RunTest
function Engine:IsTestMode() return isTestMode end

-- Lookup for BigWigs drift adjustment
local abilityToEventMap = {}     -- spellID → { damageEventIndex, expectedTimeSec }

-- Phase-relative timing state
local phaseTimings = {}          -- phase → expected start time (from plan)
local phaseDetected = {}         -- phase → actual start time (detected at runtime)
local phaseDriftApplied = {}     -- phase → drift amount already applied

-- Dynamic scheduling state (M+ sections)
local useDynamicScheduling = false
local anchorFireCounts = {}      -- spellID → count of times BigWigs fired this spell
local activatedRealCDs = 0       -- count of real CDs activated (excludes markers 774, 768)
local sectionMaxCDs = nil        -- from plan._maxCDs
-- Marker detection now delegated to Util.IsMarkerSpell() (spec-aware)

------------------------------------------------------------------------
-- Queue Building
------------------------------------------------------------------------

--- Build the CD queue from a plan for the current player
---@param plan table HealingCDPlan lua table
---@param playerClass string normalized class name
---@param playerSpec string spec name
---@return table[] queue entries
local function BuildQueue(plan, playerClass, playerSpec)
    local result = {}

    if not plan or not plan.healerAssignments then return result end

    -- Get the current character's name for playerName matching
    local playerName = UnitName("player")
    Log:Log("DEBUG", string.format("BuildQueue: player='%s' class='%s' spec='%s'", playerName or "nil", playerClass, playerSpec))

    for _, healer in ipairs(plan.healerAssignments) do
        -- If the assignment has a playerName, match by name (exact match)
        -- Otherwise fall back to class + spec matching
        local isMatch = false
        local matchReason = ""
        if healer.playerName and healer.playerName ~= "" then
            isMatch = (healer.playerName == playerName)
            matchReason = string.format("playerName '%s' vs '%s'", healer.playerName, playerName or "nil")
        else
            isMatch = (healer.className == playerClass and healer.specName == playerSpec)
            matchReason = string.format("class/spec '%s %s' vs '%s %s'", healer.className, healer.specName, playerClass, playerSpec)
        end

        Log:Log("DEBUG", string.format("BuildQueue: healer '%s' (%s %s) — %s → %s",
            healer.playerName or "(no name)", healer.className, healer.specName,
            matchReason, isMatch and "MATCH" or "skip"))

        if isMatch then
            for _, assignment in ipairs(healer.assignments or {}) do
                local rampType = Util.DetectRampType(assignment.abilityGameID)
                table.insert(result, {
                    timeSec         = assignment.timeSec,
                    adjustedTimeSec = assignment.timeSec,
                    abilityGameID   = assignment.abilityGameID,
                    abilityName     = assignment.abilityName,
                    rationale       = assignment.rationale,
                    rampType        = rampType,
                    encounterID     = plan.encounterID,
                    phase           = assignment.phase,  -- boss phase for drift adjustment
                    -- Countdown bar state (counts down TO the start time)
                    barCreated      = false,
                    ttsPreFired     = false,
                    ttsFired        = false,
                    -- Duration bar state (tracks the active window AFTER start)
                    durationActive  = false,
                    durationBarCreated = false,
                    done            = false,
                    damageEventIndex = nil,  -- set below (skipped for anchored CDs)
                    anchorSpellID   = assignment.anchorSpellID,    -- BigWigs spell to anchor to
                    anchorOffsetSec = assignment.anchorOffsetSec,  -- offset from anchor landing
                    _prevPhaseDrift = 0,     -- track cumulative drift applied
                })
            end
        end
    end

    -- Sort by time
    table.sort(result, function(a, b) return a.adjustedTimeSec < b.adjustedTimeSec end)

    -- Log each queued entry
    for i, cd in ipairs(result) do
        Log:Log("DEBUG", string.format("  Queue[%d]: %s @ %s (id=%d, rampType=%s)",
            i, cd.abilityName, Util.FormatTime(cd.timeSec),
            cd.abilityGameID, cd.rampType))
    end

    -- Compute window durations: each entry runs until the next entry starts
    -- Ramp: starts at timeSec, ends when next entry (CD) starts
    -- CD (burn): starts at timeSec, ends when next entry (cat weave or next ramp) starts
    -- Cat Weave: starts at timeSec, ends when next ramp starts
    for i, cd in ipairs(result) do
        local nextEntry = result[i + 1]
        if nextEntry then
            cd.windowEndSec = nextEntry.timeSec
            cd.windowDuration = nextEntry.timeSec - cd.timeSec
        else
            -- Last entry: estimate based on type
            if cd.abilityGameID == 774 then
                cd.windowEndSec = cd.timeSec + 22
                cd.windowDuration = 22
            elseif cd.abilityGameID == 768 then
                cd.windowEndSec = cd.timeSec + 29
                cd.windowDuration = 29
            else
                -- CD (burn): Convoke ~9s, Tranq ~22s
                cd.windowEndSec = cd.timeSec + (cd.abilityGameID == 740 and 22 or 9)
                cd.windowDuration = cd.windowEndSec - cd.timeSec
            end
        end
    end

    -- Link CDs to nearest damage event for BigWigs drift (skip anchored CDs — they use direct spell matching)
    if plan.damageTimeline then
        for _, cd in ipairs(result) do
            if not cd.anchorSpellID then
                local bestDist = math.huge
                local bestIdx = nil
                for i, de in ipairs(plan.damageTimeline) do
                    local dist = math.abs(de.timeSec - cd.timeSec)
                    if dist < bestDist then
                        bestDist = dist
                        bestIdx = i
                    end
                end
                cd.damageEventIndex = bestIdx
            end
        end
    end

    Log:Log("INFO", string.format("Built queue: %d CDs for %s %s", #result, playerClass, playerSpec))
    return result
end

------------------------------------------------------------------------
-- Dynamic Scheduling: BuildQueueV2 + Activation Functions
------------------------------------------------------------------------

--- Build the CD queue with dynamic scheduling support.
--- Reads assignment.scheduling fields and sets isQueued, schedulingMode, etc.
---@param plan table HealingCDPlan lua table (with _cdAvailability, _maxCDs)
---@param playerClass string
---@param playerSpec string
---@return table[] queue entries
local function BuildQueueV2(plan, playerClass, playerSpec)
    local result = {}
    if not plan or not plan.healerAssignments then return result end

    local playerName = UnitName("player")
    local cdAvailability = plan._cdAvailability or {}

    for _, healer in ipairs(plan.healerAssignments) do
        local isMatch = false
        if healer.playerName and healer.playerName ~= "" then
            isMatch = (healer.playerName == playerName)
        else
            isMatch = (healer.className == playerClass and healer.specName == playerSpec)
        end

        if isMatch then
            for _, assignment in ipairs(healer.assignments) do
                local sched = assignment.scheduling
                local mode = sched and sched.mode or nil
                local isMarker = Util.IsMarkerSpell(assignment.abilityGameID)

                local cd = {
                    timeSec         = assignment.timeSec,
                    adjustedTimeSec = assignment.timeSec,
                    abilityGameID   = assignment.abilityGameID,
                    abilityName     = assignment.abilityName,
                    rationale       = assignment.rationale,
                    encounterID     = plan.encounterID or 0,
                    phase           = assignment.phase,
                    anchorSpellID   = assignment.anchorSpellID,
                    anchorOffsetSec = assignment.anchorOffsetSec,
                    _explicitWindowSec = assignment.windowSec,
                    -- Bar state
                    barCreated      = false,
                    ttsPreFired     = false,
                    ttsFired        = false,
                    durationActive  = false,
                    durationBarCreated = false,
                    done            = false,
                    -- Drift state
                    _prevPhaseDrift = 0,
                    _deferredOnce   = false,
                    _driftOffset    = 0,
                    -- Dynamic scheduling
                    schedulingMode  = mode,
                    isQueued        = false, -- will be set below
                }

                -- Set ramp type for bar visuals
                if assignment.abilityGameID == 774 then
                    cd.rampType = "fullRamp"
                elseif assignment.abilityGameID == 768 then
                    cd.rampType = "catWeave"
                else
                    cd.rampType = "burn"
                end

                -- Scheduling mode determines initial queue state
                if not mode then
                    -- Legacy: queued immediately with absolute timeSec
                    cd.isQueued = true
                elseif mode == "immediate" then
                    cd.adjustedTimeSec = sched.delaySec or 0
                    cd.isQueued = true
                elseif mode == "sequential" then
                    cd.sequentialOrder = sched.order
                    cd.minDelaySec = sched.minDelaySec or 0
                    cd.maxDelaySec = sched.maxDelaySec
                    cd.isQueued = false  -- activated dynamically
                    cd._seqActivatedAt = nil -- track when this CD was activated
                elseif mode == "anchor" then
                    -- Read from scheduling fields (new style)
                    cd.anchorSpellID = sched.anchorSpellID
                    cd.anchorOffsetSec = sched.anchorOffsetSec
                    cd.anchorOccurrence = sched.occurrence
                    -- Timer-with-anchor: queue immediately using timeSec as fallback.
                    -- If BigWigs fires the anchor bar, AnchorCDToBigWigsBar() overrides
                    -- adjustedTimeSec with the precise anchor timing. If BigWigs isn't
                    -- installed or the bar never fires, the CD still activates at timeSec.
                    cd.isQueued = true
                    cd._anchorOverridden = false  -- set true when anchor fires
                elseif mode == "conditional" then
                    cd.conditionalType = sched.condition
                    cd.conditionalMinElapsed = sched.minFightElapsedSec
                    cd.conditionalAnchorSpellID = sched.afterAnchorSpellID
                    cd.conditionalAnchorCount = sched.afterAnchorCount
                    cd.conditionalOffsetSec = sched.offsetSec or 0
                    cd.isQueued = false  -- activated when condition met
                end

                -- Pre-check CD availability from ledger
                local remaining = cdAvailability[assignment.abilityGameID]
                if remaining and remaining > 0 and not isMarker then
                    cd._knownCDRemaining = remaining
                    Log:Log("DEBUG", string.format("BuildQueueV2: %s has %.1fs CD remaining from ledger",
                        cd.abilityName, remaining))
                end

                table.insert(result, cd)
            end
        end
    end

    -- Sort by timeSec for display/fallback ordering
    table.sort(result, function(a, b) return a.timeSec < b.timeSec end)

    -- Compute window durations: prefer explicit windowSec from plan, fallback to gap-based
    for i, cd in ipairs(result) do
        if cd._explicitWindowSec then
            cd.windowDuration = cd._explicitWindowSec
            cd.windowEndSec = cd.timeSec + cd.windowDuration
        else
            local nextEntry = result[i + 1]
            if nextEntry then
                cd.windowEndSec = nextEntry.timeSec
                cd.windowDuration = nextEntry.timeSec - cd.timeSec
            else
                if cd.abilityGameID == 774 then
                    cd.windowDuration = 22
                elseif cd.abilityGameID == 768 then
                    cd.windowDuration = 29
                else
                    cd.windowDuration = cd.abilityGameID == 740 and 22 or 9
                end
                cd.windowEndSec = cd.timeSec + cd.windowDuration
            end
        end
    end

    -- Merge consecutive Ramp entries with no burn between them.
    -- When a Ramp is followed directly by another Ramp (no CD/burn in between),
    -- the first ramp is just filler — absorb it into the second ramp's window.
    local i = 1
    while i < #result do
        local cur = result[i]
        local nxt = result[i + 1]
        if cur.abilityGameID == 774 and nxt.abilityGameID == 774 then
            -- Extend the second ramp's window to start at the first ramp's time
            local oldStart = nxt.timeSec
            nxt.timeSec = cur.timeSec
            nxt.windowDuration = nxt.windowEndSec - nxt.timeSec
            -- If the filler was already queued, the merged ramp should be too
            if cur.isQueued and not nxt.isQueued then
                nxt.isQueued = true
            end
            -- Remove the first (filler) ramp
            table.remove(result, i)
            Log:Info("MERGE RAMPS: absorbed filler ramp @ %.0fs into next ramp — new window %.0f-%.0fs (%.0fs)",
                oldStart, nxt.timeSec, nxt.windowEndSec, nxt.windowDuration)
        else
            i = i + 1
        end
    end

    -- Link to damage events for BigWigs drift (skip anchored and scheduled-anchor CDs)
    if plan.damageTimeline then
        for _, cd in ipairs(result) do
            if not cd.anchorSpellID then
                local bestDist = math.huge
                local bestIdx = nil
                for i, de in ipairs(plan.damageTimeline) do
                    local dist = math.abs(de.timeSec - cd.timeSec)
                    if dist < bestDist then
                        bestDist = dist
                        bestIdx = i
                    end
                end
                cd.damageEventIndex = bestIdx
            end
        end
    end

    Log:Log("INFO", string.format("Built queue: %d CDs for %s %s (dynamic scheduling)", #result, playerClass, playerSpec))
    return result
end

--- Activate sequential CDs based on ordering and prerequisites.
--- Called each tick from OnUpdate when dynamic scheduling is active.
---@param fightElapsed number seconds since fight start
local function ActivateSequentialCDs(fightElapsed)
    -- Find sequential CDs sorted by order
    local sequentials = {}
    for _, cd in ipairs(queue) do
        if cd.schedulingMode == "sequential" and not cd.done then
            table.insert(sequentials, cd)
        end
    end
    table.sort(sequentials, function(a, b) return a.sequentialOrder < b.sequentialOrder end)

    for _, cd in ipairs(sequentials) do
        if cd.isQueued then
            -- Already activated — skip
        else
            -- Check if we can activate this CD
            -- maxCDs enforcement
            if sectionMaxCDs and not Util.IsMarkerSpell(cd.abilityGameID) then
                if activatedRealCDs >= sectionMaxCDs then
                    -- Capped — mark done to avoid further processing
                    if not cd._cappedLogged then
                        cd._cappedLogged = true
                        Log:Log("INFO", string.format("SEQUENTIAL CAPPED: %s — maxCDs=%d reached",
                            cd.abilityName, sectionMaxCDs))
                    end
                    cd.done = true
                    break
                end
            end

            -- Check prerequisites
            local canActivate = false

            if cd.sequentialOrder == 1 then
                -- First sequential CD: activate after minDelaySec
                canActivate = fightElapsed >= cd.minDelaySec
            else
                -- Find previous order CD
                local prevCD = nil
                for _, s in ipairs(sequentials) do
                    if s.sequentialOrder == cd.sequentialOrder - 1 then
                        prevCD = s
                        break
                    end
                end

                if prevCD then
                    -- Previous must be activated and either in duration phase or done
                    if prevCD.isQueued and (prevCD.durationActive or prevCD.done) then
                        -- Check minDelaySec from previous activation
                        local prevActivatedAt = prevCD._seqActivatedAt or 0
                        if fightElapsed - prevActivatedAt >= cd.minDelaySec then
                            canActivate = true
                        end
                    end
                else
                    -- No previous found (gap in ordering) — activate if minDelaySec met
                    canActivate = fightElapsed >= cd.minDelaySec
                end
            end

            -- maxDelaySec safety cap: force-activate regardless of prerequisites
            if not canActivate and cd.maxDelaySec and fightElapsed >= cd.maxDelaySec then
                canActivate = true
                Log:Log("INFO", string.format("SEQUENTIAL FORCE: %s — maxDelaySec=%d exceeded (fight=%.1fs)",
                    cd.abilityName, cd.maxDelaySec, fightElapsed))
            end

            if canActivate then
                -- Check CD availability via CooldownTracker
                local tracker = HexCDReminder.CooldownTracker
                local activateTime = fightElapsed
                if tracker and not Util.IsMarkerSpell(cd.abilityGameID) then
                    local ready, remaining = tracker:IsReady(cd.abilityGameID)
                    if not ready then
                        -- Defer to when CD will be ready
                        activateTime = fightElapsed + remaining
                        Log:Log("INFO", string.format("SEQUENTIAL DEFER: %s — %.0fs remaining, activating at %s",
                            cd.abilityName, remaining, Util.FormatTime(activateTime)))
                    end
                end

                cd.isQueued = true
                cd.adjustedTimeSec = activateTime
                cd._seqActivatedAt = fightElapsed
                cd.windowEndSec = activateTime + (cd.windowDuration or 9)

                if not Util.IsMarkerSpell(cd.abilityGameID) then
                    activatedRealCDs = activatedRealCDs + 1
                end

                Log:Log("INFO", string.format("SEQUENTIAL ACTIVATE: %s (order=%d) @ %s (%ds window)",
                    cd.abilityName, cd.sequentialOrder, Util.FormatTime(activateTime), cd.windowDuration or 0))
            end
        end
    end
end

--- Evaluate conditional CDs and activate when conditions are met.
--- Called each tick from OnUpdate when dynamic scheduling is active.
---@param fightElapsed number seconds since fight start
local function EvaluateConditionalCDs(fightElapsed)
    for _, cd in ipairs(queue) do
        if cd.schedulingMode == "conditional" and not cd.isQueued and not cd.done then
            -- maxCDs enforcement
            if sectionMaxCDs and not Util.IsMarkerSpell(cd.abilityGameID) then
                if activatedRealCDs >= sectionMaxCDs then
                    if not cd._cappedLogged then
                        cd._cappedLogged = true
                        Log:Log("INFO", string.format("CONDITIONAL CAPPED: %s — maxCDs=%d reached",
                            cd.abilityName, sectionMaxCDs))
                    end
                    cd.done = true
                    break
                end
            end

            local conditionMet = false

            if cd.conditionalType == "fightElapsed" then
                if cd.conditionalMinElapsed and fightElapsed >= cd.conditionalMinElapsed then
                    conditionMet = true
                end
            elseif cd.conditionalType == "afterAnchor" then
                local spellID = cd.conditionalAnchorSpellID
                local count = cd.conditionalAnchorCount or 1
                if spellID and (anchorFireCounts[spellID] or 0) >= count then
                    conditionMet = true
                end
            end

            if conditionMet then
                local activateTime = fightElapsed + (cd.conditionalOffsetSec or 0)

                -- Check CD availability
                local tracker = HexCDReminder.CooldownTracker
                if tracker and not Util.IsMarkerSpell(cd.abilityGameID) then
                    local ready, remaining = tracker:IsReady(cd.abilityGameID)
                    if not ready then
                        activateTime = math.max(activateTime, fightElapsed + remaining)
                    end
                end

                cd.isQueued = true
                cd.adjustedTimeSec = activateTime
                cd.windowEndSec = activateTime + (cd.windowDuration or 9)

                if not Util.IsMarkerSpell(cd.abilityGameID) then
                    activatedRealCDs = activatedRealCDs + 1
                end

                Log:Log("INFO", string.format("CONDITIONAL ACTIVATE: %s (%s) @ %s",
                    cd.abilityName, cd.conditionalType, Util.FormatTime(activateTime)))
            end
        end
    end
end

--- Build the ability-to-event lookup for BigWigs drift
---@param plan table
local function BuildAbilityEventMap(plan)
    wipe(abilityToEventMap)
    if not plan or not plan.damageTimeline then return end

    local mappedCount = 0
    local unmappedCount = 0
    for i, de in ipairs(plan.damageTimeline) do
        if de.abilityGameIDs and #de.abilityGameIDs > 0 then
            for _, spellID in ipairs(de.abilityGameIDs) do
                abilityToEventMap[spellID] = {
                    damageEventIndex = i,
                    expectedTimeSec = de.timeSec,
                }
                mappedCount = mappedCount + 1
            end
        else
            unmappedCount = unmappedCount + 1
        end
    end
    Log:Log("DEBUG", string.format("AbilityEventMap: %d spell IDs mapped from %d damage events (%d events have no spell IDs)",
        mappedCount, plan.damageTimeline and #plan.damageTimeline or 0, unmappedCount))
end

------------------------------------------------------------------------
-- Phase-Relative Drift Adjustment
------------------------------------------------------------------------

--- Apply phase drift: shift all CDs in the given phase (and optionally later phases)
--- by the difference between actual and expected phase start time.
---@param phase number the phase number (1, 1.5, 2, 2.5, 3, etc.)
---@param actualStartSec number the actual fight-elapsed time when this phase started
local function ApplyPhaseDrift(phase, actualStartSec)
    local expectedStart = phaseTimings[phase]
    if not expectedStart then
        Log:Log("DEBUG", string.format("Phase %.1f drift: no expected timing in plan — skipping", phase))
        return
    end

    -- Already applied drift for this phase?
    if phaseDriftApplied[phase] then
        Log:Log("DEBUG", string.format("Phase %.1f drift: already applied (%.1fs) — skipping", phase, phaseDriftApplied[phase]))
        return
    end

    local drift = actualStartSec - expectedStart
    phaseDriftApplied[phase] = drift

    -- Small drift (<3s) is normal variance — don't bother adjusting
    if math.abs(drift) < 3 then
        Log:Log("INFO", string.format("PHASE %.1f DETECTED @ %s (expected %s, drift=%+.1fs — within tolerance, no adjustment)",
            phase, Util.FormatTime(actualStartSec), Util.FormatTime(expectedStart), drift))
        return
    end

    -- Shift all CDs in THIS phase and ALL LATER phases that haven't started yet
    local adjustCount = 0
    local adjustedNames = {}
    for _, cd in ipairs(queue) do
        if not cd.done and cd.phase and cd.phase >= phase then
            -- Only shift if this phase's drift hasn't been individually detected yet
            -- (later phases get their own drift when they're detected)
            if cd.phase == phase or not phaseDriftApplied[cd.phase] then
                local oldTime = cd.adjustedTimeSec
                cd.adjustedTimeSec = cd.timeSec + drift
                -- Also shift windowEndSec
                if cd.windowEndSec then
                    cd.windowEndSec = cd.windowEndSec + drift - (cd._prevPhaseDrift or 0)
                end
                cd._prevPhaseDrift = drift
                adjustCount = adjustCount + 1
                table.insert(adjustedNames, string.format("  P%.1f %s: %s -> %s (%+.1fs)",
                    cd.phase, cd.abilityName,
                    Util.FormatTime(math.floor(oldTime)),
                    Util.FormatTime(math.floor(cd.adjustedTimeSec)), drift))
            end
        end
    end

    Log:Log("INFO", string.format("PHASE %.1f DETECTED @ %s (expected %s, drift=%+.1fs) — shifted %d CDs",
        phase, Util.FormatTime(actualStartSec), Util.FormatTime(expectedStart), drift, adjustCount))
    for _, desc in ipairs(adjustedNames) do
        Log:Log("DEBUG", desc)
    end
end

--- Called by BigWigs plugin or combat log when a phase transition is detected
---@param phase number
---@param fightElapsedSec number
function Engine:OnPhaseTransition(phase, fightElapsedSec)
    if not active then return end
    if phaseDetected[phase] then return end  -- already handled

    phaseDetected[phase] = fightElapsedSec
    ApplyPhaseDrift(phase, fightElapsedSec)
end

------------------------------------------------------------------------
-- Debug: Periodic Status Dump
------------------------------------------------------------------------

--- Dump current state of the queue, active bars, and upcoming CDs
---@param fightElapsed number current fight time in seconds
local function DumpStatus(fightElapsed)
    local pending, done, barCount = 0, 0, 0
    local nextCD = nil
    local nextRamp = nil
    local activeBars = {}
    local currentPhase = nil

    for _, cd in ipairs(queue) do
        if cd.done then
            done = done + 1
            -- Track what phase we're currently in (last completed entry)
            if cd.windowEndSec and fightElapsed < cd.windowEndSec then
                if cd.abilityGameID == 774 then
                    currentPhase = string.format("IN RAMP (%s-%s)", Util.FormatTime(cd.timeSec), Util.FormatTime(cd.windowEndSec))
                elseif cd.abilityGameID == 768 then
                    currentPhase = string.format("CAT WEAVE (%s-%s)", Util.FormatTime(cd.timeSec), Util.FormatTime(cd.windowEndSec))
                else
                    currentPhase = string.format("BURN: %s (%s-%s)", cd.abilityName, Util.FormatTime(cd.timeSec), Util.FormatTime(cd.windowEndSec))
                end
            end
        else
            pending = pending + 1
            local timeUntil = cd.adjustedTimeSec - fightElapsed
            if cd.durationActive and cd.durationBarCreated then
                -- Phase 2: duration bar (active window)
                barCount = barCount + 1
                local windowEnd = (cd.windowEndSec or cd.adjustedTimeSec) + (cd._driftOffset or 0)
                local windowRem = windowEnd - fightElapsed
                table.insert(activeBars, string.format("    [WIN] %s ACTIVE (%s-%s, %.0fs left)",
                    cd.abilityName, Util.FormatTime(cd.adjustedTimeSec),
                    Util.FormatTime(windowEnd), math.max(0, windowRem)))
            elseif cd.barCreated then
                -- Phase 1: countdown bar
                barCount = barCount + 1
                local windowStr = cd.windowDuration and string.format(", %ds window %s-%s",
                    cd.windowDuration, Util.FormatTime(cd.adjustedTimeSec), Util.FormatTime(cd.windowEndSec or 0)) or ""
                table.insert(activeBars, string.format("    [BAR] %s @ %s (in %.0fs%s)",
                    cd.abilityName, Util.FormatTime(cd.adjustedTimeSec), timeUntil, windowStr))
            end
            if cd.abilityGameID == 774 or cd.abilityGameID == 768 then
                if not nextRamp then
                    nextRamp = string.format("%s @ %s (in %.0fs, %ds window -> %s)",
                        cd.abilityName, Util.FormatTime(cd.adjustedTimeSec), timeUntil,
                        cd.windowDuration or 0, Util.FormatTime(cd.windowEndSec or 0))
                end
            else
                if not nextCD then
                    nextCD = string.format("%s @ %s (in %.0fs, %ds window -> %s)",
                        cd.abilityName, Util.FormatTime(cd.adjustedTimeSec), timeUntil,
                        cd.windowDuration or 0, Util.FormatTime(cd.windowEndSec or 0))
                end
            end
        end
    end

    Log:Log("INFO", string.format("-- STATUS @ %s -- %d pending, %d done, %d bars visible",
        Util.FormatTime(fightElapsed), pending, done, barCount))
    if currentPhase then Log:Log("INFO", "  Phase: " .. currentPhase) end

    -- Log phase drift state
    local driftInfo = {}
    for phase, drift in pairs(phaseDriftApplied) do
        table.insert(driftInfo, string.format("P%.1f=%+.1fs", phase, drift))
    end
    if #driftInfo > 0 then
        table.sort(driftInfo)
        Log:Log("INFO", "  Phase drift: " .. table.concat(driftInfo, ", "))
    end

    if nextRamp then Log:Log("INFO", "  Next ramp: " .. nextRamp) end
    if nextCD   then Log:Log("INFO", "  Next CD:   " .. nextCD) end
    for _, line in ipairs(activeBars) do
        Log:Log("INFO", line)
    end
end

------------------------------------------------------------------------
-- Fight Lifecycle
------------------------------------------------------------------------

--- Start tracking a fight
---@param plan table the CD plan
---@param encID number encounter ID
function Engine:Start(plan, encID)
    encounterID = encID
    fightStartTime = GetTime()
    lastStatusDumpSec = -999
    isTestMode = false

    -- Initialize phase-relative timing
    wipe(phaseTimings)
    wipe(phaseDetected)
    wipe(phaseDriftApplied)
    if plan.phaseTimings then
        for phase, timeSec in pairs(plan.phaseTimings) do
            phaseTimings[tonumber(phase)] = timeSec
        end
    end
    -- Phase 1 always starts at 0 (fight start)
    phaseDetected[1] = 0
    phaseDriftApplied[1] = 0

    -- Reset dynamic scheduling state
    useDynamicScheduling = plan._useDynamicScheduling or false
    wipe(anchorFireCounts)
    activatedRealCDs = 0
    sectionMaxCDs = plan._maxCDs

    local playerClass, playerSpec = Util.GetPlayerSpec()
    playerClass = Util.NormalizeClassName(playerClass)

    if useDynamicScheduling then
        queue = BuildQueueV2(plan, playerClass, playerSpec)
    else
        queue = BuildQueue(plan, playerClass, playerSpec)
    end
    BuildAbilityEventMap(plan)

    active = true
    throttle = 0

    if not updateFrame then
        updateFrame = CreateFrame("Frame", "HexCDTimerEngineFrame")
    end
    updateFrame:SetScript("OnUpdate", function(_, elapsed)
        Engine:OnUpdate(elapsed)
    end)

    -- Log full queue overview with window durations
    Log:Log("INFO", string.format("== TimerEngine START: encounter %d, %d CDs queued ==", encID, #queue))
    for i, cd in ipairs(queue) do
        local tag
        if cd.abilityGameID == 774 then tag = "RAMP"
        elseif cd.abilityGameID == 768 then tag = "CAT "
        else tag = "CD  " end
        local extra = ""
        if cd.anchorSpellID then
            extra = string.format(" anchor=%d occ=%s queued=%s",
                cd.anchorSpellID, tostring(cd.anchorOccurrence or "next"), tostring(cd.isQueued))
        elseif cd.schedulingMode then
            extra = string.format(" mode=%s queued=%s", cd.schedulingMode, tostring(cd.isQueued))
        end
        Log:Log("INFO", string.format("  [%d] %s %s @ %s -> %s (%ds window)%s",
            i, tag, cd.abilityName, Util.FormatTime(cd.timeSec),
            Util.FormatTime(cd.windowEndSec or 0), cd.windowDuration or 0, extra))
    end

    -- Log damage timeline if present
    if plan.damageTimeline and #plan.damageTimeline > 0 then
        Log:Log("INFO", string.format("  Damage timeline: %d events", #plan.damageTimeline))
        for i, de in ipairs(plan.damageTimeline) do
            local sev = (de.severity or "?"):upper()
            local desc = de.description or ("Event " .. i)
            if #desc > 60 then desc = desc:sub(1, 57) .. "..." end
            Log:Log("DEBUG", string.format("    [%s] %s -- %s (%.1fM)",
                Util.FormatTime(de.timeSec), sev, desc, (de.raidDamage or 0) / 1000000))
        end
    end

    -- Log BigWigs ability map
    local mapCount = 0
    for _ in pairs(abilityToEventMap) do mapCount = mapCount + 1 end
    if mapCount > 0 then
        Log:Log("INFO", string.format("  BigWigs spell map: %d spell IDs linked to damage events", mapCount))
    end

    -- Log phase timings
    local phaseCount = 0
    for _ in pairs(phaseTimings) do phaseCount = phaseCount + 1 end
    if phaseCount > 0 then
        Log:Log("INFO", string.format("  Phase timings: %d phases from reference kill", phaseCount))
        local sorted = {}
        for p, t in pairs(phaseTimings) do table.insert(sorted, { phase = p, time = t }) end
        table.sort(sorted, function(a, b) return a.phase < b.phase end)
        for _, pt in ipairs(sorted) do
            local label = pt.phase == math.floor(pt.phase) and string.format("P%d", pt.phase) or string.format("I%.0f", pt.phase * 2 - 1)
            Log:Log("INFO", string.format("    %s (%.1f): expected @ %s", label, pt.phase, Util.FormatTime(pt.time)))
        end
        Log:Log("INFO", "  Phase drift will auto-adjust CDs when BigWigs detects phase transitions")
    end
end

--- Check if the engine is currently running
---@return boolean
function Engine:IsActive()
    return active
end

--- Stop tracking (wipe/kill)
function Engine:Stop()
    -- Count state before cleanup
    local doneCount, activeCount = 0, 0
    for _, cd in ipairs(queue) do
        if cd.done then doneCount = doneCount + 1 else activeCount = activeCount + 1 end
    end
    local fightElapsed = fightStartTime > 0 and (GetTime() - fightStartTime) or 0

    active = false
    isTestMode = false
    lastStatusDumpSec = -999
    useDynamicScheduling = false
    sectionMaxCDs = nil
    activatedRealCDs = 0
    wipe(anchorFireCounts)
    if updateFrame then
        updateFrame:SetScript("OnUpdate", nil)
    end
    Bars:HideAll()
    TTS:Stop()
    wipe(queue)
    wipe(abilityToEventMap)
    wipe(phaseTimings)
    wipe(phaseDetected)
    wipe(phaseDriftApplied)
    Log:Log("INFO", string.format("== TimerEngine STOP: %d CDs completed, %d still pending, fight ran %.1fs ==",
        doneCount, activeCount, fightElapsed))
end

--- Get current fight elapsed time (public, used by BigWigs plugin)
---@return number seconds
function Engine:GetFightElapsed()
    if not active or fightStartTime == 0 then return 0 end
    return GetTime() - fightStartTime
end

--- Test helper: get queue state for assertions. Returns {abilityName → {isQueued, done}}.
--- Only use in tests — exposes internal state.
function Engine:_testGetQueueState()
    local state = {}
    for _, cd in ipairs(queue) do
        state[cd.abilityName] = {
            isQueued = cd.isQueued,
            done = cd.done,
            windowDuration = cd.windowDuration,
            timeSec = cd.timeSec,
            adjustedTimeSec = cd.adjustedTimeSec,
            windowEndSec = cd.windowEndSec,
            anchorOverridden = cd._anchorOverridden or false,
        }
    end
    return state
end

--- Reset (called on wipe for clean slate)
function Engine:Reset()
    self:Stop()
    fightStartTime = 0
    encounterID = 0
end

------------------------------------------------------------------------
-- OnUpdate Tick
------------------------------------------------------------------------

function Engine:OnUpdate(elapsed)
    if not active then return end

    throttle = throttle + elapsed
    local visibleBars = Bars:GetVisibleCount()
    -- Smooth bar animation: update every frame when bars visible, otherwise save CPU
    local tickRate = visibleBars > 0 and 0 or 1.0
    if throttle < tickRate then return end
    throttle = 0

    local now = GetTime()
    local fightElapsed = now - fightStartTime
    local barWindow = Config:Get("barShowWindow") or 30

    -- Periodic status dump (every N sim-seconds)
    local dumpEvery = isTestMode and 30 or statusDumpInterval
    local currentDumpBucket = math.floor(fightElapsed / dumpEvery)
    if currentDumpBucket > lastStatusDumpSec then
        lastStatusDumpSec = currentDumpBucket
        DumpStatus(fightElapsed)
    end

    -- Dynamic scheduling: activate sequential and conditional CDs each tick
    if useDynamicScheduling then
        ActivateSequentialCDs(fightElapsed)
        EvaluateConditionalCDs(fightElapsed)
    end

    local COUNTDOWN_SECS = 5

    for _, cd in ipairs(queue) do
        if cd.done then
            -- skip

        elseif not cd.isQueued and cd.schedulingMode then
            -- Not yet activated by dynamic scheduling — skip normal processing

        elseif cd.durationActive then
            ----------------------------------------------------------------
            -- PHASE 2: Duration bar — tracking the active window
            -- (ramp = "you're ramping now", burn = "burn window active")
            ----------------------------------------------------------------
            local windowEnd = (cd.windowEndSec or cd.adjustedTimeSec) + (cd._driftOffset or 0)
            local windowRemaining = windowEnd - fightElapsed

            -- Safety: if window is >30s overdue, force-close (catches edge cases
            -- where windowEndSec was corrupted or the check was somehow skipped)
            if windowRemaining <= 0 then
                -- Window ended
                cd.done = true
                Bars:HideDurationBar(cd)
                local tag
                if cd.abilityGameID == 774 then tag = "RAMP"
                elseif cd.abilityGameID == 768 then tag = "CAT "
                else tag = "BURN" end
                local overdue = -windowRemaining
                local suffix = overdue > 2 and string.format(" [%.0fs overdue]", overdue) or ""
                Log:Log("INFO", string.format("[%s] WINDOW END: %s (%s-%s, fight=%s)%s",
                    tag, cd.abilityName,
                    Util.FormatTime(cd.adjustedTimeSec), Util.FormatTime(windowEnd),
                    Util.FormatTime(fightElapsed), suffix))
            else
                -- Update duration bar
                if not cd.durationBarCreated then
                    cd.durationBarCreated = true
                    Bars:ShowDurationBar(cd, cd.windowDuration or 0, windowRemaining)
                    local tag
                    if cd.abilityGameID == 774 then tag = "RAMP"
                    elseif cd.abilityGameID == 768 then tag = "CAT "
                    else tag = "BURN" end
                    Log:Log("INFO", string.format("[%s] WINDOW START: %s %ds (%s-%s)",
                        tag, cd.abilityName, cd.windowDuration or 0,
                        Util.FormatTime(cd.adjustedTimeSec), Util.FormatTime(windowEnd)))
                else
                    Bars:UpdateDurationBar(cd, windowRemaining)
                end
            end

        else
            ----------------------------------------------------------------
            -- PHASE 1: Countdown bar — counting down TO the start time
            ----------------------------------------------------------------
            local timeUntil = cd.adjustedTimeSec - fightElapsed

            if timeUntil <= 0 then
                -- Countdown reached zero — transition to duration phase
                Bars:HideBar(cd)
                cd.durationActive = true
                -- Don't mark done yet — duration bar will handle that

                -- If TTS never fired (e.g. immediate-mode trash CDs that
                -- skip the countdown window), announce now so the player
                -- still gets an audible reminder.
                if not cd.ttsFired and cd.abilityGameID ~= 768 then
                    if Config:Get("announceEnabled") ~= false then
                        TTS:Announce(cd.abilityName, true)
                        Log:Log("INFO", string.format("ANNOUNCE [Amy]: '%s'", cd.abilityName))
                    end
                    cd.ttsFired = true
                    cd.ttsPreFired = true
                end

            elseif not cd.barCreated and timeUntil <= barWindow then
                -- Check if the CD is actually available (skip ramp/cat markers)
                local cdReady = true
                if cd.abilityGameID ~= 774 and cd.abilityGameID ~= 768 then
                    local tracker = HexCDReminder.CooldownTracker
                    if tracker then
                        local ready, remaining = tracker:IsReady(cd.abilityGameID)
                        if not ready then
                            cdReady = false
                            -- CD still on cooldown — defer ONCE to when it'll be ready.
                            -- Only shift timing on first discovery; subsequent ticks leave
                            -- adjustedTimeSec alone so anchors can override without being
                            -- continuously clobbered by deferral recalculation.
                            if not cd._deferredOnce then
                                cd._deferredOnce = true
                                local deferredTime = fightElapsed + remaining
                                Log:Log("INFO", string.format("DEFER (on CD): %s — %.0fs remaining, planned @ %s → deferred to %s",
                                    cd.abilityName, remaining,
                                    Util.FormatTime(cd.adjustedTimeSec),
                                    Util.FormatTime(deferredTime)))
                                Log:Log("INFO", string.format("CD DEFER: %s → %s (was %s, +%.0fs)",
                                    cd.abilityName, Util.FormatTime(deferredTime),
                                    Util.FormatTime(cd.adjustedTimeSec), remaining))
                                -- Shift this CD's timing to when it'll actually be available
                                cd.adjustedTimeSec = deferredTime
                                if cd.windowEndSec and cd.windowDuration then
                                    cd.windowEndSec = deferredTime + cd.windowDuration
                                end
                            end
                            -- Recalculate timeUntil after defer for accurate countdown check below
                            timeUntil = cd.adjustedTimeSec - fightElapsed
                        end
                    end
                end
                if cdReady then
                    -- Show countdown bar
                    cd.barCreated = true
                    Bars:ShowBar(cd, timeUntil)
                    local tag = cd.rampType == "fullRamp" and "RAMP" or cd.rampType == "catWeave" and "CAT" or "BURN"
                    Log:Log("INFO", string.format("COUNTDOWN BAR: [%s] %s in %.0fs @ %s (%ds window -> %s)",
                        tag, cd.abilityName, timeUntil,
                        Util.FormatTime(cd.adjustedTimeSec),
                        cd.windowDuration or 0, Util.FormatTime(cd.windowEndSec or 0)))
                end

            elseif cd.barCreated then
                -- Update countdown bar
                Bars:UpdateBar(cd, timeUntil)
            end

            -- Sound countdown: Jim voice "5,4,3,2,1" → Amy voice announces spell name
            -- Cat Weave (768): no number countdown, but Amy announces when bar appears
            if cd.abilityGameID == 768 then
                if not cd.ttsFired and Config:Get("announceEnabled") ~= false then
                    TTS:Announce(cd.abilityName, true)
                end
                cd.ttsPreFired = true
                cd.ttsFired = true
            end

            if not cd.ttsFired then
                if timeUntil <= COUNTDOWN_SECS and timeUntil > COUNTDOWN_SECS - 2 then
                    Log:Log("INFO", string.format("COUNTDOWN TRIGGER: %s in %ds [Jim → Amy] (fight=%s)",
                        cd.abilityName, COUNTDOWN_SECS,
                        Util.FormatTime(math.floor(fightElapsed))))
                    TTS:Countdown(cd.abilityName, COUNTDOWN_SECS, cd)
                    cd.ttsFired = true
                    cd.ttsPreFired = true
                end
            end
        end
    end
end

------------------------------------------------------------------------
-- BigWigs Drift Adjustment
------------------------------------------------------------------------

--- Adjust CD timings when a BigWigs timer reveals actual boss ability timing
---@param spellID number the boss ability spell ID
---@param barText string the BigWigs bar text
---@param barDuration number seconds until the ability fires
function Engine:AdjustForBigWigsBar(spellID, barText, barDuration)
    if not active then
        Log:Log("DEBUG", string.format("BigWigs bar IGNORED (not active): spell=%d text='%s'", spellID or 0, barText or ""))
        return
    end

    local mapping = abilityToEventMap[spellID]
    if not mapping then
        Log:Log("DEBUG", string.format("BigWigs bar: NO MAPPING for spell %d ('%s') — not in damage timeline", spellID or 0, barText or ""))
        return
    end

    local fightElapsed = GetTime() - fightStartTime
    local actualLandTime = fightElapsed + barDuration
    local expectedLandTime = mapping.expectedTimeSec
    local drift = actualLandTime - expectedLandTime

    -- Only adjust if drift is significant (>2s) but not absurd (>30s = different ability)
    if math.abs(drift) < 2 then
        Log:Log("DEBUG", string.format("BigWigs drift <2s: '%s' (spell=%d) drift=%+.1fs — no adjustment",
            barText, spellID, drift))
        return
    end
    if math.abs(drift) > 30 then
        Log:Log("DEBUG", string.format("BigWigs drift >30s: '%s' (spell=%d) drift=%+.1fs — too large, skipping",
            barText, spellID, drift))
        return
    end

    local adjustCount = 0
    local adjustedNames = {}
    for _, cd in ipairs(queue) do
        if not cd.done and not cd.durationActive and cd.damageEventIndex == mapping.damageEventIndex then
            local oldTime = cd.adjustedTimeSec
            cd.adjustedTimeSec = cd.timeSec + drift
            -- Also shift windowEndSec to keep window duration consistent
            if cd.windowEndSec and cd.windowDuration then
                cd.windowEndSec = cd.adjustedTimeSec + cd.windowDuration
            end
            adjustCount = adjustCount + 1
            table.insert(adjustedNames, string.format("%s %s→%s",
                cd.abilityName, Util.FormatTime(math.floor(oldTime)), Util.FormatTime(math.floor(cd.adjustedTimeSec))))
        end
    end

    if adjustCount > 0 then
        Log:Log("INFO", string.format("BigWigs DRIFT: '%s' (spell=%d) expected=%s actual=%s drift=%+.1fs → adjusted %d CDs",
            barText, spellID,
            Util.FormatTime(math.floor(expectedLandTime)), Util.FormatTime(math.floor(actualLandTime)),
            drift, adjustCount))
        for _, desc in ipairs(adjustedNames) do
            Log:Log("DEBUG", "  shifted: " .. desc)
        end
    end
end

--- Anchor CDs to a BigWigs bar by spell ID.
--- Finds the NEXT pending (undone) CD with matching anchorSpellID and recalculates its timing.
--- Returns true if any CD was anchored.
---@param spellID number BigWigs spell ID
---@param barText string BigWigs bar text
---@param barDuration number Seconds until ability lands
---@return boolean anchored
function Engine:AnchorCDToBigWigsBar(spellID, barText, barDuration)
    if not active or not spellID then return false end

    -- Track anchor fire counts for dynamic scheduling
    anchorFireCounts[spellID] = (anchorFireCounts[spellID] or 0) + 1
    local fireCount = anchorFireCounts[spellID]

    local fightElapsed = GetTime() - fightStartTime
    local abilityLandTime = fightElapsed + barDuration
    local anchored = false

    -- Helper: apply anchor timing to a single queue entry
    local function applyAnchor(cd)
        -- Don't re-anchor CDs already in their active window (duration phase).
        -- Once the player is ramping/burning, moving the window is confusing and
        -- corrupts the remaining-time display.
        if cd.durationActive then
            Log:Log("DEBUG", string.format("ANCHOR SKIP (active window): %s — already in duration phase",
                cd.abilityName))
            return false
        end

        local offset = cd.anchorOffsetSec or 0
        local oldTime = cd.adjustedTimeSec
        local newTime = abilityLandTime + offset
        -- Don't anchor into the past (ability already passed)
        if newTime < fightElapsed - 1 then
            Log:Log("DEBUG", string.format("ANCHOR SKIP: %s — computed time %s is in the past (fight=%s)",
                cd.abilityName, Util.FormatTime(math.floor(newTime)), Util.FormatTime(math.floor(fightElapsed))))
            return false
        end

        cd.adjustedTimeSec = newTime
        -- Shift window end proportionally
        if cd.windowEndSec and cd.windowDuration then
            cd.windowEndSec = newTime + cd.windowDuration
        end

        -- Anchor override: CDs are already queued with timeSec as fallback.
        -- When the anchor fires, we override adjustedTimeSec with the precise
        -- anchor-derived timing. Log whether this is an initial activation or override.
        if cd.schedulingMode == "anchor" then
            if not cd._anchorOverridden then
                cd._anchorOverridden = true
                Log:Log("INFO", string.format("ANCHOR OVERRIDE: %s timer %s → %s (occurrence=%s)",
                    cd.abilityName, Util.FormatTime(math.floor(cd.timeSec)),
                    Util.FormatTime(math.floor(newTime)),
                    tostring(cd.anchorOccurrence or "next")))
            end
            -- maxCDs enforcement (still needed for anchor-scheduled CDs)
            if sectionMaxCDs and not Util.IsMarkerSpell(cd.abilityGameID)
               and not cd._anchorCounted then
                if activatedRealCDs >= sectionMaxCDs then
                    Log:Log("INFO", string.format("ANCHOR CAPPED: %s — maxCDs=%d reached",
                        cd.abilityName, sectionMaxCDs))
                    cd.done = true
                else
                    cd._anchorCounted = true
                    activatedRealCDs = activatedRealCDs + 1
                end
            end
        end

        -- Reset bar state so it redraws at new timing
        if cd.barCreated and not cd.durationActive then
            Bars:HideBar(cd)
            cd.barCreated = false
            cd.ttsPreFired = false
            cd.ttsFired = false
        end
        Log:Log("INFO", string.format("ANCHOR: %s → '%s' (spell=%d) land=%s offset=%+ds → %s (was %s)",
            cd.abilityName, barText, spellID,
            Util.FormatTime(math.floor(abilityLandTime)), offset,
            Util.FormatTime(math.floor(newTime)),
            Util.FormatTime(math.floor(oldTime))))
        return true
    end

    -- Two-pass dedup: prevent multiple entries for the same ability from all
    -- anchoring to the same bar fire. Specific occurrences get priority, then
    -- only ONE occurrence=next per ability per fire.
    -- claimedAbilities[abilityGameID] = true if already anchored for this fire.
    local claimedAbilities = {}

    -- Pass 1: Specific-occurrence entries (occurrence = N, matching fireCount)
    for _, cd in ipairs(queue) do
        if not cd.done and cd.anchorSpellID == spellID and cd.anchorOccurrence then
            if fireCount == cd.anchorOccurrence then
                if applyAnchor(cd) then
                    anchored = true
                    claimedAbilities[cd.abilityGameID] = true
                end
            end
        end
    end

    -- Pass 2: occurrence=next entries (no anchorOccurrence).
    -- Only one per ability per fire, skip if a specific-occurrence already claimed it.
    -- Skip already-overridden CDs to avoid re-claiming the ability slot and blocking
    -- later occurrence=next entries from activating on subsequent fires.
    -- Note: anchor CDs are pre-queued (timer fallback), so check _anchorOverridden not isQueued.
    for _, cd in ipairs(queue) do
        if not cd.done and not cd._anchorOverridden and cd.anchorSpellID == spellID and not cd.anchorOccurrence then
            if claimedAbilities[cd.abilityGameID] then
                -- Skip — another entry already anchored this ability for this fire
                Log:Log("DEBUG", string.format("ANCHOR DEDUP: %s — already anchored for fire #%d of spell %d",
                    cd.abilityName, fireCount, spellID))
            else
                if applyAnchor(cd) then
                    anchored = true
                    claimedAbilities[cd.abilityGameID] = true
                end
            end
        end
    end

    return anchored
end

--- Find damage event by ability for BigWigs matching
---@param spellID number
---@return table|nil mapping
function Engine:FindAbilityMapping(spellID)
    if spellID == nil then return nil end
    -- In Midnight (12.0), BigWigs bar IDs may be secret values that can't be
    -- used as table indices. Wrap in pcall to handle gracefully.
    local ok, result = pcall(function()
        return abilityToEventMap[spellID]
    end)
    if ok then return result end
    return nil
end

------------------------------------------------------------------------
-- Test Mode
------------------------------------------------------------------------

-- Damage event bars (boss ability reference bars shown during test)
local damageEventBars = {}
local DAMAGE_BAR_POOL_SIZE = 4

local function CreateDamageEventBar(index)
    local bar = CreateFrame("StatusBar", "HexCDDmgBar" .. index, UIParent, "BackdropTemplate")
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar.bg:SetVertexColor(0.15, 0.0, 0.0, 0.8)

    bar.nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.nameText:SetPoint("LEFT", 6, 0)
    bar.nameText:SetPoint("RIGHT", bar, "RIGHT", -50, 0)
    bar.nameText:SetJustifyH("LEFT")
    bar.nameText:SetWordWrap(false)

    bar.timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.timeText:SetPoint("RIGHT", -4, 0)
    bar.timeText:SetJustifyH("RIGHT")

    bar.sevText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.sevText:SetPoint("RIGHT", bar.timeText, "LEFT", -6, 0)

    bar:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropBorderColor(0.5, 0.1, 0.1, 0.8)

    bar._active = false
    return bar
end

local SEVERITY_COLORS = {
    low      = { 0.3, 0.6, 0.3 },
    medium   = { 0.8, 0.7, 0.2 },
    high     = { 1.0, 0.4, 0.1 },
    critical = { 1.0, 0.1, 0.1 },
    lethal   = { 1.0, 0.0, 0.5 },
}

-- Track active damage event bars for test mode
local activeDmgBars = {}
local dmgEventQueue = {}
local dmgAnchorFrame = nil

local function CreateDmgAnchorFrame()
    local f = CreateFrame("Frame", "HexCDDmgAnchor", UIParent, "BackdropTemplate")
    f:SetSize((Config:Get("barWidth") or 250) + 20, 20)
    f:SetPoint(
        Config:Get("dmgAnchorPoint") or "CENTER",
        UIParent,
        Config:Get("dmgAnchorPoint") or "CENTER",
        Config:Get("dmgAnchorX") or 300,
        Config:Get("dmgAnchorY") or -200
    )
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.6, 0.1, 0.1, 0.6)
    f:SetBackdropBorderColor(1.0, 0.3, 0.3, 0.8)

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("CENTER")
    f.label:SetText("Boss Abilities — drag to move")

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        Config:Set("dmgAnchorPoint", point)
        Config:Set("dmgAnchorX", math.floor(x + 0.5))
        Config:Set("dmgAnchorY", math.floor(y + 0.5))
        Log:Log("INFO", string.format("Damage bar anchor saved: %s (%.0f, %.0f)", point, x, y))
    end)

    f:Hide()
    return f
end

local function InitDamageBarPool()
    if not dmgAnchorFrame then
        dmgAnchorFrame = CreateDmgAnchorFrame()
    end
    for i = 1, DAMAGE_BAR_POOL_SIZE do
        if not damageEventBars[i] then
            damageEventBars[i] = CreateDamageEventBar(i)
        end
    end
end

local function AcquireDmgBar()
    for _, bar in ipairs(damageEventBars) do
        if not bar._active then
            bar._active = true
            return bar
        end
    end
    return nil
end

local function ReleaseDmgBar(bar)
    bar:Hide()
    bar._active = false
end

local function HideAllDmgBars()
    for _, bar in pairs(activeDmgBars) do
        ReleaseDmgBar(bar)
    end
    wipe(activeDmgBars)
end

local function RepositionDmgBars()
    if not dmgAnchorFrame then return end
    local barW = (Config:Get("barWidth") or 250) + 20
    local barH = (Config:Get("barHeight") or 22)
    local scale = Config:Get("barScale") or 1.0

    local sorted = {}
    for _, bar in pairs(activeDmgBars) do
        if bar._active then table.insert(sorted, bar) end
    end
    table.sort(sorted, function(a, b) return (a._remaining or 0) < (b._remaining or 0) end)

    for i, bar in ipairs(sorted) do
        bar:SetSize(barW, barH)
        bar:SetScale(scale)
        bar:ClearAllPoints()
        bar:SetPoint("BOTTOM", dmgAnchorFrame, "TOP", 0, (i - 1) * (barH + 2))
    end
end

--- Run a simulated fight at accelerated speed
---@param plan table the CD plan
---@param speedMultiplier number default 10
---@param simulateDrift boolean if true, simulate BigWigs drift on damage events
function Engine:RunTest(plan, speedMultiplier, simulateDrift)
    speedMultiplier = speedMultiplier or 10
    local playerClass, playerSpec = Util.GetPlayerSpec()
    playerClass = Util.NormalizeClassName(playerClass)

    local testQueue = BuildQueue(plan, playerClass, playerSpec)
    if #testQueue == 0 then
        Log:Log("ERRORS", "Test mode: no CDs found for your spec in this plan")
        print("|cFFFF0000[HexCD]|r Test mode: no CDs found for your class/spec in the active plan.")
        return
    end

    -- Build damage event queue for visual reference
    dmgEventQueue = {}
    if plan.damageTimeline then
        for i, de in ipairs(plan.damageTimeline) do
            table.insert(dmgEventQueue, {
                timeSec = de.timeSec,
                description = de.description or ("Event " .. i),
                severity = de.severity or "medium",
                raidDamage = de.raidDamage,
                barCreated = false,
                done = false,
            })
        end
    end

    -- Build ability-to-event map for drift testing
    -- If damageTimeline has abilityGameIDs, use those; otherwise assign synthetic IDs
    -- so the drift simulation pipeline works end-to-end
    wipe(abilityToEventMap)
    local syntheticIDBase = 9990000  -- unlikely to collide with real spell IDs
    local dmgDriftSchedule = {}      -- { simTimeSec, spellID, barText, barDuration }
    if plan.damageTimeline then
        for i, de in ipairs(plan.damageTimeline) do
            local ids = de.abilityGameIDs
            if ids and #ids > 0 then
                for _, spellID in ipairs(ids) do
                    abilityToEventMap[spellID] = {
                        damageEventIndex = i,
                        expectedTimeSec = de.timeSec,
                    }
                end
            else
                -- Assign a synthetic ID for this damage event
                local synID = syntheticIDBase + i
                abilityToEventMap[synID] = {
                    damageEventIndex = i,
                    expectedTimeSec = de.timeSec,
                }
                ids = { synID }
            end

            -- Schedule a fake BigWigs bar for drift simulation
            -- BigWigs normally fires ~15-20s before the ability lands
            -- We add random drift: -8s to +8s from expected
            if simulateDrift then
                local drift = math.random(-80, 80) / 10  -- -8.0 to +8.0s
                local bwLeadTime = 15  -- BigWigs shows bar 15s before ability
                local fireAt = math.max(0, de.timeSec - bwLeadTime + drift)
                local barDuration = bwLeadTime - drift  -- so it counts down to the drifted land time
                table.insert(dmgDriftSchedule, {
                    simTimeSec = fireAt,
                    spellID = ids[1],
                    barText = de.description or ("Boss Ability " .. i),
                    barDuration = math.max(1, barDuration),
                    drift = drift,
                    fired = false,
                })
            end
        end
    end

    if simulateDrift and #dmgDriftSchedule > 0 then
        table.sort(dmgDriftSchedule, function(a, b) return a.simTimeSec < b.simTimeSec end)
        Log:Log("INFO", string.format("BigWigs drift simulation: %d events with random drift ±8s", #dmgDriftSchedule))
    end

    InitDamageBarPool()

    -- Initialize phase-relative timing for test mode
    wipe(phaseTimings)
    wipe(phaseDetected)
    wipe(phaseDriftApplied)
    if plan.phaseTimings then
        for phase, timeSec in pairs(plan.phaseTimings) do
            phaseTimings[tonumber(phase)] = timeSec
        end
    end
    phaseDetected[1] = 0
    phaseDriftApplied[1] = 0

    -- Build phase transition schedule for test mode simulation
    -- Always simulate phases with random drift — once a phase starts,
    -- abilities within it keep their relative timing (handled by ApplyPhaseDrift)
    local phaseSchedule = {}
    if plan.phaseTimings then
        for phase, expectedTime in pairs(plan.phaseTimings) do
            phase = tonumber(phase)
            if phase > 1 then
                -- ±8s drift: enough to feel realistic without crazy swings
                local phaseDrift = math.random(-80, 80) / 10
                table.insert(phaseSchedule, {
                    phase = phase,
                    simTimeSec = math.max(1, expectedTime + phaseDrift),
                    drift = phaseDrift,
                    fired = false,
                })
            end
        end
        table.sort(phaseSchedule, function(a, b) return a.simTimeSec < b.simTimeSec end)
        if #phaseSchedule > 0 then
            Log:Log("INFO", string.format("Phase drift simulation: %d phases with random drift ±8s", #phaseSchedule))
            for _, ps in ipairs(phaseSchedule) do
                Log:Log("DEBUG", string.format("  Phase %.1f: expected %s, simulated @ %s (drift=%+.1fs)",
                    ps.phase, Util.FormatTime(phaseTimings[ps.phase] or 0),
                    Util.FormatTime(ps.simTimeSec), ps.drift))
            end
        end
    end

    -- Randomize total fight duration: ranges from ~70% of base to full base
    -- e.g. 596s base → 410s to 596s (6:50 to 9:56) — sometimes fast kill, sometimes near-enrage
    local baseDuration = plan.fightDurationSec or 600
    local minDuration = math.floor(baseDuration * 0.7)
    local duration = math.random(minDuration, baseDuration)
    local driftLabel = simulateDrift and " | BigWigs drift ON" or ""
    print(string.format("|cFF00CCFF[HexCD]|r Test mode: %s fight | %d CDs | %d damage events | %dx speed%s",
        Util.FormatTime(duration), #testQueue, #dmgEventQueue, speedMultiplier, driftLabel))

    -- Use actual timer engine with time compression
    encounterID = plan.encounterID or 0
    fightStartTime = GetTime()
    lastStatusDumpSec = -999
    isTestMode = true
    queue = testQueue
    active = true
    throttle = 0

    if not updateFrame then
        updateFrame = CreateFrame("Frame", "HexCDTimerEngineFrame")
    end

    -- Progress bar at top showing fight timeline
    if not Engine._progressBar then
        local pb = CreateFrame("StatusBar", "HexCDProgressBar", UIParent, "BackdropTemplate")
        pb:SetSize(400, 14)
        pb:SetPoint("TOP", UIParent, "TOP", 0, -10)
        pb:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        pb:SetStatusBarColor(0.2, 0.6, 1.0, 0.8)
        pb:SetMinMaxValues(0, 1)
        pb.bg = pb:CreateTexture(nil, "BACKGROUND")
        pb.bg:SetAllPoints()
        pb.bg:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
        pb.bg:SetVertexColor(0.05, 0.05, 0.1, 0.8)
        pb.text = pb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        pb.text:SetPoint("CENTER")
        Engine._progressBar = pb
    end
    Engine._progressBar:SetMinMaxValues(0, duration)
    Engine._progressBar:Show()

    local realStartTime = GetTime()
    local dmgBarWindow = 15  -- show damage bars 15s before they hit

    updateFrame:SetScript("OnUpdate", function(_, elapsed)
        if not active then return end

        local realElapsed = GetTime() - realStartTime
        local simElapsed = realElapsed * speedMultiplier

        -- Compressed time for CD engine
        fightStartTime = GetTime() - simElapsed
        Engine:OnUpdate(elapsed)

        -- Fire simulated phase transitions at appropriate sim time
        for _, ps in ipairs(phaseSchedule) do
            if not ps.fired and simElapsed >= ps.simTimeSec then
                ps.fired = true
                Log:Log("INFO", string.format(
                    "TEST PHASE: %.1f detected at sim %s (drift=%+.1fs from expected %s)",
                    ps.phase, Util.FormatTime(simElapsed), ps.drift,
                    Util.FormatTime(phaseTimings[ps.phase] or 0)))
                Engine:OnPhaseTransition(ps.phase, simElapsed)
            end
        end

        -- Fire simulated BigWigs drift events at appropriate sim time
        for _, driftEvt in ipairs(dmgDriftSchedule) do
            if not driftEvt.fired and simElapsed >= driftEvt.simTimeSec then
                driftEvt.fired = true
                Log:Log("INFO", string.format(
                    "TEST BigWigs: '%s' at sim %s, drift=%+.1fs, bar=%.1fs",
                    driftEvt.barText, Util.FormatTime(simElapsed), driftEvt.drift, driftEvt.barDuration))
                Engine:AdjustForBigWigsBar(driftEvt.spellID, driftEvt.barText, driftEvt.barDuration)
            end
        end

        -- Update progress bar
        Engine._progressBar:SetValue(simElapsed)
        Engine._progressBar.text:SetText(string.format("TEST %dx  |  %s / %s",
            speedMultiplier, Util.FormatTime(simElapsed), Util.FormatTime(duration)))

        -- Update damage event bars
        for _, de in ipairs(dmgEventQueue) do
            if de.done then
                -- skip
            else
                local timeUntil = de.timeSec - simElapsed

                if timeUntil <= -3 then
                    de.done = true
                    if activeDmgBars[de] then
                        ReleaseDmgBar(activeDmgBars[de])
                        activeDmgBars[de] = nil
                        RepositionDmgBars()
                        Log:Log("DEBUG", string.format("BOSS EVENT DONE: %s @ %s",
                            de.description or "?", Util.FormatTime(de.timeSec)))
                    end
                elseif not de.barCreated and timeUntil <= dmgBarWindow then
                    local bar = AcquireDmgBar()
                    if bar then
                        de.barCreated = true
                        bar._remaining = timeUntil
                        Log:Log("INFO", string.format("BOSS BAR SHOW: %s in %.0fs @ %s [%s]",
                            de.description or "?", timeUntil, Util.FormatTime(de.timeSec), (de.severity or "?"):upper()))

                        -- Severity color
                        local sc = SEVERITY_COLORS[de.severity] or SEVERITY_COLORS.medium
                        bar:SetStatusBarColor(sc[1], sc[2], sc[3], 0.85)

                        -- Truncate description for display
                        local desc = de.description or ""
                        if #desc > 50 then desc = desc:sub(1, 47) .. "..." end
                        bar.nameText:SetText(desc)

                        local sevLabel = (de.severity or ""):upper()
                        bar.sevText:SetText("|cFF" .. (
                            de.severity == "critical" and "FF2222" or
                            de.severity == "high" and "FF6611" or
                            de.severity == "lethal" and "FF00AA" or "CCCC44"
                        ) .. sevLabel .. "|r")

                        bar:SetMinMaxValues(0, dmgBarWindow)
                        bar:SetValue(math.max(0, timeUntil))
                        bar.timeText:SetText(Util.FormatCountdown(timeUntil))
                        bar:Show()
                        activeDmgBars[de] = bar
                        RepositionDmgBars()
                    end
                elseif activeDmgBars[de] then
                    local bar = activeDmgBars[de]
                    bar._remaining = timeUntil
                    bar:SetValue(math.max(0, timeUntil))
                    bar.timeText:SetText(Util.FormatCountdown(math.max(0, timeUntil)))
                    -- Flash when hitting
                    if timeUntil <= 0 then
                        local pulse = 0.5 + 0.5 * math.abs(math.sin(GetTime() * 5))
                        bar:SetAlpha(pulse)
                    else
                        bar:SetAlpha(1.0)
                    end
                end
            end
        end

        -- Auto-stop at fight end
        if simElapsed >= duration then
            print("|cFF00CCFF[HexCD]|r Test mode complete.")
            Engine:Stop()
            HideAllDmgBars()
            Engine._progressBar:Hide()
        end
    end)
end

--- Public: dump current queue status on demand (/hexcd dump)
function Engine:DumpStatus()
    if not active then
        Log:Log("INFO", "TimerEngine is NOT active — no fight in progress.")
        print("|cFFFF0000[HexCD]|r No fight active. Use /hexcd test to start a test fight.")
        return
    end
    local fightElapsed = GetTime() - fightStartTime
    DumpStatus(fightElapsed)
    -- Also dump to chat directly
    print("|cFF00CCFF[HexCD]|r Status dumped to debug log. Use /hexcd log to view.")
end

--- Override Stop to clean up test visuals
local originalStop = Engine.Stop
function Engine:Stop()
    originalStop(self)
    HideAllDmgBars()
    wipe(dmgEventQueue)
    if Engine._progressBar then Engine._progressBar:Hide() end
end

------------------------------------------------------------------------
-- Damage Bar Anchor Lock/Unlock (public API for GUI)
------------------------------------------------------------------------

function Engine:UnlockDmgBars()
    if not dmgAnchorFrame then
        InitDamageBarPool()
    end
    dmgAnchorFrame:EnableMouse(true)
    dmgAnchorFrame:Show()
    print("|cFF00CCFF[HexCD]|r Boss ability bars |cFFFFCC00UNLOCKED|r — drag the red handle to move.")
end

function Engine:LockDmgBars()
    if dmgAnchorFrame then
        dmgAnchorFrame:EnableMouse(false)
        dmgAnchorFrame:Hide()
        print("|cFF00CCFF[HexCD]|r Boss ability bars |cFF00FF00LOCKED|r — position saved.")
    end
end

function Engine:ToggleDmgLock()
    if dmgAnchorFrame and dmgAnchorFrame:IsShown() then
        self:LockDmgBars()
        return true
    else
        self:UnlockDmgBars()
        return false
    end
end

function Engine:IsDmgUnlocked()
    return dmgAnchorFrame and dmgAnchorFrame:IsShown() or false
end
