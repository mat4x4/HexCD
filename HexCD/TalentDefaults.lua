------------------------------------------------------------------------
-- HexCD: TalentDefaults — assumed talent ranks when inspect data is absent
--
-- Ported from MiniCC/Modules/FriendlyCooldowns/Talents.lua:259-344.
-- These are talents nearly every PvE build of a class/spec takes, so when
-- we can't inspect a unit (cross-realm, INSPECT_READY hasn't fired yet),
-- we assume they're present. This gates RequiresTalent rules on canonical
-- builds so they still activate without live inspect data.
--
-- ONLY PvE defaults. PvP talents are out of scope for this plan.
--
-- When live talent data arrives via INSPECT_READY or PLAYER_TALENT_UPDATE,
-- it replaces the default set entirely — see TalentCache:_source tag.
------------------------------------------------------------------------

HexCD = HexCD or {}

HexCD.TalentDefaults = HexCD.TalentDefaults or {}
local TD = HexCD.TalentDefaults

-- { [classToken] = { [talentSpellID] = rank } }
TD.ClassDefaultTalentRanks = {
    DEATHKNIGHT = {
        [205727] = 1,   -- Anti-Magic Barrier (AMS -20s cd, +40% duration)
    },
    HUNTER = {
        [1258485] = 1,  -- Improved Aspect of the Turtle (Turtle -30s)
    },
    MAGE = {
        [382424]  = 2,  -- Winter's Protection (Ice Block / Ice Cold -60s rank 2)
        [1265517] = 1,  -- Permafrost Bauble (Ice Block / Ice Cold -30s)
    },
    MONK = {
        [388813] = 1,   -- Expeditious Fortification (Fortifying Brew CDR)
    },
    PALADIN = {
        [114154] = 1,   -- Unbreakable Spirit (Bubble/DP/Ardent Defender -30%)
    },
    SHAMAN = {
        [381647] = 1,   -- Planes Traveler (Astral Shift -30s)
    },
    WARRIOR = {
        [107574] = 1,   -- Avatar (all specs)
        [184364] = 1,   -- Enraged Regeneration (Fury)
    },
}

-- { [specID] = { [talentSpellID] = rank } }
TD.SpecDefaultTalentRanks = {
    [102] = {  -- Balance Druid
        [468743] = 1,   -- Whirling Stars (Incarnation -60s)
    },
    [254] = {  -- Marksmanship Hunter
        [260404] = 1,   -- Calling the Shots (Trueshot -30s)
    },
    [103] = {  -- Feral Druid
        [102543] = 1,   -- Incarnation: Avatar of Ashamane
        [391174] = 1,   -- Berserk: Heart of the Lion
        [391548] = 1,   -- Ashamane's Guidance
    },
    [63]  = {  -- Fire Mage
        [1254194] = 1,  -- Kindling (Combustion -60s)
    },
    [257] = {  -- Holy Priest
        [419110] = 1,   -- Seraphic Crescendo
        [440738] = 1,   -- Foreseen Circumstances (Guardian Spirit +2s)
    },
    [105] = {  -- Restoration Druid
        [382552] = 1,   -- Improved Ironbark (Ironbark -20s)
    },
    [258] = {  -- Shadow Priest
        [288733] = 1,   -- Intangibility (Dispersion -30s)
    },
    [270] = {  -- Mistweaver Monk
        [202424] = 1,   -- Chrysalis (Life Cocoon -45s)
    },
    [1468] = { -- Preservation Evoker
        [376204] = 1,   -- Just in Time (Time Dilation -10s)
    },
    [65]  = {  -- Holy Paladin
        [384820] = 1,   -- Sacrifice of the Just (BoSac -15s)
        [216331] = 1,   -- Avenging Crusader (replaces AW, nearly universal)
    },
    [66]  = {  -- Protection Paladin
        [384820] = 1,   -- Sacrifice of the Just (BoSac -60s)
    },
    [70]  = {  -- Retribution Paladin
        [458359] = 1,   -- Radiant Glory
        [384820] = 1,   -- Sacrifice of the Just (BoSac -60s)
    },
    [72]  = {  -- Fury Warrior
        [383468] = 1,   -- Invigorating Fury (Enraged Regen +3s)
    },
    [262] = {  -- Elemental Shaman
        [114050] = 1,   -- Ascendance
        [462440] = 1,   -- First Ascendant (Ascendance -60s)
        [462443] = 1,   -- Preeminence (Ascendance +3s)
    },
    [264] = {  -- Restoration Shaman
        [114052] = 1,   -- Ascendance
        [462440] = 1,   -- First Ascendant (Ascendance -60s)
    },
    [263] = {  -- Enhancement Shaman
        [384352] = 1,   -- Doomwinds
        [384444] = 1,   -- Thorim's Invocation
    },
}

--- Compose the default talent set for a class+spec. Spec defaults overlay
--- class defaults. Both args optional; returns `{[spellID]=rank}`.
function TD:Compose(classToken, specID)
    local out = {}
    if classToken and TD.ClassDefaultTalentRanks[classToken] then
        for id, rank in pairs(TD.ClassDefaultTalentRanks[classToken]) do
            out[id] = rank
        end
    end
    if specID and TD.SpecDefaultTalentRanks[specID] then
        for id, rank in pairs(TD.SpecDefaultTalentRanks[specID]) do
            out[id] = rank
        end
    end
    return out
end
