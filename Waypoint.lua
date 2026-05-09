-- Vellum/Waypoint.lua
-- Waypoint generator. Given a questID and the current world state, returns
-- a single waypoint record (or nil if the quest produces no actionable
-- waypoint right now). The route planner enumerates candidate quests and
-- calls Waypoint.For on each to build the list it solves a TSP over.
--
-- Waypoint record shape:
--
--   {
--       questID = 12345,
--       type    = "PICKUP" | "OBJECTIVE" | "TURNIN",
--       title   = "Wolves of the Wood",
--       label   = "Pick up Wolves of the Wood",     -- short, render-ready
--       objIdx  = 1,                                -- only when type=OBJECTIVE
--       objText = "Wolves slain: 0/8",              -- only when type=OBJECTIVE
--       mapID   = 14,
--       x       = 0.42,
--       y       = 0.71,
--       source  = "blizzard"|"codex-poi"|"codex-turnin"|"codex-giver"|"missing",
--   }
--
-- Mapping from Follower.STATES to waypoint types:
--
--   NOT_IN_LOG       -> PICKUP    (target = giver)
--   OBJECTIVE        -> OBJECTIVE (target = current objective coords)
--   READY_TO_TURNIN  -> TURNIN    (target = turn-in NPC)
--   DONE | ABANDONED | UNKNOWN -> nil (no waypoint)
--
-- A nil result is the planner's signal to skip this quest entirely.
-- A non-nil result with mapID/x/y == nil means "we know we should be
-- somewhere but Locator couldn't resolve where"; the planner treats those
-- as low-priority and may de-rank or omit them.
--
-- Public API:
--   Vellum.Waypoint.For(questID)         -> waypoint record or nil
--   Vellum.Waypoint.ForMany(questIDs)    -> list of waypoint records
--                                            (nil entries skipped)
--   Vellum.Waypoint.IsActionable(wp)     -> bool: has usable coords

local ADDON, ns = ...
ns.Waypoint = ns.Waypoint or {}
local Waypoint = ns.Waypoint

local STATES   -- bound at file scope below; resolved lazily for safety

local function states()
    if not STATES then
        STATES = ns.Follower and ns.Follower.STATES
    end
    return STATES
end

-- ==========================================================================
-- Label builders (short human-readable strings for StepWindow rows)
-- ==========================================================================

local function labelPickup(s)
    local title = s.title or ("Quest " .. tostring(s.questID))
    return "Pick up " .. title
end

local function labelObjective(s)
    -- The objective text is usually self-explanatory ("Wolves slain: 0/8").
    -- Quest title precedes it for context when the row is shown standalone.
    local objText = s.objectiveText or ""
    if objText ~= "" then
        return objText
    end
    return s.title or ("Quest " .. tostring(s.questID))
end

local function labelTurnin(s)
    local title = s.title or ("Quest " .. tostring(s.questID))
    return "Turn in " .. title
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Waypoint.For(questID)
    if not (ns.Follower and ns.Follower.ComputeState) then return nil end
    local S = states()
    if not S then return nil end

    local s = ns.Follower.ComputeState(questID)
    if not s then return nil end

    if s.state == S.NOT_IN_LOG then
        return {
            questID = questID,
            type    = "PICKUP",
            title   = s.title,
            label   = labelPickup(s),
            mapID   = s.mapID, x = s.x, y = s.y, source = s.source,
        }

    elseif s.state == S.OBJECTIVE then
        return {
            questID = questID,
            type    = "OBJECTIVE",
            title   = s.title,
            label   = labelObjective(s),
            objIdx  = s.objectiveIndex,
            objText = s.objectiveText,
            mapID   = s.mapID, x = s.x, y = s.y, source = s.source,
        }

    elseif s.state == S.READY_TO_TURNIN then
        return {
            questID = questID,
            type    = "TURNIN",
            title   = s.title,
            label   = labelTurnin(s),
            mapID   = s.mapID, x = s.x, y = s.y, source = s.source,
        }
    end

    -- DONE / ABANDONED / UNKNOWN: no waypoint.
    return nil
end

function Waypoint.ForMany(questIDs)
    local out = {}
    if type(questIDs) ~= "table" then return out end
    for _, qid in ipairs(questIDs) do
        local wp = Waypoint.For(qid)
        if wp then out[#out + 1] = wp end
    end
    return out
end

function Waypoint.IsActionable(wp)
    return wp ~= nil
       and type(wp.mapID) == "number"
       and type(wp.x) == "number"
       and type(wp.y) == "number"
       and wp.source ~= "missing"
end
