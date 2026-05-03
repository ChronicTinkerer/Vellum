-- Vellum/Locator.lua
-- Resolve where to point the Vellum arrow for a given quest state.
--
-- Public API:
--
--   Vellum.Locator.Resolve(questID, objectiveIndex)
--     -> mapID, x, y, source     (or nil, nil, nil, "missing")
--
--   objectiveIndex:
--     - a 1-based index into C_QuestLog.GetQuestObjectives() output.
--     - nil = "the quest is complete; point at the turn-in".
--
--   source: short debug tag describing which fallback layer answered.
--     "blizzard"      C_QuestLog.GetNextWaypoint
--     "codex-poi"     LibCodex QuestPOI for this objective
--     "codex-npc"     Parsed NPC name from objective text -> LibCodex NPCs
--     "codex-giver"   LibCodex Quests entry mapID/x/y
--     "codex-turnin"  LibCodex NPCs entry for the turnInNPC
--     "codex-zone"    GetQuestUiMapID, centered on the zone (rough hint)
--     "missing"       no layer had an answer

local ADDON, ns = ...
ns.Locator = ns.Locator or {}
local Locator = ns.Locator

-- ==========================================================================
-- LibCodex accessors
-- ==========================================================================

local function libCodex()
    if not LibStub then return nil end
    return LibStub("LibCodex-1.0", true)
end

local function blizzardWaypoint(questID)
    if not (C_QuestLog and C_QuestLog.GetNextWaypoint) then return nil end
    local mapID, x, y = C_QuestLog.GetNextWaypoint(questID)
    if mapID and x and y then return mapID, x, y end
    return nil
end

local function codexQuestEntry(questID)
    local lc = libCodex()
    if not (lc and lc.Quests) then return nil end
    local mod = lc:Quests()
    if not (mod and mod.Get) then return nil end
    return mod:Get(questID)
end

local function npcFirstLoc(npc)
    if not (npc and npc.locations and npc.locations[1]) then return nil end
    local loc = npc.locations[1]
    if loc.mapID and loc.x and loc.y then
        return loc.mapID, loc.x, loc.y
    end
    return nil
end

local function codexNPCFirstLoc(npcID)
    if not npcID then return nil end
    local lc = libCodex()
    if not (lc and lc.NPCs) then return nil end
    local mod = lc:NPCs()
    if not (mod and mod.Get) then return nil end
    return npcFirstLoc(mod:Get(npcID))
end

local function codexPOIForObjective(questID, objectiveIndex)
    local lc = libCodex()
    if not (lc and lc.QuestPOI) then return nil end
    local mod = lc:QuestPOI()
    if not (mod and mod.ForQuest) then return nil end

    local target = (objectiveIndex or 1) - 1
    local pois = mod:ForQuest(questID) or {}

    for _, p in ipairs(pois) do
        if (p.objectiveIndex or 0) == target
            and p.points and p.points[1] and p.uiMapID then
            local pt = p.points[1]
            if pt.x and pt.y then return p.uiMapID, pt.x, pt.y end
        end
    end
    for _, p in ipairs(pois) do
        if p.points and p.points[1] and p.uiMapID then
            local pt = p.points[1]
            if pt.x and pt.y then return p.uiMapID, pt.x, pt.y end
        end
    end
    return nil
end

-- ==========================================================================
-- Layer: parse objective text -> NPC name -> LibCodex NPCs lookup.
-- Available to both ResolveObjective (single text) and ResolveTurnIn
-- (scans all objective texts; useful when the completion text contains
-- "Return to X").
-- ==========================================================================

local OBJECTIVE_NPC_PATTERNS = {
    "Speak with (.+)",
    "Speak to (.+)",
    "Talk to (.+)",
    "Return to (.+)",
    "Report to (.+)",
}

local function npcByName(name)
    if not (name and name ~= "") then return nil end
    local lc = libCodex()
    if not (lc and lc.NPCs) then return nil end
    local mod = lc:NPCs()
    if not (mod and mod.AllRaw) then return nil end

    local target = name:lower()
    for _, e in pairs(mod:AllRaw()) do
        if e.label and e.label:lower() == target then
            return e
        end
    end
    return nil
end

local function parseNPCFromObjectiveText(text)
    if not text or text == "" then return nil end

    local stripped = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")

    for _, pat in ipairs(OBJECTIVE_NPC_PATTERNS) do
        local who = stripped:match(pat)
        if who then
            who = who:gsub("[%.,;:!?].*", "")
            who = who:gsub("%s+at%s+.*", "")
            who = who:gsub("%s+in%s+.*", "")
            who = who:gsub("^%s+", ""):gsub("%s+$", "")
            if who ~= "" then return who end
        end
    end
    return nil
end

local function codexNPCByObjectiveText(questID, objectiveIndex)
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return nil end
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if not (objs and objs[objectiveIndex or 1]) then return nil end
    local name = parseNPCFromObjectiveText(objs[objectiveIndex or 1].text or "")
    if not name then return nil end
    return npcFirstLoc(npcByName(name))
end

-- Scan ALL objectives for any parseable NPC name. Used by the turn-in path
-- because completion text often lives in an objective entry like
-- "Return to Khadgar."
local function codexNPCByAnyObjective(questID)
    if not (C_QuestLog and C_QuestLog.GetQuestObjectives) then return nil end
    local objs = C_QuestLog.GetQuestObjectives(questID)
    if not objs then return nil end
    for _, o in ipairs(objs) do
        local name = parseNPCFromObjectiveText(o.text or "")
        if name then
            local m, x, y = npcFirstLoc(npcByName(name))
            if m then return m, x, y end
        end
    end
    return nil
end

-- ==========================================================================
-- Layer: zone-center fallback.
-- ==========================================================================

local function questZoneFallback(questID)
    if not (C_QuestLog and C_QuestLog.GetQuestUiMapID) then return nil end
    local mapID = C_QuestLog.GetQuestUiMapID(questID)
    if not (mapID and mapID > 0) then return nil end
    return mapID, 0.5, 0.5
end

-- ==========================================================================
-- Public resolvers
-- ==========================================================================

function Locator.ResolveObjective(questID, objectiveIndex)
    if type(questID) ~= "number" then
        return nil, nil, nil, "missing"
    end

    local m, x, y = blizzardWaypoint(questID)
    if m then return m, x, y, "blizzard" end

    m, x, y = codexPOIForObjective(questID, objectiveIndex)
    if m then return m, x, y, "codex-poi" end

    m, x, y = codexNPCByObjectiveText(questID, objectiveIndex)
    if m then return m, x, y, "codex-npc" end

    local q = codexQuestEntry(questID)
    if q and q.mapID and q.x and q.y then
        return q.mapID, q.x, q.y, "codex-giver"
    end

    m, x, y = questZoneFallback(questID)
    if m then return m, x, y, "codex-zone" end

    return nil, nil, nil, "missing"
end

function Locator.ResolveTurnIn(questID)
    if type(questID) ~= "number" then
        return nil, nil, nil, "missing"
    end

    local m, x, y = blizzardWaypoint(questID)
    if m then return m, x, y, "blizzard" end

    local q = codexQuestEntry(questID)
    if q and q.turnInNPC then
        m, x, y = codexNPCFirstLoc(q.turnInNPC)
        if m then return m, x, y, "codex-turnin" end
    end

    -- Scan completion-text objectives for "Return to X" / "Speak with X"
    -- patterns. Catches WoD/Legion class-hall quests where Blizzard doesn't
    -- supply a waypoint and LibCodex doesn't have giver/turnIn coords yet.
    m, x, y = codexNPCByAnyObjective(questID)
    if m then return m, x, y, "codex-npc" end

    if q and q.mapID and q.x and q.y then
        return q.mapID, q.x, q.y, "codex-giver"
    end

    m, x, y = questZoneFallback(questID)
    if m then return m, x, y, "codex-zone" end

    return nil, nil, nil, "missing"
end

function Locator.Resolve(questID, objectiveIndex)
    if objectiveIndex == nil then
        return Locator.ResolveTurnIn(questID)
    end
    return Locator.ResolveObjective(questID, objectiveIndex)
end

-- Internal exports for testing.
ns._parseNPCFromObjectiveText = parseNPCFromObjectiveText
ns._npcByName                 = npcByName
