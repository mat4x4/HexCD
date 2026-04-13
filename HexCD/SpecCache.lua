------------------------------------------------------------------------
-- HexCD: SpecCache — cross-realm persistent spec ID cache
--
-- Mirrors MiniCC's Talents.lua unitTalentSpecId pattern. We key the cache
-- by player name (realm stripped) so once a unit's spec is learned via
-- INSPECT_READY or by observing a spec-exclusive spell cast, subsequent
-- lookups resolve even after the unit token changes (leave/rejoin) or
-- for cross-realm party members where GetInspectSpecialization flakes.
--
-- Sources, tagged on each entry:
--   * "inspect" — from GetInspectSpecialization after INSPECT_READY
--   * "spell"   — inferred from a cast of a spec-exclusive spell
--   * "live"    — direct GetSpecialization for the local player
--
-- Consumers: CommSync.ResolveUnitSpecID reads this cache before falling
-- back to the raw API.
------------------------------------------------------------------------

HexCD = HexCD or {}
HexCD.SpecCache = HexCD.SpecCache or {}
local SC = HexCD.SpecCache

-- name → { specID, source, at }
local cache = {}

-- spec-exclusive cast spell IDs (for inference). Partial list; extend as
-- ambiguity surfaces. These are spells only one spec can cast.
SC.SpellToSpec = SC.SpellToSpec or {
    -- PALADIN
    [31884]  = nil,    -- Avenging Wrath is multi-spec (Prot 66, Ret 70)
    [216331] = 65,     -- Avenging Crusader → Holy Pala
    [389539] = 66,     -- Sentinel → Prot Pala (talent-gated)
    -- MAGE
    [190319] = 63,     -- Combustion → Fire Mage
    [12472]  = 64,     -- Icy Veins (base) → Frost Mage
    [12042]  = 62,     -- Arcane Power/legacy variant — Arcane
    -- HUNTER
    [186289] = 253,    -- Aspect of the Eagle legacy — Beast Mastery
    [288613] = 254,    -- Trueshot → Marksmanship
    -- PRIEST
    [47585]  = 258,    -- Dispersion → Shadow Priest
    [200183] = 257,    -- Apotheosis → Holy Priest
    [47788]  = 257,    -- Guardian Spirit → Holy Priest
    [33206]  = 256,    -- Pain Suppression → Discipline Priest
    -- SHAMAN
    [114050] = 262,    -- Ascendance (Elemental variant)
    [114051] = 263,    -- Ascendance (Enhancement variant)
    [114052] = 264,    -- Ascendance (Restoration variant)
    [108280] = 264,    -- Healing Tide Totem → Restoration Shaman
    -- DRUID
    [33891]  = 105,    -- Incarnation: Tree of Life → Restoration Druid
    [102560] = 102,    -- Incarnation: Chosen of Elune → Balance
    [102543] = 103,    -- Incarnation: Avatar of Ashamane → Feral
    [102558] = 104,    -- Incarnation: Guardian of Ursoc → Guardian
    -- DK
    [55233]  = 250,    -- Vampiric Blood → Blood DK
    [51271]  = 251,    -- Pillar of Frost → Frost DK
    -- MONK
    [322507] = 268,    -- Celestial Brew → Brewmaster
    [115310] = 270,    -- Revival → Mistweaver
    [137639] = 269,    -- Storm, Earth, Fire → Windwalker
    -- DH
    [196718] = 577,    -- Darkness → Havoc
    [187827] = 581,    -- Metamorphosis (Vengeance variant)
    -- EVOKER
    [363534] = 1467,   -- Rewind → Preservation
    [357170] = 1468,   -- Time Dilation → Preservation
    [375087] = 1467,   -- Dragonrage — actually Devastation; adjust if needed
    -- WARLOCK
    [212295] = nil,    -- Nether Ward PvP talent (no spec)
    [104773] = nil,    -- Unending Resolve (all specs)
}

local function KeyForName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

--- Store a spec for a player name with a source tag. Subsequent stores
--- with a higher-trust source overwrite — precedence: live > inspect > spell.
local TRUST = { live = 3, inspect = 2, spell = 1 }

function SC:Put(name, specID, source)
    local key = KeyForName(name)
    if not key or not specID or specID == 0 then return end
    source = source or "inspect"
    local existing = cache[key]
    if existing and (TRUST[existing.source] or 0) > (TRUST[source] or 0) then
        return  -- keep higher-trust entry
    end
    cache[key] = { specID = specID, source = source, at = GetTime and GetTime() or 0 }
end

function SC:Get(name)
    local key = KeyForName(name)
    local e = cache[key]
    return e and e.specID or nil
end

function SC:GetEntry(name)
    return cache[KeyForName(name)]
end

function SC:Clear()
    cache = {}
end

--- Try to resolve a unit's spec: cache first, else live API, else nil.
--- If the cache entry is low-trust (source="spell"), we still check the
--- live API to allow inspect/live upgrades. High-trust entries short-circuit.
function SC:ResolveUnit(unit)
    local name = UnitName and UnitName(unit) or nil
    local key = KeyForName(name)
    local cached = key and cache[key] or nil
    if cached and (TRUST[cached.source] or 0) >= TRUST.inspect then
        return cached.specID
    end

    local sid = nil
    pcall(function()
        if unit == "player" and GetSpecialization and GetSpecializationInfo then
            local idx = GetSpecialization()
            if idx and idx > 0 then
                local id = GetSpecializationInfo(idx)
                if id and id ~= 0 and not (issecretvalue and issecretvalue(id)) then
                    sid = id
                end
            end
        elseif GetInspectSpecialization then
            local id = GetInspectSpecialization(unit)
            if id and id ~= 0 and not (issecretvalue and issecretvalue(id)) then
                sid = id
            end
        end
    end)

    if sid and name then
        SC:Put(name, sid, unit == "player" and "live" or "inspect")
        return sid
    end
    -- Live API failed — fall back to low-trust cached value (or nil)
    return cached and cached.specID or nil
end

--- Called on UNIT_SPELLCAST_SUCCEEDED for any unit. If the cast spellID is
--- spec-exclusive in SpellToSpec, cache the inferred spec (low trust).
function SC:ObserveCast(unit, spellID)
    if not spellID or not unit then return end
    local inferredSpec = SC.SpellToSpec and SC.SpellToSpec[spellID]
    if not inferredSpec then return end
    local name = UnitName and UnitName(unit) or nil
    if not name then return end
    SC:Put(name, inferredSpec, "spell")
end

--- Test-only: inject directly.
function SC:_testPut(name, specID, source)
    SC:Put(name, specID, source)
end

function SC:_testClear()
    cache = {}
end
