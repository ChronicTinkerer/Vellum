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
            -- HomeWindow state. Position + which top tab + which sidebar
            -- category is active, plus the Phase 2 saved-variable backings
            -- for the four dashboard tiles (history, gold, favorites,
            -- time-played). All tiles read from these tables; Phase 2
            -- writes to them via Cairn.Events subscriptions in HomeData.lua.
            home = {
                x = 0, y = 0,
                selectedTab     = "home",       -- Home / Active / Recent
                sidebarSelected = "dashboard",  -- "dashboard" or category id

                -- Capped list of recently followed quests. Newest first.
                -- Cap is enforced in HomeData.PushHistoryEntry (default 50).
                -- Each entry: { questID, title, followedAt = epoch_seconds,
                --               completedAt = epoch_seconds_or_nil,
                --               mapID = number_or_nil }
                guideHistory = {},

                -- Gold accumulator. Updated on PLAYER_MONEY.
                -- dayKey   "YYYY-MM-DD"   the day todayDelta belongs to
                -- weekKey  "YYYY-WW"      the ISO week weekDelta belongs to
                -- todayDelta / weekDelta  copper net change since rollover
                -- lastSeen                last GetMoney() value (for diffing)
                gold = {
                    dayKey     = nil,
                    weekKey    = nil,
                    todayDelta = 0,
                    weekDelta  = 0,
                    lastSeen   = 0,
                },

                -- Favorited quests. Set keyed by questID, value = true.
                favorites = {},

                -- Time-played state. Refreshed via RequestTimePlayed +
                -- TIME_PLAYED_MSG. Live time = totalAtLogin + (GetTime() -
                -- sessionStartGameTime). Both fields nil before first msg.
                timePlayed = {
                    totalAtLogin         = nil,
                    sessionStartGameTime = nil,
                },
            },
            stepWindow = {
                x = 0, y = 0,
                tabs      = {},   -- ordered list of followed quest IDs
                activeTab = nil,  -- currently focused tab id
            },
            arrow  = { x = 0, y = 200, scale = 1 },

            -- Phase 3B route-planner settings. The planner reads these on
            -- every Recompute. SetMode/SetRadius from RoutePlanner.lua mutate
            -- this table and trigger a recalc.
            --   mode         = "radius" | "completionist"
            --   radius       = include catalog quests within this many
            --                  game-yards of the player (radius mode only)
            --   maxWaypoints = solver cap; routes longer than this get
            --                  truncated after candidate enumeration
            --   debounceMs   = trailing-edge debounce window for recalc
            --                  triggers (QUEST_LOG_UPDATE etc. fire often)
            engine = {
                mode         = "radius",
                radius       = 1500,
                maxWaypoints = 50,
                debounceMs   = 250,
            },
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

    -- Phase 3D: /vellum follow X pins X as route[1] in the planner so the
    -- arrow points there regardless of which other waypoint is currently
    -- closest. Legacy Follower.Set still mutates so the (read-only) state
    -- table reflects user intent.
    if ns.Follower and ns.Follower.Set then ns.Follower.Set(qid) end
    if ns.RoutePlanner and ns.RoutePlanner.Pin then
        ns.RoutePlanner.Pin(qid)
    end

    local title = (C_QuestLog and C_QuestLog.GetTitleForQuestID
        and C_QuestLog.GetTitleForQuestID(qid)) or tostring(qid)
    out(string.format("pinned: %s (id %d)", title, qid))
end, "pin a quest as next. no arg = supertracker; or pass <id> | <partial name>")

slash:Subcommand("stop", function()
    if ns.Follower and ns.Follower.Clear then ns.Follower.Clear() end
    if ns.RoutePlanner and ns.RoutePlanner.Unpin then
        ns.RoutePlanner.Unpin()
    end
    if ns.Arrow and ns.Arrow.Stop then ns.Arrow.Stop() end
    if ns.StepWindow and ns.StepWindow.Hide then ns.StepWindow.Hide() end
    out("unpinned + stopped.")
end, "unpin any pinned quest and stop tracking")

slash:Subcommand("home", function()
    if ns.HomeWindow and ns.HomeWindow.Toggle then
        ns.HomeWindow.Toggle()
    end
end, "toggle the Vellum Home launcher")

slash:Subcommand("guide", function(rest)
    local input = (rest and rest:match("^%s*(.-)%s*$")) or ""
    if input == "" then
        if ns.StepWindow and ns.StepWindow.Toggle then
            ns.StepWindow.Toggle()
        end
        return
    end
    local qid, err = resolveQuestID(input)
    if not qid then out(err) return end
    if ns.StepWindow and ns.StepWindow.OpenForQuest then
        ns.StepWindow.OpenForQuest(qid)
    end
end, "open the Step viewer (no arg toggles; or pass <id>|<partial name>)")

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

-- Bare `/vellum` opens the Home launcher (the canonical Zygor-style
-- entry point). `/vellum help` still prints the full subcommand list.
slash:Default(function()
    if ns.HomeWindow and ns.HomeWindow.Toggle then
        ns.HomeWindow.Toggle()
    else
        slash:PrintHelp()
    end
end)
