-- Vellum/Follower.lua
-- The quest-event observer. One quest is "followed" at a time. On every
-- relevant quest event we recompute the current step (which objective is
-- active, or whether the quest is ready to turn in) and fire OnChange
-- callbacks if the resolved location actually changed.
--
-- Public API:
--
--   Vellum.Follower.Set(questID)        start following questID
--   Vellum.Follower.Clear()             stop following anything
--   Vellum.Follower.Refresh()           recompute current step now
--   Vellum.Follower.Get()               returns the live state table (read-only)
--   Vellum.Follower.OnChange(fn)        subscribe; returns unsubscribe closure
--                                        fn receives the state table
--
-- State shape (all fields nil when not following):
--   {
--     questID         = 12345,
--     questTitle      = "Wolves of the Wood",
--     objectiveIndex  = 1,                 -- 1-based; nil when isComplete
--     objectiveText   = "Wolves slain: 0/8",
--     isComplete      = false,
--     mapID = 14, x = 0.42, y = 0.71,
--     source          = "blizzard"|"codex-poi"|"codex-turnin"|"codex-giver"|"missing",
--   }
--
-- OnChange fires only when the resolved signature differs from the previous
-- one (questID + objectiveIndex + isComplete + mapID + x + y), so a noisy
-- QUEST_LOG_UPDATE storm doesn't translate to N callback runs.

local ADDON, ns = ...
ns.Follower = ns.Follower or {}
local Follower = ns.Follower

-- --------------------------------------------------------------------------
-- State + subscribers
-- --------------------------------------------------------------------------

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
}

local subs    = {}    -- set of subscriber functions
local lastSig = ""    -- last fired signature, for change-detection

local function notify()
    for fn in pairs(subs) do
        local ok, err = pcall(fn, state)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

local function signature()
    return string.format("%s|%s|%s|%s|%s|%s",
        tostring(state.questID),
        tostring(state.objectiveIndex),
        tostring(state.isComplete),
        tostring(state.mapID),
        tostring(state.x),
        tostring(state.y))
end

local function clearState()
    state.questID        = nil
    state.questTitle     = nil
    state.objectiveIndex = nil
    state.objectiveText  = nil
    state.isComplete     = false
    state.mapID, state.x, state.y, state.source = nil, nil, nil, nil
end

-- --------------------------------------------------------------------------
-- Public API
-- --------------------------------------------------------------------------

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
    clearState()
    lastSig = ""
    notify()
end

function Follower.Refresh()
    if not state.questID then return end

    -- Quest no longer in the log? Drop it.
    if C_QuestLog and C_QuestLog.IsOnQuest
        and not C_QuestLog.IsOnQuest(state.questID) then
        Follower.Clear()
        return
    end

    -- Title (best effort; may be nil during a cold cache moment).
    if C_QuestLog and C_QuestLog.GetTitleForQuestID then
        local t = C_QuestLog.GetTitleForQuestID(state.questID)
        if t and t ~= "" then state.questTitle = t end
    end

    -- Complete? Look at objectives next; otherwise pick next unfinished.
    state.isComplete = (C_QuestLog and C_QuestLog.IsComplete
        and C_QuestLog.IsComplete(state.questID)) or false

    local Locator = ns.Locator

    if state.isComplete then
        state.objectiveIndex = nil
        state.objectiveText  = "Return to turn-in"
        if Locator and Locator.ResolveTurnIn then
            state.mapID, state.x, state.y, state.source =
                Locator.ResolveTurnIn(state.questID)
        end
    else
        local objectives = (C_QuestLog and C_QuestLog.GetQuestObjectives
            and C_QuestLog.GetQuestObjectives(state.questID)) or {}
        local idx, obj
        for i, o in ipairs(objectives) do
            if not o.finished then idx, obj = i, o; break end
        end
        if idx then
            state.objectiveIndex = idx
            state.objectiveText  = obj.text or ""
            if Locator and Locator.ResolveObjective then
                state.mapID, state.x, state.y, state.source =
                    Locator.ResolveObjective(state.questID, idx)
            end
        else
            -- All objectives report finished but IsComplete didn't say so.
            -- Treat as "almost there"; aim at the turn-in.
            state.objectiveIndex = nil
            state.objectiveText  = "Almost done..."
            if Locator and Locator.ResolveTurnIn then
                state.mapID, state.x, state.y, state.source =
                    Locator.ResolveTurnIn(state.questID)
            end
        end
    end

    local sig = signature()
    if sig ~= lastSig then
        lastSig = sig
        notify()
    end
end

-- --------------------------------------------------------------------------
-- Event wiring (skipped under Lupa where Cairn.Events is absent).
-- --------------------------------------------------------------------------

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
