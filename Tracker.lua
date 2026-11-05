local addonName, ns = ...

-- The guide drawn like a section of Blizzard's quest tracker: a header bar with the guide's name,
-- the active steps as "quests" with their lines as objectives, and a second section with the
-- upcoming steps. Measurements are those of Blizzard_ObjectiveTracker (module, block, line).
local WIDTH = 260
local HEADER_HEIGHT = 25
local BLOCK_INDENT = 20
local BLOCK_GAP = 10
local LINE_GAP = 4
local MODULE_GAP = 10
local MAX_UPCOMING_SCAN = 400
local DEFAULT_WINDOW = 350

local COLORS = {
    title = {"Header", 0.75, 0.61, 0},
    titleHover = {"HeaderHighlight", 1, 0.82, 0},
    line = {"Normal", 0.8, 0.8, 0.8},
    lineHover = {"NormalHighlight", 1, 1, 1},
    done = {"Complete", 0.6, 0.6, 0.6},
    missing = {"Failed", 0.8, 0.1, 0.1},
    missingHover = {"FailedHighlight", 1, 0.1, 0.1},
}

local function TrackerColor(key)
    local name, r, g, b = unpack(COLORS[key])
    local color = OBJECTIVE_TRACKER_COLOR and OBJECTIVE_TRACKER_COLOR[name]
    if color then return color.r, color.g, color.b end
    return r, g, b
end

local root, activeHeader, upcomingHeader, wheelArea, grip
local gripDragging = false
local drawFloor   -- how far down rows may reach (a negative offset from the top), nil = no limit
local rows = {}
local dashWidth
local lastSignature
local scrollOffset, scrollStep = 0, nil
local listIsFull = false
local hoveredBlock

--------------------------------------------------------------------------------------------------
-- Clicks and tooltips

local function ShowStepMenu(rxp, index)
    local menu = RXPFrame.bottomMenu
    if not (index and menu and menu[1]) then return RXPFrame.DropDownMenu() end
    -- Same as a right-click on a step in RestedXP's own list.
    local L = rxp.locale.Get
    menu[1].text = L("Go to step") .. " " .. index
    menu[1].arg1 = index
    for _, item in ipairs(menu) do
        if item.text == L("Give Feedback for step") then item.arg1 = index end
    end
    rxp:ShowMenu(menu, RXPFrame.MenuFrame, "cursor", 0, 0, "MENU")
end

-- What ticking the checkbox next to a line does in RestedXP's window.
local function ToggleSkip(rxp, element)
    local skip = not element.skip
    if not element.optional then
        if element.OnComplete and skip then element.OnComplete(element) end
        element.skip = skip
    end
    local checkbox = element.frame and element.frame.button
    if checkbox and checkbox.SetChecked then checkbox:SetChecked(skip) end
    rxp.updateSteps = true
    rxp.UpdateMap()
end

local function Row_OnClick(row, button)
    local rxp = ns.GetRXP()
    if not rxp then return end
    if button == "RightButton" then
        ShowStepMenu(rxp, row.index)
    elseif IsShiftKeyDown() then
        if row.upcoming then
            if row.index then rxp.SetStep(row.index) end
        elseif row.element and row.state ~= "note" then
            ToggleSkip(rxp, row.element)
        end
        ns.Refresh()
    end
end

-- The dash or check mark in front of a line works as its checkbox.
local function Toggle_OnClick(toggle)
    local rxp = ns.GetRXP()
    local row = toggle:GetParent()
    if not rxp or not row.element then return end
    ToggleSkip(rxp, row.element)
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    ns.Refresh()
end

local function ColorRow(row)
    local hover = row.block == hoveredBlock
    if row.kind == "title" then
        row.Text:SetTextColor(TrackerColor(hover and "titleHover" or "title"))
    elseif row.state == "done" then
        row.Text:SetTextColor(TrackerColor("done"))
    elseif row.missing then
        row.Text:SetTextColor(TrackerColor(hover and "missingHover" or "missing"))
        row.Dash:SetTextColor(TrackerColor(hover and "missingHover" or "missing"))
    else
        row.Text:SetTextColor(TrackerColor(hover and "lineHover" or "line"))
        row.Dash:SetTextColor(TrackerColor(hover and "lineHover" or "line"))
    end
end

local function SetHoveredBlock(block)
    hoveredBlock = block
    for _, row in ipairs(rows) do
        if row:IsShown() then ColorRow(row) end
    end
end

local function Row_OnEnter(row)
    SetHoveredBlock(row.block)
    local tooltip = row.element and row.element.tooltip
    if type(tooltip) ~= "string" or tooltip == "" then tooltip = nil end
    if tooltip or row.missing then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        if tooltip then GameTooltip:AddLine(tooltip, 1, 1, 1, true) end
        if row.missing then GameTooltip:AddLine("You do not have this quest.", 1, 0.1, 0.1) end
        GameTooltip:Show()
    end
end

local function Row_OnLeave(row)
    if hoveredBlock == row.block then SetHoveredBlock(nil) end
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
end

-- The step before `from` that can become the current step again: sticky steps never are, hidden
-- ones are helper steps of the guide.
local function PreviousStep(guide, from)
    local level = UnitLevel("player")
    for index = from - 1, 1, -1 do
        local step = guide.steps[index]
        if not (step.sticky or step.hidewindow or step.hidetip or step.optional or
            (step.level and step.level > level)) then
            return index
        end
    end
end

-- Guides are told apart by group and name, the way RestedXP's own guide table is keyed.
local function GuideId(guide) return (guide.group or "") .. "||" .. (guide.name or "") end

-- Does the "#next" line of `guide` name `target`? It lists one or more guides separated by ";",
-- each optionally as "group\name"; single-digit level ranges are written without the leading zero
-- that RestedXP adds to guide names.
local function LeadsTo(rxp, guide, target)
    if type(guide.next) ~= "string" then return false end
    for part in guide.next:gmatch("[^;]+") do
        local group, name = part:match("^%s*(.+)\\%s*(.-)%s*$")
        if not group then group, name = guide.group, part:match("^%s*(.-)%s*$") end
        if type(rxp.affix) == "function" then name = name:gsub("^(%d)-(%d%d?)", rxp.affix) end
        if name == target.name and group == target.group then return true end
    end
    return false
end

-- The guide that comes before `target`: one whose "#next" leads to it. Several can (one per
-- starting zone); the one this character has progress in wins, then one that applies to it.
local function PreviousGuide(rxp, target)
    local progress = RXPCData and RXPCData.guideProgress or {}
    local best, bestRank
    for _, guide in pairs(rxp.guides or {}) do
        if type(guide) == "table" and guide ~= target and not guide.internal and not guide.disabled and
            GuideId(guide) ~= GuideId(target) and LeadsTo(rxp, guide, target) then
            local rank = (guide.key and progress[guide.key]) and 3 or (rxp.IsGuideActive(guide) and 2 or 1)
            if not best or rank > bestRank then best, bestRank = guide, rank end
        end
    end
    return best
end

-- RestedXP skips steps on its own when it decides they do not apply (wrong level, quest not in the
-- log, ...), and would skip them again the moment one is stepped back to. Its setting "Disable
-- step skips" stops that, so stepping back switches the setting on until the guide is back at the
-- step the walk back started from. ns.db.hold survives a reload, so the setting is not left on.
--   hold = {guide = id of the guide the walk started in, origin = step it started at,
--           earlier = ids of the guides before it that were walked back into}
local function HoldSkips(rxp, guide, origin)
    local hold = ns.db.hold
    if hold then
        if hold.guide == GuideId(guide) then
            hold.origin = math.max(hold.origin, origin)
        else
            hold.earlier = hold.earlier or {}
            hold.earlier[GuideId(guide)] = true
        end
        return
    end
    local profile = rxp.settings.profile
    if profile.disableAutoSkip then return end
    ns.db.hold = {guide = GuideId(guide), origin = origin}
    profile.disableAutoSkip = true
    ns.Print(("RestedXP will not skip steps on its own until you are back at step %d of this guide."):format(origin))
end

-- A step that is already done (quest accepted, objective complete) cannot be stayed on: RestedXP
-- ticks it off again at once and returns to where it was. So the back arrow remembers the step it
-- went to last, and for BACK_WINDOW seconds the next click continues from there instead of from
-- RestedXP's position. Repeated clicks thus walk back past any number of finished steps, also when
-- RestedXP has meanwhile gone on into the next guide.
local BACK_WINDOW = 15
local BOUNCE_TIME = 3
local backCursor   -- {id, group, name = guide of the last target, step = that target, at = GetTime(), watching}

local function WalkingBack()
    return backCursor and GetTime() - backCursor.at < BACK_WINDOW
end

local function UpdateHold(rxp, guide)
    -- No guide at all is the moment after login, before RestedXP has loaded it.
    if not guide then return end
    local id = GuideId(guide)
    local current = rxp.GetGuideProgress()

    if backCursor and backCursor.watching then
        if id ~= backCursor.id or current > backCursor.step then
            backCursor.watching = false
            if WalkingBack() then
                ns.Print(("Step %d is already done. Click the arrow again to go back further."):format(backCursor.step))
            end
        elseif GetTime() - backCursor.at > BOUNCE_TIME then
            backCursor.watching = false
        end
    end

    local hold = ns.db.hold
    if not hold then return end
    if WalkingBack() then return end
    if not guide.empty and ((id == hold.guide and current < hold.origin) or (hold.earlier and hold.earlier[id])) then return end
    ns.db.hold = nil
    rxp.settings.profile.disableAutoSkip = false
    ns.Print("RestedXP skips steps on its own again.")
end

local function StepBack(rxp)
    local guide = rxp.currentGuide
    local origin = rxp.GetGuideProgress()
    local from = origin

    if WalkingBack() then
        if backCursor.id == GuideId(guide) then
            from = math.min(from, backCursor.step)
        else
            -- RestedXP has gone on into the next guide: return to the one the walk was in.
            local earlier = rxp.GetGuideTable(backCursor.group, backCursor.name)
            if earlier then
                HoldSkips(rxp, guide, origin)
                rxp:LoadGuide(earlier)
                guide = rxp.currentGuide
                if not guide or guide.empty or GuideId(guide) ~= backCursor.id then return end
                from = backCursor.step
            end
        end
    end

    local target = PreviousStep(guide, from)
    if not target then
        -- Before the first step: go on in the guide that leads to this one.
        local previous = PreviousGuide(rxp, guide)
        if not previous then return ns.Print("This is the first step, and no guide leads to this one.") end
        HoldSkips(rxp, guide, origin)
        rxp:LoadGuide(previous)
        guide = rxp.currentGuide
        if not guide or guide.empty or GuideId(guide) ~= GuideId(previous) then return end
        target = PreviousStep(guide, #guide.steps + 1)
        if not target then return end
        ns.Print(("Went back into the guide \"%s\"."):format(guide.name or "?"))
    end

    HoldSkips(rxp, guide, origin)
    backCursor = {id = GuideId(guide), group = guide.group, name = guide.name, step = target, at = GetTime(), watching = true}
    rxp.SetStep(target)
end

local function StepButton_OnClick(button)
    local rxp = ns.GetRXP()
    local guide = rxp and rxp.currentGuide
    if not guide or guide.empty then return end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    if button.direction < 0 then
        StepBack(rxp)
    else
        backCursor = nil
        rxp.SetStep(rxp.GetGuideProgress() + 1)
    end
    ns.Refresh()
end

local function StepButton_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine(button.direction < 0 and "Previous step" or "Next step", 1, 1, 1)
    if button.direction < 0 then
        GameTooltip:AddLine("Also stops RestedXP from skipping steps on its own until you are back where you started.",
            0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("A step that is already done jumps forward again: keep clicking to go back past it.",
            0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("On the first step it goes on in the guide that comes before this one.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
end

local function CreateStepButton(header, direction, anchor)
    local page = direction < 0 and "Prev" or "Next"
    local button = CreateFrame("Button", nil, header)
    button.direction = direction
    button:SetSize(18, 18)
    button:SetPoint("RIGHT", anchor, "LEFT", 0, 0)
    button:SetNormalTexture("Interface/Buttons/UI-SpellbookIcon-" .. page .. "Page-Up")
    button:SetPushedTexture("Interface/Buttons/UI-SpellbookIcon-" .. page .. "Page-Down")
    button:SetHighlightTexture("Interface/Buttons/UI-Common-MouseHilight", "ADD")
    button:SetScript("OnClick", StepButton_OnClick)
    button:SetScript("OnEnter", StepButton_OnEnter)
    button:SetScript("OnLeave", GameTooltip_Hide)
    return button
end

local function Header_OnEnter(header)
    GameTooltip:SetOwner(header, "ANCHOR_LEFT")
    GameTooltip:AddLine(header.tooltipTitle or header.Text:GetText(), 1, 1, 1)
    GameTooltip:AddLine("Right-click: guides and RestedXP options", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click a step: step menu", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Click the dash in front of a line: tick it off", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Shift-click an upcoming step: jump to it", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Arrows: previous / next step", 0.8, 0.8, 0.8)
    if not ns.db.attach then GameTooltip:AddLine("Drag: move", 0.8, 0.8, 0.8) end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------------------------
-- Frames

local function SetCollapseButton(button, collapsed)
    local state = collapsed and "expand" or "collapse"
    button:SetNormalAtlas("ui-questtrackerbutton-secondary-" .. state)
    button:SetPushedAtlas("ui-questtrackerbutton-secondary-" .. state .. "-pressed")
end

-- Looks like ObjectiveTrackerModuleHeaderTemplate; collapseKey is the saved setting it toggles.
local function CreateHeader(collapseKey)
    local header = CreateFrame("Button", nil, root)
    header:SetSize(WIDTH, HEADER_HEIGHT + 1)
    header:RegisterForClicks("RightButtonUp")
    header:RegisterForDrag("LeftButton")

    header.Background = header:CreateTexture(nil, "BACKGROUND")
    header.Background:SetAtlas("UI-QuestTracker-Secondary-Objective-Header", true)
    header.Background:SetPoint("CENTER")

    header.Text = header:CreateFontString(nil, "ARTWORK",
        ObjectiveTrackerHeaderFont and "ObjectiveTrackerHeaderFont" or "GameFontNormalMed2")
    header.Text:SetPoint("LEFT", 7, 0)
    header.Text:SetWidth(WIDTH - 60)
    header.Text:SetJustifyH("LEFT")
    header.Text:SetWordWrap(false)

    header.Collapse = CreateFrame("Button", nil, header)
    header.Collapse:SetSize(16, 16)
    header.Collapse:SetPoint("RIGHT", 1, 0)
    header.Collapse:SetHighlightAtlas("ui-questtrackerbutton-yellow-highlight", "ADD")
    header.Collapse:SetScript("OnClick", function()
        ns.db[collapseKey] = not ns.db[collapseKey]
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        ns.Refresh()
    end)

    header:SetScript("OnClick", function() RXPFrame.DropDownMenu() end)
    header:SetScript("OnEnter", Header_OnEnter)
    header:SetScript("OnLeave", GameTooltip_Hide)
    header:SetScript("OnDragStart", function()
        if ns.db.attach then return end
        root.moving = true
        root:StartMoving()
    end)
    header:SetScript("OnDragStop", function()
        if not root.moving then return end
        root:StopMovingOrSizing()
        root.moving = nil
        ns.db.position = {left = root:GetLeft(), top = root:GetTop()}
        root.placedAt = nil
    end)
    return header
end

local function CreateRow()
    local font = ObjectiveTrackerLineFont and "ObjectiveTrackerLineFont" or "GameFontHighlight"
    local row = CreateFrame("Button", nil, root)
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.Dash = row:CreateFontString(nil, "ARTWORK", font)
    row.Dash:SetPoint("TOPLEFT", 0, 1)
    row.Dash:SetText(QUEST_DASH or "- ")

    row.Check = row:CreateTexture(nil, "ARTWORK")
    row.Check:SetAtlas("ui-questtracker-tracker-check")
    row.Check:SetSize(16, 16)
    row.Check:SetPoint("TOPLEFT", -10, 2)

    -- Covers the dash and the check mark; hovering previews the check mark.
    row.Toggle = CreateFrame("Button", nil, row)
    row.Toggle:SetPoint("TOPLEFT", -10, 2)
    row.Toggle:SetSize(10 + dashWidth, 16)
    local preview = row.Toggle:CreateTexture(nil, "HIGHLIGHT")
    preview:SetAtlas("ui-questtracker-tracker-check")
    preview:SetSize(16, 16)
    preview:SetPoint("TOPLEFT")
    preview:SetAlpha(0.6)
    row.Toggle:SetScript("OnClick", Toggle_OnClick)
    row.Toggle:SetScript("OnEnter", function() Row_OnEnter(row) end)
    row.Toggle:SetScript("OnLeave", function() Row_OnLeave(row) end)

    row.Text = row:CreateFontString(nil, "ARTWORK", font)
    row.Text:SetJustifyH("LEFT")
    row.Text:SetJustifyV("TOP")
    row.Text:SetWordWrap(true)

    row:SetScript("OnClick", Row_OnClick)
    row:SetScript("OnEnter", Row_OnEnter)
    row:SetScript("OnLeave", Row_OnLeave)
    return row
end

local function Build()
    root = CreateFrame("Frame", "RXPBlizzStyleTracker", UIParent)
    root:SetFrameStrata("LOW")
    root:SetSize(WIDTH, HEADER_HEIGHT)
    root:SetMovable(true)
    root:SetClampedToScreen(true)
    root:Hide()

    activeHeader = CreateHeader("activeCollapsed")
    activeHeader.Next = CreateStepButton(activeHeader, 1, activeHeader.Collapse)
    activeHeader.Previous = CreateStepButton(activeHeader, -1, activeHeader.Next)
    activeHeader.Report = CreateFrame("Button", nil, activeHeader)
    activeHeader.Report:SetSize(16, 16)
    activeHeader.Report:SetPoint("RIGHT", activeHeader.Previous, "LEFT", -2, 0)
    activeHeader.Report:SetNormalFontObject("GameFontNormal")
    activeHeader.Report:SetHighlightFontObject("GameFontHighlight")
    activeHeader.Report:SetText("?")
    activeHeader.Report:SetScript("OnClick", function() ns.ShowReport() end)
    activeHeader.Report:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Debug report", 1, 1, 1)
        GameTooltip:AddLine("Shows the current step and active quests, ready to copy.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    activeHeader.Report:SetScript("OnLeave", GameTooltip_Hide)
    activeHeader.Text:SetWidth(WIDTH - 114)
    upcomingHeader = CreateHeader("upcomingCollapsed")
    upcomingHeader.Text:SetText("Upcoming Steps")

    -- The mouse wheel over the upcoming steps pages through the rest of the guide.
    wheelArea = CreateFrame("Frame", nil, root)
    wheelArea:EnableMouseWheel(true)
    wheelArea:SetScript("OnMouseWheel", function(_, delta)
        if delta < 0 and not listIsFull then return end
        scrollOffset = math.max(0, scrollOffset - delta)
        ns.Refresh()
    end)

    -- The lower end of the guide's window (option "Cut the guide off at a line"): a line across the
    -- guide that is dragged up and down. It only shows while the mouse is on the guide.
    grip = CreateFrame("Button", nil, root)
    grip:SetFrameStrata("MEDIUM")
    grip:SetSize(WIDTH, 12)
    local line = grip:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.9)
    line:SetHeight(2)
    line:SetPoint("LEFT")
    line:SetPoint("RIGHT")
    grip:SetScript("OnMouseDown", function() gripDragging = true end)
    grip:SetScript("OnMouseUp", function() gripDragging = false end)
    grip:SetScript("OnUpdate", function()
        if not gripDragging then return end
        local _, y = GetCursorPosition()
        ns.db.bottom = math.max(0, y / root:GetEffectiveScale())
        ns.Refresh()
    end)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Drag: where the guide gets cut off", 1, 1, 1)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", GameTooltip_Hide)
    grip:Hide()

    local measure = root:CreateFontString(nil, "ARTWORK",
        ObjectiveTrackerLineFont and "ObjectiveTrackerLineFont" or "GameFontHighlight")
    measure:SetText(QUEST_DASH or "- ")
    dashWidth = measure:GetStringWidth()
    if not dashWidth or dashWidth < 4 then dashWidth = 10 end
    measure:Hide()
end

--------------------------------------------------------------------------------------------------
-- What to show

-- The slider of the settings panel may hand back a fraction.
local function UpcomingCount()
    return math.floor((tonumber(ns.db.upcoming) or 0) + 0.5)
end

local function AddToSignature(signature, ...)
    for i = 1, select("#", ...) do
        signature[#signature + 1] = tostring((select(i, ...)))
    end
end

-- Lines that work on or hand in a quest are of no use without the quest: an earlier step, maybe
-- of an earlier guide, was meant to pick it up. Those lines are drawn in red.
local QUEST_NEEDED = {complete = true, turnin = true}

local function NeedsQuest(element)
    if not element.questId or element.questId <= 0 then return false end
    if QUEST_NEEDED[element.tag] then return true end
    -- ".collect item,count,quest" names a quest for two reasons. With objective flags the item is
    -- an objective of that quest; without them the item is gathered ahead of the quest (or starts it).
    return element.tag == "collect" and (element.objFlags or 0) ~= 0
end

-- The steps of a guide that pick a quest up: {[questId] = {step index, ...}}
local acceptSteps, acceptStepsGuide

local function AcceptSteps(guide)
    if acceptStepsGuide ~= guide then
        acceptSteps, acceptStepsGuide = {}, guide
        for index, step in ipairs(guide.steps) do
            for _, element in ipairs(step.elements or {}) do
                if element.tag == "accept" and element.questId then
                    acceptSteps[element.questId] = acceptSteps[element.questId] or {}
                    table.insert(acceptSteps[element.questId], index)
                end
            end
        end
    end
    return acceptSteps
end

local function AcceptedBetween(guide, questId, first, last)
    for _, index in ipairs(AcceptSteps(guide)[questId] or {}) do
        if index >= first and index <= last then return true end
    end
    return false
end

-- stepIndex: the step the line belongs to, current: where the guide is.
local function QuestMissing(rxp, guide, element, stepIndex, current)
    if not NeedsQuest(element) then return false end
    local id = rxp.GetQuestId(element.questId, nil, true) or element.questId
    if rxp.IsOnQuest(id) or rxp.IsQuestTurnedIn(id) then return false end
    -- No problem as long as the guide still gets to the step that picks the quest up.
    if stepIndex then
        local first = math.min(current, stepIndex)
        if AcceptedBetween(guide, element.questId, first, stepIndex) or AcceptedBetween(guide, id, first, stepIndex) then
            return false
        end
    end
    return true
end

local function ActiveBlocks(rxp, signature)
    local blocks = {}
    local guide, current = rxp.currentGuide, rxp.GetGuideProgress()
    for _, step in ipairs(RXPFrame.activeSteps) do
        if step.active and not step.hidewindow and not step.hidetip then
            local block = {index = step.index, lines = {}}
            if not step.sticky or step.title then block.title = ns.StepTitle(rxp, step) end
            AddToSignature(signature, "step", step.index, block.title)
            for _, element in ipairs(step.elements or {}) do
                local text = ns.ElementText(rxp, element)
                if text then
                    local icon = element.tag and (element.icon or rxp.icons[element.tag])
                    icon = icon and icon .. " " or ""
                    local state = element.textOnly and "note" or
                                      ((element.completed or element.skip) and "done" or "todo")
                    local missing = state == "todo" and QuestMissing(rxp, guide, element, step.index, current)
                    block.lines[#block.lines + 1] = {text = icon .. text, state = state, element = element, missing = missing}
                    AddToSignature(signature, state, icon, text, missing)
                end
            end
            if block.title or #block.lines > 0 then blocks[#blocks + 1] = block end
        end
    end
    return blocks
end

-- Steps that are not active yet carry their text as written in the guide file.
local function GuideText(rxp, text, element)
    text = rxp.locale.Get(text) or text
    text = rxp.ReplaceNpcIds(text, element) or text
    local ok, colored = pcall(rxp.settings.ReplaceColors, text)
    return ok and colored or text
end

-- Same choice of lines as RestedXP's step list (v2:BuildGuideStepsSnapshot).
local function UpcomingLines(rxp, guide, step, index, current)
    local lines
    for _, element in ipairs(step.elements or {}) do
        local text
        local state = "note"
        if element.text and element.text ~= "" and element.text ~= " " then
            local icon = element.icon or rxp.icons[element.tag]
            text = (icon and icon .. " " or "") .. GuideText(rxp, element.text, element)
            if not element.textOnly then state = "todo" end
        elseif element.tooltipText and element.tooltipText ~= "" then
            text = GuideText(rxp, element.tooltipText, element)
        elseif element.rawtext and element.rawtext ~= "" then
            text = GuideText(rxp, element.rawtext, element)
        end
        if text and not element.hideTooltip then
            lines = lines or {}
            -- Objectives of a step that is not active yet have no text of their own and count as
            -- notes here, so the quest check does not depend on the state.
            lines[#lines + 1] = {text = text, state = state, missing = QuestMissing(rxp, guide, element, index, current)}
        end
    end
    return lines
end

local function UpcomingBlocks(rxp, guide, signature)
    local blocks = {}
    local count = UpcomingCount()
    if count <= 0 or ns.db.upcomingCollapsed then return blocks end

    local current = rxp.GetGuideProgress()
    if scrollStep ~= current then scrollStep, scrollOffset = current, 0 end

    local level = UnitLevel("player")
    local skipped = RXPCData and RXPCData.stepSkip or {}
    local steps = guide.steps
    local seen = 0
    for index = current + 1, math.min(#steps, current + MAX_UPCOMING_SCAN) do
        local step = steps[index]
        if not (step.active or step.completed or skipped[index] or step.hidewindow or step.hidetip or
            step.optional or (step.level and step.level > level)) then
            local lines = UpcomingLines(rxp, guide, step, index, current)
            if lines then
                seen = seen + 1
                if seen > scrollOffset then
                    local title = step.title and step.title ~= "" and GuideText(rxp, step.title) or
                                      rxp.locale.Get("Step %d"):format(index)
                    blocks[#blocks + 1] = {index = index, title = title, lines = lines, upcoming = true}
                    AddToSignature(signature, "next", index, title)
                    for _, line in ipairs(lines) do AddToSignature(signature, line.text, line.missing) end
                    if #blocks == count then break end
                end
            end
        end
    end
    -- Scrolled past the end (the guide moved on): show the last page instead of nothing.
    if #blocks == 0 and scrollOffset > 0 then
        scrollOffset = math.max(0, seen - 1)
        ns.forceRedraw = true
    end
    return blocks
end

--------------------------------------------------------------------------------------------------
-- Drawing

local usedRows, nextBlock

local function PlaceRow(kind, line, block, y)
    usedRows = usedRows + 1
    local row = rows[usedRows]
    if not row then
        row = CreateRow()
        rows[usedRows] = row
    end

    row.kind, row.block, row.index, row.upcoming = kind, nextBlock, block.index, block.upcoming
    row.state = kind == "line" and line.state or nil
    row.element = kind == "line" and line.element or nil
    row.missing = kind == "line" and line.missing or false

    local indent = kind == "line" and dashWidth or 0
    local width = WIDTH - BLOCK_INDENT
    row.Dash:SetShown(row.state == "todo")
    row.Check:SetShown(row.state == "done")
    row.Toggle:SetShown(row.element ~= nil and row.state ~= "note" and not block.upcoming)
    row.Text:ClearAllPoints()
    row.Text:SetPoint("TOPLEFT", indent, 0)
    row.Text:SetWidth(width - indent)
    local text = kind == "line" and line.text or block.title
    -- Names in guide text carry their own colours; a line that is red as a whole must not.
    if row.missing then text = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    row.Text:SetText(text)
    ColorRow(row)

    local height = math.max(row.Text:GetStringHeight() or 0, 10)
    if drawFloor and y - height < drawFloor then
        -- Would reach below the cut-off line: give the row back.
        usedRows = usedRows - 1
        return nil
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", root, "TOPLEFT", BLOCK_INDENT, y)
    row:SetSize(width, height)
    row:Show()
    return y - height
end

-- Returns where the next thing goes, and whether the cut-off line was reached.
local function DrawBlocks(blocks, y)
    for _, block in ipairs(blocks) do
        nextBlock = nextBlock + 1
        local blockTop = y
        y = y - BLOCK_GAP
        local placed = 0
        if block.title then
            local below = PlaceRow("title", nil, block, y)
            if not below then return blockTop, true end
            y = below
            placed = 1
        end
        for index, line in ipairs(block.lines) do
            local below = PlaceRow("line", line, block, placed > 0 and y - LINE_GAP or y)
            if not below then
                -- A title with nothing under it says little: take it back as well.
                if index == 1 and block.title then
                    usedRows = usedRows - 1
                    return blockTop, true
                end
                return y, true
            end
            y = below
            placed = placed + 1
        end
    end
    return y, false
end

local function Draw(title, tooltipTitle, active, upcoming, floor)
    usedRows, nextBlock = 0, 0
    drawFloor = floor

    activeHeader.Text:SetText(title)
    activeHeader.Next:SetShown(tooltipTitle ~= nil)
    activeHeader.Previous:SetShown(tooltipTitle ~= nil)
    activeHeader.tooltipTitle = tooltipTitle
    activeHeader:ClearAllPoints()
    activeHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
    SetCollapseButton(activeHeader.Collapse, ns.db.activeCollapsed)

    local y, cut = -HEADER_HEIGHT, false
    if not ns.db.activeCollapsed then y, cut = DrawBlocks(active, y) end

    local showUpcoming = UpcomingCount() > 0 and (ns.db.upcomingCollapsed or #upcoming > 0)
    -- The second header needs room for itself and, unless collapsed, for a first step below it.
    local needed = MODULE_GAP + HEADER_HEIGHT + (ns.db.upcomingCollapsed and 0 or BLOCK_GAP + 30)
    if cut or (floor and y - needed < floor) then showUpcoming = false end
    upcomingHeader:SetShown(showUpcoming)
    wheelArea:SetShown(showUpcoming and #upcoming > 0)
    if showUpcoming then
        y = y - MODULE_GAP
        upcomingHeader:ClearAllPoints()
        upcomingHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, y)
        SetCollapseButton(upcomingHeader.Collapse, ns.db.upcomingCollapsed)
        y = y - HEADER_HEIGHT
        local listTop = y
        y = DrawBlocks(upcoming, y)
        wheelArea:ClearAllPoints()
        wheelArea:SetPoint("TOPLEFT", root, "TOPLEFT", 0, listTop)
        wheelArea:SetPoint("BOTTOMRIGHT", root, "TOPRIGHT", 0, y)
    end

    for index = usedRows + 1, #rows do rows[index]:Hide() end
    root:SetHeight(math.max(-y, HEADER_HEIGHT))
end

--------------------------------------------------------------------------------------------------
-- Position: where the quest tracker's next section would start, or wherever it was dragged

local function Place()
    local tracker = ObjectiveTrackerFrame
    local scale = tracker and tracker:GetEffectiveScale() / UIParent:GetEffectiveScale() or 1
    if math.abs(root:GetScale() - scale) > 0.001 then
        root:SetScale(scale)
        root.placedAt = nil
    end

    local left, top
    if ns.db.attach and tracker and tracker:GetLeft() then
        left, top = tracker:GetLeft(), tracker:GetTop()
        if tracker:IsVisible() then
            local bottom = tracker.Header and tracker.Header:IsVisible() and tracker.Header:GetBottom()
            for _, module in ipairs(tracker.modules or {}) do
                local moduleBottom = module:IsVisible() and module:GetBottom()
                if moduleBottom and (not bottom or moduleBottom < bottom) then bottom = moduleBottom end
            end
            if bottom then top = bottom - MODULE_GAP end
        end
    else
        if not ns.db.position then
            -- Detached for the first time: stay where it is.
            ns.db.position = {
                left = root:GetLeft() or (UIParent:GetWidth() / scale - WIDTH - 60),
                top = root:GetTop() or (UIParent:GetHeight() / scale - 260),
            }
        end
        left, top = ns.db.position.left, ns.db.position.top
    end

    local placedAt = left .. ":" .. top
    if root.placedAt ~= placedAt and not root.moving then
        root.placedAt = placedAt
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    return left, top
end

local function PlaceGrip(left, top)
    if not ns.db.limit or not ns.db.bottom then return grip:Hide() end
    grip:ClearAllPoints()
    grip:SetPoint("LEFT", UIParent, "BOTTOMLEFT", left, ns.db.bottom)
    -- Only in the way while the mouse is on the guide.
    local scale = root:GetEffectiveScale()
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    grip:SetShown(gripDragging or (x >= left and x <= left + WIDTH and y <= top and y >= ns.db.bottom - 12))
end

--------------------------------------------------------------------------------------------------
-- Blizzard's quest tracker is of little use next to a guide: collapse it to its header bar while a
-- guide is shown. Done once per change so that expanding it by hand sticks, and never in combat.

local questsHandled, questsCollapsedHere

local function UpdateQuestTracker(guideShown)
    local tracker = ObjectiveTrackerFrame
    if not (tracker and tracker.SetCollapsed and tracker.IsCollapsed) or InCombatLockdown() then return end

    local want = ns.db.hideQuests and guideShown or false
    if want == (questsHandled or false) then return end
    questsHandled = want
    if want then
        if not tracker:IsCollapsed() then
            questsCollapsedHere = pcall(tracker.SetCollapsed, tracker, true)
        end
    elseif questsCollapsedHere then
        questsCollapsedHere = nil
        if tracker:IsCollapsed() then pcall(tracker.SetCollapsed, tracker, false) end
    end
end

--------------------------------------------------------------------------------------------------

-- RestedXP's windows; which ones exist depends on its "V2 interface" setting.
local function GuideWindows(rxp)
    local windows = {RXPFrame}
    local state = rxp.v2 and rxp.v2.state
    if state then
        if state.guideWindow then windows[#windows + 1] = state.guideWindow.frame end
        local mine = state.player and rxp.player and state.player[rxp.player.name]
        if mine and mine.activeStepFrame then windows[#windows + 1] = mine.activeStepFrame.frame end
    end
    return windows
end

local function Disable()
    if root then root:Hide() end
    lastSignature = nil
    local rxp = _G.RXP
    if type(rxp) == "table" then
        for _, window in ipairs(GuideWindows(rxp)) do ns.Unstow(window) end
    end
end

local function Update(rxp)
    local guide = rxp.currentGuide
    -- RestedXP shows and hides RXPFrame for its "hide window" options; follow it.
    local guideShown = RXPFrame:IsShown()
    -- RestedXP leaves currentGuide nil when the character has no guide it can load (none picked yet,
    -- or the saved one is for the other faction). Its window is parked, so this bar is the only way
    -- left to open the guide menu: no guide is drawn like the empty guide, never as nothing at all.
    local hasGuide = guide and not guide.empty
    UpdateQuestTracker(guideShown and hasGuide or false)
    UpdateHold(rxp, guide)

    if not ns.db.tracker then return Disable() end
    for _, window in ipairs(GuideWindows(rxp)) do ns.Stow(window) end
    if not root then Build() end
    if not guideShown then
        root:Hide()
        lastSignature = nil
        return
    end

    local signature = {UpcomingCount(), tostring(ns.db.activeCollapsed), tostring(ns.db.upcomingCollapsed), scrollOffset}
    local title, tooltipTitle, active, upcoming
    if not hasGuide then
        title = "RestedXP Guides"
        active = {{lines = {{text = "Right-click the bar above to pick a guide.", state = "note"}}}}
        upcoming = {}
    else
        tooltipTitle = rxp.GetGuideName(guide) or guide.name or ""
        title = tooltipTitle:gsub("\n", " ")
        active = ActiveBlocks(rxp, signature)
        upcoming = UpcomingBlocks(rxp, guide, signature)
    end
    listIsFull = #upcoming >= UpcomingCount()

    local left, top = Place()
    local floor
    if ns.db.limit then
        -- Until the line has been dragged somewhere, the guide gets DEFAULT_WINDOW of height, but
        -- stays out of the lowest fifth of the screen.
        if not ns.db.bottom then
            ns.db.bottom = math.max(top - DEFAULT_WINDOW, UIParent:GetHeight() / root:GetScale() * 0.2)
        end
        floor = math.min(ns.db.bottom - top, -HEADER_HEIGHT)
    end
    AddToSignature(signature, title, floor and math.floor(floor) or "")

    signature = table.concat(signature, "\031")
    if signature ~= lastSignature or ns.forceRedraw then
        lastSignature = signature
        ns.forceRedraw = nil
        Draw(title, tooltipTitle, active, upcoming, floor)
    end
    PlaceGrip(left, top)
    root:Show()
end

ns.RegisterPart("quest tracker style", Update, Disable)
