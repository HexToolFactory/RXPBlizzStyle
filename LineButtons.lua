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

-- A line's text without colours and icons, in lower case, to look for names in.
local function PlainText(text)
    if type(text) ~= "string" then return "" end
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""):lower())
end

local function Mentions(text, name)
    return type(name) == "string" and name ~= "" and text:find(name:lower(), 1, true) ~= nil
end

-- The mobs of the quest objective a line is about: the objective named in the line's text ("5/8 Blackwood Pathfinder
-- slain", "2/6 Moonstalker Fang"), else the only objective, else all of the quest's mobs.
local function LineMobs(units, text)
    local objectives = type(units.objectives) == "table" and units.objectives or {}
    for _, objective in ipairs(objectives) do
        if Mentions(text, objective.name) then return objective.mobs end
    end
    if #objectives == 1 then return objectives[1].mobs end
    return units.mobs or {}
end

-- Sets line.buttons ({kind = "target" / "mob" / "item", name, names, item, icon, key}) on the lines of an active step
-- that still have something to do: one button per line. A button with several names (mobs that all drop the line's
-- item) targets the nearest of them. Each name or item once per step.
function ns.LineButtonsForStep(rxp, step, lines)
    local todo = {}
    for _, line in ipairs(lines) do
        if line.state == "todo" and line.element then todo[#todo + 1] = line end
    end
    if #todo == 0 then return end
    local used = {}
    local function free(line) return line and not line.buttons end
    local function add(line, button)
        if not free(line) then return end
        local key = button.item or table.concat(button.names, "/")
        button.key = button.kind .. ":" .. key
        line.buttons = {button}
    end
    local function unit(line, kind, names)
        if not free(line) then return end
        local list, seen = {}, {}
        for _, name in ipairs(names) do
            if type(name) == "string" and name ~= "" and not used[kind .. ":" .. name] and not seen[name] then
                seen[name] = true
                list[#list + 1] = name
            end
        end
        if #list == 0 then return end
        for _, name in ipairs(list) do used[kind .. ":" .. name] = true end
        add(line, {kind = kind, name = list[1], names = list, icon = kind == "mob" and ENEMY_ICON or FRIENDLY_ICON})
    end
    local function item(line, id)
        if free(line) and type(id) == "number" and not used["item:" .. id] and ItemCount(id) > 0 then
            used["item:" .. id] = true
            add(line, {kind = "item", item = id, icon = ItemIcon(id) or 134400})
        end
    end

    -- Items: a .use line has its own; an item of the step goes to the quest it belongs to.
    for _, line in ipairs(todo) do
        for id in pairs(type(line.element.activeItems) == "table" and line.element.activeItems or {}) do item(line, id) end
    end
    local loose = {}
    for id, active in pairs(type(step.activeItems) == "table" and step.activeItems or {}) do
        if active then
            local home
            for _, line in ipairs(todo) do
                local quest = line.quest and RealId(rxp, line.quest.questId)
                if quest and (QuestHasItem(rxp.questCompleteItems, quest, id) or QuestHasItem(rxp.questAcceptItems, quest, id)
                    or QuestHasItem(rxp.questTurnInItems, quest, id)) then
                    home = line
                    break
                end
            end
            if home then item(home, id) else loose[#loose + 1] = id end
        end
    end

    -- Units of the quest lines, from Questie: the giver to pick up from, the NPC to hand in to, the mobs of the
    -- objective the line is about.
    for _, line in ipairs(todo) do
        local quest = line.quest
        local units = quest and ns.QuestUnits and ns.QuestUnits(RealId(rxp, quest.questId))
        if units then
            local tag = line.element.tag
            if tag == "accept" and units.starter then
                unit(line, "target", {units.starter.name})
            elseif tag == "turnin" and units.ender then
                unit(line, "target", {units.ender.name})
            elseif tag == "complete" then
                local names = {}
                for _, mob in ipairs(LocalMobs(LineMobs(units, PlainText(line.text)))) do names[#names + 1] = mob.name end
                unit(line, "mob", names)
            end
        end
    end

    -- The step's own RestedXP units: a mob to the objective line that names it; the rest together on one line, NPCs on
    -- a pick up or hand in line, mobs on an objective line, else the first line that is not about a quest, else the
    -- first line with room.
    local friendly, enemy = {}, {}
    for _, element in ipairs(step.elements or {}) do
        for _, t in ipairs(type(element.targets) == "table" and element.targets or {}) do friendly[#friendly + 1] = CreatureName(rxp, t) end
        for _, list in ipairs({element.mobs, element.unitscan}) do
            for _, t in ipairs(type(list) == "table" and list or {}) do enemy[#enemy + 1] = CreatureName(rxp, t) end
        end
    end
    local rest = {}
    for _, name in ipairs(enemy) do
        local placed = false
        for _, line in ipairs(todo) do
            if free(line) and line.element.tag == "complete" and Mentions(PlainText(line.text), name) then
                unit(line, "mob", {name})
                placed = true
                break
            end
        end
        if not placed then rest[#rest + 1] = name end
    end
    local function home(tags)
        for _, line in ipairs(todo) do
            if free(line) and tags[line.element.tag] then return line end
        end
        for _, line in ipairs(todo) do
            if free(line) and not line.quest then return line end
        end
        for _, line in ipairs(todo) do
            if free(line) then return line end
        end
    end
    if #friendly > 0 then unit(home({accept = true, turnin = true}), "target", friendly) end
    if #rest > 0 then unit(home({complete = true}), "mob", rest) end

    -- The step's other items: a line still without a button, one that is not about a quest first.
    for _, id in ipairs(loose) do item(home({}), id) end
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
local lastLook

local function Button_OnEnter(button)
    local data = button.data
    if not data or GameTooltip:IsForbidden() then return end
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    if data.kind == "item" then
        GameTooltip:SetItemByID(data.item)
    elseif #data.names > 1 then
        GameTooltip:AddLine("Target the nearest", 1, 1, 1)
        for _, name in ipairs(data.names) do
            GameTooltip:AddLine((name == button.chosen and "> " or "") .. name, 0.8, 0.8, 0.8)
        end
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

-- How far away a unit is, roughly: LibRangeCheck when another addon brings it, else the interact distances.
local function Distance(unit)
    local lib = LibStub and LibStub("LibRangeCheck-3.0", true)
    if lib then
        local fine, low, high = pcall(lib.GetRange, lib, unit)
        if fine and (high or low) then return high or low end
    end
    for _, check in ipairs({{3, 10}, {4, 28}}) do
        local fine, inRange = pcall(CheckInteractDistance, unit, check[1])
        if fine and inRange then return check[2] end
    end
    return 100
end

-- Of a button's names, the one of the nearest living unit with a nameplate; nil when none is in sight.
local function Nearest(names)
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
    local wanted = {}
    for _, name in ipairs(names) do wanted[name] = true end
    local best, bestDistance
    for _, plate in ipairs(C_NamePlate.GetNamePlates() or {}) do
        local unit = plate.namePlateUnitToken or plate.UnitFrame and plate.UnitFrame.unit
        local fine, name = pcall(UnitName, unit or "")
        if fine and type(name) == "string" and not (issecretvalue and issecretvalue(name)) and wanted[name]
            and not UnitIsDead(unit) then
            local distance = Distance(unit)
            if not bestDistance or distance < bestDistance then best, bestDistance = name, distance end
        end
    end
    return best
end

-- The macro of a target button: the nearest of its names when one is in sight, else each name in turn (the last
-- one found stays targeted).
local function TargetMacro(data, chosen)
    if chosen or #data.names == 1 then return "/targetexact " .. (chosen or data.name) end
    local lines = {}
    for index = #data.names, 1, -1 do lines[#lines + 1] = "/targetexact " .. data.names[index] end
    return table.concat(lines, "\n")
end

local function Configure(button, want, chosen)
    local data = want.data
    button.data = data
    if data.kind == "item" then
        button:SetAttribute("type", "item")
        button:SetAttribute("macrotext", nil)
        button:SetAttribute("item", "item:" .. data.item)
    else
        button:SetAttribute("type", "macro")
        button:SetAttribute("item", nil)
        button:SetAttribute("macrotext", TargetMacro(data, chosen))
    end
    button.chosen = chosen
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
    -- Which of several mobs is nearest is looked at twice a second.
    local now = GetTime and GetTime() or 0
    local look = not lastLook or now - lastLook >= 0.5
    if look then lastLook = now end
    for index, want in ipairs(wanted) do
        local button = pool[index] or NewButton()
        local names = want.data.names
        local chosen
        if names and #names > 1 then
            chosen = button.key == want.key and button.chosen or nil
            if look or button.key ~= want.key then chosen = Nearest(names) end
        end
        if button.key ~= want.key or chosen ~= button.chosen then Configure(button, want, chosen) end
        button:SetAlpha(1)
        button:Show()
        Cooldown(button)
    end
    for index = #wanted + 1, #pool do
        local button = pool[index]
        if button:IsShown() then
            button:Hide()
            button.key, button.data, button.chosen = nil, nil, nil
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
