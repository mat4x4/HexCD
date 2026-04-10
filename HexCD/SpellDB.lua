------------------------------------------------------------------------
-- HexCD: SpellDB — Spell database for party CD tracking
--
-- Categories:
--   PERSONAL    — Personal defensives + immunities (per-player)
--   PARTY_RANGED — Party defensives that work at range (Rally, VE)
--   PARTY_STACKED — Party defensives requiring stacking (AMZ, Darkness, Barrier)
--   HEALING     — Major healing throughput CDs
--   INTERRUPT   — Interrupts
--   DISPEL      — Healer dispels
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.SpellDB = {}

local DB = HexCD.SpellDB

------------------------------------------------------------------------
-- Personal Defensives + Immunities (keyed by spellID)
------------------------------------------------------------------------
local PERSONAL = {
    -- Death Knight
    [48792]  = { name = "Icebound Fortitude",   cd = 180, class = "DEATHKNIGHT" },
    [48707]  = { name = "Anti-Magic Shell",     cd = 60,  class = "DEATHKNIGHT" },
    [49039]  = { name = "Lichborne",            cd = 120, class = "DEATHKNIGHT" },
    -- Demon Hunter
    [198589] = { name = "Blur",                 cd = 60,  class = "DEMONHUNTER" },
    [196555] = { name = "Netherwalk",           cd = 180, class = "DEMONHUNTER", immune = true },
    -- Druid
    [22812]  = { name = "Barkskin",             cd = 60,  class = "DRUID" },
    [61336]  = { name = "Survival Instincts",   cd = 180, class = "DRUID" },
    -- Evoker
    [363916] = { name = "Obsidian Scales",      cd = 150, class = "EVOKER" },
    [374349] = { name = "Renewing Blaze",       cd = 90,  class = "EVOKER" },
    -- Hunter
    [186265] = { name = "Aspect of the Turtle", cd = 180, class = "HUNTER", immune = true },
    [264735] = { name = "Survival of the Fittest", cd = 180, class = "HUNTER" },
    [109304] = { name = "Exhilaration",         cd = 120, class = "HUNTER" },
    -- Mage
    [45438]  = { name = "Ice Block",            cd = 240, class = "MAGE", immune = true },
    [414658] = { name = "Ice Cold",             cd = 120, class = "MAGE" },
    [110960] = { name = "Greater Invisibility",  cd = 120, class = "MAGE" },
    [342245] = { name = "Alter Time",           cd = 60,  class = "MAGE" },
    -- Monk
    [122278] = { name = "Dampen Harm",          cd = 120, class = "MONK" },
    [122783] = { name = "Diffuse Magic",        cd = 90,  class = "MONK" },
    [243435] = { name = "Fortifying Brew",      cd = 180, class = "MONK" },
    -- Paladin
    [642]    = { name = "Divine Shield",        cd = 300, class = "PALADIN", immune = true },
    [498]    = { name = "Divine Protection",    cd = 60,  class = "PALADIN" },
    [184662] = { name = "Shield of Vengeance",  cd = 90,  class = "PALADIN" },
    -- Priest
    [19236]  = { name = "Desperate Prayer",     cd = 90,  class = "PRIEST" },
    [47585]  = { name = "Dispersion",           cd = 120, class = "PRIEST" },
    -- Rogue
    [5277]   = { name = "Evasion",              cd = 120, class = "ROGUE" },
    [31224]  = { name = "Cloak of Shadows",     cd = 120, class = "ROGUE" },
    [1966]   = { name = "Feint",                cd = 15,  class = "ROGUE" },
    -- Shaman
    [108271] = { name = "Astral Shift",         cd = 120, class = "SHAMAN" },
    -- Warlock
    [104773] = { name = "Unending Resolve",     cd = 180, class = "WARLOCK" },
    [108416] = { name = "Dark Pact",            cd = 60,  class = "WARLOCK" },
    -- Warrior
    [871]    = { name = "Shield Wall",          cd = 210, class = "WARRIOR" },
    [12975]  = { name = "Last Stand",           cd = 180, class = "WARRIOR" },
    [118038] = { name = "Die by the Sword",     cd = 120, class = "WARRIOR" },
    [184364] = { name = "Enraged Regeneration",  cd = 120, class = "WARRIOR" },
}

------------------------------------------------------------------------
-- Ranged Party Defensives (affect group regardless of position)
------------------------------------------------------------------------
local PARTY_RANGED = {
    [97462]  = { name = "Rallying Cry",         cd = 180, class = "WARRIOR" },
    [15286]  = { name = "Vampiric Embrace",     cd = 120, class = "PRIEST" },
}

------------------------------------------------------------------------
-- Stacked Party Defensives (require positioning / area effect)
------------------------------------------------------------------------
local PARTY_STACKED = {
    [51052]  = { name = "Anti-Magic Zone",      cd = 120, class = "DEATHKNIGHT" },
    [196718] = { name = "Darkness",             cd = 180, class = "DEMONHUNTER" },
    [62618]  = { name = "Power Word: Barrier",  cd = 180, class = "PRIEST" },
    [98008]  = { name = "Spirit Link Totem",    cd = 180, class = "SHAMAN" },
    [31821]  = { name = "Aura Mastery",         cd = 180, class = "PALADIN" },
    [374227] = { name = "Zephyr",               cd = 120, class = "EVOKER" },
}

------------------------------------------------------------------------
-- Healing CDs (major throughput cooldowns)
------------------------------------------------------------------------
local HEALING = {
    [740]    = { name = "Tranquility",          cd = 180, class = "DRUID" },
    [391528] = { name = "Convoke the Spirits",  cd = 60,  class = "DRUID" },
    [132158] = { name = "Nature's Swiftness",   cd = 60,  class = "DRUID" },
    [102342] = { name = "Ironbark",             cd = 60,  class = "DRUID" },
    [33891]  = { name = "Incarnation: ToL",     cd = 180, class = "DRUID" },
    [197721] = { name = "Flourish",             cd = 90,  class = "DRUID" },
    [64843]  = { name = "Divine Hymn",          cd = 180, class = "PRIEST" },
    [200183] = { name = "Apotheosis",           cd = 120, class = "PRIEST" },
    [33206]  = { name = "Pain Suppression",     cd = 90,  class = "PRIEST" },
    [108280] = { name = "Healing Tide Totem",   cd = 180, class = "SHAMAN" },
    [363534] = { name = "Rewind",               cd = 240, class = "EVOKER" },
    [359816] = { name = "Dream Flight",         cd = 120, class = "EVOKER" },
    [216331] = { name = "Avenging Crusader",    cd = 120, class = "PALADIN" },
    [115310] = { name = "Revival",              cd = 180, class = "MONK" },
    [325197] = { name = "Invoke Chi-Ji",        cd = 180, class = "MONK" },
}

------------------------------------------------------------------------
-- Interrupts
------------------------------------------------------------------------
local INTERRUPT = {
    [106839] = { name = "Skull Bash",           cd = 15,  class = "DRUID" },
    [2139]   = { name = "Counterspell",         cd = 24,  class = "MAGE" },
    [1766]   = { name = "Kick",                 cd = 15,  class = "ROGUE" },
    [6552]   = { name = "Pummel",               cd = 15,  class = "WARRIOR" },
    [47528]  = { name = "Mind Freeze",          cd = 15,  class = "DEATHKNIGHT" },
    [96231]  = { name = "Rebuke",               cd = 15,  class = "PALADIN" },
    [116705] = { name = "Spear Hand Strike",    cd = 15,  class = "MONK" },
    [57994]  = { name = "Wind Shear",           cd = 12,  class = "SHAMAN" },
    [183752] = { name = "Disrupt",              cd = 15,  class = "DEMONHUNTER" },
    [351338] = { name = "Quell",                cd = 40,  class = "EVOKER" },
}

------------------------------------------------------------------------
-- Dispels
------------------------------------------------------------------------
local DISPEL = {
    [88423]  = { name = "Nature's Cure",        cd = 8,   class = "DRUID" },
    [527]    = { name = "Purify",               cd = 8,   class = "PRIEST" },
    [4987]   = { name = "Cleanse",              cd = 8,   class = "PALADIN" },
    [77130]  = { name = "Purify Spirit",        cd = 8,   class = "SHAMAN" },
    [115450] = { name = "Detox",                cd = 8,   class = "MONK" },
    [360823] = { name = "Naturalize",           cd = 8,   class = "EVOKER" },
}

------------------------------------------------------------------------
-- Combined lookup: spellID → { name, cd, class, category }
------------------------------------------------------------------------
local ALL_SPELLS = {}
local function Register(tbl, category)
    for id, info in pairs(tbl) do
        ALL_SPELLS[id] = {
            name = info.name,
            cd = info.cd,
            class = info.class,
            category = category,
            immune = info.immune,
        }
    end
end
Register(PERSONAL, "PERSONAL")
Register(PARTY_RANGED, "PARTY_RANGED")
Register(PARTY_STACKED, "PARTY_STACKED")
Register(HEALING, "HEALING")
Register(INTERRUPT, "INTERRUPT")
Register(DISPEL, "DISPEL")

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function DB:GetSpell(spellID)
    return ALL_SPELLS[spellID]
end

function DB:GetCategory(spellID)
    local s = ALL_SPELLS[spellID]
    return s and s.category or nil
end

function DB:GetAllSpells()
    return ALL_SPELLS
end

function DB:GetByCategory(category)
    local result = {}
    for id, info in pairs(ALL_SPELLS) do
        if info.category == category then
            result[id] = info
        end
    end
    return result
end

function DB:IsTracked(spellID)
    return ALL_SPELLS[spellID] ~= nil
end
