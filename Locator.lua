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
--       Locator returns where THAT objective lives.
--     - nil = "the quest is complete; point at the turn-in".
--
--   source: short debug tag describing which fallback layer answered:
--     "blizzard"      C_QuestLog.GetNextWaypoint
--     "codex-poi"     LibCodex QuestPOI for the objective
--     "codex-turnin"  LibCodex NPCs entry for the turn-in NPC
--     "codex-giver"   LibCodex Quests entry x/y (giver coords as a rough hint)
--     "missing"       no layer had an answer
--
-- The convenience entry point Resolve() dispatches between ResolveObjective
-- and ResolveTurnIn based on whether objectiveIndex is nil.

local ADDON, ns = ...
ns.Locator = ns.Locator or {}
local Locator = ns.Locator

-- --------------------------------------------------------------------------
-- LibCodex accessors. All wrapped so a missing module returns nil cleanly
-- instead of erroring; Vellum should still run if LibCodex modules drift.
-- --------------------------------------------------------------------------

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

local function codexNPCFirstLoc(npcID)
    if not npcID then return nil end
    local lc = libCodex()
    if not (lc and lc.NPCs) then return nil end
    local mod = lc:NPCs()
    if not (mod and mod.Get) then return nil end
    local n = mod:Get(npcID)
    if not (n and n.locations and n.locations[1]) then return nil end
    local loc = n.locations[1]
    if loc.mapID and loc.x and loc.y then
        return loc.mapID, loc.x, loc.y
    end
    return nil
end

local function codexPOIForObjective(questID, objectiveIndex)
    local lc = libCodex()
    if not (lc and lc.QuestPOI) then return nil end
    local mod = lc:QuestPOI()
    if not (mod and mod.ForQuest) then return nil end

    -- LibCodex QuestPOI.objectiveIndex is 0-based (matches DBC OrderIndex).
    -- The caller passes 1-based to match C_QuestLog.GetQuestObjectives.
    local target = (objectiveIndex or 1) - 1
    local pois = mod:ForQuest(questID) or {}

    -- Exact objective match.
    for _, p in ipairs(pois) do
        if (p.objectiveIndex or 0) == target
            and p.points and p.points[1] and p.uiMapID then
            local pt = p.points[1]
            if pt.x and pt.y then
                return p.uiMapID, pt.x, pt.y
            end
        end
    end

    -- Soft fallback: any POI on this quest is better than nothing.
    for _, p in ipairs(pois) do
        if p.points and p.points[1] and p.uiMapID then
            local pt = p.points[1]
            if pt.x and pt.y then
                return p.uiMapID, pt.x, pt.y
            end
        end
    end

    return nil
end

-- --------------------------------------------------------------------------
-- Public resolvers.
-- --------------------------------------------------------------------------

function Locator.ResolveObjective(questID, objectiveIndex)
    if type(questID) ~= "number" then
        return nil, nil, nil, "missing"
    end

    local m, x, y = blizzardWaypoint(questID)
    if m then return m, x, y, "blizzard" end

    m, x, y = codexPOIForObjective(questID, objectiveIndex)
    if m then return m, x, y, "codex-poi" end

    local q = codexQuestEntry(questID)
    if q and q.mapID and q.x and q.y then
        return q.mapID, q.x, q.y, "codex-giver"
    end

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

    if q and q.mapID and q.x and q.y then
        return q.mapID, q.x, q.y, "codex-giver"
    end

    return nil, nil, nil, "missing"
end

function Locator.Resolve(questID, objectiveIndex)
    if objectiveIndex == nil then
        return Locator.ResolveTurnIn(questID)
    end
    return Locator.ResolveObjective(questID, objectiveIndex)
end
