-- Vellum/Panel.lua
-- The Vellum panel: a Cairn-Gui-2.0 Window with three tabs (Log / Zone /
-- Search) for finding a quest to follow, plus a header banner that mirrors
-- the previous Window.lua's job (current quest title + objective text).
--
-- Public API:
--   Vellum.Panel.Show()
--   Vellum.Panel.Hide()
--   Vellum.Panel.Toggle()
--   Vellum.Panel.IsShown()
--   Vellum.Panel.SetText(title, objective, isComplete)
--
-- Backwards-compat: the old Vellum.Window API is shimmed onto Panel so
-- existing call sites in Core.lua and Follower.lua keep working without
-- needing per-call updates. New code should call Vellum.Panel.* directly.
--
-- Auto-wires to ns.Follower.OnChange at file scope: when a quest is being
-- followed, the header updates and (per db.profile.panel.autoShow) the
-- panel auto-shows. When the follower clears, the header resets and (per
-- db.profile.panel.autoHideOnClear) the panel auto-hides.
--
-- The brand logo (Vellum/Logo.png) is embedded in the header title via
-- WoW's |T...|t inline-texture syntax so we don't need a raw CreateTexture
-- in the consumer (that would violate the always-use-Cairn-libraries rule).

local ADDON, ns = ...
ns.Panel = ns.Panel or {}
local Panel = ns.Panel

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
local headerTitle, headerBody
local tg
local tabBuilt   = { log = false, zone = false, search = false }
local tabRefresh = {}
local searchState = { needle = "" }

-- ==========================================================================
-- Logo (inline texture in font strings)
-- ==========================================================================

local LOGO_PATH = "Interface\\AddOns\\Vellum\\Logo"

local function logoTag(size)
    size = size or 24
    return string.format("|T%s:%d:%d|t", LOGO_PATH, size, size)
end

-- ==========================================================================
-- Click action: follow + dismiss
-- ==========================================================================

local function followQuest(qid)
    if type(qid) ~= "number" or qid <= 0 then return end
    if not (ns.Follower and ns.Follower.Set) then return end
    ns.Follower.Set(qid)
    Panel.Hide()
end

-- (The previous fixButtonClicks workaround was removed 2026-05-08 once
-- Cairn-Gui-Widgets-Standard-2.0 MINOR=4 shipped the framework-level
-- fix: Button.OnAcquire now calls RegisterForClicks("AnyUp") directly,
-- so consumer code no longer needs the per-row workaround.)

-- ==========================================================================
-- Build: Log tab (player's accepted quests)
-- ==========================================================================

local function buildLogTab(pane)
    if tabBuilt.log then return end
    tabBuilt.log = true

    local g = gui()
    pane.Cairn:SetLayout("Stack", { direction = "vertical", gap = 4, padding = 8 })

    g:Acquire("Label", pane, {
        text    = "Quests in your log. Click one to follow it.",
        variant = "muted",
        wrap    = true,
    })

    local scroll = g:Acquire("ScrollFrame", pane, { width = 400, height = 360 })
    local body   = scroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack", { direction = "vertical", gap = 2, padding = 0 })

    local rows = {}
    local function refresh()
        for _, r in ipairs(rows) do r.Cairn:Release() end
        wipe(rows)

        if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries) then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "Quest log API unavailable.",
                variant = "muted",
            })
            return
        end

        local count = 0
        local n = C_QuestLog.GetNumQuestLogEntries() or 0
        for i = 1, n do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.title and info.questID then
                count = count + 1
                local row = g:Acquire("Button", body, {
                    text    = string.format("Lvl %d  %s", info.level or 0, info.title),
                    variant = "ghost",
                    width   = 380,
                })
                local qid = info.questID
                row.Cairn:On("Click", function() followQuest(qid) end)
                rows[#rows + 1] = row
            end
        end

        if count == 0 then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "Your quest log is empty.",
                variant = "muted",
            })
        end
    end

    refresh()
    tabRefresh.log = refresh

    if Cairn and Cairn.Events then
        Cairn.Events:Subscribe("QUEST_LOG_UPDATE", function()
            if tg and tg.Cairn:GetSelected() == "log" then refresh() end
        end, "Vellum.Panel.Log")
    end
end

-- ==========================================================================
-- Build: Zone tab (LibCodex quests filtered to current zone + side)
-- ==========================================================================

local function buildZoneTab(pane)
    if tabBuilt.zone then return end
    tabBuilt.zone = true

    local g = gui()
    pane.Cairn:SetLayout("Stack", { direction = "vertical", gap = 4, padding = 8 })

    g:Acquire("Label", pane, {
        text    = "Quests in your current zone (LibCodex catalog).",
        variant = "muted",
        wrap    = true,
    })

    local scroll = g:Acquire("ScrollFrame", pane, { width = 400, height = 360 })
    local body   = scroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack", { direction = "vertical", gap = 2, padding = 0 })

    local rows = {}
    local function refresh()
        for _, r in ipairs(rows) do r.Cairn:Release() end
        wipe(rows)

        local mapID = C_Map and C_Map.GetBestMapForUnit
            and C_Map.GetBestMapForUnit("player")
        if not mapID then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "No current zone (in a loading screen?).",
                variant = "muted",
            })
            return
        end

        local lc = libCodex()
        local mod = lc and lc.Quests and lc:Quests()
        if not (mod and mod.AllRaw) then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "LibCodex Quests module not available.",
                variant = "muted",
            })
            return
        end

        local side = UnitFactionGroup and select(1, UnitFactionGroup("player")) or nil
        local sideLetter = side == "Alliance" and "A" or side == "Horde" and "H" or nil

        local count = 0
        for qid, q in pairs(mod:AllRaw()) do
            if q.mapID == mapID then
                local sideOk = (not q.side) or q.side == "B" or q.side == sideLetter
                if sideOk then
                    count = count + 1
                    if count <= 200 then
                        local row = g:Acquire("Button", body, {
                            text    = string.format("Lvl %d  %s",
                                q.level or 0, q.label or ("Quest " .. qid)),
                            variant = "ghost",
                            width   = 380,
                        })
                        local theID = qid
                        row.Cairn:On("Click", function() followQuest(theID) end)
                        rows[#rows + 1] = row
                    end
                end
            end
        end

        if count == 0 then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = string.format("No quests in LibCodex for map %d.", mapID),
                variant = "muted",
            })
        elseif count > 200 then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = string.format("(showing first 200 of %d)", count),
                variant = "muted",
            })
        end
    end

    refresh()
    tabRefresh.zone = refresh

    if Cairn and Cairn.Events then
        Cairn.Events:Subscribe("ZONE_CHANGED_NEW_AREA", function()
            if tg and tg.Cairn:GetSelected() == "zone" then refresh() end
        end, "Vellum.Panel.Zone")
    end
end

-- ==========================================================================
-- Build: Search tab (free-text + ID across LibCodex Quests)
-- ==========================================================================

local function buildSearchTab(pane)
    if tabBuilt.search then return end
    tabBuilt.search = true

    local g = gui()
    pane.Cairn:SetLayout("Stack", { direction = "vertical", gap = 6, padding = 8 })

    g:Acquire("Label", pane, {
        text    = "Search the LibCodex catalog by quest ID or partial name.",
        variant = "muted",
        wrap    = true,
    })

    local searchRow = g:Acquire("Container", pane)
    searchRow:SetHeight(28)
    searchRow.Cairn:SetLayout("Stack",
        { direction = "horizontal", gap = 8, padding = 0 })

    g:Acquire("Label", searchRow, { text = "Find:", variant = "body" })

    local eb = g:Acquire("EditBox", searchRow, {
        placeholder = "id or partial name",
        width       = 300,
    })

    local scroll = g:Acquire("ScrollFrame", pane, { width = 400, height = 320 })
    local body   = scroll.Cairn:GetContent()
    body.Cairn:SetLayout("Stack", { direction = "vertical", gap = 2, padding = 0 })

    local rows = {}
    local function refresh()
        for _, r in ipairs(rows) do r.Cairn:Release() end
        wipe(rows)

        local needle = (searchState.needle or ""):lower()
        if needle == "" then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "Type a quest id or partial name to search.",
                variant = "muted",
            })
            return
        end

        local lc = libCodex()
        local mod = lc and lc.Quests and lc:Quests()
        if not (mod and mod.AllRaw) then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "LibCodex Quests module not available.",
                variant = "muted",
            })
            return
        end

        -- ID-direct lookup: if the needle is a number and lands in the
        -- catalog, return just that one row. Costs O(1) before the scan.
        local asNumber = tonumber(needle)
        if asNumber and asNumber > 0 and mod.Get then
            local q = mod:Get(asNumber)
            if q then
                local row = g:Acquire("Button", body, {
                    text    = string.format("Lvl %d  %s  (id %d)",
                        q.level or 0, q.label or "Unnamed", asNumber),
                    variant = "ghost",
                    width   = 380,
                })
                row.Cairn:On("Click", function() followQuest(asNumber) end)
                rows[#rows + 1] = row
                return
            end
        end

        local matches = 0
        for qid, q in pairs(mod:AllRaw()) do
            if matches >= 50 then break end
            if q.label and q.label:lower():find(needle, 1, true) then
                matches = matches + 1
                local row = g:Acquire("Button", body, {
                    text    = string.format("Lvl %d  %s  (id %d)",
                        q.level or 0, q.label, qid),
                    variant = "ghost",
                    width   = 380,
                })
                local theID = qid
                row.Cairn:On("Click", function() followQuest(theID) end)
                rows[#rows + 1] = row
            end
        end

        if matches == 0 then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = string.format("No matches for '%s'.", searchState.needle),
                variant = "muted",
            })
        elseif matches >= 50 then
            rows[#rows + 1] = g:Acquire("Label", body, {
                text    = "(showing first 50; tighten the search to see more)",
                variant = "muted",
            })
        end
    end

    eb.Cairn:On("TextChanged", function(_, t)
        searchState.needle = t or ""
        refresh()
    end)

    refresh()
    tabRefresh.search = refresh
end

-- ==========================================================================
-- Build: full panel (Window + header + TabGroup)
-- ==========================================================================

local function build()
    if win then return end
    local g = gui()
    if not g then return end

    win = g:Acquire("Window", UIParent, {
        title    = "Vellum",
        width    = 440,
        height   = 540,
        closable = true,
        movable  = true,
    })

    -- Apply saved drag offset from db.profile.panel.x/y. Cairn-Gui-2.0
    -- Standard MINOR=5 added a default CENTER anchor in Window.OnAcquire
    -- so we don't need to anchor for visibility -- but we DO need to
    -- override that default to apply the saved offset.
    do
        local sx = (ns.db and ns.db.profile and ns.db.profile.panel
                    and ns.db.profile.panel.x) or 0
        local sy = (ns.db and ns.db.profile and ns.db.profile.panel
                    and ns.db.profile.panel.y) or 0
        win:ClearAllPoints()
        win:SetPoint("CENTER", UIParent, "CENTER", sx, sy)
    end

    -- Persist drag position. Standard MINOR=5 fires Moved after OnDragStop
    -- with (x, y, point, relTo, relPoint). We only need (x, y) for the
    -- CENTER-anchored panel.
    win.Cairn:On("Moved", function(_, x, y)
        if ns.db and ns.db.profile and ns.db.profile.panel then
            ns.db.profile.panel.x = x or 0
            ns.db.profile.panel.y = y or 0
        end
    end)

    win.Cairn:On("Close", function() Panel.Hide() end)

    local content = win.Cairn:GetContent()
    content.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 6, padding = 6 })

    -- ---- Header section --------------------------------------------------

    local header = g:Acquire("Container", content)
    header.Cairn:SetLayout("Stack",
        { direction = "vertical", gap = 2, padding = 4 })
    header:SetHeight(46)

    headerTitle = g:Acquire("Label", header, {
        text    = logoTag(24) .. "  Vellum  -  No quest followed.",
        variant = "heading",
        align   = "left",
        wrap    = false,
    })
    headerBody = g:Acquire("Label", header, {
        text    = "Pick a quest from the tabs below.",
        variant = "muted",
        align   = "left",
        wrap    = true,
    })

    -- ---- Tabs ------------------------------------------------------------

    tg = g:Acquire("TabGroup", content, {
        width  = 420,
        height = 440,
        tabs = {
            { id = "log",    label = "Log"    },
            { id = "zone",   label = "Zone"   },
            { id = "search", label = "Search" },
        },
        selected  = "log",
        tabHeight = 26,
        gap       = 4,
    })

    tg.Cairn:On("Changed", function(_, tabId)
        Panel._buildTab(tabId)
    end)

    -- Build the initial (selected) tab.
    Panel._buildTab("log")
end

function Panel._buildTab(id)
    if not tg then return end
    local pane = tg.Cairn:GetTabContent(id)
    if not pane then return end
    if id == "log"    then buildLogTab(pane)
    elseif id == "zone"   then buildZoneTab(pane)
    elseif id == "search" then buildSearchTab(pane) end
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Panel.Show()
    build()
    if win then win:Show() end
end

function Panel.Hide()
    if win then win:Hide() end
end

function Panel.IsShown()
    return (win and win:IsShown()) or false
end

function Panel.Toggle()
    if Panel.IsShown() then Panel.Hide() else Panel.Show() end
end

function Panel.SetText(title, objective, isComplete)
    build()
    if not (headerTitle and headerBody) then return end

    if title and title ~= "" then
        local prefix = isComplete and "Ready to turn in: " or "Following: "
        headerTitle.Cairn:SetText(logoTag(24) .. "  " .. prefix .. title)
    else
        headerTitle.Cairn:SetText(logoTag(24) .. "  Vellum  -  No quest followed.")
    end

    headerBody.Cairn:SetText(objective or "Pick a quest from the tabs below.")
end

-- ==========================================================================
-- Backwards-compat shim: old Vellum.Window API maps to the panel so
-- existing call sites in Core.lua keep working without per-call updates.
-- ==========================================================================

ns.Window = ns.Window or {}
ns.Window.Show    = Panel.Show
ns.Window.Hide    = Panel.Hide
ns.Window.SetText = Panel.SetText
ns.Window.IsShown = Panel.IsShown
ns.Window.Center  = function() end   -- Cairn-Gui handles its own positioning

-- ==========================================================================
-- Auto-wire to Follower
-- ==========================================================================

local function autoShowEnabled()
    return ns.db and ns.db.profile and ns.db.profile.panel
       and ns.db.profile.panel.autoShow ~= false
end

local function autoHideEnabled()
    return ns.db and ns.db.profile and ns.db.profile.panel
       and ns.db.profile.panel.autoHideOnClear ~= false
end

if ns.Follower and ns.Follower.OnChange then
    ns.Follower.OnChange(function(state)
        if state and state.questID then
            Panel.SetText(state.questTitle, state.objectiveText, state.isComplete)
            if autoShowEnabled() then Panel.Show() end
        else
            Panel.SetText(nil, nil, false)
            if autoHideEnabled() then Panel.Hide() end
        end
    end)
end
