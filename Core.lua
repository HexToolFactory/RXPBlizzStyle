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

--------------------------------------------------------------------------------------------------
-- Debug report: what this addon is working from right now, as text to copy into a bug report.

local function Plain(value)
    if issecretvalue and issecretvalue(value) then return "<secret>" end
    local text = tostring(value)
    -- The edit box would interpret these codes instead of showing them.
    text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", "")
    text = text:gsub("|H.-|h(.-)|h", "%1"):gsub("|n", " "):gsub("\r?\n", " ")
    return text
end

local function AddOnVersion(name)
    local version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(name, "Version")
    return version and Plain(version) or "?"
end

local function ReportHeader(add, rxp)
    local build, buildNumber, _, interface = GetBuildInfo()
    add(("%s %s, RXPGuides %s, client %s.%s (%s)"):format(addonName, AddOnVersion(addonName), AddOnVersion("RXPGuides"),
                                                         Plain(build), Plain(buildNumber), Plain(interface)))
    add(date("%Y-%m-%d %H:%M:%S"))

    local first, last = UnitName("player")
    local _, class = UnitClass("player")
    local race = UnitRace("player")
    add(("%s%s, %s %s, level %s, %s"):format(Plain(first), last and (" " .. Plain(last)) or "", Plain(race), Plain(class),
                                             Plain(UnitLevel("player")), Plain(UnitFactionGroup("player"))))

    local map = C_Map.GetBestMapForUnit("player")
    local position = map and C_Map.GetPlayerMapPosition(map, "player")
    add(("%s / %s, map %s at %s"):format(Plain(GetRealZoneText()), Plain(GetSubZoneText()), Plain(map),
        position and ("%.1f, %.1f"):format(position.x * 100, position.y * 100) or "?"))

    local keys = {}
    for key in pairs(ns.defaults) do keys[#keys + 1] = key end
    table.sort(keys)
    for i, key in ipairs(keys) do keys[i] = key .. "=" .. Plain(ns.db[key]) end
    add("Settings: " .. table.concat(keys, ", "))

    local status = {}
    for _, part in ipairs(parts) do status[#status + 1] = part.name .. "=" .. (part.failed and "FAILED" or "ok") end
    add("Parts: " .. table.concat(status, ", "))
end

local function ReportElement(add, rxp, element)
    local flags = {}
    if element.completed then flags[#flags + 1] = "completed" end
    if element.skip then flags[#flags + 1] = "skipped" end
    if element.optional then flags[#flags + 1] = "optional" end
    if element.textOnly then flags[#flags + 1] = "note" end
    if element.questId then flags[#flags + 1] = "quest " .. Plain(element.questId) end
    if element.x and element.y then
        flags[#flags + 1] = ("goto %s %.1f, %.1f"):format(Plain(element.zone), element.x, element.y)
    end
    local tag = element.tag and Plain(element.tag) or "?"
    local text = ns.ElementText(rxp, element)
    add(("    %s: %s%s"):format(tag, text and Plain(text) or "(no text)",
                                #flags > 0 and " [" .. table.concat(flags, ", ") .. "]" or ""))
end

local function ReportStep(add, rxp)
    local guide = rxp.currentGuide
    if not guide then return add("No guide loaded.") end
    add(("Guide: %s / %s, version %s"):format(Plain(guide.group), Plain(guide.name), Plain(guide.version)))
    add("Guide progress: step " .. Plain(rxp.GetGuideProgress and rxp.GetGuideProgress()))
    local steps = _G.RXPFrame and _G.RXPFrame.activeSteps or {}
    if #steps == 0 then add("No active step.") end
    for _, step in ipairs(steps) do
        add(("  Step %s, id %s: %s"):format(Plain(step.index), Plain(step.stepId), Plain(ns.StepTitle(rxp, step))))
        for _, element in ipairs(step.elements or {}) do ReportElement(add, rxp, element) end
    end
end

local function ReportQuests(add)
    local count = 0
    for i = 1, C_QuestLog.GetNumQuestLogEntries() do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and not info.isHidden then
            count = count + 1
            local done = C_QuestLog.IsComplete(info.questID)
            add(("  %s: %s, level %s%s"):format(Plain(info.questID), Plain(info.title), Plain(info.level),
                                                done and " [complete]" or ""))
            for _, objective in ipairs(C_QuestLog.GetQuestObjectives(info.questID) or {}) do
                add(("    %s %s"):format(objective.finished and "done:" or "open:", Plain(objective.text)))
            end
        end
    end
    if count == 0 then add("  none") end
end

-- A section that fails shows its error in the report instead of taking the whole report with it.
function ns.BuildReport()
    local lines = {}
    local function add(line) lines[#lines + 1] = line end
    local function section(title, build, ...)
        if title then
            add("")
            add(title)
        end
        local ok, err = pcall(build, add, ...)
        if not ok then add("  <error: " .. Plain(err) .. ">") end
    end
    local rxp = ns.GetRXP()
    section(nil, ReportHeader, rxp)
    if rxp then
        section("Current step", ReportStep, rxp)
    else
        add("")
        add("RestedXP is not ready yet.")
    end
    section("Active quests", ReportQuests)
    return table.concat(lines, "\n")
end

local reportFrame

local function ShowText(text)
    reportFrame.text = text
    reportFrame.Edit:SetText(text)
    reportFrame.Edit:SetFocus()
    reportFrame.Edit:HighlightText()
end

local function CreateReportFrame()
    local frame = CreateFrame("Frame", "RXPBlizzStyleReport", UIParent, "BasicFrameTemplateWithInset")
    frame:SetSize(620, 460)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    if frame.TitleText then frame.TitleText:SetText("RestedXP Blizzard Style: debug report") end
    tinsert(UISpecialFrames, "RXPBlizzStyleReport")   -- Escape closes it

    local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    hint:SetPoint("BOTTOMLEFT", 14, 12)
    hint:SetText("Everything is selected: press Ctrl+C to copy.")

    local refresh = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    refresh:SetSize(90, 22)
    refresh:SetPoint("BOTTOMRIGHT", -10, 7)
    refresh:SetText("Refresh")
    refresh:SetScript("OnClick", function() ShowText(ns.BuildReport()) end)

    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -32)
    scroll:SetPoint("BOTTOMRIGHT", -32, 34)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject("ChatFontNormal")
    edit:SetSize(570, 400)
    edit:SetScript("OnEscapePressed", function() frame:Hide() end)
    frame:SetScript("OnHide", function() edit:ClearFocus() end)
    -- Read only: anything typed into it is put back, so the report cannot be changed by accident.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then ShowText(frame.text or "") end
    end)
    scroll:SetScrollChild(edit)
    frame.Edit = edit
    frame:Hide()
    return frame
end

function ns.ShowReport()
    reportFrame = reportFrame or CreateReportFrame()
    reportFrame:Show()
    ShowText(ns.BuildReport())
end

SLASH_RXPBLIZZSTYLE1 = "/rxpstyle"
SlashCmdList.RXPBLIZZSTYLE = function(message)
    if strtrim(message or ""):lower() == "report" then
        ns.ShowReport()
    else
        ns.OpenOptions()
    end
end
