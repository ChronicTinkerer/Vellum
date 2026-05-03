-- Vellum: a leveling guide built on LibCodex.
-- Phase 0: bootstrap stub. Confirms the addon loads, LibCodex is reachable,
-- and Cairn (if present) is wired up. No guide engine yet.

local ADDON, ns = ...

Vellum = ns
ns.VERSION = "0.1.0-dev"

local function out(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff9b8b6aVellum:|r " .. tostring(msg))
end

ns.Print = out

-- --------------------------------------------------------------------------
-- Slash command: /vellum
-- --------------------------------------------------------------------------
SLASH_VELLUM1 = "/vellum"
SLASH_VELLUM2 = "/vel"
SlashCmdList.VELLUM = function(input)
    input = (input or ""):lower():match("^%s*(.-)%s*$")

    if input == "" or input == "help" then
        out("v" .. ns.VERSION)
        out("  /vellum status   - show wiring (LibCodex, Cairn)")
        out("  /vellum codex    - sample LibCodex query")
        return
    end

    if input == "status" then
        local lc = LibStub and LibStub("LibCodex", true)
        out("LibCodex:  " .. (lc and "OK" or "MISSING"))
        out("Cairn:     " .. (Cairn and "OK" or "absent (optional)"))
        out("TomTom:    " .. (TomTom and "OK" or "absent (optional)"))
        return
    end

    if input == "codex" then
        local lc = LibStub and LibStub("LibCodex", true)
        if not lc then
            out("LibCodex not loaded; cannot query.")
            return
        end
        local q = lc.Quests and lc:Quests()
        if q then
            out("Quests module reachable.")
        else
            out("Quests module not yet available.")
        end
        return
    end

    out("Unknown subcommand. Try /vellum help.")
end

-- --------------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------------
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON then
        VellumDB = VellumDB or { schemaVersion = 1 }
        VellumCharDB = VellumCharDB or { schemaVersion = 1 }
    elseif event == "PLAYER_LOGIN" then
        out("loaded. Type /vellum for help.")
    end
end)
