-- Vellum/HomeWindow.lua
-- The Vellum "Home launcher" window in the Zygor shape.
--
-- Shape:
--   +--------------------------------------------------------+
--   |  Vellum                                          [X]   |
--   +--------------------------------------------------------+
--   |  Home   Active   Recent                                |
--   +-------------+------------------------------------------+
--   | [search   ] |  (main pane swaps based on sidebar)      |
--   | Dashboard   |                                          |
--   | Leveling    |  Default (Dashboard): 2x2 tiles          |
--   | Zone        |  Otherwise: that category's quest list   |
--   | Dailies     |                                          |
--   | Search      |                                          |
--   | Favorites   |                                          |
--   |             |                                          |
--   | [Options]   |                                          |
--   +-------------+------------------------------------------+
--
-- Phase 2 (this file):
--   - Sidebar categories actually swap the main pane.
--   - Sidebar search box filters the active category list.
--   - Four dashboard tiles read live data from Vellum.HomeData
--     (Guides History, Suggested Guides, Level Tracker, Gold Tracker).
--   - Active top tab lists the currently-followed quest.
--   - Recent top tab lists full guide history.
--   - Click any quest row -> Follower:Set + StepWindow.OpenForQuest.
--
-- Phase 3 will rewrite "currently followed" to N-quest, change Active to
-- list ALL followed, and make StepWindow build per-followed-quest tabs.
--
-- Public API:
--   Vellum.HomeWindow.Show()
--   Vellum.HomeWindow.Hide()
--   Vellum.HomeWindow.Toggle()
--   Vellum.HomeWindow.IsShown()

local ADDON, ns = ...
ns.HomeWindow = ns.HomeWindow or {}
local Home = ns.HomeWindow

-- ==========================================================================
-- LibStub access
-- ==========================================================================

local function gui()
    return LibStub and LibStub("Cairn-Gui-2.0", true)
end

local function libCodex()
    return LibStub and LibStub("LibCodex-1.0", true)
end

-- ==========================================================================
-- Module state
-- ==========================================================================

local win
local topTabs
local tabBuilt = { home = false }   -- chrome built once; renders re-fire
local sidebarState = { selected = "dashboard", needle = "" }

-- Chrome refs (built once in buildHomeTab).
local sidebar, mainScroll, mainPane
local searchEditBox

-- Dynamic-widget tracking lists per render scope.
local mainWidgets   = {}
local activeWidgets = {}
local recentWidgets = {}

local LOGO_PATH = "Interface\\AddOns\\Vellum\\Logo"
local function logoTag(size)
    size = size or 22
    return string.format("|T%s:%d:%d|t", LOGO_PATH, size, size)
end

-- ==========================================================================
-- DB helpers
-- ==========================================================================

local function dbHome()
    local db = ns.db and ns.db.profile
    if not db then return nil end
    db.home = db.home or { x = 0, y = 0, selectedTab = "home",
                           sidebarSelected = "dashboard" }
    return db.home
end

-- ==========================================================================
-- Formatters
-- ==========================================================================

local function formatGold(copperSigned)
    -- WoW money is integer copper. Format as "1g 23s 45c" with sign.
    local sign = copperSigned < 0 and "-" or ""
    local c = math.abs(copperSigned or 0)
    local g = math.floor(c / 10000)
    local s = math.floor((c % 10000) / 100)
    local cu = c % 100
    if g > 0 then
        return string.format("%s%dg %ds %dc", sign, g, s, cu)
    elseif s > 0 then
        return string.format("%s%ds %dc", sign, s, cu)
    else
        return string.format("%s%dc", sign, cu)
    end
end

local function formatPlayedTime(secs)
    secs = math.floor(secs or 0)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %dm", h, m) end
    return string.format("%dm", m)
end

local function formatRelativeTime(epoch)
    if not epoch then return "" end
    local diff = time() - epoch
    if diff < 60          then return "just now" end
    if diff < 3600        then return string.format("%dm ago", math.floor(diff/60)) end
    if diff < 86400       then return string.format("%dh ago", math.floor(diff/3600)) end
    if diff < 7 * 86400   then return string.format("%dd ago", math.floor(diff/86400)) end
    return date("%Y-%m-%d", epoch)
end

-- ==========================================================================
-- Click action: follow + open StepWindow
-- ==========================================================================

local function followAndOpen(qid)
    if type(qid) ~= "number" or qid <= 0 then return end
    if ns.Follower and ns.Follower.Set then ns.Follower.Set(qid) end
    if ns.StepWindow and ns.StepWindow.OpenForQuest then
        ns.StepWindow.OpenForQuest(qid)
    end
end

-- ==========================================================================
-- Widget-list helpers
-- ==========================================================================

local function trackedAcquire(widgetType, parent, opts, list)
    local g = gui()
    local w = g:Acquire(widgetType, parent, opts)
    if list then table.insert(list, w) end
    return w
end

local function clearList(list)
    if not list then return end
    -- Release in reverse so children-first (latest-added are typically
    -- inside the earlier-added Containers).
    for i = #list, 1, -1 do
        local w = list[i]
        if w and w.Cairn and w.Cairn.Release then
            w.Cairn:Release()
        end
    end
    wipe(list)
end

-- ==========================================================================
-- Quest row builder (used by every quest-list renderer)
-- ==========================================================================

local function questRow(parent, qid, level, label, list, opts)
    opts = opts or {}
    local label_text = string.format("Lvl %s  %s", tostring(level or "-"),
        label or ("Quest " .. tostring(qid)))
    if opts.suffix then label_text = label_text .. "  " .. opts.suffix end

    local row = trackedAcquire("Button", parent, {
        text    = label_text,
        variant = "ghost",
        width   = opts.width or 460,
    }, list)
    row.Cairn:On("Click", function() followAndOpen(qid) end)
    return row
end

-- ==========================================================================
-- Tile (dashboard composite) builder
-- ==========================================================================

local TILE_W, TILE_H = 240, 168

local function buildTile(parent, title, bodyLines, footerLabel, footerFn,
                        list)
    local g = gui()
    local tile = trackedAcquire("Container", parent, {
        width  = TILE_W,
        height = TILE_H,
    }, list)
    tile.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })

    -- Heading.
    g:Acquire("Label", tile, {
        text    = title,
        variant = "heading",
        align   = "left",
        wrap    = false,
    })

    -- Body lines (each line = one Label).
    if type(bodyLines) == "string" then bodyLines = { bodyLines } end
    for _, line in ipairs(bodyLines or {}) do
        g:Acquire("Label", tile, {
            text    = line,
            variant = "body",
            align   = "left",
            wrap    = true,
        })
    end

    -- Footer link.
    if footerLabel then
        local more = g:Acquire("Button", tile, {
            text    = footerLabel,
            variant = "ghost",
            width   = 100,
        })
        if footerFn then more.Cairn:On("Click", footerFn) end
    end

    return tile
end

-- ==========================================================================
-- Filter helper (sidebar search needle applied to a quest entry)
-- ==========================================================================

local function matchesNeedle(qid, label)
    local needle = (sidebarState.needle or ""):lower()
    if needle == "" then return true end
    if tostring(qid):find(needle, 1, true) then return true end
    if label and label:lower():find(needle, 1, true) then return true end
    return false
end

-- ==========================================================================
-- Main-pane renderers
-- ==========================================================================

local function setSidebarCategory(id)
    sidebarState.selected = id
    local h = dbHome()
    if h then h.sidebarSelected = id end
    Home._renderMain()
end

-- ----- Dashboard ----------------------------------------------------------

local function renderDashboard(parent)
    local g = gui()
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 8, padding = 6 })

    -- Row 1: Guides History | Suggested Guides
    local row1 = trackedAcquire("Container", parent, {
        width = TILE_W * 2 + 8, height = TILE_H,
    }, mainWidgets)
    row1.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 8, padding = 0 })

    -- Guides History tile body.
    local hist = (ns.HomeData and ns.HomeData.GetHistory(3)) or {}
    local histLines = {}
    if #hist == 0 then
        histLines[1] = "No followed guides yet. Click a quest to start."
    else
        for _, e in ipairs(hist) do
            local title = e.title or ("Quest " .. tostring(e.questID))
            local rel   = formatRelativeTime(e.followedAt)
            local mark  = e.completedAt and " (done)" or ""
            histLines[#histLines + 1] =
                string.format("%s  -  %s%s", title, rel, mark)
        end
    end
    buildTile(row1, "Guides History", histLines, "See more  >",
        function()
            -- Route to the Recent top tab (full history list).
            if topTabs and topTabs.Cairn.SetSelected then
                topTabs.Cairn:SetSelected("recent")
            end
        end, mainWidgets)

    -- Suggested Guides tile body (LibCodex Quests filtered to current map +
    -- faction + level range).
    local suggLines = {}
    local lc = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    local mapID = C_Map and C_Map.GetBestMapForUnit
        and C_Map.GetBestMapForUnit("player")
    if not (mod and mod.AllRaw) then
        suggLines[1] = "LibCodex Quests not loaded."
    elseif not mapID then
        suggLines[1] = "No current zone."
    else
        local side       = UnitFactionGroup and select(1, UnitFactionGroup("player")) or nil
        local sideLetter = side == "Alliance" and "A" or side == "Horde" and "H" or nil
        local plvl       = (UnitLevel and UnitLevel("player")) or 1
        local pickedLines, count = {}, 0
        for qid, q in pairs(mod:AllRaw()) do
            if count >= 3 then break end
            if q.mapID == mapID then
                local sideOk = (not q.side) or q.side == "B" or q.side == sideLetter
                local lvl    = q.level or 0
                local lvlOk  = (lvl == 0) or (math.abs(lvl - plvl) <= 5)
                if sideOk and lvlOk then
                    count = count + 1
                    pickedLines[#pickedLines + 1] = string.format(
                        "Lvl %d  %s", lvl, q.label or ("Quest " .. qid))
                end
            end
        end
        if count == 0 then
            suggLines[1] = "Nothing nearby in your level range."
        else
            for i, line in ipairs(pickedLines) do suggLines[i] = line end
        end
    end
    buildTile(row1, "Suggested Guides", suggLines, "See more  >",
        function() setSidebarCategory("zone") end, mainWidgets)

    -- Row 2: Level Tracker | Gold Tracker
    local row2 = trackedAcquire("Container", parent, {
        width = TILE_W * 2 + 8, height = TILE_H,
    }, mainWidgets)
    row2.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 8, padding = 0 })

    local tp = (ns.HomeData and ns.HomeData.GetTimePlayed())
            or { level = 0, hasData = false }
    local lvlLines = { string.format("Level %d", tp.level or 0) }
    if tp.hasData then
        lvlLines[2] = string.format("This session: %s",
            formatPlayedTime(tp.sessionSec))
        lvlLines[3] = string.format("Total: %s",
            formatPlayedTime(tp.totalSec))
    else
        lvlLines[2] = "Time-played not yet captured."
    end
    buildTile(row2, "Level Tracker", lvlLines, nil, nil, mainWidgets)

    local gd = (ns.HomeData and ns.HomeData.GetGold())
            or { todayDelta = 0, weekDelta = 0 }
    local goldLines = {
        string.format("Today: %s", formatGold(gd.todayDelta or 0)),
        string.format("Week:  %s", formatGold(gd.weekDelta  or 0)),
    }
    buildTile(row2, "Gold Tracker", goldLines, nil, nil, mainWidgets)
end

-- ----- Quest list renderers (Leveling / Zone / Dailies / Favorites) -------

local function renderHeading(parent, title, sub)
    -- IMPORTANT: track these Labels in mainWidgets so clearList(mainWidgets)
    -- releases them on the next render. Previously these were untracked,
    -- which caused headings to stack up every time the sidebar swapped
    -- (Leveling -> Zone -> Dailies left visible "Leveling guides" + "Zone
    -- quests" + "Dailies" headings all on top of each other).
    trackedAcquire("Label", parent, {
        text    = title,
        variant = "heading",
        align   = "left",
        wrap    = false,
    }, mainWidgets)
    if sub then
        trackedAcquire("Label", parent, {
            text    = sub,
            variant = "muted",
            align   = "left",
            wrap    = true,
        }, mainWidgets)
    end
end

local function withScrollBody(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })

    -- The renderHeading is added to parent BEFORE this is called; trust caller.
    local scroll = trackedAcquire("ScrollFrame", parent, {
        width = 480, height = 340,
    }, mainWidgets)
    local body = scroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 0 })
    return body
end

local function renderLeveling(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })
    renderHeading(parent, "Leveling guides",
        "LibCodex quests for your faction within +/- 5 of your level.")
    local body = withScrollBody(parent)

    local lc = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    if not (mod and mod.AllRaw) then
        trackedAcquire("Label", body, {
            text = "LibCodex Quests module not available.",
            variant = "muted",
        }, mainWidgets)
        return
    end

    local side       = UnitFactionGroup and select(1, UnitFactionGroup("player")) or nil
    local sideLetter = side == "Alliance" and "A" or side == "Horde" and "H" or nil
    local plvl       = (UnitLevel and UnitLevel("player")) or 1
    local rendered, total = 0, 0
    local cap = 200

    for qid, q in pairs(mod:AllRaw()) do
        local sideOk = (not q.side) or q.side == "B" or q.side == sideLetter
        local lvl    = q.level or 0
        local lvlOk  = (lvl > 0) and (math.abs(lvl - plvl) <= 5)
        if sideOk and lvlOk and matchesNeedle(qid, q.label) then
            total = total + 1
            if rendered < cap then
                rendered = rendered + 1
                questRow(body, qid, lvl, q.label, mainWidgets, { width = 460 })
            end
        end
    end

    if total == 0 then
        trackedAcquire("Label", body, {
            text = "No leveling-range quests in the catalog match.",
            variant = "muted",
        }, mainWidgets)
    elseif total > rendered then
        trackedAcquire("Label", body, {
            text    = string.format("(showing %d of %d; tighten the search)",
                rendered, total),
            variant = "muted",
        }, mainWidgets)
    end
end

local function renderZone(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })
    renderHeading(parent, "Zone quests",
        "LibCodex quests in your current zone, faction-filtered.")
    local body = withScrollBody(parent)

    local mapID = C_Map and C_Map.GetBestMapForUnit
        and C_Map.GetBestMapForUnit("player")
    if not mapID then
        trackedAcquire("Label", body, {
            text = "No current zone (loading screen?).", variant = "muted",
        }, mainWidgets)
        return
    end

    local lc = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    if not (mod and mod.AllRaw) then
        trackedAcquire("Label", body, {
            text = "LibCodex Quests module not available.", variant = "muted",
        }, mainWidgets)
        return
    end

    local side       = UnitFactionGroup and select(1, UnitFactionGroup("player")) or nil
    local sideLetter = side == "Alliance" and "A" or side == "Horde" and "H" or nil
    local rendered, total = 0, 0
    local cap = 200

    for qid, q in pairs(mod:AllRaw()) do
        if q.mapID == mapID then
            local sideOk = (not q.side) or q.side == "B" or q.side == sideLetter
            if sideOk and matchesNeedle(qid, q.label) then
                total = total + 1
                if rendered < cap then
                    rendered = rendered + 1
                    questRow(body, qid, q.level, q.label, mainWidgets,
                        { width = 460 })
                end
            end
        end
    end

    if total == 0 then
        trackedAcquire("Label", body, {
            text = string.format("No quests in LibCodex for map %d.", mapID),
            variant = "muted",
        }, mainWidgets)
    elseif total > rendered then
        trackedAcquire("Label", body, {
            text    = string.format("(showing %d of %d)", rendered, total),
            variant = "muted",
        }, mainWidgets)
    end
end

local function renderDailies(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })
    renderHeading(parent, "Daily quests",
        "Daily-frequency quests in your log.")
    local body = withScrollBody(parent)

    if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
        trackedAcquire("Label", body, {
            text = "Quest log API unavailable.", variant = "muted",
        }, mainWidgets)
        return
    end

    local dailyEnum = (Enum and Enum.QuestFrequency
        and Enum.QuestFrequency.Daily) or 1
    local rendered = 0
    local n = C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.title and info.questID
           and info.frequency == dailyEnum
           and matchesNeedle(info.questID, info.title) then
            rendered = rendered + 1
            questRow(body, info.questID, info.level, info.title,
                mainWidgets, { width = 460 })
        end
    end

    if rendered == 0 then
        trackedAcquire("Label", body, {
            text    = "No dailies in your log.",
            variant = "muted",
        }, mainWidgets)
    end
end

local function renderSearch(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })
    renderHeading(parent, "Search the catalog",
        "Use the sidebar search box to find by quest ID or partial name.")
    local body = withScrollBody(parent)

    local needle = (sidebarState.needle or ""):lower()
    if needle == "" then
        trackedAcquire("Label", body, {
            text    = "Type a quest id or partial name in the sidebar search.",
            variant = "muted",
        }, mainWidgets)
        return
    end

    local lc = libCodex()
    local mod = lc and lc.Quests and lc:Quests()
    if not (mod and mod.AllRaw) then
        trackedAcquire("Label", body, {
            text = "LibCodex Quests module not available.", variant = "muted",
        }, mainWidgets)
        return
    end

    -- ID-direct fast-path.
    local asNumber = tonumber(needle)
    if asNumber and mod.Get then
        local q = mod:Get(asNumber)
        if q then
            questRow(body, asNumber, q.level, q.label, mainWidgets,
                { width = 460, suffix = "(id " .. asNumber .. ")" })
            return
        end
    end

    local matches = 0
    for qid, q in pairs(mod:AllRaw()) do
        if matches >= 50 then break end
        if q.label and q.label:lower():find(needle, 1, true) then
            matches = matches + 1
            questRow(body, qid, q.level, q.label, mainWidgets,
                { width = 460, suffix = "(id " .. qid .. ")" })
        end
    end

    if matches == 0 then
        trackedAcquire("Label", body, {
            text = string.format("No matches for '%s'.", sidebarState.needle),
            variant = "muted",
        }, mainWidgets)
    elseif matches >= 50 then
        trackedAcquire("Label", body, {
            text = "(showing first 50; tighten the search)",
            variant = "muted",
        }, mainWidgets)
    end
end

local function renderFavorites(parent)
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })
    renderHeading(parent, "Favorited guides",
        "Quests you've starred. (Star toggle: coming in Phase 4.)")
    local body = withScrollBody(parent)

    local favs = (ns.HomeData and ns.HomeData.GetFavorites()) or {}
    local lc = libCodex()
    local mod = lc and lc.Quests and lc:Quests()

    local rendered = 0
    for qid in pairs(favs) do
        if matchesNeedle(qid, nil) then
            rendered = rendered + 1
            local label, level = ("Quest " .. qid), 0
            if mod and mod.Get then
                local q = mod:Get(qid)
                if q then label, level = q.label or label, q.level or 0 end
            end
            questRow(body, qid, level, label, mainWidgets, { width = 460 })
        end
    end

    if rendered == 0 then
        trackedAcquire("Label", body, {
            text = "No favorites yet.", variant = "muted",
        }, mainWidgets)
    end
end

-- ----- Dispatcher ---------------------------------------------------------

function Home._renderMain()
    if not mainPane then return end
    clearList(mainWidgets)

    -- Reset layout to a clean vertical-stack every time so renderers can
    -- assume a fresh slate.
    mainPane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 0 })

    local sel = sidebarState.selected or "dashboard"
    if sel == "dashboard"     then renderDashboard(mainPane)
    elseif sel == "leveling"  then renderLeveling(mainPane)
    elseif sel == "zone"      then renderZone(mainPane)
    elseif sel == "dailies"   then renderDailies(mainPane)
    elseif sel == "search"    then renderSearch(mainPane)
    elseif sel == "favorites" then renderFavorites(mainPane)
    else
        renderDashboard(mainPane)
    end
end

-- ==========================================================================
-- Sidebar (built once)
-- ==========================================================================

local SIDEBAR_CATEGORIES = {
    { id = "dashboard", label = "Dashboard" },
    { id = "leveling",  label = "Leveling"  },
    { id = "zone",      label = "Zone"      },
    { id = "dailies",   label = "Dailies"   },
    { id = "search",    label = "Search"    },
    { id = "favorites", label = "Favorites" },
}

local function buildSidebar(parent)
    local g = gui()
    parent.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 6 })

    -- Search box (filters the active main pane).
    searchEditBox = g:Acquire("EditBox", parent, {
        placeholder = "Search guides...",
        width       = 168,
    })
    searchEditBox.Cairn:On("TextChanged", function(_, t)
        sidebarState.needle = t or ""
        Home._renderMain()
    end)

    -- Category buttons.
    for _, cat in ipairs(SIDEBAR_CATEGORIES) do
        local btn = g:Acquire("Button", parent, {
            text    = cat.label,
            variant = "ghost",
            width   = 168,
        })
        local id = cat.id
        btn.Cairn:On("Click", function() setSidebarCategory(id) end)
    end

    -- Spacer + Options at bottom.
    g:Acquire("Label", parent, { text = " ", variant = "muted" })

    local opts = g:Acquire("Button", parent, {
        text    = "[Options]",
        variant = "ghost",
        width   = 168,
    })
    opts.Cairn:On("Click", function()
        -- Phase 4: open Cairn.Settings panel for Vellum.
    end)
end

-- ==========================================================================
-- Top-tab builders
-- ==========================================================================

local function buildHomeTab(pane)
    if tabBuilt.home then
        Home._renderMain()
        return
    end
    tabBuilt.home = true

    local g = gui()
    pane.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 8, padding = 8 })

    -- Sidebar (built once).
    sidebar = g:Acquire("Container", pane, { width = 180, height = 420 })
    buildSidebar(sidebar)

    -- Main pane (its content swaps via _renderMain on every Show / sidebar
    -- click / data change).
    mainPane = g:Acquire("Container", pane, { width = 500, height = 420 })

    Home._renderMain()
end

local function buildActiveTab(pane)
    clearList(activeWidgets)
    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 12 })

    local g  = gui()
    local RP = ns.RoutePlanner

    g:Acquire("Label", pane, {
        text    = "Active route",
        variant = "heading",
        align   = "left",
    })

    local route = (RP and RP.GetRoute and RP.GetRoute()) or {}
    local total = (RP and RP.GetRouteLength and RP.GetRouteLength()) or 0

    if #route == 0 then
        trackedAcquire("Label", pane, {
            text    = "No waypoints in range. Move closer to a quest hub, "
                   .. "accept a quest, or toggle Completionist mode in "
                   .. "Options to widen the search.",
            variant = "muted",
            align   = "left",
            wrap    = true,
        }, activeWidgets)
        return
    end

    -- Summary.
    trackedAcquire("Label", pane, {
        text    = string.format("%d waypoint%s, %.0f yd total",
            #route, #route == 1 and "" or "s", total),
        variant = "muted",
        align   = "left",
        wrap    = false,
    }, activeWidgets)

    -- First 8 waypoints. Click any row to open the Step viewer.
    local maxShow = math.min(8, #route)
    for i = 1, maxShow do
        local wp = route[i]
        local prefix = (i == 1) and "> " or "  "
        local title  = wp.title or ("Quest " .. tostring(wp.questID))
        local rowText = string.format("%s[%s] %s", prefix, wp.type, title)

        local row = trackedAcquire("Button", pane, {
            text    = rowText,
            variant = "ghost",
            width   = 620,
        }, activeWidgets)
        local qid = wp.questID
        row.Cairn:On("Click", function() followAndOpen(qid) end)

        if wp.type == "OBJECTIVE" and wp.objText and wp.objText ~= "" then
            trackedAcquire("Label", pane, {
                text    = "    " .. wp.objText,
                variant = "muted",
                align   = "left",
                wrap    = true,
            }, activeWidgets)
        end
    end

    if #route > maxShow then
        trackedAcquire("Label", pane, {
            text    = string.format("(showing first %d of %d -- "
                .. "open the Step viewer for the full route)",
                maxShow, #route),
            variant = "muted",
            align   = "left",
            wrap    = false,
        }, activeWidgets)
    end
end

local function buildRecentTab(pane)
    clearList(recentWidgets)
    pane.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 4, padding = 8 })

    local g = gui()
    g:Acquire("Label", pane, {
        text    = "Recently followed",
        variant = "heading",
        align   = "left",
    })

    local hist = (ns.HomeData and ns.HomeData.GetHistory(50)) or {}
    if #hist == 0 then
        trackedAcquire("Label", pane, {
            text    = "No history yet. Follow a quest to start the log.",
            variant = "muted",
            align   = "left",
            wrap    = true,
        }, recentWidgets)
        return
    end

    local scroll = trackedAcquire("ScrollFrame", pane, {
        width = 660, height = 380,
    }, recentWidgets)
    local body = scroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 0 })

    for _, e in ipairs(hist) do
        local title  = e.title or ("Quest " .. tostring(e.questID))
        local rel    = formatRelativeTime(e.followedAt)
        local mark   = e.completedAt and "  -  done" or ""
        local row = trackedAcquire("Button", body, {
            text    = string.format("%s  -  %s%s  (id %d)",
                title, rel, mark, e.questID),
            variant = "ghost",
            width   = 640,
        }, recentWidgets)
        local qid = e.questID
        row.Cairn:On("Click", function() followAndOpen(qid) end)
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
        title    = logoTag(20) .. "  Vellum",
        width    = 720,
        height   = 480,
        closable = true,
        movable  = true,
    })

    do
        local h  = dbHome() or { x = 0, y = 0 }
        win:ClearAllPoints()
        win:SetPoint("CENTER", UIParent, "CENTER", h.x or 0, h.y or 0)
        -- Restore last sidebar category so /reload preserves where we
        -- were. Falls back to "dashboard" for first-ever opens.
        sidebarState.selected = h.sidebarSelected or "dashboard"
    end

    win.Cairn:On("Moved", function(_, x, y)
        local h = dbHome()
        if h then h.x, h.y = x or 0, y or 0 end
    end)

    win.Cairn:On("Close", function() Home.Hide() end)

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 6 })

    topTabs = g:Acquire("TabGroup", content, {
        width  = 700,
        height = 430,
        tabs = {
            { id = "home",   label = "Home"   },
            { id = "active", label = "Active" },
            { id = "recent", label = "Recent" },
        },
        selected  = (dbHome() and dbHome().selectedTab) or "home",
        tabHeight = 26,
        gap       = 4,
    })

    topTabs.Cairn:On("Changed", function(_, tabId)
        local h = dbHome()
        if h then h.selectedTab = tabId end
        Home._buildTab(tabId)
    end)

    Home._buildTab(topTabs.Cairn:GetSelected() or "home")
end

function Home._buildTab(id)
    if not topTabs then return end
    local pane = topTabs.Cairn:GetTabContent(id)
    if not pane then return end
    if id == "home"        then buildHomeTab(pane)
    elseif id == "active"  then buildActiveTab(pane)
    elseif id == "recent"  then buildRecentTab(pane) end
end

-- ==========================================================================
-- Refresh-on-data-change
-- ==========================================================================

local function refreshIfVisible()
    if not (win and win:IsShown() and topTabs) then return end
    local sel = topTabs.Cairn:GetSelected()
    if sel == "home"         then Home._renderMain()
    elseif sel == "active"   then buildActiveTab(topTabs.Cairn:GetTabContent("active"))
    elseif sel == "recent"   then buildRecentTab(topTabs.Cairn:GetTabContent("recent"))
    end
end

-- HomeData fires OnChanged on PLAYER_MONEY / TIME_PLAYED_MSG / new history /
-- favorite toggle. Refresh whatever's visible.
if ns.HomeData and ns.HomeData.OnChanged then
    ns.HomeData.OnChanged(refreshIfVisible)
end

-- Follower changes drive the Active tab specifically (legacy; the route
-- planner is the primary driver now).
if ns.Follower and ns.Follower.OnChange then
    ns.Follower.OnChange(refreshIfVisible)
end

-- RoutePlanner is the primary driver for the Active tab in Phase 3C+.
-- Whenever the route changes (debounced), re-render the active pane.
if ns.RoutePlanner and ns.RoutePlanner.OnRouteChanged then
    ns.RoutePlanner.OnRouteChanged(refreshIfVisible)
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Home.Show()
    build()
    if win then win:Show() end
end

function Home.Hide()
    if win then win:Hide() end
end

function Home.IsShown()
    return (win and win:IsShown()) or false
end

function Home.Toggle()
    if Home.IsShown() then Home.Hide() else Home.Show() end
end

-- ==========================================================================
-- Legacy ns.Window shim (back-compat for the v0.1 panel surface).
-- ==========================================================================

ns.Window = ns.Window or {}
ns.Window.Show    = Home.Show
ns.Window.Hide    = Home.Hide
ns.Window.IsShown = Home.IsShown
ns.Window.Center  = function() end
ns.Window.SetText = function() end
