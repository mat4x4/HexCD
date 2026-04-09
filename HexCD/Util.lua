------------------------------------------------------------------------
-- HexCD: Shared Utilities
------------------------------------------------------------------------
local ADDON_NAME = ...
HexCD = HexCD or {}
HexCD.Util = {}

local Util = HexCD.Util

--- Format seconds into "M:SS" string
---@param sec number
---@return string
function Util.FormatTime(sec)
    if not sec or sec < 0 then return "0:00" end
    local m = math.floor(sec / 60)
    local s = math.floor(sec % 60)
    return string.format("%d:%02d", m, s)
end

--- Format seconds into "Xs" or "M:SS" depending on magnitude
---@param sec number
---@return string
function Util.FormatCountdown(sec)
    if not sec or sec < 0 then return "0" end
    if sec < 60 then
        return string.format("%.0f", sec)
    end
    return Util.FormatTime(sec)
end

--- Marker spell IDs per spec. Markers are planning-only signals (not real CDs).
--- Specs without markers use an empty table — all abilities are "burn".
Util.SPEC_MARKERS = {
    ["Druid:Restoration"] = {
        [774] = "fullRamp",   -- Ramp entry (pre-HoT setup window)
        [768] = "catWeave",   -- Cat Weave (mana recovery downtime)
    },
    -- Evoker:Preservation has no ramp markers — all CDs are direct burns
}

--- Current spec's marker table (set by SetSpecMarkers)
local activeMarkers = Util.SPEC_MARKERS["Druid:Restoration"] or {}

--- Switch active markers to match the player's spec.
---@param className string
---@param specName string
function Util.SetSpecMarkers(className, specName)
    local key = Util.NormalizeClassName(className) .. ":" .. specName
    activeMarkers = Util.SPEC_MARKERS[key] or {}
end

--- Detect ramp type from ability ID (source of truth)
--- Returns "fullRamp", "catWeave", or "burn" depending on current spec's markers.
---@param abilityGameID number
---@return string "fullRamp"|"burn"|"catWeave"
function Util.DetectRampType(abilityGameID)
    return activeMarkers[abilityGameID] or "burn"
end

--- Check if a spell ID is a marker (not a real CD) for the current spec.
---@param abilityGameID number
---@return boolean
function Util.IsMarkerSpell(abilityGameID)
    return activeMarkers[abilityGameID] ~= nil
end

--- Get ramp display label
---@param rampType string
---@return string
function Util.RampLabel(rampType)
    if rampType == "fullRamp" then
        return "RAMP"
    elseif rampType == "burn" then
        return "BURN"
    elseif rampType == "catWeave" then
        return "CAT"
    end
    return ""
end

--- Get player class and spec
---@return string className, string specName
function Util.GetPlayerSpec()
    local _, className = UnitClass("player")
    local specIndex = GetSpecialization()
    local specName = ""
    if specIndex then
        local _, name = GetSpecializationInfo(specIndex)
        specName = name or ""
    end
    return className, specName
end

--- Normalize class name for plan matching (e.g., "DRUID" → "Druid")
---@param className string
---@return string
function Util.NormalizeClassName(className)
    if not className then return "" end
    return className:sub(1, 1):upper() .. className:sub(2):lower()
end

--- Class colors for bar tinting
Util.CLASS_COLORS = {
    Druid   = { r = 1.00, g = 0.49, b = 0.04 },
    Shaman  = { r = 0.00, g = 0.44, b = 0.87 },
    Paladin = { r = 0.96, g = 0.55, b = 0.73 },
    Priest  = { r = 1.00, g = 1.00, b = 1.00 },
    Monk    = { r = 0.00, g = 1.00, b = 0.59 },
    Evoker  = { r = 0.20, g = 0.58, b = 0.50 },
}

--- Deep copy a table
---@param t table
---@return table
function Util.DeepCopy(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = Util.DeepCopy(v)
    end
    return copy
end
