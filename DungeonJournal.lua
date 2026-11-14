local addonName, ns = ...

-- With the DungeonJournal addon (ForeverDungeonJournal): a "Generate route" button on its quest list. It takes the
-- quests of the dungeon shown there that this character can pick up outside the dungeon, adds the quests that have
-- to be done before them, and plans one trip through all of it that ends at the dungeon's entrance (Route.lua).
-- Hover: what the trip costs and brings. Click: the trip as a RestedXP guide of its own; RestedXP returns to the
-- guide it came from when it is done. Option dungeonRoute.
-- Without DungeonJournal nothing here runs. DungeonJournal is not changed: its data (ForeverDungeonJournal_NS) and
-- its window are only read.

local JOURNAL = "ForeverDungeonJournal"
local STANDALONE = "DungeonQuestRoute"      -- this file as an addon of its own, before it moved in here
local MAX_STOPS_SHOWN = 12      -- stops listed in the tooltip
local ATTACH_EVERY = 0.5        -- seconds between looks for DungeonJournal's window, until the button is on it

local function Planner()
    local api = _G.RXPBlizzStyleAPI
    return type(api) == "table" and api or nil
end

local function AddOnLoaded(name)
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or _G.IsAddOnLoaded
    return loaded and loaded(name) and true or false
end

-- The dungeon DungeonJournal shows: its name and its data.
local function Dungeon()
    local journal = _G.ForeverDungeonJournal_NS
    if type(journal) ~= "table" or type(journal.GetSelectedDungeon) ~= "function" or type(journal.DB) ~= "table" then return end
    local ok, name = pcall(journal.GetSelectedDungeon)
    local data = ok and name and journal.DB[name]
    if type(data) == "table" then return name, data end
end

-- The dungeon's quests for this character's side. The optional lead-ins the journal keeps out of its main list
-- are left out: where one is needed after all, the planner finds it as a quest to do first.
local function QuestIds(data)
    local side = UnitFactionGroup and UnitFactionGroup("player")
    local other = side == "Alliance" and "Horde" or side == "Horde" and "Alliance" or nil
    local journal = _G.ForeverDungeonJournal_NS
    local ids = {}
    for _, quest in ipairs(type(data.quests) == "table" and data.quests or {}) do
        if type(quest) == "table" and type(quest.id) == "number" and not quest.hideFromMainList and quest.faction ~= other then
            local lost = false
            if type(journal.IsQuestLost) == "function" then
                local ok, gone = pcall(journal.IsQuestLost, quest)
                lost = ok and gone and true or false
            end
            if not lost then ids[#ids + 1] = quest.id end
        end
    end
    return ids
end

-- Whether a map is a zone of the world; a dungeon's own map is not.
local function Outdoors(mapId)
    local ok, info = pcall(function() return C_Map.GetMapInfo(mapId) end)
    if not ok or type(info) ~= "table" or info.mapType == nil then return true end
    return info.mapType == (Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3)
end

local LEFT_OUT = {
    done = "done", log = "in your log", notforyou = "not for you", unknown = "not in Questie's database",
    inside = "starts inside", item = "starts from an item", level = "level too low", noplace = "no known place",
}
local LEFT_OUT_ORDER = {"done", "log", "inside", "item", "level", "notforyou", "noplace", "unknown"}

-- The trip for the dungeon shown: {dungeon, entries, route, left = {reason = count}}, or nil and why not.
local function Build()
    local api = Planner()
    if not api then return nil, "The route planner is not loaded." end
    local name, data = Dungeon()
    if not name then return nil, "DungeonJournal shows no dungeon." end
    local entries, skipped = api.QuestEntries(QuestIds(data))
    if not entries then return nil, tostring(skipped) end
    local left = {}
    local function leave(why) left[why] = (left[why] or 0) + 1 end
    for _, skip in ipairs(skipped or {}) do leave(skip.why) end
    local kept = {}
    for _, entry in ipairs(entries) do
        if entry.status == "item" then
            leave("item")       -- nothing to pick up before the run
        elseif entry.status == "level" then
            leave("level")
        elseif not (entry.mapId and entry.x and entry.y) then
            leave("noplace")
        elseif not Outdoors(entry.mapId) then
            leave("inside")
        else
            kept[#kept + 1] = entry
        end
    end
    local trip = {dungeon = name, entries = kept, left = left}
    if #kept == 0 then return trip end
    local entrance = data.entrance
    local finish
    if type(entrance) == "table" and entrance.mapID and entrance.x and entrance.y then
        finish = {name = entrance.label or (name .. " entrance"), mapId = entrance.mapID, x = entrance.x * 100, y = entrance.y * 100}
    end
    local ok, route = api.Plan(kept, finish)
    if not ok then return nil, "The route could not be planned: " .. tostring(route) end
    trip.route = route
    return trip
end

local function LeftOutText(left)
    local parts = {}
    for _, why in ipairs(LEFT_OUT_ORDER) do
        if left[why] then parts[#parts + 1] = ("%d %s"):format(left[why], LEFT_OUT[why]) end
    end
    return #parts > 0 and ("Left out: " .. table.concat(parts, ", ")) or nil
end

local function Button_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local trip, problem = Build()
    if not trip then
        GameTooltip:AddLine("Generate route", 1, 0.82, 0)
        GameTooltip:AddLine(problem, 1, 0.3, 0.3, true)
        GameTooltip:Show()
        return
    end
    local api = Planner()
    local leftOut = LeftOutText(trip.left)
    if not trip.route then
        GameTooltip:AddLine(trip.dungeon, 1, 0.82, 0)
        GameTooltip:AddLine("Nothing to pick up before the run.", 0.9, 0.9, 0.9, true)
        if leftOut then GameTooltip:AddLine(leftOut, 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
        return
    end
    local route, entries = trip.route, trip.entries
    GameTooltip:AddLine(("%s: route for %d quest%s"):format(trip.dungeon, #entries, #entries == 1 and "" or "s"), 1, 0.82, 0)
    local dungeonXp = api.UnlockedXp(entries)
    GameTooltip:AddDoubleLine("Travel", "about " .. api.Duration(route.seconds), 0.9, 0.9, 0.9, 1, 1, 1)
    GameTooltip:AddDoubleLine(("XP on the way (%d hand-in%s)"):format(route.handins, route.handins == 1 and "" or "s"),
        api.FormatXp(route.xp), 0.9, 0.9, 0.9, 0.55, 0.75, 1)
    GameTooltip:AddDoubleLine("XP of the dungeon quests", api.FormatXp(dungeonXp), 0.9, 0.9, 0.9, 0.55, 0.75, 1)
    GameTooltip:AddDoubleLine("Total", api.FormatXp(route.xp + dungeonXp), 1, 0.82, 0, 0.55, 0.75, 1)
    -- What the planner has to say beyond stops, time and experience (rides, hearthstone, notes).
    local lines = api.Summary(route, entries)
    for i = 3, #lines do GameTooltip:AddLine(lines[i], 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine(" ")
    for i, stop in ipairs(route.stops) do
        if i > MAX_STOPS_SHOWN then
            GameTooltip:AddLine(("... and %d more"):format(#route.stops - MAX_STOPS_SHOWN), 0.8, 0.8, 0.8)
            break
        end
        local place = stop.mapId and api.PlaceName(stop.mapId, stop.x, stop.y) or "anywhere"
        GameTooltip:AddDoubleLine(("%d. %s"):format(i, api.StopText(stop)), place, 0.9, 0.9, 0.9, 0.7, 0.7, 0.7)
    end
    if leftOut then GameTooltip:AddLine(leftOut, 0.6, 0.6, 0.6, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: put it into RestedXP as a guide of its own.", 0.5, 0.8, 1, true)
    GameTooltip:Show()
end

local function Button_OnClick()
    GameTooltip:Hide()
    local trip, problem = Build()
    if not trip then return ns.Print(problem) end
    if not trip.route then
        return ns.Print(("%s: nothing to pick up before the run.%s"):format(trip.dungeon, LeftOutText(trip.left) and (" " .. LeftOutText(trip.left) .. ".") or ""))
    end
    local api = Planner()
    local loaded, back = api.LoadGuide(trip.route, trip.dungeon .. " quests")
    if not loaded then return ns.Print("The route guide could not be made: " .. tostring(back)) end
    ns.Print(("%s: route guide loaded, %d stops, about %s.%s"):format(trip.dungeon, #trip.route.stops, api.Duration(trip.route.seconds),
        type(back) == "table" and back.name and (" RestedXP returns to %s after it."):format(back.name) or ""))
end

-- The button, under the "QUESTS" title of the journal's quest list; true once it is there (or never will be).
local button
local function Attach()
    -- The addon this came from is still installed: it has its own button.
    if AddOnLoaded(STANDALONE) then return true end
    local journal = _G.ForeverDungeonJournalFrame
    local panel = type(journal) == "table" and journal.questLeftPanel
    if not panel then return false end
    button = CreateFrame("Button", "RXPBlizzStyleDungeonRouteButton", panel, "UIPanelButtonTemplate")
    button:SetSize(120, 20)
    button:SetPoint("TOPLEFT", 10, -32)
    button:SetText("Generate route")
    button:SetScript("OnEnter", Button_OnEnter)
    button:SetScript("OnLeave", function(self)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    button:SetScript("OnClick", Button_OnClick)
    button:SetShown(ns.db.dungeonRoute ~= false)
    return true
end

-- Only with DungeonJournal. It builds its window when it is first opened: look for it until it is there.
local driver = CreateFrame("Frame")
local waited, looking = 0, false
local function Look(self, elapsed)
    waited = waited + elapsed
    if waited < ATTACH_EVERY then return end
    waited = 0
    if Attach() then self:SetScript("OnUpdate", nil) end
end
local function Start()
    if looking or type(_G.ForeverDungeonJournal_NS) ~= "table" then return end
    looking = true
    driver:UnregisterAllEvents()
    driver:SetScript("OnUpdate", Look)
end
driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:SetScript("OnEvent", Start)
Start()

-- The option, applied at once.
ns.RegisterPart("route button in DungeonJournal", function()
    local wanted = ns.db.dungeonRoute ~= false
    if button and button:IsShown() ~= wanted then button:SetShown(wanted) end
end, function()
    if button then button:Hide() end
end)
