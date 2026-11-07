local addonName, ns = ...

-- The guide drawn like a section of Blizzard's quest tracker: a header bar with the guide's name,
-- the active steps as "quests" with their lines as objectives, and a second section with the
-- upcoming steps. Measurements are those of Blizzard_ObjectiveTracker (module, block, line).
local WIDTH = 260
local HEADER_HEIGHT = 25
local BLOCK_INDENT = 20
local SHOP_SIZE = 14
local BLOCK_GAP = 10
local LINE_GAP = 4
local MODULE_GAP = 10
local MAX_UPCOMING_SCAN = 400
local DEFAULT_WINDOW = 350
local MIN_ROOM = 150   -- what the guide keeps below an open quest tracker, cut-off line or not

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

local function ShowQuestieTooltip(row)
    local element = row.quest
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

local function Row_OnEnter(row)
    SetHoveredBlock(row.block)
    local tooltip = row.element and row.element.tooltip
    if type(tooltip) ~= "string" or tooltip == "" then tooltip = nil end
    if ShowQuestieTooltip(row) then
        if tooltip or row.missing then GameTooltip:AddLine(" ") end
        if tooltip then GameTooltip:AddLine(tooltip, 1, 1, 1, true) end
        if row.missing then GameTooltip:AddLine("You do not have this quest.", 1, 0.1, 0.1) end
        GameTooltip:Show()
    elseif tooltip or row.missing then
        GameTooltip:SetOwner(row, "ANCHOR_LEFT")
        if tooltip then GameTooltip:AddLine(tooltip, 1, 1, 1, true) end
        if row.missing then GameTooltip:AddLine("You do not have this quest.", 1, 0.1, 0.1) end
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
    if row and row:IsVisible() and row:IsMouseOver() and GameTooltip:GetOwner() == row then Row_OnEnter(row) end
end)

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
                    local shop = ns.ShopItem(step, element)
                    block.lines[#block.lines + 1] = {text = icon .. text, state = state, element = element, missing = missing, shop = shop,
                        quest = QuestElement(element)}
                    AddToSignature(signature, state, icon, text, missing, shop and shop.id, shop and shop.qty)
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
            lines[#lines + 1] = {text = text, state = state, missing = QuestMissing(rxp, guide, element, index, current),
                quest = QuestElement(element)}
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
    row.quest = kind == "line" and line.quest or nil

    local indent = kind == "line" and dashWidth or 0
    local width = WIDTH - BLOCK_INDENT
    row.Dash:SetShown(row.state == "todo")
    row.Check:SetShown(row.state == "done")
    row.Toggle:SetShown(row.element ~= nil and row.state ~= "note" and not block.upcoming)
    row.Text:ClearAllPoints()
    row.Text:SetPoint("TOPLEFT", indent, 0)
    local shop = kind == "line" and line.shop or nil
    row.Shop.item = shop
    row.Shop:SetShown(shop ~= nil)
    if shop then Shop_Update(row.Shop) end
    row.Text:SetWidth(width - indent - (shop and SHOP_SIZE + 2 or 0))
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
    return UIParent:GetWidth() / scale - WIDTH - 60, UIParent:GetHeight() / scale - 260
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
    local scale = root:GetScale()   -- a shrunk tracker without its measurement says nothing: keep the last one
    if replaced then
        scale = trackerOrigin.scale
    elseif tracker and not trackerHidden then
        scale = tracker:GetEffectiveScale() / UIParent:GetEffectiveScale()
    elseif not tracker then
        scale = 1
    end
    if math.abs(root:GetScale() - scale) > 0.001 then
        root:SetScale(scale)
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
    if not left then
        if not ns.db.position then
            -- Detached for the first time: stay where it is.
            local defaultLeft, defaultTop = DefaultPosition(scale)
            ns.db.position = {left = root:GetLeft() or defaultLeft, top = root:GetTop() or defaultTop}
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

    local left, top = Place()
    if not left then return end
    local floor
    if ns.db.limit then
        -- Until the line has been dragged somewhere, the guide gets DEFAULT_WINDOW of height, but
        -- stays out of the lowest fifth of the screen.
        if not ns.db.bottom then
            ns.db.bottom = math.max(top - DEFAULT_WINDOW, UIParent:GetHeight() / root:GetScale() * 0.2)
        end
        -- An open quest tracker can reach down to the line or past it. The guide keeps room for its
        -- current step then, otherwise nothing but its bar would be left.
        local tracker = ObjectiveTrackerFrame
        local open = tracker and not trackerHidden and tracker.IsCollapsed and not tracker:IsCollapsed()
        floor = math.min(ns.db.bottom - top, open and -MIN_ROOM or -HEADER_HEIGHT)
    end
    AddToSignature(signature, title, floor and math.floor(floor) or "")

    signature = table.concat(signature, "\031")
    if signature ~= lastSignature or ns.forceRedraw then
        lastSignature = signature
        ns.forceRedraw = nil
        Draw(title, tooltipTitle, active, upcoming, floor)
    end
    PlaceGrip(left, top)
    PlaceStand()
    root:Show()
end

ns.RegisterPart("quest tracker style", Update, Disable)
