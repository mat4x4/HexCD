------------------------------------------------------------------------
-- HexCD_Reminder: Configuration & SavedVariables
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.Config = {}

local Config = HexCDReminder.Config

local DEFAULTS = {
    -- Timing mode
    timingMode = "bigwigs",        -- "bigwigs" or "elapsed"

    -- TTS settings
    ttsEnabled = true,
    ttsLeadTime = {
        fullRamp = 22,             -- seconds before CD time to announce ramp
        burn     = 8,              -- seconds before CD time for burn-phase CDs
        catWeave = 0,              -- no lead time for cat weave markers
        noRamp   = 8,
    },
    ttsRate   = 3,                 -- 1-10 speech rate
    ttsVolume = 100,               -- 0-100

    -- Announce spell in /say after countdown finishes
    announceEnabled = true,

    -- Bar settings
    barWidth         = 250,
    barHeight        = 22,
    barScale         = 1.0,
    barGrowDirection = "UP",       -- "UP" or "DOWN"
    barAnchorPoint   = "CENTER",
    barAnchorX       = 0,
    barAnchorY       = -200,
    barShowWindow    = 30,         -- show bar N seconds before CD time

    -- Colors by ramp type {r, g, b}
    barColors = {
        fullRamp = { 1.0, 0.84, 0.0 },   -- gold
        burn     = { 1.0, 0.4,  0.1 },   -- orange
        catWeave = { 0.2, 0.9,  0.2 },   -- green
        noRamp   = { 0.3, 0.6,  1.0 },   -- blue
    },

    -- Ramp bar anchor position (separate from CD bars)
    rampAnchorPoint  = "CENTER",
    rampAnchorX      = 0,
    rampAnchorY      = -130,

    -- Window tracker bar anchor position (RAMPING/BURNING/CAT WEAVE active phases)
    windowAnchorPoint = "CENTER",
    windowAnchorX     = 0,
    windowAnchorY     = -270,

    -- Damage bar (boss ability) anchor position
    dmgAnchorPoint   = "CENTER",
    dmgAnchorX       = 300,
    dmgAnchorY       = -200,

    -- Per-CD overrides: key = "encounterID:timeSec:abilityGameID"
    -- value = { enabled = bool, ttsText = string, ttsLeadTime = number }
    cdOverrides = {},

    -- Debug
    logLevel = "INFO",             -- OFF, ERRORS, INFO, DEBUG, TRACE

    -- Plans (imported Lua tables): encounterID → plan table
    plans = {},

    -- Dungeon plans (imported Lua tables): challengeMapID → DungeonCDPlan table
    dungeonPlans = {},

    -- Auto-saved fight logs (last 10)
    fightLogs = {},

    -- Auto-export settings
    autoExportOnWipe = true,       -- auto-open log frame after raid wipe
    autoExportOnKeyEnd = true,     -- auto-open session log after M+ key completion
}

--- Initialize config with defaults for missing keys
function Config:Init()
    if not HexCDReminderDB then
        HexCDReminderDB = HexCDReminder.Util.DeepCopy(DEFAULTS)
        return
    end
    -- Fill in missing keys from defaults
    for k, v in pairs(DEFAULTS) do
        if HexCDReminderDB[k] == nil then
            HexCDReminderDB[k] = HexCDReminder.Util.DeepCopy(v)
        elseif type(v) == "table" and type(HexCDReminderDB[k]) == "table" then
            for sk, sv in pairs(v) do
                if HexCDReminderDB[k][sk] == nil then
                    HexCDReminderDB[k][sk] = HexCDReminder.Util.DeepCopy(sv)
                end
            end
        end
    end
end

--- Get a config value
---@param key string
---@return any
function Config:Get(key)
    if HexCDReminderDB and HexCDReminderDB[key] ~= nil then
        return HexCDReminderDB[key]
    end
    return DEFAULTS[key]
end

--- Set a config value
---@param key string
---@param value any
function Config:Set(key, value)
    if not HexCDReminderDB then HexCDReminderDB = HexCDReminder.Util.DeepCopy(DEFAULTS) end
    HexCDReminderDB[key] = value
end

--- Get TTS lead time for a ramp type
---@param rampType string "fullRamp"|"miniRamp"|"noRamp"
---@return number seconds
function Config:GetTTSLeadTime(rampType)
    local lt = self:Get("ttsLeadTime")
    return lt and lt[rampType] or DEFAULTS.ttsLeadTime[rampType] or 8
end

--- Get bar color for a ramp type
---@param rampType string
---@return number r, number g, number b
function Config:GetBarColor(rampType)
    local colors = self:Get("barColors")
    local c = colors and colors[rampType] or DEFAULTS.barColors.noRamp
    return c[1], c[2], c[3]
end

--- Get a per-CD override
---@param encounterID number
---@param timeSec number
---@param abilityGameID number
---@return table|nil {enabled, ttsText, ttsLeadTime}
function Config:GetCDOverride(encounterID, timeSec, abilityGameID)
    local key = string.format("%d:%d:%d", encounterID, timeSec, abilityGameID)
    local overrides = self:Get("cdOverrides")
    return overrides and overrides[key]
end

--- Check if a plan has playerName fields on its healer assignments
---@param plan table
---@return boolean
local function PlanHasPlayerNames(plan)
    if not plan or not plan.healerAssignments then return false end
    for _, healer in ipairs(plan.healerAssignments) do
        if healer.playerName and healer.playerName ~= "" then
            return true
        end
    end
    return false
end

--- Map WoW difficultyID to the plan difficulty values used in CD plan data files.
--- WoW uses: 14=Normal, 15=Heroic, 16=Mythic (current raid flex).
--- WCL/plan files use: 3=Normal, 4=Heroic, 5=Mythic.
---@param wowDifficultyID number
---@return number planDifficulty
local function MapDifficulty(wowDifficultyID)
    local MAP = {
        [3]  = 3,  -- Legacy Normal 10
        [4]  = 4,  -- Legacy Normal 25 → Heroic equivalent
        [5]  = 5,  -- Legacy Heroic 10 → Mythic equivalent
        [14] = 4,  -- Normal Flex → plan Heroic (closest tuning)
        [15] = 4,  -- Heroic Flex → plan Heroic
        [16] = 5,  -- Mythic 20 → plan Mythic
        [17] = 3,  -- LFR → plan Normal
        [8]  = 8,  -- M+ (passed through, handled by MythicPlusEngine)
    }
    return MAP[wowDifficultyID] or wowDifficultyID
end

--- Resolve a bundled plan for an encounter + difficulty.
--- BundledPlans[eid] can be either:
---   (new) a table keyed by difficulty: BundledPlans[eid][diff] = plan
---   (legacy) a single plan object:     BundledPlans[eid] = plan
--- Returns the best match: exact difficulty → highest available → nil.
---@param encounterID number
---@param difficultyID number|nil
---@return table|nil plan
local function ResolveBundledPlan(encounterID, difficultyID)
    local entry = HexCDReminder.BundledPlans and HexCDReminder.BundledPlans[encounterID]
    if not entry then return nil end

    -- Legacy format: entry IS the plan (has healerAssignments)
    if entry.healerAssignments then
        return entry
    end

    -- New format: entry[difficulty] = plan
    if difficultyID and entry[difficultyID] then
        return entry[difficultyID]
    end

    -- Fallback: prefer higher difficulty first, then lower
    -- e.g. if current is Heroic (4): try Mythic (5) first, then Normal (3), then LFR (1)
    if difficultyID then
        -- Try higher difficulties ascending (closest higher first)
        for diff = difficultyID + 1, 5 do
            if entry[diff] then return entry[diff] end
        end
        -- Then lower difficulties descending (closest lower first)
        for diff = difficultyID - 1, 1, -1 do
            if entry[diff] then return entry[diff] end
        end
    end

    -- No difficultyID given or nothing found: highest available
    local best, bestDiff = nil, 0
    for diff, plan in pairs(entry) do
        if type(diff) == "number" and diff > bestDiff then
            best, bestDiff = plan, diff
        end
    end
    return best
end

--- Get plan for an encounter (checks SavedVariables first, then bundled plans)
--- If bundled plan has playerName fields but saved plan doesn't, prefer bundled
--- (catches stale imports from before playerName was added)
---@param encounterID number
---@param difficultyID number|nil  Current instance difficulty (3=Normal, 4=Heroic, 5=Mythic)
---@return table|nil plan, string|nil source
function Config:GetPlan(encounterID, difficultyID)
    -- Map WoW difficulty IDs (14/15/16) to plan difficulty values (3/4/5)
    local planDiff = difficultyID and MapDifficulty(difficultyID) or nil

    local savedPlans = self:Get("plans")
    -- Saved plans: try [eid][diff] (new) then [eid] (legacy)
    local savedPlan = nil
    if savedPlans and savedPlans[encounterID] then
        local entry = savedPlans[encounterID]
        if entry.healerAssignments then
            -- Legacy format: single plan
            savedPlan = entry
        elseif planDiff and entry[planDiff] then
            savedPlan = entry[planDiff]
        elseif planDiff then
            -- Fallback: prefer higher difficulty first, then lower
            for diff = planDiff + 1, 5 do
                if type(entry[diff]) == "table" and entry[diff].healerAssignments then
                    savedPlan = entry[diff]; break
                end
            end
            if not savedPlan then
                for diff = planDiff - 1, 1, -1 do
                    if type(entry[diff]) == "table" and entry[diff].healerAssignments then
                        savedPlan = entry[diff]; break
                    end
                end
            end
        else
            -- No difficulty: highest available
            local bestDiff = 0
            for diff, plan in pairs(entry) do
                if type(diff) == "number" and diff > bestDiff then
                    savedPlan, bestDiff = plan, diff
                end
            end
        end
    end

    local bundledPlan = ResolveBundledPlan(encounterID, planDiff)

    if savedPlan and bundledPlan then
        -- If bundled has playerNames but saved doesn't, saved is stale — prefer bundled
        if PlanHasPlayerNames(bundledPlan) and not PlanHasPlayerNames(savedPlan) then
            if HexCDReminder.DebugLog then
                HexCDReminder.DebugLog:Log("INFO", string.format(
                    "Plan %d: saved plan lacks playerName, using bundled plan instead (run /hexcd clearplans to remove stale imports)",
                    encounterID))
            end
            return bundledPlan, "bundled"
        end
        return savedPlan, "imported"
    elseif savedPlan then
        return savedPlan, "imported"
    elseif bundledPlan then
        return bundledPlan, "bundled"
    end
    return nil, nil
end

--- Get dungeon CD plan by challenge map ID (checks SavedVariables first, then bundled)
---@param challengeMapID number
---@return table|nil plan, string|nil source
function Config:GetDungeonPlan(challengeMapID)
    local savedPlans = self:Get("dungeonPlans")
    local savedPlan = savedPlans and savedPlans[challengeMapID]
    local bundledPlan = HexCDReminder.BundledDungeonPlans and HexCDReminder.BundledDungeonPlans[challengeMapID]
    if savedPlan then
        return savedPlan, "imported"
    elseif bundledPlan then
        return bundledPlan, "bundled"
    end
    return nil, nil
end

--- Get all available plans (merged: SavedVariables + bundled).
--- Returns a flat map: encounterID → { difficulty → plan }.
--- Each encounter may have multiple difficulties.
---@return table planMap: encounterID → { difficulty → plan }
function Config:GetAllPlans()
    local merged = {} -- [eid] = { [diff] = plan }

    -- Bundled plans first (lower priority)
    if HexCDReminder.BundledPlans then
        for eid, entry in pairs(HexCDReminder.BundledPlans) do
            merged[eid] = merged[eid] or {}
            if entry.healerAssignments then
                -- Legacy: single plan
                merged[eid][entry.difficulty or 4] = entry
            else
                -- New: keyed by difficulty
                for diff, plan in pairs(entry) do
                    if type(diff) == "number" then
                        merged[eid][diff] = plan
                    end
                end
            end
        end
    end

    -- SavedVariables plans override bundled
    local saved = self:Get("plans")
    if saved then
        for eid, entry in pairs(saved) do
            merged[eid] = merged[eid] or {}
            if entry.healerAssignments then
                -- Legacy: single plan
                merged[eid][entry.difficulty or 4] = entry
            else
                for diff, plan in pairs(entry) do
                    if type(diff) == "number" then
                        merged[eid][diff] = plan
                    end
                end
            end
        end
    end

    return merged
end
