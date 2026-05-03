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
--   source: short debug tag describing which fallback layer answered.
--     "blizzard"      C_QuestLog.GetNextWaypoint
--     "codex-poi"     LibCodex QuestPOI for this objective
--     "codex-npc"     Parsed an NPC name out of the objective text and
--                     looked it up in LibCodex NPCs catalog
--     "codex-giver"   LibCodex Quests entry mapID/x/y (giver coords)
--     "codex-turnin"  LibCodex NPCs entry for the turnInNPC
--     "codex-zone"    Last-resort: C_QuestLog.GetQuestUiMapID, centered
--                     on the zone (0.5, 0.5). Less accurate; consumers
--                     may render a muted color to flag it as a hint.
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

    local target = (objectiveIndex or 1) - 1   -- LibCodex POI is 0-based
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
-- ==========================================================================

-- Patterns we try, in order. Most specific first. The (.+) capture is the
-- candidate NPC name that we then trim and look up.
local OBJECTIVE_NPC_PATTERNS = {
    "Speak with (.+)",
    "Speak to (.+)",
    "Talk to (.+)",
    "Return to (.+)",
    "Report to (.+)",
}

-- Walk LibCodex NPCs catalog for a label that case-insensitively matches.
-- AllRaw is the canonical iterator on a CollectionFactory module; we only
-- read fields, so this is safe even if the catalog is being mutated.
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

    -- Strip Blizzard's leading "X/Y " count prefix if present.
    local stripped = text:gsub("^%s*%d+%s*/%s*%d+%s*", "")

    for _, pat in ipairs(OBJECTIVE_NPC_PATTERNS) do
        local who = stripped:match(pat)
        if who then
            -- Trim trailing punctuation and stop-phrases.
            who = who:gsub("[%.,;:!?].*", "")     -- "Marla."   -> "Marla"
            who = who:gsub("%s+at%s+.*", "")      -- "Marla at the Inn"
            who = who:gsub("%s+in%s+.*", "")      -- "Marla in Stormwind"
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

-- ==========================================================================
-- Layer: zone-center fallback. Always have *something* to point at.
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
