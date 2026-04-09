------------------------------------------------------------------------
-- HexCD_Reminder: Core — Addon entry point, event handling, slash commands
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}

local ADDON_NAME = "HexCD_Reminder"
local VERSION = "1.0.0"

local Config = HexCDReminder.Config
local Engine = HexCDReminder.TimerEngine
local MP     = HexCDReminder.MythicPlus
local Bars = HexCDReminder.TimerBars
local TTS = HexCDReminder.TTS
local Log = HexCDReminder.DebugLog
local Import = HexCDReminder.PlanImport
local GUI = HexCDReminder.ConfigGUI
local Util = HexCDReminder.Util

------------------------------------------------------------------------
-- Event Frame
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "HexCDReminderEventFrame")

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            -- Burn through random sequence so test mode gets different values each session
            -- (WoW removes math.randomseed, but math.random advances the state)
            local burns = math.floor(GetTime() * 10) % 200
            for _ = 1, burns do math.random() end
            Config:Init()
            Log:Init()
            Bars:Init()
            GUI:Init()
            -- Initialize CooldownTracker and markers for current spec
            local initCls, initSpec = Util.GetPlayerSpec()
            if initSpec ~= "" then
                Util.SetSpecMarkers(initCls, initSpec)
                if HexCDReminder.CooldownTracker then
                    HexCDReminder.CooldownTracker:SetSpec(initCls, initSpec)
                end
            end
            Log:Log("INFO", string.format("HexCD Reminder v%s loaded. BigWigs: %s. Type /hexcdr for commands.",
                VERSION, HexCDReminder.BigWigsAvailable and "available" or "not detected"))
            print(string.format("|cFF00CCFF[HexCD Reminder]|r v%s loaded. Type |cFFFFCC00/hexcdr|r for commands.", VERSION))

            -- Check if we loaded mid-key (e.g. /reload while inside a Mythic+ dungeon).
            -- CHALLENGE_MODE_START won't re-fire after a reload, so we must bootstrap manually.
            if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
                local activeMapID = C_ChallengeMode.GetActiveChallengeMapID()
                if activeMapID and activeMapID > 0 then
                    Log:Log("INFO", string.format("HexCD: Detected active M+ key (mapID=%d) on load — bootstrapping MythicPlus state", activeMapID))
                    MP:OnChallengeModeStart()
                end
            end
        end

    elseif event == "ENCOUNTER_START" then
        local encounterID, encounterName, difficultyID, groupSize = ...
        encounterID = tonumber(encounterID) or 0
        difficultyID = tonumber(difficultyID) or 0

        Log:OnFightStart(encounterName, encounterID, difficultyID)

        Log:Log("INFO", string.format("ENCOUNTER_START: '%s' (id=%d, diff=%d, size=%d)",
            encounterName or "Unknown", encounterID, difficultyID, groupSize or 0))

        -- M+ boss handling: delegate to MythicPlusEngine if this boss belongs to a dungeon plan
        if MP.inMythicPlus and MP.dungeonPlan and MP:IsOurBoss(encounterID) then
            MP:OnBossStart(encounterID, encounterName, difficultyID)
            return
        end

        -- Raid plan lookup (difficulty-aware)
        local plan, planSource = Config:GetPlan(encounterID, difficultyID)
        if not plan then
            Log:Log("INFO", string.format("No CD plan for encounter %d (%s) diff=%d — addon idle",
                encounterID, encounterName or "Unknown", difficultyID))
            return
        end

        Log:Log("INFO", string.format("Plan found: encounter %d, source=%s, diff=%d, duration=%ds, %d healers, %d damage events",
            encounterID, planSource or "?", plan.difficulty or 0, plan.fightDurationSec or 0,
            plan.healerAssignments and #plan.healerAssignments or 0,
            plan.damageTimeline and #plan.damageTimeline or 0))

        -- Warn if plan difficulty doesn't match (fallback was used)
        if plan.difficulty and plan.difficulty ~= difficultyID then
            Log:Log("WARN", string.format("No plan for difficulty %d, using difficulty %d plan (timings may differ)",
                difficultyID, plan.difficulty))
            print(string.format("|cFFFFAA00[HexCD]|r No plan for difficulty %d, using d%d plan — timings may differ.",
                difficultyID, plan.difficulty))
        end

        Engine:Start(plan, encounterID)

    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...
        success = (tonumber(success) == 1)

        Log:Log("INFO", string.format("ENCOUNTER_END: '%s' (id=%d) — %s",
            encounterName or "Unknown", tonumber(encounterID) or 0, success and "KILL" or "WIPE"))

        -- M+ boss end: delegate to MythicPlusEngine
        if MP.activeBossEncounterID then
            MP:OnBossEnd(tonumber(encounterID) or 0, encounterName, difficultyID, groupSize, success)
            Log:OnFightEnd(success)
            if success then
                print("|cFF00FF00[HexCD]|r Boss down! Moving to next pull.")
            else
                print("|cFFFF6600[HexCD]|r Boss wipe. Resetting.")
            end
            return
        end

        -- Raid encounter end (existing flow)
        Engine:Stop()
        Log:OnFightEnd(success)

        if success then
            print("|cFF00FF00[HexCD]|r Fight ended — KILL! Log saved.")
        else
            print("|cFFFF6600[HexCD]|r Fight ended — Wipe. Log saved.")
        end
        -- Auto-open log after raid encounter for easy copy-paste
        if Config:Get("autoExportOnWipe") ~= false then
            C_Timer.After(2, function()
                Log:ShowFrame()
            end)
        end

    -- M+ key lifecycle events
    elseif event == "CHALLENGE_MODE_START" then
        MP:OnChallengeModeStart()

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        MP:OnChallengeModeEnd(true)  -- completed/timed
        -- Auto-open M+ session log after key completion
        if Config:Get("autoExportOnKeyEnd") ~= false then
            C_Timer.After(3, function()
                Log:ShowFrame("session")
                print("|cFF00CCFF[HexCD]|r M+ session log auto-opened. Copy with Ctrl+A → Ctrl+C, then paste to Claude for analysis.")
                print("|cFF00CCFF[HexCD]|r Disable with: /hexcd set autoExportOnKeyEnd false")
            end)
        end

    elseif event == "CHALLENGE_MODE_RESET" then
        MP:OnChallengeModeEnd(false) -- abandoned/reset

    -- Combat start/end for M+ trash detection
    elseif event == "PLAYER_REGEN_DISABLED" then
        Log:Log("INFO", string.format("PLAYER_REGEN_DISABLED: inMythicPlus=%s activeBossEncounterID=%s",
            tostring(MP.inMythicPlus), tostring(MP.activeBossEncounterID)))
        if MP.inMythicPlus and not MP.activeBossEncounterID then
            MP:OnCombatStart()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        Log:Log("INFO", string.format("PLAYER_REGEN_ENABLED: inMythicPlus=%s activeBossEncounterID=%s currentSection=%s",
            tostring(MP.inMythicPlus), tostring(MP.activeBossEncounterID), tostring(MP.currentSectionId)))
        if MP.inMythicPlus and not MP.activeBossEncounterID then
            MP:OnCombatEnd()
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        local unit = ...
        if unit == "player" then
            local cls, spec = Util.GetPlayerSpec()
            Log:Log("INFO", string.format("Spec changed: %s %s", Util.NormalizeClassName(cls), spec))
            -- Switch CooldownTracker and markers to new spec
            Util.SetSpecMarkers(cls, spec)
            if HexCDReminder.CooldownTracker then
                HexCDReminder.CooldownTracker:SetSpec(cls, spec)
            end
        end
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("ENCOUNTER_START")
eventFrame:RegisterEvent("ENCOUNTER_END")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
-- M+ events
eventFrame:RegisterEvent("CHALLENGE_MODE_START")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("CHALLENGE_MODE_RESET")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", OnEvent)

------------------------------------------------------------------------
-- M+ Plan Validator: static analysis of CD availability across sections
------------------------------------------------------------------------

--- Build KNOWN_CDS from CooldownTracker's active spec table.
--- Returns { [spellID] = baseCDsec } for plan validation.
local function GetKnownCDs()
    local tracker = HexCDReminder.CooldownTracker
    if not tracker then return {} end
    local tracked = tracker:GetTrackedCDs()
    local result = {}
    for spellID, info in pairs(tracked) do
        result[spellID] = info.cd
    end
    return result
end

--- Validate a dungeon CD plan by simulating CD usage across all sections.
--- Reports conflicts where a CD is assigned but won't be ready.
---@param plan table DungeonCDPlan
---@param gapBetweenPulls number seconds of downtime between pulls (default 10)
---@return table[] issues array of { section, assignment, conflict description }
local function ValidateDungeonPlan(plan, gapBetweenPulls)
    gapBetweenPulls = gapBetweenPulls or 10
    local issues = {}
    local warnings = {}
    local KNOWN_CDS = GetKnownCDs()

    -- Track when each CD becomes available (absolute key timeline)
    local cdReadyAt = {}  -- abilityGameID → absolute second when ready
    local absoluteTime = 0 -- running clock across all sections

    -- Match the player (same logic as BuildQueue)
    local playerClass, playerSpec = Util.GetPlayerSpec()
    playerClass = Util.NormalizeClassName(playerClass)
    local playerName = UnitName("player")

    for sectionIdx, section in ipairs(plan.sections) do
        local sectionStart = absoluteTime
        local sectionLabel = string.format("[%d] %s '%s'", sectionIdx, section.type, section.label or "?")

        -- Find matching assignments for this player
        local assignments = {}
        -- Dungeon plan sections have assignments directly
        if section.assignments then
            assignments = section.assignments
        end

        -- Check each assignment
        for _, assignment in ipairs(assignments) do
            local absTime = sectionStart + assignment.timeSec
            local spellID = assignment.abilityGameID

            -- Skip markers (ramp/cat weave for Druid) — they're not real CDs
            if not Util.IsMarkerSpell(spellID) then
                local baseCd = KNOWN_CDS[spellID]
                local readyAt = cdReadyAt[spellID] or 0

                if absTime < readyAt then
                    local deficit = readyAt - absTime
                    table.insert(issues, {
                        sectionIdx = sectionIdx,
                        sectionLabel = section.label or "?",
                        sectionType = section.type,
                        abilityName = assignment.abilityName,
                        spellID = spellID,
                        plannedAt = absTime,
                        readyAt = readyAt,
                        deficit = deficit,
                        sectionTime = assignment.timeSec,
                    })
                end

                -- Record when this CD will be available next (even if it conflicts,
                -- because defer logic will push it forward)
                if baseCd then
                    local castTime = math.max(absTime, readyAt) -- defer accounts for actual cast
                    cdReadyAt[spellID] = castTime + baseCd
                end
            end
        end

        -- Advance the absolute clock by section duration + gap
        absoluteTime = absoluteTime + (section.durationSec or 0) + gapBetweenPulls
    end

    return issues
end

--- Print validation results to chat
---@param plan table DungeonCDPlan
local function PrintValidation(plan)
    local issues = ValidateDungeonPlan(plan)

    print(string.format("|cFF00CCFF[HexCD]|r Validating: %s +%d (%d sections)",
        plan.dungeonName, plan.keyLevel or 0, #plan.sections))

    if #issues == 0 then
        print("|cFF00FF00[HexCD]|r ✓ No CD conflicts found! All CDs available when planned.")
        return
    end

    print(string.format("|cFFFF6600[HexCD]|r Found %d CD conflict(s):", #issues))
    for _, issue in ipairs(issues) do
        local severity = issue.deficit > 30 and "|cFFFF0000" or issue.deficit > 10 and "|cFFFF6600" or "|cFFFFCC00"
        print(string.format("  %s[%.0fs late]|r %s @ %s in %s '%s' (ready @ %s, %s into section)",
            severity,
            issue.deficit,
            issue.abilityName,
            Util.FormatTime(issue.plannedAt),
            issue.sectionType,
            issue.sectionLabel,
            Util.FormatTime(issue.readyAt),
            Util.FormatTime(issue.sectionTime)))
    end

    -- Summary by CD
    local byCd = {}
    for _, issue in ipairs(issues) do
        byCd[issue.abilityName] = (byCd[issue.abilityName] or 0) + 1
    end
    print("|cFF00CCFF[HexCD]|r Summary:")
    for name, count in pairs(byCd) do
        print(string.format("  %s: %d conflict(s)", name, count))
    end

    -- Log full details to debug log for export
    Log:Log("INFO", string.format("=== PLAN VALIDATION: %s +%d ===", plan.dungeonName, plan.keyLevel or 0))
    for _, issue in ipairs(issues) do
        Log:Log("INFO", string.format("CONFLICT: %s @ %s (key time) in '%s' — CD ready @ %s (%.0fs late)",
            issue.abilityName, Util.FormatTime(issue.plannedAt),
            issue.sectionLabel, Util.FormatTime(issue.readyAt), issue.deficit))
    end
end

------------------------------------------------------------------------
-- Slash Commands
------------------------------------------------------------------------
SLASH_HEXCDR1 = "/hexcdr"
SLASH_HEXCDR2 = "/hcdr"

SlashCmdList["HEXCDR"] = function(msg)
    local cmd, arg = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or msg):lower()

    if cmd == "" or cmd == "gui" or cmd == "show" then
        GUI:Toggle()
        return

    elseif cmd == "test" then
        -- Run test mode with a specific encounter or first available
        -- GetAllPlans() returns { eid → { diff → plan } }
        local encID = tonumber(arg)
        local allPlans = Config:GetAllPlans()
        local plan
        if encID and allPlans[encID] then
            -- Pick highest difficulty for this encounter
            local bestDiff = 0
            for diff, p in pairs(allPlans[encID]) do
                if type(diff) == "number" and diff > bestDiff then
                    plan, bestDiff = p, diff
                end
            end
        else
            -- First available plan (highest difficulty)
            for id, diffMap in pairs(allPlans) do
                encID = id
                for diff, p in pairs(diffMap) do
                    if type(diff) == "number" then plan = p; break end
                end
                if plan then break end
            end
        end
        if not plan then
            print("|cFFFF0000[HexCD]|r No plan found. Use /hexcd import or check /hexcd plans.")
            return
        end
        local speed = 10
        Log:OnFightStart("TEST MODE", encID, plan.difficulty or 4)
        Engine:RunTest(plan, speed, false)

    elseif cmd == "testbw" then
        -- Test mode WITH BigWigs drift simulation
        local encID = tonumber(arg)
        local allPlans = Config:GetAllPlans()
        local plan
        if encID and allPlans[encID] then
            local bestDiff = 0
            for diff, p in pairs(allPlans[encID]) do
                if type(diff) == "number" and diff > bestDiff then
                    plan, bestDiff = p, diff
                end
            end
        else
            for id, diffMap in pairs(allPlans) do
                encID = id
                for diff, p in pairs(diffMap) do
                    if type(diff) == "number" then plan = p; break end
                end
                if plan then break end
            end
        end
        if not plan then
            print("|cFFFF0000[HexCD]|r No plan found.")
            return
        end
        Log:OnFightStart("TEST+BW", encID, plan.difficulty or 4)
        Engine:RunTest(plan, 5, true)  -- slower speed so you can see drift adjustments
        print("|cFF00CCFF[HexCD]|r BigWigs drift test — watch debug log for drift adjustments.")
        print("|cFF00CCFF[HexCD]|r Each damage event fires ±8s from expected. CDs shift in real-time.")

    elseif cmd == "fakebw" then
        -- Manual fake BigWigs bar: /hexcd fakebw <spellID> <duration>
        local spellID, dur = arg:match("(%d+)%s+(%d+%.?%d*)")
        spellID = tonumber(spellID)
        dur = tonumber(dur)
        if not spellID or not dur then
            print("|cFFFF0000[HexCD]|r Usage: /hexcd fakebw <spellID> <duration>")
            print("|cFFFF0000[HexCD]|r   Simulates a BigWigs bar to test drift adjustment.")
            return
        end
        Engine:AdjustForBigWigsBar(spellID, "FakeBW " .. spellID, dur)
        print(string.format("|cFF00CCFF[HexCD]|r Fake BigWigs bar: spell %d, %.1fs duration", spellID, dur))

    elseif cmd == "log" then
        if arg == "export" then
            Log:ShowFrame()
            print("|cFF00CCFF[HexCD]|r Log frame opened. Click 'Select All' to copy.")
        else
            Log:ShowFrame()
        end

    elseif cmd == "exportkey" or cmd == "keylog" then
        -- Export full M+ session log for debugging
        if arg ~= "" and tonumber(arg) then
            Log:ShowFrame("session", tonumber(arg))
        else
            Log:ShowFrame("session")
        end
        print("|cFF00CCFF[HexCD]|r M+ session log opened. Click 'Select All' to copy, then paste to Claude.")

    elseif cmd == "keys" or cmd == "sessions" then
        -- List saved M+ session logs
        local sessions = Log:GetSavedSessions()
        if #sessions == 0 then
            print("|cFF00CCFF[HexCD]|r No saved M+ session logs. Complete a key first.")
        else
            print("|cFF00CCFF[HexCD]|r Saved M+ session logs:")
            for _, s in ipairs(sessions) do
                print(string.format("  [%d] %s +%d — %s — %s — %d entries",
                    s.index, s.dungeonName, s.keyLevel, s.date,
                    s.completed and "|cFF00FF00COMPLETED|r" or "|cFFFF6600ABANDONED|r",
                    s.entryCount))
            end
            print("|cFF00CCFF[HexCD]|r Use /hexcd exportkey <number> to view a specific session.")
        end

    elseif cmd == "import" then
        Import:ShowFrame()

    elseif cmd == "config" or cmd == "options" or cmd == "settings" then
        GUI:Open()

    elseif cmd == "lock" then
        Bars:Lock()

    elseif cmd == "unlock" or cmd == "move" then
        Bars:Unlock()

    elseif cmd == "lockramp" then
        Bars:LockRamp()

    elseif cmd == "unlockramp" or cmd == "moveramp" then
        Bars:UnlockRamp()

    elseif cmd == "lockwindow" then
        Bars:LockWindow()

    elseif cmd == "unlockwindow" or cmd == "movewindow" then
        Bars:UnlockWindow()

    elseif cmd == "reset" then
        Engine:Reset()
        Bars:HideAll()
        TTS:Stop()
        print("|cFF00CCFF[HexCD]|r Reset complete.")

    elseif cmd == "plans" then
        local totalCount = 0
        local DiffNames = { [3] = "Normal", [4] = "Heroic", [5] = "Mythic", [8] = "M+" }

        -- Raid plans (GetAllPlans returns { eid → { diff → plan } })
        local allPlans = Config:GetAllPlans()
        local raidCount = 0
        for _ in pairs(allPlans) do raidCount = raidCount + 1 end
        if raidCount > 0 then
            print("|cFF00CCFF[HexCD]|r |cFFFFCC00— Raid Plans —|r")
            for eid, diffMap in pairs(allPlans) do
                for diff, p in pairs(diffMap) do
                    if type(diff) == "number" then
                        totalCount = totalCount + 1
                        local totalCDs = 0
                        for _, h in ipairs(p.healerAssignments or {}) do
                            totalCDs = totalCDs + #(h.assignments or {})
                        end
                        local diffName = DiffNames[diff] or ("d" .. diff)
                        print(string.format("  Encounter %d (%s): %d healer specs, %d CDs, %ds fight",
                            eid, diffName, #(p.healerAssignments or {}), totalCDs, p.fightDurationSec or 0))
                    end
                end
            end
        end

        -- Dungeon (M+) plans
        local dungeonSources = {}
        if HexCDReminder.BundledDungeonPlans then
            for mapID, dp in pairs(HexCDReminder.BundledDungeonPlans) do
                dungeonSources[mapID] = { plan = dp, source = "bundled" }
            end
        end
        local savedDungeons = Config:Get("dungeonPlans") or {}
        for mapID, dp in pairs(savedDungeons) do
            dungeonSources[mapID] = { plan = dp, source = "imported" }
        end
        local dungeonCount = 0
        for _ in pairs(dungeonSources) do dungeonCount = dungeonCount + 1 end
        if dungeonCount > 0 then
            print("|cFF00CCFF[HexCD]|r |cFF00FF00— M+ Dungeon Plans —|r")
            for mapID, entry in pairs(dungeonSources) do
                totalCount = totalCount + 1
                local dp = entry.plan
                local totalCDs = 0
                for _, section in ipairs(dp.sections or {}) do
                    totalCDs = totalCDs + #(section.assignments or {})
                end
                local bossCount, trashCount = 0, 0
                for _, section in ipairs(dp.sections or {}) do
                    if section.type == "boss" then bossCount = bossCount + 1
                    else trashCount = trashCount + 1 end
                end
                print(string.format("  %s +%d: %d sections (%d boss, %d trash), %d CDs, %s %s (%s)",
                    dp.dungeonName or "?", dp.keyLevel or 0,
                    #(dp.sections or {}), bossCount, trashCount, totalCDs,
                    dp.playerName or dp.className or "?", dp.specName or "",
                    entry.source))
            end
        end

        if totalCount == 0 then
            print("|cFF00CCFF[HexCD]|r No plans loaded — use /hexcd import or bundle a PlanData.lua")
        end

    elseif cmd == "status" then
        local cls, spec = Util.GetPlayerSpec()
        cls = Util.NormalizeClassName(cls)
        print("|cFF00CCFF[HexCD]|r Status:")
        print(string.format("  Player: %s %s", cls, spec))
        print(string.format("  Timing mode: %s", Config:Get("timingMode")))
        print(string.format("  TTS: %s", Config:Get("ttsEnabled") and "ON" or "OFF"))
        print(string.format("  BigWigs: %s", HexCDReminder.BigWigsAvailable and "available" or "not detected"))
        local allPlans = Config:GetAllPlans()
        local planCount = 0
        for _, diffMap in pairs(allPlans) do
            for diff in pairs(diffMap) do
                if type(diff) == "number" then planCount = planCount + 1 end
            end
        end
        print(string.format("  Plans loaded: %d", planCount))
        local fightLogs = Config:Get("fightLogs") or {}
        print(string.format("  Saved fight logs: %d", #fightLogs))
        local tracker = HexCDReminder.CooldownTracker
        if tracker then
            print(string.format("  CD tracking: %s",
                tracker:IsEventTracking() and "|cFF00FF00auto (UNIT_SPELLCAST_SUCCEEDED)|r"
                or "|cFFFFCC00waiting for first cast — use /hexcd macros for fallback|r"))
        end

    elseif cmd == "clearplans" then
        Config:Set("plans", {})
        print("|cFF00CCFF[HexCD]|r All imported plans cleared. Bundled plans from PlanData.lua are still available.")

    elseif cmd == "dump" or cmd == "status2" then
        -- Dump current queue state to debug log
        Engine:DumpStatus()

    elseif cmd == "cds" then
        -- Show CD tracker state
        local tracker = HexCDReminder.CooldownTracker
        if tracker then
            tracker:DumpState()
            print("|cFF00CCFF[HexCD]|r CD tracker state dumped to debug log. Use /hexcd log to view.")
        end

    elseif cmd == "macros" then
        -- Print macro text for CD tracking fallback
        local tracker = HexCDReminder.CooldownTracker
        if tracker then
            tracker:PrintMacros()
        end

    elseif cmd == "announce" then
        local current = Config:Get("announceEnabled")
        if current == nil then current = true end
        Config:Set("announceEnabled", not current)
        if not current then
            print("|cFF00CCFF[HexCD]|r Spell announce in /say: |cFF00FF00ON|r")
        else
            print("|cFF00CCFF[HexCD]|r Spell announce in /say: |cFFFF0000OFF|r")
        end

    elseif cmd == "validate" or cmd == "check" then
        -- Static validation of M+ dungeon plan CD availability
        local mapID = tonumber(arg)
        if mapID then
            local plan = Config:GetDungeonPlan(mapID)
            if plan then
                PrintValidation(plan)
            else
                print(string.format("|cFFFF0000[HexCD]|r No dungeon plan for mapID %d", mapID))
            end
        else
            -- Validate all loaded dungeon plans
            local anyPlan = false
            local dungeonSources = {}
            if HexCDReminder.BundledDungeonPlans then
                for mid, dp in pairs(HexCDReminder.BundledDungeonPlans) do
                    dungeonSources[mid] = dp
                end
            end
            local saved = Config:Get("dungeonPlans") or {}
            for mid, dp in pairs(saved) do
                dungeonSources[mid] = dp
            end
            for _, dp in pairs(dungeonSources) do
                anyPlan = true
                PrintValidation(dp)
                print("") -- spacing between plans
            end
            if not anyPlan then
                print("|cFF00CCFF[HexCD]|r No dungeon plans loaded. Use /hexcd validate <mapID> or load plans first.")
            end
        end

    elseif cmd == "debug" then
        local level = arg:upper()
        if level == "OFF" or level == "ERRORS" or level == "INFO" or level == "DEBUG" or level == "TRACE" then
            Config:Set("logLevel", level)
            print("|cFF00CCFF[HexCD Reminder]|r Log level set to: " .. level)
        else
            print("|cFF00CCFF[HexCD Reminder]|r Valid levels: OFF, ERRORS, INFO, DEBUG, TRACE")
        end

    else
        -- Unknown command — open GUI
        GUI:Toggle()
    end
end
