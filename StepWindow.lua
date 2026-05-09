-- Vellum/StepWindow.lua
-- Phase 3C: the Step viewer renders the live RoutePlanner route.
--
-- Shape:
--   +-------------------------------------------+
--   |  Vellum Steps                       [X]   |
--   +-------------------------------------------+
--   |  Route: 8 waypoints, 1234 yd total        |   <- summary header
--   +-------------------------------------------+
--   |  > [PICKUP]   Wolves of the Wood          |
--   |    +120 yd from start                     |
--   |                                           |
--   |    [OBJECTIVE] Slain: 0/8                 |
--   |    +200 yd                                |
--   |                                           |
--   |    [TURNIN]   Wolves of the Wood          |
--   |    +95 yd                                 |
--   +-------------------------------------------+
--
-- Active row (route[1]) is bolded with a "> " prefix as a stand-in for the
-- red left-bar Phase 4 will paint. Click any row to log it (Phase 4 turns
-- this into "pin this waypoint as next").
--
-- Public API:
--   Vellum.StepWindow.Show()
--   Vellum.StepWindow.Hide()
--   Vellum.StepWindow.Toggle()
--   Vellum.StepWindow.IsShown()
--   Vellum.StepWindow.OpenForQuest(questID)   -- legacy: just opens

local ADDON, ns = ...
ns.StepWindow = ns.StepWindow or {}
local Step = ns.StepWindow

-- ==========================================================================
-- LibStub
-- ==========================================================================

local function gui()
    return LibStub and LibStub("Cairn-Gui-2.0", true)
end

-- ==========================================================================
-- Module state
-- ==========================================================================

local win
local content              -- Window content container (chrome target)
local summaryLabel         -- "Route: N waypoints, X yd total"
local bodyScroll
local body                 -- ScrollFrame content (where route rows go)
local rowWidgets = {}      -- tracked widgets for clearing on re-render

local LOGO_PATH = "Interface\\AddOns\\Vellum\\Logo"
local function logoTag(size)
    size = size or 20
    return string.format("|T%s:%d:%d|t", LOGO_PATH, size, size)
end

-- ==========================================================================
-- DB helpers
-- ==========================================================================

local function dbStep()
    local db = ns.db and ns.db.profile
    if not db then return nil end
    db.stepWindow = db.stepWindow or { x = 0, y = 0, tabs = {},
                                       activeTab = nil }
    return db.stepWindow
end

-- ==========================================================================
-- Helpers
-- ==========================================================================

local function trackedAcquire(widgetType, parent, opts, list)
    local g = gui()
    local w = g:Acquire(widgetType, parent, opts)
    if list then table.insert(list, w) end
    return w
end

local function clearList(list)
    if not list then return end
    for i = #list, 1, -1 do
        local w = list[i]
        if w and w.Cairn and w.Cairn.Release then
            w.Cairn:Release()
        end
    end
    wipe(list)
end

-- World-distance helper: same math as RoutePlanner uses.
local function worldPosOf(mapID, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then
        return nil, nil, nil
    end
    if not (mapID and x and y) then return nil, nil, nil end
    local cont, world = C_Map.GetWorldPosFromMapPos(mapID,
        CreateVector2D(x, y))
    if not (cont and world) then return nil, nil, nil end
    return cont, world.x, world.y
end

local function distanceBetween(a, b)
    if not (a and b and a.mapID and b.mapID) then return 0 end
    local c1, x1, y1 = worldPosOf(a.mapID, a.x, a.y)
    local c2, x2, y2 = worldPosOf(b.mapID, b.x, b.y)
    if not (c1 and c2 and c1 == c2) then return 0 end
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

local function distanceFromPlayer(wp)
    if not wp then return 0 end
    local mid = C_Map and C_Map.GetBestMapForUnit
        and C_Map.GetBestMapForUnit("player")
    if not mid then return 0 end
    local pos = C_Map.GetPlayerMapPosition(mid, "player")
    if not pos then return 0 end
    return distanceBetween(
        { mapID = mid,    x = pos.x, y = pos.y },
        { mapID = wp.mapID, x = wp.x,  y = wp.y }
    )
end

-- ==========================================================================
-- Render the route
-- ==========================================================================

local function renderRoute()
    if not body then return end
    clearList(rowWidgets)

    local route = (ns.RoutePlanner and ns.RoutePlanner.GetRoute()) or {}
    local total = (ns.RoutePlanner and ns.RoutePlanner.GetRouteLength
        and ns.RoutePlanner.GetRouteLength()) or 0

    -- Header summary.
    if summaryLabel then
        if #route == 0 then
            summaryLabel.Cairn:SetText("No waypoints. Try moving to a "
                .. "quest hub or accept a quest.")
        else
            summaryLabel.Cairn:SetText(string.format(
                "Route: %d waypoint%s, %.0f yd total",
                #route, #route == 1 and "" or "s", total))
        end
    end

    if #route == 0 then return end

    body.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 6 })

    local prevWP = nil
    for i, wp in ipairs(route) do
        local isActive = (i == 1)
        local row = trackedAcquire("Container", body,
            { width = 400, height = 56 }, rowWidgets)
        row.Cairn:SetLayout("Stack",
            { direction = "vertical", gap = 2, padding = 4 })

        -- Heading: prefix + [TYPE] + title.
        local prefix = isActive and "> " or "  "
        local title  = wp.title or ("Quest " .. tostring(wp.questID))
        local headText = string.format("%s[%s] %s", prefix, wp.type, title)
        trackedAcquire("Label", row, {
            text    = headText,
            variant = isActive and "heading" or "body",
            align   = "left",
            wrap    = false,
        }, rowWidgets)

        -- Sub-line: objective text (if OBJECTIVE) or context.
        local sub = nil
        if wp.type == "OBJECTIVE" and wp.objText and wp.objText ~= "" then
            sub = "    " .. wp.objText
        elseif wp.label and wp.label ~= title then
            sub = "    " .. wp.label
        end
        if sub then
            trackedAcquire("Label", row, {
                text    = sub,
                variant = "body",
                align   = "left",
                wrap    = true,
            }, rowWidgets)
        end

        -- Distance.
        local dist
        if i == 1 then
            dist = distanceFromPlayer(wp)
            trackedAcquire("Label", row, {
                text    = string.format("    %.0f yd from you   src=%s",
                    dist, tostring(wp.source or "?")),
                variant = "muted",
                align   = "left",
                wrap    = false,
            }, rowWidgets)
        elseif prevWP then
            dist = distanceBetween(prevWP, wp)
            trackedAcquire("Label", row, {
                text    = string.format("    +%.0f yd   src=%s",
                    dist, tostring(wp.source or "?")),
                variant = "muted",
                align   = "left",
                wrap    = false,
            }, rowWidgets)
        end

        prevWP = wp
    end
end

-- ==========================================================================
-- Build: full window
-- ==========================================================================

local function build()
    if win then return end
    local g = gui()
    if not g then return end

    win = g:Acquire("Window", UIParent, {
        title    = logoTag(20) .. "  Vellum Steps",
        width    = 460,
        height   = 540,
        closable = true,
        movable  = true,
    })

    do
        local s = dbStep() or { x = 0, y = 0 }
        win:ClearAllPoints()
        win:SetPoint("CENTER", UIParent, "CENTER",
            (s.x ~= 0 and s.x) or 240,
            s.y or 0)
    end

    win.Cairn:On("Moved", function(_, x, y)
        local s = dbStep()
        if s then s.x, s.y = x or 0, y or 0 end
    end)

    win.Cairn:On("Close", function() Step.Hide() end)

    content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 8 })

    -- Summary header.
    summaryLabel = g:Acquire("Label", content, {
        text    = "Route loading...",
        variant = "heading",
        align   = "left",
        wrap    = true,
    })

    -- Scrollable body for the route entries.
    bodyScroll = g:Acquire("ScrollFrame", content, {
        width = 440, height = 460,
    })
    body = bodyScroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 6 })

    renderRoute()
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Step.Show()
    build()
    if win then
        win:Show()
        renderRoute()  -- refresh on open in case route changed while hidden
    end
end

function Step.Hide()
    if win then win:Hide() end
end

function Step.IsShown()
    return (win and win:IsShown()) or false
end

function Step.Toggle()
    if Step.IsShown() then Step.Hide() else Step.Show() end
end

-- Legacy: just opens the viewer. The route already includes that questID
-- as a candidate if it's pickable / in log. (Future "pin" feature will
-- force this questID as the head of the route.)
function Step.OpenForQuest(questID)
    Step.Show()
end

-- ==========================================================================
-- Auto-refresh on route change
-- ==========================================================================

if ns.RoutePlanner and ns.RoutePlanner.OnRouteChanged then
    ns.RoutePlanner.OnRouteChanged(function()
        if win and win:IsShown() then renderRoute() end
    end)
end
