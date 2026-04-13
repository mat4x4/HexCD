------------------------------------------------------------------------
-- HexCD: CommSync — Party CD State Manager
--
-- Manages partyCD state (who has what CDs, when they're ready).
-- Detection is handled by:
--   Layer 1: AuraDetector (UNIT_AURA state machine) — primary in M+
--   Layer 2/3: UNIT_SPELLCAST_SUCCEEDED + taint laundering — this file
--   Layer 4: Addon comms (REMOVED — blocked by Midnight 12.0 lockdown)
--
-- Midnight 12.0 blocks SendAddonMessage during M+ keys (entire run)
-- and raid encounters (per-pull). CDHELLO/CDCAST/CDSTATE protocol
-- was removed because it can't deliver messages when needed most.
-- Party discovery uses UnitClass-based ScanAndPopulateParty instead.
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

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local eventFrame = nil
local rosterTimer = nil    -- coalesce rapid GROUP_ROSTER_UPDATE events

-- Party CD state: partyCD[playerName][spellID] = { readyTime, effectiveCD, castTime }
-- partyCD[playerName]._spec = "specName"
local partyCD = {}
local isTestMode = false

local localPlayerName = nil

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

-- Addon comms (CDHELLO/CDCAST/CDSTATE) removed — blocked by Midnight 12.0 lockdown
-- during M+ keys and raid encounters. See project_midnight_addon_comms.md for details.

-- Addon message receive handler removed — see header comment.

------------------------------------------------------------------------
-- Record a local cast into partyCD
------------------------------------------------------------------------

local function RecordLocalCast(spellID, effectiveCD)
    local now = GetTime()
    partyCD[localPlayerName] = partyCD[localPlayerName] or {}
    partyCD[localPlayerName][spellID] = {
        readyTime = now + effectiveCD,
        effectiveCD = effectiveCD,
        castTime = now,
    }
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
        -- Layer 4: addon comms REMOVED (blocked by Midnight 12.0 lockdown)
        local isPartyUnit = HexCD.Util and HexCD.Util.IsOtherGroupMemberUnit
            and HexCD.Util.IsOtherGroupMemberUnit(unit)
            or (unit == "party1" or unit == "party2" or unit == "party3" or unit == "party4")
        if isPartyUnit then
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

                -- Log what laundering produced (once per unique result per unit)
                if cleanID then
                    local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(cleanID)
                    Log:Log("DEBUG", string.format("Layer2+3: %s %s id=%d cat=%s [%s]",
                        unitName, info and info.name or "unknown", cleanID,
                        info and info.category or "untracked", layer))
                    -- Feed the spec cache so spec-exclusive casts back-fill
                    -- the party member's spec ID even without inspect data.
                    if HexCD.SpecCache and HexCD.SpecCache.ObserveCast then
                        HexCD.SpecCache:ObserveCast(unit, cleanID)
                    end
                else
                    return  -- secret + launder failed
                end

                -- Check if this spell is tracked. CD comes from AuraRules
                -- (talent-adjusted when talents are known); SpellDB provides
                -- name/category metadata and fallback CD for non-AuraRules
                -- utility spells (BoF, Stampeding Roar, etc.).
                local info = HexCD.SpellDB and HexCD.SpellDB:GetSpell(cleanID)
                local ADmod = HexCD.AuraDetector
                local rule = ADmod and ADmod.GetRuleBySpellID and ADmod:GetRuleBySpellID(cleanID)
                if not info and not rule then return end

                -- Skip kicks and dispels — dedicated trackers handle them.
                -- Category lives in SpellDB; rule-only entries are never
                -- KICK/DISPEL by construction.
                if info and (info.category == "KICK" or info.category == "DISPEL") then
                    return
                end

                if not partyCD[unitName][cleanID] then return end

                -- Cross-layer dedup: skip if Layer 1 (aura) already recorded this
                if ADmod and ADmod.IsDuplicate and ADmod:IsDuplicate(unitName, cleanID) then
                    Log:Log("DEBUG", string.format("Layer2+3: %s %s(%d) — DEDUP [%s]",
                        unitName, (info and info.name) or "unknown", cleanID, layer))
                    return
                end

                -- Resolve effective CD: AuraRules (talent-adjusted) preferred,
                -- SpellDB static CD as fallback.
                local baseCD = (rule and rule.Cooldown) or (info and info.cd)
                if not baseCD then return end
                local effectiveCD = baseCD
                if rule then
                    local DM = HexCD.DurationModifiers
                    local talents = (HexCD.TalentCache and HexCD.TalentCache.GetTalentsForUnit
                        and HexCD.TalentCache:GetTalentsForUnit(unit)) or {}
                    local classToken = select(2, UnitClass(unit))
                    local specID = HexCD.SpecCache and HexCD.SpecCache.Get
                        and HexCD.SpecCache:Get(unitName) or nil
                    if DM and DM.AdjustCooldown then
                        effectiveCD = DM:AdjustCooldown(classToken, specID, talents,
                            cleanID, baseCD, 0)
                    end
                end

                local now = GetTime()
                partyCD[unitName][cleanID] = {
                    readyTime = now + effectiveCD,
                    effectiveCD = effectiveCD,
                    castTime = now,
                }
                Log:Log("DEBUG", string.format("Layer2+3: %s %s(%d) CD %ds [%s]",
                    unitName, (info and info.name) or "rule", cleanID, effectiveCD, layer))
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

        RecordLocalCast(spellID, info.cd)

    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Coalesce rapid GROUP_ROSTER_UPDATE events (fires many times on group changes)
        CS:PruneStale()
        if not rosterTimer then
            rosterTimer = C_Timer.After(2, function()
                rosterTimer = nil
                ScanAndPopulateParty()
            end)
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Fires after /reload and zone transitions — APIs are fully ready
        -- here. Re-pop both player and party: during the initial load at
        -- ADDON_LOADED, GetSpecialization() may still return nil for the
        -- local player, leaving spec-gated entries ungated. Doing this
        -- again at PLAYER_ENTERING_WORLD (delayed 1s) lets the spec
        -- resolve first, then prune off-spec leaks.
        C_Timer.After(1, function()
            local localName = UnitName("player")
            if localName then
                localName = StripRealm(localName)
                PrePopulatePersonalCDs("player", localName)
                pcall(function() CS:PruneWrongSpec("player", localName) end)
            end
            ScanAndPopulateParty()
        end)
        -- Bootstrap inMythicPlus for /reload mid-key: CHALLENGE_MODE_START
        -- only fires when a key is started, not when PEW occurs inside an
        -- active key. Without this, per-boss ENCOUNTER_END would auto-open
        -- the log mid-run.
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
            local mapID = C_ChallengeMode.GetActiveChallengeMapID() or 0
            if mapID > 0 and not inMythicPlus then
                inMythicPlus = true
                Log:Log("INFO", string.format(
                    "CommSync: /reload detected inside M+ key (mapID=%d) — inMythicPlus=true",
                    mapID))
            end
        end

    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- Local player's spec (re-)resolved — re-pre-pop and prune
        -- previously-created entries that don't match the new spec and
        -- haven't been observed live (readyTime==0 → never cast).
        local unit = ...
        if unit == "player" then
            local localName = GetUnitName("player", false) or UnitName("player")
            if localName then
                PrePopulatePersonalCDs("player", localName)
                pcall(function() CS:PruneWrongSpec("player", localName) end)
            end
        end

    elseif event == "INSPECT_READY" then
        -- Party member's spec data arrived — re-pre-pop and prune
        for i = 1, 4 do
            local uid = "party" .. i
            if UnitExists(uid) then
                local n = UnitName(uid)
                if n and not (issecretvalue and issecretvalue(n)) then
                    n = n:match("^([^-]+)") or n
                    PrePopulatePersonalCDs(uid, n)
                    pcall(function() CS:PruneWrongSpec(uid, n) end)
                end
            end
        end

    elseif event == "ENCOUNTER_START" then
        local encounterID, name = ...
        inEncounter = true
        encounterName = name or ("ID:" .. tostring(encounterID))
        Log:Log("INFO", "CommSync ENCOUNTER_START: " .. encounterName)

    elseif event == "ENCOUNTER_END" then
        inEncounter = false
        Log:Log("INFO", "CommSync ENCOUNTER_END")
        encounterName = ""
        -- Auto-open HexCD debug log after RAID encounters only (dev opt-in).
        -- The `inMythicPlus` flag only flips on CHALLENGE_MODE_START, so
        -- after a /reload mid-key we'd think we're in a raid. Use the
        -- Blizzard API as the authoritative check too — if an M+ key is
        -- currently active, suppress the popup (per-boss ENCOUNTER_END
        -- mid-key would otherwise spam the log frame).
        local activeMapID = 0
        if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
            activeMapID = C_ChallengeMode.GetActiveChallengeMapID() or 0
        end
        local inMPlusNow = inMythicPlus or (activeMapID > 0)
        if not inMPlusNow and Config:Get("autoOpenLog") then
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
--- Resolve the best-available spec ID for a unit. Delegates to SpecCache
--- when available (adds a persistent name-realm cache that survives unit
--- token churn and covers cross-realm members). Falls back to raw API.
local function ResolveUnitSpecID(unitID)
    if HexCD.SpecCache and HexCD.SpecCache.ResolveUnit then
        return HexCD.SpecCache:ResolveUnit(unitID)
    end
    -- Legacy fallback (SpecCache not loaded — should never hit in live addon)
    local specID = nil
    pcall(function()
        if unitID == "player" and GetSpecialization and GetSpecializationInfo then
            local idx = GetSpecialization()
            if idx and idx > 0 then
                local id = GetSpecializationInfo(idx)
                if id and id ~= 0 and not (issecretvalue and issecretvalue(id)) then
                    specID = id
                end
            end
        elseif GetInspectSpecialization then
            local id = GetInspectSpecialization(unitID)
            if id and id ~= 0 and not (issecretvalue and issecretvalue(id)) then
                specID = id
            end
        end
    end)
    return specID
end

PrePopulatePersonalCDs = function(unitID, name)
    pcall(function()
        local unitClass = select(2, UnitClass(unitID))
        if not unitClass or (issecretvalue and issecretvalue(unitClass)) then
            unitClass = UnitClassBase and UnitClassBase(unitID)
        end
        if not unitClass then return end
        unitClass = unitClass:upper()
        local unitSpec = ResolveUnitSpecID(unitID)
        local talents = (HexCD.TalentCache and HexCD.TalentCache.GetTalentsForUnit
            and HexCD.TalentCache:GetTalentsForUnit(unitID)) or {}
        partyCD[name] = partyCD[name] or {}
        -- Stash the class token (e.g. "MONK") so display code can wrap
        -- the name in class color without needing to re-resolve UnitClass
        -- at render time.
        partyCD[name]._class = unitClass
        -- Stash the specID so the display layer can resolve per-spec
        -- categoryOverride (hybrid spells like Avenging Wrath route to
        -- the OFFENSIVE bar for Ret/Prot but the HEALING bar for Holy).
        partyCD[name]._specID = unitSpec
        local count, skippedUtility = 0, 0

        -- Primary source: AuraRules (BySpec + ByClass). Talent-gated rules
        -- are included only when the unit's talent set permits — e.g. Ice
        -- Cold (414659) skipped for Mages without the talent. Deduped by
        -- SpellId so multiple variants of the same spell collapse.
        local AD = HexCD.AuraDetector
        if AD and AD.GetRulesForClassSpec then
            local rules = AD:GetRulesForClassSpec(unitClass, unitSpec, talents)
            for _, rule in ipairs(rules) do
                if not partyCD[name][rule.SpellId] then
                    partyCD[name][rule.SpellId] = {
                        readyTime = 0,
                        effectiveCD = rule.Cooldown,
                        castTime = 0,
                    }
                    count = count + 1
                end
            end
        end

        -- Secondary source: SpellDB UTILITY/HEALING spells that aren't in
        -- AuraRules (BoF, Stampeding Roar, etc.). Spec-gated entries are
        -- only added when we actually know the unit's spec — previously
        -- we fell back to "lenient" pre-pop when spec was unknown, which
        -- populated off-spec spells (e.g. Incarnation: Guardian on a
        -- Resto Druid). PLAYER_SPECIALIZATION_CHANGED /
        -- PLAYER_ENTERING_WORLD / INSPECT_READY re-runs this function
        -- once the spec resolves, so strict gating is safe.
        local DB = HexCD.SpellDB
        if DB and DB.GetAllSpells then
            for spellID, info in pairs(DB:GetAllSpells()) do
                if info.class == unitClass and not partyCD[name][spellID] then
                    local allow = true
                    if info.pvpTalent then
                        -- PvP talents never pre-pop in PvE context.
                        allow = false
                    elseif info.talentOnly then
                        -- Talent-gated: pre-pop only if the unit actually
                        -- has the spell. Layered check:
                        --   (a) local player: Util.PlayerHasSpell — tries
                        --       IsPlayerSpell + IsSpellKnown +
                        --       FindSpellBookSlotBySpellID (catches legacy
                        --       cast IDs that talent-tree traversal misses).
                        --   (b) TalentCache lookup (works for player too,
                        --       needed in tests that set talents directly).
                        allow = false
                        if unitID == "player"
                           and HexCD.Util and HexCD.Util.PlayerHasSpell
                           and HexCD.Util.PlayerHasSpell(spellID) then
                            allow = true
                        elseif talents and talents[spellID] then
                            allow = true
                        end
                        -- Log diagnostic for talentOnly class-tree CCs so a
                        -- user can see why a talent they have isn't showing.
                        if Log and unitID == "player"
                           and info.class == unitClass and not info.specs
                           and info.category == "CC" then
                            Log:Log("DEBUG", string.format(
                                "CommSync: talent check %s (%d, %s) → %s",
                                tostring(info.name), spellID,
                                tostring(info.category),
                                allow and "PASS" or "skip"))
                        end
                    end
                    if allow and info.specs then
                        -- Require known spec to match the list. If spec
                        -- is still nil at this moment, re-pop later will
                        -- pick it up — don't leak off-spec entries now.
                        local specMatch = false
                        if unitSpec then
                            for _, s in ipairs(info.specs) do
                                if s == unitSpec then specMatch = true; break end
                            end
                        end
                        allow = specMatch
                    end
                    if allow and info.cd then
                        partyCD[name][spellID] = {
                            readyTime = 0,
                            effectiveCD = info.cd,
                            castTime = 0,
                        }
                        count = count + 1
                    elseif not allow then
                        skippedUtility = skippedUtility + 1
                    end
                end
            end
        end

        if count > 0 then
            Log:Log("DEBUG", string.format(
                "CommSync: pre-populated %d spells for %s (%s, spec=%s, skipped %d utility-gated)",
                count, name, unitClass, tostring(unitSpec), skippedUtility))
        end
    end)
end

--- Scan all group members (party or raid) and pre-populate their
--- personal CDs. Called on init, GROUP_ROSTER_UPDATE, and
--- PLAYER_ENTERING_WORLD.
ScanAndPopulateParty = function()
    if not HexCD.Util.IsInAnyGroup() then return end

    -- In raids, party1..4 is either empty or partially mirrors raid
    -- members — iterate raid1..40 instead. In a 5-man party, use
    -- party1..4.
    local inRaid = IsInRaid and IsInRaid()
    local prefix = inRaid and "raid" or "party"
    local maxN = inRaid and 40 or 4

    for i = 1, maxN do
        local uid = prefix .. i
        pcall(function()
            if not UnitExists(uid) then return end
            -- Skip ourselves when iterating raid tokens (UnitIsUnit picks
            -- up that raidN == player for whichever slot is us).
            if inRaid and UnitIsUnit and UnitIsUnit(uid, "player") then return end
            local name = UnitName(uid)
            if not name or (issecretvalue and issecretvalue(name)) then return end
            name = StripRealm(name)
            PrePopulatePersonalCDs(uid, name)
            -- Request talent / spec data so INSPECT_READY can prune later.
            if CanInspect and NotifyInspect and CanInspect(uid) then
                pcall(NotifyInspect, uid)
            end
        end)
    end
end

--- Prune entries that were pre-populated without spec knowledge and no
--- longer match the player's now-known spec. Only prunes entries that
--- were never observed live (readyTime == 0 AND castTime == 0).
function CS:PruneWrongSpec(unitID, name)
    local DB = HexCD.SpellDB
    if not DB or not partyCD[name] then return end
    local specID = ResolveUnitSpecID(unitID)
    if not specID then return end

    local pruned = 0
    for spellID, state in pairs(partyCD[name]) do
        if type(spellID) == "number" and type(state) == "table" then
            local info = DB:GetSpell(spellID)
            if info and info.specs then
                local ok = false
                for _, s in ipairs(info.specs) do
                    if s == specID then ok = true; break end
                end
                -- Prune only untouched (pre-pop ghost) entries
                if not ok and (state.readyTime or 0) == 0 and (state.castTime or 0) == 0 then
                    partyCD[name][spellID] = nil
                    pruned = pruned + 1
                end
            elseif info and info.pvpTalent then
                -- Remove leaked pvpTalent entries from legacy pre-pops.
                if (state.readyTime or 0) == 0 and (state.castTime or 0) == 0 then
                    partyCD[name][spellID] = nil
                    pruned = pruned + 1
                end
            elseif info and info.talentOnly then
                -- Prune talentOnly pre-pop entries the unit doesn't actually
                -- have. Same check PrePopulatePersonalCDs uses: local player
                -- via Util.PlayerHasSpell (IsPlayerSpell + fallbacks), party
                -- via TalentCache. Only prune untouched pre-pop ghosts.
                if (state.readyTime or 0) == 0 and (state.castTime or 0) == 0 then
                    local talents = (HexCD.TalentCache and HexCD.TalentCache.GetTalentsForUnit
                        and HexCD.TalentCache:GetTalentsForUnit(unitID)) or {}
                    local has = false
                    if unitID == "player"
                       and HexCD.Util and HexCD.Util.PlayerHasSpell
                       and HexCD.Util.PlayerHasSpell(spellID) then
                        has = true
                    elseif talents[spellID] then
                        has = true
                    end
                    if not has then
                        partyCD[name][spellID] = nil
                        pruned = pruned + 1
                    end
                end
            end
        end
    end
    if pruned > 0 and Log then
        Log:Log("DEBUG", string.format(
            "CommSync: pruned %d off-spec pre-pop entries for %s (spec=%s)",
            pruned, name, tostring(specID)))
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
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ENCOUNTER_START")
    eventFrame:RegisterEvent("ENCOUNTER_END")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("CHALLENGE_MODE_START")
    eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
    eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
    eventFrame:RegisterEvent("INSPECT_READY")

    -- Hook into CooldownTracker for spec-specific CDs (Convoke, Tranq, etc.)
    -- CT already validates the spell is tracked for this spec — no need to
    -- re-check against SpellDB (which may not have spec-specific IDs
    -- like Convoke 391528, etc.)
    local CT = HexCD.CooldownTracker
    if CT then
        CT._onCastCallback = function(spellID, state)
            if state then
                RecordLocalCast(spellID, state.effectiveCD)
            end
        end
    end

    -- Pre-populate local player's personal CDs as "ready" so icons show immediately
    PrePopulatePersonalCDs("player", localPlayerName)

    -- Scan party members and pre-populate their personal CDs too
    -- (works even without CDHELLO — discovers class from UnitClass)
    ScanAndPopulateParty()

    Log:Log("INFO", "CommSync: initialized (local detection, no addon comms)")
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
    partyCD[localPlayerName]._class = "DRUID"

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
                partyCD[short]._class = className
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
        inEncounter = inEncounter,
        inCombat = inCombat,
        inMythicPlus = inMythicPlus,
    }
end

function CS:_testReset()
    partyCD = {}
    lastDirectCast = {}
    localPlayerName = StripRealm(UnitName("player") or "Unknown")
end

-- Expose PrePopulatePersonalCDs so tests can verify the pre-pop/prune
-- cycle converges (regression for the WW Monk pre-pop/prune ping-pong
-- where AuraRules.ByClass[MONK] re-added 115203 every cycle).
function CS:_testPrePopulate(unitID, name)
    return PrePopulatePersonalCDs(unitID, name)
end
