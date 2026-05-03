-- Vellum: a leveling guide built on LibCodex.
-- Phase 0 stub: confirms wiring (Cairn.Addon, Cairn.Slash, Cairn.DB, Cairn.Log).
-- No guide engine yet; that's the next session.

local ADDON, ns = ...

Vellum = ns
ns.VERSION = "0.1.0-dev"

-- --------------------------------------------------------------------------
-- DB. Cairn.DB owns SavedVariables persistence, defaults, and profiles.
-- Lazy-inits on first .profile / .global access (after ADDON_LOADED).
-- --------------------------------------------------------------------------
local db = Cairn.DB.New("VellumDB", {
    defaults = {
        profile = {
            window = { x = 0, y = -120, shown = true },
            arrow  = { x = 0, y = -200, scale = 1 },
        },
        global = {
            schemaVersion = 1,
        },
    },
    profileType = "char",
})
ns.db = db

-- --------------------------------------------------------------------------
-- Addon lifecycle. Cairn.Addon wires ADDON_LOADED / PLAYER_LOGIN /
-- PLAYER_ENTERING_WORLD / PLAYER_LOGOUT for us.
-- --------------------------------------------------------------------------
local addon = Cairn.Addon.New("Vellum")
ns.addon = addon

function addon:OnInit()
    -- SavedVariables are now ready. Touch db.profile once so Cairn.DB
    -- materializes defaults on first run.
    local _ = db.profile
end

function addon:OnLogin()
    local log = self:Log()
    log:Info("Vellum v%s loaded.", ns.VERSION)

    local lc = LibStub and LibStub("LibCodex", true)
    if not lc then
        log:Warn("LibCodex missing. Vellum cannot drive a guide without it.")
    end
end

-- --------------------------------------------------------------------------
-- Slash router. /vellum and /vel.
-- --------------------------------------------------------------------------
local slash = Cairn.Slash.Register("Vellum", "/vellum", { aliases = { "/vel" } })
ns.slash = slash

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b8b6aVellum:|r " .. tostring(msg))
    end
end

slash:Subcommand("status", function()
    local lc = LibStub and LibStub("LibCodex", true)
    out("v" .. ns.VERSION)
    out("  LibCodex: " .. (lc and "OK" or "MISSING"))
    out("  Cairn:    " .. (Cairn and "OK" or "MISSING"))
    out("  TomTom:   " .. (TomTom and "OK" or "absent (optional)"))
    out("  Profile:  " .. tostring(db:GetCurrentProfile()))
end, "show wiring (LibCodex, Cairn, profile)")

slash:Subcommand("codex", function()
    local lc = LibStub and LibStub("LibCodex", true)
    if not lc then out("LibCodex not loaded.") return end
    if lc.Quests and lc:Quests() then
        out("LibCodex Quests reachable.")
    else
        out("Quests module not yet available.")
    end
end, "smoke-test the LibCodex Quests module")

slash:Subcommand("reset", function()
    db:ResetProfile()
    out("profile reset to defaults.")
end, "reset the current profile to defaults")

slash:Default(function() slash:PrintHelp() end)
