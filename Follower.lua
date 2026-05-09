-- Vellum/Follower.lua
-- Quest-state observer + state machine.
--
-- Two layers in this file:
--
-- 1. Pure layer -- Follower.ComputeState(questID) is a pure function over
--    (C_QuestLog state + LibCodex catalog + Locator). Given any questID it
--    returns a state record telling you "what's going on with this quest
--    right now." Used by the engine (Waypoint.For, RoutePlanner) to survey
--    many quests at once. Doesn't mutate anything.
--
-- 2. Live layer -- the legacy single-quest "currently followed" surface.
--    Set(qid) / Clear() / Refresh() / Get() / OnChange(fn). Internally
--    Refresh now calls ComputeState; behavior is unchanged for callers
--    that already use this API (Arrow.lua, HomeWindow.lua, HomeData.lua).
--
-- ----- States ----------------------------------------------------------
-- STATES.NOT_IN_LOG        Quest is in catalog with known giver coords;
--                          player doesn't have it. Engine will route here
--                          for pickup.
-- STATES.OBJECTIVE         Quest is in log; at least one objective is
--                          unfinished. Record carries objectiveIndex +
--                          objectiveText + the resolved (mapID, x, y) for
--                          that objective via Locator.ResolveObjective.
-- STATES.READY_TO_TURNIN   Quest is in log + IsComplete is true (or all
--                          objectives report finished). Record carries the
--                          turn-in (mapID, x, y) via Locator.ResolveTurnIn.
-- STATES.DONE              IsQuestFlaggedCompleted returns true. Quest is
--                          finished and history; engine emits no waypoint.
-- STATES.ABANDONED         (Reserved.) Engine doesn't observe this state
--                          today -- the live layer just clears on
--                          QUEST_REMOVED. Kept in the enum so consumers
--                          can pattern-match completely.
-- STATES.UNKNOWN           Not in log + not in catalog with usable coords.
--                          Engine emits no waypoint.
--
-- Public API:
--
--   Vellum.Follower.STATES                table of state-name strings
--   Vellum.Follower.ComputeState(qid)     pure: returns state record
--   Vellum.Follower.Set(qid)              live: start following one quest
--   Vellum.Follower.Clear()               live: stop following anything
--   Vellum.Follower.Refresh()             live: recompute current step
--   Vellum.Follower.Get()                 live: returns the state table
--   Vellum.Follower.OnChange(fn)          live: subscribe; returns
--                                         unsubscribe-closure

local ADDON, ns = ...
ns.Follower = ns.Follower or {}
local Follower = ns.Follower

-- ==========================================================================
-- States
-- ==========================================================================

Follower.STATES = {
    NOT_IN_LOG       = "NOT_IN_LOG",
    OBJECTIVE        = "OBJECTIVE",
    READY_TO_TURNIN  = "READY_TO_TURNIN",
    DONE             = "DONE",
    ABANDONED        = "ABANDONED",
    UNKNOWN          = "UNKNOWN",
}
local STATES = Follower.STATES

-- ==========================================================================
-- LibStub
-- ==========================================================================

local function libCodex()
    return LibStub and LibStub("LibCodex-1.0", true)
end

-- ==========================================================================
-- Pure: ComputeState(questID)
-- ==========================================================================

-- Helper: pull the catalog entry for questID (or nil).
local function catalogEntry(questID)
    local lc  = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    if not (mod and mod.Get) then return nil end
    return mod:Get(questID)
end

-- Returns a fresh state record. Never reads or writes Follower's live state.
-- Safe to call for any questID in any quantity (the planner will hammer it).
function Follower.ComputeState(questID)
    if type(questID) ~= "number" or questID <= 0 then
        return { state = STATES.UNKNOWN, questID = questID }
    end

    -- Quest already turned in (account history)?
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
       and C_QuestLog.IsQuestFlaggedCompleted(questID) then
        return { state = STATES.DONE, questID = questID }
    end

    -- Currently in log?
    if C_QuestLog and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(questID) then
        local title = (C_QuestLog.GetTitleForQuestID
            and C_QuestLog.GetTitleForQuestID(questID)) or nil

        local isComplete = (C_QuestLog.IsComplete
            and C_QuestLog.IsComplete(questID)) or false

        if isComplete then
            local mapID, x, y, source
            if ns.Locator and ns.Locator.ResolveTurnIn then
                mapID, x, y, source = ns.Locator.ResolveTurnIn(questID)
            end
            return {
                state   = STATES.READY_TO_TURNIN,
                questID = questID,
                title   = title,
                mapID   = mapID, x = x, y = y, source = source,
            }
        end

        -- Pick first unfinished objective.
        local objectives = (C_QuestLog.GetQuestObjectives
            and C_QuestLog.GetQuestObjectives(questID)) or {}
        local idx, obj
        for i, o in ipairs(objectives) do
            if not o.finished then idx, obj = i, o; break end
        end

        if not idx then
            -- All objectives report finished but IsComplete didn't say so.
            -- Treat as turn-in (matches legacy Refresh behavior).
            local mapID, x, y, source
            if ns.Locator and ns.Locator.ResolveTurnIn then
                mapID, x, y, source = ns.Locator.ResolveTurnIn(questID)
            end
            return {
                state   = STATES.READY_TO_TURNIN,
                questID = questID,
                title   = title,
                mapID   = mapID, x = x, y = y, source = source,
            }
        end

        local mapID, x, y, source
        if ns.Locator and ns.Locator.ResolveObjective then
            mapID, x, y, source = ns.Locator.ResolveObjective(questID, idx)
        end
        return {
            state          = STATES.OBJECTIVE,
            questID        = questID,
            title          = title,
            objectiveIndex = idx,
            objectiveText  = obj.text or "",
            mapID = mapID, x = x, y = y, source = source,
        }
    end

    -- Not in log. Catalog entry with a usable giver location?
    local q = catalogEntry(questID)
    if q then
        -- Flat shape (runtime-added entries via AddFromAPI).
        if q.mapID and q.x and q.y then
            return {
                state   = STATES.NOT_IN_LOG,
                questID = questID,
                title   = q.label,
                mapID = q.mapID, x = q.x, y = q.y, source = "codex-giver",
                level   = q.level,
                side    = q.side,
            }
        end
        -- Bundled-row shape: walk q.locations for point="start" entry.
        -- Prefer player's current map, otherwise first start point.
        if type(q.locations) == "table" then
            local pmap = (C_Map and C_Map.GetBestMapForUnit
                and C_Map.GetBestMapForUnit("player")) or nil
            local picked
            if pmap then
                for _, loc in ipairs(q.locations) do
                    if loc.point == "start"
                       and loc.mapID == pmap
                       and loc.x and loc.y then
                        picked = loc; break
                    end
                end
            end
            if not picked then
                for _, loc in ipairs(q.locations) do
                    if loc.point == "start"
                       and loc.mapID and loc.x and loc.y then
                        picked = loc; break
                    end
                end
            end
            if picked then
                return {
                    state   = STATES.NOT_IN_LOG,
                    questID = questID,
                    title   = q.label,
                    mapID   = picked.mapID,
                    x       = picked.x,
                    y       = picked.y,
                    source  = "codex-locations-start",
                    level   = q.level,
                    side    = q.side,
                }
            end
        end
    end

    -- Catalog has it but no coords, or not in catalog at all.
    return {
        state   = STATES.UNKNOWN,
        questID = questID,
        title   = q and q.label or nil,
    }
end

-- ==========================================================================
-- Live: single-quest follower (legacy API)
-- ==========================================================================

local state = {
    questID        = nil,
    questTitle     = nil,
    objectiveIndex = nil,
    objectiveText  = nil,
    isComplete     = false,
    mapID          = nil,
    x              = nil,
    y              = nil,
    source         = nil,
    -- Phase 3A: also expose the engine state name for any consumer that
    -- wants to know "is this NOT_IN_LOG vs OBJECTIVE vs READY_TO_TURNIN".
    engineState    = nil,
}

local subs    = {}
local lastSig = ""

local function notify()
    for fn in pairs(subs) do
        local ok, err = pcall(fn, state)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

local function signature()
    return string.format("%s|%s|%s|%s|%s|%s|%s",
        tostring(state.questID),
        tostring(state.engineState),
        tostring(state.objectiveIndex),
        tostring(state.isComplete),
        tostring(state.mapID),
        tostring(state.x),
        tostring(state.y))
end

local function clearLive()
    state.questID        = nil
    state.questTitle     = nil
    state.objectiveIndex = nil
    state.objectiveText  = nil
    state.isComplete     = false
    state.mapID, state.x, state.y, state.source = nil, nil, nil, nil
    state.engineState    = nil
end

function Follower.Get() return state end

function Follower.OnChange(fn)
    if type(fn) ~= "function" then
        error("Vellum.Follower.OnChange: fn must be a function", 2)
    end
    subs[fn] = true
    return function() subs[fn] = nil end
end

function Follower.Set(questID)
    if type(questID) ~= "number" then
        return false, "questID must be a number"
    end
    state.questID = questID
    Follower.Refresh()
    return true
end

function Follower.Clear()
    if state.questID == nil then return end
    clearLive()
    lastSig = ""
    notify()
end

function Follower.Refresh()
    if not state.questID then return end

    local computed = Follower.ComputeState(state.questID)

    -- Engine says quest is done / unknown / abandoned -> clear the live
    -- single-quest follower. (DONE here means turned in, which matches
    -- the legacy "QUEST_TURNED_IN" auto-clear behavior.)
    if computed.state == STATES.DONE
       or computed.state == STATES.UNKNOWN
       or computed.state == STATES.ABANDONED then
        Follower.Clear()
        return
    end

    -- NOT_IN_LOG: the legacy follower expected the quest to be in log. Keep
    -- legacy behavior (clear) so existing callers don't get surprised. The
    -- planner uses ComputeState directly and handles NOT_IN_LOG itself.
    if computed.state == STATES.NOT_IN_LOG then
        Follower.Clear()
        return
    end

    -- OBJECTIVE or READY_TO_TURNIN: copy fields into live state.
    state.questTitle     = computed.title
    state.objectiveIndex = computed.objectiveIndex
    state.objectiveText  = computed.objectiveText
        or (computed.state == STATES.READY_TO_TURNIN
            and "Return to turn-in" or nil)
    state.isComplete     = (computed.state == STATES.READY_TO_TURNIN)
    state.mapID          = computed.mapID
    state.x              = computed.x
    state.y              = computed.y
    state.source         = computed.source
    state.engineState    = computed.state

    local sig = signature()
    if sig ~= lastSig then
        lastSig = sig
        notify()
    end
end

-- ==========================================================================
-- Event wiring (skipped under Lupa where Cairn.Events is absent).
-- ==========================================================================

if Cairn and Cairn.Events then
    local owner = "Vellum.Follower"
    Cairn.Events:Subscribe("QUEST_LOG_UPDATE", function()
        Follower.Refresh()
    end, owner)
    Cairn.Events:Subscribe("UNIT_QUEST_LOG_CHANGED", function(unit)
        if unit == "player" then Follower.Refresh() end
    end, owner)
    Cairn.Events:Subscribe("QUEST_ACCEPTED", function()
        Follower.Refresh()
    end, owner)
    Cairn.Events:Subscribe("QUEST_REMOVED", function(questID)
        if questID == state.questID then Follower.Clear() end
    end, owner)
    Cairn.Events:Subscribe("QUEST_TURNED_IN", function(questID)
        if questID == state.questID then Follower.Clear() end
    end, owner)
end
