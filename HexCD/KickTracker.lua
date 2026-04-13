------------------------------------------------------------------------
-- HexCD: Kick Tracker
-- Shows an interrupt rotation overlay during combat.
-- Supports 2 independent rotation groups for raid use.
--
-- States: HIDDEN (out of combat) → ACTIVE (in combat with rotation set)
--
-- === 4-Layer Kick Detection Architecture ===
--
-- Layer 1: OWN CAST (0ms latency, no addon required)
--   UNIT_SPELLCAST_SUCCEEDED "player" → spellID is clean for self
--   → SafeGetKickData(spellID) → HandleKickByName(source="self")
--   → BroadcastKickCast() to group via SendAddonMessage
--
-- Layer 3: CORRELATION (30ms latency, no addon required on other player)
--   In Midnight 12.0, UNIT_SPELLCAST_SUCCEEDED fires for party members
--   but spellID is a "secret value" (can't read/compare it).
--   UNIT_SPELLCAST_INTERRUPTED fires on nameplates when a mob cast is kicked.
--   We correlate the two by timestamp within a 50ms window:
--     party1 casts *something* at T=100.003
--     nameplate3's cast interrupted at T=100.020
--     diff = 17ms < 50ms window → party1 kicked nameplate3
--   Works even if the other player doesn't have HexCD!
--   (Technique from InterruptTracker by josh-the-dev)
--
-- Layer 4: ADDON MESSAGE (100-500ms latency, requires HexCD on other player)
--   Other HexCD clients broadcast KICK1:Name:spellID via SendAddonMessage.
--   Received via CHAT_MSG_ADDON → HandleKickByName(source="addon")
--   Serves as backup when correlation fails (no nameplate visible, etc.)
--
-- Dedup: All layers route through HandleKickByName() which has a 2-second
-- dedup window per player. If a kick was already recorded for that player
-- within 2s, subsequent detections are silently dropped. Typical flow:
-- Layer 1 (0ms) or Layer 3 (~30ms) records the kick first, then Layer 4
-- (~300ms) arrives and is deduped.
--
-- False positive risk: Layer 3 can't verify the spell was an interrupt
-- (spellID is secret). If a party member casts a regular spell within 50ms
-- of a mob cast being interrupted by someone else, it could false-match.
-- The 50ms window makes this extremely unlikely in practice.
--
-- Taint Laundering: SafeGetKickData() uses a StatusBar SetValue trick to
-- strip Midnight's "secret value" wrapper from spellIDs, allowing direct
-- lookup in the KICK_SPELL_IDS table even for party member casts.
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.KickTracker = {}

local KT = HexCD.KickTracker
local Config = HexCD.Config
local Log = HexCD.DebugLog
local Util = HexCD.Util

-- Forward declaration (defined later, called from _correlRoute)
local HandleKickByName

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

-- KICK_SPELLS: class → { default={}, specs={[specID]={}} }
--   default : used when spec is unknown or not listed in specs
--   specs   : spec-specific override. Map to `false` for specs that have
--             NO baseline interrupt (e.g. Resto Druid, Disc/Holy Priest).
-- The structure is needed because some classes have spec-differentiated
-- interrupts (Balance Druid's Solar Beam vs Feral's Skull Bash, Survival
-- Hunter's Muzzle vs the rest's Counter Shot).
local KICK_SPELLS = {
    ["Death Knight"] = { default = { spellID = 47528,  name = "Mind Freeze",       cd = 15 } },
    ["Demon Hunter"] = { default = { spellID = 183752, name = "Disrupt",           cd = 15 } },
    ["Druid"] = {
        default = { spellID = 106839, name = "Skull Bash", cd = 15 }, -- fallback
        specs = {
            [102] = { spellID = 78675,  name = "Solar Beam", cd = 60 }, -- Balance
            [103] = { spellID = 106839, name = "Skull Bash", cd = 15 }, -- Feral
            [104] = { spellID = 106839, name = "Skull Bash", cd = 15 }, -- Guardian
            [105] = false,                                              -- Resto: no baseline kick
        },
    },
    ["Evoker"]  = { default = { spellID = 351338, name = "Quell",             cd = 40 } },
    ["Hunter"]  = {
        default = { spellID = 147362, name = "Counter Shot", cd = 24 },
        specs = {
            [253] = { spellID = 147362, name = "Counter Shot", cd = 24 }, -- BM
            [254] = { spellID = 147362, name = "Counter Shot", cd = 24 }, -- MM
            [255] = { spellID = 187707, name = "Muzzle",       cd = 15 }, -- Survival (melee)
        },
    },
    ["Mage"]    = { default = { spellID = 2139,   name = "Counterspell",      cd = 24 } },
    ["Monk"]    = { default = { spellID = 116705, name = "Spear Hand Strike", cd = 15 } },
    ["Paladin"] = {
        default = { spellID = 96231, name = "Rebuke", cd = 15 },
        specs = {
            [65] = false,                                          -- Holy: no baseline kick
            [66] = { spellID = 96231, name = "Rebuke", cd = 15 },  -- Prot
            [70] = { spellID = 96231, name = "Rebuke", cd = 15 },  -- Ret
        },
    },
    ["Priest"] = {
        default = { spellID = 15487, name = "Silence", cd = 45 },
        specs = {
            [256] = false,                                         -- Disc: no baseline kick
            [257] = false,                                         -- Holy: no baseline kick
            [258] = { spellID = 15487, name = "Silence", cd = 45 },-- Shadow
        },
    },
    ["Rogue"]   = { default = { spellID = 1766,   name = "Kick",              cd = 15 } },
    ["Shaman"]  = { default = { spellID = 57994,  name = "Wind Shear",        cd = 12 } },
    ["Warlock"] = {
        -- Affliction/Destruction run Felhunter → Spell Lock 24s.
        -- Demonology runs Felguard → Axe Toss 30s.
        default = { spellID = 119910, name = "Spell Lock", cd = 24 },
        specs = {
            [265] = { spellID = 119910, name = "Spell Lock", cd = 24 }, -- Affliction
            [266] = { spellID = 89766,  name = "Axe Toss",   cd = 30 }, -- Demonology
            [267] = { spellID = 119910, name = "Spell Lock", cd = 24 }, -- Destruction
        },
    },
    ["Warrior"] = { default = { spellID = 6552,   name = "Pummel",            cd = 15 } },
}

-- Resolve a class/spec pair to its primary kick entry (or nil if the spec
-- has no baseline interrupt). Falls back to `default` when specID is
-- unknown or not listed in the class's specs table.
local function ResolveKickSpell(classKey, specID)
    local entry = KICK_SPELLS[classKey]
    if not entry then return nil end
    if specID and entry.specs ~= nil then
        local override = entry.specs[specID]
        if override == false then return nil end  -- explicit "no kick"
        if override ~= nil then return override end
    end
    return entry.default
end

-- Secondary interrupts (long CD) — tracked if used but not the primary rotation spell
local KICK_SPELLS_SECONDARY = {
    [78675]  = { class = "Druid",   name = "Solar Beam",        cd = 60 },
    [187707] = { class = "Hunter",  name = "Muzzle",            cd = 15 },
    [386071] = { class = "Warrior", name = "Disrupting Shout",  cd = 90 },
}

-- Reverse lookup: spellID → { class, name, cd }. Indexes the default
-- + every spec variant + secondaries so a cast on any of them resolves.
local KICK_SPELL_IDS = {}
for class, entry in pairs(KICK_SPELLS) do
    if entry.default then
        KICK_SPELL_IDS[entry.default.spellID] = { class = class, name = entry.default.name, cd = entry.default.cd }
    end
    if entry.specs then
        for _, v in pairs(entry.specs) do
            if v and v.spellID and not KICK_SPELL_IDS[v.spellID] then
                KICK_SPELL_IDS[v.spellID] = { class = class, name = v.name, cd = v.cd }
            end
        end
    end
end
for spellID, info in pairs(KICK_SPELLS_SECONDARY) do
    KICK_SPELL_IDS[spellID] = info
end

--- Strip realm suffix from a player name ("Name-Realm" → "Name")
local function StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

local BAR_POOL_SIZE = 6
local ALERT_DEBOUNCE_SEC = 2
local UPDATE_THROTTLE = 0.2
local ADDON_MSG_PREFIX = "HexCD"
local commsRegistered = false

------------------------------------------------------------------------
-- Taint laundering (from InterruptTracker by josh-the-dev)
-- UNIT_SPELLCAST_SUCCEEDED spellID for party members is a "secret value"
-- in Midnight 12.0. Passing it through a StatusBar's SetValue causes C++
-- to re-emit a clean value via OnValueChanged.
------------------------------------------------------------------------
local launderBar = CreateFrame("StatusBar")
launderBar:SetMinMaxValues(0, 9999999)
local _launderedID = nil
launderBar:SetScript("OnValueChanged", function(_, v) _launderedID = v end)

local function SafeGetKickData(spellID)
    -- Try direct lookup first (pcall guards tainted key access)
    local ok, data = pcall(function() return KICK_SPELL_IDS[spellID] end)
    if ok and data then return data, spellID end
    -- Launder through StatusBar to strip taint
    _launderedID = nil
    launderBar:SetValue(0)
    pcall(launderBar.SetValue, launderBar, spellID)
    local cleanID = _launderedID
    if cleanID then
        local ok2, data2 = pcall(function() return KICK_SPELL_IDS[cleanID] end)
        if ok2 and data2 then return data2, cleanID end
    end
    return nil, nil
end

------------------------------------------------------------------------
-- Correlation-based party interrupt detection (from InterruptTracker)
-- UNIT_SPELLCAST_SUCCEEDED fires for party members but spellID is tainted.
-- UNIT_SPELLCAST_INTERRUPTED fires on nameplates when a mob cast is kicked.
-- Match the two by timestamp within 50ms to determine who kicked.
-- Works even if the other player doesn't have HexCD!
------------------------------------------------------------------------
local pendingCasts = {}       -- [unit] = GetTime()
local pendingInterrupts = {}  -- [nameplateUnit] = GetTime()
local correlPending = false
local CORREL_WINDOW = 0.200   -- 200ms match window (50ms was too tight in practice)

local function ProcessCorrelation()
    correlPending = false

    -- Count interrupt events
    local interruptCount, targetUnit = 0, nil
    for unit in pairs(pendingInterrupts) do
        interruptCount = interruptCount + 1
        targetUnit = unit
    end

    local castCount = 0
    for _ in pairs(pendingCasts) do castCount = castCount + 1 end

    if interruptCount == 0 then
        wipe(pendingCasts)
        return
    end

    Log:Log("DEBUG", string.format("KickCorrel: processing — %d casts, %d interrupts", castCount, interruptCount))

    -- Multiple simultaneous interrupts = AoE CC, not a kick
    if interruptCount > 1 then
        Log:Log("DEBUG", string.format("KickCorrel: %d simultaneous interrupts — AoE CC, skipping", interruptCount))
        wipe(pendingInterrupts)
        wipe(pendingCasts)
        return
    end

    local interruptTime = pendingInterrupts[targetUnit]

    -- Find the party member whose cast timestamp is closest
    local bestUnit, bestDiff = nil, math.huge
    for unit, castTime in pairs(pendingCasts) do
        local diff = math.abs(interruptTime - castTime)
        Log:Log("DEBUG", string.format("KickCorrel: checking %s diff=%.3fs (window=%.3f)", unit, diff, CORREL_WINDOW))
        if diff <= CORREL_WINDOW and diff < bestDiff then
            bestUnit, bestDiff = unit, diff
        end
    end

    if bestUnit then
        local ok, name = pcall(UnitName, bestUnit)
        if ok and name then
            local shortName = StripRealm(name)
            Log:Log("INFO", string.format("KickCorrel: matched %s (unit=%s, diff=%.3fs)", shortName, bestUnit, bestDiff))

            -- Clear immediately to prevent re-matching on subsequent ProcessCorrelation calls
            wipe(pendingInterrupts)
            wipe(pendingCasts)

            -- Route via KT module function (groups is defined later in file,
            -- but KT:_correlRoute is set after groups exists)
            if KT._correlRoute then
                KT:_correlRoute(shortName, bestUnit)
            else
                Log:Log("DEBUG", "KickCorrel: routing deferred (groups not yet initialized)")
            end
        end
        return  -- Already cleaned up
    else
        Log:Log("DEBUG", "KickCorrel: no cast matched within time window")
    end

    wipe(pendingInterrupts)
    wipe(pendingCasts)
end

local correlFrame = CreateFrame("Frame")
correlFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
correlFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
correlFrame:SetScript("OnEvent", function(_, event, unit)
    if not Config:Get("kickEnabled") then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- Skip player, pets, and non-party units
        if unit == "player" or unit == "pet" then return end
        if unit:find("pet") then return end  -- partypet1, raidpet3, etc.
        if not unit:find("^party") and not unit:find("^raid") then return end
        pendingCasts[unit] = GetTime()
        Log:Log("TRACE", string.format("KickCorrel: CAST from %s at %.3f", unit, GetTime()))
        if not correlPending then
            correlPending = true
            C_Timer.After(0.03, ProcessCorrelation)
        end

    elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
        -- Only care about nameplate units (mob cast was interrupted)
        if not unit:find("^nameplate") then return end
        pendingInterrupts[unit] = GetTime()
        Log:Log("TRACE", string.format("KickCorrel: INTERRUPT on %s at %.3f", unit, GetTime()))
        if not correlPending then
            correlPending = true
            C_Timer.After(0.03, ProcessCorrelation)
        end
    end
end)

------------------------------------------------------------------------
-- Per-Group State (2 groups for raid use)
------------------------------------------------------------------------

local MAX_GROUPS = 2

local function NewGroupState()
    return {
        rotation = {},
        currentIdx = 1,
        cdState = {},
        unitMap = {},
        visibilityState = "HIDDEN",
        lastAlertTime = 0,
        bars = {},
        anchorFrame = nil,
        headerText = nil,
        onUpdateFrame = nil,
        onUpdateThrottle = 0,
    }
end

local groups = { NewGroupState(), NewGroupState() }
local myGroupIdx = nil

-- Shared state
local inCombat = false
local groupUnits = {}

--- Helper to get config key for a group
local function CfgKey(base, gi)
    if gi == 1 or not gi then return base end
    return base .. tostring(gi)
end

--- Resolve which group the local player is in
local function ResolveMyGroup()
    local playerName = StripRealm(UnitName("player") or "")
    for gi = 1, MAX_GROUPS do
        for _, entry in ipairs(groups[gi].rotation) do
            if entry.name == playerName then
                myGroupIdx = gi
                return
            end
        end
    end
    myGroupIdx = nil
end

-- Backward-compat aliases for group 1
local kickRotation = groups[1].rotation
local currentIdx = groups[1].currentIdx
local kickCDState = groups[1].cdState
local kickerBars = groups[1].bars
local anchorFrame = groups[1].anchorFrame
local headerText = groups[1].headerText
local visibilityState = groups[1].visibilityState
local lastAlertTime = groups[1].lastAlertTime
local onUpdateFrame = groups[1].onUpdateFrame
local onUpdateThrottle = groups[1].onUpdateThrottle
local rotationUnitMap = groups[1].unitMap

------------------------------------------------------------------------
-- Correlation routing (deferred — groups must exist before this runs)
------------------------------------------------------------------------

local CLASSTOKEN_TO_NAME = {
    DEATHKNIGHT="Death Knight", DEMONHUNTER="Demon Hunter", DRUID="Druid",
    EVOKER="Evoker", HUNTER="Hunter", MAGE="Mage", MONK="Monk",
    PALADIN="Paladin", PRIEST="Priest", ROGUE="Rogue", SHAMAN="Shaman",
    WARLOCK="Warlock", WARRIOR="Warrior",
}

function KT:_correlRoute(shortName, bestUnit)
    Log:Log("DEBUG", string.format("KickCorrel: routing %s, rotation size=%d", shortName, #groups[1].rotation))
    local found = false
    for gi = 1, MAX_GROUPS do
        for _, entry in ipairs(groups[gi].rotation) do
            if entry.name == shortName then
                local spellID = entry.spellID
                if not spellID or spellID == 0 then
                    local specID = HexCD.SpecCache and HexCD.SpecCache.Get
                        and HexCD.SpecCache:Get(entry.name) or nil
                    local classInfo = entry.class and ResolveKickSpell(entry.class, specID)
                    spellID = classInfo and classInfo.spellID or 0
                end
                HandleKickByName(shortName, spellID, gi, "correlated")
                found = true
                break
            end
        end
        if found then break end
    end
    if not found then
        -- Verify this person is actually in the current party before auto-adding
        local inParty = false
        pcall(function()
            for i = 1, 4 do
                local uid = "party" .. i
                if UnitExists(uid) then
                    local n = UnitName(uid)
                    if n and not (issecretvalue and issecretvalue(n)) then
                        if n:match("^([^-]+)") == shortName then inParty = true end
                    end
                end
            end
        end)
        if not inParty then
            Log:Log("DEBUG", string.format("KickCorrel: %s kicked but not in party — skipping auto-add", shortName))
        else
            -- Cap: don't exceed party size (4 party members max for kicks)
            if #groups[1].rotation >= 4 then
                Log:Log("DEBUG", string.format("KickCorrel: %s kicked but rotation full (%d) — skipping", shortName, #groups[1].rotation))
            else
                Log:Log("INFO", string.format("KickCorrel: %s kicked (not in rotation) — auto-adding to group 1", shortName))
                local kickInfo, classKey = nil, nil
                pcall(function()
                    local _, c = UnitClass(bestUnit)
                    if c and not (issecretvalue and issecretvalue(c)) then
                        classKey = CLASSTOKEN_TO_NAME[c:upper()]
                        local specID = HexCD.SpecCache and HexCD.SpecCache.Get
                            and HexCD.SpecCache:Get(shortName) or nil
                        kickInfo = classKey and ResolveKickSpell(classKey, specID) or nil
                    end
                end)
                local spellID = kickInfo and kickInfo.spellID or 0
                local cd = kickInfo and kickInfo.cd or 15
                table.insert(groups[1].rotation, { name = shortName, class = classKey, spellID = spellID, cd = cd })
                if #groups[1].rotation == 1 then groups[1].currentIdx = 1 end
                kickRotation = groups[1].rotation
                -- Map the new entry to its unit token + persist the roster
                -- so RebuildGroupMapping fills unitMap[i] and liveness checks
                -- work for the auto-added kicker.
                KT:RebuildGroupMapping()
                local saveData = {}
                for _, r in ipairs(groups[1].rotation) do
                    table.insert(saveData, { name = r.name, class = r.class })
                end
                Config:Set(CfgKey("kickRotation", 1), saveData)
                -- Transition to ACTIVE if we're in combat. PLAYER_REGEN_DISABLED
                -- earlier may have kept us HIDDEN (empty rotation at combat
                -- start); now that we have a kicker, show the bar.
                if inCombat and Config:Get("kickEnabled") and visibilityState == "HIDDEN" then
                    TransitionTo("ACTIVE")
                end
            end
        end
        kickRotation = groups[1].rotation
        HandleKickByName(shortName, spellID, 1, "correlated")
    end
end

------------------------------------------------------------------------
-- Bar Creation
------------------------------------------------------------------------

local function CreateKickerBar(index)
    return Util.CreateTrackerBar("HexCDKickBar" .. index)
end

local kickAnchorCount = 0
local function CreateAnchor(pointKey, xKey, yKey, defaultX, defaultY)
    kickAnchorCount = kickAnchorCount + 1
    pointKey = pointKey or "kickAnchorPoint"
    xKey = xKey or "kickAnchorX"
    yKey = yKey or "kickAnchorY"
    defaultX = defaultX or -300
    defaultY = defaultY or 0
    return Util.CreateTrackerAnchor("HexCDKickAnchor" .. kickAnchorCount, {0.08, 0.08, 0.12}, {0.3, 0.5, 0.7}, "CENTER", defaultX, defaultY, pointKey, xKey, yKey)
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------

function KT:Init()
    -- Create UI for both groups
    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        local suffix = gi == 1 and "" or "2"
        local defY = gi == 1 and 0 or -80
        gs.anchorFrame = CreateAnchor("kickAnchorPoint" .. suffix, "kickAnchorX" .. suffix, "kickAnchorY" .. suffix, -300, defY)
        gs.bars = {}
        for i = 1, BAR_POOL_SIZE do
            gs.bars[i] = CreateKickerBar(i)
            gs.bars[i]:SetParent(gs.anchorFrame)
        end
        gs.headerText = gs.anchorFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        gs.headerText:SetPoint("TOP", 0, -2)
    end
    -- Backward compat aliases
    anchorFrame = groups[1].anchorFrame
    kickerBars = groups[1].bars
    headerText = groups[1].headerText

    -- Register addon message prefix (idempotent — DispelTracker may have already done this)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, err = pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_MSG_PREFIX)
        if ok then
            commsRegistered = true
            Log:Log("DEBUG", "KickTracker: addon comms registered (prefix: " .. ADDON_MSG_PREFIX .. ")")
        else
            -- Already registered by DispelTracker — that's fine
            commsRegistered = true
            Log:Log("DEBUG", "KickTracker: addon comms prefix already registered")
        end
    end

    -- OnUpdate frame for CD ticking (only runs in ACTIVE state)
    onUpdateFrame = CreateFrame("Frame", "HexCDKickOnUpdate")
    onUpdateFrame:Hide()
    onUpdateFrame:SetScript("OnUpdate", function(_, elapsed)
        onUpdateThrottle = onUpdateThrottle + elapsed
        if onUpdateThrottle < UPDATE_THROTTLE then return end
        onUpdateThrottle = 0
        KT:UpdateDisplay()
    end)

    -- Load rotation from saved config, or auto-enroll
    local saved = Config:Get("kickRotation")
    if saved and #saved > 0 then
        KT:SetRotation(saved)
    end
    local saved2 = Config:Get("kickRotation2")
    if saved2 and #saved2 > 0 then
        KT:SetRotation(saved2, 2)
    end
    KT:AutoEnroll()

    Log:Log("DEBUG", "KickTracker initialized")
end

------------------------------------------------------------------------
-- Rotation Management
------------------------------------------------------------------------

function KT:SetRotation(names, groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    gs.rotation = {}

    if type(names) == "string" then
        for name in names:gmatch("[^,]+") do
            name = StripRealm(name:match("^%s*(.-)%s*$"))
            table.insert(gs.rotation, { name = name, class = nil })
        end
    elseif type(names) == "table" then
        for _, entry in ipairs(names) do
            if type(entry) == "string" then
                table.insert(gs.rotation, { name = entry, class = nil })
            elseif type(entry) == "table" then
                table.insert(gs.rotation, entry)
            end
        end
    end

    if groupIdx == 1 then kickRotation = gs.rotation end

    KT:RebuildGroupMapping()

    gs.currentIdx = 1
    wipe(gs.cdState)
    if groupIdx == 1 then currentIdx = 1; kickCDState = gs.cdState end

    local saveData = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(saveData, { name = r.name, class = r.class })
    end
    Config:Set(CfgKey("kickRotation", groupIdx), saveData)

    ResolveMyGroup()

    local names_str = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names_str, r.name)
    end
    local groupLabel = groupIdx > 1 and (" (group " .. groupIdx .. ")") or ""
    Log:Log("INFO", "Kick rotation set" .. groupLabel .. ": " .. table.concat(names_str, " > "))
    print("|cFF88CCFF[HexCD]|r Kick rotation" .. groupLabel .. ": " .. table.concat(names_str, " > "))
end

function KT:RebuildGroupMapping()
    wipe(groupUnits)
    wipe(rotationUnitMap)

    local Util = HexCD.Util
    local prefix, count
    if Util.IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    elseif Util.IsInAnyGroup() then
        prefix, count = "party", GetNumGroupMembers() - 1
        groupUnits["player"] = true
    else
        groupUnits["player"] = true
        return
    end

    for i = 1, count do
        local unit = prefix .. i
        if UnitExists(unit) then
            groupUnits[unit] = true
        end
    end

    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        wipe(gs.unitMap)
        for i, entry in ipairs(gs.rotation) do
            for unit in pairs(groupUnits) do
                local ok, unitName = pcall(UnitName, unit)
                if ok and StripRealm(unitName) == entry.name then
                    gs.unitMap[i] = unit
                    if not entry.class then
                        local _, className = UnitClass(unit)
                        if className and not issecretvalue(className) then
                            entry.class = className:sub(1,1):upper() .. className:sub(2):lower()
                        end
                    end
                    if entry.class then
                        local specID = HexCD.SpecCache and HexCD.SpecCache.Get
                            and HexCD.SpecCache:Get(entry.name) or nil
                        local info = ResolveKickSpell(entry.class, specID)
                        if info then
                            entry.spellID = info.spellID
                            entry.cd = info.cd
                            entry.kickName = info.name
                        end
                    end
                    break
                end
            end
        end
    end
    rotationUnitMap = groups[1].unitMap
end

------------------------------------------------------------------------
-- Rotation Logic
------------------------------------------------------------------------

local function IsKickerReady(idx)
    local state = kickCDState[idx]
    if not state then return true, 0 end
    local remaining = state.readyTime - GetTime()
    if remaining <= 0 then return true, 0 end
    return false, remaining
end

local function GetNextAliveIdx(startIdx)
    if #kickRotation == 0 then return nil end
    local idx = startIdx
    for _ = 1, #kickRotation do
        local unit = rotationUnitMap[idx]
        if unit and UnitExists(unit) and not UnitIsDeadOrGhost(unit) then
            return idx
        end
        idx = (idx % #kickRotation) + 1
    end
    return startIdx
end

-- Pick the alive kicker with the lowest readyTime (soonest off CD).
-- Tiebreaker: rotation order (lower index wins).
-- Called after each kick to lock in who goes next.
local function GetLowestCDIdx()
    if #kickRotation == 0 then return 1 end
    local now = GetTime()
    local bestIdx = nil
    local bestReadyTime = math.huge

    for i = 1, #kickRotation do
        local unit = rotationUnitMap[i]
        local alive = not unit or (UnitExists(unit) and not UnitIsDeadOrGhost(unit))
        if alive then
            local state = kickCDState[i]
            local readyTime = state and state.readyTime or 0
            -- Clamp: all ready players are equal at 0, rotation order breaks tie
            if readyTime <= now then readyTime = 0 end
            if readyTime < bestReadyTime then
                bestReadyTime = readyTime
                bestIdx = i
            end
        end
    end

    return bestIdx or 1
end

------------------------------------------------------------------------
-- Display
------------------------------------------------------------------------

function KT:UpdateDisplay()
    local barWidth = Config:Get("kickBarWidth") or 210
    local barHeight = Config:Get("kickBarHeight") or 20
    local now = GetTime()

    for gi = 1, MAX_GROUPS do
        local gs = groups[gi]
        if not gs.anchorFrame then break end

        if gs.visibilityState == "HIDDEN" or #gs.rotation == 0 then
            gs.anchorFrame:Hide()
            for _, bar in ipairs(gs.bars) do bar:Hide(); bar._active = false end
        else
            gs.anchorFrame:Show()

            -- Lazy class resolve: entries added via correlation auto-add or
            -- during secretvalue'd roster scans may still have class=nil.
            -- Retry here so the header + bar colors self-heal each frame.
            for i, entry in ipairs(gs.rotation) do
                if not entry.class then
                    local unit = gs.unitMap[i]
                    if unit and UnitExists(unit) then
                        pcall(function()
                            local _, c = UnitClass(unit)
                            if c and not (issecretvalue and issecretvalue(c)) then
                                entry.class = c:sub(1,1):upper() .. c:sub(2):lower()
                            end
                        end)
                    end
                end
            end

            local activeIdx = gs.currentIdx
            local nextEntry = activeIdx and gs.rotation[activeIdx] or nil
            local nextName = (nextEntry and nextEntry.name) or "?"
            local coloredNext = HexCD.Util.ColorNameByClass(nextName, nextEntry and nextEntry.class)
            local groupTag = gi > 1 and (" G" .. gi) or ""
            gs.headerText:SetText("|cFF88CCFFKICK" .. groupTag .. "|r  " .. coloredNext .. "|cFFFFCC00's turn|r")

            local HEADER_HEIGHT = 20
            local GAP = 4
            local BAR_SPACING = barHeight + 4
            local yPos = -(HEADER_HEIGHT + GAP)

            for i = 1, BAR_POOL_SIZE do
                local bar = gs.bars[i]
                local entry = gs.rotation[i]

                if entry then
                    local ready = true
                    local remaining = 0
                    local state = gs.cdState[i]
                    if state then
                        remaining = math.max(0, state.readyTime - now)
                        ready = remaining <= 0
                    end
                    local unit = gs.unitMap[i]
                    local isDead = unit and UnitExists(unit) and UnitIsDeadOrGhost(unit)

                    if isDead then
                        bar:Hide()
                        bar._active = false
                    else
                        bar._active = true
                        bar:ClearAllPoints()
                        bar:SetPoint("TOPLEFT", gs.anchorFrame, "TOPLEFT", 4, yPos)
                        bar:SetSize(barWidth - 8, barHeight)
                        bar:Show()
                        yPos = yPos - BAR_SPACING

                        local kickSpellName = entry.kickName
                        if not kickSpellName and entry.class then
                            local specID = HexCD.SpecCache and HexCD.SpecCache.Get
                                and HexCD.SpecCache:Get(entry.name) or nil
                            local info = ResolveKickSpell(entry.class, specID)
                            kickSpellName = info and info.name or "Interrupt"
                        end
                        kickSpellName = kickSpellName or "Interrupt"
                        local coloredName = HexCD.Util.ColorNameByClass(entry.name or "?", entry.class)
                        bar.nameText:SetText(string.format("|cFFFFFFFF%d|r  %s |cFF888888(%s)|r", i, coloredName, kickSpellName))

                        if ready then
                            bar.cdText:SetText("|cFF00FF00OK|r")
                            bar:SetStatusBarColor(0.15, 0.4, 0.55)
                            bar:SetValue(1)
                        else
                            bar.cdText:SetText(string.format("|cFFFF4444%.0fs|r", remaining))
                            bar:SetStatusBarColor(0.5, 0.1, 0.1)
                            bar:SetValue(remaining / (entry.cd or 15))
                        end

                        if i == activeIdx then
                            bar.goldBorder:Show()
                            if ready then bar:SetStatusBarColor(0.2, 0.5, 0.7) end
                        else
                            bar.goldBorder:Hide()
                        end
                    end
                else
                    bar:Hide()
                    bar._active = false
                end
            end

            local totalHeight = math.abs(yPos) + GAP
            gs.anchorFrame:SetSize(barWidth, totalHeight)
        end
    end
end

------------------------------------------------------------------------
-- Visibility State Machine
------------------------------------------------------------------------

local function TransitionTo(newState)
    if newState == visibilityState then return end
    local old = visibilityState
    visibilityState = newState
    -- Sync state to all groups
    for gi = 1, MAX_GROUPS do
        groups[gi].visibilityState = newState
    end

    if newState == "HIDDEN" then
        for gi = 1, MAX_GROUPS do
            if groups[gi].anchorFrame then groups[gi].anchorFrame:Hide() end
            for _, bar in ipairs(groups[gi].bars) do bar:Hide(); bar._active = false end
        end
        if onUpdateFrame then onUpdateFrame:Hide() end

    elseif newState == "ACTIVE" then
        for gi = 1, MAX_GROUPS do
            if groups[gi].anchorFrame and #groups[gi].rotation > 0 then
                groups[gi].anchorFrame:Show()
                groups[gi].anchorFrame:SetAlpha(1.0)
            end
        end
        if onUpdateFrame then onUpdateFrame:Show() end
        KT:UpdateDisplay()
        -- Do NOT CheckAlert on combat entry — only alert on actual kick events
    end

    Log:Log("DEBUG", string.format("KickTracker: %s → %s", old, newState))
end

------------------------------------------------------------------------
-- Alert Sound
------------------------------------------------------------------------

function KT:CheckAlert()
    if not Config:Get("kickAlertEnabled") then return end
    if #kickRotation == 0 then return end

    -- Active kicker is locked after each kick event
    local activeIdx = currentIdx
    local entry = kickRotation[activeIdx]
    if not entry then return end

    local playerName = UnitName("player")
    if entry.name ~= playerName then return end

    -- Only alert if CD is ready
    local ready, remaining = IsKickerReady(activeIdx)
    if not ready then
        Log:Log("DEBUG", string.format("KickTracker: alert skipped — CD not ready (%.1fs remaining)", remaining))
        return
    end

    local now = GetTime()
    if now - lastAlertTime < ALERT_DEBOUNCE_SEC then return end
    lastAlertTime = now

    local alertText = Config:Get("kickAlertText") or "Kick"
    Util.SpeakTTS(alertText)
    Log:Log("INFO", "KickTracker: ALERT — TTS: " .. alertText)
end

------------------------------------------------------------------------
-- Addon Comms
------------------------------------------------------------------------

local function GetAddonChannel()
    return HexCD.Util.GetGroupChannel()
end

local function BroadcastKickCast(casterName, spellID, groupIdx)
    if not commsRegistered then return end
    -- Check messaging lockdown (Midnight restriction during encounters)
    if C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() then return end

    local channel = GetAddonChannel()
    if not channel then return end
    local tag = "KICK" .. (groupIdx or 1)
    local msg = tag .. ":" .. casterName .. ":" .. spellID
    local ok, ret = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok and ret ~= 0 then
        Log:Log("DEBUG", "KickTracker: broadcast kick from " .. casterName)
        return
    end

    -- Fallback: whisper each member individually (when PARTY/RAID blocked in instances)
    local unitPrefix = HexCD.Util.GetGroupUnitInfo()
    for i = 1, GetNumGroupMembers() do
        local unit = unitPrefix .. i
        if UnitExists(unit) then
            local name, realm = UnitName(unit)
            local target = realm and realm ~= "" and (name .. "-" .. realm) or name
            pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, "WHISPER", target)
        end
    end
    Log:Log("DEBUG", "KickTracker: broadcast kick via whisper fallback")
end

function KT:BroadcastRotation(groupIdx)
    groupIdx = groupIdx or 1
    if not commsRegistered then
        print("|cFFFF0000[HexCD]|r Comms not registered — are you in a group?")
        return
    end
    local channel = GetAddonChannel()
    if not channel then
        print("|cFFFF0000[HexCD]|r Not in a group — cannot broadcast.")
        return
    end
    local gs = groups[groupIdx]
    local names = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names, r.name)
    end
    local tag = "KICKROTATION" .. groupIdx
    local msg = tag .. ":" .. table.concat(names, ",")
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    if ok then
        local groupLabel = groupIdx > 1 and (" (group " .. groupIdx .. ")") or ""
        print("|cFF88CCFF[HexCD]|r Kick rotation" .. groupLabel .. " broadcast to group.")
        Log:Log("INFO", "KickTracker: broadcast rotation" .. groupLabel .. ": " .. table.concat(names, " > "))
    else
        print("|cFFFF0000[HexCD]|r Broadcast failed: " .. tostring(err))
    end
end

-- Dedup window: if a kick was already recorded for this player within N seconds,
-- skip the duplicate. Layer 3 (correlation, ~30ms) wins over Layer 4 (addon msg, ~300ms).
local DEDUP_WINDOW = 2.0

HandleKickByName = function(casterName, spellID, groupIdx, source)
    groupIdx = groupIdx or 1
    source = source or "unknown"
    local gs = groups[groupIdx]
    casterName = StripRealm(casterName)
    local now = GetTime()

    for i, entry in ipairs(gs.rotation) do
        if entry.name == casterName then
            -- Resolve the kick spell. Combat log in Midnight sometimes hands
            -- us a redacted spellID (0 or nil — see MIDNIGHT-API-RESTRICTIONS).
            -- When that happens, fall back to the class/spec-resolved kick.
            local spellInfo = spellID and spellID ~= 0 and KICK_SPELL_IDS[spellID] or nil
            local effectiveSpellID = spellID
            local resolvedVia = nil
            if not spellInfo and entry.class then
                local specID = HexCD.SpecCache and HexCD.SpecCache:Get(casterName)
                local resolved = ResolveKickSpell(entry.class, specID)
                if resolved then
                    spellInfo = resolved
                    effectiveSpellID = resolved.spellID
                    resolvedVia = "class-fallback"
                end
            end
            local spellCD = spellInfo and spellInfo.cd or 15

            -- Dedup: skip if already recorded within DEDUP_WINDOW
            local existing = gs.cdState[i]
            if existing and (now - existing.lastTime) < DEDUP_WINDOW then
                Log:Log("DEBUG", string.format("KickTracker: dedup %s kick from %s (already recorded %.1fs ago)",
                    casterName, source, now - existing.lastTime))
                return
            end

            gs.cdState[i] = {
                lastTime = now,
                readyTime = now + spellCD,
            }
            Log:Log("INFO", string.format("KickTracker: %s used kick (spell %s%s) group %d [%s]",
                casterName, tostring(effectiveSpellID or "?"),
                resolvedVia and (", via " .. resolvedVia) or "",
                groupIdx, source))
            break
        end
    end

    -- Advance rotation (shared logic: only if current person cast, 15s inactivity reset)
    local didAdvance = Util.AdvanceRotation(gs, casterName, GetNextAliveIdx, function(g)
        if groupIdx == 1 then currentIdx = g.currentIdx; kickCDState = g.cdState end
    end, "Kick", nil)

    -- Only alert if rotation actually changed to the player
    if didAdvance then
        KT:CheckAlert()
    end

    -- Schedule a re-check when the player's CD expires
    local playerName = StripRealm(UnitName("player") or "")
    local myEntry = gs.rotation[gs.currentIdx]
    if myEntry and myEntry.name == playerName then
        local state = gs.cdState[gs.currentIdx]
        if state and state.readyTime then
            local remaining = state.readyTime - GetTime()
            if remaining > 0 then
                C_Timer.After(remaining + 0.1, function()
                    Log:Log("DEBUG", "KickTracker: CD expired timer — re-checking alert")
                    KT:CheckAlert()
                end)
            end
        end
    end
end

local function HandleAddonMessage(prefix, message, _, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end

    local senderShort = StripRealm(sender)
    local playerName = UnitName("player")
    if senderShort == playerName then return end

    -- Handle "KICKROTATION1:" / "KICKROTATION2:" / legacy "KICKROTATION:"
    local rotGi, rotationNames = message:match("^KICKROTATION(%d?):(.+)$")
    if rotationNames then
        local gi = tonumber(rotGi) or 1
        Log:Log("INFO", string.format("KickTracker: received rotation group %d from %s: %s", gi, senderShort, rotationNames))
        Config:Set("kickEnabled", true)
        KT:SetRotation(rotationNames, gi)
        local groupLabel = gi > 1 and (" (group " .. gi .. ")") or ""
        print(string.format("|cFF88CCFF[HexCD]|r Kick rotation%s received from %s: %s", groupLabel, senderShort, rotationNames))
        return
    end

    -- Parse "KICK1:Name:spellID" / "KICK2:Name:spellID" / legacy "KICK:Name:spellID"
    local kickGi, casterName, spellIDStr = message:match("^KICK(%d?):(.+):(%d+)$")
    if casterName and spellIDStr then
        local gi = tonumber(kickGi) or 1
        local spellID = tonumber(spellIDStr)
        if not KICK_SPELL_IDS[spellID] then return end
        HandleKickByName(casterName, spellID, gi, "addon")
    end
end

------------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "HexCDKickTrackerFrame")

eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
-- INSPECT_READY arrives after GROUP_ROSTER_UPDATE once spec resolves;
-- rebuild so e.g. a Balance Druid's Solar Beam replaces the default
-- Skull Bash in the rotation.
eventFrame:RegisterEvent("INSPECT_READY")
-- Local-player re-resolve fires PLAYER_SPECIALIZATION_CHANGED.
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "CHAT_MSG_ADDON" then
        if Config:Get("kickEnabled") then
            HandleAddonMessage(...)
        end
        return
    end

    if event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        if Config:Get("kickEnabled") and #kickRotation > 0 then
            TransitionTo("ACTIVE")
        end
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        TransitionTo("HIDDEN")
        return
    end

    if not Config:Get("kickEnabled") then return end

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...
        if unit == "player" then
            -- Use taint laundering for safety (spellID may be tainted even for player)
            local kickData, cleanID = SafeGetKickData(spellID)
            if kickData then
                local playerName = UnitName("player")
                ResolveMyGroup()
                local gi = myGroupIdx or 1
                HandleKickByName(playerName, cleanID, gi, "self")
                BroadcastKickCast(playerName, cleanID, gi)
            end
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        KT:RebuildGroupMapping()
        KT:AutoEnroll()

    elseif event == "INSPECT_READY" or event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Spec became known / changed — re-resolve kick variants so
        -- spec-specific interrupts (Solar Beam vs Skull Bash, Muzzle vs
        -- Counter Shot) get picked up in the rotation display.
        KT:RebuildGroupMapping()
    end
end)

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Auto-enroll kickers based on group composition.
--- Party: all tanks + DPS with interrupts. Raid: no auto-enrollment.
function KT:AutoEnroll()
    if not HexCD.Util.IsInAnyGroup() then
        Log:Log("DEBUG", "KickTracker.AutoEnroll: skipped — not in any group")
        return
    end

    local comp = Util.ScanGroupComposition()

    -- Check if group 1 rotation is stale
    local currentNames = self:GetRotationNames(1)
    local groupSet = {}
    for _, n in ipairs(comp.kickers) do groupSet[n] = true end

    Log:Log("DEBUG", string.format(
        "KickTracker.AutoEnroll: comp.kickers=%d, currentRotation=%d, isRaid=%s",
        #comp.kickers, #currentNames, tostring(comp.isRaid)))

    -- If the current group has NO valid kickers (follower dungeon /
    -- Exile's Reach / solo world / raid-without-kickers), clear the
    -- rotation entirely rather than leave ghosts from a previous key.
    -- Otherwise "rotation full (4)" prevents real kickers from getting
    -- auto-added when a real group forms.
    if #comp.kickers == 0 then
        if #currentNames > 0 then
            groups[1].rotation = {}
            groups[1].currentIdx = 1
            wipe(groups[1].cdState)
            kickRotation = groups[1].rotation
            kickCDState = groups[1].cdState
            currentIdx = 1
            Config:Set("kickRotation", {})
            Log:Log("INFO", "KickTracker: cleared stale rotation (no kickers in current group)")
            KT:RebuildGroupMapping()
        end
        return
    end

    -- Always clean up stale group 2 (old party/test data)
    local allMembers = {}
    for _, n in ipairs(comp.kickers) do allMembers[n] = true end
    for _, n in ipairs(comp.dispellers or {}) do allMembers[n] = true end
    local g2names = self:GetRotationNames(2)
    for _, n in ipairs(g2names) do
        if not allMembers[n] then
            groups[2].rotation = {}
            groups[2].currentIdx = 1
            wipe(groups[2].cdState)
            Config:Set("kickRotation2", {})
            Log:Log("DEBUG", "KickTracker: cleared stale group 2")
            break
        end
    end

    -- Auto-enroll if any rotation name is no longer a valid kicker in
    -- the current group — someone left, respecced to healer, etc. Any
    -- single gone member triggers a full re-enroll with current kickers.
    -- Stale in either direction:
    --   (a) rotation has a name no longer a current kicker (left group,
    --       respecced), OR
    --   (b) current group has a kicker not in the rotation (new member
    --       joined, or rotation was only partial).
    local stale = (#currentNames == 0)
    local staleReason = stale and "empty" or nil
    local rotationSet = {}
    for _, n in ipairs(currentNames) do rotationSet[n] = true end
    if not stale then
        for _, n in ipairs(currentNames) do
            if not groupSet[n] then
                stale = true
                staleReason = n .. " not in current kickers"
                break
            end
        end
    end
    if not stale then
        for _, n in ipairs(comp.kickers) do
            if not rotationSet[n] then
                stale = true
                staleReason = n .. " not yet in rotation"
                break
            end
        end
    end
    if not stale then
        Log:Log("DEBUG", "KickTracker.AutoEnroll: rotation still valid, no-op")
        return
    end
    Log:Log("DEBUG", "KickTracker.AutoEnroll: stale (" .. tostring(staleReason) .. "), re-enrolling")

    -- Sort auto-enrolled kickers by CD ascending (lowest CD first). This
    -- gives the party a fast-rotating baseline: the player with the cheapest
    -- interrupt goes up, then the next, etc. Resolves each kicker's class +
    -- spec to look up their kick CD via the KICK_SPELLS table.
    local prefix, maxCount = Util.GetGroupUnitInfo()
    local nameToCd = {}
    local function recordCd(unit)
        local ok, name = pcall(UnitName, unit)
        if not ok or not name or name == "" then return end
        if issecretvalue and issecretvalue(name) then return end
        local shortName = name:match("^([^-]+)") or name
        local classKey = nil
        pcall(function()
            local _, c = UnitClass(unit)
            if c and not issecretvalue(c) then
                -- KICK_SPELLS is keyed by friendly name ("Death Knight"), so
                -- convert class token back via CLASS_SORT_ORDER mapping.
                local map = { DEATHKNIGHT="Death Knight", DEMONHUNTER="Demon Hunter",
                              DRUID="Druid", EVOKER="Evoker", HUNTER="Hunter",
                              MAGE="Mage", MONK="Monk", PALADIN="Paladin",
                              PRIEST="Priest", ROGUE="Rogue", SHAMAN="Shaman",
                              WARLOCK="Warlock", WARRIOR="Warrior" }
                classKey = map[c:upper()] or c
            end
        end)
        local specID = nil
        if unit == "player" then
            pcall(function()
                local idx = GetSpecialization and GetSpecialization()
                if idx then specID = select(1, GetSpecializationInfo and GetSpecializationInfo(idx)) end
            end)
        else
            -- party specID requires inspect; fall back to default kick CD
            -- when unknown (ResolveKickSpell handles nil specID correctly).
        end
        local info = classKey and ResolveKickSpell(classKey, specID) or nil
        if info then nameToCd[shortName] = info.cd end
    end
    recordCd("player")
    if prefix and maxCount then
        for i = 1, maxCount do
            local unit = prefix .. i
            if UnitExists(unit) then recordCd(unit) end
        end
    end
    local sorted = {}
    for _, n in ipairs(comp.kickers) do table.insert(sorted, n) end
    table.sort(sorted, function(a, b)
        local ca, cb = nameToCd[a] or 999, nameToCd[b] or 999
        if ca ~= cb then return ca < cb end
        return a < b  -- stable tiebreak by name
    end)

    -- Cap auto-enroll at 5 (same as DispelTracker). Keeps the bar compact
    -- and picks the lowest-CD kickers first.
    local MAX_AUTO_ENROLL = 5
    if #sorted > MAX_AUTO_ENROLL then
        local trimmed = {}
        for i = 1, MAX_AUTO_ENROLL do trimmed[i] = sorted[i] end
        sorted = trimmed
    end

    KT:SetRotation(sorted, 1)
    Log:Log("INFO", string.format("KickTracker: auto-enrolled %d kickers%s, sorted by CD",
        #sorted, comp.isRaid and " (raid)" or ""))
end

function KT:GetRotationNames(groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    local names = {}
    for _, r in ipairs(gs.rotation) do
        table.insert(names, r.name)
    end
    return names
end

function KT:GetMyGroup()
    ResolveMyGroup()
    return myGroupIdx
end

function KT:Reset()
    wipe(kickCDState)
    currentIdx = 1
    TransitionTo("HIDDEN")
end

function KT:Unlock()
    for gi = 1, MAX_GROUPS do
        local af = groups[gi].anchorFrame
        if af then
            af:EnableMouse(true)
            af:Show()
            af:SetAlpha(1.0)
            af:SetBackdropBorderColor(1.0, 0.8, 0.0, 0.9)
            local ht = groups[gi].headerText
            if ht then
                ht:SetText("|cFF88CCFFKick Tracker" .. (gi > 1 and (" G" .. gi) or "") .. "|r  |cFFFFCC00DRAG TO MOVE|r")
            end
        end
    end
end

function KT:Lock()
    for gi = 1, MAX_GROUPS do
        local af = groups[gi].anchorFrame
        if af then
            af:EnableMouse(false)
            af:SetBackdropBorderColor(0.3, 0.5, 0.7, 0.8)
            if visibilityState == "HIDDEN" then af:Hide() end
        end
    end
end

function KT:IsUnlocked()
    return anchorFrame and anchorFrame:IsMouseEnabled() or false
end

function KT:ToggleLock()
    if self:IsUnlocked() then self:Lock() else self:Unlock() end
end

--- Test helper: show the kick UI for a duration (default 15s)
--- @param duration number|nil Duration in seconds
function KT:SimulateKicks(duration, _count)
    duration = duration or 15
    if #kickRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set kick rotation first: /hexcd kickorder Name1,Name2,Name3")
        return
    end
    TransitionTo("ACTIVE")
    print(string.format("|cFF88CCFF[HexCD]|r Kick test: UI shown for %ds.", duration))

    C_Timer.After(duration, function()
        if not inCombat then
            TransitionTo("HIDDEN")
        end
    end)
end

--- Test helper: simulate a specific player's kick cast
function KT:SimulateCastFrom(name)
    local playerName = UnitName("player")
    local spellID = 6552
    local targetGroup = 1
    for gi = 1, MAX_GROUPS do
        for _, entry in ipairs(groups[gi].rotation) do
            if entry.name == name then
                spellID = entry.spellID or 6552
                targetGroup = gi
                break
            end
        end
    end
    if name == playerName then
        HandleKickByName(name, spellID, targetGroup, "simulate")
    else
        local tag = "KICK" .. targetGroup
        local fakeMessage = tag .. ":" .. name .. ":" .. spellID
        local fakeSender = name .. "-FakeRealm"
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end
    print(string.format("|cFF88CCFF[HexCD]|r Simulated %s kick (group %d)", name, targetGroup))
end

--- Test helper: simulate an incoming kick from the current active kicker
function KT:SimulateIncomingComms()
    if #kickRotation == 0 then
        print("|cFFFF0000[HexCD]|r Set kick rotation first: /hexcd kickorder Name1,Name2,Name3")
        return
    end

    local activeIdx = GetNextAliveIdx(currentIdx)
    if not activeIdx then
        print("|cFFFF0000[HexCD]|r No active kicker in rotation")
        return
    end

    local entry = kickRotation[activeIdx]
    local playerName = UnitName("player")

    if entry.name == playerName then
        local spellID = entry.spellID or 6552
        print(string.format("|cFF88CCFF[HexCD]|r Simulating YOUR kick (%s, spell %d)", entry.name, spellID))
        HandleKickByName(entry.name, spellID, 1, "simulate")
    else
        local spellID = entry.spellID or 6552
        local fakeMessage = "KICK:" .. entry.name .. ":" .. spellID
        local fakeSender = entry.name .. "-FakeRealm"
        print(string.format("|cFF88CCFF[HexCD]|r Simulating incoming comm: %s kicked (spell %d)", entry.name, spellID))
        HandleAddonMessage(ADDON_MSG_PREFIX, fakeMessage, "PARTY", fakeSender)
    end

    if kickRotation[currentIdx] then
        print(string.format("|cFF88CCFF[HexCD]|r Next kicker: #%d %s", currentIdx, kickRotation[currentIdx].name))
    end
end

------------------------------------------------------------------------
-- Test helpers
------------------------------------------------------------------------

function KT:_testResolveKickSpell(classKey, specID)
    return ResolveKickSpell(classKey, specID)
end

function KT:_testGetState(groupIdx)
    groupIdx = groupIdx or 1
    local gs = groups[groupIdx]
    return {
        bars = gs.bars,
        cdState = gs.cdState,
        currentIdx = gs.currentIdx,
        rotation = gs.rotation,
        visibilityState = gs.visibilityState,
    }
end

function KT:_testGetQueueState()
    local gs = groups[1]
    return {
        currentIdx = gs.currentIdx,
        rotation = gs.rotation,
        cdState = gs.cdState,
    }
end

function KT:_testHandleKick(name, spellID, groupIdx)
    HandleKickByName(name, spellID, groupIdx or 1, "test")
end

function KT:_testInjectMessage(msg, sender)
    HandleAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY", sender or "Test-Realm")
end

-- Expose _correlRoute so tests can verify the auto-add-from-correlation
-- path populates the rotation entry's class (regression for uncolored kick
-- bars when a new kicker was added via KickCorrel).
function KT:_testCorrelRoute(shortName, bestUnit)
    KT:_correlRoute(shortName, bestUnit)
end
