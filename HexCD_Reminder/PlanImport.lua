------------------------------------------------------------------------
-- HexCD: Plan Import System
-- Paste Lua table data via EditBox to load CD plans
------------------------------------------------------------------------
HexCDReminder = HexCDReminder or {}
HexCDReminder.PlanImport = {}

local Import = HexCDReminder.PlanImport
local Config = HexCDReminder.Config
local Log = HexCDReminder.DebugLog

local importFrame = nil

------------------------------------------------------------------------
-- Lua Table Parser
------------------------------------------------------------------------

--- Parse a pasted Lua table string into a Lua value
--- Uses loadstring in a sandboxed environment
---@param str string
---@return any|nil value, string|nil error
local function ParseLuaTable(str)
    if not str or str == "" then
        return nil, "Empty input"
    end

    -- Wrap in return if it starts with { (raw table)
    local code = str
    if code:match("^%s*{") then
        code = "return " .. code
    end

    local fn, err = loadstring(code)
    if not fn then
        return nil, "Parse error: " .. (err or "unknown")
    end

    -- Sandbox: only allow safe operations
    local sandbox = {
        -- Allow basic types and table constructors
        pairs = pairs,
        ipairs = ipairs,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
    }
    setfenv(fn, sandbox)

    local ok, result = pcall(fn)
    if not ok then
        return nil, "Execution error: " .. tostring(result)
    end

    return result, nil
end

--- Validate a parsed plan has required fields
---@param plan table
---@return boolean valid, string|nil error
local function ValidatePlan(plan)
    if type(plan) ~= "table" then
        return false, "Plan must be a table"
    end
    if not plan.encounterID or type(plan.encounterID) ~= "number" then
        return false, "Missing or invalid encounterID"
    end
    if not plan.healerAssignments or type(plan.healerAssignments) ~= "table" then
        return false, "Missing healerAssignments"
    end

    local totalCDs = 0
    for _, healer in ipairs(plan.healerAssignments) do
        if healer.assignments then
            totalCDs = totalCDs + #healer.assignments
        end
    end

    if totalCDs == 0 then
        return false, "No CD assignments found in plan"
    end

    return true, nil
end

------------------------------------------------------------------------
-- Import Action
------------------------------------------------------------------------

--- Import a plan from a string
---@param str string Lua table string
---@return boolean success, string message
function Import:ImportString(str)
    local plan, parseErr = ParseLuaTable(str)
    if parseErr then
        Log:Log("ERRORS", "Plan import failed: " .. parseErr)
        return false, parseErr
    end

    local valid, valErr = ValidatePlan(plan)
    if not valid then
        Log:Log("ERRORS", "Plan validation failed: " .. valErr)
        return false, valErr
    end

    -- Store in SavedVariables (keyed by [encounterID][difficulty])
    local plans = Config:Get("plans") or {}
    local diff = plan.difficulty or 4
    if not plans[plan.encounterID] or plans[plan.encounterID].healerAssignments then
        -- First import for this encounter, or migrating from legacy single-plan format
        plans[plan.encounterID] = {}
    end
    plans[plan.encounterID][diff] = plan
    Config:Set("plans", plans)

    local totalCDs = 0
    for _, healer in ipairs(plan.healerAssignments) do
        totalCDs = totalCDs + #(healer.assignments or {})
    end

    local msg = string.format("Imported plan for encounter %d (%d healer specs, %d total CDs, %ds fight)",
        plan.encounterID,
        #plan.healerAssignments,
        totalCDs,
        plan.fightDurationSec or 0
    )
    Log:Log("INFO", msg)
    return true, msg
end

------------------------------------------------------------------------
-- Import Frame (EditBox UI)
------------------------------------------------------------------------

local function CreateImportFrame()
    local f = CreateFrame("Frame", "HexCDImportFrame", UIParent, "BackdropTemplate")
    f:SetSize(600, 400)
    f:SetPoint("CENTER")
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    f:SetBackdropColor(0, 0, 0, 0.95)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("DIALOG")

    -- Title
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10)
    title:SetText("HexCD — Import CD Plan")

    -- Instructions
    local instr = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    instr:SetPoint("TOP", 0, -30)
    instr:SetText("Paste a Lua table exported from: hex-logs export-cdplan <encounter-id>")

    -- Close button
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)

    -- Scroll frame for EditBox
    local scroll = CreateFrame("ScrollFrame", "HexCDImportScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -50)
    scroll:SetPoint("BOTTOMRIGHT", -30, 50)

    local editBox = CreateFrame("EditBox", "HexCDImportEditBox", scroll)
    editBox:SetMultiLine(true)
    editBox:SetAutoFocus(true)
    editBox:SetFontObject(GameFontHighlightSmall)
    editBox:SetWidth(550)
    editBox:SetScript("OnEscapePressed", function(self) f:Hide() end)
    scroll:SetScrollChild(editBox)

    -- Status text
    local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("BOTTOMLEFT", 12, 16)
    status:SetJustifyH("LEFT")
    status:SetText("")

    -- Import button
    local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    importBtn:SetSize(100, 26)
    importBtn:SetPoint("BOTTOMRIGHT", -12, 12)
    importBtn:SetText("Import")
    importBtn:SetScript("OnClick", function()
        local text = editBox:GetText()
        local ok, msg = Import:ImportString(text)
        if ok then
            status:SetTextColor(0.2, 1.0, 0.2)
            status:SetText("Success: " .. msg)
            C_Timer.After(2, function() f:Hide() end)
        else
            status:SetTextColor(1.0, 0.3, 0.3)
            status:SetText("Error: " .. msg)
        end
    end)

    -- Clear button
    local clearBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    clearBtn:SetSize(80, 26)
    clearBtn:SetPoint("RIGHT", importBtn, "LEFT", -8, 0)
    clearBtn:SetText("Clear")
    clearBtn:SetScript("OnClick", function()
        editBox:SetText("")
        status:SetText("")
        editBox:SetFocus()
    end)

    f.editBox = editBox
    f.status = status
    return f
end

--- Show the import frame
function Import:ShowFrame()
    if not importFrame then
        importFrame = CreateImportFrame()
    end
    importFrame.editBox:SetText("")
    importFrame.status:SetText("")
    importFrame:Show()
    importFrame.editBox:SetFocus()
end
