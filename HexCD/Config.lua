------------------------------------------------------------------------
-- HexCD: Configuration & SavedVariables
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.Config = {}

local Config = HexCD.Config

local DEFAULTS = {
    -- Debug
    logLevel = "INFO",             -- OFF, ERRORS, INFO, DEBUG, TRACE

    -- Dispel Tracker
    dispelEnabled = true,
    dispelRotation = {},
    dispelAlertEnabled = true,
    dispelAnchorPoint = "CENTER",
    dispelAnchorX = 300,
    dispelAnchorY = 0,
    dispelBarWidth = 210,
    dispelBarHeight = 20,

    -- Dispel Tracker — Group 2
    dispelRotation2 = {},
    dispelAnchorPoint2 = "CENTER",
    dispelAnchorX2 = 300,
    dispelAnchorY2 = -80,

    -- Kick Tracker
    kickEnabled = true,
    kickRotation = {},
    kickAlertEnabled = true,
    kickAnchorPoint = "CENTER",
    kickAnchorX = -300,
    kickAnchorY = 0,
    kickBarWidth = 210,
    kickBarHeight = 20,

    -- Kick Tracker — Group 2
    kickRotation2 = {},
    kickAnchorPoint2 = "CENTER",
    kickAnchorX2 = -300,
    kickAnchorY2 = -80,

    -- TTS Settings (global defaults)
    hexcd_tts_enabled = true,     -- master TTS toggle
    ttsVoiceName = "",            -- empty = auto-detect (Amy → first available)
    ttsRate = 3,                  -- speech rate 1-10
    ttsVolume = 100,              -- volume 0-100
    -- Legacy keys (kept for backward compat)
    dispelAlertText = "Dispel",
    kickAlertText = "Kick",

    -- Party CD Display (legacy keys — migrated to hexcd_personal_* on init)
    partyCDAnchorSide = "RIGHT",
    partyCDOfsX = 4,
    partyCDOfsY = 0,
    partyCDGrowth = "RIGHT",
    partyCDIconSize = 24,
    partyCDIconPadding = 2,
    partyCDReadyAlpha = 1.0,
    partyCDActiveAlpha = 0.6,
    partyCDSwipeAlpha = 0.65,
    partyCDDesaturate = true,
    partyCDShowGlow = true,
    partyCDShowText = true,

    -- === Per-Tracker Settings (hexcd_{tracker}_{setting}) ===

    -- Personal Defensives (Panel A: anchored to unit frames)
    hexcd_personal_anchorSide = "RIGHT",
    hexcd_personal_ofsX = 4,
    hexcd_personal_ofsY = 0,
    hexcd_personal_growth = "RIGHT",
    hexcd_personal_iconSize = 24,
    hexcd_personal_iconPadding = 2,
    hexcd_personal_maxIconsPerRow = 6,
    hexcd_personal_maxRows = 1,
    hexcd_personal_desaturate = true,
    hexcd_personal_showText = true,
    hexcd_personal_showGlow = true,
    hexcd_personal_hideReady = false,
    hexcd_personal_readyAlpha = 1.0,
    hexcd_personal_activeCDAlpha = 0.6,

    -- Floating bar defaults (Panel B: shared by 6 trackers)
    -- Each uses hexcd_{slug}_* where slug = ranged/stacked/utility/healing/stcc/aoecc
    hexcd_external_iconSize = 24,
    hexcd_external_iconPadding = 2,
    hexcd_external_maxIcons = 6,
    hexcd_external_nameWidth = 55,
    hexcd_external_hideTitle = false,
    hexcd_external_desaturate = true,
    hexcd_external_showText = true,
    hexcd_external_showTooltips = false,
    hexcd_external_hideReady = false,
    hexcd_external_barAlpha = 0.75,

    hexcd_utility_iconSize = 24,
    hexcd_utility_iconPadding = 2,
    hexcd_utility_maxIcons = 6,
    hexcd_utility_nameWidth = 55,
    hexcd_utility_hideTitle = false,
    hexcd_utility_desaturate = true,
    hexcd_utility_showText = true,
    hexcd_utility_showTooltips = false,
    hexcd_utility_hideReady = false,
    hexcd_utility_barAlpha = 0.75,

    hexcd_healing_iconSize = 24,
    hexcd_healing_iconPadding = 2,
    hexcd_healing_maxIcons = 6,
    hexcd_healing_nameWidth = 55,
    hexcd_healing_hideTitle = false,
    hexcd_healing_desaturate = true,
    hexcd_healing_showText = true,
    hexcd_healing_showTooltips = false,
    hexcd_healing_hideReady = false,
    hexcd_healing_barAlpha = 0.75,

    hexcd_cc_iconSize = 24,
    hexcd_cc_iconPadding = 2,
    hexcd_cc_maxIcons = 6,
    hexcd_cc_nameWidth = 55,
    hexcd_cc_hideTitle = false,
    hexcd_cc_desaturate = true,
    hexcd_cc_showText = true,
    hexcd_cc_showTooltips = false,
    hexcd_cc_hideReady = false,
    hexcd_cc_barAlpha = 0.75,

    -- Rotation overlay defaults (Panel C: kicks + dispels)
    hexcd_kicks_ttsEnabled = true,
    hexcd_kicks_alertText = "Kick",
    hexcd_kicks_ttsVoice = "",       -- empty = use global default
    hexcd_kicks_ttsRate = 0,         -- 0 = use global default
    hexcd_kicks_ttsVolume = 0,       -- 0 = use global default
    hexcd_kicks_barWidth = 210,
    hexcd_kicks_barHeight = 20,
    hexcd_kicks_showInRaid = false,

    hexcd_dispels_ttsEnabled = true,
    hexcd_dispels_alertText = "Dispel",
    hexcd_dispels_ttsVoice = "",     -- empty = use global default
    hexcd_dispels_ttsRate = 0,       -- 0 = use global default
    hexcd_dispels_ttsVolume = 0,     -- 0 = use global default
    hexcd_dispels_barWidth = 210,
    hexcd_dispels_barHeight = 20,
    hexcd_dispels_showInRaid = false,

    -- Detection layer toggles
    hexcd_layer_aura = true,
    hexcd_layer_direct = true,
    hexcd_layer_launder = true,
    hexcd_layer_comms = true,

    -- Auto-open debug log
    autoOpenLog = false,
}

-- Migration: old partyCDFoo keys → hexcd_personal_foo
local MIGRATIONS = {
    { old = "partyCDAnchorSide",  new = "hexcd_personal_anchorSide" },
    { old = "partyCDOfsX",        new = "hexcd_personal_ofsX" },
    { old = "partyCDOfsY",        new = "hexcd_personal_ofsY" },
    { old = "partyCDGrowth",      new = "hexcd_personal_growth" },
    { old = "partyCDIconSize",    new = "hexcd_personal_iconSize" },
    { old = "partyCDIconPadding", new = "hexcd_personal_iconPadding" },
    { old = "partyCDReadyAlpha",  new = "hexcd_personal_readyAlpha" },
    { old = "partyCDActiveAlpha", new = "hexcd_personal_activeCDAlpha" },
    { old = "partyCDDesaturate",  new = "hexcd_personal_desaturate" },
    { old = "partyCDShowGlow",    new = "hexcd_personal_showGlow" },
    { old = "partyCDShowText",    new = "hexcd_personal_showText" },
}

--- Initialize config with defaults for missing keys
function Config:Init()
    if not HexCDDB then
        HexCDDB = HexCD.Util.DeepCopy(DEFAULTS)
        return
    end
    -- Apply defaults for missing keys
    for k, v in pairs(DEFAULTS) do
        if HexCDDB[k] == nil then
            HexCDDB[k] = HexCD.Util.DeepCopy(v)
        elseif type(v) == "table" and type(HexCDDB[k]) == "table" then
            for sk, sv in pairs(v) do
                if HexCDDB[k][sk] == nil then
                    HexCDDB[k][sk] = HexCD.Util.DeepCopy(sv)
                end
            end
        end
    end
    -- Migrate old keys to new (copy value, keep old for backward compat)
    for _, m in ipairs(MIGRATIONS) do
        if HexCDDB[m.old] ~= nil and HexCDDB[m.new] == DEFAULTS[m.new] then
            HexCDDB[m.new] = HexCDDB[m.old]
        end
    end
end

--- Get a config value
---@param key string
---@return any
function Config:Get(key)
    if HexCDDB and HexCDDB[key] ~= nil then
        return HexCDDB[key]
    end
    return DEFAULTS[key]
end

--- Set a config value
---@param key string
---@param value any
function Config:Set(key, value)
    if not HexCDDB then HexCDDB = HexCD.Util.DeepCopy(DEFAULTS) end
    HexCDDB[key] = value
end
