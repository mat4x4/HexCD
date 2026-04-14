------------------------------------------------------------------------
-- HexCD: SpellDB — Spell database for party CD tracking
--
-- 9 Categories:
--   PERSONAL           — Personal defensives + immunities (per-player)
--   RANGED_DEFENSIVE   — Party defensives that work at range (Rally, VE)
--   STACKED_DEFENSIVE  — Party defensives requiring stacking (AMZ, Darkness, Barrier)
--   UTILITY            — Utility abilities (Roar, Grip, Freedom, Rescue)
--   HEALING            — Major healing throughput CDs
--   KICK               — Interrupts
--   ST_CC              — Single-target crowd control
--   AOE_CC             — Area-of-effect crowd control
--   DISPEL             — Healer dispels
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.SpellDB = {}

local DB = HexCD.SpellDB

------------------------------------------------------------------------
-- Personal Defensives + Immunities
------------------------------------------------------------------------
local PERSONAL = {
    -- Death Knight
    [48792]  = { name = "Icebound Fortitude",   cd = 180, class = "DEATHKNIGHT" },
    [48707]  = { name = "Anti-Magic Shell",     cd = 60,  class = "DEATHKNIGHT" },
    [49039]  = { name = "Lichborne",            cd = 120, class = "DEATHKNIGHT" },
    [48743]  = { name = "Death Pact",           cd = 120, class = "DEATHKNIGHT", talentOnly = true }, -- class-tree talent; 50% HP self-heal + healing-absorb 30%
    -- Demon Hunter
    [198589] = { name = "Blur",                 cd = 60,  class = "DEMONHUNTER" },
    [196555] = { name = "Netherwalk",           cd = 180, class = "DEMONHUNTER", immune = true },
    -- Druid
    [22812]  = { name = "Barkskin",             cd = 60,  class = "DRUID" },
    [61336]  = { name = "Survival Instincts",   cd = 180, class = "DRUID", specs = {103, 104} }, -- Feral/Guardian only (class-tree talent, unreachable for Boomy/Resto)
    -- Evoker
    [363916] = { name = "Obsidian Scales",      cd = 150, class = "EVOKER" },
    [374349] = { name = "Renewing Blaze",       cd = 90,  class = "EVOKER" },
    -- Hunter
    [186265] = { name = "Aspect of the Turtle", cd = 180, class = "HUNTER", immune = true },
    [264735] = { name = "Survival of the Fittest", cd = 90,  class = "HUNTER" }, -- 90s since 12.0 build 63534 (was 120s prior)
    [109304] = { name = "Exhilaration",         cd = 120, class = "HUNTER" },
    -- Mage
    [45438]  = { name = "Ice Block",            cd = 240, class = "MAGE", immune = true },
    [414658] = { name = "Ice Cold",             cd = 120, class = "MAGE" },
    [110960] = { name = "Greater Invisibility",  cd = 120, class = "MAGE" },
    [342245] = { name = "Alter Time",           cd = 60,  class = "MAGE" },
    -- Monk
    [122278] = { name = "Dampen Harm",          cd = 120, class = "MONK" },
    [122783] = { name = "Diffuse Magic",        cd = 90,  class = "MONK" },
    [243435] = { name = "Fortifying Brew",      cd = 180, class = "MONK", specs = {269, 270} }, -- WW/MW baseline (BrM uses 115203 variant)
    -- Paladin
    [642]    = { name = "Divine Shield",        cd = 300, class = "PALADIN", immune = true },
    [498]    = { name = "Divine Protection",    cd = 60,  class = "PALADIN", specs = {65, 66} }, -- Holy/Prot only; Ret uses 403876 variant (90s CD)
    [184662] = { name = "Shield of Vengeance",  cd = 90,  class = "PALADIN", specs = {70} },  -- Ret baseline
    -- Priest
    [19236]  = { name = "Desperate Prayer",     cd = 90,  class = "PRIEST" },
    [47585]  = { name = "Dispersion",           cd = 120, class = "PRIEST", specs = {258} }, -- Shadow
    [586]    = { name = "Fade",                 cd = 30,  class = "PRIEST" },                -- baseline all specs; talents make it 10% DR
    [193065] = { name = "Protective Light",     cd = 10,  class = "PRIEST", specs = {256, 257}, talentOnly = true }, -- Disc/Holy talent proc — 10s buff, 10% DR
    -- Rogue
    [5277]   = { name = "Evasion",              cd = 120, class = "ROGUE" },
    [31224]  = { name = "Cloak of Shadows",     cd = 120, class = "ROGUE" },
    -- NOTE: Feint (1966) removed — 15s rotational damage reducer, violates
    -- the ≥60s rule for PERSONAL/EXTERNAL/HEALING/OFFENSIVE. It's pressed
    -- on CD as a normal rotation button, not a planned CD.
    -- Shaman
    [108271] = { name = "Astral Shift",         cd = 120, class = "SHAMAN" },
    -- Warlock
    [104773] = { name = "Unending Resolve",     cd = 180, class = "WARLOCK" },
    [108416] = { name = "Dark Pact",            cd = 60,  class = "WARLOCK" },
    -- Warrior
    [871]    = { name = "Shield Wall",          cd = 210, class = "WARRIOR", specs = {73} },  -- Prot baseline
    [12975]  = { name = "Last Stand",           cd = 180, class = "WARRIOR", specs = {73} },  -- Prot baseline
    [118038] = { name = "Die by the Sword",     cd = 120, class = "WARRIOR", specs = {71, 72} },  -- Arms/Fury
    [184364] = { name = "Enraged Regeneration", cd = 120, class = "WARRIOR", specs = {72} },  -- Fury baseline

    ------------------------------------------------------------------
    -- Phase 7 sync: added to satisfy AuraRules.lua (MiniCC port).
    --
    -- Entries with a `specs` field are gated to those spec IDs — CommSync
    -- only pre-populates them when the player's spec is in the list.
    -- Entries with `pvpTalent = true` are PvP-only and never pre-populated
    -- (surfaced live by AuraDetector when observed).
    -- Entries without `specs` or `pvpTalent` pre-populate for any spec of
    -- the class (baseline behaviour).
    --
    -- Spec ID reference: Pala H=65/P=66/R=70; War A=71/F=72/P=73;
    --   Mage A=62/F=63/Fr=64; Priest D=256/H=257/Sh=258;
    --   DK B=250/F=251/U=252; Rogue Asn=259/Ou=260/Sub=261;
    --   Druid Bal=102/Fer=103/Gua=104/Res=105;
    --   Evoker Dev=1467/Pre=1468/Aug=1473;
    --   Shaman El=262/En=263/Re=264;
    --   Monk BrM=268/WW=269/MW=270;
    --   DH Hav=577/Ven=581/Dev=1480;
    --   Hunter BM=253/MM=254/Surv=255
    ------------------------------------------------------------------
    -- Paladin (spec-specific)
    [31850]  = { name = "Ardent Defender",       cd = 180, class = "PALADIN", specs = {66} },
    -- NOTE: Avenging Wrath (31884) moved to OFFENSIVE — damage/healing amp,
    -- not a damage-reduction defensive.
    [86659]  = { name = "Guardian of Ancient Kings", cd = 300, class = "PALADIN", specs = {66} },
    [389539] = { name = "Sentinel",              cd = 120, class = "PALADIN", specs = {66}, talentOnly = true }, -- Prot talent replacing Avenging Wrath (30% DR + 15% max HP stacks)
    [403876] = { name = "Divine Protection (Ret)", cd = 90, class = "PALADIN", specs = {70} },
    -- Priest (spec-specific)
    -- NOTE: Voidform (228260) moved to OFFENSIVE — DPS ramp CD, not defensive.
    -- Death Knight (spec-specific)
    -- NOTE: Pillar of Frost (51271) moved to OFFENSIVE — strength buff for Frost DPS.
    [55233]  = { name = "Vampiric Blood",        cd = 90,  class = "DEATHKNIGHT", specs = {250} }, -- Blood
    -- Druid (spec-specific)
    -- NOTE: Feral (102543) and Balance (102560) Incarnations are offensive
    -- DPS CDs, not personal defensives — removed. Guardian (102558) is a
    -- tank defensive (+30% HP / 20% DR) and stays. Resto ToL (33891) is
    -- tracked under HEALING.
    [102558] = { name = "Incarnation: Guardian of Ursoc",  cd = 180, class = "DRUID", specs = {104} }, -- Guardian (tank defensive)
    [200851] = { name = "Rage of the Sleeper",             cd = 120, class = "DRUID", specs = {104} }, -- Guardian (DR + self-sustain)
    -- NOTE: Berserk (106951) removed — offensive Feral CD (energy regen +
    -- combo-point reset), not a defensive. Same rationale as the
    -- Incarnation DPS variants.
    -- NOTE: Avatar (107574) moved to OFFENSIVE — +20% damage done, mostly
    -- an offensive buff (minor stamina boost doesn't make it defensive).
    -- Shaman (spec-specific)
    -- NOTE: Ascendance Elem/Enh (114050/114051) and Doomwinds (384352) moved
    -- to OFFENSIVE. Resto Ascendance (114052) is in HEALING.
    -- Monk (spec-specific)
    [115203] = { name = "Fortifying Brew (MiniCC ID)", cd = 120, class = "MONK", specs = {268} }, -- BrM
    [132578] = { name = "Invoke Niuzao, the Black Ox", cd = 120, class = "MONK", specs = {268} }, -- BrM
    [122470] = { name = "Touch of Karma",              cd = 90,  class = "MONK", specs = {269} }, -- WW (50% HP absorb + reflect)
    -- Demon Hunter (spec-specific)
    [187827] = { name = "Metamorphosis (Vengeance)", cd = 120, class = "DEMONHUNTER", specs = {581} },
    -- NOTE: Metamorphosis (Havoc) 191427 is OFFENSIVE (+20% haste burst,
    -- resets Eye Beam / Blade Dance), not a personal defensive like Veng's
    -- 187827. Tracked below in OFFENSIVE.
    [204021] = { name = "Fiery Brand",           cd = 60,  class = "DEMONHUNTER", specs = {581} },
    -- Hunter (spec-specific)
    -- NOTE: Trueshot (288613, MM) and Takedown (1250646, Surv) moved to OFFENSIVE.
    -- Mage (spec + talent)
    -- NOTE: Combustion (190319, Fire) and Arcane Surge (365350, Arcane) moved
    -- to OFFENSIVE. 342246 is the Alter Time RETURN proc, not the cast —
    -- real cast ID 342245 is in PERSONAL above.
    [414659] = { name = "Ice Cold",              cd = 240, class = "MAGE", talentOnly = true }, -- talent replaces Ice Block
    -- Rogue (spec-specific)
    -- NOTE: Shadow Blades (121471, Sub) moved to OFFENSIVE.
    -- Warlock (PvP talent)
    [212295] = { name = "Nether Ward",           cd = 45,  class = "WARLOCK", pvpTalent = true },
    -- Evoker (spec + PvP)
    -- NOTE: Dragonrage (375087, Dev) moved to OFFENSIVE.
    [378441] = { name = "Time Stop",             cd = 45,  class = "EVOKER", pvpTalent = true },
}

------------------------------------------------------------------------
-- Offensive CDs (major DPS cooldowns — damage/haste/crit ramps)
-- Surfaced on a separate floating tracker so coordinators can time bursts
-- and healers can anticipate incoming damage spikes from adds dying fast.
-- Not a defensive — these spells never reduce damage taken.
------------------------------------------------------------------------
local OFFENSIVE = {
    -- Paladin
    -- Avenging Wrath is a hybrid: damage amp (Ret/Prot) AND healing amp (Holy).
    -- Base bucket OFFENSIVE works for Ret/Prot. Holy (65) sees it on the
    -- HEALING bar via categoryOverride so it sits next to Divine Hymn /
    -- Holy Word: Salvation where Holy raid-healers actually plan it.
    [31884]  = { name = "Avenging Wrath",              cd = 120, class = "PALADIN",    specs = {65, 66, 70},
                 categoryOverride = { [65] = "HEALING" } },
    -- Warrior
    [107574] = { name = "Avatar",                      cd = 90,  class = "WARRIOR",    specs = {71, 72, 73} },
    [1719]   = { name = "Recklessness",                cd = 300, class = "WARRIOR",    specs = {72} }, -- Fury baseline (Arms/Prot can channel via Warlord's Torment talent)
    [227847] = { name = "Bladestorm",                  cd = 90,  class = "WARRIOR",    specs = {71, 72} }, -- current Arms+Fury talent (per Wowhead); 46924 is the legacy Fury-only variant
    [384318] = { name = "Thunderous Roar",             cd = 90,  class = "WARRIOR",    talentOnly = true }, -- class talent all specs (AoE bleed)
    [376079] = { name = "Champion's Spear",            cd = 90,  class = "WARRIOR",    talentOnly = true }, -- class talent all specs (renamed from Spear of Bastion)
    -- Priest
    [228260] = { name = "Voidform",                    cd = 120, class = "PRIEST",     specs = {258} }, -- Shadow
    [10060]  = { name = "Power Infusion",              cd = 120, class = "PRIEST",     talentOnly = true }, -- class-tree talent, all specs
    -- Death Knight
    [51271]  = { name = "Pillar of Frost",             cd = 45,  class = "DEATHKNIGHT", specs = {251} }, -- Frost (45s — grandfathered exception to the ≥60s rule; Frost's iconic burst)
    [279302] = { name = "Frostwyrm's Fury",            cd = 90,  class = "DEATHKNIGHT", specs = {251}, talentOnly = true }, -- Frost talent (AoE burst + 3s stun + slow)
    -- Breath of Sindragosa: 155166 is the cast/channel ID that appears in
    -- combat log; 152279 is the talent node ID. We track 155166 and use
    -- it for RequiresTalent (TalentCache key) below.
    [155166] = { name = "Breath of Sindragosa",        cd = 120, class = "DEATHKNIGHT", specs = {251}, talentOnly = true }, -- Frost talent (channeled runic power drain)
    [49206]  = { name = "Summon Gargoyle",             cd = 180, class = "DEATHKNIGHT", specs = {252}, talentOnly = true }, -- Unholy talent (25s gargoyle summon)
    -- Demon Hunter
    [191427] = { name = "Metamorphosis (Havoc)",       cd = 120, class = "DEMONHUNTER", specs = {577} }, -- Havoc baseline (20s demon form + haste + CD resets)
    [370965] = { name = "The Hunt",                    cd = 90,  class = "DEMONHUNTER", specs = {577, 581}, talentOnly = true }, -- class talent (Havoc+Veng); charge + DoT
    [390163] = { name = "Sigil of Spite",              cd = 60,  class = "DEMONHUNTER", specs = {577, 581}, talentOnly = true }, -- class talent (Havoc+Veng); AoE chaos damage + soul shatter
    -- Druid
    [106951] = { name = "Berserk (Feral)",             cd = 180, class = "DRUID",      specs = {103} },
    [102543] = { name = "Incarnation: Avatar of Ashamane", cd = 180, class = "DRUID",  specs = {103}, talentOnly = true },
    [102560] = { name = "Incarnation: Chosen of Elune",    cd = 180, class = "DRUID",  specs = {102}, talentOnly = true },
    [194223] = { name = "Celestial Alignment",         cd = 180, class = "DRUID",      specs = {102} },
    -- Mage
    [190319] = { name = "Combustion",                  cd = 120, class = "MAGE",       specs = {63} }, -- Fire
    [365350] = { name = "Arcane Surge",                cd = 90,  class = "MAGE",       specs = {62} }, -- Arcane
    [12472]  = { name = "Icy Veins",                   cd = 180, class = "MAGE",       specs = {64} }, -- Frost baseline (+20% haste, +15% spell damage, 25s)
    [55342]  = { name = "Mirror Image",                cd = 90,  class = "MAGE" }, -- class-wide baseline (3 copies attack target for 15s; off-GCD)
    -- Shaman
    [114050] = { name = "Ascendance (Elemental)",      cd = 180, class = "SHAMAN",     specs = {262}, talentOnly = true },
    [114051] = { name = "Ascendance (Enhancement)",    cd = 180, class = "SHAMAN",     specs = {263}, talentOnly = true },
    [384352] = { name = "Doomwinds",                   cd = 60,  class = "SHAMAN",     specs = {263} },
    [198067] = { name = "Fire Elemental",              cd = 120, class = "SHAMAN",     specs = {262} }, -- Elem baseline (mutually exclusive with Storm Elemental talent)
    [192249] = { name = "Storm Elemental",             cd = 120, class = "SHAMAN",     specs = {262}, talentOnly = true }, -- Elem talent replacing Fire Elemental
    [191634] = { name = "Stormkeeper",                 cd = 60,  class = "SHAMAN",     specs = {262}, talentOnly = true }, -- Elem talent (Lightning Bolt empower)
    [51533]  = { name = "Feral Spirit",                cd = 120, class = "SHAMAN",     specs = {263} }, -- Enh baseline (spirit wolves)
    -- Rogue
    [121471] = { name = "Shadow Blades",               cd = 90,  class = "ROGUE",      specs = {261} }, -- Sub
    [13750]  = { name = "Adrenaline Rush",             cd = 180, class = "ROGUE",      specs = {260} }, -- Outlaw baseline (energy regen + attack speed)
    [51690]  = { name = "Killing Spree",               cd = 120, class = "ROGUE",      specs = {260}, talentOnly = true }, -- Outlaw talent (multi-strike barrage)
    [360194] = { name = "Deathmark",                   cd = 120, class = "ROGUE",      specs = {259}, talentOnly = true }, -- Assassination talent (replaces Vendetta)
    [343142] = { name = "Dreadblades",                 cd = 120, class = "ROGUE",      specs = {260}, talentOnly = true }, -- Outlaw talent (auto-max combo points at 8% HP cost)
    [385408] = { name = "Sepsis",                      cd = 90,  class = "ROGUE",      talentOnly = true }, -- class talent (all specs since 11.0+); DoT burst + Stealth ability reset
    -- Warlock
    [1122]   = { name = "Summon Infernal",             cd = 120, class = "WARLOCK" }, -- baseline all specs (Destro main DPS CD; available to Aff/Demo too)
    [265187] = { name = "Summon Demonic Tyrant",       cd = 60,  class = "WARLOCK",    specs = {266} }, -- Demonology baseline (Wowhead flags as talent but always-taken)
    [205180] = { name = "Summon Darkglare",            cd = 120, class = "WARLOCK",    specs = {265}, talentOnly = true }, -- Affliction talent (DoT damage amp)
    [386997] = { name = "Soul Rot",                    cd = 60,  class = "WARLOCK" }, -- class-wide baseline in 12.0 (restriction removed build 63534)
    [267217] = { name = "Nether Portal",               cd = 180, class = "WARLOCK",    specs = {266}, talentOnly = true }, -- Demo talent (15s random-demon summons as shards are spent)
    -- Hunter
    [288613] = { name = "Trueshot",                    cd = 120, class = "HUNTER",     specs = {254} }, -- MM
    [1250646] = { name = "Takedown",                   cd = 90,  class = "HUNTER",     specs = {255} }, -- Surv
    [359844] = { name = "Call of the Wild",            cd = 120, class = "HUNTER",     specs = {253}, talentOnly = true }, -- BM talent (summons 2 pets for 20s)
    -- Evoker
    [375087] = { name = "Dragonrage",                  cd = 120, class = "EVOKER",     specs = {1467} }, -- Devastation
    [403631] = { name = "Breath of Eons",              cd = 120, class = "EVOKER",     specs = {1473}, talentOnly = true }, -- Augmentation talent (Temporal Wounds burst)
    -- Deep Breath: baseline 2-min DPS CD for Dev. Pres/Aug can flip it into
    -- AoE CC by taking the stun talent — but without that talent it's just
    -- a weak mobility tool, not worth tracking. So we pre-pop only for Dev
    -- here. Pres/Aug surface it via a live-observation AuraRules rule gated
    -- on the stun talent (TODO: resolve the exact stun-talent ID and add
    -- BySpec[1468]/[1473] rules with RequiresTalent + a CC category override).
    [357210] = { name = "Deep Breath",                 cd = 120, class = "EVOKER", specs = {1467} },
    -- Monk
    [123904] = { name = "Invoke Xuen, the White Tiger", cd = 120, class = "MONK",       specs = {269} }, -- Windwalker (baseline 12.0; technically all-spec but only WW builds around it)
    [137639] = { name = "Storm, Earth, and Fire",      cd = 90,  class = "MONK",       specs = {269} }, -- Windwalker (2-charge offensive; tracked per-cast on the bar)
    -- Paladin
    [105809] = { name = "Holy Avenger",                cd = 180, class = "PALADIN",    talentOnly = true }, -- class-tree talent; 3x Holy Power gen, hybrid burst (heal/shield/damage by spec)
    [231895] = { name = "Crusade",                     cd = 120, class = "PALADIN",    specs = {70}, talentOnly = true }, -- Ret talent replacing Avenging Wrath
}

------------------------------------------------------------------------
-- External Defensives (party/raid CDs that protect others)
-- Subtypes for future granular breakdown:
--   ranged  — works at any range (Rally, VE, Aura Mastery)
--   stacked — requires positioning (AMZ, Darkness, Barrier, Spirit Link)
--   single  — single-target external (BoP, Pain Suppression, Ironbark)
------------------------------------------------------------------------
local EXTERNAL_DEFENSIVE = {
    -- Ranged (group-wide, no positioning needed)
    [97462]  = { name = "Rallying Cry",         cd = 180, class = "WARRIOR" },
    [15286]  = { name = "Vampiric Embrace",     cd = 120, class = "PRIEST" },
    [31821]  = { name = "Aura Mastery",         cd = 180, class = "PALADIN", specs = {65} }, -- Holy
    -- Stacked (require positioning / area effect)
    [51052]  = { name = "Anti-Magic Zone",      cd = 120, class = "DEATHKNIGHT" },
    [196718] = { name = "Darkness",             cd = 180, class = "DEMONHUNTER" },
    [62618]  = { name = "Power Word: Barrier",  cd = 180, class = "PRIEST", specs = {256} }, -- Disc
    [98008]  = { name = "Spirit Link Totem",    cd = 180, class = "SHAMAN", specs = {264} }, -- Resto
    [374227] = { name = "Zephyr",               cd = 120, class = "EVOKER" },

    -- Phase 7 sync: MiniCC-referenced externals
    [47788]  = { name = "Guardian Spirit",      cd = 180, class = "PRIEST",  specs = {257} },  -- Holy
    [116849] = { name = "Life Cocoon",          cd = 120, class = "MONK",    specs = {270} },  -- Mistweaver
    [204018] = { name = "Blessing of Spellwarding", cd = 300, class = "PALADIN", specs = {66} }, -- Prot
    [357170] = { name = "Time Dilation",        cd = 60,  class = "EVOKER",  specs = {1468} }, -- Preservation
    [33206]  = { name = "Pain Suppression",     cd = 180, class = "PRIEST",  specs = {256} },  -- Disc (single-target external)
    [102342] = { name = "Ironbark",             cd = 60,  class = "DRUID",   specs = {105} },  -- Resto (single-target external)
    -- Moved from UTILITY this audit pass (plan rule #5: ally DR ⇒ EXTERNAL_DEFENSIVE)
    [1022]   = { name = "Blessing of Protection", cd = 300, class = "PALADIN" }, -- physical immunity, single-target
    [6940]   = { name = "Blessing of Sacrifice",  cd = 120, class = "PALADIN" }, -- redirects 30% ally damage to self
    [633]    = { name = "Lay on Hands",         cd = 600, class = "PALADIN" }, -- emergency full-heal save (applies Forbearance)
    [53480]  = { name = "Roar of Sacrifice",    cd = 60,  class = "HUNTER" }, -- pet redirects 30% damage to pet
}

------------------------------------------------------------------------
-- Utility (movement, grips, externals that aren't defensives)
------------------------------------------------------------------------
local UTILITY = {
    -- Movement
    [106898] = { name = "Stampeding Roar",      cd = 120, class = "DRUID" },
    [192077] = { name = "Wind Rush Totem",      cd = 120, class = "SHAMAN", talentOnly = true }, -- class talent (group movement buff +40% speed, 15s totem)
    [116841] = { name = "Tiger's Lust",         cd = 30,  class = "MONK" },
    [1044]   = { name = "Blessing of Freedom",  cd = 25,  class = "PALADIN" },
    -- Grips / Rescue
    [49576]  = { name = "Death Grip",           cd = 25,  class = "DEATHKNIGHT" },
    [73325]  = { name = "Leap of Faith",        cd = 90,  class = "PRIEST" },
    [32375]  = { name = "Mass Dispel",          cd = 45,  class = "PRIEST" },                 -- all specs, magic dispel (utility)
    [370665] = { name = "Rescue",               cd = 60,  class = "EVOKER" },
    -- Externals (non-defensive)
    [29166]  = { name = "Innervate",            cd = 180, class = "DRUID", specs = {105}, talentOnly = true }, -- Resto talent in 12.0 (not baseline — optional Resto tree node)
    -- NOTE: Blessing of Protection (1022), Blessing of Sacrifice (6940),
    -- Lay on Hands (633), and Roar of Sacrifice (53480) moved to
    -- EXTERNAL_DEFENSIVE — they all reduce damage taken on an ally
    -- (physical immunity / redirect / emergency full-heal), which matches
    -- the plan's category rule #5 (ally DR buff ⇒ EXTERNAL_DEFENSIVE).
}

------------------------------------------------------------------------
-- Healing CDs (major throughput cooldowns)
------------------------------------------------------------------------
local HEALING = {
    [740]    = { name = "Tranquility",          cd = 180, class = "DRUID", specs = {105} }, -- Resto-only baseline in 12.0
    [391528] = { name = "Convoke the Spirits",  cd = 120, class = "DRUID", talentOnly = true }, -- 120s base; Cenarius' Guidance (Resto talent 393371) reduces by -50% (→60s) via DurationModifiers
    -- NOTE: Nature's Swiftness (132158) is a cast-time modifier, not a
    -- healing throughput CD — removed from HEALING.
    -- NOTE: Ironbark (102342) moved to EXTERNAL_DEFENSIVE — it's a
    -- single-target damage-reduction external, not throughput healing.
    [33891]  = { name = "Incarnation: ToL",     cd = 180, class = "DRUID", specs = {105}, talentOnly = true },   -- Resto talent
    [64843]  = { name = "Divine Hymn",          cd = 180, class = "PRIEST", specs = {257} },  -- Holy
    [200183] = { name = "Apotheosis",           cd = 120, class = "PRIEST", specs = {257}, talentOnly = true },  -- Holy talent
    [197871] = { name = "Dark Archangel",       cd = 90,  class = "PRIEST", specs = {256}, talentOnly = true },  -- Disc talent; for Disc, damage amp == healing amp via Atonement
    -- NOTE: Pain Suppression (33206) moved to EXTERNAL_DEFENSIVE —
    -- single-target damage reduction, not throughput healing.
    [108280] = { name = "Healing Tide Totem",   cd = 180, class = "SHAMAN", specs = {264} },   -- Resto
    [363534] = { name = "Rewind",               cd = 240, class = "EVOKER", specs = {1468} }, -- Preservation
    [359816] = { name = "Dream Flight",         cd = 120, class = "EVOKER", specs = {1468} }, -- Preservation
    [370564] = { name = "Stasis",               cd = 90,  class = "EVOKER", specs = {1468}, talentOnly = true }, -- Pres talent (release ID: 370564 is when CD starts ticking; 370537=store / 370562=base)
    [216331] = { name = "Avenging Crusader",    cd = 120, class = "PALADIN", talentOnly = true }, -- Holy talent
    [115310] = { name = "Revival",              cd = 180, class = "MONK",   specs = {270} },   -- MW baseline
    [325197] = { name = "Invoke Chi-Ji",        cd = 180, class = "MONK",   talentOnly = true }, -- MW talent
    [322118] = { name = "Invoke Yu'lon",        cd = 120, class = "MONK",   specs = {270} },   -- MW baseline alternative to Chi-Ji
    [388615] = { name = "Restoral",             cd = 180, class = "MONK",   specs = {270}, talentOnly = true }, -- MW talent; replaces Revival, AoE heal + poison/disease cleanse
    [265202] = { name = "Holy Word: Salvation", cd = 240, class = "PRIEST", talentOnly = true }, -- Holy talent
    [114052] = { name = "Ascendance (Restoration)", cd = 180, class = "SHAMAN", specs = {264}, talentOnly = true }, -- Resto talent
}

------------------------------------------------------------------------
-- Kicks (interrupts)
------------------------------------------------------------------------
local KICK = {
    [106839] = { name = "Skull Bash",           cd = 15,  class = "DRUID", specs = {103, 104} }, -- Feral/Guardian (Boomy=Solar Beam, Resto=none baseline)
    [2139]   = { name = "Counterspell",         cd = 24,  class = "MAGE" },
    [1766]   = { name = "Kick",                 cd = 15,  class = "ROGUE" },
    [6552]   = { name = "Pummel",               cd = 15,  class = "WARRIOR" },
    [47528]  = { name = "Mind Freeze",          cd = 15,  class = "DEATHKNIGHT" },
    [96231]  = { name = "Rebuke",               cd = 15,  class = "PALADIN" },
    [116705] = { name = "Spear Hand Strike",    cd = 15,  class = "MONK" },
    [57994]  = { name = "Wind Shear",           cd = 12,  class = "SHAMAN" },
    [183752] = { name = "Disrupt",              cd = 15,  class = "DEMONHUNTER" },
    [351338] = { name = "Quell",                cd = 40,  class = "EVOKER" },
    [147362] = { name = "Counter Shot",         cd = 24,  class = "HUNTER", specs = {253, 254} }, -- BM/MM (Surv=Muzzle 187707)
}

------------------------------------------------------------------------
-- Crowd Control (ST + AoE combined)
------------------------------------------------------------------------
-- Gating legend (used by CommSync PrePopulatePersonalCDs fallback):
--   talentOnly = true     — never pre-pop; AuraDetector surfaces on cast
--   specs = {specID, ...} — only pre-pop when unit's spec matches
--   (no gate)             — class-baseline for every spec
local CC = {
    -- Only CC spells with a real cooldown are tracked — there's nothing to
    -- coordinate for free-cast CC (Polymorph 118, Entangling Roots 339,
    -- Hibernate 2637, Banish 710, Fear 5782, Shackle Undead 9484, Mind
    -- Control 605, Sleep Walk 360806): they'd just sit on the bar forever
    -- as "Ready" and clutter the view. Removed 2026-04.
    -- Single-target
    [51514]  = { name = "Hex",                  cd = 30,  class = "SHAMAN" },
    [20066]  = { name = "Repentance",           cd = 15,  class = "PALADIN", specs = {70} }, -- Ret baseline, talent for Holy/Prot
    [853]    = { name = "Hammer of Justice",    cd = 60,  class = "PALADIN" }, -- baseline all specs; 6s stun, reduced to 30s CD with Fist of Justice talent
    [217832] = { name = "Imprison",             cd = 45,  class = "DEMONHUNTER" },
    [115078] = { name = "Paralysis",            cd = 45,  class = "MONK" },
    [47476]  = { name = "Strangulate",          cd = 45,  class = "DEATHKNIGHT", specs = {250}, pvpTalent = true }, -- Blood PvP talent (4s silence; replaces Asphyxiate)
    [116844] = { name = "Ring of Peace",        cd = 45,  class = "MONK", talentOnly = true }, -- class-tree talent, knockback area-denial
    [368970] = { name = "Tail Swipe",           cd = 180, class = "EVOKER" }, -- baseline (Evoker-only since 11.0.5); AoE knockback + 70% slow
    -- AoE
    [192058] = { name = "Capacitor Totem",      cd = 60,  class = "SHAMAN" },
    [113724] = { name = "Ring of Frost",        cd = 45,  class = "MAGE", talentOnly = true }, -- Mage general talent
    [102793] = { name = "Ursol's Vortex",       cd = 60,  class = "DRUID", talentOnly = true },
    [202137] = { name = "Sigil of Silence",     cd = 60,  class = "DEMONHUNTER", specs = {581, 1480} }, -- Vengeance/Aldrachi baseline, Havoc talent
    [207684] = { name = "Sigil of Misery",      cd = 120, class = "DEMONHUNTER", specs = {581, 1480} }, -- Vengeance/Aldrachi baseline
    [105421] = { name = "Blinding Light",       cd = 60,  class = "PALADIN", talentOnly = true }, -- Paladin talent
    [102359] = { name = "Mass Entanglement",    cd = 30,  class = "DRUID", talentOnly = true },
    [99]     = { name = "Incapacitating Roar",  cd = 30,  class = "DRUID", talentOnly = true }, -- class-tree talent (all Druid specs; AoE 3s incapacitate via Bear Form)
    [132469] = { name = "Typhoon",              cd = 30,  class = "DRUID", talentOnly = true }, -- class-tree talent (AoE knockback + 50% slow)
    [5211]   = { name = "Mighty Bash",          cd = 60,  class = "DRUID", talentOnly = true }, -- class-tree talent (ST 4s stun)
    [122]    = { name = "Frost Nova",           cd = 30,  class = "MAGE" }, -- baseline (AoE 6s root, damage breaks)
    [31661]  = { name = "Dragon's Breath",      cd = 45,  class = "MAGE", specs = {63} }, -- Fire baseline (cone 4s disorient)
    [2094]   = { name = "Blind",                cd = 120, class = "ROGUE" }, -- baseline (ST 60s disorient; damage interrupts)
    [5484]   = { name = "Howl of Terror",       cd = 40,  class = "WARLOCK", talentOnly = true }, -- class talent (AoE 20s fear, 5 targets)
    [6789]   = { name = "Mortal Coil",          cd = 45,  class = "WARLOCK", talentOnly = true }, -- class talent (ST 3s horror + 20% max HP self-heal)
    [107570] = { name = "Storm Bolt",           cd = 30,  class = "WARRIOR", talentOnly = true }, -- class talent (ST 4s stun)
    [46968]  = { name = "Shockwave",            cd = 35,  class = "WARRIOR", talentOnly = true }, -- talent (cone 2s AoE stun; primarily Prot)
    [19577]  = { name = "Intimidation",         cd = 60,  class = "HUNTER", specs = {253, 255}, talentOnly = true }, -- BM/Surv talent (pet-cast 5s stun)
    [109248] = { name = "Binding Shot",         cd = 45,  class = "HUNTER", talentOnly = true }, -- class talent (AoE tether-into-3s-stun on movement)
    [108194] = { name = "Asphyxiate",           cd = 45,  class = "DEATHKNIGHT", specs = {251, 252}, talentOnly = true }, -- Frost/Unholy talent (ST 4s stun)
    [108199] = { name = "Gorefiend's Grasp",    cd = 90,  class = "DEATHKNIGHT", talentOnly = true }, -- class talent all specs (AoE pull 15y + 3s silence)
    [202138] = { name = "Sigil of Chains",      cd = 90,  class = "DEMONHUNTER", specs = {581, 1480}, talentOnly = true }, -- Vengeance talent (AoE pull + 70% slow)
    [198898] = { name = "Song of Chi-Ji",       cd = 30,  class = "MONK", specs = {270}, talentOnly = true }, -- Mistweaver talent (slow-moving mist, AoE 20s disorient)
    [5246]   = { name = "Intimidating Shout",   cd = 90,  class = "WARRIOR" },
    [119381] = { name = "Leg Sweep",            cd = 60,  class = "MONK" },
    [8122]   = { name = "Psychic Scream",       cd = 45,  class = "PRIEST" },
    [88625]  = { name = "Holy Word: Chastise",  cd = 60,  class = "PRIEST", specs = {257} },  -- Holy stun (part of Holy Word rotation, basically baseline)
    [64044]  = { name = "Psychic Horror",       cd = 45,  class = "PRIEST", specs = {258}, talentOnly = true }, -- Shadow talent stun
    [30283]  = { name = "Shadowfury",           cd = 60,  class = "WARLOCK", talentOnly = true }, -- Warlock general talent
    [179057] = { name = "Chaos Nova",           cd = 60,  class = "DEMONHUNTER", specs = {577, 1480} }, -- Havoc/Aldrachi baseline, Vengeance talent
}

------------------------------------------------------------------------
-- Dispels
------------------------------------------------------------------------
-- Dispels are healer-spec locked. Spec IDs prevent ghost pre-pop on
-- DPS/tank specs of the same class (e.g. Ret Pala seeing Cleanse).
local DISPEL = {
    [88423]  = { name = "Nature's Cure",        cd = 8,   class = "DRUID",   specs = {105} },       -- Resto Druid
    [527]    = { name = "Purify",               cd = 8,   class = "PRIEST",  specs = {256, 257} },  -- Disc/Holy
    [4987]   = { name = "Cleanse",              cd = 8,   class = "PALADIN", specs = {65} },        -- Holy Paladin
    [77130]  = { name = "Purify Spirit",        cd = 8,   class = "SHAMAN",  specs = {264} },       -- Resto Shaman
    [115450] = { name = "Detox",                cd = 8,   class = "MONK",    specs = {270} },       -- Mistweaver
    [360823] = { name = "Naturalize",           cd = 8,   class = "EVOKER",  specs = {1468} },      -- Preservation
}

------------------------------------------------------------------------
-- Combined lookup: spellID → { name, cd, class, category }
------------------------------------------------------------------------
local ALL_SPELLS = {}

-- Category aliases: old name → new name (for backward compat in existing code)
local CATEGORY_ALIASES = {
    PARTY_RANGED      = "EXTERNAL_DEFENSIVE",
    PARTY_STACKED     = "EXTERNAL_DEFENSIVE",
    RANGED_DEFENSIVE  = "EXTERNAL_DEFENSIVE",
    STACKED_DEFENSIVE = "EXTERNAL_DEFENSIVE",
    INTERRUPT         = "KICK",
    ST_CC             = "CC",
    AOE_CC            = "CC",
}

local function Register(tbl, category)
    for id, info in pairs(tbl) do
        ALL_SPELLS[id] = {
            name = info.name,
            cd = info.cd,
            class = info.class,
            category = category,
            immune = info.immune,
            specs = info.specs,           -- nil = all specs of the class
            talentOnly = info.talentOnly, -- true = only shown when real talent data proves it
            pvpTalent = info.pvpTalent,   -- true = never pre-populated
            -- Per-spec category override (for hybrid spells): a table
            -- { [specID] = "CATEGORY" } that flips the bucket per spec.
            -- Example: Avenging Wrath is OFFENSIVE for Ret/Prot but HEALING
            -- for Holy (the 20% healing buff + 30% haste is Holy's burst
            -- heal window). Display layer passes the player's specID to
            -- GetCategory/GetByCategory to resolve correctly.
            categoryOverride = info.categoryOverride,
        }
    end
end

Register(PERSONAL, "PERSONAL")
Register(EXTERNAL_DEFENSIVE, "EXTERNAL_DEFENSIVE")
Register(UTILITY, "UTILITY")
Register(HEALING, "HEALING")
Register(OFFENSIVE, "OFFENSIVE")
Register(KICK, "KICK")
Register(CC, "CC")
Register(DISPEL, "DISPEL")

------------------------------------------------------------------------
-- All category names in display order (8 categories)
------------------------------------------------------------------------
DB.CATEGORIES = {
    "PERSONAL", "EXTERNAL_DEFENSIVE",
    "UTILITY", "HEALING", "OFFENSIVE", "KICK", "CC", "DISPEL",
}

DB.CATEGORY_LABELS = {
    PERSONAL            = "Personal Defensives",
    EXTERNAL_DEFENSIVE  = "External Defensives",
    UTILITY             = "Utility",
    HEALING             = "Healing CDs",
    OFFENSIVE           = "Offensive CDs",
    KICK                = "Kicks",
    CC                  = "Crowd Control",
    DISPEL              = "Dispels",
}

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function DB:GetSpell(spellID)
    return ALL_SPELLS[spellID]
end

--- Resolve a spell's category, optionally for a specific spec. If the
--- entry has a `categoryOverride` table and the caller passes a specID
--- that has an override entry, the override wins. Otherwise returns the
--- base category. Callers that don't know the spec (e.g. ConfigGUI
--- sidebar enumeration) should omit specID to get the base bucket.
function DB:GetCategory(spellID, specID)
    local s = ALL_SPELLS[spellID]
    if not s then return nil end
    if specID and s.categoryOverride and s.categoryOverride[specID] then
        return s.categoryOverride[specID]
    end
    return s.category
end

function DB:GetAllSpells()
    return ALL_SPELLS
end

--- Get spells by category. Accepts both new and old category names.
--- If specID is provided, per-spec categoryOverride is respected —
--- spells overridden INTO the requested category are included, and
--- spells overridden OUT of it are excluded. Callers that iterate
--- categories for config/UI enumeration should omit specID.
function DB:GetByCategory(category, specID)
    local resolved = CATEGORY_ALIASES[category] or category
    local result = {}
    for id, info in pairs(ALL_SPELLS) do
        local effective = info.category
        if specID and info.categoryOverride and info.categoryOverride[specID] then
            effective = info.categoryOverride[specID]
        end
        if effective == resolved then
            result[id] = info
        end
    end
    return result
end

function DB:IsTracked(spellID)
    return ALL_SPELLS[spellID] ~= nil
end

--- Resolve old category names to new names
function DB:ResolveCategory(category)
    return CATEGORY_ALIASES[category] or category
end
