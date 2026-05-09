-- Vellum/RoutePlanner.lua
-- The route planner: surveys candidate quests, builds a waypoint list via
-- Waypoint.For, solves a constrained TSP, exposes the ordered route.
--
-- Architecture overview:
--
--   1. Candidate enumeration -- walks C_QuestLog (in-log quests) and
--      LibCodex Quests (catalog quests), filters by faction / level /
--      completed-flag and the configured spatial constraint:
--        radius mode        -> same mapID + within db.engine.radius yards
--        completionist mode -> same mapID, no distance filter
--      Caps at db.engine.maxWaypoints.
--
--   2. Waypoint generation -- runs Waypoint.For on each candidate questID;
--      drops nil results (DONE / ABANDONED / UNKNOWN) and waypoints with
--      no usable coords (Waypoint.IsActionable == false).
--
--   3. Distance matrix -- precomputes O(N^2) game-world distances between
--      player and every waypoint via C_Map.GetWorldPosFromMapPos. Symmetric.
--      Cross-continent waypoints get distance = math.huge.
--
--   4. Nearest-neighbor seed -- builds an initial tour starting from the
--      player position, repeatedly picking the closest unvisited waypoint.
--
--   5. 2-opt improvement -- for every (i, j) pair in the tour, try
--      reversing the [i..j] segment; keep the swap if total length drops.
--      Loops until no improvement found.
--
--   6. Signature comparison -- compares (questID|type) string of new vs
--      previous route; fires OnRouteChanged subscribers only if changed.
--
--   7. Debounce -- recalc triggers (QUEST_LOG_UPDATE, etc.) call
--      scheduleRecalc which uses C_Timer.NewTimer to coalesce bursts into
--      a single Recompute after db.engine.debounceMs of silence.
--
-- Public API:
--   Vellum.RoutePlanner.GetRoute()           -> array of waypoints (in order)
--   Vellum.RoutePlanner.GetCandidates()      -> array of questIDs (debug)
--   Vellum.RoutePlanner.Recompute()          -> force recalc; returns route
--   Vellum.RoutePlanner.GetMode()            -> "radius" | "completionist"
--   Vellum.RoutePlanner.SetMode(m)           -> set mode + recalc
--   Vellum.RoutePlanner.GetRadius()          -> yards (number)
--   Vellum.RoutePlanner.SetRadius(r)         -> set radius + recalc
--   Vellum.RoutePlanner.OnRouteChanged(fn)   -> subscribe; returns
--                                                unsubscribe-closure

local ADDON, ns = ...
ns.RoutePlanner = ns.RoutePlanner or {}
local RP = ns.RoutePlanner

-- ==========================================================================
-- LibStub
-- ==========================================================================

local function libCodex()
    return LibStub and LibStub("LibCodex-1.0", true)
end

-- ==========================================================================
-- Settings (lazy-init from db.profile.engine)
-- ==========================================================================

local function settings()
    local db = ns.db and ns.db.profile
    if not db then
        return { mode = "radius", radius = 1500,
                 maxWaypoints = 50, debounceMs = 250 }
    end
    db.engine = db.engine or {}
    db.engine.mode         = db.engine.mode         or "radius"
    db.engine.radius       = db.engine.radius       or 1500
    db.engine.maxWaypoints = db.engine.maxWaypoints or 50
    db.engine.debounceMs   = db.engine.debounceMs   or 250
    return db.engine
end

function RP.GetMode()        return settings().mode end
function RP.GetRadius()      return settings().radius end
function RP.GetMaxWaypoints() return settings().maxWaypoints end

function RP.SetMode(mode)
    if mode ~= "radius" and mode ~= "completionist" then return false end
    settings().mode = mode
    RP.Recompute()
    return true
end

function RP.SetRadius(r)
    r = tonumber(r)
    if not r or r <= 0 then return false end
    settings().radius = r
    RP.Recompute()
    return true
end

-- ==========================================================================
-- World-coords helpers
-- ==========================================================================

local function worldPosOf(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then
        return nil, nil, nil
    end
    if not (mapID and x and y) then return nil, nil, nil end
    local cont, world = C_Map.GetWorldPosFromMapPos(mapID, CreateVector2D(x, y))
    if not (cont and world) then return nil, nil, nil end
    return cont, world.x, world.y
end

local function playerWorld()
    if not (C_Map and C_Map.GetBestMapForUnit
            and C_Map.GetPlayerMapPosition) then
        return nil
    end
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local cont, wx, wy = worldPosOf(mapID, pos.x, pos.y)
    if not cont then return nil end
    return { mapID = mapID, x = pos.x, y = pos.y,
             cont = cont, wx = wx, wy = wy }
end

local function worldDistance(p1, p2)
    -- p1 / p2 = { cont, wx, wy } (world-space). Cross-continent = inf.
    if not (p1 and p2) then return math.huge end
    if p1.cont ~= p2.cont then return math.huge end
    local dx = p2.wx - p1.wx
    local dy = p2.wy - p1.wy
    return math.sqrt(dx * dx + dy * dy)
end

-- ==========================================================================
-- Candidate enumerator
-- ==========================================================================

local function factionLetter()
    local f = UnitFactionGroup and select(1, UnitFactionGroup("player")) or nil
    if f == "Alliance" then return "A" end
    if f == "Horde"    then return "H" end
    return nil
end

local function sideOk(q, sideLetter)
    return (not q.side) or q.side == "B" or q.side == sideLetter
end

local function levelOk(q, plvl)
    if not q.level or q.level == 0 then return true end
    return math.abs(q.level - plvl) <= 5
end

-- Walk the player's quest log; return a set of in-log questIDs.
local function inLogQuestIDs()
    local out = {}
    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries
            and C_QuestLog.GetInfo) then
        return out
    end
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID then
            out[info.questID] = true
        end
    end
    return out
end

-- Extract a (mapID, x, y) "giver" hint from a LibCodex Quests entry.
-- Bundled rows store coords in q.locations as records with `point` set to
-- "start" / "end" / "requirement" etc. Runtime-added entries (via
-- AddFromAPI) have flat q.mapID/q.x/q.y. Returns nil if no giver location.
local function giverFromCatalog(q, preferMapID)
    if not q then return nil end
    if q.mapID and q.x and q.y then
        return q.mapID, q.x, q.y
    end
    if type(q.locations) ~= "table" then return nil end
    -- First pass: prefer player's current map.
    if preferMapID then
        for _, loc in ipairs(q.locations) do
            if loc.point == "start" and loc.mapID == preferMapID
               and loc.x and loc.y then
                return loc.mapID, loc.x, loc.y
            end
        end
    end
    -- Second pass: any "start" point.
    for _, loc in ipairs(q.locations) do
        if loc.point == "start" and loc.mapID and loc.x and loc.y then
            return loc.mapID, loc.x, loc.y
        end
    end
    return nil
end

-- Returns array of questIDs that should be candidates this recalc.
function RP.GatherCandidates()
    local out  = {}
    local seen = {}
    local cap  = settings().maxWaypoints
    local mode = settings().mode
    local rad  = settings().radius

    local pPos = playerWorld()

    -- 1. All in-log quests are always candidates (we always have something
    --    to say about them: do current objective, or turn in).
    for qid in pairs(inLogQuestIDs()) do
        if #out >= cap then break end
        seen[qid] = true
        out[#out + 1] = qid
    end

    -- 2. Catalog quests not in log, faction-/level-/spatial-eligible.
    local lc  = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    if not (mod and mod.AllRaw) then return out end

    local sideLetter = factionLetter()
    local plvl       = (UnitLevel and UnitLevel("player")) or 1

    for qid, q in pairs(mod:AllRaw()) do
        if #out >= cap then break end
        if not seen[qid]
           and not (C_QuestLog.IsQuestFlaggedCompleted
                    and C_QuestLog.IsQuestFlaggedCompleted(qid))
           and sideOk(q, sideLetter)
           and levelOk(q, plvl) then

            -- Pull giver coords from either flat fields or locations list.
            local qMapID, qX, qY = giverFromCatalog(q, pPos and pPos.mapID)
            if qMapID and qX and qY then
                -- Spatial filter.
                local include = false
                if pPos and qMapID == pPos.mapID then
                    if mode == "completionist" then
                        include = true
                    else
                        -- Radius: world-distance <= configured radius.
                        local cont, qwx, qwy = worldPosOf(qMapID, qX, qY)
                        if cont == pPos.cont then
                            local dx = qwx - pPos.wx
                            local dy = qwy - pPos.wy
                            local d  = math.sqrt(dx * dx + dy * dy)
                            if d <= rad then include = true end
                        end
                    end
                end

                if include then
                    seen[qid] = true
                    out[#out + 1] = qid
                end
            end
        end
    end

    return out
end

-- ==========================================================================
-- TSP solver (nearest-neighbor + 2-opt, with cached world coords)
-- ==========================================================================

-- Augment a waypoint with cached world coords. Mutates the waypoint table.
local function attachWorld(wp)
    if wp._cont then return end
    local cont, wx, wy = worldPosOf(wp.mapID, wp.x, wp.y)
    wp._cont, wp._wx, wp._wy = cont, wx, wy
end

local function distWP(a, b)
    if not (a and b and a._cont and b._cont) then return math.huge end
    if a._cont ~= b._cont then return math.huge end
    local dx = b._wx - a._wx
    local dy = b._wy - a._wy
    return math.sqrt(dx * dx + dy * dy)
end

local function distPlayerWP(p, wp)
    if not (p and wp and p.cont and wp._cont) then return math.huge end
    if p.cont ~= wp._cont then return math.huge end
    local dx = wp._wx - p.wx
    local dy = wp._wy - p.wy
    return math.sqrt(dx * dx + dy * dy)
end

local function nearestNeighbor(playerPos, waypoints)
    local route = {}
    local pool  = {}
    for i, wp in ipairs(waypoints) do pool[i] = wp end

    -- Start from player.
    local prev = playerPos
    while #pool > 0 do
        local bestIdx, bestDist = nil, math.huge
        for i, wp in ipairs(pool) do
            local d
            if prev == playerPos then
                d = distPlayerWP(prev, wp)
            else
                d = distWP(prev, wp)
            end
            -- Use <= instead of < so a math.huge tie still picks SOMETHING.
            -- Without this, every-waypoint-cross-continent (or every-waypoint
            -- world-pos-failed) returns nil bestIdx and the route comes out
            -- empty. The user then sees "no arrow" even though valid
            -- in-log waypoints exist -- they just can't be ranked by distance.
            if d <= bestDist then bestIdx, bestDist = i, d end
        end
        if not bestIdx then break end
        local picked = pool[bestIdx]
        table.remove(pool, bestIdx)
        route[#route + 1] = picked
        prev = picked
    end
    return route
end

local function tourLength(playerPos, route)
    if #route == 0 then return 0 end
    -- Sum only FINITE segment distances. math.huge segments (cross-continent
    -- or world-pos-unresolvable) are excluded so the returned total stays
    -- finite. Consumers don't have to worry about formatting inf -- though
    -- defense-in-depth, callers should still use %.0f instead of %d.
    local function safe(d)
        if d == math.huge or d ~= d --[[NaN]] then return 0 end
        return d
    end
    local total = safe(distPlayerWP(playerPos, route[1]))
    for i = 2, #route do
        total = total + safe(distWP(route[i - 1], route[i]))
    end
    return total
end

local function twoOptImprove(playerPos, route)
    local n = #route
    if n < 4 then return route end

    local improved = true
    local pass = 0
    while improved and pass < 8 do  -- hard cap on passes (safety)
        improved = false
        pass = pass + 1
        for i = 1, n - 1 do
            for j = i + 1, n do
                -- Build the swap: reverse route[i..j].
                local newRoute = {}
                for k = 1, i - 1 do newRoute[k] = route[k] end
                for k = j, i, -1 do newRoute[#newRoute + 1] = route[k] end
                for k = j + 1, n do newRoute[#newRoute + 1] = route[k] end

                if tourLength(playerPos, newRoute)
                   < tourLength(playerPos, route) then
                    route = newRoute
                    improved = true
                end
            end
        end
    end
    return route
end

-- ==========================================================================
-- Recompute pipeline + change detection
-- ==========================================================================

local currentRoute  = {}
local currentLength = 0
local lastSig       = ""
local subs          = {}

local function notifyChanged()
    for fn in pairs(subs) do
        local ok, err = pcall(fn, currentRoute)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

local function routeSig(route)
    local parts = {}
    for i, wp in ipairs(route) do
        -- Include objText so kill-counter progress (e.g. "Wolves slain:
        -- 3/8" -> "4/8") propagates as a route change. Without this,
        -- objective text updates within the same objective don't fire
        -- OnRouteChanged and the StepWindow doesn't refresh.
        parts[i] = string.format("%s|%d|%s|%s|%s",
            wp.type, wp.questID,
            tostring(wp.objIdx or ""),
            wp.source or "",
            wp.objText or "")
    end
    return table.concat(parts, ";")
end

function RP.Recompute()
    -- 1. candidates
    local qids = RP.GatherCandidates()

    -- 2. waypoints (drop nils + non-actionable)
    local waypoints = {}
    if ns.Waypoint and ns.Waypoint.For then
        for _, qid in ipairs(qids) do
            local wp = ns.Waypoint.For(qid)
            if wp and ns.Waypoint.IsActionable(wp) then
                attachWorld(wp)
                waypoints[#waypoints + 1] = wp
            end
        end
    end

    -- 3. Pull out the pinned quest's waypoint BEFORE solving. The pinned
    -- waypoint is always route[1] regardless of what NN/2-opt produces -- so
    -- the solver can't accidentally drop it when world-distance is
    -- math.huge (cross-continent / cross-mapID without GetWorldPosFromMapPos
    -- coverage). This is the fix for "I pinned 28794 but waypoints=0 in the
    -- route" bug seen in VellumDebug 2026-05-08.
    local pinnedQID = RP.GetPinned()
    local pinnedWP  = nil
    if pinnedQID then
        for i, wp in ipairs(waypoints) do
            if wp.questID == pinnedQID then
                pinnedWP = wp
                table.remove(waypoints, i)
                break
            end
        end
    end

    -- 4. Solve over the remaining waypoints.
    local pPos = playerWorld()
    local route
    if pPos and #waypoints > 0 then
        route = nearestNeighbor(pPos, waypoints)
        route = twoOptImprove(pPos, route)
    else
        route = waypoints  -- no player pos? hand back unsorted
    end

    -- 5. Prepend pinned waypoint to position 1.
    if pinnedWP then
        table.insert(route, 1, pinnedWP)
    end

    -- 6. signature change?
    currentRoute  = route
    currentLength = pPos and tourLength(pPos, route) or 0
    local sig = routeSig(route)
    if sig ~= lastSig then
        lastSig = sig
        notifyChanged()
    end

    return route
end

function RP.GetRoute()       return currentRoute end
function RP.GetRouteLength() return currentLength end
function RP.GetCandidates()  return RP.GatherCandidates() end

function RP.OnRouteChanged(fn)
    if type(fn) ~= "function" then
        error("Vellum.RoutePlanner.OnRouteChanged: fn must be a function", 2)
    end
    subs[fn] = true
    return function() subs[fn] = nil end
end

-- ==========================================================================
-- Pinning
-- ==========================================================================
-- A "pinned" quest forces its waypoint to position 1 in the route,
-- regardless of distance. Used by:
--   - Auto-pin on QUEST_ACCEPTED (newest accepted quest takes priority)
--   - Manual /vellum follow X (user explicitly says "do this one next")
-- Pin clears automatically on QUEST_TURNED_IN or QUEST_REMOVED for the
-- pinned questID. Persists across /reload via db.profile.engine.pinned.

function RP.GetPinned()
    local s = settings()
    return s.pinned
end

function RP.Pin(questID)
    if type(questID) ~= "number" or questID <= 0 then return false end
    settings().pinned = questID
    RP.Recompute()
    return true
end

function RP.Unpin()
    if settings().pinned == nil then return false end
    settings().pinned = nil
    RP.Recompute()
    return true
end

-- ==========================================================================
-- Recalc bus (debounced)
-- ==========================================================================

local pendingTimer = nil

local function scheduleRecalc()
    if pendingTimer and pendingTimer.Cancel then
        pendingTimer:Cancel()
    end
    local ms = settings().debounceMs or 250
    pendingTimer = C_Timer.NewTimer(ms / 1000, function()
        pendingTimer = nil
        RP.Recompute()
    end)
end

if Cairn and Cairn.Events then
    local owner = "Vellum.RoutePlanner"

    -- Auto-pin: a newly accepted quest takes priority. This addresses the
    -- "I accepted Q and the arrow stayed pointing at the previously-closest
    -- waypoint" frustration. The pin replaces any prior pin.
    Cairn.Events:Subscribe("QUEST_ACCEPTED", function(qid)
        if type(qid) == "number" and qid > 0 then
            settings().pinned = qid  -- write directly; Recompute below
        end
        scheduleRecalc()
    end, owner)

    -- Auto-unpin: if the pinned quest is gone (turned in or abandoned),
    -- drop the pin so the planner picks the next-best waypoint by distance.
    local function clearPinIfMatches(qid)
        local s = settings()
        if type(qid) == "number" and s.pinned == qid then
            s.pinned = nil
        end
    end
    Cairn.Events:Subscribe("QUEST_TURNED_IN", function(qid)
        clearPinIfMatches(qid)
        scheduleRecalc()
    end, owner)
    Cairn.Events:Subscribe("QUEST_REMOVED", function(qid)
        clearPinIfMatches(qid)
        scheduleRecalc()
    end, owner)

    Cairn.Events:Subscribe("QUEST_LOG_UPDATE",       scheduleRecalc, owner)
    Cairn.Events:Subscribe("UNIT_QUEST_LOG_CHANGED", function(unit)
        if unit == "player" then scheduleRecalc() end
    end, owner)
    Cairn.Events:Subscribe("ZONE_CHANGED_NEW_AREA",  scheduleRecalc, owner)
    Cairn.Events:Subscribe("PLAYER_LEVEL_UP",        scheduleRecalc, owner)
    Cairn.Events:Subscribe("PLAYER_ENTERING_WORLD",  scheduleRecalc, owner)
end
