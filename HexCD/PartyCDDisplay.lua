------------------------------------------------------------------------
-- HexCD: PartyCDDisplay — Party CD icon grid with independent trackers
--
-- Four independent tracker bars, each movable:
--   1. PERSONAL    — Personal defensives + immunities (per-player, anchored to unit frames)
--   2. PARTY_RANGED  — Rally, VE etc. (floating bar showing all players)
--   3. PARTY_STACKED — AMZ, Darkness, Barrier etc. (floating bar)
--   4. HEALING     — Tranq, Hymn, Convoke etc. (floating bar)
--
-- Personal defensives anchor to each player's unit frame.
-- Party-wide CD bars are floating panels showing who has what ready.
------------------------------------------------------------------------
HexCD = HexCD or {}
HexCD.PartyCDDisplay = {}

local PCD = HexCD.PartyCDDisplay
local Config = HexCD.Config
local Log = HexCD.DebugLog

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------
local ICON_SIZE = 24
local ICON_PADDING = 2
local MAX_ICONS_PER_PLAYER = 6
local MAX_PLAYERS = 5
local UPDATE_INTERVAL = 0.25
local BAR_ROW_HEIGHT = 26
local BAR_NAME_WIDTH = 55

-- Categories that anchor per-player to unit frames
local ANCHORED_CATEGORIES = { PERSONAL = true }

-- Categories that get their own floating bar
local FLOATING_CATEGORIES = { "PARTY_RANGED", "PARTY_STACKED", "HEALING" }
local FLOATING_TITLES = {
    PARTY_RANGED  = "|cFF44CC44Ranged Party CDs|r",
    PARTY_STACKED = "|cFFCC8844Stacked Party CDs|r",
    HEALING       = "|cFF4488CCHealing CDs|r",
}

------------------------------------------------------------------------
-- Unit Frame detection (Danders, Cell, ElvUI, Blizzard)
------------------------------------------------------------------------
local UF_PATTERNS = {
    { name = "Danders",      frames = "DandersFrames_Party%d",             unit = "unit", count = 4 },
    { name = "Danders-Player", frames = "DandersFrames_Player",            unit = "unit", count = 1, noIndex = true },
    { name = "Danders-Raid", frames = "DandersRaidFrame%d",                unit = "unit", count = 40 },
    { name = "Cell",         frames = "CellPartyFrameHeaderUnitButton%d",  unit = "unit", count = 5 },
    { name = "Cell-Raid",    frames = "CellRaidFrameHeader1UnitButton%d",  unit = "unit", count = 40 },
    { name = "ElvUI",        frames = "ElvUF_PartyGroup1UnitButton%d",     unit = "unit", count = 5 },
    { name = "Blizzard",     frames = "CompactPartyFrameMember%d",         unit = "unit", count = 5 },
    { name = "Blizz-Raid",   frames = "CompactRaidFrame%d",               unit = "unit", count = 40 },
}

------------------------------------------------------------------------
-- State
------------------------------------------------------------------------
local isVisible = false
local updateFrame = nil
local onUpdateThrottle = 0

-- Personal defensives: playerName → { container, icons[] }
local personalBars = {}

-- Floating bars: category → { frame, rows[], ... }
local floatingBars = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local spellIconCache = {}
local function GetSpellIcon(spellID)
    if spellIconCache[spellID] then return spellIconCache[spellID] end
    local icon = nil
    pcall(function()
        if C_Spell and C_Spell.GetSpellInfo then
            local info = C_Spell.GetSpellInfo(spellID)
            if info and info.iconID then icon = info.iconID end
        end
    end)
    if not icon then
        pcall(function()
            if GetSpellTexture then icon = GetSpellTexture(spellID) end
        end)
    end
    if not icon then icon = "Interface\\Icons\\INV_Misc_QuestionMark" end
    spellIconCache[spellID] = icon
    return icon
end

local function FormatTime(sec)
    if sec <= 0 then return "" end
    if sec < 60 then return string.format("%d", sec) end
    return string.format("%d:%02d", sec / 60, sec % 60)
end

local function StripRealm(name)
    if not name then return name end
    return name:match("^([^-]+)") or name
end

local function IsSpellEnabled(spellID)
    if not Config then return true end
    local val = Config:Get("partyCDSpell_" .. spellID)
    if val == nil then return true end  -- default: enabled
    return val and true or false
end

------------------------------------------------------------------------
-- Icon creation
------------------------------------------------------------------------

local function CreateCDIcon(parent)
    local btn = CreateFrame("Frame", nil, parent)
    btn:SetSize(ICON_SIZE, ICON_SIZE)
    btn:Hide()

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetAllPoints()
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    local cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    cd:SetAllPoints()
    cd:SetDrawEdge(false)
    cd:SetSwipeColor(0, 0, 0, 0.65)
    cd:SetHideCountdownNumbers(true)
    btn.cooldown = cd

    local timeText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    timeText:SetPoint("CENTER", 0, 0)
    timeText:SetFont(timeText:GetFont(), 10, "OUTLINE")
    timeText:SetTextColor(1, 1, 1)
    btn.timeText = timeText

    local glow = btn:CreateTexture(nil, "OVERLAY")
    glow:SetPoint("TOPLEFT", -2, 2)
    glow:SetPoint("BOTTOMRIGHT", 2, -2)
    glow:SetColorTexture(1.0, 0.8, 0.0, 0.5)  -- bright yellow, test mode indicator
    glow:Hide()
    btn.glow = glow

    return btn
end

local function UpdateIcon(btn, spellID, state, now)
    btn.icon:SetTexture(GetSpellIcon(spellID))
    local remaining = math.max(0, state.readyTime - now)
    if remaining > 0 then
        btn.icon:SetDesaturated(true)
        btn.icon:SetAlpha(0.6)
        btn.glow:Hide()
        btn.timeText:SetText(FormatTime(remaining))
        local startTime = state.castTime or (now - state.effectiveCD + remaining)
        btn.cooldown:SetCooldown(startTime, state.effectiveCD)
    else
        btn.icon:SetDesaturated(false)
        btn.icon:SetAlpha(1.0)
        -- Show obvious glow only in test mode
        local CS = HexCD.CommSync
        if CS and CS:IsTestMode() then btn.glow:Show() else btn.glow:Hide() end
        btn.timeText:SetText("")
        btn.cooldown:Clear()
    end
    btn:Show()
end

------------------------------------------------------------------------
-- Find unit frame (Danders API first, then patterns)
------------------------------------------------------------------------

local function FindUnitFrame(playerName)
    -- Danders API
    if DandersFrames_GetAllFrames then
        local ok, allFrames = pcall(DandersFrames_GetAllFrames)
        if ok and allFrames then
            for _, f in ipairs(allFrames) do
                if f and f.unit then
                    local ok2, name = pcall(UnitName, f.unit)
                    if ok2 and name and not (issecretvalue and issecretvalue(name)) then
                        if StripRealm(name) == playerName then return f end
                    end
                end
            end
        end
    end

    -- Fallback: frame name patterns
    for _, pattern in ipairs(UF_PATTERNS) do
        for i = 1, pattern.count do
            local frameName = pattern.noIndex and pattern.frames or string.format(pattern.frames, i)
            local f = _G[frameName]
            if f then
                local unit = nil
                pcall(function()
                    unit = f[pattern.unit] or (f.GetAttribute and f:GetAttribute("unit"))
                end)
                if unit then
                    local ok, name = pcall(UnitName, unit)
                    if ok and name and not (issecretvalue and issecretvalue(name)) then
                        if StripRealm(name) == playerName then return f end
                    end
                end
            end
        end
    end

    -- Last resort: if this is the local player, use PlayerFrame
    local ok, localName = pcall(UnitName, "player")
    if ok and localName and StripRealm(localName) == playerName then
        if PlayerFrame and PlayerFrame:IsShown() then return PlayerFrame end
    end

    return nil
end

------------------------------------------------------------------------
-- PERSONAL DEFENSIVES: per-player, anchored to unit frames
------------------------------------------------------------------------

local function GetOrCreatePersonalBar(playerName)
    if personalBars[playerName] then return personalBars[playerName] end

    local container = CreateFrame("Frame", nil, UIParent)
    container:SetSize(MAX_ICONS_PER_PLAYER * (ICON_SIZE + ICON_PADDING), ICON_SIZE)
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(10)
    container:Hide()

    local icons = {}
    for i = 1, MAX_ICONS_PER_PLAYER do
        icons[i] = CreateCDIcon(container)
    end

    personalBars[playerName] = { container = container, icons = icons, unitFrame = nil }
    return personalBars[playerName]
end

local function UpdatePersonalBars(partyCD, now)
    local used = {}
    local side = Config and Config:Get("partyCDAnchorSide") or "RIGHT"
    local ofsX = Config and Config:Get("partyCDOfsX") or 4
    local ofsY = Config and Config:Get("partyCDOfsY") or 0
    local growth = Config and Config:Get("partyCDGrowth") or "RIGHT"
    local iconSize = Config and Config:Get("partyCDIconSize") or ICON_SIZE
    local padding = Config and Config:Get("partyCDIconPadding") or ICON_PADDING

    local point, relPoint
    if side == "LEFT" then point, relPoint = "TOPRIGHT", "TOPLEFT"; ofsX = -ofsX
    elseif side == "TOP" then point, relPoint = "BOTTOMLEFT", "TOPLEFT"
    elseif side == "BOTTOM" then point, relPoint = "TOPLEFT", "BOTTOMLEFT"; ofsY = -ofsY
    else point, relPoint = "TOPLEFT", "TOPRIGHT"
    end

    for playerName, pData in pairs(partyCD) do
        if type(pData) == "table" then
            -- Collect personal defensives for this player
            local spells = {}
            for spellID, state in pairs(pData) do
                if type(spellID) == "number" and type(state) == "table" and IsSpellEnabled(spellID) then
                    local dbInfo = HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID)
                    if dbInfo and dbInfo.category == "PERSONAL" then
                        table.insert(spells, { id = spellID, state = state })
                    end
                end
            end

            if #spells > 0 then
                table.sort(spells, function(a, b)
                    local ra = math.max(0, a.state.readyTime - now)
                    local rb = math.max(0, b.state.readyTime - now)
                    if (ra > 0) ~= (rb > 0) then return ra > 0 end
                    return a.id < b.id
                end)

                local bar = GetOrCreatePersonalBar(playerName)
                used[playerName] = true

                local uf = FindUnitFrame(playerName)
                if uf then
                    bar.container:SetParent(UIParent)
                    bar.container:SetFrameStrata("MEDIUM")
                    bar.container:SetFrameLevel(10)
                    bar.container:ClearAllPoints()
                    bar.container:SetPoint(point, uf, relPoint, ofsX, ofsY)
                    bar.unitFrame = uf
                    bar.container:Show()

                    local iconIdx = 0
                    for _, spell in ipairs(spells) do
                        if iconIdx >= MAX_ICONS_PER_PLAYER then break end
                        iconIdx = iconIdx + 1
                        local btn = bar.icons[iconIdx]
                        btn:SetSize(iconSize, iconSize)
                        btn:ClearAllPoints()
                        if growth == "LEFT" then
                            btn:SetPoint("RIGHT", -(iconIdx - 1) * (iconSize + padding), 0)
                        elseif growth == "DOWN" then
                            btn:SetPoint("TOP", 0, -(iconIdx - 1) * (iconSize + padding))
                        elseif growth == "UP" then
                            btn:SetPoint("BOTTOM", 0, (iconIdx - 1) * (iconSize + padding))
                        else
                            btn:SetPoint("LEFT", (iconIdx - 1) * (iconSize + padding), 0)
                        end
                        UpdateIcon(btn, spell.id, spell.state, now)
                    end
                    for i = iconIdx + 1, MAX_ICONS_PER_PLAYER do bar.icons[i]:Hide() end
                    if growth == "DOWN" or growth == "UP" then
                        bar.container:SetSize(iconSize, iconIdx * (iconSize + padding))
                    else
                        bar.container:SetSize(iconIdx * (iconSize + padding), iconSize)
                    end
                else
                    bar.container:Hide()
                end
            end
        end
    end

    for name, bar in pairs(personalBars) do
        if not used[name] then bar.container:Hide() end
    end
end

------------------------------------------------------------------------
-- FLOATING BARS: party-wide CDs (ranged, stacked, healing)
------------------------------------------------------------------------

local function CreateFloatingBar(category)
    local f = CreateFrame("Frame", "HexCDPartyCD_" .. category, UIParent, "BackdropTemplate")
    f:SetSize(200, 80)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(0.05, 0.05, 0.08, 0.75)
    f:SetBackdropBorderColor(0.3, 0.3, 0.35, 0.6)
    f:SetFrameStrata("MEDIUM")

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("TOP", 0, -3)
    title:SetText(FLOATING_TITLES[category] or category)
    title:SetFont(title:GetFont(), 9, "OUTLINE")
    f.title = title

    -- Movable
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local pt, _, relPt, x, y = self:GetPoint()
        if HexCDDB then
            HexCDDB["partyCD_" .. category .. "_pos"] = { point = pt, relPoint = relPt, x = x, y = y }
        end
    end)

    -- Restore position
    local saved = HexCDDB and HexCDDB["partyCD_" .. category .. "_pos"]
    if saved then
        f:ClearAllPoints()
        f:SetPoint(saved.point, UIParent, saved.relPoint, saved.x, saved.y)
    else
        local defaults = {
            PARTY_RANGED  = { "TOPRIGHT", -200, -100 },
            PARTY_STACKED = { "TOPRIGHT", -200, -200 },
            HEALING       = { "TOPRIGHT", -200, -300 },
        }
        local d = defaults[category] or { "CENTER", 0, 0 }
        f:SetPoint(d[1], UIParent, d[1], d[2], d[3])
    end

    -- Pre-allocate rows
    f.rows = {}
    for i = 1, MAX_PLAYERS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(200, BAR_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -14 - (i - 1) * BAR_ROW_HEIGHT)
        row:Hide()

        row.nameText = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.nameText:SetPoint("LEFT", 0, 0)
        row.nameText:SetWidth(BAR_NAME_WIDTH)
        row.nameText:SetJustifyH("LEFT")
        row.nameText:SetWordWrap(false)

        row.icons = {}
        for j = 1, MAX_ICONS_PER_PLAYER do
            local icon = CreateCDIcon(row)
            icon:SetPoint("LEFT", BAR_NAME_WIDTH + (j - 1) * (ICON_SIZE + ICON_PADDING), 0)
            row.icons[j] = icon
        end
        f.rows[i] = row
    end

    f:Hide()
    return f
end

local function GetFloatingBar(category)
    if not floatingBars[category] then
        floatingBars[category] = CreateFloatingBar(category)
    end
    return floatingBars[category]
end

local function UpdateFloatingBar(category, partyCD, now)
    local bar = GetFloatingBar(category)

    -- Collect all players who have spells in this category
    local players = {}
    for playerName, pData in pairs(partyCD) do
        if type(pData) == "table" then
            local spells = {}
            for spellID, state in pairs(pData) do
                if type(spellID) == "number" and type(state) == "table" and IsSpellEnabled(spellID) then
                    local dbInfo = HexCD.SpellDB and HexCD.SpellDB:GetSpell(spellID)
                    if dbInfo and dbInfo.category == category then
                        table.insert(spells, { id = spellID, state = state })
                    end
                end
            end
            if #spells > 0 then
                table.sort(spells, function(a, b) return a.id < b.id end)
                table.insert(players, { name = playerName, spells = spells })
            end
        end
    end
    table.sort(players, function(a, b) return a.name < b.name end)

    if #players == 0 then
        bar:Hide()
        return
    end

    local rowIdx = 0
    for _, p in ipairs(players) do
        if rowIdx >= MAX_PLAYERS then break end
        rowIdx = rowIdx + 1
        local row = bar.rows[rowIdx]
        row.nameText:SetText(p.name)
        row:Show()

        local iconIdx = 0
        for _, spell in ipairs(p.spells) do
            if iconIdx >= MAX_ICONS_PER_PLAYER then break end
            iconIdx = iconIdx + 1
            UpdateIcon(row.icons[iconIdx], spell.id, spell.state, now)
        end
        for i = iconIdx + 1, MAX_ICONS_PER_PLAYER do row.icons[i]:Hide() end
    end
    for i = rowIdx + 1, MAX_PLAYERS do bar.rows[i]:Hide() end

    -- Resize
    bar:SetSize(
        8 + BAR_NAME_WIDTH + MAX_ICONS_PER_PLAYER * (ICON_SIZE + ICON_PADDING),
        18 + rowIdx * BAR_ROW_HEIGHT
    )
    bar:Show()
end

local function HideAllFloating()
    for _, bar in pairs(floatingBars) do bar:Hide() end
end

local function HideAllPersonal()
    for _, bar in pairs(personalBars) do bar.container:Hide() end
end

------------------------------------------------------------------------
-- Main update
------------------------------------------------------------------------

local pcdDebugOnce = true
local function UpdateDisplay()
    if not isVisible then return end
    -- Only show in party (not solo, not raid) unless test mode
    local CS = HexCD.CommSync
    if not CS then return end
    local inParty = IsInGroup and IsInGroup() and not (IsInRaid and IsInRaid())
    local testing = CS.IsTestMode and CS:IsTestMode()
    if not inParty and not testing then
        for _, bar in pairs(personalBars) do bar.container:Hide() end
        return
    end
    local partyCD = CS:GetPartyCD()
    local now = GetTime()

    -- One-time debug dump to diagnose personal CD visibility
    if pcdDebugOnce then
        pcdDebugOnce = false
        local Log = HexCD.DebugLog
        if Log then
            local count = 0
            for pName, pData in pairs(partyCD) do
                if type(pData) == "table" then
                    local spellCount = 0
                    for k, v in pairs(pData) do
                        if type(k) == "number" then spellCount = spellCount + 1 end
                    end
                    Log:Log("DEBUG", string.format("PartyCDDisplay: partyCD['%s'] has %d spells", pName, spellCount))
                    count = count + 1
                end
            end
            Log:Log("DEBUG", string.format("PartyCDDisplay: %d players in partyCD", count))
        end
    end

    UpdatePersonalBars(partyCD, now)
    for _, cat in ipairs(FLOATING_CATEGORIES) do
        UpdateFloatingBar(cat, partyCD, now)
    end
end

local function OnUpdate(self, elapsed)
    onUpdateThrottle = onUpdateThrottle + elapsed
    if onUpdateThrottle < UPDATE_INTERVAL then return end
    onUpdateThrottle = 0
    UpdateDisplay()
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

function PCD:Init()
    if updateFrame then return end
    updateFrame = CreateFrame("Frame", nil, UIParent)
    updateFrame:SetScript("OnUpdate", OnUpdate)
    isVisible = true
    updateFrame:Show()
    Log:Log("DEBUG", "PartyCDDisplay: initialized (always-on)")
end

function PCD:Show()
    if not updateFrame then self:Init() end
    isVisible = true
    updateFrame:Show()
    UpdateDisplay()
end

function PCD:Hide()
    isVisible = false
    if updateFrame then updateFrame:Hide() end
    HideAllPersonal()
    HideAllFloating()
end

function PCD:Toggle()
    if isVisible then self:Hide() else self:Show() end
end

function PCD:IsVisible()
    return isVisible
end

function PCD:ShowDetached()
    self:Show()
end

function PCD:Lock()
    for _, bar in pairs(floatingBars) do bar:EnableMouse(false) end
    print("|cFF88CCFF[HexCD]|r Party CD bars locked.")
end

function PCD:Unlock()
    for _, bar in pairs(floatingBars) do bar:EnableMouse(true) end
    print("|cFF88CCFF[HexCD]|r Party CD bars unlocked. Drag to move.")
end

function PCD:GetMode()
    return "attached"
end

function PCD:_testGetState()
    return {
        isVisible = isVisible,
        personalBars = personalBars,
        floatingBars = floatingBars,
    }
end
