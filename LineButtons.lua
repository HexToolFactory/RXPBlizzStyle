local addonName, ns = ...

-- Small buttons on a line of the current step, at its end or its start (option lineButtons): target the NPC to talk to (a quest to
-- pick up or hand in), target a mob of the line (an objective: those to kill and those that drop the item), or use
-- the line's item. Who is meant comes from Questie (the quest's giver, ender and objective NPCs), else from the
-- step's own RestedXP targets (.target, .mob, .unitscan) and items (.use, the quest's items).
--
-- The buttons are secure (a /targetexact macro, an item), so they sit in a holder of their own on UIParent and are
-- placed by position, never anchored to the guide: the guide moves and redraws during fights, which a frame with
-- secure buttons on it could not. Out of a fight they follow the lines on every tick. During one nothing about them
-- can change: a button whose line moved or went away turns invisible until the fight is over.
-- RestedXP's own target macro (RXPTargeting) and its key bindings are not touched.

local SIZE = 16
local GAP = 2
local MAX_PER_LINE = 3
local ENEMY_ICON = 135274      -- RestedXP's own placeholders: a sword for mobs,
local FRIENDLY_ICON = 2056011  -- a speech bubble for NPCs
ns.LINE_BUTTON_SIZE, ns.LINE_BUTTON_GAP = SIZE, GAP

--------------------------------------------------------------------------------------------------
-- Which buttons a line gets

local function ItemCount(id)
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or GetItemCount and GetItemCount(id)
    return tonumber(count) or 0
end

local function ItemIcon(id)
    return C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id) or GetItemIcon and GetItemIcon(id)
end

local function CreatureName(rxp, unit)
    if type(unit) == "string" and unit ~= "" then
        if rxp.GetCreatureName then return rxp.GetCreatureName(unit) or unit end
        return unit
    end
    if type(unit) == "number" and rxp.GetCreatureName then return rxp.GetCreatureName(unit) end
end

local function RealId(rxp, id)
    return rxp.GetQuestId and rxp.GetQuestId(id, nil, true) or id
end

-- An item list of RestedXP's (questCompleteItems and the like) holds this item for the quest.
local function QuestHasItem(list, questId, item)
    local entry = type(list) == "table" and list[questId]
    if type(entry) == "table" then
        for _, value in pairs(entry) do if value == item then return true end end
        return false
    end
    return entry == item
end

-- The quest's objective mobs, those of the player's map first.
local function LocalMobs(mobs)
    local map = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local here = {}
    for _, mob in ipairs(mobs) do
        if map and type(mob.maps) == "table" and mob.maps[map] then here[#here + 1] = mob end
    end
    return #here > 0 and here or mobs
end

-- Sets line.buttons ({kind = "target" / "mob" / "item", name, item, icon, key}) on the lines of an active step that
-- still have something to do. Each name or item once per step.
function ns.LineButtonsForStep(rxp, step, lines)
    local todo = {}
    for _, line in ipairs(lines) do
        if line.state == "todo" and line.element then todo[#todo + 1] = line end
    end
    if #todo == 0 then return end
    local used = {}
    local function add(line, button)
        if not line then return end
        button.key = button.kind .. ":" .. (button.item or button.name)
        if used[button.key] then return end
        line.buttons = line.buttons or {}
        if #line.buttons >= MAX_PER_LINE then return end
        used[button.key] = true
        line.buttons[#line.buttons + 1] = button
    end
    local function unit(line, kind, name)
        if type(name) == "string" and name ~= "" then
            add(line, {kind = kind, name = name, icon = kind == "mob" and ENEMY_ICON or FRIENDLY_ICON})
        end
    end
    local function item(line, id)
        if type(id) == "number" and ItemCount(id) > 0 then
            add(line, {kind = "item", item = id, icon = ItemIcon(id) or 134400})
        end
    end

    -- Items: a .use line has its own; the step's other items go to the quest they belong to, else the first line.
    for _, line in ipairs(todo) do
        for id in pairs(type(line.element.activeItems) == "table" and line.element.activeItems or {}) do item(line, id) end
    end
    for id, active in pairs(type(step.activeItems) == "table" and step.activeItems or {}) do
        if active then
            local home = todo[1]
            for _, line in ipairs(todo) do
                local quest = line.quest and RealId(rxp, line.quest.questId)
                if quest and (QuestHasItem(rxp.questCompleteItems, quest, id) or QuestHasItem(rxp.questAcceptItems, quest, id)
                    or QuestHasItem(rxp.questTurnInItems, quest, id)) then
                    home = line
                    break
                end
            end
            item(home, id)
        end
    end

    -- Units of the quest lines, from Questie: the giver to pick up from, the NPC to hand in to, the objective's mobs.
    local fromQuestie = {}
    for _, line in ipairs(todo) do
        local quest = line.quest
        local units = quest and ns.QuestUnits and ns.QuestUnits(RealId(rxp, quest.questId))
        if units then
            local tag = line.element.tag
            if tag == "accept" and units.starter then
                unit(line, "target", units.starter.name)
            elseif tag == "turnin" and units.ender then
                unit(line, "target", units.ender.name)
            elseif tag == "complete" then
                for _, mob in ipairs(LocalMobs(units.mobs or {})) do unit(line, "mob", mob.name) end
            end
            fromQuestie[line] = line.buttons ~= nil
        end
    end

    -- The step's own RestedXP units: NPCs to the pick up and hand in lines, mobs to the objective lines (one Questie
    -- did not fill first), else the first line that is not about a quest, else the first line.
    local friendly, enemy = {}, {}
    for _, element in ipairs(step.elements or {}) do
        for _, t in ipairs(type(element.targets) == "table" and element.targets or {}) do friendly[#friendly + 1] = CreatureName(rxp, t) end
        for _, list in ipairs({element.mobs, element.unitscan}) do
            for _, t in ipairs(type(list) == "table" and list or {}) do enemy[#enemy + 1] = CreatureName(rxp, t) end
        end
    end
    local function home(tags)
        for _, line in ipairs(todo) do
            if tags[line.element.tag] and not fromQuestie[line] then return line end
        end
        for _, line in ipairs(todo) do
            if tags[line.element.tag] then return line end
        end
        for _, line in ipairs(todo) do
            if not line.quest then return line end
        end
        return todo[1]
    end
    if #friendly > 0 then
        local line = home({accept = true, turnin = true})
        for _, name in ipairs(friendly) do unit(line, "target", name) end
    end
    if #enemy > 0 then
        local line = home({complete = true})
        for _, name in ipairs(enemy) do unit(line, "mob", name) end
    end
end

--------------------------------------------------------------------------------------------------
-- Where on a line they go

-- For the guide's rows: count buttons on this line, most on any line of the step, the row's width and the room the
-- shop button takes at its right end. lineButtonSide Right: a line's buttons at the row's right end, left of the
-- shop button. Left: they stick out to the left of the row, past the check mark; the text stays where it is.
-- Returns each button's left edge from the row's left (nil without buttons), how far the text moves right (always 0
-- now) and the room the buttons take at the right end.
function ns.LineButtonSlots(count, most, width, shopRoom)
    local step = SIZE + GAP
    local onLeft = ns.db.lineButtonSide == "LEFT"
    if count == 0 then return nil, 0, 0 end
    -- On the left the check mark reaches 10 past the row's start, unless the text sits on the right (it follows it).
    local first = onLeft and -(ns.db.textAlign == "RIGHT" and 0 or 10) - count * step
        or width - shopRoom - count * step + GAP
    local slots = {}
    for n = 1, count do slots[n] = first + (n - 1) * step end
    return slots, 0, onLeft and 0 or count * step
end

--------------------------------------------------------------------------------------------------
-- The secure buttons

local holder
local pool = {}

local function Button_OnEnter(button)
    local data = button.data
    if not data or GameTooltip:IsForbidden() then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    if data.kind == "item" then
        GameTooltip:SetItemByID(data.item)
    else
        GameTooltip:AddLine("Target " .. data.name, 1, 1, 1)
        GameTooltip:AddLine(data.kind == "mob" and "Mob of this line" or "NPC of this line", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function Button_OnLeave(button)
    if not GameTooltip:IsForbidden() and GameTooltip:GetOwner() == button then GameTooltip:Hide() end
end

local function NewButton()
    if not holder then
        holder = CreateFrame("Frame", "RXPBlizzStyleLineButtons", UIParent)
        holder:SetSize(1, 1)
        holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 0, 0)
        holder:SetFrameStrata("LOW")
    end
    local index = #pool + 1
    local button = CreateFrame("Button", "RXPBlizzStyleLineButton" .. index, holder, "SecureActionButtonTemplate")
    button:SetSize(SIZE, SIZE)
    button:RegisterForClicks("AnyUp", "AnyDown")
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetAllPoints()
    button:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square", "ADD")
    button.cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
    button.cooldown:SetAllPoints()
    button:SetScript("OnEnter", Button_OnEnter)
    button:SetScript("OnLeave", Button_OnLeave)
    button:Hide()
    pool[index] = button
    return button
end

-- What a button is showing: the row, its place on the row, what it does, and where the row is. The guide sets each
-- button's place on its row (row.buttonSlots, from the options Line buttons side and alignment).
local function Want(row, n, data)
    local left, top = row:GetLeft(), row:GetTop()
    local slot = row.buttonSlots and row.buttonSlots[n]
    if not (left and top and slot) then return end
    left = left + slot
    top = top + (SIZE - 12) / 2
    return {row = row, data = data, left = left, top = top,
        key = ("%s|%d|%s|%d|%d"):format(tostring(row), n, data.key, math.floor(left + 0.5), math.floor(top + 0.5))}
end

local function Wanted()
    local list = {}
    if not ns.db.lineButtons or not ns.TrackerRows then return list end
    local rows, count, root = ns.TrackerRows()
    if not (root and root:IsVisible()) then return list end
    for index = 1, count do
        local row = rows[index]
        if row:IsShown() and row.buttons and not row.upcoming and (not row.IsRectValid or row:IsRectValid()) then
            for n, data in ipairs(row.buttons) do
                local want = Want(row, n, data)
                if want then list[#list + 1] = want end
            end
        end
    end
    return list, root
end

local function Configure(button, want)
    local data = want.data
    button.data = data
    if data.kind == "item" then
        button:SetAttribute("type", "item")
        button:SetAttribute("macrotext", nil)
        button:SetAttribute("item", "item:" .. data.item)
    else
        button:SetAttribute("type", "macro")
        button:SetAttribute("item", nil)
        button:SetAttribute("macrotext", "/targetexact " .. data.name)
    end
    button.icon:SetTexture(data.icon)
    button:ClearAllPoints()
    button:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", want.left, want.top)
    button.key = want.key
end

local function Cooldown(button)
    local data = button.data
    if not (data and data.kind == "item") then return button.cooldown:Hide() end
    local get = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    local start, duration, enable = 0, 0, 0
    if get then start, duration, enable = get(data.item) end
    if enable and enable ~= 0 and (duration or 0) > 1.5 then
        button.cooldown:SetCooldown(start, duration)
        button.cooldown:Show()
    else
        button.cooldown:Hide()
    end
end

local function Update()
    local wanted, root = Wanted()
    if InCombatLockdown() then
        -- Nothing can be placed, set or hidden now: a button still right stays, the others turn invisible.
        local right = {}
        for _, want in ipairs(wanted) do right[want.key] = true end
        for _, button in ipairs(pool) do
            if button:IsShown() then
                button:SetAlpha(right[button.key] and 1 or 0)
                if right[button.key] then Cooldown(button) end
            end
        end
        return
    end
    if #wanted > 0 or holder then
        if not holder then NewButton() end
        local scale = root and root:GetEffectiveScale() / UIParent:GetEffectiveScale() or 1
        if math.abs(holder:GetScale() - scale) > 0.0001 then holder:SetScale(scale) end
        if root then holder:SetFrameLevel(root:GetFrameLevel() + 20) end
    end
    for index, want in ipairs(wanted) do
        local button = pool[index] or NewButton()
        if button.key ~= want.key then Configure(button, want) end
        button:SetAlpha(1)
        button:Show()
        Cooldown(button)
    end
    for index = #wanted + 1, #pool do
        local button = pool[index]
        if button:IsShown() then
            button:Hide()
            button.key, button.data = nil, nil
        end
    end
end

local function Disable()
    for _, button in ipairs(pool) do
        if InCombatLockdown() then button:SetAlpha(0) else button:Hide() end
        button.key = nil
    end
end

ns.RegisterPart("target and item buttons on lines", Update, Disable)
