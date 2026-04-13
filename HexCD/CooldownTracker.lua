-- CooldownTracker.lua — Track player healing CD usage and estimate availability
--
-- Midnight (12.0) removed COMBAT_LOG_EVENT_UNFILTERED and may secret-value
-- C_Spell.GetSpellCooldown during combat. This module self-tracks CD usage:
--
-- Primary: UNIT_SPELLCAST_SUCCEEDED on "player" — fires when you cast a spell
-- Fallback: /hexcd cast <name> macro prefix — manual event injection
--
-- The tracker maintains internal timers: when a tracked spell is cast,
-- it records the time and estimates when it will be ready again based on
-- known base cooldown durations.

local Log = HexCD.DebugLog

local CT = {}
HexCD.CooldownTracker = CT

-- ============================================================
-- Tracked spell cooldowns per spec (spellID → base CD in seconds)
-- ============================================================

-- Aliases: alternate spell IDs that map to a canonical ID.
-- When the alias fires, we treat it as the canonical spell.
local SPELL_ALIASES = {
    [157982] = 740,  -- Tranquility alternate ID → canonical 740
}

local SPEC_CDS = {
    ["Druid:Restoration"] = {
        [391528] = { name = "Convoke the Spirits", cd = 120 },  -- 120s base; Cenarius' Guidance talent reduces to 60s (handled via DurationModifiers on live-player detection)
        [740]    = { name = "Tranquility",         cd = 180 },
        [33891]  = { name = "Incarnation: ToL",    cd = 180 },
        -- Nature's Swiftness (132158) removed — it's a cast-time modifier,
        -- not a healing throughput CD worth tracking on the healing bar.
    },
    ["Evoker:Preservation"] = {
        [363534] = { name = "Rewind",          cd = 240 },
        [359816] = { name = "Dream Flight",    cd = 120 },
        [374227] = { name = "Zephyr",          cd = 120 },
        [370553] = { name = "Tip the Scales",  cd = 120 },
        [357170] = { name = "Time Dilation",   cd = 60 },
        [370562] = { name = "Stasis",          cd = 90 },
    },
}

-- Active CD table — reassigned by SetSpec(). Defaults to Resto Druid.
local TRACKED_CDS = SPEC_CDS["Druid:Restoration"]

-- State: spellID → { lastCastTime, readyTime }
local cdState = {}

-- Debounce: ignore duplicate UNIT_SPELLCAST_SUCCEEDED within N seconds
-- (channeled spells like Tranquility fire on every tick)
local DEBOUNCE_WINDOW = 5.0  -- Tranquility channels for ~4s, ticks fire SUCCEEDED each time
local lastCastTimestamp = {} -- spellID → GetTime() of last accepted cast

-- Whether UNIT_SPELLCAST_SUCCEEDED is working (set to false if we detect it's blocked)
local spellcastEventWorks = true
local spellcastDetected = false  -- flips true on first UNIT_SPELLCAST_SUCCEEDED

-- ============================================================
-- Spec Switching
-- ============================================================

--- Switch tracked CDs to match the player's current spec.
--- Resets CD state since spell IDs change between specs.
---@param className string e.g. "DRUID" or "Druid"
---@param specName string e.g. "Restoration" or "Preservation"
function CT:SetSpec(className, specName)
    local Util = HexCD.Util
    local normalized = Util.NormalizeClassName(className)
    local key = normalized .. ":" .. specName

    local newCDs = SPEC_CDS[key]
    if newCDs then
        TRACKED_CDS = newCDs
        Log:Log("INFO", string.format("CooldownTracker: Switched to %s — %d tracked CDs", key, CT:CountTrackedCDs()))
    else
        Log:Log("WARN", string.format("CooldownTracker: No CD table for '%s' — tracker inactive", key))
        TRACKED_CDS = {}
    end

    -- Reset state — old spell IDs are no longer relevant
    wipe(cdState)
    wipe(lastCastTimestamp)
end

--- Get the active TRACKED_CDS table (for external consumers like MythicPlusEngine).
---@return table spellID → { name, cd }
function CT:GetTrackedCDs()
    return TRACKED_CDS
end

--- Get all spec CD tables (for plan validation).
---@return table SPEC_CDS
function CT:GetAllSpecCDs()
    return SPEC_CDS
end

--- Get spell alias table.
---@return table SPELL_ALIASES
function CT:GetAliases()
    return SPELL_ALIASES
end

--- Count entries in the active tracked CDs table.
---@return number
function CT:CountTrackedCDs()
    local n = 0
    for _ in pairs(TRACKED_CDS) do n = n + 1 end
    return n
end

-- ============================================================
-- Core Logic
-- ============================================================

--- Record that a tracked spell was cast.
---@param spellID number
---@param source string "event" or "macro"
function CT:OnSpellCast(spellID, source)
    source = source or "unknown"

    -- Resolve aliases to canonical spell ID
    spellID = SPELL_ALIASES[spellID] or spellID

    local info = TRACKED_CDS[spellID]
    if not info then return end

    local now = GetTime()

    -- Debounce: channeled spells (Tranquility) fire UNIT_SPELLCAST_SUCCEEDED
    -- on every tick. Ignore if we already recorded a cast within DEBOUNCE_WINDOW.
    if lastCastTimestamp[spellID] and (now - lastCastTimestamp[spellID]) < DEBOUNCE_WINDOW then
        Log:Log("TRACE", string.format("CooldownTracker: debounced %s (%.1fs since last)",
            info.name, now - lastCastTimestamp[spellID]))
        return
    end
    lastCastTimestamp[spellID] = now

    local actualCD = info.cd -- default to base CD

    -- Try to read actual CD from the game API.
    -- In Midnight (12.0), cdInfo.duration is a Secret Value that cannot be compared
    -- or used in arithmetic. We wrap the entire access in pcall to handle this gracefully.
    local apiCD = nil
    pcall(function()
        if C_Spell and C_Spell.GetSpellCooldown then
            local cdInfo = C_Spell.GetSpellCooldown(spellID)
            if cdInfo and cdInfo.duration then
                -- This comparison may throw if duration is a secret value
                if cdInfo.duration > 0 then
                    apiCD = cdInfo.duration
                end
            end
        end
    end)
    if apiCD then
        actualCD = apiCD
        Log:Log("DEBUG", string.format(
            "CooldownTracker: C_Spell.GetSpellCooldown returned %.1fs for %s (base=%ds)",
            actualCD, info.name, info.cd))
    else
        -- Talent-based CD adjustment via DurationModifiers — catches static
        -- reductions like Cenarius' Guidance (-50% Convoke) on the FIRST cast,
        -- before we have any observed-interval data to learn from. Uses
        -- TalentCache for the local player.
        local DM = HexCD.DurationModifiers
        local TC = HexCD.TalentCache
        if DM and TC and UnitClass and GetSpecialization then
            local _, classToken = UnitClass("player")
            local specIdx = GetSpecialization()
            local specID = nil
            if specIdx and GetSpecializationInfo then
                specID = select(1, GetSpecializationInfo(specIdx))
            end
            local talents = TC.GetTalentsForUnit and TC:GetTalentsForUnit("player") or nil
            if classToken and talents then
                local adjusted = DM:AdjustCooldown(classToken, specID, talents, spellID, info.cd, nil)
                if adjusted and adjusted < info.cd then
                    actualCD = adjusted
                    Log:Log("DEBUG", string.format(
                        "CooldownTracker: talent-adjusted CD for %s = %ds via DurationModifiers (base=%ds)",
                        info.name, actualCD, info.cd))
                end
            end
        end

        -- Heuristic: if we've seen this spell before, check if haste reduced the CD.
        -- Observed interval is always >= actual CD (player may hold the spell),
        -- so it can only tell us the CD is *shorter* than base, never longer.
        -- Use `actualCD` (post-talent-adjust) as the baseline for learning so
        -- haste further reducing a talent-reduced CD is still caught.
        local prev = cdState[spellID]
        if prev and prev.lastCastTime then
            local observed = now - prev.lastCastTime
            -- Only learn if observed < current and > 50% current (sanity)
            if observed > actualCD * 0.5 and observed < actualCD then
                actualCD = math.floor(observed + 0.5)
                Log:Log("DEBUG", string.format(
                    "CooldownTracker: learned CD for %s = %ds (haste-reduced, base=%ds)",
                    info.name, actualCD, info.cd))
            end
        end
    end

    cdState[spellID] = {
        lastCastTime = now,
        readyTime = now + actualCD,
        effectiveCD = actualCD,
    }

    Log:Log("DEBUG", string.format(
        "CooldownTracker: %s (id=%d) cast via %s — ready in %ds @ %.1f%s",
        info.name, spellID, source, actualCD, cdState[spellID].readyTime,
        actualCD ~= info.cd and string.format(" (modified from base %ds)", info.cd) or ""
    ))

    -- Logged to persistent fight log (viewable via /hexcd log after key)
    Log:Log("INFO", string.format("CD CAST: %s — %ds cooldown", info.name, actualCD))

    -- Notify external listeners (CommSync)
    if CT._onCastCallback then
        CT._onCastCallback(spellID, cdState[spellID])
    end
end

--- Check if a tracked spell is estimated to be ready.
---@param spellID number
---@return boolean ready
---@return number remainingSec (0 if ready)
function CT:IsReady(spellID)
    local state = cdState[spellID]
    if not state then return true, 0 end -- never tracked = assume ready

    local now = GetTime()
    if now >= state.readyTime then
        return true, 0
    end
    return false, state.readyTime - now
end

--- Get time until a spell is ready (0 if ready now)
---@param spellID number
---@return number seconds
function CT:GetRemaining(spellID)
    local _, remaining = self:IsReady(spellID)
    return remaining
end

--- Check if UNIT_SPELLCAST_SUCCEEDED is working
---@return boolean
function CT:IsEventTracking()
    return spellcastEventWorks and spellcastDetected
end

--- Reset all tracking state (key end, wipe, etc)
function CT:Reset()
    wipe(cdState)
    wipe(lastCastTimestamp)
    Log:Log("DEBUG", "CooldownTracker: Reset all CD state")
end

--- Dump current CD state to debug log
function CT:DumpState()
    local now = GetTime()
    Log:Log("INFO", "CooldownTracker state:")
    Log:Log("INFO", string.format("  UNIT_SPELLCAST_SUCCEEDED: %s (detected=%s)",
        spellcastEventWorks and "enabled" or "BLOCKED",
        spellcastDetected and "yes" or "NO — cast a healing CD to test"))

    local anyTracked = false
    for spellID, info in pairs(TRACKED_CDS) do
        local state = cdState[spellID]
        if state then
            anyTracked = true
            local remaining = math.max(0, state.readyTime - now)
            local cdNote = ""
            if state.effectiveCD and state.effectiveCD ~= info.cd then
                cdNote = string.format(" [effective=%ds, base=%ds]", state.effectiveCD, info.cd)
            end
            Log:Log("INFO", string.format("  [%d] %s: %s (%.1fs remaining)%s",
                spellID, info.name,
                remaining <= 0 and "|cFF00FF00READY|r" or "|cFFFF0000ON CD|r",
                remaining, cdNote))
        end
    end
    if not anyTracked then
        Log:Log("INFO", "  (no CDs tracked yet — cast something to start tracking)")
    end
end

-- ============================================================
-- Event Frame
-- ============================================================
local frame = CreateFrame("Frame", "HexCDCooldownTrackerFrame")

frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:SetScript("OnEvent", function(self, event, unit, castGUID, spellID)
    if event == "UNIT_SPELLCAST_SUCCEEDED" and unit == "player" then
        -- Mark that the event works (first detection)
        if not spellcastDetected then
            spellcastDetected = true
            Log:Log("INFO", "CooldownTracker: UNIT_SPELLCAST_SUCCEEDED is working! Auto-tracking CDs.")
        end

        -- Only track our known healing CDs (resolve aliases first)
        local canonical = SPELL_ALIASES[spellID] or spellID
        if TRACKED_CDS[canonical] then
            CT:OnSpellCast(spellID, "event")
        end
    end
end)

--- Manual cast notification — called from /hexcd cast macros
--- Usage in macro: /run HexCD.CooldownTracker:OnManualCast(391528)
---@param spellID number
function CT:OnManualCast(spellID)
    CT:OnSpellCast(spellID, "macro")
end

-- ============================================================
-- Macro Generation Helper
-- ============================================================

--- Generate macro text for a tracked CD.
--- The macro casts the spell AND notifies the tracker.
---@param spellID number
---@return string|nil macroText, string|nil spellName
function CT:GenerateMacro(spellID)
    local info = TRACKED_CDS[spellID]
    if not info then return nil, nil end

    local macro = string.format(
        "#showtooltip %s\n/cast %s\n/run HexCD.CooldownTracker:OnManualCast(%d)",
        info.name, info.name, spellID
    )
    return macro, info.name
end

--- Print all trackable macros to chat
function CT:PrintMacros()
    print("|cFF00CCFF[HexCD]|r CD Tracking macros (use if auto-detection fails):")
    print("|cFF00CCFF[HexCD]|r Create these macros in WoW and bind them to your CD keys:")
    local sorted = {}
    for spellID, info in pairs(TRACKED_CDS) do
        table.insert(sorted, { id = spellID, name = info.name })
    end
    table.sort(sorted, function(a, b) return a.name < b.name end)
    for _, entry in ipairs(sorted) do
        print(string.format("  |cFFFFCC00%s|r:", entry.name))
        print(string.format("    #showtooltip %s", entry.name))
        print(string.format("    /cast %s", entry.name))
        print(string.format("    /run HexCD.CooldownTracker:OnManualCast(%d)", entry.id))
    end
end
