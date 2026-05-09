-- Vellum/HomeData.lua
-- Saved-variable state + event hooks that drive the HomeWindow dashboard
-- tiles. Kept separate from HomeWindow.lua so the UI module stays focused
-- on layout and the data layer can be tested in isolation.
--
-- Public API:
--
--   Vellum.HomeData.PushHistoryEntry(questID, title, mapID)
--   Vellum.HomeData.MarkHistoryComplete(questID)
--   Vellum.HomeData.GetHistory(maxN)         -> array of entries (newest first)
--   Vellum.HomeData.GetGold()                -> { todayDelta, weekDelta,
--                                                 dayKey, weekKey }
--   Vellum.HomeData.GetTimePlayed()          -> { level, sessionSec, totalSec,
--                                                 hasData = bool }
--   Vellum.HomeData.GetFavorites()           -> map [questID] = true
--   Vellum.HomeData.IsFavorite(questID)      -> bool
--   Vellum.HomeData.ToggleFavorite(questID)  -> new state (true / false)
--   Vellum.HomeData.OnChanged(fn)            -> unsubscribe-closure
--                                              fn() runs whenever any tracked
--                                              state changes.
--
-- Event subscriptions (Cairn.Events, file scope):
--   PLAYER_MONEY    -> diff vs gold.lastSeen, accumulate today/week deltas
--   QUEST_TURNED_IN -> mark the matching history entry as completed
--   TIME_PLAYED_MSG -> capture totalAtLogin + sessionStartGameTime
--   PLAYER_LOGIN    -> snapshot starting money so the first PLAYER_MONEY
--                      event after login produces a real delta
--
-- Wraps ns.Follower.OnChange to push history when a new questID becomes the
-- followed one (for now -- Phase 3 will hook this on Follower:Follow / Set).

local ADDON, ns = ...
ns.HomeData = ns.HomeData or {}
local HomeData = ns.HomeData

-- ==========================================================================
-- Constants
-- ==========================================================================

local HISTORY_CAP = 50

-- ==========================================================================
-- Subscriber bus (HomeWindow re-renders on data change)
-- ==========================================================================

local subs = {}

local function notify()
    for fn in pairs(subs) do
        local ok, err = pcall(fn)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

function HomeData.OnChanged(fn)
    if type(fn) ~= "function" then
        error("Vellum.HomeData.OnChanged: fn must be a function", 2)
    end
    subs[fn] = true
    return function() subs[fn] = nil end
end

-- ==========================================================================
-- DB helpers (lazy-init the home table to survive defaults-not-retroactive)
-- ==========================================================================

local function dbHome()
    local db = ns.db and ns.db.profile
    if not db then return nil end
    db.home = db.home or {}
    db.home.guideHistory = db.home.guideHistory or {}
    db.home.gold         = db.home.gold or {
        dayKey = nil, weekKey = nil,
        todayDelta = 0, weekDelta = 0, lastSeen = 0,
    }
    db.home.favorites    = db.home.favorites or {}
    db.home.timePlayed   = db.home.timePlayed or {
        totalAtLogin = nil, sessionStartGameTime = nil,
    }
    return db.home
end

-- ==========================================================================
-- Date keys (day + week)
-- ==========================================================================

local function dayKey()
    return date("%Y-%m-%d")
end

local function weekKey()
    -- %U: Sunday-based week of year. Stable across platforms; good enough
    -- for "this week's gold" rollover. ISO 8601 (%V) isn't reliable on
    -- some Lua builds.
    return date("%Y-%U")
end

-- ==========================================================================
-- History
-- ==========================================================================

local function nowEpoch()
    return time()
end

function HomeData.PushHistoryEntry(questID, title, mapID)
    if type(questID) ~= "number" or questID <= 0 then return end
    local h = dbHome(); if not h then return end

    -- Dedupe: if the same questID is already at the front and not completed,
    -- don't double-push (the user re-/vellum-followed it).
    local first = h.guideHistory[1]
    if first and first.questID == questID and not first.completedAt then
        return
    end

    table.insert(h.guideHistory, 1, {
        questID     = questID,
        title       = title,
        followedAt  = nowEpoch(),
        completedAt = nil,
        mapID       = mapID,
    })

    -- Cap.
    while #h.guideHistory > HISTORY_CAP do
        table.remove(h.guideHistory)
    end

    notify()
end

function HomeData.MarkHistoryComplete(questID)
    local h = dbHome(); if not h then return end
    -- Find the most recent entry for this quest without a completion.
    for _, entry in ipairs(h.guideHistory) do
        if entry.questID == questID and not entry.completedAt then
            entry.completedAt = nowEpoch()
            notify()
            return
        end
    end
end

function HomeData.GetHistory(maxN)
    local h = dbHome(); if not h then return {} end
    local out = {}
    local cap = maxN or HISTORY_CAP
    for i = 1, math.min(cap, #h.guideHistory) do
        out[i] = h.guideHistory[i]
    end
    return out
end

-- ==========================================================================
-- Gold
-- ==========================================================================

local function ensureKeys(g)
    local d, w = dayKey(), weekKey()
    if g.dayKey  ~= d then g.dayKey,  g.todayDelta = d, 0 end
    if g.weekKey ~= w then g.weekKey, g.weekDelta  = w, 0 end
end

local function snapshotMoney()
    local h = dbHome(); if not h then return end
    h.gold.lastSeen = (GetMoney and GetMoney()) or 0
    ensureKeys(h.gold)
end

local function recordMoneyDelta()
    local h = dbHome(); if not h then return end
    local current = (GetMoney and GetMoney()) or 0
    ensureKeys(h.gold)
    local diff = current - (h.gold.lastSeen or current)
    h.gold.lastSeen   = current
    h.gold.todayDelta = (h.gold.todayDelta or 0) + diff
    h.gold.weekDelta  = (h.gold.weekDelta  or 0) + diff
    notify()
end

function HomeData.GetGold()
    local h = dbHome(); if not h then return { todayDelta = 0, weekDelta = 0 } end
    ensureKeys(h.gold)  -- in case the day rolled over since the last event
    return {
        todayDelta = h.gold.todayDelta or 0,
        weekDelta  = h.gold.weekDelta  or 0,
        dayKey     = h.gold.dayKey,
        weekKey    = h.gold.weekKey,
    }
end

-- ==========================================================================
-- Time played
-- ==========================================================================

function HomeData.GetTimePlayed()
    local h = dbHome(); if not h then return { hasData = false } end
    local tp = h.timePlayed
    local level = (UnitLevel and UnitLevel("player")) or 0

    if not (tp.totalAtLogin and tp.sessionStartGameTime) then
        return { level = level, hasData = false }
    end

    local sessionSec = (GetTime() - tp.sessionStartGameTime)
    local totalSec   = tp.totalAtLogin + sessionSec
    return {
        level      = level,
        sessionSec = sessionSec,
        totalSec   = totalSec,
        hasData    = true,
    }
end

-- ==========================================================================
-- Favorites
-- ==========================================================================

function HomeData.GetFavorites()
    local h = dbHome(); if not h then return {} end
    return h.favorites
end

function HomeData.IsFavorite(questID)
    local h = dbHome(); if not h then return false end
    return h.favorites[questID] == true
end

function HomeData.ToggleFavorite(questID)
    if type(questID) ~= "number" then return false end
    local h = dbHome(); if not h then return false end
    if h.favorites[questID] then
        h.favorites[questID] = nil
        notify()
        return false
    else
        h.favorites[questID] = true
        notify()
        return true
    end
end

-- ==========================================================================
-- Event wiring (skipped under Lupa where Cairn.Events is absent).
-- ==========================================================================

if Cairn and Cairn.Events then
    local owner = "Vellum.HomeData"

    -- Snapshot money on login so the first PLAYER_MONEY produces a real
    -- delta rather than counting the entire balance as today's earnings.
    Cairn.Events:Subscribe("PLAYER_LOGIN", function()
        snapshotMoney()
    end, owner)

    Cairn.Events:Subscribe("PLAYER_MONEY", function()
        recordMoneyDelta()
    end, owner)

    Cairn.Events:Subscribe("QUEST_TURNED_IN", function(questID)
        if type(questID) == "number" then
            HomeData.MarkHistoryComplete(questID)
        end
    end, owner)

    Cairn.Events:Subscribe("TIME_PLAYED_MSG",
        function(totalSec, _sessionSec)
            local h = dbHome(); if not h then return end
            h.timePlayed.totalAtLogin         = totalSec or 0
            h.timePlayed.sessionStartGameTime = GetTime()
            notify()
        end, owner)
end

-- Hook Follower changes to capture history. Files load in order
-- (Core -> Locator -> Follower -> Arrow -> HomeData -> HomeWindow -> ...)
-- so ns.Follower exists by the time we run.
do
    local lastSeenQID
    if ns.Follower and ns.Follower.OnChange then
        ns.Follower.OnChange(function(state)
            if state and state.questID and state.questID ~= lastSeenQID then
                lastSeenQID = state.questID
                HomeData.PushHistoryEntry(state.questID,
                    state.questTitle, state.mapID)
            elseif (not state or not state.questID) and lastSeenQID then
                lastSeenQID = nil
            end
        end)
    end
end
