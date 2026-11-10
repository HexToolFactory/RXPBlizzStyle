local addonName, ns = ...

-- The guide drawn like a section of Blizzard's quest tracker: a header bar with the guide's name,
-- the active steps as "quests" with their lines as objectives, and a second section with the
-- upcoming steps. Measurements are those of Blizzard_ObjectiveTracker (module, block, line).
local DEFAULT_WIDTH = 260
local HEADER_HEIGHT = 25
local BLOCK_INDENT = 20
local SHOP_SIZE = 14
local INFO_SIZE = 12
local INFO_TEXTURE = "Interface\\FriendsFrame\\InformationIcon"
local BLOCK_GAP = 10
local LINE_GAP = 4
local MODULE_GAP = 10
local MAX_UPCOMING_SCAN = 400
local DEFAULT_WINDOW = 350
local MIN_ROOM = 150   -- what the guide keeps when the screen edge is nearer than its height

-- The display settings (Options > AddOns > RestedXP Blizzard Style > Display).
local function Width() return ns.Clamp("width", ns.db.width) end
local function UserScale() return ns.Clamp("scale", ns.db.scale) end
local function Height() return ns.Clamp("height", ns.db.height) end

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
-- Blizzard's quest tracker while the guide stands in for it (see "The guide in place of the quest tracker").
local trackerHidden, trackerAway, trackerShownByUser
local trackerOrigin      -- where the tracker and its header bar are at full size, measured while shown
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

-- Steps RestedXP would skip for a missing prerequisite (see "Steps with missing prerequisites" below).
local held = setmetatable({}, {__mode = "k"})       -- step -> {frame, tag, id, name, kind = "log" / "done", marker}
local released = setmetatable({}, {__mode = "k"})   -- step -> true: ticked off, RestedXP may skip it

-- Ticking off the red line of a held step: RestedXP skips it as it would have.
local function ReleaseStep(rxp, step)
    local hold = held[step]
    released[step] = true
    held[step] = nil
    if hold and rxp.functions and rxp.functions[hold.tag] then pcall(rxp.functions[hold.tag], hold.frame, "RXPBlizzStyle") end
    rxp.updateSteps = true
end

-- What ticking the checkbox next to a line does in RestedXP's window.
local function ToggleSkip(rxp, element)
    if element.heldStep then return ReleaseStep(rxp, element.heldStep) end
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
    elseif row.missing and not IsShiftKeyDown() and ns.ShowPrereqsFor then
        -- Row_OnClick is defined above RowQuestId; read the ID the same way here.
        local id = row.quest and row.quest.questId
        if id and rxp.GetQuestId then id = rxp.GetQuestId(id, nil, true) or id end
        if id then ns.ShowPrereqsFor(id) end
    elseif IsShiftKeyDown() then
        if row.past and row.index and ns.GoBackTo then
            ns.GoBackTo(rxp, row.index)
        elseif row.upcoming then
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
    if row.past then
        row.Text:SetTextColor(TrackerColor(row.kind == "title" and hover and "titleHover" or "done"))
        row.Dash:SetTextColor(TrackerColor("done"))
    elseif row.kind == "title" then
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

-- Questie's map pin tooltip on quest lines. Hovering a line that picks up, works on or hands in a quest
-- shows what hovering that quest's pin on the map shows, Shift included (experience, money, the rest of
-- the chain). Questie builds that tooltip from its map icons, so it exists only for quests Questie marks
-- on the map: available ones at their giver, accepted ones at their objectives, finished ones at their
-- turn-in. Questie redraws it on Shift only over the map and the minimap; for the guide this does.
local QUESTIE_TYPE = {accept = "available", turnin = "complete"}
local questieRow, questieIcon

local function QuestieModule(name)
    local loader, questie = _G.QuestieLoader, _G.Questie
    if type(loader) ~= "table" or type(questie) ~= "table" or not (questie.API and questie.API.isReady) then return end
    local ok, module = pcall(loader.ImportModule, loader, name)
    if ok and type(module) == "table" then return module end
end

-- One world map icon per objective of the quest, those of the kind the line is about first.
local function QuestieIcons(questId, tag)
    local map = QuestieModule("QuestieMap")
    if not (map and map.GetFramesForQuest) then return end
    local ok, frames = pcall(map.GetFramesForQuest, map, questId)
    if not ok or type(frames) ~= "table" then return end
    local wanted = QUESTIE_TYPE[tag]
    local matching, other, seen = {}, {}, {}
    for _, frame in pairs(frames) do
        local data = frame.data
        -- Pooled frames are reused: the name list can point at a frame of another quest by now.
        if type(data) == "table" and data.Id == questId and frame.miniMapIcon == false and frame.texture
            and data.Type ~= "manual" then
            local key = tostring(data.Type) .. ":" .. tostring(data.ObjectiveIndex or 0)
            if not seen[key] then
                seen[key] = true
                local objective = data.Type ~= "available" and data.Type ~= "complete"
                if data.Type == wanted or (not wanted and objective) then
                    matching[#matching + 1] = frame
                else
                    other[#other + 1] = frame
                end
            end
        end
    end
    local icons = #matching > 0 and matching or other
    if #icons > 0 then return icons end
end

local function HideQuestieTooltip()
    if not questieRow then return end
    local row, icon = questieRow, questieIcon
    questieRow, questieIcon = nil, nil
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
    GameTooltip._Rebuild = nil
    GameTooltip.ShownAsMapIcon = false
    local frames = QuestieModule("QuestieFrame")
    if frames and frames.ResetHoverHighlights and icon and icon.data then pcall(frames.ResetHoverHighlights, icon) end
end

-- owner: the frame the tooltip belongs to; element: {questId = , tag = } as in a guide step.
local function ShowQuestieTooltip(row, element)
    if not (element and ns.db.questie) then return false end
    local tooltips = QuestieModule("MapIconTooltip")
    if not (tooltips and tooltips.ShowOnTooltip) then return false end
    local rxp = _G.RXP
    local questId = element.questId
    if type(rxp) == "table" and rxp.GetQuestId then questId = rxp.GetQuestId(questId, nil, true) or questId end
    local icons = QuestieIcons(questId, element.tag)
    if not icons then return false end
    HideQuestieTooltip()
    GameTooltip:Hide()      -- Questie skips a call that comes right after another while the tooltip is shown
    questieRow, questieIcon = row, icons[1]
    local ok = pcall(tooltips.ShowOnTooltip, icons[1], GameTooltip, row, icons)
    if not ok or not GameTooltip:IsShown() or GameTooltip:GetOwner() ~= row then
        HideQuestieTooltip()
        return false
    end
    return true
end

-- The real quest ID of a line's quest (RestedXP maps some IDs to the variant of the character's race or class).
local function RowQuestId(row)
    local id = row.quest and row.quest.questId
    local rxp = ns.GetRXP()
    if id and rxp and rxp.GetQuestId then id = rxp.GetQuestId(id, nil, true) or id end
    return id
end

-- For a quest the player does not have: which one it is, where it starts and what has to be done first.
local function AddMissingLines(row)
    local marker = row.element and row.element.heldStep and row.element
    GameTooltip:AddLine(marker and marker.headline or "You do not have this quest.", 1, 0.1, 0.1, true)
    if marker then GameTooltip:AddLine("Tick it off (the dash) to skip the step.", 0.5, 0.8, 1) end
    local id = RowQuestId(row)
    local ok, hint = false, nil
    if id and ns.QuestHint then ok, hint = pcall(ns.QuestHint, id) end
    if not ok or type(hint) ~= "table" then return end
    GameTooltip:AddLine(hint.name .. (hint.level and (" (level " .. hint.level .. ")") or ""), 1, 0.82, 0)
    if hint.starter then
        GameTooltip:AddLine("Starts at " .. hint.starter .. (hint.zone and (", " .. hint.zone) or ""), 1, 1, 1, true)
    end
    if #hint.before > 0 then
        GameTooltip:AddLine(("Do these first (%d):"):format(#hint.before), 1, 0.5, 0.25)
        for i = 1, math.min(#hint.before, 6) do GameTooltip:AddLine(i .. ". " .. hint.before[i], 0.9, 0.9, 0.9) end
        if #hint.before > 6 then GameTooltip:AddLine(("... and %d more"):format(#hint.before - 6), 0.9, 0.9, 0.9) end
    elseif hint.status == "level" then
        GameTooltip:AddLine(("Needs level %d to pick it up."):format(hint.requiredLevel), 1, 0.5, 0.25)
    elseif hint.status == "available" then
        GameTooltip:AddLine("You can pick it up now.", 0.25, 1, 0.25)
    end
    if ns.ShowPrereqsFor then GameTooltip:AddLine("Click: show it in Missing Prerequisites", 0.5, 0.8, 1) end
end

local function Row_OnEnter(row)
    SetHoveredBlock(row.block)
    local tooltip = row.element and row.element.tooltip
    if type(tooltip) ~= "string" or tooltip == "" then tooltip = nil end
    if ShowQuestieTooltip(row, row.quest) then
        if tooltip or row.missing then GameTooltip:AddLine(" ") end
        if tooltip then GameTooltip:AddLine(tooltip, 1, 1, 1, true) end
        if row.missing then AddMissingLines(row) end
        GameTooltip:Show()
    elseif tooltip or row.missing then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        if tooltip then GameTooltip:AddLine(tooltip, 1, 1, 1, true) end
        if row.missing then AddMissingLines(row) end
        GameTooltip:Show()
    end
end

local function Row_OnLeave(row)
    if hoveredBlock == row.block then SetHoveredBlock(nil) end
    if questieRow == row then HideQuestieTooltip() end
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
end

local modifierWatcher = CreateFrame("Frame")
modifierWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")
modifierWatcher:SetScript("OnEvent", function(_, _, key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    local row = questieRow
    if row and row:IsVisible() and row:IsMouseOver() and GameTooltip:GetOwner() == row then
        local onEnter = row:GetScript("OnEnter")
        if onEnter then onEnter(row) end
    end
end)

-- For the prerequisites window.
ns.QuestieModule = QuestieModule
ns.ShowQuestieTooltip = ShowQuestieTooltip
function ns.HideQuestieTooltip(owner)
    if questieRow == owner then HideQuestieTooltip() end
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

local function NextStep(guide, from)
    local level = UnitLevel("player")
    for index = from + 1, #guide.steps do
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
    local pin = ns.db.pin
    if pin and (guide.empty or id ~= pin.guide or current ~= pin.step) then ns.db.pin = nil end

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

-- A step gone back to on purpose stays the current step even when it is done, until the player goes on (see
-- "Going back" at the end). ns.db.pin = {guide = id, step, origin = {group, name, step} where the walk started}.
local function Pin(rxp, guide, step, origin)
    local first = ns.db.pin and ns.db.pin.origin or origin
    ns.db.pin = {guide = GuideId(guide), step = step, origin = first}
end

-- The return arrow: back to the step the walk back started from.
function ns.ReturnFromBack(rxp)
    local pin = ns.db.pin
    ns.db.pin = nil
    backCursor = nil
    local origin = pin and pin.origin
    if not origin then return end
    local guide = rxp.currentGuide
    if not guide or guide.group ~= origin.group or guide.name ~= origin.name then
        local target = rxp.GetGuideTable(origin.group, origin.name)
        if not target then return end
        rxp:LoadGuide(target)
    end
    rxp.SetStep(origin.step)
end

-- Shift-click on a previous step (scrolled back in the list): goes there like the back arrow, so RestedXP does
-- not skip straight on from it.
function ns.GoBackTo(rxp, index)
    local guide = rxp.currentGuide
    if not guide or guide.empty then return end
    local origin = rxp.GetGuideProgress()
    if index < origin then
        HoldSkips(rxp, guide, origin)
        backCursor = {id = GuideId(guide), group = guide.group, name = guide.name, step = index, at = GetTime(), watching = true}
        Pin(rxp, guide, index, {group = guide.group, name = guide.name, step = origin})
    else
        ns.db.pin = nil
    end
    rxp.SetStep(index)
end

local function StepBack(rxp)
    local guide = rxp.currentGuide
    local origin = rxp.GetGuideProgress()
    local from = origin
    local start = {group = guide.group, name = guide.name, step = origin}

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
    Pin(rxp, guide, target, start)
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
        local pin = ns.db.pin
        local origin = pin and pin.origin
        local current = rxp.GetGuideProgress()
        local nextStep = NextStep(guide, current)
        if origin and nextStep and guide.group == origin.group and guide.name == origin.name and nextStep < origin.step then
            Pin(rxp, guide, nextStep, origin)
            rxp.SetStep(nextStep)
        else
            ns.db.pin = nil
            rxp.SetStep(current + 1)
        end
    end
    ns.Refresh()
end

local function StepButton_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine(button.direction < 0 and "Previous step" or "Next step", 1, 1, 1)
    if button.direction < 0 then
        GameTooltip:AddLine("Also stops RestedXP from skipping steps on its own until you are back where you started.",
            0.8, 0.8, 0.8, true)
        GameTooltip:AddLine("The step you go back to stays, even when it is done: the next arrow then walks forward step by step, the round arrow returns at once.",
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
    GameTooltip:AddLine("Shift-click an upcoming or previous step: go to it", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Scroll over the steps below: look ahead, or back at the previous steps", 0.8, 0.8, 0.8)
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
-- The guide's box from the last update, in the units of its position (the quest tracker's scale): top and bottom
-- (one of them nil while the height is not limited), which edge stays put ("top" / "bottom") and the height in
-- the guide's own units, nil while not limited.
local box = {}

-- Keeps where the guide stands now as its detached position.
local function SavePosition()
    local u = UserScale()
    local left, top, bottom = root:GetLeft(), root:GetTop(), root:GetBottom()
    if not (left and top and bottom) then return end
    left, top, bottom = left * u, top * u, bottom * u
    local height = (box.height or root:GetHeight()) * u
    if ns.db.anchor == "BOTTOM" and box.height then top = bottom + height else bottom = top - height end
    ns.db.position = {left = left, top = top, bottom = bottom}
    root.placedAt = nil
end

local function StartMove()
    -- Attached, the guide stays below the quest tracker (so tracked quests can stay above it): the two move together
    -- in Edit Mode. Detached, its header bars drag it.
    if ns.db.attach then return end
    root.moving = true
    root:StartMoving()
end

local function StopMove()
    if not root.moving then return end
    root:StopMovingOrSizing()
    root.moving = nil
    SavePosition()
end

local function CreateHeader(collapseKey)
    local header = CreateFrame("Button", nil, root)
    header:SetSize(Width(), HEADER_HEIGHT + 1)
    header:RegisterForClicks("RightButtonUp")
    header:RegisterForDrag("LeftButton")

    header.Background = header:CreateTexture(nil, "BACKGROUND")
    header.Background:SetAtlas("UI-QuestTracker-Secondary-Objective-Header", true)
    header.Background:SetPoint("CENTER")
    header.backgroundWidth = header.Background:GetWidth()

    header.Text = header:CreateFontString(nil, "ARTWORK",
        ObjectiveTrackerHeaderFont and "ObjectiveTrackerHeaderFont" or "GameFontNormalMed2")
    header.Text:SetPoint("LEFT", 7, 0)
    header.Text:SetWidth(Width() - 60)
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
    header:SetScript("OnDragStart", StartMove)
    header:SetScript("OnDragStop", StopMove)
    return header
end

-- Where the auction house button of a guide line puts an item. A target counts while its addon is loaded:
-- available() says so, has(id) whether the item is on its list already, add(id, qty) puts it there.

local function ItemName(itemID)
    return C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
end

-- Forever Auction: its shopping list "Guide".
local foreverAuction = {
    available = function() return ForeverAuction_AddToShopping ~= nil end,
    has = function(itemID)
        return not ForeverAuction_ShoppingQty or (ForeverAuction_ShoppingQty(itemID) or 0) > 0
    end,
    add = function(itemID, qty) ForeverAuction_AddToShopping(itemID, qty, "Guide") end,
    hint = function() return "Forever Auction shows it at the auction house." end,
}

-- Auctionator: a shopping list of its own, "RestedXP Guide", with an exact search per item and the quantity still
-- needed. Its API only replaces whole lists, so the list is read, changed and written back.
local AUCTIONATOR_LIST, AUCTIONATOR_CALLER = "RestedXP Guide", "RXPBlizzStyle"

local function AuctionatorAPI()
    local api = type(Auctionator) == "table" and type(Auctionator.API) == "table" and Auctionator.API.v1
    if type(api) ~= "table" then return end
    for _, name in ipairs({"CreateShoppingList", "GetShoppingListItems", "ConvertToSearchString", "ConvertFromSearchString"}) do
        if type(api[name]) ~= "function" then return end
    end
    return api
end

local function AuctionatorItems(api)      -- a copy of the list's search strings; empty while the list does not exist
    local ok, items = pcall(api.GetShoppingListItems, AUCTIONATOR_CALLER, AUCTIONATOR_LIST)
    local copy = {}
    for i, search in ipairs(ok and type(items) == "table" and items or {}) do copy[i] = search end
    return copy
end

local function AuctionatorIndex(api, items, name)
    name = name:lower()
    for i, search in ipairs(items) do
        local ok, term = pcall(api.ConvertFromSearchString, AUCTIONATOR_CALLER, search)
        if ok and type(term) == "table" and type(term.searchString) == "string" and term.searchString:lower() == name then
            return i
        end
    end
end

local auctionator = {
    available = function() return AuctionatorAPI() ~= nil end,
    has = function(itemID)
        local api, name = AuctionatorAPI(), ItemName(itemID)
        return api and name and AuctionatorIndex(api, AuctionatorItems(api), name) ~= nil or false
    end,
    add = function(itemID, qty)
        local api, name = AuctionatorAPI(), ItemName(itemID)
        if not (api and name) then return end   -- name not in the item cache yet; the tooltip asks for it
        local ok, search = pcall(api.ConvertToSearchString, AUCTIONATOR_CALLER,
            {searchString = name, isExact = true, quantity = qty})
        if not ok or type(search) ~= "string" then return end
        local items = AuctionatorItems(api)
        local index = AuctionatorIndex(api, items, name)
        items[index or #items + 1] = search     -- an item already there gets the current quantity
        pcall(api.CreateShoppingList, AUCTIONATOR_CALLER, AUCTIONATOR_LIST, items)
    end,
    hint = function(itemID, has)
        return has and ('On the Auctionator shopping list "' .. AUCTIONATOR_LIST .. '". A click updates the quantity.')
            or ('Auctionator: shopping list "' .. AUCTIONATOR_LIST .. '".')
    end,
}

-- Auctioneer has no shopping list. Its Search UI keeps a snatch list instead: items a search offers to buy when an
-- auction is at or below a price. A guide item goes on it at 100% of Auctioneer's market price; an entry that is
-- already there keeps the price its owner set.
local SNATCH_PERCENT = 100

-- The snatch searcher and its list, once Search UI has loaded its settings. Before that the list is a stand-in, and
-- adding to it would overwrite the saved one.
local function SnatchList()
    local searchUI = AucSearchUI
    local snatch = type(searchUI) == "table" and type(searchUI.Searchers) == "table" and searchUI.Searchers.Snatch
    if type(snatch) ~= "table" or type(snatch.AddSnatch) ~= "function" or type(snatch.Private) ~= "table" then return end
    local list = snatch.Private.snatchList
    if type(list) ~= "table" or type(searchUI.GetSearchLocals) ~= "function" then return end
    local ok, get = pcall(searchUI.GetSearchLocals)
    if not ok or type(get) ~= "function" then return end
    local okSaved, saved = pcall(get, "snatch.itemsList")
    if okSaved and saved == list then return snatch, list end
end

local function OnSnatchList(itemID)
    local _, list = SnatchList()
    for _, entry in pairs(list or {}) do
        local link = type(entry) == "table" and entry.link
        if type(link) == "string" and tonumber(link:match("item:(%d+)")) == itemID then return true end
    end
    return false
end

local auctioneer = {
    snatch = true,
    available = function() return SnatchList() ~= nil end,
    has = OnSnatchList,
    add = function(itemID, qty)
        local snatch = SnatchList()
        if not snatch or OnSnatchList(itemID) then return end
        local getInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
        local link = getInfo and select(2, getInfo(itemID))
        if not link then return end
        -- AddSnatch saves the entry first and then resets its own window, which fails while that window was never opened.
        pcall(snatch.AddSnatch, link, nil, SNATCH_PERCENT, qty)
    end,
    hint = function(itemID, has)
        return has and "Already on Auctioneer's snatch list."
            or "Auctioneer's Snatch search offers it at up to its market price."
    end,
}

local SHOP_TARGETS = {foreverAuction, auctionator, auctioneer}

local function AnyShopTarget()
    for _, target in ipairs(SHOP_TARGETS) do
        if target.available() then return true end
    end
    return false
end

-- Dimmed once the item is on every list there is.
local function Shop_Update(button)
    local item = button.item
    if not item then return end
    local done = true
    for _, target in ipairs(SHOP_TARGETS) do
        if done and target.available() then done = target.has(item.id) end
    end
    button:SetAlpha(done and 0.45 or 1)
end

local function Shop_OnEnter(button)
    Row_OnEnter(button:GetParent())
    local item = button.item
    if not item then return end
    local onlySnatch, hints = true, {}
    for _, target in ipairs(SHOP_TARGETS) do
        if target.available() then
            onlySnatch = onlySnatch and target.snatch or false
            hints[#hints + 1] = target.hint(item.id, target.has(item.id))
        end
    end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine(onlySnatch and "Add to Auctioneer's snatch list" or "Add to the shopping list", 1, 1, 1)
    GameTooltip:AddLine((ItemName(item.id) or "Item") .. " x" .. item.qty, 0.8, 0.8, 0.8)
    for _, hint in ipairs(hints) do GameTooltip:AddLine(hint, 0.8, 0.8, 0.8, true) end
    GameTooltip:Show()
end

local function Shop_OnClick(button)
    local item = button.item
    if not item then return end
    for _, target in ipairs(SHOP_TARGETS) do
        if target.available() then target.add(item.id, item.qty) end
    end
    Shop_Update(button)
end

-- The info button next to a step's title: what the step's quests lead to in their chains (Questie's "Next in
-- chain"), to see before doing or skipping one what comes after it.
local hasFollowUps = {}     -- quest ID -> true / false; chains do not change, so asked once per quest

local function HasFollowUps(id)
    if hasFollowUps[id] == nil then
        local ok, list = false, nil
        if ns.QuestFollowUps then ok, list = pcall(ns.QuestFollowUps, id) end
        if not ok or type(list) ~= "table" then return false end    -- not kept: Questie may not be ready yet
        hasFollowUps[id] = #list > 0
    end
    return hasFollowUps[id]
end

local function FormatXp(xp)
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or tostring(xp)) .. " XP"
end

local MAX_FOLLOW_LINES = 12

local function Info_OnEnter(button)
    local row = button:GetParent()
    SetHoveredBlock(row.block)
    local inStep, sections, listed = {}, {}, {}
    for _, id in ipairs(row.quests or {}) do inStep[id] = true end
    for _, id in ipairs(button.quests or {}) do
        local ok, list, name = false, nil, nil
        if ns.QuestFollowUps then ok, list, name = pcall(ns.QuestFollowUps, id) end
        if ok and type(list) == "table" and #list > 0 then
            sections[#sections + 1] = {id = id, name = name, list = list}
            for _, info in ipairs(list) do listed[info.id] = true end
        end
    end
    -- A step quest that comes later in another step quest's chain is shown in that chain.
    local shown = {}
    for _, section in ipairs(sections) do
        if not listed[section.id] then shown[#shown + 1] = section end
    end
    if #shown == 0 then shown = sections end

    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("Follow-up quests", 1, 1, 1)
    for _, section in ipairs(shown) do
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine((section.name or ("Quest " .. section.id)) .. " leads to:", 1, 0.82, 0)
        local rest = 0
        for i, info in ipairs(section.list) do
            if info.status ~= "done" then rest = rest + (info.xp or 0) end
            if i <= MAX_FOLLOW_LINES then
                local left = (info.level and ("[" .. info.level .. "] ") or "") .. info.name
                    .. (info.xp and ("  " .. FormatXp(info.xp)) or "")
                local right, r, g, b
                if info.status == "done" then
                    right, r, g, b = "done", 0.5, 0.5, 0.5
                elseif info.status == "log" then
                    right, r, g, b = "in quest log", 1, 0.82, 0
                elseif inStep[info.id] then
                    right, r, g, b = "this step", 1, 1, 1
                elseif info.step then
                    right, r, g, b = "step " .. info.step, 0.25, 1, 0.25
                else
                    right, r, g, b = "not in this guide", 1, 0.5, 0.25
                end
                local shade = info.status == "done" and 0.5 or 0.9
                GameTooltip:AddDoubleLine(left, right, shade, shade, shade, r, g, b)
            end
        end
        if #section.list > MAX_FOLLOW_LINES then
            GameTooltip:AddLine(("... and %d more"):format(#section.list - MAX_FOLLOW_LINES), 0.8, 0.8, 0.8)
        end
        if rest > 0 then GameTooltip:AddLine("Still open after it: " .. FormatXp(rest), 0.55, 0.75, 1) end
    end
    GameTooltip:Show()
end

local function Info_OnLeave(button)
    local row = button:GetParent()
    if hoveredBlock == row.block then SetHoveredBlock(nil) end
    if GameTooltip:GetOwner() == button then GameTooltip:Hide() end
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

    row.Shop = CreateFrame("Button", nil, row)
    row.Shop:SetSize(SHOP_SIZE, SHOP_SIZE)
    row.Shop:SetPoint("TOPRIGHT", 0, 1)
    row.Shop:SetNormalTexture("Interface\\Minimap\\Tracking\\Auctioneer")
    row.Shop:SetHighlightTexture("Interface\\Minimap\\Tracking\\Auctioneer", "ADD")
    row.Shop:SetScript("OnClick", Shop_OnClick)
    row.Shop:SetScript("OnEnter", Shop_OnEnter)
    row.Shop:SetScript("OnLeave", function(button) Row_OnLeave(button:GetParent()) end)

    row.Info = CreateFrame("Button", nil, row)
    row.Info:SetSize(INFO_SIZE, INFO_SIZE)
    row.Info:SetNormalTexture(INFO_TEXTURE)
    row.Info:SetHighlightTexture(INFO_TEXTURE, "ADD")
    row.Info:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.Info:SetScript("OnClick", function(button, mouse) Row_OnClick(button:GetParent(), mouse) end)
    row.Info:SetScript("OnEnter", Info_OnEnter)
    row.Info:SetScript("OnLeave", Info_OnLeave)
    row.Info:Hide()

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
    root:SetSize(Width(), HEADER_HEIGHT)
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
    activeHeader.Prereqs = CreateFrame("Button", nil, activeHeader)
    activeHeader.Prereqs:SetSize(16, 16)
    activeHeader.Prereqs:SetPoint("RIGHT", activeHeader.Report, "LEFT", -2, 0)
    activeHeader.Prereqs:SetNormalTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    activeHeader.Prereqs:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    activeHeader.Prereqs:SetScript("OnClick", function() ns.TogglePrereqs() end)
    activeHeader.Prereqs:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Missing prerequisites", 1, 1, 1)
        GameTooltip:AddLine("Quests of this guide you cannot pick up yet, with the quests that unlock them. Needs Questie.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    activeHeader.Prereqs:SetScript("OnLeave", GameTooltip_Hide)
    activeHeader.Return = CreateFrame("Button", nil, activeHeader)
    activeHeader.Return:SetSize(14, 14)
    activeHeader.Return:SetPoint("RIGHT", activeHeader.Prereqs, "LEFT", -3, 0)
    activeHeader.Return:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
    activeHeader.Return:SetHighlightTexture("Interface\\Buttons\\UI-RefreshButton", "ADD")
    activeHeader.Return:SetScript("OnClick", function()
        local rxp = ns.GetRXP()
        if not rxp then return end
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        ns.ReturnFromBack(rxp)
        ns.Refresh()
    end)
    activeHeader.Return:SetScript("OnEnter", function(self)
        local origin = ns.db.pin and ns.db.pin.origin
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine(origin and ("Back to step %d"):format(origin.step) or "Back", 1, 1, 1)
        GameTooltip:AddLine("Where you were before going back.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end)
    activeHeader.Return:SetScript("OnLeave", GameTooltip_Hide)
    activeHeader.Return:Hide()
    activeHeader.Text:SetWidth(Width() - 132)
    upcomingHeader = CreateHeader("upcomingCollapsed")
    upcomingHeader.Text:SetText("Upcoming Steps")

    -- The mouse wheel over the upcoming steps (or their header) pages through the rest of the guide, and back past
    -- the current step through the steps before it, like scrolling up in RestedXP's step list.
    local function Wheel(_, delta)
        -- Anchor Bottom has the later steps above: the wheel goes up to them.
        if ns.db.anchor == "BOTTOM" then delta = -delta end
        if delta < 0 and scrollOffset >= 0 and not listIsFull then return end
        scrollOffset = scrollOffset - delta
        ns.Refresh()
    end
    wheelArea = CreateFrame("Frame", nil, root)
    wheelArea:EnableMouseWheel(true)
    wheelArea:SetScript("OnMouseWheel", Wheel)
    upcomingHeader:EnableMouseWheel(true)
    upcomingHeader:SetScript("OnMouseWheel", Wheel)
    -- Shown while scrolled away: back to the steps right after the current one.
    local back = CreateFrame("Button", nil, upcomingHeader)
    back:SetSize(14, 14)
    back:SetPoint("RIGHT", upcomingHeader.Collapse, "LEFT", -3, 0)
    back:SetNormalTexture("Interface\\Buttons\\UI-RefreshButton")
    back:SetHighlightTexture("Interface\\Buttons\\UI-RefreshButton", "ADD")
    back:SetScript("OnClick", function()
        scrollOffset = 0
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        ns.Refresh()
    end)
    back:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Back to the current step", 1, 1, 1)
        GameTooltip:Show()
    end)
    back:SetScript("OnLeave", GameTooltip_Hide)
    back:Hide()
    upcomingHeader.Return = back

    -- The free end of the guide's box (option "Limit the guide's height"): a line across the guide that is dragged
    -- up and down to set its height. It only shows while the mouse is on the guide.
    grip = CreateFrame("Button", nil, root)
    grip:SetFrameStrata("MEDIUM")
    grip:SetSize(Width(), 12)
    local line = grip:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 0.82, 0, 0.9)
    line:SetHeight(2)
    line:SetPoint("LEFT")
    line:SetPoint("RIGHT")
    grip:SetScript("OnMouseDown", function() gripDragging = true end)
    grip:SetScript("OnMouseUp", function()
        gripDragging = false
        ns.SetOption("height", ns.db.height)
    end)
    grip:SetScript("OnUpdate", function()
        if not gripDragging or not box.height then return end
        local u = UserScale()
        local _, y = GetCursorPosition()
        y = y / root:GetEffectiveScale() * u
        local height = box.fixed == "bottom" and y - box.bottom or box.top - y
        ns.db.height = ns.Clamp("height", height / u)
        ns.Refresh()
    end)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Drag: height of the guide", 1, 1, 1)
        GameTooltip:AddLine(("%d (Options > AddOns > RestedXP Blizzard Style > Display)"):format(Height()), 0.8, 0.8, 0.8, true)
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

-- The width setting, applied to the frames that have a size of their own.
local appliedWidth
local function ApplyWidth()
    local width = Width()
    if width == appliedWidth then return end
    appliedWidth = width
    root:SetWidth(width)
    for _, header in ipairs({activeHeader, upcomingHeader}) do
        header:SetWidth(width)
        if header.backgroundWidth and header.backgroundWidth > 0 then
            header.Background:SetWidth(header.backgroundWidth * width / DEFAULT_WIDTH)
        end
    end
    activeHeader.Text:SetWidth(width - 132)
    upcomingHeader.Text:SetWidth(width - 60)
    grip:SetWidth(width)
    ns.forceRedraw = true
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

local function MentionsAuctionHouse(step)
    if step.ah then return true end
    for _, element in ipairs(step.elements or {}) do
        for _, text in ipairs({element.text or "", element.rawtext or "", element.tooltipText or ""}) do
            if type(text) == "string" and text:find("Auction House", 1, true) then return true end
        end
    end
    return false
end

-- What the auction house button of a line would put on a shopping list: an item the step still wants, in a step that
-- names the auction house. Nothing without Forever Auction, Auctionator or Auctioneer's Search UI, so nobody else sees
-- the button.
function ns.ShopItem(step, element)
    if element.tag ~= "collect" and element.tag ~= "buy" then return end
    if not AnyShopTarget() then return end
    if type(element.id) ~= "number" or element.completed or element.skip then return end
    if not MentionsAuctionHouse(step) then return end
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(element.id) or 0
    local qty = tonumber(element.qty) or 1
    if qty >= 1000 then qty = 1 end         -- guides write "as many as there are" with a huge number
    return {id = element.id, qty = math.max(qty - count, 1)}
end

-- The line's element when it picks up, works on or hands in a quest (for Questie's tooltip).
local function QuestElement(element)
    if (element.tag == "accept" or element.tag == "turnin" or element.tag == "complete")
        and type(element.questId) == "number" and element.questId > 0 then
        return element
    end
end

-- The step's quests (real IDs, each once), for the info button next to its title.
local function StepQuests(rxp, step)
    local list, seen = {}, {}
    for _, element in ipairs(step.elements or {}) do
        local quest = QuestElement(element)
        if quest then
            local id = rxp.GetQuestId and rxp.GetQuestId(quest.questId, nil, true) or quest.questId
            if not seen[id] then
                seen[id] = true
                list[#list + 1] = id
            end
        end
    end
    return list
end

-- The step's quests that lead on to others (for the info button). Part of the signature: Questie gets ready
-- after the first drawing, and the button has to appear then.
local function FollowQuests(quests)
    local list = {}
    for _, id in ipairs(quests) do
        if HasFollowUps(id) then list[#list + 1] = id end
    end
    return list
end

local function ActiveBlocks(rxp, signature)
    local blocks = {}
    local guide, current = rxp.currentGuide, rxp.GetGuideProgress()
    for _, step in ipairs(RXPFrame.activeSteps) do
        if step.active and not step.hidewindow and not step.hidetip then
            local block = {index = step.index, lines = {}, quests = StepQuests(rxp, step)}
            block.follow = FollowQuests(block.quests)
            if not step.sticky or step.title then block.title = ns.StepTitle(rxp, step) end
            AddToSignature(signature, "step", step.index, block.title, #block.follow)
            for _, element in ipairs(step.elements or {}) do
                local text = ns.ElementText(rxp, element)
                if text then
                    local icon = element.tag and (element.icon or rxp.icons[element.tag])
                    icon = icon and icon .. " " or ""
                    local state = element.textOnly and "note" or
                                      ((element.completed or element.skip) and "done" or "todo")
                    local missing = state == "todo" and QuestMissing(rxp, guide, element, step.index, current)
                    local shop = ns.ShopItem(step, element)
                    block.lines[#block.lines + 1] = {text = icon .. text, state = state, element = element, missing = missing, shop = shop,
                        quest = QuestElement(element)}
                    AddToSignature(signature, state, icon, text, missing, shop and shop.id, shop and shop.qty)
                end
            end
            local pin = ns.db.pin
            if pin and pin.step == step.index and pin.guide == GuideId(guide) and pin.origin then
                local text = ("You went back to this step: RestedXP stays here until you go on (the arrows above, or the round one to return to step %d)."):format(pin.origin.step)
                block.lines[#block.lines + 1] = {text = text, state = "note"}
                AddToSignature(signature, "pin", text)
            end
            local hold = held[step]
            if hold then
                local text = (hold.kind == "log" and "Missing prerequisite: %s is not in your quest log" or
                    "Missing prerequisite: %s is not done"):format(hold.name)
                block.lines[#block.lines + 1] = {text = text, state = "todo", element = hold.marker, missing = true,
                    quest = {questId = hold.id}}
                AddToSignature(signature, "held", text)
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
            lines[#lines + 1] = {text = text, state = state, missing = QuestMissing(rxp, guide, element, index, current),
                quest = QuestElement(element)}
        end
    end
    return lines
end

-- Scrolled back past the next steps: the steps before the current one, in guide order. scrollOffset -1 ends the
-- page at the step right before the current one, each further tick goes one step back. nil when there are none.
local function PreviousBlocks(rxp, guide, signature, current, count)
    local skipped = RXPCData and RXPCData.stepSkip or {}
    local back = -scrollOffset
    local found = {}
    for index = current - 1, math.max(1, current - MAX_UPCOMING_SCAN), -1 do
        local step = guide.steps[index]
        if step and not (step.hidewindow or step.hidetip or step.optional) then
            local lines = UpcomingLines(rxp, guide, step, index, current)
            if lines then
                found[#found + 1] = {index = index, step = step, lines = lines}
                if #found >= back + count - 1 then break end
            end
        end
    end
    if #found == 0 then
        scrollOffset = 0
        return nil
    end
    local last = math.max(1, #found - count + 1)
    if back > last then
        back = last
        scrollOffset = -back
    end
    local blocks = {}
    for i = math.min(#found, back + count - 1), back, -1 do
        local item = found[i]
        for _, line in ipairs(item.lines) do
            line.missing = false
            -- Done, unless the player skipped the step.
            if line.state == "todo" and not skipped[item.index] then line.state = "done" end
        end
        local title = item.step.title and item.step.title ~= "" and GuideText(rxp, item.step.title) or
                          rxp.locale.Get("Step %d"):format(item.index)
        local quests = StepQuests(rxp, item.step)
        local follow = FollowQuests(quests)
        blocks[#blocks + 1] = {index = item.index, title = title, lines = item.lines, upcoming = true, past = true,
            quests = quests, follow = follow}
        AddToSignature(signature, "previous", item.index, title, #follow)
        for _, line in ipairs(item.lines) do AddToSignature(signature, line.text, line.state) end
    end
    -- Anchor Bottom lays the list out from the bottom up: reversed, it still reads in guide order.
    if ns.db.anchor == "BOTTOM" then
        for i = 1, math.floor(#blocks / 2) do blocks[i], blocks[#blocks + 1 - i] = blocks[#blocks + 1 - i], blocks[i] end
    end
    return blocks
end

local function UpcomingBlocks(rxp, guide, signature)
    local blocks = {}
    local count = UpcomingCount()
    if count <= 0 or ns.db.upcomingCollapsed then return blocks end

    local current = rxp.GetGuideProgress()
    if scrollStep ~= current then scrollStep, scrollOffset = current, 0 end
    if scrollOffset < 0 then
        local previous = PreviousBlocks(rxp, guide, signature, current, count)
        if previous then return previous end
    end

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
                    local quests = StepQuests(rxp, step)
                    local follow = FollowQuests(quests)
                    blocks[#blocks + 1] = {index = index, title = title, lines = lines, upcoming = true,
                        quests = quests, follow = follow}
                    AddToSignature(signature, "next", index, title, #follow)
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
    row.past = block.past
    row.state = kind == "line" and line.state or nil
    row.element = kind == "line" and line.element or nil
    row.missing = kind == "line" and line.missing or false
    row.quest = kind == "line" and line.quest or nil

    local indent = kind == "line" and dashWidth or 0
    local width = Width() - BLOCK_INDENT
    row.Dash:SetShown(row.state == "todo")
    row.Check:SetShown(row.state == "done")
    row.Toggle:SetShown(row.element ~= nil and row.state ~= "note" and not block.upcoming)
    row.Text:ClearAllPoints()
    row.Text:SetPoint("TOPLEFT", indent, 0)
    local shop = kind == "line" and line.shop or nil
    row.Shop.item = shop
    row.Shop:SetShown(shop ~= nil)
    if shop then Shop_Update(row.Shop) end
    -- The info button behind a step's title, when one of its quests leads on to others.
    local follow = kind == "title" and block.follow or {}
    row.quests = kind == "title" and block.quests or nil
    row.Info.quests = follow
    row.Info:SetShown(#follow > 0)
    local textWidth = width - indent - (shop and SHOP_SIZE + 2 or 0) - (#follow > 0 and INFO_SIZE + 4 or 0)
    row.Text:SetWidth(textWidth)
    local text = kind == "line" and line.text or block.title
    -- Names in guide text carry their own colours; a line that is red as a whole must not.
    if row.missing then text = (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
    row.Text:SetText(text)
    if #follow > 0 then
        local _, fontHeight = row.Text:GetFont()
        local x = indent + math.min(row.Text:GetStringWidth() or 0, textWidth) + 4
        row.Info:ClearAllPoints()
        row.Info:SetPoint("CENTER", row, "TOPLEFT", x + INFO_SIZE / 2, -(fontHeight or 12) / 2)
    end
    ColorRow(row)

    local height = math.max(row.Text:GetStringHeight() or 0, 10)
    if drawFloor and y - height < drawFloor then
        -- Would reach below the cut-off line: give the row back.
        usedRows = usedRows - 1
        return nil
    end
    row.drawY = y
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

-- Moves the rows from first on, laid out top-down from 0, so that 0 is "top" above the guide's lower edge.
local function Lift(first, top)
    for index = first, usedRows do
        local row = rows[index]
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", root, "BOTTOMLEFT", BLOCK_INDENT, top + row.drawY)
    end
end

-- Anchor Bottom, like RestedXP's "Current step frame anchor": the current step at the bottom, the next steps above
-- it, the nearest one closest, so the list grows upwards. Each block still reads top-down. Built from the lower edge
-- up; returns the height. With a limit, the steps furthest away are the ones left out.
local function DrawFlipped(active, upcoming, floor)
    local limit = floor and -floor
    drawFloor = limit and -(limit - HEADER_HEIGHT) or nil
    local y, cut = 0, false
    if not ns.db.activeCollapsed then y, cut = DrawBlocks(active, 0) end
    local top = -y
    Lift(1, top)
    activeHeader:ClearAllPoints()
    activeHeader:SetPoint("TOPLEFT", root, "BOTTOMLEFT", 0, top + HEADER_HEIGHT)
    top = top + HEADER_HEIGHT

    local showUpcoming = UpcomingCount() > 0 and (ns.db.upcomingCollapsed or #upcoming > 0)
    local needed = MODULE_GAP + HEADER_HEIGHT + (ns.db.upcomingCollapsed and 0 or BLOCK_GAP + 30)
    if cut or (limit and top + needed > limit) then showUpcoming = false end
    upcomingHeader:SetShown(showUpcoming)
    wheelArea:SetShown(showUpcoming and #upcoming > 0)
    if showUpcoming then
        top = top + MODULE_GAP
        local listBottom = top
        for _, block in ipairs(upcoming) do
            local first = usedRows + 1
            drawFloor = limit and -(limit - HEADER_HEIGHT - top) or nil
            local below, blockCut = DrawBlocks({block}, 0)
            Lift(first, top - below)
            top = top - below
            if blockCut then break end
        end
        upcomingHeader:ClearAllPoints()
        upcomingHeader:SetPoint("TOPLEFT", root, "BOTTOMLEFT", 0, top + HEADER_HEIGHT)
        SetCollapseButton(upcomingHeader.Collapse, ns.db.upcomingCollapsed)
        wheelArea:ClearAllPoints()
        wheelArea:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, listBottom)
        wheelArea:SetPoint("TOPRIGHT", root, "BOTTOMRIGHT", 0, top)
        top = top + HEADER_HEIGHT
    end
    return top
end

local function Draw(title, tooltipTitle, active, upcoming, floor)
    usedRows, nextBlock = 0, 0
    drawFloor = floor
    upcomingHeader.Text:SetText(scrollOffset < 0 and "Previous Steps" or "Upcoming Steps")
    upcomingHeader.Return:SetShown(scrollOffset ~= 0)

    activeHeader.Text:SetText(title)
    activeHeader.Next:SetShown(tooltipTitle ~= nil)
    activeHeader.Previous:SetShown(tooltipTitle ~= nil)
    local pinned = ns.db.pin ~= nil and tooltipTitle ~= nil
    activeHeader.Return:SetShown(pinned)
    activeHeader.Text:SetWidth(Width() - 132 - (pinned and 17 or 0))
    activeHeader.tooltipTitle = tooltipTitle
    SetCollapseButton(activeHeader.Collapse, ns.db.activeCollapsed)

    if ns.db.anchor == "BOTTOM" then
        local height = DrawFlipped(active, upcoming, floor)
        for index = usedRows + 1, #rows do rows[index]:Hide() end
        root:SetHeight(math.max(height, HEADER_HEIGHT))
        return
    end

    activeHeader:ClearAllPoints()
    activeHeader:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
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

-- Positions of Blizzard's frames are only read once the game has worked them out (IsRectValid). Asking for a position
-- that is still pending makes the game work it out on the spot, inside this addon's code: the tracker's OnSizeChanged
-- then marks it dirty from here, its next update runs tainted, and the world map's quest pins inherit that (blocked
-- SetPassThroughButtons in combat). Until the game has done its layout pass, the last position stays.
local function Resolved(region)
    return not region.IsRectValid or region:IsRectValid()
end

local attachedAt     -- {left, top} below the quest tracker, from the last resolved layout

local function Secret(...)
    if not issecretvalue then return false end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return true end
    end
    return false
end

-- A hidden tracker (nothing tracked) is never laid out, so it has no position of its own. Its anchor still says where
-- it would be: worked out from the frame it hangs on, once that one is laid out. Only for a single TOP* anchor, which
-- is how Blizzard and Edit Mode place it; returns the tracker's would-be top left in its own coordinates.
local function HiddenTrackerAnchor(tracker)
    if tracker:GetNumPoints() ~= 1 then return end
    local point, relative, relativePoint, x, y = tracker:GetPoint(1)
    if Secret(point, relative, relativePoint, x, y) or not point or not relativePoint or not point:find("TOP") then return end
    relative = relative or tracker:GetParent()
    if not relative or not Resolved(relative) then return end
    local l, r, t, b = relative:GetLeft(), relative:GetRight(), relative:GetTop(), relative:GetBottom()
    local width = tracker:GetWidth()
    if not (l and r and t and b and width) or Secret(l, r, t, b, width) then return end
    local ratio = relative:GetEffectiveScale() / tracker:GetEffectiveScale()
    local rx = relativePoint:find("LEFT") and l or relativePoint:find("RIGHT") and r or (l + r) / 2
    local ry = relativePoint:find("TOP") and t or relativePoint:find("BOTTOM") and b or (t + b) / 2
    local px, top = rx * ratio + (x or 0), ry * ratio + (y or 0)
    local left = point:find("LEFT") and px or point:find("RIGHT") and px - width or px - width / 2
    return left, top
end

local function TrackerAnchor(tracker)
    if not tracker:IsShown() and not Resolved(tracker) then return HiddenTrackerAnchor(tracker) end
    if not Resolved(tracker) or not tracker:GetLeft() then return end
    local left, top = tracker:GetLeft(), tracker:GetTop()
    if tracker:IsVisible() then
        local bottom
        local header = tracker.Header
        if header and header:IsVisible() then
            if not Resolved(header) then return end
            bottom = header:GetBottom()
            trackerOrigin = {
                left = header:GetLeft(), top = header:GetTop(), bottom = bottom, width = header:GetWidth(),
                scale = tracker:GetEffectiveScale() / UIParent:GetEffectiveScale(), uiScale = UIParent:GetEffectiveScale(),
            }
        end
        for _, module in ipairs(tracker.modules or {}) do
            if module:IsVisible() then
                if not Resolved(module) then return end
                local moduleBottom = module:GetBottom()
                if moduleBottom and (not bottom or moduleBottom < bottom) then bottom = moduleBottom end
            end
        end
        if bottom then top = bottom - MODULE_GAP end
    end
    return left, top
end

local function DefaultPosition(scale)
    return UIParent:GetWidth() / scale - Width() * UserScale() - 60, UIParent:GetHeight() / scale - 260
end

-- The last spot below the quest tracker is kept across reloads, together with the guide's scale it belongs to.
local function RememberAttached(left, top, scale)
    local saved = ns.db.attachedAt
    if saved and saved.scale == scale and math.abs(saved.left - left) < 0.5 and math.abs(saved.top - top) < 0.5 then
        return
    end
    ns.db.attachedAt = {left = left, top = top, scale = scale}
end

local function Place()
    local tracker = ObjectiveTrackerFrame
    local replaced = trackerHidden and trackerOrigin   -- the origin is gone only until it can be measured again
    local scale = root.baseScale or 1   -- a shrunk tracker without its measurement says nothing: keep the last one
    if replaced then
        scale = trackerOrigin.scale
    elseif tracker and not trackerHidden then
        scale = tracker:GetEffectiveScale() / UIParent:GetEffectiveScale()
    elseif not tracker then
        scale = 1
    end
    -- Positions are in the quest tracker's scale; the guide is drawn at that scale times the Scale setting.
    root.baseScale = scale
    local u = UserScale()
    if math.abs(root:GetScale() - scale * u) > 0.001 then
        root:SetScale(scale * u)
        root.placedAt = nil
    end

    local left, top
    if ns.db.attach and tracker and replaced then
        left, top = trackerOrigin.left, trackerOrigin.bottom - MODULE_GAP
        RememberAttached(left, top, scale)
    elseif ns.db.attach and tracker and trackerHidden then
        if attachedAt then left, top = attachedAt[1], attachedAt[2] end
    elseif ns.db.attach and tracker then
        left, top = TrackerAnchor(tracker)
        if left then
            attachedAt = {left, top}
            RememberAttached(left, top, scale)
        elseif attachedAt then
            left, top = attachedAt[1], attachedAt[2]
        end
    end
    if not left and ns.db.attach and tracker then
        -- The tracker has no position yet (right after loading, or the game never lays it out because it stays
        -- hidden). Waiting for it could keep the guide away for good: until it can be measured, the guide stands
        -- where it was attached last time, or at the default place, without making that the detached position.
        local saved = ns.db.attachedAt
        if saved and math.abs((saved.scale or 0) - scale) < 0.001 then
            left, top = saved.left, saved.top
        else
            left, top = DefaultPosition(scale)
        end
    end
    local bottom
    if not left then
        if not ns.db.position then
            -- Detached for the first time: stay where it is.
            local defaultLeft, defaultTop = DefaultPosition(scale)
            local l, t = root:GetLeft(), root:GetTop()
            ns.db.position = {left = l and l * u or defaultLeft, top = t and t * u or defaultTop}
        end
        left, top, bottom = ns.db.position.left, ns.db.position.top, ns.db.position.bottom
        -- Detached, the anchor says which edge stays where it was dragged to.
        if ns.db.anchor == "BOTTOM" and bottom then top = nil else bottom = nil end
    end

    -- The box: the fixed edge, and the other one a height away, kept on the screen.
    local height
    if ns.db.limit then
        local room = top or UIParent:GetHeight() / scale - bottom
        height = math.min(Height(), math.max(room / u, MIN_ROOM))
    end
    box.fixed = top and "top" or "bottom"
    if top then
        bottom = height and top - height * u
    else
        top = height and bottom + height * u
    end
    box.top, box.bottom, box.height = top, bottom, height

    local point = ns.db.anchor == "BOTTOM" and bottom and "BOTTOMLEFT" or "TOPLEFT"
    local y = point == "BOTTOMLEFT" and bottom or top
    local placedAt = point .. ":" .. left .. ":" .. y .. ":" .. u
    if root.placedAt ~= placedAt and not root.moving then
        root.placedAt = placedAt
        root.anchorPoint = point
        root:ClearAllPoints()
        root:SetPoint(point, UIParent, "BOTTOMLEFT", left / u, y / u)
    end
    return left, height
end

local function PlaceGrip(left)
    if not box.height then return grip:Hide() end
    local u = UserScale()
    local edge = box.fixed == "bottom" and box.top or box.bottom
    grip:ClearAllPoints()
    grip:SetPoint("LEFT", UIParent, "BOTTOMLEFT", left / u, edge / u)
    -- Only in the way while the mouse is on the guide.
    local scale = root:GetEffectiveScale() / u
    local x, y = GetCursorPosition()
    x, y = x / scale, y / scale
    local margin = 12 * u
    grip:SetShown(gripDragging or (x >= left and x <= left + Width() * u
        and y <= box.top + margin and y >= box.bottom - margin))
end

--------------------------------------------------------------------------------------------------
-- The guide in place of the quest tracker. While a guide is shown, Blizzard's tracker is made invisible and moved
-- off the screen, and a copy of its header bar with Blizzard's "+" button stands where it was, the guide below it.
-- "+" brings the real tracker back until the guide is hidden or the interface reloads.
--
-- Only alpha, clamping and the anchors' x offsets are changed: that runs none of Blizzard's code. Collapsing or hiding
-- the tracker would. SetCollapsed runs its layout in this addon's code, which taints it and, through its quest buttons,
-- the world map (blocked SetPassThroughButtons in combat); Hide runs the layout of the right-hand frame column with
-- the action bars. Its scale must stay too: that column lays out with the child's scale, so a tracker shrunk while the
-- column was laid out ends up far off its place and too short once it is back. Its height comes from the anchor's y
-- offset, which is kept. When Blizzard anchors it anew, it is moved away again. Moving it waits for the end of a fight
-- (it holds protected item buttons).

local AWAY = 10000      -- x offset that puts the tracker right of any screen
local stand

local function EditModeOpen()
    return EditModeManagerFrame and EditModeManagerFrame:IsShown() or false
end

local function Plain(...)
    if not issecretvalue then return true end
    for i = 1, select("#", ...) do
        if issecretvalue((select(i, ...))) then return false end
    end
    return true
end

local function TrackerPoints(tracker)
    local points = {}
    for i = 1, tracker:GetNumPoints() do
        local point = {tracker:GetPoint(i)}
        if not Plain(unpack(point, 1, 5)) then return end
        points[i] = point
    end
    return points
end

local function SamePoints(a, b)
    if not a or not b or #a ~= #b then return false end
    for i, p in ipairs(a) do
        local q = b[i]
        if p[1] ~= q[1] or p[2] ~= q[2] or p[3] ~= q[3]
            or math.abs((p[4] or 0) - (q[4] or 0)) > 0.01 or math.abs((p[5] or 0) - (q[5] or 0)) > 0.01 then
            return false
        end
    end
    return true
end

local function SetPoints(tracker, points, dx)
    tracker:ClearAllPoints()
    for _, p in ipairs(points) do
        tracker:SetPoint(p[1], p[2], p[3], (p[4] or 0) + dx, p[5] or 0)
    end
end

-- Moves the tracker away from where Blizzard anchored it; false when it has no usable anchors.
local function MoveAway(tracker)
    local points = TrackerPoints(tracker)
    if not points or #points == 0 then return false end
    SetPoints(tracker, points, AWAY)
    trackerAway.home, trackerAway.away = points, TrackerPoints(tracker)
    return true
end

local function SetTrackerHidden(tracker, hide)
    if hide then
        trackerAway = {clamped = tracker:IsClampedToScreen()}
        tracker:SetClampedToScreen(false)
        if not MoveAway(tracker) then
            tracker:SetClampedToScreen(trackerAway.clamped)
            trackerAway = nil
            return
        end
        tracker:SetAlpha(0)
    else
        if trackerAway then
            -- Unless Blizzard has anchored it anew meanwhile, put it back where it was.
            if SamePoints(TrackerPoints(tracker), trackerAway.away) then SetPoints(tracker, trackerAway.home, 0) end
            tracker:SetClampedToScreen(trackerAway.clamped)
        end
        tracker:SetAlpha(1)
        trackerAway = nil
        -- Until the tracker can be measured again, the guide stays under its header bar.
        if trackerOrigin then attachedAt = {trackerOrigin.left, trackerOrigin.bottom - MODULE_GAP} end
    end
    trackerHidden = hide
end

local function UpdateQuestTracker(guideShown)
    local tracker = ObjectiveTrackerFrame
    if not tracker then return end
    if not guideShown then trackerShownByUser = nil end
    -- Measured again after Edit Mode (it may have been moved) or a change of the UI scale.
    if EditModeOpen() or (trackerOrigin and trackerOrigin.uiScale ~= UIParent:GetEffectiveScale()) then
        trackerOrigin = nil
    end
    if InCombatLockdown() then return end

    local want = ns.db.hideQuests and ns.db.tracker and guideShown and not trackerShownByUser and not EditModeOpen()
        and trackerOrigin ~= nil or false
    if want ~= (trackerHidden or false) then
        SetTrackerHidden(tracker, want)
    elseif trackerHidden then
        -- Blizzard may have anchored it anew or shown it again; keep it away.
        if not SamePoints(TrackerPoints(tracker), trackerAway.away) then MoveAway(tracker) end
        if tracker:IsClampedToScreen() then tracker:SetClampedToScreen(false) end
        if tracker:GetAlpha() > 0 then tracker:SetAlpha(0) end
    end
end

local function Stand_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:AddLine("Show the quest tracker", 1, 1, 1)
    if trackerShownByUser then
        GameTooltip:AddLine("It comes back when the fight is over.", 0.8, 0.8, 0.8, true)
    elseif InCombatLockdown() then
        GameTooltip:AddLine("During a fight it comes back when the fight is over.", 0.8, 0.8, 0.8, true)
    end
    GameTooltip:Show()
end

-- Looks like the tracker's own header bar (ObjectiveTrackerContainerHeaderTemplate).
local function CreateStand()
    stand = CreateFrame("Frame", nil, root)
    stand:SetHeight(32)
    stand.Background = stand:CreateTexture(nil, "BACKGROUND")
    stand.Background:SetAtlas("ui-questtracker-primary-objective-header", true)
    stand.Background:SetPoint("CENTER")
    stand.Text = stand:CreateFontString(nil, "ARTWORK",
        ObjectiveTrackerHeaderFont and "ObjectiveTrackerHeaderFont" or "GameFontNormalMed2")
    stand.Text:SetPoint("LEFT", 7, 0)
    stand.Text:SetWidth(208)
    stand.Text:SetJustifyH("LEFT")
    stand.Text:SetWordWrap(false)
    stand.Button = CreateFrame("Button", nil, stand)
    stand.Button:SetSize(18, 19)
    stand.Button:SetPoint("RIGHT", -1, 0)
    stand.Button:SetNormalAtlas("ui-questtrackerbutton-expand-all")
    stand.Button:SetPushedAtlas("ui-questtrackerbutton-expand-all-pressed")
    stand.Button:SetHighlightAtlas("ui-questtrackerbutton-red-highlight", "ADD")
    stand.Button:SetScript("OnClick", function(button)
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        trackerShownByUser = true
        ns.Refresh()
        if button:IsMouseOver() then Stand_OnEnter(button) end
    end)
    stand.Button:SetScript("OnEnter", Stand_OnEnter)
    stand.Button:SetScript("OnLeave", GameTooltip_Hide)
end

local function PlaceStand()
    if not (trackerHidden and trackerOrigin) then
        if stand then stand:Hide() end
        return
    end
    if not stand then CreateStand() end
    local tracker = ObjectiveTrackerFrame
    local text = tracker.Header and tracker.Header.Text and tracker.Header.Text:GetText()
    stand.Text:SetText(text or TRACKER_ALL_OBJECTIVES or "All Objectives")
    stand:SetScale(1 / UserScale())
    stand:SetWidth(trackerOrigin.width)
    stand:ClearAllPoints()
    stand:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", trackerOrigin.left, trackerOrigin.top)
    stand:Show()
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
    if trackerHidden and ObjectiveTrackerFrame and not InCombatLockdown() then
        SetTrackerHidden(ObjectiveTrackerFrame, false)
    end
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

    ApplyWidth()
    local left, height = Place()
    if not left then return end
    local floor = height and -height or nil
    AddToSignature(signature, title, floor and math.floor(floor) or "", Width(), ns.db.anchor)

    signature = table.concat(signature, "\031")
    if signature ~= lastSignature or ns.forceRedraw then
        lastSignature = signature
        ns.forceRedraw = nil
        Draw(title, tooltipTitle, active, upcoming, floor)
    end
    PlaceGrip(left)
    PlaceStand()
    root:Show()
end

ns.RegisterPart("quest tracker style", Update, Disable)

--------------------------------------------------------------------------------------------------
-- Going back. A step that is already done is ticked off again by RestedXP the moment it becomes the current step,
-- and RestedXP goes on at once (UpdateStepCompletion sets loadNextStep). For the step the player went back to on
-- purpose (ns.db.pin, see Pin) that is held back, so the step stays until the player goes on.

local completion
ns.RegisterPart("going back", function(rxp)
    if completion then return end
    assert(type(rxp.UpdateStepCompletion) == "function", "RestedXP has no UpdateStepCompletion")
    local original = rxp.UpdateStepCompletion
    local function wrapper(...)
        local result = original(...)
        local pin = ns.db.pin
        local guide = rxp.currentGuide
        if pin and rxp.loadNextStep and type(guide) == "table" and not guide.empty and GuideId(guide) == pin.guide
            and rxp.GetGuideProgress() == pin.step then
            rxp.loadNextStep = false
        end
        return result
    end
    completion = {original = original, wrapper = wrapper}
    rxp.UpdateStepCompletion = wrapper
end, function()
    local rxp = ns.GetRXP()
    if rxp and completion and rxp.UpdateStepCompletion == completion.wrapper then
        rxp.UpdateStepCompletion = completion.original
    end
    ns.db.pin = nil
end)

--------------------------------------------------------------------------------------------------
-- Steps with missing prerequisites. RestedXP skips a step on its own when its quest is not in the quest log
-- (.isOnQuest) or a quest before it is not done (.isQuestTurnedIn): "Step skipped: Missing pre-requisites". With
-- holdMissing such a step stays, with a red line naming the missing quest, until the player ticks that line off or
-- the condition is met. Not for quests already turned in or meant for another race or class: those are skipped.

local HOLD_TAGS = {isOnQuest = "log", isQuestTurnedIn = "done"}
local originals = {}

local function QuestTitle(id)
    local name = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    if not name and ns.QuestHint then
        local ok, hint = pcall(ns.QuestHint, id)
        name = ok and type(hint) == "table" and hint.name or nil
    end
    return name or ("Quest " .. id)
end

-- The quest whose absence made RestedXP skip the step, when the step is worth keeping for it.
local function MissingQuest(rxp, kind, element)
    for _, raw in pairs(element.questIds or {}) do
        local id = tonumber(raw)
        id = id and rxp.GetQuestId and rxp.GetQuestId(id, nil, true) or id
        if id and not rxp.IsQuestTurnedIn(id) and not (kind == "log" and rxp.IsOnQuest(id))
            and (not ns.QuestForMe or ns.QuestForMe(id)) then
            return id
        end
    end
end

local function Checked(rxp, tag, frame, event, ...)
    local element = frame.element
    local step = element.step
    local before = step and step.completed
    local result = originals[tag](frame, event, ...)
    if not (step and step.active) or element.reverse then return result end
    if before or not step.completed then
        -- Not skipped by this call: a hold of this element ends once its condition is met.
        if not step.completed and held[step] and held[step].frame == frame and event ~= "WindowUpdate" then
            held[step] = nil
        end
        return result
    end
    if not ns.db.holdMissing or released[step] then return result end
    local id = MissingQuest(rxp, HOLD_TAGS[tag], element)
    if not id then return result end
    step.completed = false
    element.tooltipText = nil
    local hold = held[step]
    if not (hold and hold.frame == frame and hold.id == id) then
        local kind = HOLD_TAGS[tag]
        hold = {frame = frame, tag = tag, id = id, kind = kind, name = QuestTitle(id)}
        hold.marker = {heldStep = step, headline = kind == "log" and
            "RestedXP would skip this step: this quest is not in your quest log." or
            "RestedXP would skip this step: this quest is not done."}
        held[step] = hold
    end
    return result
end

-- Element frames keep the function they were bound with: point the active ones at the current one.
local function Rebind(from, to)
    for _, step in ipairs(RXPFrame and RXPFrame.activeSteps or {}) do
        for _, element in ipairs(step.elements or {}) do
            local frame = element.frame
            if frame and frame.element == element and HOLD_TAGS[element.tag] and frame.callback == from[element.tag] then
                frame.callback = to[element.tag]
            end
        end
    end
end

local wrappers
ns.RegisterPart("missing prerequisite steps", function(rxp)
    if not wrappers then
        local functions = rxp.functions
        assert(type(functions) == "table" and type(rxp.IsOnQuest) == "function" and type(rxp.IsQuestTurnedIn) == "function",
            "RestedXP's quest checks are missing")
        local made = {}
        for tag in pairs(HOLD_TAGS) do
            assert(type(functions[tag]) == "function", "RestedXP has no " .. tag)
            originals[tag] = functions[tag]
            made[tag] = function(self, text, ...)
                if type(self) ~= "table" or type(self.element) ~= "table" then return originals[tag](self, text, ...) end
                return Checked(rxp, tag, self, text, ...)
            end
        end
        for tag, wrapper in pairs(made) do functions[tag] = wrapper end
        wrappers = made
        Rebind(originals, wrappers)
        rxp.updateSteps = true
    end
    -- Switched off: let RestedXP skip what is held.
    if not ns.db.holdMissing and next(held) then
        for step in pairs(held) do ReleaseStep(rxp, step) end
    end
end, function()
    local rxp = ns.GetRXP()
    if not (rxp and wrappers) then return end
    for tag, original in pairs(originals) do
        if rxp.functions[tag] == wrappers[tag] then rxp.functions[tag] = original end
    end
    Rebind(wrappers, originals)
    for step in pairs(held) do held[step] = nil end
end)
