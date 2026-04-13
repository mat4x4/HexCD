------------------------------------------------------------------------
-- HexCD: AuraRules — party defensive detection rule database
--
-- Ported from MiniCC v3.4.0 (Modules/FriendlyCooldowns/Rules.lua)
-- Source: https://www.curseforge.com/wow/addons/minicc
-- Ported: 2026-04-11
--
-- Rule data is factual game information (spell IDs, buff durations,
-- cooldowns). We retain MiniCC's trailing comments for each rule to
-- document the spell name and any talent/variant notes.
--
-- Normalizations applied during port:
--   - MiniCC "UnitFlags" evidence → HexCD "Flags" (matches existing HexCD convention)
--   - MiniCC "MinCancelDuration" dropped (not yet supported in HexCD; only 1 rule affected)
--
-- Spec ID reference:
--   Paladin:       Holy=65, Prot=66, Ret=70
--   Warrior:       Arms=71, Fury=72, Prot=73
--   Mage:          Arcane=62, Fire=63, Frost=64
--   Hunter:        BM=253, MM=254, Surv=255
--   Priest:        Disc=256, Holy=257, Shadow=258
--   Rogue:         Assn=259, Outlaw=260, Sub=261
--   Death Knight:  Blood=250, Frost=251, Unholy=252
--   Shaman:        Elem=262, Enh=263, Resto=264
--   Warlock:       Afflic=265, Demo=266, Dest=267
--   Monk:          Brew=268, WW=269, MW=270
--   Demon Hunter:  Havoc=577, Venge=581, Devourer=1480
--   Druid:         Bal=102, Feral=103, Guard=104, Resto=105
--   Evoker:        Devas=1467, Preserv=1468, Aug=1473
------------------------------------------------------------------------
HexCD = HexCD or {}

HexCD.AuraRules = {
    BySpec = {
        [65] = { -- Holy Paladin
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 31821,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Aura Mastery (raid CD — caster + group get buff 31821)
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 31884,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, ExcludeIfTalent = 216331,
            }, -- Avenging Wrath (hidden if Avenging Crusader talented)
            {
                BuffDuration = 10, Cooldown = 60, SpellId = 216331,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 216331,
            }, -- Avenging Crusader
            {
                BuffDuration = 8, Cooldown = 300, SpellId = 642,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = { "Cast", "Flags" }, CanCancelEarly = true,
            }, -- Divine Shield
            {
                BuffDuration = 8, Cooldown = 60, SpellId = 498,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Divine Protection
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 204018,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                RequiresTalent = 5692,
            }, -- Blessing of Spellwarding (replaces BoP)
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 1022,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                ExcludeIfTalent = 5692,
            }, -- Blessing of Protection
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 6940,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Blessing of Sacrifice
            {
                BuffDuration = 20, Cooldown = 180, SpellId = 105809,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 105809,
            }, -- Holy Avenger (class-tree talent; 3x Holy Power = healing burst on Holy)
        },
        [66] = { -- Protection Paladin
            {
                BuffDuration = 25, Cooldown = 120, SpellId = 31884,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                MinDuration = true, RequiresEvidence = "Cast", ExcludeIfTalent = 389539,
            }, -- Avenging Wrath (hidden if Sentinel talented)
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 389539,
                BigDefensive = true, ExternalDefensive = false, Important = false,
                MinDuration = true, RequiresEvidence = "Cast",
                RequiresTalent = 389539, ExcludeIfTalent = 31884,
            }, -- Sentinel — 30% DR + 15% max HP via stacks; tank defensive, not offensive
            {
                BuffDuration = 8, Cooldown = 300, SpellId = 642,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = { "Cast", "Flags" }, CanCancelEarly = true,
            }, -- Divine Shield
            {
                BuffDuration = 8, Cooldown = 90, SpellId = 31850,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Ardent Defender
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 86659,
                BigDefensive = true, Important = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Guardian of Ancient Kings
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 204018,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                RequiresTalent = 5692,
            }, -- Blessing of Spellwarding
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 1022,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                ExcludeIfTalent = 5692,
            }, -- Blessing of Protection
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 6940,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Blessing of Sacrifice
            {
                BuffDuration = 20, Cooldown = 180, SpellId = 105809,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 105809,
            }, -- Holy Avenger (class-tree talent; 3x Holy Power = shield spam on Prot)
        },
        [70] = { -- Retribution Paladin
            {
                BuffDuration = 24, Cooldown = 60, SpellId = 31884,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", ExcludeIfTalent = 458359,
            }, -- Avenging Wrath (hidden if Radiant Glory talented)
            {
                BuffDuration = 8, Cooldown = 300, SpellId = 642,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = { "Cast", "Flags" }, CanCancelEarly = true,
            }, -- Divine Shield
            {
                BuffDuration = 8, Cooldown = 90, SpellId = 403876,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = { "Cast", "Shield" },
            }, -- Divine Protection (90s base for Ret)
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 204018,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                RequiresTalent = 5692,
            }, -- Blessing of Spellwarding
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 1022,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                ExcludeIfTalent = 5692,
            }, -- Blessing of Protection
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 6940,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Blessing of Sacrifice
            {
                BuffDuration = 20, Cooldown = 180, SpellId = 105809,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 105809,
            }, -- Holy Avenger (class-tree talent; 3x Holy Power = damage burst on Ret)
            {
                BuffDuration = 25, Cooldown = 120, SpellId = 231895,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 231895, ExcludeIfTalent = 31884,
            }, -- Crusade (Ret talent replacement for Avenging Wrath)
        },
        [62] = { -- Arcane Mage
            {
                BuffDuration = 15, Cooldown = 90, SpellId = 365350,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Arcane Surge
        },
        [63] = { -- Fire Mage
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 190319,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Combustion
        },
        [64] = { -- Frost Mage
            {
                BuffDuration = 25, Cooldown = 180, SpellId = 12472,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Icy Veins (Frost baseline DPS CD)
        },
        [71] = { -- Arms Warrior
            {
                BuffDuration = 8, Cooldown = 120, SpellId = 118038,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Die by the Sword
            {
                BuffDuration = 20, Cooldown = 90, SpellId = 107574,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 107574,
            }, -- Avatar
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 227847,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Bladestorm (current cross-spec ID, Arms variant)
        },
        [72] = { -- Fury Warrior
            {
                BuffDuration = 8, Cooldown = 108, SpellId = 184364,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast", RequiresTalent = 184364,
            }, -- Enraged Regeneration
            {
                BuffDuration = 11, Cooldown = 108, SpellId = 184364,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast", RequiresTalent = 184364,
            }, -- Enraged Regeneration + duration talent
            {
                BuffDuration = 20, Cooldown = 90, SpellId = 107574,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 107574,
            }, -- Avatar
            {
                BuffDuration = 12, Cooldown = 300, SpellId = 1719,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Recklessness (Fury baseline)
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 227847,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Bladestorm (current cross-spec ID, Fury variant)
        },
        [73] = { -- Protection Warrior
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 871,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Shield Wall
            {
                BuffDuration = 20, Cooldown = 90, SpellId = 107574,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 107574,
            }, -- Avatar
        },
        [251] = { -- Frost Death Knight
            {
                BuffDuration = 12, Cooldown = 45, SpellId = 51271,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Pillar of Frost
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 279302,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 279302,
            }, -- Frostwyrm's Fury (Frost talent)
            {
                BuffDuration = 30, Cooldown = 120, SpellId = 155166,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 155166, CanCancelEarly = true,
            }, -- Breath of Sindragosa (Frost talent channel; 155166 = cast ID in combat log, 152279 = talent node)
        },
        [250] = { -- Blood Death Knight
            {
                BuffDuration = 10, Cooldown = 90, SpellId = 55233,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Vampiric Blood
            {
                BuffDuration = 12, Cooldown = 90, SpellId = 55233,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Vampiric Blood + Goreringers Anguish r1 (+2s)
            {
                BuffDuration = 14, Cooldown = 90, SpellId = 55233,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Vampiric Blood + Goreringers Anguish r2 (+4s)
        },
        [252] = { -- Unholy Death Knight
            {
                BuffDuration = 25, Cooldown = 180, SpellId = 49206,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 49206,
            }, -- Summon Gargoyle (Unholy talent)
        },
        [256] = { -- Discipline Priest
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 33206,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Pain Suppression
            {
                Cooldown = 180, SpellId = 62618, Important = true,
                RequiresEvidence = "Cast", CastOnly = true,
            }, -- Power Word: Barrier (ground effect — cast fast-path only)
        },
        [257] = { -- Holy Priest
            {
                BuffDuration = 10, Cooldown = 180, SpellId = 47788,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                ExcludeIfTalent = 440738,
            }, -- Guardian Spirit
            {
                BuffDuration = 12, Cooldown = 180, SpellId = 47788,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                RequiresTalent = 440738,
            }, -- Guardian Spirit (Foreseen Circumstances)
            {
                BuffDuration = 5, Cooldown = 180, SpellId = 64843,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                CanCancelEarly = true, MinCancelDuration = 1.5,
                -- MinCancelDuration=1.5 excludes Phase Shift (a 1s IMPORTANT
                -- buff on Fade) from false-matching Divine Hymn.
                RequiresEvidence = "Cast",
            }, -- Divine Hymn
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 200183,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 200183,
            }, -- Apotheosis (caster buff)
            {
                Cooldown = 240, SpellId = 265202, Important = true,
                RequiresEvidence = "Cast", CastOnly = true,
            }, -- Holy Word: Salvation (instant, no caster buff → cast fast-path). Talent-gating is enforced upstream: the fast-path fires on UNIT_SPELLCAST_SUCCEEDED, and casting the spell is proof the player has the talent (the client refuses to cast untalented spells). SpellDB.talentOnly=true still prevents pre-pop.
        },
        [258] = { -- Shadow Priest
            {
                BuffDuration = 6, Cooldown = 120, SpellId = 47585,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                CanCancelEarly = true, RequiresEvidence = "Cast",
            }, -- Dispersion
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 228260,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Voidform
        },
        [102] = { -- Balance Druid
            -- NOTE: Incarnation: Chosen of Elune (102560) removed — it is
            -- an offensive DPS CD, not a personal defensive. No display
            -- category fits; SpellDB entry was also removed.
        },
        [103] = { -- Feral Druid
            -- NOTE: Berserk (106951) and Incarnation: Avatar of Ashamane
            -- (102543) removed — both are offensive DPS CDs, not defensives.
        },
        [104] = { -- Guardian Druid
            {
                BuffDuration = 30, Cooldown = 180, SpellId = 102558,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Incarnation: Guardian of Ursoc
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 200851,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Rage of the Sleeper
        },
        [105] = { -- Restoration Druid
            {
                BuffDuration = 12, Cooldown = 90, SpellId = 102342,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Ironbark
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 740,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", CanCancelEarly = true, MinCancelDuration = 1.5,
            }, -- Tranquility (8s channel buff on caster; cancellable)
            {
                BuffDuration = 30, Cooldown = 180, SpellId = 33891,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true, RequiresTalent = 33891,
            }, -- Incarnation: Tree of Life
        },
        [268] = { -- Brewmaster Monk
            {
                BuffDuration = 25, Cooldown = 120, SpellId = 132578,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Invoke Niuzao, the Black Ox
            {
                BuffDuration = 15, Cooldown = 360, SpellId = 115203,
                BigDefensive = true, Important = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Fortifying Brew
        },
        [269] = { -- Windwalker Monk
            {
                BuffDuration = 10, Cooldown = 90, SpellId = 122470,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Touch of Karma (absorb + reflect; self-buff)
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 123904,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Invoke Xuen (offensive)
            {
                BuffDuration = 15, Cooldown = 90, SpellId = 137639,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Storm, Earth, and Fire (offensive)
        },
        [270] = { -- Mistweaver Monk
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 116849,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
            }, -- Life Cocoon
            {
                Cooldown = 180, SpellId = 115310, Important = true,
                RequiresEvidence = "Cast", CastOnly = true,
            }, -- Revival (instant AoE heal; no caster buff → cast fast-path)
            {
                BuffDuration = 25, Cooldown = 120, SpellId = 322118,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Invoke Yu'lon (healing serpent)
            {
                Cooldown = 180, SpellId = 388615, Important = true,
                RequiresEvidence = "Cast", CastOnly = true, RequiresTalent = 388615,
            }, -- Restoral (instant AoE heal + cleanse; MW talent replaces Revival)
        },
        [577] = { -- Havoc Demon Hunter
            {
                BuffDuration = 10, Cooldown = 60, SpellId = 198589,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Blur
            {
                BuffDuration = 8, Cooldown = 300, SpellId = 196718,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Darkness (raid CD, caster + party inside zone get buff 196718)
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 191427,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Metamorphosis (Havoc DPS burst — 20s demon form + haste + CD resets)
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 370965,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 370965,
            }, -- The Hunt (class talent, Havoc variant)
            {
                BuffDuration = 2, Cooldown = 60, SpellId = 390163,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 390163,
            }, -- Sigil of Spite (class talent, Havoc variant)
        },
        [1480] = { -- Devourer Demon Hunter (phantom/cancelled spec from 12.0 dev — no player-facing access, entries harmless)
            {
                BuffDuration = 10, Cooldown = 60, SpellId = 198589,
                BigDefensive = true, ExternalDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Blur
        },
        [581] = { -- Vengeance Demon Hunter
            {
                BuffDuration = 12, Cooldown = 60, SpellId = 204021,
                BigDefensive = true, ExternalDefensive = false, Important = false,
                MinDuration = true, RequiresEvidence = "Cast",
            }, -- Fiery Brand
            {
                BuffDuration = 15, Cooldown = 120, SpellId = 187827,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Metamorphosis
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 187827,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Metamorphosis +5s (Vengeful Beast)
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 370965,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 370965,
            }, -- The Hunt (class talent, Veng variant)
            {
                BuffDuration = 2, Cooldown = 60, SpellId = 390163,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 390163,
            }, -- Sigil of Spite (class talent, Veng variant)
        },
        [253] = { -- Beast Mastery Hunter
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 359844,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 359844,
            }, -- Call of the Wild (BM talent — summons 2 pets)
        },
        [254] = { -- Marksmanship Hunter
            {
                BuffDuration = 15, Cooldown = 120, SpellId = 288613,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Trueshot
            {
                BuffDuration = 17, Cooldown = 120, SpellId = 288613,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Trueshot +2s
        },
        [255] = { -- Survival Hunter
            {
                BuffDuration = 8, Cooldown = 90, SpellId = 1250646,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Takedown
            {
                BuffDuration = 10, Cooldown = 90, SpellId = 1250646,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Takedown +2s
        },
        [259] = { -- Assassination Rogue
            {
                BuffDuration = 16, Cooldown = 120, SpellId = 360194,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 360194,
            }, -- Deathmark (Assn talent, replaces Vendetta)
        },
        [260] = { -- Outlaw Rogue
            {
                BuffDuration = 15, Cooldown = 180, SpellId = 13750,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Adrenaline Rush (baseline)
            {
                BuffDuration = 3, Cooldown = 120, SpellId = 51690,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 51690,
            }, -- Killing Spree (talent)
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 343142,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 343142,
            }, -- Dreadblades (Outlaw talent)
        },
        [265] = { -- Affliction Warlock
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 205180,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 205180,
            }, -- Summon Darkglare (Aff talent; DoT amp)
        },
        [266] = { -- Demonology Warlock
            {
                BuffDuration = 15, Cooldown = 60, SpellId = 265187,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Summon Demonic Tyrant (Demo baseline)
            {
                BuffDuration = 15, Cooldown = 180, SpellId = 267217,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 267217,
            }, -- Nether Portal (Demo talent — shard-spending demon summons)
        },
        [261] = { -- Subtlety Rogue
            {
                BuffDuration = 16, Cooldown = 90, SpellId = 121471,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Shadow Blades
            {
                BuffDuration = 18, Cooldown = 90, SpellId = 121471,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Shadow Blades +2s
            {
                BuffDuration = 20, Cooldown = 90, SpellId = 121471,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Shadow Blades +4s
        },
        [1467] = { -- Devastation Evoker
            {
                BuffDuration = 18, Cooldown = 120, SpellId = 375087,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Dragonrage
            {
                BuffDuration = 6, Cooldown = 120, SpellId = 357210,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Deep Breath (Dev — OFFENSIVE DPS CD baseline)
        },
        [1468] = { -- Preservation Evoker
            {
                BuffDuration = 8, Cooldown = 60, SpellId = 357170,
                ExternalDefensive = true, BigDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Time Dilation
            {
                BuffDuration = 30, Cooldown = 90, SpellId = 370564,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 370564,
            }, -- Stasis release (CD starts ticking when Release is cast; 370564 = release, 370537 = store)
        },
        [1473] = { -- Augmentation Evoker
            {
                BuffDuration = 13.4, Cooldown = 90, SpellId = 363916,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Obsidian Scales
            {
                BuffDuration = 5, Cooldown = 41, SpellId = 378441,
                BigDefensive = false, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                RequiresTalent = { 5463, 5464, 5619 },
            }, -- Time Stop (PvP talent)
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 403631,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 403631,
            }, -- Breath of Eons (Aug talent offensive)
        },
        [264] = { -- Restoration Shaman
            {
                BuffDuration = 15, Cooldown = 180, SpellId = 114052,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 114052,
            }, -- Ascendance
            {
                Cooldown = 180, SpellId = 108280, Important = true,
                RequiresEvidence = "Cast", CastOnly = true,
            }, -- Healing Tide Totem (totem emits; no caster buff → cast fast-path)
            {
                Cooldown = 180, SpellId = 98008, Important = true,
                RequiresEvidence = "Cast", CastOnly = true,
            }, -- Spirit Link Totem (totem emits; no caster buff → cast fast-path)
        },
        [262] = { -- Elemental Shaman
            {
                BuffDuration = 20, Cooldown = 120, SpellId = 198067,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", ExcludeIfTalent = 192249,
            }, -- Fire Elemental (mutually exclusive with Storm Elemental)
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 192249,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 192249,
            }, -- Storm Elemental (talent replaces Fire Elemental)
            {
                BuffDuration = 15, Cooldown = 60, SpellId = 191634,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 191634,
            }, -- Stormkeeper
        },
        [263] = { -- Enhancement Shaman
            {
                BuffDuration = 8, Cooldown = 60, SpellId = 384352,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 384352,
                ExcludeIfTalent = { 114051, 378270 },
            }, -- Doomwinds
            {
                BuffDuration = 10, Cooldown = 60, SpellId = 384352,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 384352,
                ExcludeIfTalent = { 114051, 378270 },
            }, -- Doomwinds +2s (Thorim's Invocation)
            -- NOTE: Ascendance (114051) removed — offensive CD, no category fits.
            {
                BuffDuration = 15, Cooldown = 120, SpellId = 51533,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Feral Spirit (Enh baseline)
        },
    },
    ByClass = {
        PALADIN = {
            {
                BuffDuration = 8, Cooldown = 300, SpellId = 642,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = { "Cast", "Flags" }, CanCancelEarly = true,
            }, -- Divine Shield
            {
                BuffDuration = 8, Cooldown = 25, SpellId = 1044,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                CastableOnOthers = true,
            }, -- Blessing of Freedom
            {
                BuffDuration = 10, Cooldown = 45, SpellId = 204018,
                ExternalDefensive = true, Important = false, BigDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                RequiresTalent = 5692,
            }, -- Blessing of Spellwarding
            {
                BuffDuration = 10, Cooldown = 300, SpellId = 1022,
                ExternalDefensive = true, Important = false, BigDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff" },
                ExcludeIfTalent = 5692,
            }, -- Blessing of Protection
        },
        WARRIOR = {
            {
                BuffDuration = 10, Cooldown = 180, SpellId = 97462,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Rallying Cry (raid CD — caster + group get buff 97463)
            {
                BuffDuration = 8, Cooldown = 90, SpellId = 384318,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 384318,
            }, -- Thunderous Roar (class talent, AoE bleed)
            {
                BuffDuration = 4, Cooldown = 90, SpellId = 376079,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 376079,
            }, -- Champion's Spear (class talent)
        },
        MAGE = {
            {
                BuffDuration = 15, Cooldown = 90, SpellId = 55342,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Mirror Image (class-wide DPS summon; baseline)
            {
                BuffDuration = 10, Cooldown = 240, SpellId = 45438,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Debuff", "Flags" },
                ExcludeIfTalent = 414659,
            }, -- Ice Block
            {
                BuffDuration = 6, Cooldown = 240, SpellId = 414659,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast", RequiresTalent = 414659,
            }, -- Ice Cold (replaces Ice Block)
            {
                BuffDuration = 10, Cooldown = 50, SpellId = 342245,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                CanCancelEarly = true, RequiresEvidence = "Cast",
            }, -- Alter Time
        },
        HUNTER = {
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 186265,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Flags" },
                -- Do NOT match if the "Flags" evidence is actually a Feign
                -- Death toggle (UnitIsFeignDeath just flipped). Feign sets a
                -- different UNIT_FLAG but fires the same UNIT_FLAGS event;
                -- without this gate Turtle would false-match on Feign.
                ExcludeIfEvidence = { FeignDeath = true },
            }, -- Aspect of the Turtle
            {
                BuffDuration = 6, Cooldown = 90, SpellId = 264735,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                MinDuration = true, RequiresEvidence = "Cast",
            }, -- Survival of the Fittest
            {
                BuffDuration = 8, Cooldown = 90, SpellId = 264735,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                MinDuration = true, RequiresEvidence = "Cast",
            }, -- Survival of the Fittest + talent (+2s)
        },
        DRUID = {
            {
                BuffDuration = 8, Cooldown = 60, SpellId = 22812,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Barkskin
            {
                BuffDuration = 12, Cooldown = 60, SpellId = 22812,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Barkskin + Improved Barkskin (+4s)
        },
        ROGUE = {
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 5277,
                Important = true, ExternalDefensive = false, BigDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Evasion
            {
                BuffDuration = 5, Cooldown = 120, SpellId = 31224,
                BigDefensive = true, ExternalDefensive = false, Important = false,
                RequiresEvidence = "Cast",
            }, -- Cloak of Shadows
            {
                BuffDuration = 10, Cooldown = 90, SpellId = 385408,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 385408,
            }, -- Sepsis (class talent, all specs)
        },
        DEATHKNIGHT = {
            {
                BuffDuration = 5, Cooldown = 60, SpellId = 48707,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Shield" },
            }, -- Anti-Magic Shell (BigDefensive, without Spellwarding)
            {
                BuffDuration = 7, Cooldown = 60, SpellId = 48707,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Shield" },
            }, -- Anti-Magic Shell + Anti-Magic Barrier
            {
                BuffDuration = 8, Cooldown = 120, SpellId = 48792,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Icebound Fortitude
            {
                BuffDuration = 5, Cooldown = 60, SpellId = 48707,
                BigDefensive = false, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Shield" },
            }, -- Anti-Magic Shell (with Spellwarding)
            {
                BuffDuration = 7, Cooldown = 60, SpellId = 48707,
                BigDefensive = false, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = { "Cast", "Shield" },
            }, -- Anti-Magic Shell + Barrier (with Spellwarding)
            {
                BuffDuration = 10, Cooldown = 120, SpellId = 51052,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Anti-Magic Zone (raid CD; caster gets own AMZ buff)
            {
                BuffDuration = 15, Cooldown = 120, SpellId = 48743,
                BigDefensive = true, Important = true, ExternalDefensive = false,
                RequiresEvidence = "Cast", RequiresTalent = 48743,
            }, -- Death Pact (class-tree talent; 50% HP self-heal with healing absorb)
        },
        DEMONHUNTER = {},
        MONK = {
            -- NOTE: spell 115203 is the Brewmaster-specific Fortifying Brew
            -- variant (see BySpec[268]). WW/MW cast 243435 instead. A
            -- class-baseline ByClass entry for 115203 caused a pre-pop /
            -- PruneWrongSpec ping-pong on non-BrM Monks (SpellDB gates
            -- 115203 to spec=268). Kept empty intentionally.
        },
        SHAMAN = {
            {
                BuffDuration = 12, Cooldown = 120, SpellId = 108271,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Astral Shift
        },
        WARLOCK = {
            {
                BuffDuration = 8, Cooldown = 180, SpellId = 104773,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Unending Resolve
            {
                BuffDuration = 3, Cooldown = 45, SpellId = 212295,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                RequiresTalent = { 18, 3508, 3624 },
            }, -- Nether Ward (PvP talent)
            {
                BuffDuration = 30, Cooldown = 120, SpellId = 1122,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Summon Infernal (class-wide, Destro main DPS CD)
            {
                BuffDuration = 8, Cooldown = 60, SpellId = 386997,
                Important = true, BigDefensive = false, ExternalDefensive = false,
                RequiresEvidence = "Cast",
            }, -- Soul Rot (class-wide baseline in 12.0)
        },
        PRIEST = {
            {
                BuffDuration = 10, Cooldown = 90, SpellId = 19236,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast",
            }, -- Desperate Prayer
        },
        EVOKER = {
            {
                BuffDuration = 12, Cooldown = 90, SpellId = 363916,
                BigDefensive = true, ExternalDefensive = false, Important = true,
                RequiresEvidence = "Cast", MinDuration = true,
            }, -- Obsidian Scales
            {
                BuffDuration = 5, Cooldown = 45, SpellId = 378441,
                BigDefensive = false, Important = true, ExternalDefensive = false,
                CanCancelEarly = true, RequiresEvidence = "Cast",
                RequiresTalent = { 5463, 5464, 5619 },
            }, -- Time Stop (PvP talent)
        },
    },
}

-- Spell IDs treated as offensive cooldowns (shown under the "Important" filter).
HexCD.AuraRules.OffensiveSpellIds = {
    [375087] = true, -- Dragonrage
    [107574] = true, -- Avatar
    [121471] = true, -- Shadow Blades
    [31884]  = true, -- Avenging Wrath
    [216331] = true, -- Avenging Crusader
    [190319] = true, -- Combustion
    [288613] = true, -- Trueshot
    [228260] = true, -- Voidform
    [102560] = true, -- Incarnation: Chosen of Elune (Balance)
    [102543] = true, -- Incarnation: Avatar of Ashamane (Feral)
    [106951] = true, -- Berserk (Feral)
    [102558] = true, -- Incarnation: Guardian of Ursoc (Guardian)
    [1250646] = true, -- Takedown
    [384352] = true, -- Doomwinds
    [114051] = true, -- Ascendance (Enhancement)
    [114050] = true, -- Ascendance (Elemental)
    [123904] = true, -- Invoke Xuen, the White Tiger (Windwalker)
    [137639] = true, -- Storm, Earth, and Fire (Windwalker)
    [105809] = true, -- Holy Avenger (class-tree talent, all Paladin specs)
    [231895] = true, -- Crusade (Ret talent, replaces Avenging Wrath)
    [198067] = true, -- Fire Elemental (Elem baseline)
    [192249] = true, -- Storm Elemental (Elem talent replacing Fire Elemental)
    [191634] = true, -- Stormkeeper (Elem talent)
    [51533]  = true, -- Feral Spirit (Enh baseline)
    [403631] = true, -- Breath of Eons (Aug talent)
    [357210] = true, -- Deep Breath (Dev OFFENSIVE; Pres/Aug need stun-talent to route to CC, TODO)
    [279302] = true, -- Frostwyrm's Fury (Frost talent)
    [155166] = true, -- Breath of Sindragosa (Frost talent channel; cast ID)
    [49206]  = true, -- Summon Gargoyle (Unholy talent)
    [191427] = true, -- Metamorphosis (Havoc DPS form)
    [370965] = true, -- The Hunt (Havoc/Veng talent)
    [390163] = true, -- Sigil of Spite (Havoc/Veng class talent)
    [12472]  = true, -- Icy Veins (Frost baseline)
    [55342]  = true, -- Mirror Image (class-wide baseline)
    [13750]  = true, -- Adrenaline Rush (Outlaw baseline)
    [51690]  = true, -- Killing Spree (Outlaw talent)
    [360194] = true, -- Deathmark (Assn talent)
    [343142] = true, -- Dreadblades (Outlaw talent)
    [385408] = true, -- Sepsis (class-wide talent)
    [1122]   = true, -- Summon Infernal (class-wide, Destro main DPS CD)
    [265187] = true, -- Summon Demonic Tyrant (Demo baseline)
    [205180] = true, -- Summon Darkglare (Aff talent)
    [386997] = true, -- Soul Rot (class-wide baseline)
    [267217] = true, -- Nether Portal (Demo talent)
    [1719]   = true, -- Recklessness (Fury baseline)
    [227847] = true, -- Bladestorm (current Arms+Fury talent; 46924 is the legacy Fury-only variant)
    [384318] = true, -- Thunderous Roar (class talent)
    [376079] = true, -- Champion's Spear (class talent)
    [359844] = true, -- Call of the Wild (BM talent)
}
