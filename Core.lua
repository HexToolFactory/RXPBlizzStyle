local addonName, ns = ...

-- RestedXP is restyled from the outside: RXPGuides is replaced as a whole on every update, so
-- nothing in its folder is touched. Its addon table is private, but RXPGuides.lua publishes it as
-- the global "RXP" (for debugging), and its windows are the global frames RXPFrame / RXPG_ARROW.
--
-- RestedXP's own windows cannot simply be hidden or switched off: every line of a step is bound
-- to a frame in those windows, and those frames' events and OnUpdate scripts are what detect that
-- a line is done. So the windows stay alive and shown, parked in an invisible holder (see Stow),
-- while this addon draws the same data in its own frames.

ns.defaults = {
    tracker = true,       -- quest tracker style display instead of the RestedXP guide window
    attach = true,        -- keep that display where the quest tracker's next section would be
    limit = true,         -- cut that display off at a line on the screen (RXPBlizzStyleDB.bottom)
    hideQuests = true,    -- hide Blizzard's quest tracker while a guide is shown
    upcoming = 3,         -- how many upcoming steps to list
    arrowText = true,     -- write the current step under the waypoint arrow
    tomtom = true,        -- hand the waypoint to TomTom's arrow when TomTom is loaded
}

local UPDATE_INTERVAL = 0.2

-- Shown but invisible and too small to hover or click: frames parked here keep running.
local holder = CreateFrame("Frame", nil, UIParent)
holder:SetPoint("CENTER")
holder:SetSize(1, 1)
holder:SetScale(0.001)
holder:SetAlpha(0)

local stowed = {}

function ns.Stow(frame)
    if not frame or frame:GetParent() == holder then return end
    if InCombatLockdown() and frame:IsProtected() then return end
    stowed[frame] = stowed[frame] or
        {parent = frame:GetParent(), strata = frame:GetFrameStrata(), level = frame:GetFrameLevel()}
    frame:SetParent(holder)
end

function ns.Unstow(frame)
    local was = frame and stowed[frame]
    if not was then return end
    if InCombatLockdown() and frame:IsProtected() then return end
    stowed[frame] = nil
    if frame:GetParent() ~= holder then return end
    frame:SetParent(was.parent)
    frame:SetFrameStrata(was.strata)
    frame:SetFrameLevel(was.level)
end

local function Print(message)
    print("|cffffd100RestedXP Blizzard Style:|r " .. message)
end
ns.Print = Print

-- The RestedXP addon table once it is far enough along to be read.
function ns.GetRXP()
    local rxp = _G.RXP
    if type(rxp) == "table" and rxp.settings and rxp.settings.profile and rxp.arrowFrame and
        _G.RXPFrame and _G.RXPFrame.activeSteps then
        return rxp
    end
end

-- A line of a step as RestedXP would print it, or nil if the element has no text (yet).
function ns.ElementText(rxp, element)
    local text = element.text
    if type(text) ~= "string" or text == "" or text == " " then return end
    text = rxp.locale.Get(text) or text
    return rxp.ReplaceNpcIds(text, element) or text
end

function ns.StepTitle(rxp, step)
    if step.title and step.title ~= "" then return step.title end
    if step.index then return rxp.locale.Get("Step %d"):format(step.index) end
end

-- Parts that read RestedXP internals run through here: a RestedXP update that changes those
-- internals then switches the part off with one chat line instead of an error on every tick.
local parts = {}

function ns.RegisterPart(name, update, disable)
    parts[#parts + 1] = {name = name, update = update, disable = disable}
end

local function RunParts(rxp)
    for _, part in ipairs(parts) do
        if not part.failed then
            local ok, err = pcall(part.update, rxp)
            if not ok then
                part.failed = true
                pcall(part.disable)
                Print(("the %s was switched off after an error: %s"):format(part.name, tostring(err)))
            end
        end
    end
end

-- Settings changed: redraw now instead of on the next tick.
function ns.Refresh()
    ns.forceRedraw = true
    local rxp = ns.GetRXP()
    if rxp then RunParts(rxp) end
end

local driver = CreateFrame("Frame")
local sinceUpdate = 0

driver:RegisterEvent("ADDON_LOADED")
driver:SetScript("OnEvent", function(self, event, name)
    if name ~= addonName then return end
    self:UnregisterEvent(event)

    RXPBlizzStyleDB = RXPBlizzStyleDB or {}
    for key, value in pairs(ns.defaults) do
        if RXPBlizzStyleDB[key] == nil then RXPBlizzStyleDB[key] = value end
    end
    ns.db = RXPBlizzStyleDB
    ns.InitOptions()

    self:SetScript("OnUpdate", function(_, elapsed)
        sinceUpdate = sinceUpdate + elapsed
        if sinceUpdate < UPDATE_INTERVAL then return end
        sinceUpdate = 0
        local rxp = ns.GetRXP()
        if rxp then RunParts(rxp) end
    end)
end)

SLASH_RXPBLIZZSTYLE1 = "/rxpstyle"
SlashCmdList.RXPBLIZZSTYLE = function() ns.OpenOptions() end
