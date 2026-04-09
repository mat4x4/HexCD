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
    dispelEnabled = false,
    dispelRotation = {},
    dispelAlertEnabled = true,
    dispelAnchorPoint = "CENTER",
    dispelAnchorX = 300,
    dispelAnchorY = 0,
    dispelBarWidth = 210,
    dispelBarHeight = 20,

    -- Kick Tracker
    kickEnabled = false,
    kickRotation = {},
    kickAlertEnabled = true,
    kickAnchorPoint = "CENTER",
    kickAnchorX = -300,
    kickAnchorY = 0,
    kickBarWidth = 210,
    kickBarHeight = 20,

    -- Party CD Display
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
}

--- Initialize config with defaults for missing keys
function Config:Init()
    if not HexCDDB then
        HexCDDB = HexCD.Util.DeepCopy(DEFAULTS)
        return
    end
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
