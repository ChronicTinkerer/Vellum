-- Vellum: a leveling guide built on LibCodex.
-- Core: bootstrap (DB + lifecycle) and the /vellum slash router.

local ADDON, ns = ...

Vellum = ns
ns.VERSION = "0.1.0-dev"

-- --------------------------------------------------------------------------
-- DB.
-- --------------------------------------------------------------------------
local db = Cairn.DB.New("VellumDB", {
    defaults = {
        profile = {
            panel = {
                x = 0, y = 0,
                autoShow        = true,   -- show on Follower:Set
                autoHideOnClear = true,   -- hide on Follower:Clear
                selectedTab     = "log",  -- last viewed tab
            },
            arrow  = { x = 0, y = 200, scale = 1 },
        },
        global = { schemaVersion = 1 },
    },
    profileType = "char",
})
ns.db = db

-- --------------------------------------------------------------------------
-- Addon lifecycle.
-- --------------------------------------------------------------------------
local addon = Cairn.Addon.New("Vellum")
ns.addon = addon

function addon:OnInit()
    local _ = db.profile
end

function addon:OnLogin()
    local log = self:Log()
    log:Info("Vellum v%s loaded.", ns.VERSION)
    local lc = LibStub and LibStub("LibCodex-1.0", true)
    if not lc then
        log:Warn("LibCodex missing. Vellum cannot drive a guide without it.")
    end
end

local function out(msg)
    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff9b8b6aVellum:|r " .. tostring(msg))
    end
end

-- --------------------------------------------------------------------------
-- Quest resolver for /vellum follow.
-- --------------------------------------------------------------------------
local function resolveQuestID(input)
    input = (input and input:match("^%s*(.-)%s*$")) or ""

    if input == "" then
        if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then
            local qid = C_SuperTrack.GetSuperTrackedQuestID()
            if qid and qid > 0 then return qid end
        end
        return nil, "no supertracked quest. Set one in your quest tracker, or use /vellum follow <id|name>."
    end

    local asNumber = tonumber(input)
    if asNumber and asNumber > 0 then
        if C_QuestLog and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(asNumber) then
            return asNumber
        end
        return nil, string.format("quest %d is not in your log.", asNumber)
    end

    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then
        return nil, "quest log API unavailable; try /vellum follow <id>."
    end

    local needle = input:lower()
    local matches = {}
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.title and info.questID then
            if info.title:lower():find(needle, 1, true) then
                matches[#matches + 1] = info
            end
        end
    end

    if #matches == 0 then
        return nil, string.format("no quest in your log matching '%s'.", input)
    elseif #matches == 1 then
        return matches[1].questID
    else
        local names = {}
        for i, m in ipairs(matches) do
            if i > 4 then names[#names + 1] = "..."; break end
            names[#names + 1] = string.format("%s (id %d)", m.title, m.questID)
        end
        return nil, string.format("multiple matches for '%s': %s. Use /vellum follow <id>.",
            input, table.concat(names, "; "))
    end
end

ns._resolveQuestID = resolveQuestID

-- --------------------------------------------------------------------------
-- Slash router.
-- --------------------------------------------------------------------------
local slash = Cairn.Slash.Register("Vellum", "/vellum", { aliases = { "/vel" } })
ns.slash = slash

slash:Subcommand("status", function()
    local lc = LibStub and LibStub("LibCodex-1.0", true)
    out("v" .. ns.VERSION)
    out("  LibCodex: " .. (lc and "OK" or "MISSING"))
    out("  Cairn:    " .. (Cairn and "OK" or "MISSING"))
    out("  TomTom:   " .. (TomTom and "OK" or "absent (optional)"))
    out("  Profile:  " .. tostring(db:GetCurrentProfile()))
end, "show wiring (LibCodex, Cairn, profile)")

slash:Subcommand("codex", function()
    local lc = LibStub and LibStub("LibCodex-1.0", true)
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

slash:Subcommand("follow", function(rest)
    local qid, err = resolveQuestID(rest)
    if not qid then out(err) return end
    if not (ns.Follower and ns.Follower.Set) then
        out("follower module not available.")
        return
    end
    ns.Follower.Set(qid)
    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID
        and C_QuestLog.GetTitleForQuestID(qid)) or tostring(qid)
    out(string.format("following: %s (id %d)", title, qid))
end, "follow a quest. no arg = supertracker; or pass <id> | <partial name>")

slash:Subcommand("stop", function()
    if ns.Follower and ns.Follower.Clear then ns.Follower.Clear() end
    if ns.Arrow and ns.Arrow.Stop then ns.Arrow.Stop() end
    if ns.Panel and ns.Panel.Hide then ns.Panel.Hide() end
    out("stopped.")
end, "stop following any quest")

slash:Subcommand("panel", function()
    if ns.Panel and ns.Panel.Toggle then ns.Panel.Toggle() end
end, "toggle the Vellum panel (Log / Zone / Search)")

-- --------------------------------------------------------------------------
-- /vellum debug -- probe every Locator layer for the current quest.
-- --------------------------------------------------------------------------
slash:Subcommand("debug", function()
    local s = (ns.Follower and ns.Follower.Get and ns.Follower.Get()) or {}
    if not s.questID then
        out("not following anything; run /vellum follow first.")
        return
    end

    out("Follower state:")
    out(string.format("  questID:     %s", tostring(s.questID)))
    out(string.format("  questTitle:  %s", tostring(s.questTitle)))
    out(string.format("  objIdx:      %s", tostring(s.objectiveIndex)))
    out(string.format("  objText:     %s", tostring(s.objectiveText)))
    out(string.format("  isComplete:  %s", tostring(s.isComplete)))
    out(string.format("  resolved:    map=%s xy=(%s, %s) src=%s",
        tostring(s.mapID), tostring(s.x), tostring(s.y), tostring(s.source)))

    out("Locator layer probes:")

    -- [1] Blizzard waypoint
    if C_QuestLog and C_QuestLog.GetNextWaypoint then
        local m, x, y = C_QuestLog.GetNextWaypoint(s.questID)
        if m then
            out(string.format("  [1] Blizzard GetNextWaypoint -> map=%d xy=(%.3f, %.3f)", m, x, y))
        else
            out("  [1] Blizzard GetNextWaypoint -> nil")
        end
    else
        out("  [1] Blizzard GetNextWaypoint -> API unavailable")
    end

    local lc = LibStub and LibStub("LibCodex-1.0", true)

    -- [2] LibCodex Quests entry
    if lc and lc.Quests and lc:Quests() and lc:Quests().Get then
        local q = lc:Quests():Get(s.questID)
        if q then
            out(string.format("  [2] LibCodex Quests:Get -> map=%s xy=(%s, %s) turnInNPC=%s",
                tostring(q.mapID), tostring(q.x), tostring(q.y), tostring(q.turnInNPC)))
        else
            out("  [2] LibCodex Quests:Get -> not in catalog")
        end
    else
        out("  [2] LibCodex Quests -> module unavailable")
    end

    -- [3] LibCodex QuestPOI
    if lc and lc.QuestPOI and lc:QuestPOI() and lc:QuestPOI().ForQuest then
        local pois = lc:QuestPOI():ForQuest(s.questID) or {}
        out(string.format("  [3] LibCodex QuestPOI:ForQuest -> %d POIs", #pois))
        for i, p in ipairs(pois) do
            if i > 3 then out("    ..."); break end
            local pt = p.points and p.points[1]
            out(string.format("    POI[%d] objIdx=%s map=%s pt=(%s, %s)",
                i, tostring(p.objectiveIndex), tostring(p.uiMapID),
                pt and tostring(pt.x) or "?", pt and tostring(pt.y) or "?"))
        end
    else
        out("  [3] LibCodex QuestPOI -> module unavailable")
    end

    -- [4] codex-npc parser. Show what we extracted from each objective text
    -- and whether LibCodex NPCs has a matching label.
    out("  [4] codex-npc parser:")
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then
        out("        GetQuestObjectives -> API unavailable")
    else
        local objs = C_QuestLog.GetQuestObjectives(s.questID) or {}
        if #objs == 0 then
            out("        no objectives returned")
        else
            for i, o in ipairs(objs) do
                local name = ns._parseNPCFromObjectiveText and ns._parseNPCFromObjectiveText(o.text or "")
                if not name then
                    out(string.format("        obj[%d] '%s' -> no NPC name parsed", i, o.text or ""))
                else
                    local npc = ns._npcByName and ns._npcByName(name)
                    if not npc then
                        out(string.format("        obj[%d] -> name='%s' but NOT in LibCodex NPCs", i, name))
                    elseif not (npc.locations and npc.locations[1]) then
                        out(string.format("        obj[%d] -> name='%s' in catalog but no locations recorded", i, name))
                    else
                        local loc = npc.locations[1]
                        out(string.format("        obj[%d] -> name='%s' loc=map=%s (%.3f, %.3f)",
                            i, name, tostring(loc.mapID), loc.x or 0, loc.y or 0))
                    end
                end
            end
        end
    end

    -- [5] codex-zone fallback
    if C_QuestLog and C_QuestLog.GetQuestUiMapID then
        local uimap = C_QuestLog.GetQuestUiMapID(s.questID)
        out(string.format("  [5] GetQuestUiMapID -> %s", tostring(uimap)))
    else
        out("  [5] GetQuestUiMapID -> API unavailable")
    end
end, "diagnose Locator (per-layer coord probes for current quest)")

slash:Default(function() slash:PrintHelp() end)
