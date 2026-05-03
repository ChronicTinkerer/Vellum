-- Vellum/Arrow.lua
-- Wax-seal compass: a brass-rimmed circular pointer with an oxblood wax-red
-- chevron rotating inside on a parchment-toned disc, with a small ink emblem
-- at the pivot and parchment-ink labels below. Auto-tracks Vellum.Follower.
--
-- Visual layers (back to front):
--   1. Parchment disc       (square color texture masked to a circle)
--   2. Brass ring           (atlas-based decorative frame)
--   3. Wax-red chevron      (rotating; tint shifts with distance)
--   4. Ink dot emblem       (the pivot point, doesn't rotate)
--   5. Quest title + distance text below the frame
--
-- Polish layers:
--   * Smooth rotation lerp (not snappy)
--   * Pointer color shifts oxblood (far) -> bright red (close) -> green (arrival)
--   * Brief alpha pulse when the destination changes
--
-- Public API:
--   Vellum.Arrow.Track(mapID, x, y, label)   show + start tracking
--   Vellum.Arrow.Stop()                       hide and stop ticker
--   Vellum.Arrow.Center()                     re-center on screen
--   Vellum.Arrow.SetSize(px)                  resize (32..256)
--   Vellum.Arrow.IsShown()
--
-- Auto-wires to ns.Follower.OnChange at file-scope so the user doesn't have
-- to glue them together.

local ADDON, ns = ...
ns.Arrow = ns.Arrow or {}
local Arrow = ns.Arrow

-- ==========================================================================
-- Constants
-- ==========================================================================

local DEFAULT_SIZE    = 96
local UPDATE_INTERVAL = 0.05            -- ticker resolution in seconds
local ROT_LERP_RATE   = 12              -- larger = snappier rotation
local ARRIVAL_YARDS   = 25

-- Parchment + ink palette
local PARCHMENT_RGB = { 0.92, 0.86, 0.69 }
local INK_RGB       = { 0.25, 0.18, 0.10 }

-- Pointer color stops, by distance in yards. Lerped between consecutive stops.
local POINTER_STOPS = {
    { d = 0,             r = 0.30, g = 0.85, b = 0.30 },  -- arrival green
    { d = ARRIVAL_YARDS, r = 0.85, g = 0.18, b = 0.10 },  -- bright wax red
    { d = 200,           r = 0.55, g = 0.12, b = 0.10 },  -- mid wax red
    { d = 1000,          r = 0.40, g = 0.10, b = 0.10 },  -- deep oxblood far
}

-- Atlas chain: try the prettier name first, fall back to a reliable older one.
-- Texture path is the last-resort string fallback for the chevron.
local RING_ATLAS_CHAIN    = { "QuestPortraitBorder-Round", "common-iconframe" }
local POINTER_ATLAS_CHAIN = { "Waypoint-MapPin-Untracked", "Minimap-PositionArrows" }
local POINTER_FALLBACK    = "Interface\\Cursor\\Point"
local CIRCLE_MASK_PATH    = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- ==========================================================================
-- Math helpers
-- ==========================================================================

local atan2 = math.atan2 or math.atan

local function shortestAngle(from, to)
    local d = to - from
    while d <= -math.pi do d = d + 2 * math.pi end
    while d  >  math.pi do d = d - 2 * math.pi end
    return d
end

local function lerpAngle(from, to, t)
    return from + shortestAngle(from, to) * t
end

local function pointerColor(distance)
    if not distance then
        local last = POINTER_STOPS[#POINTER_STOPS]
        return last.r, last.g, last.b
    end
    for i = 1, #POINTER_STOPS - 1 do
        local a, b = POINTER_STOPS[i], POINTER_STOPS[i + 1]
        if distance <= b.d then
            local span = b.d - a.d
            local t = span > 0 and (distance - a.d) / span or 0
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            return a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t
        end
    end
    local last = POINTER_STOPS[#POINTER_STOPS]
    return last.r, last.g, last.b
end

local function bearingAndDistance(destMapID, destX, destY)
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition
            and C_Map.GetWorldPosFromMapPos and CreateVector2D) then
        return false, nil, nil
    end
    local playerMap = C_Map.GetBestMapForUnit("player")
    if not playerMap then return false, nil, nil end
    local playerPos = C_Map.GetPlayerMapPosition(playerMap, "player")
    if not playerPos then return false, nil, nil end

    local pCont, pWorld = C_Map.GetWorldPosFromMapPos(playerMap, playerPos)
    local dCont, dWorld = C_Map.GetWorldPosFromMapPos(destMapID,
        CreateVector2D(destX, destY))
    if not (pCont and dCont and pWorld and dWorld) then return false, nil, nil end
    if pCont ~= dCont then return false, nil, nil end

    local dxNorth = dWorld.x - pWorld.x
    local dyWest  = dWorld.y - pWorld.y
    local dist = math.sqrt(dxNorth * dxNorth + dyWest * dyWest)
    local bearing = atan2(dyWest, dxNorth)
    return true, bearing, dist
end

-- Try atlas names from a chain; returns true if any succeeded.
local function applyFirstAtlas(tex, names)
    if not tex.SetAtlas then return false end
    for _, name in ipairs(names) do
        local ok = pcall(tex.SetAtlas, tex, name, false)
        if ok then return true end
    end
    return false
end

-- ==========================================================================
-- Frame state
-- ==========================================================================

local frame
local destination          -- { mapID, x, y, label }
local ticker
local currentRotation = 0
local pulseAnim

-- ==========================================================================
-- Frame construction
-- ==========================================================================

local function savedPos()
    if ns.db and ns.db.profile and ns.db.profile.arrow then
        return ns.db.profile.arrow.x or 0, ns.db.profile.arrow.y or 200
    end
    return 0, 200
end

local function persistPos(x, y)
    if ns.db and ns.db.profile and ns.db.profile.arrow then
        ns.db.profile.arrow.x = x or 0
        ns.db.profile.arrow.y = y or 0
    end
end

local function buildFrame()
    if frame then return end

    frame = CreateFrame("Frame", "VellumArrowFrame", UIParent)
    frame:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("HIGH")

    local sx, sy = savedPos()
    frame:SetPoint("CENTER", UIParent, "CENTER", sx, sy)

    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local _, _, _, x, y = self:GetPoint(1)
        persistPos(x, y)
    end)

    -- Layer 1: parchment disc (square color masked to a circle).
    frame.disc = frame:CreateTexture(nil, "BACKGROUND")
    frame.disc:SetAllPoints()
    frame.disc:SetColorTexture(
        PARCHMENT_RGB[1], PARCHMENT_RGB[2], PARCHMENT_RGB[3], 0.92)
    if frame.CreateMaskTexture then
        local mask = frame:CreateMaskTexture()
        mask:SetAllPoints(frame.disc)
        local okMask = pcall(mask.SetTexture, mask, CIRCLE_MASK_PATH,
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if okMask then frame.disc:AddMaskTexture(mask) end
    end

    -- Layer 2: brass ring (slightly oversized so it overlaps the disc edge).
    frame.ring = frame:CreateTexture(nil, "BORDER")
    frame.ring:SetPoint("TOPLEFT", frame, "TOPLEFT", -6, 6)
    frame.ring:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 6, -6)
    if not applyFirstAtlas(frame.ring, RING_ATLAS_CHAIN) then
        frame.ring:SetColorTexture(0.55, 0.42, 0.18, 0.0)  -- invisible fallback
    end

    -- Layer 3: rotating wax-red chevron.
    frame.pointer = frame:CreateTexture(nil, "ARTWORK")
    frame.pointer:SetSize(DEFAULT_SIZE * 0.55, DEFAULT_SIZE * 0.55)
    frame.pointer:SetPoint("CENTER", frame, "CENTER", 0, 0)
    if not applyFirstAtlas(frame.pointer, POINTER_ATLAS_CHAIN) then
        pcall(frame.pointer.SetTexture, frame.pointer, POINTER_FALLBACK)
    end
    frame.pointer:SetVertexColor(0.55, 0.13, 0.16)

    -- Layer 4: tiny ink dot at the pivot.
    frame.emblem = frame:CreateTexture(nil, "OVERLAY")
    frame.emblem:SetSize(DEFAULT_SIZE * 0.10, DEFAULT_SIZE * 0.10)
    frame.emblem:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.emblem:SetColorTexture(INK_RGB[1], INK_RGB[2], INK_RGB[3], 1)

    -- Layer 5: parchment-ink label + distance below.
    frame.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
    frame.label:SetWidth(DEFAULT_SIZE * 2.6)
    frame.label:SetWordWrap(false)
    frame.label:SetTextColor(INK_RGB[1], INK_RGB[2], INK_RGB[3])

    frame.distance = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.distance:SetPoint("TOP", frame.label, "BOTTOM", 0, -1)
    frame.distance:SetTextColor(INK_RGB[1], INK_RGB[2], INK_RGB[3])

    -- Pulse animation on waypoint change (alpha dip-and-recover on the whole frame).
    pulseAnim = frame:CreateAnimationGroup()
    local fade1 = pulseAnim:CreateAnimation("Alpha")
    fade1:SetFromAlpha(1.0); fade1:SetToAlpha(0.45); fade1:SetDuration(0.18); fade1:SetOrder(1)
    local fade2 = pulseAnim:CreateAnimation("Alpha")
    fade2:SetFromAlpha(0.45); fade2:SetToAlpha(1.0); fade2:SetDuration(0.32); fade2:SetOrder(2)

    frame:Hide()
end

-- ==========================================================================
-- Tick
-- ==========================================================================

local function tick(dt)
    if not (frame and frame:IsShown() and destination) then return end

    local same, bearing, dist =
        bearingAndDistance(destination.mapID, destination.x, destination.y)

    if not same then
        frame.pointer:SetRotation(0)
        frame.pointer:SetVertexColor(0.40, 0.10, 0.10)
        frame.distance:SetText("?? yd")
        return
    end

    local facing = (GetPlayerFacing and GetPlayerFacing()) or 0
    local target = bearing - facing

    local t = (dt or UPDATE_INTERVAL) * ROT_LERP_RATE
    if t > 1 then t = 1 end
    currentRotation = lerpAngle(currentRotation, target, t)
    frame.pointer:SetRotation(currentRotation)

    if dist < 1000 then
        frame.distance:SetText(string.format("%.0f yd", dist))
    else
        frame.distance:SetText(string.format("%.1f km", dist / 1000))
    end

    local r, g, b = pointerColor(dist)
    frame.pointer:SetVertexColor(r, g, b)
end

local function startTicker()
    if ticker then return end
    if C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(UPDATE_INTERVAL, function() tick(UPDATE_INTERVAL) end)
    end
end

local function stopTicker()
    if ticker and ticker.Cancel then ticker:Cancel() end
    ticker = nil
end

-- ==========================================================================
-- Public API
-- ==========================================================================

function Arrow.Track(mapID, x, y, label)
    if type(mapID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return false, "Track requires numeric mapID, x, y."
    end
    buildFrame()

    local same = destination
        and destination.mapID == mapID
        and math.abs((destination.x or 0) - x) < 0.0001
        and math.abs((destination.y or 0) - y) < 0.0001

    destination = { mapID = mapID, x = x, y = y, label = label or "" }
    frame.label:SetText(destination.label)
    frame:Show()

    if not same and pulseAnim then
        if pulseAnim.Stop then pulseAnim:Stop() end
        if pulseAnim.Play then pulseAnim:Play() end
    end

    tick(UPDATE_INTERVAL)
    startTicker()
    return true
end

function Arrow.Stop()
    destination = nil
    stopTicker()
    if frame then frame:Hide() end
end

function Arrow.Center()
    buildFrame()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
    persistPos(0, 200)
end

function Arrow.SetSize(px)
    buildFrame()
    px = tonumber(px) or DEFAULT_SIZE
    if px < 32 then px = 32 elseif px > 256 then px = 256 end
    frame:SetSize(px, px)
    frame.pointer:SetSize(px * 0.55, px * 0.55)
    frame.emblem:SetSize(px * 0.10, px * 0.10)
    frame.label:SetWidth(px * 2.6)
    return px
end

function Arrow.IsShown()
    return (frame and frame:IsShown()) or false
end

-- ==========================================================================
-- Auto-wire to Follower (file-scope, runs once at load)
-- ==========================================================================

if ns.Follower and ns.Follower.OnChange then
    ns.Follower.OnChange(function(state)
        if state and state.questID and state.mapID and state.x and state.y then
            local label = state.questTitle or "Quest"
            if state.objectiveText and state.objectiveText ~= "" then
                label = label .. "  -  " .. state.objectiveText
            end
            Arrow.Track(state.mapID, state.x, state.y, label)
        else
            Arrow.Stop()
        end
    end)
end
