-- Vellum/Arrow.lua
-- Wax-seal compass: a brass-rimmed circular pointer with a wax-red chevron
-- rotating inside on a parchment-toned disc, with a small ink emblem at the
-- pivot and parchment-cream labels below. Auto-tracks Vellum.Follower.
--
-- Uses stable Blizzard texture paths (not atlases) for ring + chevron so we
-- don't rely on atlas names that might rename between patches.
--
-- Public API:
--   Vellum.Arrow.Track(mapID, x, y, label, source)
--   Vellum.Arrow.Stop()
--   Vellum.Arrow.Center()
--   Vellum.Arrow.SetSize(px)
--   Vellum.Arrow.IsShown()

local ADDON, ns = ...
ns.Arrow = ns.Arrow or {}
local Arrow = ns.Arrow

-- ==========================================================================
-- Constants
-- ==========================================================================

local DEFAULT_SIZE    = 96
local UPDATE_INTERVAL = 0.05
local ROT_LERP_RATE   = 12
local ARRIVAL_YARDS   = 25

local PARCHMENT_RGB = { 0.92, 0.86, 0.69 }
local INK_RGB       = { 0.25, 0.18, 0.10 }    -- used on the parchment disc
local TEXT_RGB      = { 0.95, 0.90, 0.72 }    -- parchment-cream for off-disc text

-- Pointer color stops by distance (yards), used for precise sources.
local POINTER_STOPS = {
    { d = 0,             r = 0.30, g = 0.85, b = 0.30 },
    { d = ARRIVAL_YARDS, r = 0.85, g = 0.18, b = 0.10 },
    { d = 200,           r = 0.55, g = 0.12, b = 0.10 },
    { d = 1000,          r = 0.40, g = 0.10, b = 0.10 },
}

-- Muted tint when the destination came from a low-confidence "codex-zone"
-- fallback. Faded sepia red (NOT parchment-brown -- that blends into the
-- disc behind the chevron); reads as "rough hint."
local MUTED_RGB = { 0.55, 0.30, 0.30 }

local MUTED_SOURCES = {
    ["codex-zone"] = true,
}

-- Stable Blizzard texture paths.
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- Bundled Material Symbols glyphs, rendered to 128x128 RGBA TGAs at design
-- time. White pixels on transparent background so SetVertexColor tints them
-- any color we want.
--
--   arrow_pointer = Material "navigation" (filled). Triangular paper-plane
--                   shape, the canonical "you are facing this way" compass
--                   needle. Replaces a previous Material "arrow_shape_up"
--                   bake which read more as "stylized house."
--   ring          = Material "circle" (outlined, default variant). A clean
--                   centered ring outline. Replaces Blizzard's
--                   MiniMap-TrackingBorder which had calendar/tracking
--                   notches baked in and looked off-center when used as a
--                   plain ring.
--
-- Both have Blizzard fallbacks for the (rare) case the asset folder didn't
-- ship -- the addon stays usable, just visually less branded.
local POINTER_TEXTURE          = "Interface\\AddOns\\Vellum\\Assets\\arrow_pointer"
local POINTER_TEXTURE_FALLBACK = "Interface\\Minimap\\MinimapArrow"
local RING_TEXTURE             = "Interface\\AddOns\\Vellum\\Assets\\ring"
local RING_TEXTURE_FALLBACK    = "Interface\\Common\\common-iconframe"

-- Brass tint for the ring. Warm gold so it reads as "metal frame."
local RING_TINT = { 0.90, 0.70, 0.25, 1 }

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

-- ==========================================================================
-- Frame state
-- ==========================================================================

local frame
local destination
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
        local okMask = pcall(mask.SetTexture, mask, CIRCLE_MASK,
            "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        if okMask then frame.disc:AddMaskTexture(mask) end
    end

    -- Layer 2: brass ring. Bundled Material Symbols "circle" outline,
    -- tinted brass via SetVertexColor. Sized to the full frame so the
    -- ring traces the disc's edge.
    frame.ring = frame:CreateTexture(nil, "BORDER")
    frame.ring:SetAllPoints(frame)
    pcall(frame.ring.SetTexture, frame.ring, RING_TEXTURE)
    if not (frame.ring:GetTexture() and frame.ring:GetTexture() ~= "") then
        pcall(frame.ring.SetTexture, frame.ring, RING_TEXTURE_FALLBACK)
    end
    frame.ring:SetVertexColor(
        RING_TINT[1], RING_TINT[2], RING_TINT[3], RING_TINT[4])

    -- Layer 3: rotating compass needle (Material Symbols "navigation"
    -- filled, bundled at Vellum/Assets/arrow_pointer.tga).
    frame.pointer = frame:CreateTexture(nil, "ARTWORK")
    frame.pointer:SetSize(DEFAULT_SIZE * 0.55, DEFAULT_SIZE * 0.55)
    frame.pointer:SetPoint("CENTER", frame, "CENTER", 0, 0)
    pcall(frame.pointer.SetTexture, frame.pointer, POINTER_TEXTURE)
    -- If the bundled asset failed to load, the texture's GetTexture is nil
    -- (or empty); fall back to Blizzard's stable MinimapArrow path.
    if not (frame.pointer:GetTexture() and frame.pointer:GetTexture() ~= "") then
        pcall(frame.pointer.SetTexture, frame.pointer, POINTER_TEXTURE_FALLBACK)
    end
    frame.pointer:SetVertexColor(0.55, 0.13, 0.16)

    -- Layer 4: tiny ink dot at the pivot. Small enough that the chevron's
    -- arms still poke past it.
    frame.emblem = frame:CreateTexture(nil, "OVERLAY")
    frame.emblem:SetSize(DEFAULT_SIZE * 0.08, DEFAULT_SIZE * 0.08)
    frame.emblem:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame.emblem:SetColorTexture(INK_RGB[1], INK_RGB[2], INK_RGB[3], 1)

    -- Layer 5: parchment-cream label + distance below the frame, so they
    -- read against any world background.
    frame.label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.label:SetPoint("TOP", frame, "BOTTOM", 0, -2)
    frame.label:SetWidth(DEFAULT_SIZE * 2.6)
    frame.label:SetWordWrap(false)
    frame.label:SetTextColor(TEXT_RGB[1], TEXT_RGB[2], TEXT_RGB[3])
    if frame.label.SetShadowOffset then
        frame.label:SetShadowOffset(1, -1)
        frame.label:SetShadowColor(0, 0, 0, 1)
    end

    frame.distance = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.distance:SetPoint("TOP", frame.label, "BOTTOM", 0, -1)
    frame.distance:SetTextColor(TEXT_RGB[1], TEXT_RGB[2], TEXT_RGB[3])
    if frame.distance.SetShadowOffset then
        frame.distance:SetShadowOffset(1, -1)
        frame.distance:SetShadowColor(0, 0, 0, 1)
    end

    -- Pulse animation on waypoint change.
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

    if MUTED_SOURCES[destination.source or ""] then
        frame.pointer:SetVertexColor(MUTED_RGB[1], MUTED_RGB[2], MUTED_RGB[3])
    else
        local r, g, b = pointerColor(dist)
        frame.pointer:SetVertexColor(r, g, b)
    end
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

function Arrow.Track(mapID, x, y, label, source)
    if type(mapID) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return false, "Track requires numeric mapID, x, y."
    end
    buildFrame()

    local same = destination
        and destination.mapID == mapID
        and math.abs((destination.x or 0) - x) < 0.0001
        and math.abs((destination.y or 0) - y) < 0.0001

    destination = { mapID = mapID, x = x, y = y, label = label or "", source = source }
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
    frame.emblem:SetSize(px * 0.08, px * 0.08)
    frame.label:SetWidth(px * 2.6)
    return px
end

function Arrow.IsShown()
    return (frame and frame:IsShown()) or false
end

-- ==========================================================================
-- Auto-wire to RoutePlanner (Phase 3C)
-- The arrow now points at route[1] of the planner's current route. Empty
-- route -> arrow hides. The planner debounces its own recalc bus so we
-- just react to OnRouteChanged here.
--
-- Legacy single-quest Follower.OnChange wire is intentionally removed:
-- /vellum follow X still mutates Follower.state but doesn't drive the
-- arrow anymore. The planner sees the same world state and picks the
-- best next waypoint across all candidates. To force a specific quest as
-- next, a future "pin" feature will inject it at the head of the route.
-- ==========================================================================

local function trackHead(route)
    if not route or #route == 0 then
        Arrow.Stop()
        return
    end
    local wp = route[1]
    if not (wp and wp.mapID and wp.x and wp.y) then
        Arrow.Stop()
        return
    end

    -- Build a label that's compact enough to fit under the disc but still
    -- communicates the action. Format: "<type>: <title> -- <objText>".
    local title = wp.title or ("Quest " .. tostring(wp.questID))
    local label = title
    if wp.type == "PICKUP" then
        label = "Pick up: " .. title
    elseif wp.type == "TURNIN" then
        label = "Turn in: " .. title
    elseif wp.type == "OBJECTIVE" and wp.objText and wp.objText ~= "" then
        label = title .. "  -  " .. wp.objText
    end

    Arrow.Track(wp.mapID, wp.x, wp.y, label, wp.source)
end

if ns.RoutePlanner and ns.RoutePlanner.OnRouteChanged then
    ns.RoutePlanner.OnRouteChanged(trackHead)

    -- Seed the arrow on login (planner already subscribes to
    -- PLAYER_ENTERING_WORLD so it'll Recompute; the resulting OnRouteChanged
    -- will fire trackHead for the initial state).
end
