------------------------------------------------------------------------
-- HexCD: CommSync — Party CD Sync Protocol
--
-- Each client tracks its own CDs locally and broadcasts to the group.
-- Other clients interpolate remaining time. Protocol:
--
--   CDHELLO:<name>:<spec>              — On group join / reload
--   CDCAST:<name>:<spellID>:<cd>       — On own cast detected
--   CDSTATE:<name>:<sid>:<rem>,...     — On combat end (reconciliation)
--
-- Consumers: future PartyCDDisplay, DispelTracker/KickTracker integration.
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.CommSync = {}

local CS = HexCD.CommSync
local Config = HexCD.Config
local Log = HexCD.DebugLog

-- Forward declarations (defined later, needed by OnEvent closures)
local ScanAndPopulateParty
local PrePopulatePersonalCDs

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local ADDON_MSG_PREFIX = "HexCD"

-- SpellDB provides the tracked spell database.
-- CommSync broadcasts any spell in SpellDB when cast.

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local commsRegistered = false
local eventFrame = nil
local lastHelloTime = 0
local HELLO_DEBOUNCE = 5   -- min seconds between CDHELLO sends
local rosterTimer = nil    -- coalesce rapid GROUP_ROSTER_UPDATE events
local helloRetryTimer = nil -- retry timer for failed/unknown CDHELLO

-- Party CD state: partyCD[playerName][spellID] = { readyTime, effectiveCD, castTime }
-- partyCD[playerName]._spec = "specName"
local partyCD = {}
local isTestMode = false

local localPlayerName = nil
local localSpec = nil

-- Combat context (retained from Phase 1 for logging + auto-open)
local inEncounter = false
local inCombat = false
local inMythicPlus = false
local encounterName = ""

-- Debounce for UNIT_SPELLCAST_SUCCEEDED (dispels/interrupts not covered by CT)
local DEBOUNCE_WINDOW = 2.0
local lastDirectCast = {} -- spellID → GetTime()

------------------------------------------------------------------------
-- Taint laundering (same technique as KickTracker, from InterruptTracker)
-- UNIT_SPELLCAST_SUCCEEDED spellID for party members is a "secret value"
-- in Midnight 12.0. Passing it through a StatusBar's SetValue causes C++
-- to re-emit a clean numeric value via OnValueChanged.
------------------------------------------------------------------------
local launderBar = CreateFrame("StatusBar")
launderBar:SetMinMaxValues(0, 9999999)
local _launderedID = nil
launderBar:SetScript("OnValueChanged", function(_, v) _launderedID = v end)

local function LaunderSpellID(spellID)
    _launderedID = nil
    launderBar:SetValue(0)
    pcall(launderBar.SetValue, launderBar, spellID)
    return _launderedID  -- nil if laundering failed
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function GetAddonChannel()
    return HexCD.Util.GetGroupChannel()
end

local function StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

local function GetCombatContext()
    if inEncounter then
        return "ENCOUNTER(" .. encounterName .. ")"
    elseif inCombat then
        return "COMBAT"
    elseif inMythicPlus then
        return "M+_OOC"
    else
        return "IDLE"
    end
end

------------------------------------------------------------------------
-- Send: CDHELLO
------------------------------------------------------------------------

--- Cancel any pending CDHELLO retry timer.
local function CancelHelloRetry()
    if helloRetryTimer then
        helloRetryTimer:Cancel()
        helloRetryTimer = nil
    end
end

--- Schedule a CDHELLO retry after `delaySec` seconds.
local function ScheduleHelloRetry(delaySec, reason)
    CancelHelloRetry()
    helloRetryTimer = C_Timer.NewTimer(delaySec, function()
        helloRetryTimer = nil
        lastHelloTime = 0  -- clear debounce so the retry goes through
        SendCDHello()
    end)
    Log:Log("DEBUG", "CommSync: CDHELLO retry in " .. delaySec .. "s (" .. reason .. ")")
end

function SendCDHello()
    if not commsRegistered then return end

    -- Debounce: don't spam CDHELLO
    local now = GetTime()
    if now - lastHelloTime < HELLO_DEBOUNCE then return end

    local channel = GetAddonChannel()
    if not channel then
        -- No channel yet (solo or APIs not ready) — retry in 3s
        ScheduleHelloRetry(3, "no channel")
        return
    end

    local specName = "Unknown"
    if GetSpecialization and GetSpecializationInfo then
        local specIdx = GetSpecialization()
        if specIdx then
            local _, sName = GetSpecializationInfo(specIdx)
            if sName then specName = sName end
        end
    end
    localSpec = specName
    lastHelloTime = now

    local msg = "CDHELLO:" .. (localPlayerName or "Unknown") .. ":" .. specName
    pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    Log:Log("DEBUG", "CommSync: sent CDHELLO spec=" .. specName)

    -- If spec was "Unknown", GetSpecialization wasn't ready — retry in 3s
    if specName == "Unknown" then
        ScheduleHelloRetry(3, "spec unknown")
    end
end

------------------------------------------------------------------------
-- Send: CDCAST
------------------------------------------------------------------------

local function SendCDCast(spellID, effectiveCD)
    if not commsRegistered then return end
    local channel = GetAddonChannel()
    if not channel then return end

    local msg = "CDCAST:" .. (localPlayerName or "Unknown") .. ":" .. spellID .. ":" .. effectiveCD
    local ok, err = pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)

    local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID)
    local spellName = info and info.name or tostring(spellID)
    if ok then
        Log:Log("DEBUG", string.format("CommSync CDCAST sent | %s(%d) cd=%ds", spellName, spellID, effectiveCD))
    else
        Log:Log("ERRORS", string.format("CommSync CDCAST failed | %s | %s", spellName, tostring(err)))
    end
end

------------------------------------------------------------------------
-- Send: CDSTATE (reconciliation on combat end)
------------------------------------------------------------------------

local function SendCDState()
    if not commsRegistered then return end
    local channel = GetAddonChannel()
    if not channel then return end

    local now = GetTime()
    local myCDs = partyCD[localPlayerName]
    if not myCDs then return end

    local parts = {}
    for spellID, state in pairs(myCDs) do
        if type(spellID) == "number" then
            local remaining = math.max(0, math.floor(state.readyTime - now))
            if remaining > 0 then
                table.insert(parts, spellID .. ":" .. remaining)
            end
        end
    end
    if #parts == 0 then return end

    local msg = "CDSTATE:" .. (localPlayerName or "Unknown") .. ":" .. table.concat(parts, ",")
    -- Respect 255-byte limit
    if #msg > 255 then
        -- Truncate to fit — drop trailing entries
        while #msg > 255 and #parts > 1 do
            table.remove(parts)
            msg = "CDSTATE:" .. (localPlayerName or "Unknown") .. ":" .. table.concat(parts, ",")
        end
    end

    pcall(C_ChatInfo.SendAddonMessage, ADDON_MSG_PREFIX, msg, channel)
    Log:Log("DEBUG", string.format("CommSync CDSTATE sent | %d CDs on cooldown", #parts))
end

------------------------------------------------------------------------
-- Receive handler
------------------------------------------------------------------------

local function OnAddonMessage(prefix, msg, channel, sender)
    if prefix ~= ADDON_MSG_PREFIX then return end

    local tag = msg:match("^(%u+):")
    if not tag then return end

    -- Ignore self-echo for CDHELLO (we already set our own state locally)
    local senderName = StripRealm(sender)
    local isSelf = (senderName == localPlayerName)

    if tag == "CDHELLO" then
        local name, spec = msg:match("^CDHELLO:([^:]+):(.+)$")
        if name then
            name = StripRealm(name)
            if name == localPlayerName then return end  -- skip self-echo entirely
            partyCD[name] = partyCD[name] or {}
            partyCD[name]._spec = spec
            Log:Log("DEBUG", string.format("CommSync CDHELLO from %s spec=%s", name, spec))

            -- Pre-populate their personal CDs as "ready" based on class
            -- Resolve class from spec name (avoids name-matching issues with special chars)
            local SPEC_TO_CLASS = {
                -- DK
                Blood = "DEATHKNIGHT", Frost = "DEATHKNIGHT", Unholy = "DEATHKNIGHT",
                -- DH
                Havoc = "DEMONHUNTER", Vengeance = "DEMONHUNTER",
                -- Druid
                Balance = "DRUID", Feral = "DRUID", Guardian = "DRUID", Restoration = "DRUID",
                -- Evoker
                Devastation = "EVOKER", Preservation = "EVOKER", Augmentation = "EVOKER",
                -- Hunter
                ["Beast Mastery"] = "HUNTER", Marksmanship = "HUNTER", Survival = "HUNTER",
                -- Mage
                Arcane = "MAGE", Fire = "MAGE", ["Frost "] = "MAGE",  -- note: "Frost" conflicts with DK
                -- Monk
                Brewmaster = "MONK", Mistweaver = "MONK", Windwalker = "MONK",
                -- Paladin
                Holy = "PALADIN", Protection = "PALADIN", Retribution = "PALADIN",
                -- Priest
                Discipline = "PRIEST", ["Holy "] = "PRIEST", Shadow = "PRIEST",
                -- Rogue
                Assassination = "ROGUE", Outlaw = "ROGUE", Subtlety = "ROGUE",
                -- Shaman
                Elemental = "SHAMAN", Enhancement = "SHAMAN",
                -- Warlock
                Affliction = "WARLOCK", Demonology = "WARLOCK", Destruction = "WARLOCK",
                -- Warrior
                Arms = "WARRIOR", Fury = "WARRIOR",
            }
            -- Handle ambiguous specs (Frost, Holy, Protection) by also checking UnitClass
            pcall(function()
                local DB = HexCD.SpellDB
                if not DB or not DB.GetAllSpells then return end
                local theirClass = SPEC_TO_CLASS[spec]
                -- Fallback: try UnitClass if spec didn't resolve
                if not theirClass then
                    for i = 1, 4 do
                        local unit = "party" .. i
                        pcall(function()
                            local uname = UnitName(unit)
                            if uname and StripRealm(uname) == name then
                                local c = select(2, UnitClass(unit))
                                if c and not (issecretvalue and issecretvalue(c)) then theirClass = c:upper() end
                            end
                        end)
                        if theirClass then break end
                    end
                end
                if not theirClass then return end
                local count = 0
                for spellID, info in pairs(DB:GetAllSpells()) do
                    if info.class == theirClass then
                        if not partyCD[name][spellID] then
                            partyCD[name][spellID] = { readyTime = 0, effectiveCD = info.cd, castTime = 0 }
                            count = count + 1
                        end
                    end
                end
                if count > 0 then
                    Log:Log("DEBUG", string.format("CommSync: pre-populated %d spells for %s (%s)", count, name, theirClass))
                end
            end)

            -- Reply with our own CDHELLO so the sender discovers us too
            -- (e.g., they just /reloaded and don't know about us yet)
            -- Short delay + debounce prevents ping-pong loops
            C_Timer.After(1, function() SendCDHello() end)
        end

    elseif tag == "CDCAST" then
        local name, spellIDStr, cdStr = msg:match("^CDCAST:([^:]+):(%d+):(%d+)$")
        if name and spellIDStr and cdStr then
            name = StripRealm(name)
            local spellID = tonumber(spellIDStr)
            local effectiveCD = tonumber(cdStr)
            local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID)

            -- Cross-layer dedup: skip if Layer 1/2/3 already recorded this CD
            local ADmod = HexCD.AuraDetector
            if ADmod and ADmod.IsDuplicate and ADmod:IsDuplicate(name, spellID) then
                Log:Log("DEBUG", string.format("CommSync CDCAST from %s | %s(%d) cd=%ds — DEDUP [comms]",
                    name, info and info.name or "?", spellID, effectiveCD))
            else
                local now = GetTime()
                partyCD[name] = partyCD[name] or {}
                partyCD[name][spellID] = {
                    readyTime = now + effectiveCD,
                    effectiveCD = effectiveCD,
                    castTime = now,
                }
                Log:Log("DEBUG", string.format("CommSync CDCAST from %s | %s(%d) cd=%ds [comms]",
                    name, info and info.name or "?", spellID, effectiveCD))
            end
        end

    elseif tag == "CDSTATE" then
        local name, stateCSV = msg:match("^CDSTATE:([^:]+):(.+)$")
        if name and stateCSV then
            name = StripRealm(name)
            local now = GetTime()
            partyCD[name] = partyCD[name] or {}
            for pair in stateCSV:gmatch("([^,]+)") do
                local sid, rem = pair:match("(%d+):(%d+)")
                if sid and rem then
                    local spellID = tonumber(sid)
                    local remaining = tonumber(rem)
                    local existing = partyCD[name][spellID]
                    partyCD[name][spellID] = {
                        readyTime = now + remaining,
                        effectiveCD = existing and existing.effectiveCD or (HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID) and HexCD.SpellDB:GetSpell(spellID).cd or 0),
                        castTime = existing and existing.castTime or nil,
                    }
                end
            end
            Log:Log("DEBUG", string.format("CommSync CDSTATE from %s | reconciled", name))
        end
    end
    -- Ignore DISPEL:, KICK:, ROTATION:, KICKROTATION:, COMMSTEST: — other modules handle those
end

------------------------------------------------------------------------
-- Record a local cast into partyCD and broadcast
------------------------------------------------------------------------

local function RecordAndBroadcast(spellID, effectiveCD)
    local now = GetTime()
    partyCD[localPlayerName] = partyCD[localPlayerName] or {}
    partyCD[localPlayerName][spellID] = {
        readyTime = now + effectiveCD,
        effectiveCD = effectiveCD,
        castTime = now,
    }
    SendCDCast(spellID, effectiveCD)
end

------------------------------------------------------------------------
-- Event Handling
------------------------------------------------------------------------

local function OnEvent(self, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellID = ...

        -- Track party member personal CD casts (partyN units only)
        -- Layer 2: direct spellID (works when not secret)
        -- Layer 3: taint laundering (StatusBar trick to unwrap secret values)
        -- Layer 4: addon comms (CDCAST) handled separately in OnAddonMessage
        local isPartyUnit = (unit == "party1" or unit == "party2" or unit == "party3" or unit == "party4")
        if isPartyUnit then
            -- Safe trace: only use clean values to avoid taint in log
            Log:Log("DEBUG", "Layer2+3: UNIT_SPELLCAST_SUCCEEDED for " .. unit)
            pcall(function()
                local n = UnitName(unit)
                if not n or (issecretvalue and issecretvalue(n)) then return end
                local unitName = StripRealm(n)
                if not unitName or not partyCD[unitName] then return end

                -- Layer 2: try direct spellID access
                local cleanID = nil
                local layer = "none"
                if not (issecretvalue and issecretvalue(spellID)) and type(spellID) == "number" then
                    cleanID = spellID
                    layer = "direct"
                end

                -- Layer 3: taint laundering if direct failed
                if not cleanID then
                    cleanID = LaunderSpellID(spellID)
                    if cleanID then layer = "laundered" end
                end

                if not cleanID then
                    Log:Log("DEBUG", string.format("Layer2+3: %s (%s) — spellID secret+launder failed, skip", unitName, unit))
                    return
                end

                -- Check if this spell is tracked
                local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(cleanID)
                if not info then
                    -- Not in SpellDB — not a tracked spell, ignore silently
                    return
                end

                -- Skip kicks and dispels — those have their own dedicated trackers
                if info.category == "KICK" or info.category == "DISPEL" then
                    return
                end

                if not partyCD[unitName][cleanID] then
                    Log:Log("DEBUG", string.format("Layer2+3: %s %s(%d) — spell not in partyCD [%s]",
                        unitName, info.name, cleanID, layer))
                    return
                end

                -- Cross-layer dedup: skip if Layer 1 (aura) already recorded this
                local ADmod = HexCD.AuraDetector
                if ADmod and ADmod.IsDuplicate and ADmod:IsDuplicate(unitName, cleanID) then
                    Log:Log("DEBUG", string.format("Layer2+3: %s %s(%d) — DEDUP [%s]",
                        unitName, info.name, cleanID, layer))
                    return
                end

                local now = GetTime()
                partyCD[unitName][cleanID] = {
                    readyTime = now + info.cd,
                    effectiveCD = info.cd,
                    castTime = now,
                }
                Log:Log("DEBUG", string.format("Layer2+3: %s %s(%d) CD %ds [%s]",
                    unitName, info.name, cleanID, info.cd, layer))
            end)
            return
        elseif unit ~= "player" then
            return  -- ignore targettarget, focus, nameplate, etc.
        end

        -- Local player: only handle spells NOT already covered by CooldownTracker callback
        local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID)
        if not info then return end

        local CT = HexCD.CooldownTracker
        local ctTracked = CT and CT:GetTrackedCDs() or {}
        if ctTracked[spellID] then return end -- CT callback handles these

        -- Also check aliases
        local aliases = CT and CT.GetAliases and CT:GetAliases() or {}
        local canonical = aliases[spellID] or spellID
        if ctTracked[canonical] then return end

        -- Debounce
        local now = GetTime()
        if lastDirectCast[spellID] and (now - lastDirectCast[spellID]) < DEBOUNCE_WINDOW then
            return
        end
        lastDirectCast[spellID] = now

        RecordAndBroadcast(spellID, info.cd)

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        OnAddonMessage(prefix, msg, channel, sender)

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Coalesce rapid GROUP_ROSTER_UPDATE events (fires many times on group changes)
        CS:PruneStale()
        if not rosterTimer then
            rosterTimer = C_Timer.After(2, function()
                rosterTimer = nil
                ScanAndPopulateParty()
                SendCDHello()
            end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Fires after /reload and zone transitions — APIs are fully ready here
        -- Short delay to let group state settle
        CancelHelloRetry()
        C_Timer.After(1, function()
            ScanAndPopulateParty()
            lastHelloTime = 0  -- clear debounce so hello goes through
            SendCDHello()
        end)

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        lastHelloTime = 0  -- always allow re-announce on spec change
        SendCDHello()

    elseif event == "ENCOUNTER_START" then
        local encounterID, name = ...
        inEncounter = true
        encounterName = name or ("ID:" .. tostring(encounterID))
        Log:Log("INFO", "CommSync ENCOUNTER_START: " .. encounterName)

    elseif event == "ENCOUNTER_END" then
        inEncounter = false
        Log:Log("INFO", "CommSync ENCOUNTER_END")
        encounterName = ""
        -- Auto-open HexCD debug log after raid encounters (dev only)
        if not inMythicPlus and Config:Get("autoOpenLog") then
            C_Timer.After(2, function()
                Log:ShowFrame()
            end)
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        inCombat = true
        Log:Log("DEBUG", "CommSync COMBAT START")
        -- Reset AuraDetector probes for fresh data each pull
        if HexCD.AuraDetector and HexCD.AuraDetector.Reset then
            HexCD.AuraDetector:Reset()
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        inCombat = false
        Log:Log("DEBUG", "CommSync COMBAT END")
        -- Send reconciliation state
        SendCDState()

    elseif event == "CHALLENGE_MODE_START" then
        inMythicPlus = true
        Log:Log("INFO", "CommSync M+ KEY STARTED")
        -- Reset PartyCDDisplay debug diagnostics for this key
        if HexCD.PartyCDDisplay and HexCD.PartyCDDisplay.ResetDebug then
            HexCD.PartyCDDisplay:ResetDebug()
        end

    elseif event == "CHALLENGE_MODE_COMPLETED" then
        inMythicPlus = false
        Log:Log("INFO", "CommSync M+ KEY COMPLETED")
        if Config:Get("autoOpenLog") then
            C_Timer.After(3, function()
                Log:ShowFrame()
                print("|cFF00CCFF[HexCD]|r Debug log auto-opened. Copy with Ctrl+A \226\134\146 Ctrl+C.")
            end)
        end
    end
end

------------------------------------------------------------------------
-- Party auto-discovery (works without CDHELLO — uses UnitClass)
------------------------------------------------------------------------

--- Pre-populate ALL tracked spells for a unit as "ready".
--- Covers PERSONAL, EXTERNAL_DEFENSIVE, UTILITY, HEALING, CC, KICK, DISPEL
--- so all detection layers can find the spell in partyCD when it fires.
--- @param unitID string e.g. "player", "party1"
--- @param name string Player name (stripped of realm)
PrePopulatePersonalCDs = function(unitID, name)
    pcall(function()
        local DB = HexCD.SpellDB
        if not DB or not DB.GetAllSpells then return end
        local unitClass = select(2, UnitClass(unitID))
        if not unitClass or (issecretvalue and issecretvalue(unitClass)) then
            unitClass = UnitClassBase and UnitClassBase(unitID)
        end
        if not unitClass then return end
        unitClass = unitClass:upper()
        partyCD[name] = partyCD[name] or {}
        local count = 0
        for spellID, info in pairs(DB:GetAllSpells()) do
            if info.class == unitClass then
                if not partyCD[name][spellID] then
                    partyCD[name][spellID] = {
                        readyTime = 0,
                        effectiveCD = info.cd,
                        castTime = 0,
                    }
                    count = count + 1
                end
            end
        end
        if count > 0 then
            Log:Log("DEBUG", string.format("CommSync: pre-populated %d spells for %s (%s)", count, name, unitClass))
        end
    end)
end

--- Scan all party members and pre-populate their personal CDs.
--- Called on init, GROUP_ROSTER_UPDATE, and PLAYER_ENTERING_WORLD.
ScanAndPopulateParty = function()
    if not HexCD.Util.IsInAnyGroup() then return end
    for i = 1, 4 do
        local uid = "party" .. i
        pcall(function()
            if not UnitExists(uid) then return end
            local name = UnitName(uid)
            if not name or (issecretvalue and issecretvalue(name)) then return end
            name = StripRealm(name)
            PrePopulatePersonalCDs(uid, name)
        end)
    end
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

function CS:Init()
    if eventFrame then return end

    localPlayerName = StripRealm(UnitName("player") or "Unknown")

    eventFrame = CreateFrame("Frame", "HexCDCommSyncFrame")
    eventFrame:SetScript("OnEvent", OnEvent)

    eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("ENCOUNTER_START")
    eventFrame:RegisterEvent("ENCOUNTER_END")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")

    -- Register prefix (idempotent — DispelTracker/KickTracker may have already done this)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, ADDON_MSG_PREFIX)
        commsRegistered = true
    end

    -- Hook into CooldownTracker for spec-specific CDs (Convoke, Tranq, etc.)
    -- CT already validates the spell is tracked for this spec — no need to
    -- re-check against SpellDB (which may not have spec-specific IDs
    -- like Convoke 391528, Flourish 197721, etc.)
    local CT = HexCD.CooldownTracker
    if CT then
        CT._onCastCallback = function(spellID, state)
            if state then
                RecordAndBroadcast(spellID, state.effectiveCD)
            end
        end
    end

    -- Pre-populate local player's personal CDs as "ready" so icons show immediately
    PrePopulatePersonalCDs("player", localPlayerName)

    -- Scan party members and pre-populate their personal CDs too
    -- (works even without CDHELLO — discovers class from UnitClass)
    ScanAndPopulateParty()

    -- Send initial hello if already in a group
    SendCDHello()

    Log:Log("INFO", "CommSync: initialized (party CD sync)")
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Get the full party CD state table.
---@return table partyCD[playerName][spellID] = { readyTime, effectiveCD, castTime }
function CS:GetPartyCD()
    return partyCD
end

--- Get a specific player's CD state for a spell.
---@param playerName string
---@param spellID number
---@return table|nil { readyTime, effectiveCD, castTime }
function CS:GetPlayerCD(playerName, spellID)
    local pcd = partyCD[playerName]
    if not pcd then return nil end
    return pcd[spellID]
end

--- Check if a party member's spell is ready.
---@param playerName string
---@param spellID number
---@return boolean ready, number remainingSec
function CS:IsReady(playerName, spellID)
    local state = self:GetPlayerCD(playerName, spellID)
    if not state then return true, 0 end
    local remaining = math.max(0, state.readyTime - GetTime())
    if remaining <= 0 then return true, 0 end
    return false, remaining
end

--- Get spec info for all known group members.
---@return table { [playerName] = specName }
function CS:GetGroupSpecs()
    local specs = {}
    for name, data in pairs(partyCD) do
        if type(data) == "table" and data._spec then
            specs[name] = data._spec
        end
    end
    return specs
end

--- Get the tracked spells table (for external consumers).
---@return table spellID → { name, cd }
function CS:GetTrackedSpells()
    return HexCD.SpellDB and HexCD.SpellDB:GetAllSpells() or {}
end

--- Inject test CD data for real party members using SpellDB categories.
function CS:IsTestMode() return isTestMode end

function CS:SimulateParty()
    isTestMode = true
    local now = GetTime()
    localPlayerName = StripRealm(UnitName("player") or "Unknown")

    -- Class-based test data: personal defensives + party CDs
    local CLASS_TEST = {
        DRUID       = { personal = { {22812, 60, 20}, {61336, 180, 90} },
                        healing  = { {740, 180, 100}, {391528, 60, 25} } },
        WARRIOR     = { personal = { {118038, 120, 0}, {184364, 120, 45} },
                        party_ranged = { {97462, 180, 60} } },
        DEATHKNIGHT = { personal = { {48792, 180, 80}, {48707, 60, 0} },
                        party_stacked = { {51052, 120, 30} } },
        DEMONHUNTER = { personal = { {198589, 60, 15} },
                        party_stacked = { {196718, 180, 90} } },
        PRIEST      = { personal = { {19236, 90, 0} },
                        healing = { {64843, 180, 120} } },
        PALADIN     = { personal = { {642, 300, 200}, {498, 60, 10} },
                        party_stacked = { {31821, 180, 45} } },
        SHAMAN      = { personal = { {108271, 120, 30} },
                        healing = { {108280, 180, 0} },
                        party_stacked = { {98008, 180, 100} } },
        EVOKER      = { personal = { {363916, 150, 50}, {374349, 90, 0} },
                        healing = { {363534, 240, 150} },
                        party_stacked = { {374227, 120, 40} } },
        MAGE        = { personal = { {45438, 240, 0}, {342245, 60, 20} } },
        ROGUE       = { personal = { {5277, 120, 45}, {31224, 120, 0} } },
        HUNTER      = { personal = { {186265, 180, 60}, {109304, 120, 0} } },
        WARLOCK     = { personal = { {104773, 180, 80}, {108416, 60, 15} } },
        MONK        = { personal = { {122278, 120, 0}, {243435, 180, 90} },
                        healing = { {115310, 180, 60} } },
    }

    -- Fallback if class not found
    local FALLBACK = { personal = { {22812, 60, 20} } }

    local function InjectSpells(playerName, classData)
        partyCD[playerName] = partyCD[playerName] or {}
        local function add(spellList)
            if not spellList then return end
            for _, s in ipairs(spellList) do
                partyCD[playerName][s[1]] = {
                    readyTime = now + s[3],
                    effectiveCD = s[2],
                    castTime = now - (s[2] - s[3]),
                }
            end
        end
        add(classData.personal)
        add(classData.healing)
        add(classData.party_ranged)
        add(classData.party_stacked)
    end

    -- Local player: use Druid data
    InjectSpells(localPlayerName, CLASS_TEST.DRUID)
    partyCD[localPlayerName]._spec = "Restoration"

    -- Other party members: get class from UnitClass, use matching test data
    local classPool = { "WARRIOR", "DEATHKNIGHT", "PRIEST", "SHAMAN", "EVOKER", "PALADIN", "DEMONHUNTER" }
    local poolIdx = 1
    for i = 1, 40 do
        local unit = i <= 4 and ("party" .. i) or ("raid" .. i)
        local ok, name = pcall(UnitName, unit)
        if ok and name and name ~= "" and not (issecretvalue and issecretvalue(name)) then
            local short = StripRealm(name)
            if short ~= localPlayerName then
                -- Try real class
                local _, className = pcall(UnitClass, unit)
                if not className or className == "" then
                    className = classPool[((poolIdx - 1) % #classPool) + 1]
                    poolIdx = poolIdx + 1
                end
                className = (className or "WARRIOR"):upper()
                local data = CLASS_TEST[className] or FALLBACK
                InjectSpells(short, data)
                partyCD[short]._spec = className
            end
        end
    end

    local count = 0
    local names = {}
    for n in pairs(partyCD) do count = count + 1; table.insert(names, n) end
    Log:Log("INFO", string.format("CommSync: simulated CDs for %d players: %s", count, table.concat(names, ", ")))

    local PCD = HexCD.PartyCDDisplay
    if PCD then
        if not PCD:IsVisible() then PCD:Show() end
    end
end

--- Clear simulated data.
function CS:ClearSimulation()
    isTestMode = false
    -- Keep local player's data, clear everyone else
    local myData = partyCD[localPlayerName]
    for name in pairs(partyCD) do
        if name ~= localPlayerName then
            partyCD[name] = nil
        end
    end
    Log:Log("INFO", "CommSync: cleared simulated data (kept local player)")
end

--- Prune players no longer in the group.
function CS:PruneStale()
    local inGroup = {}
    inGroup[localPlayerName] = true

    -- Check party units
    for i = 1, 4 do
        local unit = "party" .. i
        local ok, name = pcall(UnitName, unit)
        if ok and name and not (issecretvalue and issecretvalue(name)) then
            inGroup[StripRealm(name)] = true
        end
    end
    -- Check raid units
    for i = 1, 40 do
        local unit = "raid" .. i
        local ok, name = pcall(UnitName, unit)
        if ok and name and not (issecretvalue and issecretvalue(name)) then
            inGroup[StripRealm(name)] = true
        end
    end

    for name in pairs(partyCD) do
        if not inGroup[name] then
            partyCD[name] = nil
            Log:Log("DEBUG", "CommSync: pruned stale player " .. name)
        end
    end
end

------------------------------------------------------------------------
-- Test helpers
------------------------------------------------------------------------

function CS:_testGetState()
    return {
        partyCD = partyCD,
        localPlayerName = localPlayerName,
        localSpec = localSpec,
        commsRegistered = commsRegistered,
        inEncounter = inEncounter,
        inCombat = inCombat,
        inMythicPlus = inMythicPlus,
    }
end

function CS:_testInjectMessage(msg, sender)
    OnAddonMessage(ADDON_MSG_PREFIX, msg, "PARTY", sender or "Test-Realm")
end

function CS:_testReset()
    partyCD = {}
    lastDirectCast = {}
    localPlayerName = StripRealm(UnitName("player") or "Unknown")
    localSpec = nil
end
