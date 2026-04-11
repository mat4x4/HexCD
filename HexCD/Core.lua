------------------------------------------------------------------------
-- HexCD: Core — Addon entry point for the tracker (dispel/kick rotation)
------------------------------------------------------------------------
HexCD = HexCD or {}

local ADDON_NAME = "HexCD"
local VERSION = "1.5.2"

local Config = HexCD.Config
local Log = HexCD.DebugLog
local GUI = HexCD.ConfigGUI

------------------------------------------------------------------------
-- Event Frame
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame", "HexCDEventFrame")

local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == ADDON_NAME then
            Config:Init()
            Log:Init()
            if GUI then GUI:Init() end
            if HexCD.DispelTracker then HexCD.DispelTracker:Init() end
            if HexCD.KickTracker then HexCD.KickTracker:Init() end
            if HexCD.CommSync then HexCD.CommSync:Init() end
            if HexCD.AuraDetector then HexCD.AuraDetector:Init() end
            if HexCD.PartyCDDisplay then HexCD.PartyCDDisplay:Init() end
            Log:Log("INFO", string.format("HexCD v%s loaded. Type /hexcd for commands.", VERSION))
            print(string.format("|cFF00CCFF[HexCD]|r v%s loaded. Type |cFFFFCC00/hexcd|r for commands.", VERSION))
        end
    end
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", OnEvent)

------------------------------------------------------------------------
-- Slash Commands
------------------------------------------------------------------------
SLASH_HEXCD1 = "/hexcd"
SLASH_HEXCD2 = "/hcd"

SlashCmdList["HEXCD"] = function(msg)
    local cmd, arg = msg:match("^(%S+)%s*(.*)")
    cmd = (cmd or msg):lower()

    if cmd == "" or cmd == "gui" or cmd == "show" then
        if GUI then GUI:Toggle() end

    elseif cmd == "settings" then
        if GUI then GUI:OpenSettings() end

    elseif cmd == "log" or cmd == "logs" then
        Log:ShowFrame()

    elseif cmd == "loglevel" then
        local level = (arg or ""):upper()
        if level == "OFF" or level == "ERRORS" or level == "INFO" or level == "DEBUG" or level == "TRACE" then
            Config:Set("logLevel", level)
            print("|cFF00CCFF[HexCD]|r Log level set to: " .. level)
        else
            print("|cFF00CCFF[HexCD]|r Valid levels: OFF, ERRORS, INFO, DEBUG, TRACE")
        end

    -- Dispel Tracker commands
    elseif cmd == "dispelorder" then
        if arg == "" then
            print("|cFFCC88FF[HexCD]|r Usage: /hexcd dispelorder Name1,Name2,Name3 [broadcast]")
        else
            local doBroadcast = false
            local names = arg
            local lastComma = arg:match(".*,()")
            if lastComma then
                local lastToken = arg:sub(lastComma):match("^%s*(.-)%s*$")
                if lastToken:lower() == "broadcast" then
                    doBroadcast = true
                    names = arg:sub(1, lastComma - 2)
                end
            end
            Config:Set("dispelEnabled", true)
            HexCD.DispelTracker:SetRotation(names)
            if doBroadcast then
                HexCD.DispelTracker:BroadcastRotation()
            end
        end

    elseif cmd == "dispeltest" then
        if HexCD.DispelTracker then
            if arg == "" then
                print("|cFFCC88FF[HexCD]|r Usage: /hexcd dispeltest Name1,Name2,Name3 [duration]")
            else
                local duration = 15
                local names = arg
                local lastComma = arg:match(".*,()")
                if lastComma then
                    local lastToken = arg:sub(lastComma):match("^%s*(.-)%s*$")
                    local num = tonumber(lastToken)
                    if num then
                        duration = num
                        names = arg:sub(1, lastComma - 2)
                    end
                end
                Config:Set("dispelEnabled", true)
                HexCD.DispelTracker:SetRotation(names)
                HexCD.DispelTracker:SimulateDebuffs(duration)
            end
        end

    elseif cmd == "lockdispel" then
        if HexCD.DispelTracker then HexCD.DispelTracker:Lock() end

    elseif cmd == "unlockdispel" or cmd == "movedispel" then
        if HexCD.DispelTracker then HexCD.DispelTracker:Unlock() end

    -- Kick Tracker commands
    elseif cmd == "kickorder" then
        if arg == "" then
            print("|cFF88CCFF[HexCD]|r Usage: /hexcd kickorder Name1,Name2,Name3 [broadcast]")
        else
            local doBroadcast = false
            local names = arg
            local lastComma = arg:match(".*,()")
            if lastComma then
                local lastToken = arg:sub(lastComma):match("^%s*(.-)%s*$")
                if lastToken:lower() == "broadcast" then
                    doBroadcast = true
                    names = arg:sub(1, lastComma - 2)
                end
            end
            Config:Set("kickEnabled", true)
            HexCD.KickTracker:SetRotation(names)
            if doBroadcast then
                HexCD.KickTracker:BroadcastRotation()
            end
        end

    elseif cmd == "kicktest" then
        if HexCD.KickTracker then
            if arg == "" then
                print("|cFF88CCFF[HexCD]|r Usage: /hexcd kicktest Name1,Name2,Name3 [duration]")
            else
                local duration = 15
                local names = arg
                local lastComma = arg:match(".*,()")
                if lastComma then
                    local lastToken = arg:sub(lastComma):match("^%s*(.-)%s*$")
                    local num = tonumber(lastToken)
                    if num then
                        duration = num
                        names = arg:sub(1, lastComma - 2)
                    end
                end
                Config:Set("kickEnabled", true)
                HexCD.KickTracker:SetRotation(names)
                HexCD.KickTracker:SimulateKicks(duration)
            end
        end

    elseif cmd == "lockkick" then
        if HexCD.KickTracker then HexCD.KickTracker:Lock() end

    elseif cmd == "unlockkick" or cmd == "movekick" then
        if HexCD.KickTracker then HexCD.KickTracker:Unlock() end

    elseif cmd == "debugframes" then
        if HexCD.PartyCDDisplay then HexCD.PartyCDDisplay:DebugFrames() end

    else
        if GUI then GUI:Toggle() end
    end
end
