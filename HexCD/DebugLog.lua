------------------------------------------------------------------------
-- HexCD: Debug Logging System
-- Ring buffer with scrollable frame and auto-save on fight end
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.DebugLog = {}

local Log = HexCD.DebugLog

local LOG_LEVELS = { OFF = 0, ERRORS = 1, INFO = 2, DEBUG = 3, TRACE = 4 }
local MAX_ENTRIES = 2000
local MAX_SAVED_FIGHTS = 50

-- Ring buffer state (per-fight, wiped on boss start)
local entries = {}
local entryCount = 0
local fightStartTime = nil
local currentFightInfo = nil

-- M+ session log: accumulates ALL entries across the entire key (trash + bosses)
-- Never wiped until key ends. This is what you export for debugging.
local sessionEntries = {}
local sessionEntryCount = 0
local sessionStartTime = nil
local sessionInfo = nil    -- { dungeonName, mapID, keyLevel, startTime }

--- Initialize (called from Config after SavedVariables load)
function Log:Init()
    entries = {}
    entryCount = 0
end

--- Get numeric log level from config string
---@return number
local function getLogLevel()
    local cfg = HexCDDB and HexCDDB.logLevel or "INFO"
    return LOG_LEVELS[cfg] or LOG_LEVELS.INFO
end

--- Log a message at the given level
---@param level string "ERRORS"|"INFO"|"DEBUG"|"TRACE"
---@param msg string
function Log:Log(level, msg)
    -- Guard: reject secret/tainted values to prevent export crashes
    if issecretvalue and (issecretvalue(msg) or issecretvalue(level)) then return end
    local numLevel = LOG_LEVELS[level] or 0
    if numLevel > getLogLevel() then return end

    entryCount = entryCount + 1
    local now = GetTime()
    local fightRel = fightStartTime and (now - fightStartTime) or nil

    local entry = {
        level = level,
        timestamp = now,
        fightRelativeSec = fightRel,
        message = msg,
    }

    -- Ring buffer: overwrite oldest if full
    local idx = ((entryCount - 1) % MAX_ENTRIES) + 1
    entries[idx] = entry

    -- Also append to M+ session log if active
    if sessionStartTime then
        sessionEntryCount = sessionEntryCount + 1
        local sessionIdx = ((sessionEntryCount - 1) % MAX_ENTRIES) + 1
        sessionEntries[sessionIdx] = {
            level = level,
            timestamp = now,
            sessionRelativeSec = now - sessionStartTime,
            message = msg,
        }
    end

    -- Also print to chat if DEBUG or TRACE.
    -- WoW's default chat font (FrizQuadrataTT) doesn't render a handful of
    -- non-ASCII glyphs we use in log messages — em-dash and arrows render as
    -- boxes. Player names with Latin-Extended (ä, ê) are fine.
    if numLevel >= LOG_LEVELS.DEBUG then
        local prefix = "|cFF00CCFF[HexCD]|r "
        local timeStr = fightRel and string.format("[%.1fs] ", fightRel) or ""
        local chatMsg = msg
            :gsub("\226\128\148", "-")  -- em-dash U+2014
            :gsub("\226\134\146", "->") -- right arrow U+2192
        DEFAULT_CHAT_FRAME:AddMessage(prefix .. timeStr .. level .. ": " .. chatMsg)
    end
end

--- Mark fight start for relative timestamps
---@param encounterName string
---@param encounterID number
---@param difficultyID number
function Log:OnFightStart(encounterName, encounterID, difficultyID)
    fightStartTime = GetTime()
    currentFightInfo = {
        encounter = encounterName,
        encounterID = encounterID,
        difficulty = difficultyID,
        startTime = fightStartTime,
    }
    -- Clear entries for fresh fight log
    entries = {}
    entryCount = 0
    self:Log("INFO", string.format("=== Fight Start: %s (ID %d, diff %d) ===",
        encounterName or "Unknown", encounterID or 0, difficultyID or 0))
end

--- Mark fight end, auto-save to SavedVariables
---@param success boolean
function Log:OnFightEnd(success)
    local duration = fightStartTime and (GetTime() - fightStartTime) or 0
    self:Log("INFO", string.format("=== Fight End: %s (%.0fs) ===",
        success and "KILL" or "WIPE", duration))

    -- Auto-save fight log
    if currentFightInfo and HexCDDB then
        HexCDDB.fightLogs = HexCDDB.fightLogs or {}

        local savedEntries = {}
        for i = 1, math.min(entryCount, MAX_ENTRIES) do
            local idx = ((i - 1) % MAX_ENTRIES) + 1
            if entries[idx] then
                table.insert(savedEntries, {
                    level = entries[idx].level,
                    fightRelativeSec = entries[idx].fightRelativeSec,
                    message = entries[idx].message,
                })
            end
        end

        -- Save BigWigs ability timeline if available (for anchor analysis)
        local savedTimeline = nil
        local savedFireCounts = nil
        if HexCD.GetAbilityTimeline then
            local timeline = HexCD.GetAbilityTimeline()
            if timeline and #timeline > 0 then
                savedTimeline = {}
                for _, e in ipairs(timeline) do
                    table.insert(savedTimeline, {
                        fightSec  = e.fightSec,
                        landSec   = e.landSec,
                        spellID   = e.spellID,
                        text      = e.text,
                        duration  = e.duration,
                        fireCount = e.fireCount,
                        matchType = e.matchType,
                    })
                end
            end
        end
        if HexCD.GetSpellFireCounts then
            local counts = HexCD.GetSpellFireCounts()
            if counts then
                savedFireCounts = {}
                for spellID, count in pairs(counts) do
                    savedFireCounts[tostring(spellID)] = count
                end
            end
        end

        local fightLog = {
            encounter = currentFightInfo.encounter,
            encounterID = currentFightInfo.encounterID,
            difficulty = currentFightInfo.difficulty,
            kill = success,
            duration = duration,
            date = date("%Y-%m-%d %H:%M:%S"),
            entryCount = #savedEntries,
            entries = savedEntries,
            abilityTimeline = savedTimeline,
            spellFireCounts = savedFireCounts,
        }

        table.insert(HexCDDB.fightLogs, fightLog)

        -- Keep only last N fights
        while #HexCDDB.fightLogs > MAX_SAVED_FIGHTS do
            table.remove(HexCDDB.fightLogs, 1)
        end

        self:Log("INFO", string.format("Fight log auto-saved (%d entries, %d total saved fights)",
            #savedEntries, #HexCDDB.fightLogs))
    end

    fightStartTime = nil
    currentFightInfo = nil
end

------------------------------------------------------------------------
-- M+ Session Log Lifecycle
------------------------------------------------------------------------

--- Start a new M+ session log (called on CHALLENGE_MODE_START)
---@param dungeonName string
---@param mapID number
---@param keyLevel number
function Log:OnSessionStart(dungeonName, mapID, keyLevel)
    sessionEntries = {}
    sessionEntryCount = 0
    sessionStartTime = GetTime()
    sessionInfo = {
        dungeonName = dungeonName or "Unknown",
        mapID = mapID or 0,
        keyLevel = keyLevel or 0,
        startTime = sessionStartTime,
        date = date("%Y-%m-%d %H:%M:%S"),
    }
    self:Log("INFO", string.format("=== M+ SESSION START: %s +%d (mapID=%d) ===",
        dungeonName or "Unknown", keyLevel or 0, mapID or 0))
end

--- End the M+ session log, auto-save to SavedVariables
---@param completed boolean true if timed/completed, false if abandoned/reset
--- Test helper: expose current session info for assertions.
function Log:_testGetSessionInfo()
    return sessionInfo
end

function Log:OnSessionEnd(completed)
    if not sessionInfo then return end

    local duration = sessionStartTime and (GetTime() - sessionStartTime) or 0
    local result = completed and "COMPLETED" or "ABANDONED"
    self:Log("INFO", string.format("=== M+ SESSION END: %s (%s, %.0fs) ===",
        result, HexCD.Util.FormatTime(duration), duration))

    -- Save full session log to SavedVariables
    if HexCDDB then
        HexCDDB.sessionLogs = HexCDDB.sessionLogs or {}

        local savedEntries = {}
        local total = math.min(sessionEntryCount, MAX_ENTRIES)
        for i = 1, total do
            local idx
            if sessionEntryCount <= MAX_ENTRIES then
                idx = i
            else
                idx = ((sessionEntryCount - MAX_ENTRIES + i - 1) % MAX_ENTRIES) + 1
            end
            if sessionEntries[idx] then
                table.insert(savedEntries, {
                    level = sessionEntries[idx].level,
                    sessionRelativeSec = sessionEntries[idx].sessionRelativeSec,
                    message = sessionEntries[idx].message,
                })
            end
        end

        local sessionLog = {
            dungeonName = sessionInfo.dungeonName,
            mapID = sessionInfo.mapID,
            keyLevel = sessionInfo.keyLevel,
            completed = completed,
            duration = duration,
            date = sessionInfo.date,
            entryCount = #savedEntries,
            entries = savedEntries,
        }

        table.insert(HexCDDB.sessionLogs, sessionLog)

        -- Keep only last 10 session logs (keys are long, entries are big)
        while #HexCDDB.sessionLogs > 10 do
            table.remove(HexCDDB.sessionLogs, 1)
        end

        self:Log("INFO", string.format("M+ session log saved (%d entries, %d total sessions)",
            #savedEntries, #HexCDDB.sessionLogs))
    end

    -- Reset session state
    sessionEntries = {}
    sessionEntryCount = 0
    sessionStartTime = nil
    sessionInfo = nil
end

--- Check if a M+ session is active
---@return boolean
function Log:IsSessionActive()
    return sessionStartTime ~= nil
end

--- Get ordered session entries (oldest first)
---@return table[]
function Log:GetSessionEntries()
    local result = {}
    local total = math.min(sessionEntryCount, MAX_ENTRIES)
    for i = 1, total do
        local idx
        if sessionEntryCount <= MAX_ENTRIES then
            idx = i
        else
            idx = ((sessionEntryCount - MAX_ENTRIES + i - 1) % MAX_ENTRIES) + 1
        end
        if sessionEntries[idx] then
            table.insert(result, sessionEntries[idx])
        end
    end
    return result
end

--- Export session log as a formatted string for copy-paste
---@return string
function Log:ExportSession()
    if not sessionInfo and (not HexCDDB or not HexCDDB.sessionLogs or #HexCDDB.sessionLogs == 0) then
        return "No M+ session log available. Run a key first."
    end

    -- If session is active, export current live entries
    if sessionInfo then
        local lines = {}
        local duration = GetTime() - sessionStartTime
        table.insert(lines, string.format("=== HexCD M+ Session Log ==="))
        table.insert(lines, string.format("Dungeon: %s +%d (mapID=%d)",
            sessionInfo.dungeonName, sessionInfo.keyLevel, sessionInfo.mapID))
        table.insert(lines, string.format("Date: %s", sessionInfo.date))
        table.insert(lines, string.format("Duration: %s (IN PROGRESS)", HexCD.Util.FormatTime(duration)))
        table.insert(lines, "")

        local allEntries = self:GetSessionEntries()
        for _, e in ipairs(allEntries) do
            -- Sanitize: secret values can leak into log messages via BigWigs bar callbacks.
            -- Wrap in pcall to skip entries that contain untouchable secret strings.
            local ok, line = pcall(function()
                local timeStr = e.sessionRelativeSec
                    and string.format("[%s]", HexCD.Util.FormatTime(e.sessionRelativeSec))
                    or "[--:--]"
                return string.format("%s %s: %s", timeStr, e.level, e.message)
            end)
            if ok then
                table.insert(lines, line)
            else
                table.insert(lines, "[??:??] INFO: <entry contained secret value — skipped>")
            end
        end
        return table.concat(lines, "\n")
    end

    -- Otherwise export the most recent saved session
    local log = HexCDDB.sessionLogs[#HexCDDB.sessionLogs]
    local lines = {}
    table.insert(lines, string.format("=== HexCD M+ Session Log ==="))
    table.insert(lines, string.format("Dungeon: %s +%d (mapID=%d)",
        log.dungeonName, log.keyLevel, log.mapID))
    table.insert(lines, string.format("Date: %s", log.date))
    table.insert(lines, string.format("Duration: %s | Result: %s",
        HexCD.Util.FormatTime(log.duration), log.completed and "COMPLETED" or "ABANDONED"))
    table.insert(lines, string.format("Entries: %d", log.entryCount))
    table.insert(lines, "")

    for _, e in ipairs(log.entries) do
        local ok, line = pcall(function()
            local timeStr = e.sessionRelativeSec
                and string.format("[%s]", HexCD.Util.FormatTime(e.sessionRelativeSec))
                or "[--:--]"
            return string.format("%s %s: %s", timeStr, e.level, e.message)
        end)
        if ok then
            table.insert(lines, line)
        else
            table.insert(lines, "[??:??] INFO: <entry contained secret value — skipped>")
        end
    end
    return table.concat(lines, "\n")
end

--- Get list of saved session logs (for UI display)
---@return table[] array of { dungeonName, keyLevel, date, completed, duration, entryCount }
function Log:GetSavedSessions()
    if not HexCDDB or not HexCDDB.sessionLogs then return {} end
    local result = {}
    for i, log in ipairs(HexCDDB.sessionLogs) do
        table.insert(result, {
            index = i,
            dungeonName = log.dungeonName,
            keyLevel = log.keyLevel,
            date = log.date,
            completed = log.completed,
            duration = log.duration,
            entryCount = log.entryCount,
        })
    end
    return result
end

--- Export a specific saved session by index
---@param index number
---@return string
function Log:ExportSavedSession(index)
    if not HexCDDB or not HexCDDB.sessionLogs then return "No saved sessions." end
    local log = HexCDDB.sessionLogs[index]
    if not log then return string.format("Session %d not found.", index) end

    local lines = {}
    table.insert(lines, string.format("=== HexCD M+ Session Log ==="))
    table.insert(lines, string.format("Dungeon: %s +%d (mapID=%d)",
        log.dungeonName, log.keyLevel, log.mapID))
    table.insert(lines, string.format("Date: %s", log.date))
    table.insert(lines, string.format("Duration: %s | Result: %s",
        HexCD.Util.FormatTime(log.duration), log.completed and "COMPLETED" or "ABANDONED"))
    table.insert(lines, string.format("Entries: %d", log.entryCount))
    table.insert(lines, "")

    for _, e in ipairs(log.entries) do
        local ok, line = pcall(function()
            local timeStr = e.sessionRelativeSec
                and string.format("[%s]", HexCD.Util.FormatTime(e.sessionRelativeSec))
                or "[--:--]"
            return string.format("%s %s: %s", timeStr, e.level, e.message)
        end)
        if ok then
            table.insert(lines, line)
        else
            table.insert(lines, "[??:??] INFO: <entry contained secret value — skipped>")
        end
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Per-Fight Log (existing)
------------------------------------------------------------------------

--- Get all current entries as ordered array (oldest first)
---@return table[]
function Log:GetEntries()
    local result = {}
    local total = math.min(entryCount, MAX_ENTRIES)
    for i = 1, total do
        local idx
        if entryCount <= MAX_ENTRIES then
            idx = i
        else
            idx = ((entryCount - MAX_ENTRIES + i - 1) % MAX_ENTRIES) + 1
        end
        if entries[idx] then
            table.insert(result, entries[idx])
        end
    end
    return result
end

--- Format all entries as a single string for export
---@return string
function Log:Export()
    local lines = {}
    local allEntries = self:GetEntries()
    for _, e in ipairs(allEntries) do
        -- Skip entries with secret/tainted values (Midnight taint can leak into log messages)
        if issecretvalue and (issecretvalue(e.message) or issecretvalue(e.level)) then
            table.insert(lines, "[--:--] DEBUG: (secret value — skipped)")
        else
            local timeStr = e.fightRelativeSec
                and string.format("[%s]", HexCD.Util.FormatTime(e.fightRelativeSec))
                or "[--:--]"
            table.insert(lines, string.format("%s %s: %s", timeStr, e.level, e.message))
        end
    end
    return table.concat(lines, "\n")
end

------------------------------------------------------------------------
-- Scrollable Log Frame
------------------------------------------------------------------------
local logFrame = nil

local function CreateLogFrame()
    local f = CreateFrame("Frame", "HexCDTrackerLogFrame", UIParent, "BackdropTemplate")
    f:SetSize(700, 450)
    f:SetPoint("CENTER", -360, 0)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0.0, 0.02, 0.08, 0.95)
    f:SetBackdropBorderColor(0.3, 0.5, 0.8, 0.8)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")

    -- Title (blue tint — tracker/CD log)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("|cFF4488CCHexCD|r |cFFAAAAAATracker Log|r")

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", "HexCDLogScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -35)
    scroll:SetPoint("BOTTOMRIGHT", -30, 45)

    local editBox = CreateFrame("EditBox", "HexCDLogEditBox", scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(false)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(650)
    editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    scroll:SetScrollChild(editBox)

    -- Export button
    local exportBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    exportBtn:SetSize(120, 24)
    exportBtn:SetPoint("BOTTOMLEFT", 12, 12)
    exportBtn:SetText("Select All")
    exportBtn:SetScript("OnClick", function()
        editBox:HighlightText()
        editBox:SetFocus()
    end)

    -- Refresh button
    local refreshBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    refreshBtn:SetSize(120, 24)
    refreshBtn:SetPoint("BOTTOM", 0, 12)
    refreshBtn:SetText("Refresh")
    refreshBtn:SetScript("OnClick", function()
        editBox:SetText(Log:Export())
    end)

    f.editBox = editBox
    return f
end

--- Show the log viewer frame
---@param mode string|nil "session" for M+ session log, nil for current fight log
---@param sessionIndex number|nil specific saved session to show (only for mode="session")
function Log:ShowFrame(mode, sessionIndex)
    if not logFrame then
        logFrame = CreateLogFrame()
    end
    if mode == "session" then
        if sessionIndex then
            logFrame.editBox:SetText(self:ExportSavedSession(sessionIndex))
        else
            logFrame.editBox:SetText(self:ExportSession())
        end
    else
        logFrame.editBox:SetText(self:Export())
    end
    logFrame:Show()
end

--- Hide the log viewer frame
function Log:HideFrame()
    if logFrame then logFrame:Hide() end
end
