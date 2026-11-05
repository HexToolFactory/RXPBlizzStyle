local addonName, ns = ...

-- The waypoint arrow. RestedXP has no TomTom support, but it keeps the waypoint it is pointing at
-- in arrowFrame.element, so that waypoint can be handed to TomTom's arrow instead. Without TomTom,
-- RestedXP's own arrow stays and only the text below it is replaced by the current step.
local MAX_LINES = 3
local LABEL_WIDTH = 230

local label
local waypoint, waypointKey

-- What the arrow should say for the waypoint it points at.
local function Summary(rxp, element)
    -- Corpse, spirit healer and other waypoints with a name of their own.
    if element.title then return element.title end
    local step = element.step
    if not step then return end
    if step.arrowtext and step.arrowtext ~= "" then return step.arrowtext end
    if not ns.db.arrowText then return ns.StepTitle(rxp, step) end

    -- What is left to do in the step; a step that only has notes (e.g. "run to ...") shows those.
    local todo, notes = {}, {}
    for _, other in ipairs(step.elements or {}) do
        local text = not other.hideTooltip and ns.ElementText(rxp, other)
        if text then
            if other.textOnly then
                notes[#notes + 1] = text
            elseif not (other.completed or other.skip) then
                todo[#todo + 1] = text
            end
        end
    end
    local lines = #todo > 0 and todo or notes
    if #lines == 0 then return ns.StepTitle(rxp, step) end
    return table.concat(lines, "\n", 1, math.min(#lines, MAX_LINES))
end

--------------------------------------------------------------------------------------------------
-- TomTom

local function GetTomTom()
    local tomtom = _G.TomTom
    if ns.db.tomtom and type(tomtom) == "table" and tomtom.AddWaypoint and tomtom.RemoveWaypoint and
        tomtom.profile then
        return tomtom
    end
end

local function ClearWaypoint()
    if waypoint and _G.TomTom then _G.TomTom:RemoveWaypoint(waypoint) end
    waypoint, waypointKey = nil, nil
end

-- Map id and 0-1 map position of a RestedXP waypoint.
local function MapPosition(element)
    if type(element.zone) == "number" and element.x and element.y then
        return element.zone, element.x / 100, element.y / 100
    end
    -- Corpse and spirit healer only come with world coordinates.
    local hbd = LibStub and LibStub("HereBeDragons-2.0", true)
    local zone = hbd and hbd:GetPlayerZone()
    if type(zone) == "number" and element.wx and element.wy then
        local x, y = hbd:GetZoneCoordinatesFromWorld(element.wx, element.wy, zone, true)
        if x and y then return zone, x, y end
    end
end

local function SetWaypoint(tomtom, zone, x, y, title)
    local key = strjoin(":", zone, x, y, title)
    if key == waypointKey then return end
    ClearWaypoint()
    waypointKey = key
    -- RestedXP already draws its own map pins and decides when the step is done.
    waypoint = tomtom:AddWaypoint(zone, x, y, {
        title = title,
        from = addonName,
        persistent = false,
        minimap = false,
        world = false,
        crazy = true,
        cleardistance = 0,
        silent = true,
    })
end

--------------------------------------------------------------------------------------------------
-- RestedXP's arrow

local function ShowLabel(arrow, text)
    if not label then
        label = CreateFrame("Frame", nil, arrow)
        label:SetSize(1, 1)
        label:SetPoint("TOP", arrow, "BOTTOM", 0, -4)
        label.Text = label:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        label.Text:SetPoint("TOP")
        label.Text:SetWidth(LABEL_WIDTH)
        label.Text:SetJustifyH("CENTER")
        label.Distance = label:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label.Distance:SetPoint("TOP", label.Text, "BOTTOM", 0, -2)
    end
    arrow.text:SetAlpha(0)
    label.Text:SetText(text)
    label.Distance:SetFormattedText("%d yd", arrow.distance or 0)
    label:Show()
end

local function HideLabel(arrow)
    arrow.text:SetAlpha(1)
    if label then label:Hide() end
end

--------------------------------------------------------------------------------------------------

local function Disable()
    ClearWaypoint()
    local rxp = _G.RXP
    local arrow = type(rxp) == "table" and rxp.arrowFrame
    if arrow then
        ns.Unstow(arrow)
        HideLabel(arrow)
    end
end

local function Update(rxp)
    local arrow = rxp.arrowFrame
    -- RestedXP shows the arrow frame whenever it has a waypoint to point at.
    local element = arrow:IsShown() and not arrow.wrongContinent and arrow.element or nil
    local text = element and Summary(rxp, element)

    local tomtom = GetTomTom()
    if tomtom then
        ns.Stow(arrow)
        HideLabel(arrow)
        local zone, x, y
        if element then zone, x, y = MapPosition(element) end
        if zone then
            SetWaypoint(tomtom, zone, x, y, text or "")
        else
            ClearWaypoint()
        end
        return
    end

    ClearWaypoint()
    ns.Unstow(arrow)
    if ns.db.arrowText and text then
        ShowLabel(arrow, text)
    else
        HideLabel(arrow)
    end
end

ns.RegisterPart("waypoint arrow", Update, Disable)
