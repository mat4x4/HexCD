------------------------------------------------------------------------
-- HexCD: BigWigs Integration Plugin
-- Hooks into BigWigs boss ability timers for drift-adjusted CD timing
-- Conditionally loaded — does nothing if BigWigs is not present
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}

local Log = HexCDReminder.DebugLog
local Config = HexCDReminder.Config
local Engine = HexCDReminder.TimerEngine

-- Early exit if BigWigs is not loaded
local bigwigsLoaded = false
do
    -- Check both possible addon names
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        bigwigsLoaded = C_AddOns.IsAddOnLoaded("BigWigs") or C_AddOns.IsAddOnLoaded("BigWigs_Core")
    elseif IsAddOnLoaded then
        bigwigsLoaded = IsAddOnLoaded("BigWigs") or IsAddOnLoaded("BigWigs_Core")
    end
end

if not bigwigsLoaded then
    HexCDReminder.BigWigsAvailable = false
    return
end

HexCDReminder.BigWigsAvailable = true

------------------------------------------------------------------------
-- Ability Timeline Tracker
-- Records every BigWigs bar for anchor analysis (especially raids).
-- Persisted in fight logs so we can later identify anchorable abilities.
------------------------------------------------------------------------

local abilityTimeline = {}   -- ordered array of timeline entries
local spellFireCounts = {}   -- spellID → cumulative fire count this fight

--- Reset timeline for a new fight
local function ResetTimeline()
    wipe(abilityTimeline)
    wipe(spellFireCounts)
end

--- Record a BigWigs bar start into the timeline
---@param fightElapsed number seconds since fight start
---@param spellID number|nil extracted spell ID (nil if secret/unavailable)
---@param text string bar text
---@param duration number bar duration in seconds
---@param matchType string "anchor"|"drift"|"unmatched"
local function RecordTimelineEntry(fightElapsed, spellID, text, duration, matchType)
    local fireCount = 0
    if spellID then
        spellFireCounts[spellID] = (spellFireCounts[spellID] or 0) + 1
        fireCount = spellFireCounts[spellID]
    end
    table.insert(abilityTimeline, {
        fightSec     = fightElapsed,
        landSec      = fightElapsed + duration,
        spellID      = spellID,
        text         = text,
        duration     = duration,
        fireCount    = fireCount,
        matchType    = matchType,
    })
end

--- Get the current timeline (for saving)
function HexCDReminder.GetAbilityTimeline()
    return abilityTimeline
end

--- Get fire counts (for saving / summary)
function HexCDReminder.GetSpellFireCounts()
    return spellFireCounts
end

------------------------------------------------------------------------
-- BigWigs Plugin Registration
------------------------------------------------------------------------

-- Wait for BigWigs to be fully initialized
local pluginFrame = CreateFrame("Frame")
pluginFrame:RegisterEvent("ADDON_LOADED")
pluginFrame:SetScript("OnEvent", function(self, event, addonName)
    -- BigWigs may load in parts; wait for the core
    if not BigWigs or not BigWigs.NewPlugin then return end

    local plugin = BigWigs:NewPlugin("HexCD")
    if not plugin then
        Log:Log("ERRORS", "BigWigs: Failed to register as plugin")
        return
    end

    HexCDReminder.BigWigsPlugin = plugin

    function plugin:OnPluginEnable()
        self:RegisterMessage("BigWigs_OnBossEngage", "OnBossEngage")
        self:RegisterMessage("BigWigs_OnBossWipe", "OnBossWipe")
        self:RegisterMessage("BigWigs_OnBossWin", "OnBossWin")
        self:RegisterMessage("BigWigs_StartBar", "OnStartBar")
        self:RegisterMessage("BigWigs_StopBar", "OnStopBar")
        self:RegisterMessage("BigWigs_OnBossDisable", "OnBossDisable")
        self:RegisterMessage("BigWigs_SetStage", "OnSetStage")
        Log:Log("INFO", "BigWigs plugin enabled — listening for boss events + phase transitions")
    end

    function plugin:OnPluginDisable()
        Log:Log("INFO", "BigWigs plugin disabled")
    end

    --- Boss engagement confirmed by BigWigs
    function plugin:OnBossEngage(event, module)
        local modName = module and module.moduleName or "unknown"
        local encID = module and module.GetEncounterID and module:GetEncounterID() or 0
        Log:Log("DEBUG", string.format("BigWigs_OnBossEngage: %s (encounter %d)", modName, encID))
        -- Reset ability timeline for fresh fight
        ResetTimeline()
    end

    --- Log a summary of all BigWigs bars seen this fight (anchor analysis data)
    local function LogTimelineSummary()
        local timeline = abilityTimeline
        if #timeline == 0 then return end

        Log:Log("INFO", string.format("== ABILITY TIMELINE SUMMARY: %d bars recorded ==", #timeline))

        -- Group by spellID for anchor candidacy analysis
        local bySpell = {}  -- spellID → { text, count, matchTypes, intervals }
        local prevLandBySpell = {}  -- spellID → last land time (for interval calc)
        for _, e in ipairs(timeline) do
            local key = e.spellID or 0
            if not bySpell[key] then
                bySpell[key] = { text = e.text, count = 0, matchTypes = {}, intervals = {}, durations = {} }
            end
            local info = bySpell[key]
            info.count = info.count + 1
            info.matchTypes[e.matchType] = (info.matchTypes[e.matchType] or 0) + 1
            table.insert(info.durations, e.duration)
            -- Track intervals between consecutive fires
            if prevLandBySpell[key] then
                table.insert(info.intervals, e.fightSec - prevLandBySpell[key])
            end
            prevLandBySpell[key] = e.fightSec
        end

        -- Sort by fire count descending (most frequent = best anchor candidates)
        local sorted = {}
        for spellID, info in pairs(bySpell) do
            table.insert(sorted, { spellID = spellID, info = info })
        end
        table.sort(sorted, function(a, b) return a.info.count > b.info.count end)

        for _, entry in ipairs(sorted) do
            local info = entry.info
            -- Average interval between fires
            local avgInterval = 0
            if #info.intervals > 0 then
                local sum = 0
                for _, v in ipairs(info.intervals) do sum = sum + v end
                avgInterval = sum / #info.intervals
            end
            -- Average duration
            local avgDur = 0
            if #info.durations > 0 then
                local sum = 0
                for _, v in ipairs(info.durations) do sum = sum + v end
                avgDur = sum / #info.durations
            end
            -- Match type breakdown
            local matchStr = ""
            for mt, ct in pairs(info.matchTypes) do
                if matchStr ~= "" then matchStr = matchStr .. "," end
                matchStr = matchStr .. mt .. "=" .. ct
            end
            Log:Log("INFO", string.format("  spell=%s '%s' fires=%d avgInterval=%.1fs avgDur=%.1fs [%s]",
                entry.spellID ~= 0 and tostring(entry.spellID) or "?",
                info.text, info.count, avgInterval, avgDur, matchStr))
        end
    end

    --- Boss wipe confirmed by BigWigs
    function plugin:OnBossWipe(event, module)
        Log:Log("DEBUG", "BigWigs_OnBossWipe: " .. (module and module.moduleName or "unknown"))
        LogTimelineSummary()
    end

    --- Boss kill confirmed by BigWigs
    function plugin:OnBossWin(event, module)
        Log:Log("DEBUG", "BigWigs_OnBossWin: " .. (module and module.moduleName or "unknown"))
        LogTimelineSummary()
    end

    --- Boss module disabled
    function plugin:OnBossDisable(event, module)
        Log:Log("TRACE", "BigWigs_OnBossDisable: " .. (module and module.moduleName or "unknown"))
    end

    --- Boss phase transition detected by BigWigs
    --- BigWigs fires this with the new stage number (1, 2, 3, etc.)
    --- Some bosses use intermission stages (e.g., Crown: 1→1.5→2→2.5→3)
    --- BigWigs stage numbers may differ from our phase numbering
    function plugin:OnSetStage(event, module, stage)
        local modName = module and module.moduleName or "unknown"
        local stageNum = tonumber(stage) or 0
        Log:Log("INFO", string.format("BigWigs_SetStage: %s stage=%d", modName, stageNum))

        if Engine.OnPhaseTransition then
            -- Map BigWigs stage numbers to our phase numbers
            -- BigWigs typically uses: 1, 2, 3, 4, 5 for sequential phases
            -- Our plan uses: 1, 1.5, 2, 2.5, 3 (intermissions get .5)
            -- For Crown of the Cosmos (3181):
            --   BW stage 1 = P1 (our 1)
            --   BW stage 2 = Intermission 1 (our 1.5)
            --   BW stage 3 = P2 (our 2)
            --   BW stage 4 = Intermission 2 (our 2.5)
            --   BW stage 5 = P3 (our 3)
            local phaseMap = {
                [1] = 1,
                [2] = 1.5,
                [3] = 2,
                [4] = 2.5,
                [5] = 3,
            }
            local phase = phaseMap[stageNum] or stageNum

            -- Calculate fight elapsed time
            local fightElapsed = 0
            if Engine._getFightElapsed then
                fightElapsed = Engine:_getFightElapsed()
            else
                -- Fallback: use GetTime() - fightStartTime (exposed via public method)
                fightElapsed = Engine:GetFightElapsed()
            end

            Log:Log("INFO", string.format("  Mapped BW stage %d -> phase %.1f at fight %s",
                stageNum, phase, HexCDReminder.Util.FormatTime(math.floor(fightElapsed))))
            Engine:OnPhaseTransition(phase, fightElapsed)
        end
    end

    --- Track BigWigs bar start times for StopBar elapsed calculation
    local barStartTimes = {}

    --- A BigWigs timer bar started — opportunity for drift adjustment
    --- Safely stringify a value that might be a Midnight secret.
    local function safeStr(val)
        if val == nil then return "nil" end
        local ok, s = pcall(tostring, val)
        if not ok then return "SECRET" end
        local cmpOk = pcall(function() return s == "" end)
        if not cmpOk then return "SECRET" end
        return s
    end

    function plugin:OnStartBar(event, module, barId, text, duration, icon)
        -- Safe value extraction (Midnight 12.0 secret values)
        local durSafe = 0
        pcall(function() durSafe = duration + 0 end)
        local textSafe = safeStr(text)

        -- Track start time for StopBar elapsed calculation
        local barKey = safeStr(barId)
        barStartTimes[barKey] = { startTime = GetTime(), duration = durSafe, text = textSafe }

        -- Extract spell ID (may be secret in Midnight 12.0)
        local spellID = nil
        pcall(function()
            if type(barId) == "number" then
                spellID = barId + 0
            end
        end)
        if not spellID then
            pcall(function()
                if type(icon) == "number" then
                    spellID = icon + 0
                end
            end)
        end

        -- Compute fight-relative time for timeline
        local fightElapsed = 0
        if Engine.GetFightElapsed then
            fightElapsed = Engine:GetFightElapsed()
        end

        -- Determine match type and log accordingly
        local matchType = "unmatched"

        if Config:Get("timingMode") ~= "bigwigs" then
            -- Still record in timeline even if timing mode is elapsed
            RecordTimelineEntry(fightElapsed, spellID, textSafe, durSafe, "skipped")
            Log:Log("INFO", string.format("BW_BAR: '%s' spell=%s dur=%.1f land@%s [SKIPPED mode=%s]",
                textSafe, spellID and tostring(spellID) or "?", durSafe,
                HexCDReminder.Util.FormatTime(math.floor(fightElapsed + durSafe)),
                Config:Get("timingMode") or "?"))
            return
        end

        if spellID then
            -- Try anchor-based matching first (explicit CD → boss ability link)
            local anchored = false
            if Engine.AnchorCDToBigWigsBar then
                anchored = Engine:AnchorCDToBigWigsBar(spellID, text or "", duration or 0)
            end
            if anchored then
                matchType = "anchor"
            end

            -- Fall back to drift-based matching for unanchored CDs
            if not anchored and Engine.FindAbilityMapping then
                local mapping = Engine:FindAbilityMapping(spellID)
                if mapping then
                    Log:Log("DEBUG", string.format("  Mapped: spell %d → dmgEvent #%d (expected %s)",
                        spellID, mapping.damageEventIndex,
                        HexCDReminder.Util.FormatTime(math.floor(mapping.expectedTimeSec))))
                    Engine:AdjustForBigWigsBar(spellID, text or "", duration or 0)
                    matchType = "drift"
                end
            end
        end

        -- Record to ability timeline (always, regardless of match)
        RecordTimelineEntry(fightElapsed, spellID, textSafe, durSafe, matchType)

        -- Structured log line for every bar — INFO level so it always shows in fight logs
        local fireCount = spellID and (spellFireCounts[spellID] or 0) or 0
        Log:Log("INFO", string.format("BW_BAR: '%s' spell=%s dur=%.1f land@%s fire#%d [%s]",
            textSafe, spellID and tostring(spellID) or "?", durSafe,
            HexCDReminder.Util.FormatTime(math.floor(fightElapsed + durSafe)),
            fireCount, matchType:upper()))
    end

    --- A BigWigs timer bar stopped (expired or cancelled)
    function plugin:OnStopBar(event, module, barId)
        local barStr = safeStr(barId)
        local now = GetTime()
        -- Look up when this bar started to compute actual duration
        local startInfo = barStartTimes[barStr]
        if startInfo then
            local elapsed = now - startInfo.startTime
            Log:Log("INFO", string.format("BigWigs_StopBar: barId=%s text='%s' elapsed=%.1fs (planned=%.1fs)",
                barStr, startInfo.text or "?", elapsed, startInfo.duration or 0))
            barStartTimes[barStr] = nil
        else
            Log:Log("INFO", string.format("BigWigs_StopBar: barId=%s (no start tracked)", barStr))
        end
    end

    Log:Log("INFO", "BigWigs plugin registered successfully")
    self:UnregisterEvent("ADDON_LOADED")
end)
