------------------------------------------------------------------------
-- HexCD: DurationModifiers — talent-driven duration + cooldown adjustments
--
-- Ported from MiniCC/Modules/FriendlyCooldowns/Talents.lua:30-254.
-- Tables are keyed by talent spell ID; each entry lists the buffs the
-- talent modifies, additively (seconds) or multiplicatively (% of base).
--
-- Structure:
--   [talentSpellId] = { {rank1_mods}, {rank2_mods}, ... }
--   Each mod: { SpellId = affectedSpellId, Amount = number [, Mult = true] [, PostBuff = true] }
--
--   Additive:  value = value + Amount
--   Mult:      value = value + (baseValue * Amount / 100)
--   PostBuff:  sets remaining CD after buff expires to Amount (cooldown only)
--
-- Functions:
--   HexCD.DurationModifiers:AdjustDuration(classToken, specID, talentSet, abilityID, baseDuration)
--   HexCD.DurationModifiers:AdjustCooldown(classToken, specID, talentSet, abilityID, baseCooldown, measuredDuration)
--
-- PvE only — PvP-only modifier entries omitted.
------------------------------------------------------------------------

HexCD = HexCD or {}
HexCD.DurationModifiers = HexCD.DurationModifiers or {}
local DM = HexCD.DurationModifiers

------------------------------------------------------------------------
-- Cooldown modifiers (reduce/extend spell CD based on talents)
------------------------------------------------------------------------

DM.ClassCooldownModifiers = {
    DEATHKNIGHT = {
        [205727] = { { { SpellId = 48707,  Amount = -20 } } },           -- Anti-Magic Barrier
        [457574] = { { { SpellId = 48707,  Amount =  20 } } },           -- (talent that increases AMS CD)
    },
    HUNTER = {
        [1258485] = { { { SpellId = 186265, Amount = -30 } } },          -- Improved Aspect of the Turtle
        [266921]  = {
            { { SpellId = 186265, Amount = -15 } },
            { { SpellId = 186265, Amount = -30 } },
        },
    },
    MAGE = {
        [382424] = {                                                     -- Winter's Protection
            { { SpellId = 45438, Amount = -30 }, { SpellId = 414659, Amount = -30 } },
            { { SpellId = 45438, Amount = -60 }, { SpellId = 414659, Amount = -60 } },
        },
        [1265517] = { { { SpellId = 45438, Amount = -30 }, { SpellId = 414659, Amount = -30 } } }, -- Permafrost Bauble
        [1255166] = { { { SpellId = 342245, Amount = -10 } } },          -- Alter Time CDR
    },
    PALADIN = {
        [384909] = { { { SpellId = 1022,   Amount = -60 }, { SpellId = 204018, Amount = -60 } } },  -- Blessed Protector
        [114154] = {                                                     -- Unbreakable Spirit: -30% on Bubble/DP/AD
            {
                { SpellId = 642,    Amount = -30, Mult = true },
                { SpellId = 498,    Amount = -30, Mult = true },
                { SpellId = 31850,  Amount = -30, Mult = true },
                { SpellId = 403876, Amount = -30, Mult = true },
            },
        },
    },
    SHAMAN  = { [381647] = { { { SpellId = 108271, Amount = -30 } } } },  -- Planes Traveler
    WARLOCK = { [386659] = { { { SpellId = 104773, Amount = -45 } } } },  -- Dark Accord
    WARRIOR = {
        [391271] = { { { SpellId = 118038, Amount = -10, Mult = true } } },  -- Honed Reflexes
    },
}

DM.SpecCooldownModifiers = {
    [581] = { [389732] = { { { SpellId = 204021, Amount = -12 } } } },    -- Vengeance DH: Fiery Brand
    [102] = {                                                             -- Balance Druid
        [468743] = { { { SpellId = 102560, Amount = -60 } } },            -- Whirling Stars
        [390378] = { { { SpellId = 102560, Amount = -60 } } },            -- Orbital Strike
    },
    [103] = {                                                             -- Feral Druid
        [391174] = { { { SpellId = 102543, Amount = -60 }, { SpellId = 106951, Amount = -60 } } },
        [391548] = { { { SpellId = 102543, Amount = -30 }, { SpellId = 106951, Amount = -30 } } },
    },
    [105]  = {                                                             -- Restoration Druid
        [382552] = { { { SpellId = 102342, Amount = -20 } } },              -- Improved Ironbark
        [393371] = { { { SpellId = 391528, Amount = -50, Mult = true } } }, -- Cenarius' Guidance: -50% Convoke CD (120s → 60s)
    },
    [1468] = { [376204] = { { { SpellId = 357170, Amount = -10 } } } },   -- Preservation: Just in Time
    [1473] = { [412713] = { { { SpellId = 363916, Amount = -10, Mult = true } } } }, -- Aug: Obsidian Scales
    [254]  = { [260404] = { { { SpellId = 288613, Amount = -30 } } } },   -- MM Hunter: Calling the Shots
    [255]  = { [1251790] = {                                              -- Survival Hunter
        { { SpellId = 1250646, Amount = -15 } },
        { { SpellId = 1250646, Amount = -30 } },
    } },
    [63]   = { [1254194] = { { { SpellId = 190319, Amount = -60 } } } },  -- Fire Mage: Kindling
    [268]  = {                                                            -- Brewmaster Monk
        [450989] = { { { SpellId = 132578, Amount = -25  } } },
        [388813] = { { { SpellId = 115203, Amount = -120 } } },
    },
    [269]  = { [388813] = { { { SpellId = 115203, Amount = -30 } } } },   -- Windwalker Monk
    [270]  = {                                                            -- Mistweaver Monk
        [202424] = { { { SpellId = 116849, Amount = -45 } } },
        [388813] = { { { SpellId = 115203, Amount = -30 } } },
    },
    [257]  = {                                                            -- Holy Priest
        [419110] = { { { SpellId = 64843,  Amount = -60 } } },
        [200209] = { { { SpellId = 47788,  Amount =  60, PostBuff = true } } },  -- Guardian Angel
    },
    [66] = {                                                              -- Prot Pala
        [384820] = { { { SpellId = 6940,  Amount = -60 } } },             -- Sacrifice of the Just
        [378425] = { {                                                    -- Aegis of Light
            { SpellId = 642,    Amount = -15, Mult = true },
            { SpellId = 1022,   Amount = -15, Mult = true },
            { SpellId = 204018, Amount = -15, Mult = true },
        } },
        [204074] = { {                                                    -- Righteous Protector
            { SpellId = 31884,  Amount = -50, Mult = true },
            { SpellId = 389539, Amount = -50, Mult = true },
        } },
    },
    [65] = {                                                              -- Holy Pala
        [384820]  = { { { SpellId = 6940, Amount = -15 } } },             -- SotJ (Holy)
        [1241511] = {                                                     -- Call of the Righteous
            { { SpellId = 31884, Amount = -15  }, { SpellId = 216331, Amount = -7.5 } },
            { { SpellId = 31884, Amount = -30  }, { SpellId = 216331, Amount = -15  } },
        },
    },
    [70]  = { [384820] = { { { SpellId = 6940,   Amount = -60 } } } },    -- Ret Pala: SotJ
    [258] = { [288733] = { { { SpellId = 47585,  Amount = -30 } } } },    -- Shadow: Intangibility
    [73]  = { [397103] = { { { SpellId = 871,    Amount = -60 } } } },    -- Prot Warrior: Shield Wall
    [263] = { [384444] = { { { SpellId = 114051, Amount = -60 } } } },    -- Enh: Thorim's Invocation
    [262] = { [462440] = { { { SpellId = 114050, Amount = -60 } } } },    -- Ele: First Ascendant
    [264] = { [462440] = { { { SpellId = 114052, Amount = -60 } } } },    -- Resto: First Ascendant
}

------------------------------------------------------------------------
-- Duration modifiers (extend/shorten buff duration based on talents)
------------------------------------------------------------------------

DM.ClassDurationModifiers = {
    DEATHKNIGHT = { [205727] = { { { SpellId = 48707,  Amount = 40, Mult = true } } } },  -- AMS +40%
    DRUID       = { [327993] = { { { SpellId = 22812,  Amount = 4 } } } },                -- Improved Barkskin
    HUNTER      = { [388039] = { { { SpellId = 264735, Amount = 2 } } } },                -- Survival of the Fittest
}

DM.SpecDurationModifiers = {
    [66]  = { [204074] = { {                                              -- Righteous Protector
        { SpellId = 31884,  Amount = -40, Mult = true },
        { SpellId = 389539, Amount = -40, Mult = true },
    } } },
    [250] = { [317133] = {                                                -- Blood DK: Vampiric Blood
        { { SpellId = 55233, Amount = 2 } },
        { { SpellId = 55233, Amount = 4 } },
    } },
    [255]  = { [1253830] = { { { SpellId = 1250646, Amount = 2 } } } },   -- Survival: Takedown
    [72]   = { [383468]  = { { { SpellId = 184364,  Amount = 3 } } } },   -- Fury: Invigorating Fury
    [581]  = { [1265818] = { { { SpellId = 187827,  Amount = 5 } } } },   -- Vengeance: Vengeful Beast
    [263]  = { [384444]  = { { { SpellId = 384352,  Amount = 2 } } } },   -- Enh: Thorim's Invocation
    [262]  = { [462443]  = { { { SpellId = 114050,  Amount = 3 } } } },   -- Ele: Preeminence
    [257]  = { [440738]  = { { { SpellId = 47788,   Amount = 2 } } } },   -- Holy: Foreseen Circumstances
}

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Accumulate add/mult/postBuff deltas from one modifier table.
local function accumulate(modTable, talentSet, abilityID, out)
    if not modTable then return end
    for talentSpellId, rankList in pairs(modTable) do
        local rank = talentSet[talentSpellId]
        -- Accept rank as bool (legacy) or number
        local r
        if rank == true then r = 1
        elseif type(rank) == "number" and rank > 0 then r = rank
        else r = nil end
        if r then
            local mods = rankList[r]
            if mods then
                for _, mod in ipairs(mods) do
                    if mod.SpellId == abilityID then
                        if mod.PostBuff then
                            out.postBuff = mod.Amount
                        elseif mod.Mult then
                            out.mult = out.mult + mod.Amount
                        else
                            out.add = out.add + mod.Amount
                        end
                    end
                end
            end
        end
    end
end

--- Return talent-adjusted buff duration.
function DM:AdjustDuration(classToken, specID, talentSet, abilityID, baseDuration)
    if not talentSet or not baseDuration then return baseDuration end
    local acc = { add = 0, mult = 0 }
    accumulate(DM.ClassDurationModifiers[classToken], talentSet, abilityID, acc)
    accumulate(specID and DM.SpecDurationModifiers[specID], talentSet, abilityID, acc)
    return math.max(baseDuration + acc.add + (baseDuration * acc.mult / 100), 0)
end

--- Return talent-adjusted cooldown. `measuredDuration` used by PostBuff
--- talents which set the remaining CD after the buff expires.
function DM:AdjustCooldown(classToken, specID, talentSet, abilityID, baseCooldown, measuredDuration)
    if not talentSet or not baseCooldown then return baseCooldown end
    local acc = { add = 0, mult = 0, postBuff = nil }
    accumulate(DM.ClassCooldownModifiers[classToken], talentSet, abilityID, acc)
    accumulate(specID and DM.SpecCooldownModifiers[specID], talentSet, abilityID, acc)
    if acc.postBuff then
        return math.max((measuredDuration or 0) + acc.postBuff, 0)
    end
    return math.max(baseCooldown + acc.add + (baseCooldown * acc.mult / 100), 0)
end
