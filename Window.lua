-- Vellum/Window.lua
-- The sticky guide window: a parchment-toned panel with the current quest
-- title and current objective text. Sits independently of the compass
-- arrow; user drags either anywhere they want.
--
-- Visual:
--   - Parchment backdrop (Blizzard tooltip background tinted parchment)
--   - Ink-colored border (Blizzard tooltip border tinted dark brown)
--   - Title row: quest title (parchment-ink, bold, slightly larger)
--   - Thin ink divider line beneath the title
--   - Body: objective text (parchment-ink, two-line wrap, truncates on overflow)
--   - When the quest is complete, the border tints gold to signal "ready to turn in"
--
-- Public API:
--   Vellum.Window.Show()
--   Vellum.Window.Hide()
--   Vellum.Window.SetText(title, objective, isComplete)
--   Vellum.Window.IsShown()
--   Vellum.Window.Center()
--
-- Auto-wires to ns.Follower.OnChange at file scope: shows + updates when a
-- quest is being followed, hides when Follower clears. No glue code needed
-- in slash handlers.

local ADDON, ns = ...
ns.Window = ns.Window or {}
local Window = ns.Window

-- ==========================================================================
-- Constants
-- ==========================================================================

local DEFAULT_W = 280
local DEFAULT_H = 78

local PARCHMENT_RGB = { 0.92, 0.86, 0.69 }
local INK_RGB       = { 0.20, 0.13, 0.06 }
local GOLD_RGB      = { 0.85, 0.66, 0.16 }   -- ready-to-turn-in border tint

-- ==========================================================================
-- Frame state
-- ==========================================================================

local frame
local lastIsComplete = false

-- ==========================================================================
-- Build
-- ==========================================================================

local function savedPos()
    if ns.db and ns.db.profile and ns.db.profile.window then
        return ns.db.profile.window.x or 0, ns.db.profile.window.y or 0
    end
    return 0, 0
end

local function persistPos(x, y)
    if ns.db and ns.db.profile and ns.db.profile.window then
        ns.db.profile.window.x = x or 0
        ns.db.profile.window.y = y or 0
    end
end

local function buildFrame()
    if frame then return end

    -- BackdropTemplate is the Dragonflight+ way to use SetBackdrop. It exists
    -- in 120005; falling back to a plain Frame just means SetBackdrop silently
    -- no-ops, which is acceptable.
    local ok, f = pcall(CreateFrame, "Frame", "VellumWindowFrame", UIParent, "BackdropTemplate")
    if not ok or not f then
        f = CreateFrame("Frame", "VellumWindowFrame", UIParent)
    end
    frame = f

    frame:SetSize(DEFAULT_W, DEFAULT_H)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")

    local sx, sy = savedPos()
    -- Default: anchored RIGHT side, ~100px above center, then offset by saved position.
    frame:SetPoint("CENTER", UIParent, "RIGHT", -160 + sx, 120 + sy)

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint(1)
        persistPos(x, y)
    end)

    if frame.SetBackdrop then
        frame:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12,
            tile = true, tileSize = 8,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        frame:SetBackdropColor(PARCHMENT_RGB[1], PARCHMENT_RGB[2], PARCHMENT_RGB[3], 0.95)
        frame:SetBackdropBorderColor(INK_RGB[1], INK_RGB[2], INK_RGB[3], 1)
    end

    -- Title row (top): quest title in larger parchment-ink, single-line.
    frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT",  frame, "TOPLEFT",  10, -8)
    frame.title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -8)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetWordWrap(false)
    frame.title:SetTextColor(INK_RGB[1], INK_RGB[2], INK_RGB[3])

    -- Thin ink divider beneath the title.
    frame.divider = frame:CreateTexture(nil, "ARTWORK")
    frame.divider:SetHeight(1)
    frame.divider:SetPoint("TOPLEFT",  frame.title, "BOTTOMLEFT",  0, -3)
    frame.divider:SetPoint("TOPRIGHT", frame.title, "BOTTOMRIGHT", 0, -3)
    frame.divider:SetColorTexture(INK_RGB[1], INK_RGB[2], INK_RGB[3], 0.55)

    -- Objective body: two-line max, truncates with ellipsis if overflow.
    frame.body = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.body:SetPoint("TOPLEFT",  frame.divider, "BOTTOMLEFT",  0, -4)
    frame.body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 8)
    frame.body:SetJustifyH("LEFT")
    frame.body:SetJustifyV("TOP")
    frame.body:SetMaxLines(3)
    frame.body:SetWordWrap(true)
    frame.body:SetTextColor(INK_RGB[1] + 0.05, INK_RGB[2] + 0.05, INK_RGB[3] + 0.05)

    frame:Hide()
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Window.Show()
    buildFrame()
    frame:Show()
end

function Window.Hide()
    if frame then frame:Hide() end
end

function Window.IsShown()
    return (frame and frame:IsShown()) or false
end

function Window.SetText(title, objective, isComplete)
    buildFrame()
    frame.title:SetText(title or "")
    frame.body:SetText(objective or "")

    -- Border tint shifts to gold when ready to turn in. Skip the SetBackdrop
    -- update if the state hasn't changed - cheap but avoids needless calls.
    local complete = isComplete and true or false
    if complete ~= lastIsComplete and frame.SetBackdropBorderColor then
        if complete then
            frame:SetBackdropBorderColor(GOLD_RGB[1], GOLD_RGB[2], GOLD_RGB[3], 1)
        else
            frame:SetBackdropBorderColor(INK_RGB[1], INK_RGB[2], INK_RGB[3], 1)
        end
        lastIsComplete = complete
    end
end

function Window.Center()
    buildFrame()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "RIGHT", -160, 120)
    persistPos(0, 0)
end

-- ==========================================================================
-- Auto-wire to Follower
-- ==========================================================================

if ns.Follower and ns.Follower.OnChange then
    ns.Follower.OnChange(function(state)
        if state and state.questID then
            local title = state.questTitle or "Quest"
            local body  = state.objectiveText or ""
            Window.SetText(title, body, state.isComplete)
            Window.Show()
        else
            Window.Hide()
        end
    end)
end
