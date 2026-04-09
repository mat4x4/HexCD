------------------------------------------------------------------------
-- HexCD: Timer Bar Display
--
-- Two bar groups with distinct visual styling:
--
--   COUNTDOWN bars — "what's coming next" (bright, spell icon, sharp border)
--     Ramp, Convoke, Tranq, Cat Weave countdowns
--     Single anchor: /hexcd unlock | /hexcd lock
--
--   ACTIVE WINDOW bars — "what's happening now" (wider, glowing border, no icon)
--     RAMPING, BURNING, CAT WEAVE phase trackers
--     Single anchor: /hexcd unlockwindow | /hexcd lockwindow
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.TimerBars = {}

local Bars = HexCDReminder.TimerBars
local Config = HexCDReminder.Config
local Util = HexCDReminder.Util
local Log = HexCDReminder.DebugLog

local COUNTDOWN_POOL_SIZE = 8
local WINDOW_POOL_SIZE    = 4
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"

------------------------------------------------------------------------
-- State — Countdown bars (upcoming actions)
------------------------------------------------------------------------
local countdownBarPool   = {}
local activeCountdownBars = {}  -- cdEntry -> bar
local countdownAnchor    = nil

------------------------------------------------------------------------
-- State — Active window bars (phase trackers)
------------------------------------------------------------------------
local windowBarPool      = {}
local activeWindowBars   = {}   -- cdEntry -> bar
local windowAnchor       = nil

------------------------------------------------------------------------
-- Countdown Bar Frame (bright, compact, icon + label + time)
------------------------------------------------------------------------
local function CreateCountdownBar(index)
    local bar = CreateFrame("StatusBar", "HexCDBar" .. index, UIParent, "BackdropTemplate")
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    -- Dark background
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(BAR_TEXTURE)
    bar.bg:SetVertexColor(0.08, 0.08, 0.12, 0.85)

    -- Spell icon (left)
    bar.icon = bar:CreateTexture(nil, "OVERLAY")
    bar.icon:SetSize(0, 0)
    bar.icon:SetPoint("LEFT", bar, "LEFT", 2, 0)
    bar.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Type tag (left of name): RAMP / BURN / CAT
    bar.tagText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.tagText:SetPoint("LEFT", bar.icon, "RIGHT", 4, 0)
    bar.tagText:SetJustifyH("LEFT")

    -- Ability name
    bar.nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.nameText:SetPoint("LEFT", bar.tagText, "RIGHT", 4, 0)
    bar.nameText:SetPoint("RIGHT", bar, "RIGHT", -50, 0)
    bar.nameText:SetJustifyH("LEFT")
    bar.nameText:SetWordWrap(false)

    -- Countdown text (right)
    bar.timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.timeText:SetJustifyH("RIGHT")

    -- Sharp thin border
    bar:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    bar:SetBackdropBorderColor(0.4, 0.4, 0.5, 0.9)

    bar._index = index
    bar._active = false
    return bar
end

------------------------------------------------------------------------
-- Active Window Bar Frame (wider feel, colored glow border, bold label)
------------------------------------------------------------------------
local function CreateWindowBar(index)
    local bar = CreateFrame("StatusBar", "HexCDWinBar" .. index, UIParent, "BackdropTemplate")
    bar:SetStatusBarTexture(BAR_TEXTURE)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:Hide()

    -- Darker tinted background
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(BAR_TEXTURE)
    bar.bg:SetVertexColor(0.04, 0.04, 0.06, 0.9)

    -- No spell icon on window bars

    -- Phase label (bold, left-aligned): "RAMPING" / "BURN: Convoke" / "CAT WEAVE"
    bar.labelText = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.labelText:SetPoint("LEFT", bar, "LEFT", 8, 0)
    bar.labelText:SetPoint("RIGHT", bar, "RIGHT", -50, 0)
    bar.labelText:SetJustifyH("LEFT")
    bar.labelText:SetWordWrap(false)

    -- Time remaining (right)
    bar.timeText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
    bar.timeText:SetJustifyH("RIGHT")

    -- Thick colored border (glowing effect)
    bar:SetBackdrop({
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })

    bar._index = index
    bar._active = false
    return bar
end

------------------------------------------------------------------------
-- Anchor Frame Creation
------------------------------------------------------------------------
local function CreateAnchorFrame(name, label, bgR, bgG, bgB, borderR, borderG, borderB,
                                  pointKey, xKey, yKey, defaultPoint, defaultX, defaultY)
    local width = Config:Get("barWidth") or 250
    local f = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
    f:SetSize(width, 20)
    f:SetPoint(
        Config:Get(pointKey) or defaultPoint,
        UIParent,
        Config:Get(pointKey) or defaultPoint,
        Config:Get(xKey) or defaultX,
        Config:Get(yKey) or defaultY
    )
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(false)

    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 8,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    f:SetBackdropColor(bgR, bgG, bgB, 0.6)
    f:SetBackdropBorderColor(borderR, borderG, borderB, 0.8)

    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.label:SetPoint("CENTER")
    f.label:SetText(label)

    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, _, x, y = self:GetPoint()
        Config:Set(pointKey, point)
        Config:Set(xKey, math.floor(x + 0.5))
        Config:Set(yKey, math.floor(y + 0.5))
        Log:Log("INFO", string.format("%s anchor saved: %s (%.0f, %.0f)", name, point, x, y))
    end)

    f:Hide()
    return f
end

------------------------------------------------------------------------
-- Initialization
------------------------------------------------------------------------
function Bars:Init()
    -- Countdown bar anchor + pool
    if not countdownAnchor then
        countdownAnchor = CreateAnchorFrame(
            "HexCDAnchor", "Countdown Bars -- drag to move",
            0.1, 0.3, 0.6,   0.2, 0.5, 1.0,
            "barAnchorPoint", "barAnchorX", "barAnchorY",
            "CENTER", 0, -200
        )
    end
    for i = 1, COUNTDOWN_POOL_SIZE do
        if not countdownBarPool[i] then
            countdownBarPool[i] = CreateCountdownBar(i)
        end
    end

    -- Active window bar anchor + pool
    if not windowAnchor then
        windowAnchor = CreateAnchorFrame(
            "HexCDWindowAnchor", "Active Window Bars -- drag to move",
            0.4, 0.25, 0.0,   0.7, 0.45, 0.1,
            "windowAnchorPoint", "windowAnchorX", "windowAnchorY",
            "CENTER", 0, -270
        )
    end
    for i = 1, WINDOW_POOL_SIZE do
        if not windowBarPool[i] then
            windowBarPool[i] = CreateWindowBar(i)
        end
    end

    Log:Log("DEBUG", string.format("TimerBars initialized: %d countdown, %d window bars",
        COUNTDOWN_POOL_SIZE, WINDOW_POOL_SIZE))
end

------------------------------------------------------------------------
-- Pool helpers
------------------------------------------------------------------------

local function AcquireFrom(pool, poolName)
    local activeCount = 0
    for _, bar in ipairs(pool) do
        if bar._active then activeCount = activeCount + 1 end
    end
    for _, bar in ipairs(pool) do
        if not bar._active then
            bar._active = true
            Log:Log("TRACE", string.format("%s: acquired bar #%d (%d/%d active)",
                poolName, bar._index, activeCount + 1, #pool))
            return bar
        end
    end
    Log:Log("ERRORS", string.format("%s pool exhausted (%d/%d active)", poolName, activeCount, #pool))
    return nil
end

local function ReleaseBar(bar)
    bar:Hide()
    bar._active = false
    bar._cdEntry = nil
end

------------------------------------------------------------------------
-- Reposition helpers
------------------------------------------------------------------------

local function RepositionGroup(activeMap, anchor, heightOverride)
    local width  = Config:Get("barWidth") or 250
    local height = heightOverride or (Config:Get("barHeight") or 22)
    local scale  = Config:Get("barScale") or 1.0
    local growUp = (Config:Get("barGrowDirection") or "UP") == "UP"
    local spacing = 2

    local sorted = {}
    for _, bar in pairs(activeMap) do
        if bar._active then table.insert(sorted, bar) end
    end
    table.sort(sorted, function(a, b) return (a._remaining or 0) < (b._remaining or 0) end)

    for i, bar in ipairs(sorted) do
        bar:SetSize(width, height)
        bar:SetScale(scale)
        if bar.icon then
            bar.icon:SetSize(height - 4, height - 4)
        end

        bar:ClearAllPoints()
        local yOff = (i - 1) * (height + spacing)
        if growUp then
            bar:SetPoint("BOTTOM", anchor, "TOP", 0, yOff)
        else
            bar:SetPoint("TOP", anchor, "BOTTOM", 0, -yOff)
        end
    end
end

local function RepositionCountdownBars()
    RepositionGroup(activeCountdownBars, countdownAnchor)
end

local function RepositionWindowBars()
    -- Window bars are slightly taller for emphasis
    local h = (Config:Get("barHeight") or 22) + 4
    RepositionGroup(activeWindowBars, windowAnchor, h)
end

------------------------------------------------------------------------
-- Color / tag tables
------------------------------------------------------------------------

-- Countdown bar colors by rampType
local COUNTDOWN_COLORS = {
    fullRamp = { 1.0, 0.84, 0.0 },   -- gold
    burn     = { 0.4, 0.7,  1.0 },   -- blue (CDs to press)
    catWeave = { 0.2, 0.9,  0.2 },   -- green
}

-- Countdown bar type tags
local COUNTDOWN_TAGS = {
    fullRamp = { text = "RAMP",  r = 1.0, g = 0.84, b = 0.0 },
    burn     = { text = "BURN",  r = 0.4, g = 0.7,  b = 1.0 },
    catWeave = { text = "CAT",   r = 0.2, g = 0.9,  b = 0.2 },
}

-- Active window bar styles by abilityGameID
local WINDOW_STYLES = {
    [774] = { label = "RAMPING",    r = 0.95, g = 0.80, b = 0.10, borderR = 1.0, borderG = 0.85, borderB = 0.0 },
    [768] = { label = "CAT WEAVE",  r = 0.15, g = 0.75, b = 0.15, borderR = 0.2, borderG = 0.9,  borderB = 0.2 },
}
-- Default for burn CDs (Convoke, Tranq, etc)
local WINDOW_BURN = { r = 0.90, g = 0.45, b = 0.10, borderR = 1.0, borderG = 0.5, borderB = 0.1 }

------------------------------------------------------------------------
-- Configure countdown bar appearance
------------------------------------------------------------------------
local function ConfigureCountdownBar(bar, cdEntry, totalDuration)
    bar._cdEntry = cdEntry
    bar._totalDuration = totalDuration
    bar._remaining = totalDuration

    local rampType = cdEntry.rampType or "burn"
    local c = COUNTDOWN_COLORS[rampType] or COUNTDOWN_COLORS.burn
    bar:SetStatusBarColor(c[1], c[2], c[3], 0.85)

    -- Type tag
    local tag = COUNTDOWN_TAGS[rampType]
    if tag then
        bar.tagText:SetText(tag.text)
        bar.tagText:SetTextColor(tag.r, tag.g, tag.b)
    else
        bar.tagText:SetText("")
    end

    -- Ability name
    bar.nameText:SetText(cdEntry.abilityName or "Unknown")
    bar.nameText:SetTextColor(1, 1, 1)

    -- Spell icon
    local spellInfo = C_Spell and C_Spell.GetSpellInfo(cdEntry.abilityGameID)
    local iconTexture = spellInfo and spellInfo.iconID
    if iconTexture then
        bar.icon:SetTexture(iconTexture)
        bar.icon:Show()
    else
        bar.icon:Hide()
    end

    -- Border tinted by type
    bar:SetBackdropBorderColor(c[1] * 0.5, c[2] * 0.5, c[3] * 0.5, 0.9)

    bar:SetMinMaxValues(0, totalDuration)
    bar:SetValue(totalDuration)
    bar.timeText:SetText(Util.FormatCountdown(totalDuration))
end

------------------------------------------------------------------------
-- Configure active window bar appearance
------------------------------------------------------------------------
local function ConfigureWindowBar(bar, cdEntry, totalDuration, remaining)
    bar._cdEntry = cdEntry
    bar._totalDuration = totalDuration
    bar._remaining = remaining

    local id = cdEntry.abilityGameID
    local style = WINDOW_STYLES[id]

    if style then
        bar:SetStatusBarColor(style.r, style.g, style.b, 0.65)
        bar:SetBackdropBorderColor(style.borderR, style.borderG, style.borderB, 0.95)
        bar.labelText:SetText(style.label)
        bar.labelText:SetTextColor(style.borderR, style.borderG, style.borderB)
    else
        -- Burn CD
        bar:SetStatusBarColor(WINDOW_BURN.r, WINDOW_BURN.g, WINDOW_BURN.b, 0.65)
        bar:SetBackdropBorderColor(WINDOW_BURN.borderR, WINDOW_BURN.borderG, WINDOW_BURN.borderB, 0.95)
        bar.labelText:SetText("BURN: " .. (cdEntry.abilityName or ""))
        bar.labelText:SetTextColor(WINDOW_BURN.borderR, WINDOW_BURN.borderG, WINDOW_BURN.borderB)
    end

    bar:SetMinMaxValues(0, totalDuration)
    bar:SetValue(math.max(0, remaining))
    bar.timeText:SetText(Util.FormatCountdown(remaining))
    bar.timeText:SetTextColor(1, 1, 1)
end

------------------------------------------------------------------------
-- Public API — Countdown bars
------------------------------------------------------------------------

--- Show a countdown bar
---@param cdEntry table from TimerEngine queue
---@param totalDuration number seconds until action starts
function Bars:ShowBar(cdEntry, totalDuration)
    if activeCountdownBars[cdEntry] then return end

    local bar = AcquireFrom(countdownBarPool, "CountdownBars")
    if not bar then return end

    ConfigureCountdownBar(bar, cdEntry, totalDuration)
    activeCountdownBars[cdEntry] = bar
    bar:Show()
    RepositionCountdownBars()

    Log:Log("DEBUG", string.format("Countdown bar shown: %s (%.0fs, type=%s)",
        cdEntry.abilityName, totalDuration, cdEntry.rampType or "?"))
end

--- Update a countdown bar's remaining time
---@param cdEntry table
---@param remaining number seconds
function Bars:UpdateBar(cdEntry, remaining)
    local bar = activeCountdownBars[cdEntry]
    if not bar then return end

    bar._remaining = remaining
    bar:SetValue(math.max(0, remaining))
    bar.timeText:SetText(Util.FormatCountdown(remaining))

    -- Flash when close
    if remaining <= 3 then
        local pulse = 0.5 + 0.5 * math.abs(math.sin(GetTime() * 3))
        bar:SetAlpha(pulse)
    else
        bar:SetAlpha(1.0)
    end
end

--- Hide a countdown bar
---@param cdEntry table
function Bars:HideBar(cdEntry)
    local bar = activeCountdownBars[cdEntry]
    if bar then
        Log:Log("TRACE", string.format("Countdown bar hidden: %s (bar #%d)",
            cdEntry.abilityName or "?", bar._index))
        ReleaseBar(bar)
        activeCountdownBars[cdEntry] = nil
        RepositionCountdownBars()
    end
end

------------------------------------------------------------------------
-- Public API — Active window bars
------------------------------------------------------------------------

--- Show an active window bar
---@param cdEntry table
---@param totalDuration number total window length
---@param remaining number seconds remaining
function Bars:ShowDurationBar(cdEntry, totalDuration, remaining)
    if activeWindowBars[cdEntry] then return end

    local bar = AcquireFrom(windowBarPool, "WindowBars")
    if not bar then return end

    ConfigureWindowBar(bar, cdEntry, totalDuration, remaining)
    activeWindowBars[cdEntry] = bar
    bar:Show()
    RepositionWindowBars()

    Log:Log("DEBUG", string.format("Window bar shown: %s (%.0fs window)",
        cdEntry.abilityName, totalDuration))
end

--- Update an active window bar
---@param cdEntry table
---@param remaining number seconds
function Bars:UpdateDurationBar(cdEntry, remaining)
    local bar = activeWindowBars[cdEntry]
    if not bar then return end

    bar._remaining = remaining
    bar:SetValue(math.max(0, remaining))
    bar.timeText:SetText(Util.FormatCountdown(remaining))
    bar:SetAlpha(1.0)
end

--- Hide an active window bar
---@param cdEntry table
function Bars:HideDurationBar(cdEntry)
    local bar = activeWindowBars[cdEntry]
    if bar then
        ReleaseBar(bar)
        activeWindowBars[cdEntry] = nil
        RepositionWindowBars()
    end
end

------------------------------------------------------------------------
-- Hide all / count
------------------------------------------------------------------------

function Bars:HideAll()
    local cCount, wCount = 0, 0
    for _ in pairs(activeCountdownBars) do cCount = cCount + 1 end
    for _ in pairs(activeWindowBars)    do wCount = wCount + 1 end
    for _, bar in pairs(activeCountdownBars) do ReleaseBar(bar) end
    wipe(activeCountdownBars)
    for _, bar in pairs(activeWindowBars) do ReleaseBar(bar) end
    wipe(activeWindowBars)
    if cCount + wCount > 0 then
        Log:Log("DEBUG", string.format("HideAll: cleared %d countdown, %d window bars", cCount, wCount))
    end
end

function Bars:GetVisibleCount()
    local count = 0
    for _ in pairs(activeCountdownBars) do count = count + 1 end
    for _ in pairs(activeWindowBars)    do count = count + 1 end
    return count
end

------------------------------------------------------------------------
-- Lock / Unlock — Countdown bars
------------------------------------------------------------------------

function Bars:Unlock()
    if countdownAnchor then
        countdownAnchor:EnableMouse(true)
        countdownAnchor:Show()
        Log:Log("INFO", "Countdown bars unlocked")
        print("|cFF00CCFF[HexCD]|r Countdown Bars |cFFFFCC00UNLOCKED|r -- drag to move. /hexcd lock to save.")
    end
end

function Bars:Lock()
    if countdownAnchor then
        countdownAnchor:EnableMouse(false)
        countdownAnchor:Hide()
        Log:Log("INFO", "Countdown bars locked")
        print("|cFF00CCFF[HexCD]|r Countdown Bars |cFF00FF00LOCKED|r -- position saved.")
    end
end

function Bars:ToggleLock()
    if countdownAnchor and countdownAnchor:IsShown() then
        self:Lock()
        return true
    else
        self:Unlock()
        return false
    end
end

function Bars:IsUnlocked()
    return countdownAnchor and countdownAnchor:IsShown() or false
end

------------------------------------------------------------------------
-- Lock / Unlock — Active window bars
------------------------------------------------------------------------

function Bars:UnlockWindow()
    if windowAnchor then
        windowAnchor:EnableMouse(true)
        windowAnchor:Show()
        Log:Log("INFO", "Window bars unlocked")
        print("|cFF00CCFF[HexCD]|r Active Window Bars |cFFFFCC00UNLOCKED|r -- drag to move. /hexcd lockwindow to save.")
    end
end

function Bars:LockWindow()
    if windowAnchor then
        windowAnchor:EnableMouse(false)
        windowAnchor:Hide()
        Log:Log("INFO", "Window bars locked")
        print("|cFF00CCFF[HexCD]|r Active Window Bars |cFF00FF00LOCKED|r -- position saved.")
    end
end

function Bars:ToggleWindowLock()
    if windowAnchor and windowAnchor:IsShown() then
        self:LockWindow()
        return true
    else
        self:UnlockWindow()
        return false
    end
end

function Bars:IsWindowUnlocked()
    return windowAnchor and windowAnchor:IsShown() or false
end

------------------------------------------------------------------------
-- Legacy API compat (ramp lock commands now alias countdown)
------------------------------------------------------------------------
function Bars:UnlockRamp() self:Unlock() end
function Bars:LockRamp()   self:Lock() end
function Bars:ToggleRampLock() return self:ToggleLock() end
function Bars:IsRampUnlocked() return self:IsUnlocked() end
