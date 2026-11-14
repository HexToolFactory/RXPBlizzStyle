local addonName, ns = ...

-- Missing prerequisites: the quests of the current guide that cannot be picked up yet, because a quest before
-- them is not done and this guide does not do it either, with the whole chain of quests that unlocks them. The
-- prerequisites come from Questie's quest database; RestedXP's guides do not carry them.
-- The window follows the look of the DungeonJournal addon: dark rock with a dialog border, a brown title strip
-- with gold lines, framed quest rows on the left and the quest on parchment on the right.

local WINDOW_WIDTH, WINDOW_HEIGHT = 800, 540
local LIST_WIDTH = 300
local ROW_HEIGHT, ROW_GAP = 52, 4
local CHAIN_HEIGHT, CHAIN_GAP = 70, 4
-- The parchment's scroll area: window minus margins, list, gap and the scroll bar.
local DETAIL_WIDTH = WINDOW_WIDTH - 18 - LIST_WIDTH - 30 - 18 - 8 - 30

local GOLD = {0.96, 0.79, 0.25}
local INK = {0.20, 0.12, 0.03}          -- text on parchment
local INK_SOFT = {0.33, 0.24, 0.12}
local AVAILABLE_ICON = "Interface\\GossipFrame\\AvailableQuestIcon"
local ACTIVE_ICON = "Interface\\GossipFrame\\ActiveQuestIcon"

--------------------------------------------------------------------------------------------------
-- Data

local function Questie(name) return ns.QuestieModule and ns.QuestieModule(name) end

local function Query(db, kind, id, key)
    local get = db[kind]
    if type(get) ~= "function" or type(id) ~= "number" then return end
    local ok, value = pcall(get, id, key)
    if ok then return value end
end

-- Fields added by hand (PrereqFixes.lua) come before Questie's.
local function Fix(id) return ns.PREREQ_FIXES and ns.PREREQ_FIXES[id] end

local function QuestValue(db, id, key)
    local fix = Fix(id)
    if fix and fix[key] ~= nil then return fix[key] end
    return Query(db, "QueryQuestSingle", id, key)
end

local function IsKnown(db, id) return QuestValue(db, id, "name") ~= nil end

local function IsDone(id)
    local questie = _G.Questie
    local complete = type(questie) == "table" and questie.db and questie.db.char and questie.db.char.complete
    if complete and complete[id] then return true end
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then return C_QuestLog.IsQuestFlaggedCompleted(id) and true or false end
    return false
end

local function IsInLog(id, player)
    if player and type(player.currentQuestlog) == "table" and player.currentQuestlog[id] then return true end
    if C_QuestLog and C_QuestLog.IsOnQuest then return C_QuestLog.IsOnQuest(id) and true or false end
    return false
end

local function IsForMe(db, player, id)
    if not player then return true end
    local ok1, race = pcall(player.HasRequiredRace, QuestValue(db, id, "requiredRaces"))
    local ok2, class = pcall(player.HasRequiredClass, QuestValue(db, id, "requiredClasses"))
    return (not ok1 or race ~= false) and (not ok2 or class ~= false)
end

-- The guide's quests: {{id, step, kind}, ...} in guide order, kind "accept" for the ones it picks up and "handin"
-- for the ones it only works on or hands in, and the quests it takes care of itself: the ones it picks up, and
-- the ones it hands in while they are in the quest log. Handing in a quest nobody picked up does not count.
-- The quests a step is only meant for when the player already has them (.isOnQuest / .isQuestComplete):
-- without the quest RestedXP skips the step on purpose.
local function OnlyIfTaken(rxp, step)
    local only = {}
    for _, element in ipairs(step.elements or {}) do
        if (element.tag == "isOnQuest" or element.tag == "isQuestComplete") and not element.reverse then
            local ids = type(element.questIds) == "table" and element.questIds or {element.questId}
            for _, id in pairs(ids) do
                if type(id) == "number" then
                    only[id] = true
                    if rxp.GetQuestId then only[rxp.GetQuestId(id, nil, true) or id] = true end
                end
            end
        end
    end
    return only
end

-- The step the player is at in the guide.
local function CurrentStep(rxp, guide)
    if type(rxp.GetGuideProgress) ~= "function" then return 1 end
    local ok, step = pcall(rxp.GetGuideProgress, guide)
    return ok and tonumber(step) or 1
end

-- A pick-up line in a step the player is already past, of a quest they neither have nor did, picks nothing up any
-- more (RestedXP skipped the step, or the player did): such a quest counts as one the guide only works on, from
-- the steps still ahead (order[...].missed = the step of that line).
local function GuideQuests(rxp, guide, player)
    local covered, order, stepOf, accepted = {}, {}, {}, {}
    local work, missed = {}, {}
    local current = CurrentStep(rxp, guide)
    for index, step in ipairs(guide.steps or {}) do
        local only = OnlyIfTaken(rxp, step)
        for _, element in ipairs(step.elements or {}) do
            local id = element.questId
            local tag = element.tag
            if type(id) == "number" and id > 0 and (tag == "accept" or tag == "turnin" or tag == "complete") then
                local real = rxp.GetQuestId and rxp.GetQuestId(id, nil, true) or id
                if tag == "accept" and index < current and not IsInLog(real, player) and not IsDone(real) then
                    missed[real] = missed[real] or index
                elseif tag == "accept" then
                    accepted[real] = true
                    covered[id], covered[real] = true, true
                    if not stepOf[real] then
                        stepOf[real] = index
                        order[#order + 1] = {id = real, step = index, kind = "accept"}
                    end
                else
                    if tag == "turnin" and IsInLog(real, player) then covered[id], covered[real] = true, true end
                    work[#work + 1] = {id = real, step = index, optional = only[real] or only[id] or nil}
                end
            end
        end
    end
    for _, item in ipairs(work) do
        local missedAt = not accepted[item.id] and missed[item.id] or nil
        if not accepted[item.id] and not stepOf[item.id] and not (missedAt and item.step < current) then
            stepOf[item.id] = item.step
            order[#order + 1] = {id = item.id, step = item.step, kind = "handin", optional = item.optional, missed = missedAt}
        end
    end
    table.sort(order, function(a, b)
        if a.step ~= b.step then return a.step < b.step end
        return a.id < b.id
    end)
    return covered, order
end

-- The quests that must be done before `id` and are not: all of preQuestGroup, one of preQuestSingle.
local function Requirements(db, player, covered, id)
    local needs = {}
    local group = QuestValue(db, id, "preQuestGroup")
    if type(group) == "table" then
        for _, pre in ipairs(group) do
            if type(pre) == "number" and pre > 0 and not IsDone(pre) then needs[#needs + 1] = pre end
        end
    end
    local single = QuestValue(db, id, "preQuestSingle")
    if type(single) == "table" and #single > 0 then
        local satisfied, pick, inLog, forMe = false, nil, nil, nil
        for _, pre in ipairs(single) do
            if type(pre) == "number" and pre > 0 then
                if IsDone(pre) then satisfied = true break end
                if covered[pre] and not pick then pick = pre end
                if not inLog and IsInLog(pre, player) then inLog = pre end
                if not forMe and IsForMe(db, player, pre) then forMe = pre end
            end
        end
        if not satisfied then
            -- One of them is enough: the one the guide does, else one already taken, else one for this character.
            local choice = pick or inLog or forMe
            if choice then needs[#needs + 1] = choice end
        end
    end
    return needs
end

-- The quests to do before `id` that the guide does not do, earliest first.
local function Chain(db, player, covered, id)
    local chain, seen = {}, {[id] = true}
    local function visit(quest)
        if seen[quest] then return end
        seen[quest] = true
        -- A quest in the log needs nothing more before it; one the guide does is the guide's business.
        if not IsInLog(quest, player) then
            for _, pre in ipairs(Requirements(db, player, covered, quest)) do
                if not covered[pre] then visit(pre) end
            end
        end
        chain[#chain + 1] = quest
    end
    for _, pre in ipairs(Requirements(db, player, covered, id)) do
        if not covered[pre] then visit(pre) end
    end
    return chain
end

local mapIdOfArea = {}

local function MapName(mapId)
    local info = mapId and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
    return info and info.name
end

local function ZoneName(areaId)
    local mapId = mapIdOfArea[areaId]
    if mapId == nil then
        local zones = Questie("ZoneDB")
        mapId = zones and zones.GetUiMapIdByAreaId and select(2, pcall(zones.GetUiMapIdByAreaId, zones, areaId))
        mapId = type(mapId) == "number" and mapId or false
        mapIdOfArea[areaId] = mapId
    end
    return MapName(mapId or nil), mapId or nil
end

-- The first NPC or object of Questie's startedBy / finishedBy that it knows, and where it is: name, zone name,
-- uiMapId, x, y (0-100).
local function Placed(db, by)
    local sources = {{by[1], "QueryNPCSingle"}, {by[2], "QueryObjectSingle"}}
    for _, source in ipairs(sources) do
        if type(source[1]) == "table" then
            for _, starterId in ipairs(source[1]) do
                local name = Query(db, source[2], starterId, "name")
                if name then
                    local spawns = Query(db, source[2], starterId, "spawns")
                    if type(spawns) == "table" then
                        for areaId, points in pairs(spawns) do
                            local point = type(points) == "table" and points[1]
                            if type(point) == "table" and (point[1] or -1) >= 0 then
                                local zone, mapId = ZoneName(areaId)
                                return name, zone, mapId, point[1], point[2]
                            end
                        end
                    end
                    return name
                end
            end
        end
    end
end

-- Who starts the quest and where: name, zone name, uiMapId, x, y (0-100).
local function Starter(db, id)
    local fix = Fix(id)
    if fix and fix.starter then return fix.starter, fix.zone, fix.mapId, fix.x, fix.y end
    local startedBy = QuestValue(db, id, "startedBy")
    if type(startedBy) ~= "table" then return end
    local name, zone, mapId, x, y = Placed(db, startedBy)
    if name then return name, zone, mapId, x, y end
    if type(startedBy[3]) == "table" and startedBy[3][1] then
        local item = Query(db, "QueryItemSingle", startedBy[3][1], "name")
        if item then return "Item: " .. item end
    end
end

-- Whether the player has an item (bags or bank); true when the game does not say.
local function HasItem(itemId)
    local count = C_Item and C_Item.GetItemCount or GetItemCount
    if not count then return true end
    local ok, has = pcall(function() return count(itemId, true) > 0 end)
    return not ok or has
end

-- Where an item comes from by Questie's data, as the rest of a sentence about it ("drops from ..."), or nil.
local function ItemSource(db, itemId)
    local rewards = Query(db, "QueryItemSingle", itemId, "questRewards")
    if type(rewards) == "table" and type(rewards[1]) == "number" then
        local name = QuestValue(db, rewards[1], "name")
        if name then return "is a reward of the quest " .. name end
    end
    local sources = {
        {"npcDrops", "QueryNPCSingle", "drops from %s", "drops from creatures (%d kinds)"},
        {"objectDrops", "QueryObjectSingle", "is found in %s", "is found in objects (%d kinds)"},
        {"vendors", "QueryNPCSingle", "is sold by %s", "is sold by vendors (%d)"},
    }
    for _, source in ipairs(sources) do
        local ids = Query(db, "QueryItemSingle", itemId, source[1])
        if type(ids) == "table" and #ids > 0 then
            local name = #ids == 1 and Query(db, source[2], ids[1], "name")
            return name and source[3]:format(name) or source[4]:format(#ids)
        end
    end
end

-- The item of a quest that only an item starts, when the player has none of them: item name, where it comes
-- from, item ID.
local function MissingStartItem(db, id)
    local startedBy = QuestValue(db, id, "startedBy")
    if type(startedBy) ~= "table" then return end
    local function any(list) return type(list) == "table" and next(list) ~= nil end
    if any(startedBy[1]) or any(startedBy[2]) or not any(startedBy[3]) then return end
    local first
    for _, itemId in pairs(startedBy[3]) do
        if type(itemId) == "number" then
            if HasItem(itemId) then return end
            first = first or itemId
        end
    end
    if not first then return end
    return Query(db, "QueryItemSingle", first, "name") or ("item " .. first), ItemSource(db, first), first
end

-- Points of a spawn list ({[areaId] = {{x, y}, ...}}) added to places: {[uiMapId] = {{x, y, label}, ...}}.
local function AddPoints(places, spawns, label)
    if type(spawns) ~= "table" then return end
    for areaId, points in pairs(spawns) do
        local _, mapId = ZoneName(areaId)
        if mapId and type(points) == "table" then
            local list = places[mapId] or {seen = {}}
            places[mapId] = list
            for _, point in ipairs(points) do
                local key = type(point) == "table" and (point[1] or -1) >= 0 and point[2] and (point[1] .. ":" .. point[2])
                if key and not list.seen[key] then
                    list.seen[key] = true
                    list[#list + 1] = {x = point[1], y = point[2], label = label}
                end
            end
        end
    end
end

local function AddSpawns(db, kind, ids, label, places)
    if type(ids) ~= "table" then return end
    for _, spawnId in ipairs(ids) do
        AddPoints(places, Query(db, kind, spawnId, "spawns"), label or Query(db, kind, spawnId, "name"))
    end
end

-- The quest's objective as Questie words it, e.g. "Bring 8 Gnoll Paws to Marshal Dughan in Goldshire."
local function ObjectiveText(db, id)
    local fix = Fix(id)
    if fix and fix.objective then return fix.objective end
    local lines = QuestValue(db, id, "objectivesText")
    if type(lines) == "string" and lines ~= "" then return lines end
    if type(lines) ~= "table" then return end
    local parts = {}
    for _, line in ipairs(lines) do
        if type(line) == "string" and line ~= "" then parts[#parts + 1] = line end
    end
    return #parts > 0 and table.concat(parts, " ") or nil
end

-- Where the objectives are done: places as in AddPoints, and the names of what is killed, used or collected.
-- Items count where the NPCs and objects that drop them are.
local function Objectives(db, id)
    local places, names, seen = {}, {}, {}
    local count = 0
    local function Named(name)
        if type(name) == "string" and name ~= "" and not seen[name] then
            seen[name] = true
            names[#names + 1] = name
        end
        return name
    end
    local objectives = QuestValue(db, id, "objectives")
    if type(objectives) == "table" then
        for _, o in ipairs(type(objectives[1]) == "table" and objectives[1] or {}) do
            if type(o) == "table" then
                count = count + 1
                AddSpawns(db, "QueryNPCSingle", {o[1]}, Named(o[2] or Query(db, "QueryNPCSingle", o[1], "name")), places)
            end
        end
        for _, o in ipairs(type(objectives[2]) == "table" and objectives[2] or {}) do
            if type(o) == "table" then
                count = count + 1
                AddSpawns(db, "QueryObjectSingle", {o[1]}, Named(o[2] or Query(db, "QueryObjectSingle", o[1], "name")), places)
            end
        end
        for _, o in ipairs(type(objectives[3]) == "table" and objectives[3] or {}) do
            if type(o) == "table" then
                count = count + 1
                local name = Named(o[2] or Query(db, "QueryItemSingle", o[1], "name"))
                AddSpawns(db, "QueryNPCSingle", Query(db, "QueryItemSingle", o[1], "npcDrops"), name, places)
                AddSpawns(db, "QueryObjectSingle", Query(db, "QueryItemSingle", o[1], "objectDrops"), name, places)
            end
        end
        for _, o in ipairs(type(objectives[5]) == "table" and objectives[5] or {}) do
            if type(o) == "table" then
                count = count + 1
                AddSpawns(db, "QueryNPCSingle", o[1], Named(o[3] or Query(db, "QueryNPCSingle", o[2], "name")), places)
            end
        end
    end
    local trigger = QuestValue(db, id, "triggerEnd")
    if type(trigger) == "table" then AddPoints(places, trigger[2], Named(trigger[1])) end
    for mapId, list in pairs(places) do
        if #list == 0 then places[mapId] = nil end
    end
    -- An item the quest giver hands out with the quest: nothing to find, only to deliver.
    local given = false
    local source = QuestValue(db, id, "sourceItemId")
    if type(objectives) == "table" and type(objectives[3]) == "table" and source then
        for _, o in ipairs(objectives[3]) do
            if type(o) == "table" and o[1] == source then given = true end
        end
    end
    return places, names, given, count
end

-- Who the quest is handed in to and where, like Starter.
local function Ender(db, id)
    local fix = Fix(id)
    if fix and fix.ender then return fix.ender, fix.endZone, fix.endMapId, fix.endX, fix.endY end
    local finishedBy = QuestValue(db, id, "finishedBy")
    if type(finishedBy) ~= "table" then return end
    return Placed(db, finishedBy)
end

-- The quest's experience at the player's level, as Questie's map tooltips show it; nil when unknown or none.
local function QuestXp(id)
    local module = Questie("QuestXP")
    if not (module and module.GetQuestLogRewardXP) then return end
    local ok, xp = pcall(module.GetQuestLogRewardXP, module, id, false)
    return ok and type(xp) == "number" and xp > 0 and xp or nil
end

-- The place a quest is picked up at, for the groups of the list: a town or other landmark when the quest starts
-- within TOWN_RADIUS of one (Goldshire, Booty Bay), else its zone. Landmarks are what the world map marks on the
-- zone: its points of interest and its flight points. A capital has its own map and is its own place.
local TOWN_RADIUS = 200     -- yards
local CITY_MAPS = {[1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true}
local PLACE_ITEM, PLACE_UNKNOWN = "Starts from an item", "Unknown place"
local landmarkCache = {}

-- World coordinates (yards) of a point on a map, x and y 0-1, and the continent they are on.
local function WorldPoint(mapId, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return end
    local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, mapId, CreateVector2D(x, y))
    if ok and type(pos) == "table" and pos.GetXY then
        local wx, wy = pos:GetXY()
        return wx, wy, continent
    end
end
ns.WorldPoint = WorldPoint

-- RestedXP's flight points of a continent as landmarks ("Booty Bay, Stranglethorn" is Booty Bay): they do not
-- depend on what the game gives for a map.
local taxiLandmarks = {}
local function TaxiLandmarks(continent)
    local list = taxiLandmarks[continent]
    if list then return list end
    list = {}
    local rxp = _G.RXP
    local nodes = type(rxp) == "table" and type(rxp.taxiPos) == "table" and rxp.taxiPos[continent]
    for id, node in pairs(type(nodes) == "table" and nodes or {}) do
        local name
        for _, times in pairs(type(rxp.FPDB) == "table" and rxp.FPDB or {}) do
            name = name or (type(times) == "table" and type(times[id]) == "table" and times[id].name)
        end
        name = type(name) == "string" and name:match("^%s*([^,]+)")
        if name and type(node) == "table" and type(node.wx) == "number" and type(node.wy) == "number" then
            list[#list + 1] = {name = name, x = node.wx, y = node.wy}
        end
    end
    if #list > 0 then taxiLandmarks[continent] = list end
    return list
end

local function Landmarks(mapId)
    local list = landmarkCache[mapId]
    if list then return list end
    list = {}
    local function add(name, position)
        if type(name) ~= "string" or name == "" or type(position) ~= "table" or not position.GetXY then return end
        local wx, wy, continent = WorldPoint(mapId, position:GetXY())
        if wx then list[#list + 1] = {name = name, x = wx, y = wy, instance = continent} end
    end
    local poi = C_AreaPoiInfo
    if poi and poi.GetAreaPOIForMap and poi.GetAreaPOIInfo then
        local ok, ids = pcall(poi.GetAreaPOIForMap, mapId)
        for _, id in ipairs(ok and type(ids) == "table" and ids or {}) do
            local found, info = pcall(poi.GetAreaPOIInfo, mapId, id)
            if found and type(info) == "table" then pcall(add, info.name, info.position) end
        end
    end
    if C_TaxiMap and C_TaxiMap.GetTaxiNodesForMap then
        local ok, nodes = pcall(C_TaxiMap.GetTaxiNodesForMap, mapId)
        for _, node in ipairs(ok and type(nodes) == "table" and nodes or {}) do
            -- "Booty Bay, Stranglethorn": the place is the part before the comma.
            if type(node) == "table" and type(node.name) == "string" then
                pcall(add, node.name:match("^%s*([^,]+)"), node.position)
            end
        end
    end
    -- Kept only once there is something: the game may not have the map's data yet.
    if #list > 0 then landmarkCache[mapId] = list end
    return list
end

-- For the debug report: the landmarks the game gives for the map the player is on.
function ns.LandmarkReport()
    local mapId = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapId then return "no map" end
    local names = {}
    for i, mark in ipairs(Landmarks(mapId)) do names[i] = mark.name end
    return ("map %d, %d: %s"):format(mapId, #names, table.concat(names, ", "))
end

-- The name of the place at a spot of a map (x, y 0-100): the landmark it is at, else the zone.
local function PlaceName(mapId, x, y, zone)
    zone = zone or MapName(mapId) or PLACE_UNKNOWN
    if CITY_MAPS[mapId] then return zone end
    local wx, wy, continent = WorldPoint(mapId, x / 100, y / 100)
    if not wx then return zone end
    local best, bestDistance
    for _, list in ipairs({Landmarks(mapId), continent and TaxiLandmarks(continent) or {}}) do
        for _, mark in ipairs(list) do
            local distance = math.sqrt((mark.x - wx) ^ 2 + (mark.y - wy) ^ 2)
            if distance <= TOWN_RADIUS and (not bestDistance or distance < bestDistance) then
                best, bestDistance = mark.name, distance
            end
        end
    end
    return best or zone
end
ns.PlaceName = PlaceName

-- The spot of a place by its name, for where the hearthstone leads: a town with a flight point, a capital (the
-- middle of its map) or a landmark of a zone's map; {x, y, instance} in world coordinates, nil when not found.
function ns.FindPlace(name)
    if type(name) ~= "string" or name == "" then return end
    local wanted = name:lower()
    local rxp = _G.RXP
    for continent in pairs(type(rxp) == "table" and type(rxp.taxiPos) == "table" and rxp.taxiPos or {}) do
        for _, mark in ipairs(TaxiLandmarks(continent)) do
            if mark.name:lower() == wanted then return {x = mark.x, y = mark.y, instance = continent} end
        end
    end
    for mapId in pairs(CITY_MAPS) do
        local city = MapName(mapId)
        if city and city:lower() == wanted then
            local wx, wy, continent = WorldPoint(mapId, 0.5, 0.5)
            if wx and continent then return {x = wx, y = wy, instance = continent} end
        end
    end
    local zones
    if C_Map and C_Map.GetMapChildrenInfo then
        local ok, list = pcall(C_Map.GetMapChildrenInfo, 947, Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3, true)
        zones = ok and type(list) == "table" and list or nil
    end
    for _, zone in ipairs(zones or {}) do
        for _, mark in ipairs(type(zone) == "table" and zone.mapID and Landmarks(zone.mapID) or {}) do
            if mark.instance and mark.name:lower() == wanted then return {x = mark.x, y = mark.y, instance = mark.instance} end
        end
    end
end

local function PickupPlace(info)
    if not (info.mapId and info.x and info.y) then return info.fromItem and PLACE_ITEM or PLACE_UNKNOWN end
    return PlaceName(info.mapId, info.x, info.y, info.zone)
end

local function QuestInfo(db, player, covered, id)
    local level = QuestValue(db, id, "questLevel")
    local required = QuestValue(db, id, "requiredLevel")
    local info = {
        id = id,
        name = QuestValue(db, id, "name") or ("Quest " .. id),
        level = type(level) == "number" and level > 0 and level or nil,
        requiredLevel = type(required) == "number" and required or nil,
    }
    info.starter, info.zone, info.mapId, info.x, info.y = Starter(db, id)
    info.fromItem = type(info.starter) == "string" and info.starter:find("^Item: ") ~= nil or nil
    info.ender, info.endZone, info.endMapId, info.endX, info.endY = Ender(db, id)
    info.objective = ObjectiveText(db, id)
    info.objectivePlaces, info.objectiveNames, info.objectiveGiven, info.objectiveCount = Objectives(db, id)
    info.xp = QuestXp(id)
    -- The quests still to be done before it (for the route planner: it waits for them).
    info.needs = Requirements(db, player, covered, id)
    if not IsKnown(db, id) then
        info.status = "unknown"
    elseif IsInLog(id, player) then
        info.status = "log"
    elseif info.requiredLevel and info.requiredLevel > UnitLevel("player") then
        info.status = "level"
    elseif #info.needs > 0 then
        info.status = "locked"
    else
        -- A quest that starts from an item cannot be picked up without it.
        info.startItem, info.startItemSource, info.startItemId = MissingStartItem(db, id)
        info.status = info.startItem and "item" or "available"
    end
    return info
end

-- The quests after this one in its chain, the way Questie's tooltips list them under "Next in chain":
-- {{id, name, level, xp}, ...}; stops where the chain ends or turns to a quest this character cannot take.
local function FollowingQuests(db, player, id)
    local list, seen = {}, {[id] = true}
    local nextId = QuestValue(db, id, "nextQuestInChain")
    while type(nextId) == "number" and nextId > 0 and not seen[nextId] and #list < 40 do
        seen[nextId] = true
        if not IsForMe(db, player, nextId) then break end
        local level = QuestValue(db, nextId, "questLevel")
        list[#list + 1] = {
            id = nextId,
            name = QuestValue(db, nextId, "name") or ("Quest " .. nextId),
            level = type(level) == "number" and level > 0 and level or nil,
            xp = QuestXp(nextId),
        }
        nextId = QuestValue(db, nextId, "nextQuestInChain")
    end
    return list
end

local function GuideQuestName(rxp, id)
    if rxp.GetQuestName then
        local ok, name = pcall(rxp.GetQuestName, id)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
    if type(title) == "string" and title ~= "" then return title end
    return "Quest " .. id
end

-- Quests Questie does not know, kept in the saved variables to be looked up and added to PrereqFixes.lua.
local function NoteUnknown(db, guideName, unknown)
    if type(RXPBlizzStyleDB) ~= "table" then return end
    local saved = RXPBlizzStyleDB.unknownQuests or {}
    RXPBlizzStyleDB.unknownQuests = saved
    for id in pairs(saved) do
        if IsKnown(db, id) then saved[id] = nil end
    end
    for _, entry in ipairs(unknown) do
        saved[entry.id] = {name = entry.name, guide = guideName, step = entry.step, why = entry.why, seen = date("%Y-%m-%d")}
    end
end

-- The guide whose quests count: the current one, or, while the route guide made from it runs (Route.lua), the
-- guide that one leads back to.
local function QuestGuide(rxp)
    if type(rxp) ~= "table" then return end
    return ns.RouteOrigin and ns.RouteOrigin(rxp) or rxp.currentGuide or nil
end

-- {guide = name, quests = {{info, step, place, chain = {info, ...}}, ...}, unknown = {{id, name, step, why}, ...}}
-- or nil, reason
function ns.PrereqData(rxp)
    local guide = QuestGuide(rxp)
    if not guide or guide.empty then
        return nil, "No guide is loaded."
    end
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle) then
        return nil, "This list needs Questie: its quest database knows which quests come before which."
    end
    local covered, order = GuideQuests(rxp, guide, player)
    local result = {guide = guide.displayName or guide.name, quests = {}, unknown = {}}
    local listed = {}
    local function unknown(id, step, why)
        if listed[id] then return end
        listed[id] = true
        result.unknown[#result.unknown + 1] = {id = id, name = GuideQuestName(rxp, id), step = step, why = why}
    end
    for _, item in ipairs(order) do
        local id = item.id
        if not IsDone(id) and not IsInLog(id, player) and not IsKnown(db, id) then
            unknown(id, item.step, "guide")
        elseif not IsDone(id) and not IsInLog(id, player) and IsForMe(db, player, id) then
            local chain = Chain(db, player, covered, id)
            -- A quest the guide only hands in has to be picked up elsewhere too: it ends its own chain. Not when
            -- the quests before it are all the guide's own: then the game hands it out when the one before is
            -- turned in (like The Missing Diplomat 1267 after 1324), and the guide has no line to pick it up.
            if item.kind == "handin" then
                local needs = Requirements(db, player, covered, id)
                local viaGuide = #chain == 0 and #needs > 0
                for _, pre in ipairs(needs) do viaGuide = viaGuide and covered[pre] or false end
                if not viaGuide then chain[#chain + 1] = id end
            end
            if #chain > 0 then
                local entry = QuestInfo(db, player, covered, id)
                entry.step, entry.kind, entry.optional, entry.missed = item.step, item.kind, item.optional, item.missed
                entry.after = FollowingQuests(db, player, id)
                entry.chain = {}
                for i, pre in ipairs(chain) do
                    entry.chain[i] = QuestInfo(db, player, covered, pre)
                    if entry.chain[i].status == "unknown" then unknown(pre, item.step, "prerequisite of " .. id) end
                end
                -- Where the trip for it begins: at the first quest of its chain.
                entry.place = PickupPlace(entry.chain[1])
                result.quests[#result.quests + 1] = entry
            end
        end
    end
    -- A listed quest that is part of another one's chain is listed there: keep only the longer chain, and mark
    -- the quest in it with the step where the guide takes it up.
    local inChain = {}
    for _, entry in ipairs(result.quests) do
        for _, info in ipairs(entry.chain) do
            if info.id ~= entry.id then inChain[info.id] = true end
        end
    end
    local kept, stepOfListed = {}, {}
    for _, entry in ipairs(result.quests) do
        if inChain[entry.id] then stepOfListed[entry.id] = entry.step else kept[#kept + 1] = entry end
    end
    for _, entry in ipairs(kept) do
        for _, info in ipairs(entry.chain) do info.guideStep = stepOfListed[info.id] end
    end
    result.quests = kept
    NoteUnknown(db, result.guide, result.unknown)
    return result
end

-- For other addons (RXPBlizzStyleAPI in Route.lua): the quests of a list as entries for the route planner. Each
-- is to be picked up only; the quests before it that are not done are done in full, whatever guide is loaded.
-- Returns entries ({info..., kind = "handin", chain = {info, ..., the quest itself}}) and what was left out
-- ({{id, why = "unknown" / "done" / "log" / "notforyou"}, ...}); nil and the reason without Questie.
function ns.QuestEntries(ids)
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle) then return nil, "Questie is needed: its quest database knows where quests start." end
    local entries, skipped, seen, covered = {}, {}, {}, {}
    for _, id in ipairs(ids or {}) do
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            local why = not IsKnown(db, id) and "unknown" or IsDone(id) and "done" or IsInLog(id, player) and "log"
                or not IsForMe(db, player, id) and "notforyou" or nil
            if why then
                skipped[#skipped + 1] = {id = id, why = why}
            else
                local entry = QuestInfo(db, player, covered, id)
                entry.kind, entry.chain = "handin", {}
                for i, before in ipairs(Chain(db, player, covered, id)) do entry.chain[i] = QuestInfo(db, player, covered, before) end
                entry.chain[#entry.chain + 1] = QuestInfo(db, player, covered, id)
                entries[#entries + 1] = entry
            end
        end
    end
    return entries, skipped
end

-- For the tracker's tooltip on a quest line of a quest the player does not have: the quest's info (name, starter,
-- zone, status, ...) with before = {names of the quests to do first, earliest first}; nil without Questie.
function ns.QuestHint(id)
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle and type(id) == "number" and id > 0 and IsKnown(db, id)) then return end
    local rxp = _G.RXP
    local guide = QuestGuide(rxp)
    local covered = type(guide) == "table" and guide.steps and GuideQuests(rxp, guide, player) or {}
    local info = QuestInfo(db, player, covered, id)
    info.before = {}
    for i, pre in ipairs(Chain(db, player, covered, id)) do
        info.before[i] = QuestValue(db, pre, "name") or ("Quest " .. pre)
    end
    return info
end

-- The first step of the guide with each of its quests (accepted, worked on or handed in), by quest ID.
local stepsCache = {}
local function GuideSteps(rxp, guide)
    if stepsCache.guide == guide then return stepsCache.steps end
    local steps = {}
    for index, step in ipairs(guide.steps or {}) do
        for _, element in ipairs(step.elements or {}) do
            local id, tag = element.questId, element.tag
            if type(id) == "number" and id > 0 and (tag == "accept" or tag == "turnin" or tag == "complete") then
                local real = rxp.GetQuestId and rxp.GetQuestId(id, nil, true) or id
                steps[id] = steps[id] or index
                steps[real] = steps[real] or index
            end
        end
    end
    stepsCache.guide, stepsCache.steps = guide, steps
    return steps
end

-- For the tracker's info button next to a step's title: the quests after this one in its chain,
-- {{id, name, level, xp, status = "done" / "log" / nil, step = the current guide's first step with it}, ...},
-- and the quest's own name; nil without Questie or for a quest Questie does not know.
function ns.QuestFollowUps(id)
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle and type(id) == "number" and id > 0 and IsKnown(db, id)) then return end
    local list = FollowingQuests(db, player, id)
    local rxp = _G.RXP
    local guide = type(rxp) == "table" and rxp.currentGuide
    local steps = type(guide) == "table" and guide.steps and GuideSteps(rxp, guide) or {}
    for _, info in ipairs(list) do
        info.status = IsDone(info.id) and "done" or IsInLog(info.id, player) and "log" or nil
        info.step = steps[info.id]
    end
    return list, QuestValue(db, id, "name") or ("Quest " .. id)
end

--------------------------------------------------------------------------------------------------
-- Window

local HEADER_HEIGHT = 24    -- the place name above each group of the list
local frame, listRows, chainRows, groupHeaders, routeRows = nil, {}, {}, {}, {}
local routeMode = false     -- the parchment shows the route for the ticked quests instead of the chosen quest
local routeWaypoint, ClearRouteWaypoint     -- see RouteRow_OnClick
local data, selected
local focusQuest    -- a quest to select at the next refresh (ns.ShowPrereqsFor)
local focusMissed   -- that refresh found no entry for it

local function SetBackdrop(f, bg, border, edge, inset)
    f:SetBackdrop({
        bgFile = bg, edgeFile = border, tile = true, tileSize = 16, edgeSize = edge or 12,
        insets = {left = inset or 3, right = inset or 3, top = inset or 3, bottom = inset or 3},
    })
end

local function Line(parent, layer, r, g, b, a)
    local texture = parent:CreateTexture(nil, layer or "ARTWORK")
    texture:SetColorTexture(r, g, b, a)
    return texture
end

local function Font(fontString, preferred, fallback)
    fontString:SetFontObject(_G[preferred] and preferred or fallback)
end

local function LevelColor(level)
    if level and GetQuestDifficultyColor then
        local color = GetQuestDifficultyColor(level)
        if color then return color.r, color.g, color.b end
    end
    return 1, 0.82, 0
end

local STATUS_TEXT = {
    available = {"Can be picked up now", 0.10, 0.42, 0.06},
    log = {"In your quest log", 0.10, 0.25, 0.55},
    level = {"Needs level %d", 0.62, 0.08, 0.05},
    locked = {"Needs the quest above first", 0.40, 0.33, 0.24},
    item = {"Needs its starting item", 0.62, 0.08, 0.05},
    unknown = {"Not in Questie's database", 0.45, 0.40, 0.34},
}

local function StatusText(info)
    local status = STATUS_TEXT[info.status]
    local text = status[1]
    if info.status == "level" then text = text:format(info.requiredLevel) end
    return text, status[2], status[3], status[4]
end

local function SetQuestIcon(texture, status)
    texture:SetTexture(status == "log" and ACTIVE_ICON or AVAILABLE_ICON)
    texture:SetDesaturated(status ~= "available" and status ~= "log")
    texture:SetAlpha((status == "available" or status == "log") and 1 or 0.7)
end

-- Where the quest starts (kind "start") or is handed in (kind "end").
local function Place(info, kind)
    if kind == "end" then
        return {who = info.ender, zone = info.endZone, mapId = info.endMapId, x = info.endX, y = info.endY}
    end
    return {who = info.starter, zone = info.zone, mapId = info.mapId, x = info.x, y = info.y}
end

local function AddWaypoint(info, kind)
    local place, tomtom = Place(info, kind), _G.TomTom
    if not (place.mapId and place.x and type(tomtom) == "table" and tomtom.AddWaypoint) then return false end
    pcall(tomtom.AddWaypoint, tomtom, place.mapId, place.x / 100, place.y / 100,
        {title = info.name .. (kind == "end" and " (turn in)" or "") .. (place.who and (" - " .. place.who) or ""), from = addonName})
    return true
end

--------------------------------------------------------------------------------------------------
-- Share and Show on Map, per quest, like DungeonJournal's buttons. Share hands the quest to the group, which the
-- game only allows from the quest log; shift-click puts a quest link into chat instead. Show on Map opens the world
-- map with a pin where the quest starts (and a TomTom waypoint, when TomTom is there).

local function QuestLogIndex(id)
    if not (C_QuestLog and C_QuestLog.GetLogIndexForQuestID) then return end
    local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, id)
    return ok and type(index) == "number" and index > 0 and index or nil
end

local function IsPushable(id)
    if not (C_QuestLog and C_QuestLog.IsPushableQuest) then return false end
    local ok, pushable = pcall(C_QuestLog.IsPushableQuest, id)
    return ok and pushable == true
end

-- "share" when the quest can be shared now, otherwise why not: "log", "no" or "group".
local function ShareState(id)
    if not QuestLogIndex(id) then return "log" end
    if not IsPushable(id) then return "no" end
    if not (IsInGroup and IsInGroup()) then return "group" end
    return "share"
end

local function ShareQuest(id)
    local index = QuestLogIndex(id)
    if not index or type(QuestLogPushQuest) ~= "function" then return false end
    if C_QuestLog.SetSelectedQuest then pcall(C_QuestLog.SetSelectedQuest, id) end
    return (pcall(QuestLogPushQuest, index))
end

local function LinkQuest(info)
    if type(ChatEdit_InsertLink) ~= "function" then return false end
    local link
    if type(GetQuestLink) == "function" then
        local ok, live = pcall(GetQuestLink, info.id)
        if ok and type(live) == "string" and live ~= "" then link = live end
    end
    link = link or ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(info.id, info.level or -1, info.name)
    if not (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()) and type(ChatFrame_OpenChat) == "function" then
        ChatFrame_OpenChat("")
    end
    return ChatEdit_InsertLink(link) or ChatEdit_InsertLink("[" .. info.name .. "]") or false
end

-- The world map pins: one place at a time (where a quest starts, where it is handed in, or the spots of its
-- objective), gone once the quest is picked up (start) or handed in, or on right-click.
local MAX_PINS = 150
local pins, mapTarget, pinDriver = {}, nil, nil

local function WorldMapCanvas()
    local map = _G.WorldMapFrame
    if not map then return end
    if map.GetCanvas then
        local ok, canvas = pcall(map.GetCanvas, map)
        if ok and canvas then return canvas end
    end
    return map.ScrollContainer and map.ScrollContainer.Child
end

local function WorldMapId()
    local map = _G.WorldMapFrame
    if not (map and map.GetMapID) then return end
    local ok, id = pcall(map.GetMapID, map)
    return ok and id or nil
end

local function ClearPins()
    mapTarget = nil
    for _, pin in ipairs(pins) do pin:Hide() end
end

local function Pin_OnEnter(self)
    local target = mapTarget
    if not target then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(target.name, 1, 0.82, 0)
    if target.kind == "objective" then
        if self.label then GameTooltip:AddLine("Objective: " .. self.label, 1, 1, 1, true) end
    elseif target.where then
        GameTooltip:AddLine((target.kind == "end" and "Turn in at " or "Starts at ") .. target.where, 1, 1, 1, true)
    end
    GameTooltip:AddLine(("%.1f, %.1f"):format(self.x, self.y), 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Right-click: remove the pins", 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function CreatePinFrame()
    local pin = CreateFrame("Frame", nil, UIParent)
    pin:SetSize(32, 32)
    pin:EnableMouse(true)
    pin:Hide()
    pin.Backing = pin:CreateTexture(nil, "BACKGROUND")
    pin.Backing:SetPoint("CENTER")
    pin.Backing:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    pin.Backing:SetVertexColor(0.10, 0.07, 0.03, 0.85)
    pin.Ring = pin:CreateTexture(nil, "BORDER")
    pin.Ring:SetPoint("CENTER")
    pin.Ring:SetSize(46, 46)
    pin.Ring:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    pin.Ring:SetVertexColor(0.96, 0.79, 0.25, 0.45)
    local pulse = pin.Ring:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.15)
    fade:SetToAlpha(0.9)
    fade:SetDuration(0.7)
    pulse:Play()
    pin.Icon = pin:CreateTexture(nil, "ARTWORK")
    pin.Icon:SetPoint("CENTER")
    pin.Icon:SetSize(22, 22)
    pin.Dot = pin:CreateTexture(nil, "ARTWORK")
    pin.Dot:SetPoint("CENTER")
    pin.Dot:SetSize(10, 10)
    pin.Dot:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
    pin.Dot:SetVertexColor(0.96, 0.79, 0.25, 1)
    pin:SetScript("OnEnter", Pin_OnEnter)
    pin:SetScript("OnLeave", function(self) if GameTooltip:GetOwner() == self then GameTooltip:Hide() end end)
    pin:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then
            GameTooltip:Hide()
            ClearPins()
        end
    end)
    return pin
end

-- Start and end: one big pulsing quest icon. Objective: small gold dots, one per spot.
local function StylePin(pin, kind)
    local objective = kind == "objective"
    pin:SetSize(objective and 16 or 32, objective and 16 or 32)
    pin.Backing:SetSize(objective and 16 or 30, objective and 16 or 30)
    pin.Ring:SetShown(not objective)
    pin.Icon:SetShown(not objective)
    pin.Dot:SetShown(objective)
    pin.Icon:SetTexture(kind == "end" and ACTIVE_ICON or AVAILABLE_ICON)
    pin.kind = kind
end

local function PlacePins()
    local target, canvas = mapTarget, WorldMapCanvas()
    local width, height, zoom
    if target and canvas and WorldMapFrame:IsVisible() and WorldMapId() == target.mapId then
        width, height, zoom = canvas:GetWidth(), canvas:GetHeight(), canvas:GetScale()
    end
    if not (width and width > 0 and zoom and zoom > 0) then
        for _, pin in ipairs(pins) do pin:Hide() end
        return
    end
    -- Same size at every zoom: the pins undo the canvas scale, so their offsets are in their own, larger units.
    local scale = 1 / zoom
    for i, point in ipairs(target.points) do
        local pin = pins[i]
        if not pin then
            pin = CreatePinFrame()
            pins[i] = pin
        end
        if pin:GetParent() ~= canvas then
            pin:SetParent(canvas)
            pin:SetFrameStrata(canvas:GetFrameStrata())
        end
        if pin.kind ~= target.kind then StylePin(pin, target.kind) end
        pin:SetFrameLevel(canvas:GetFrameLevel() + 2500)
        pin.x, pin.y, pin.label = point.x, point.y, point.label
        pin:SetScale(scale)
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", canvas, "TOPLEFT", width * point.x / 100 / scale, -height * point.y / 100 / scale)
        pin:Show()
    end
    for i = #target.points + 1, #pins do pins[i]:Hide() end
end

-- Follows the map while it is open (a child of the map runs only then), drops the pins once their quest is picked up
-- (start pin) or handed in, and brings the prerequisites window back when the map closes.
local function CreatePinDriver()
    if pinDriver then return end
    pinDriver = CreateFrame("Frame", nil, WorldMapFrame or UIParent)
    local elapsed = 0
    pinDriver:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 0.05 then return end
        elapsed = 0
        PlacePins()
    end)
    pinDriver:SetScript("OnHide", function()
        for _, pin in ipairs(pins) do pin:Hide() end
        if frame and frame.reopenAfterMap then
            frame.reopenAfterMap = nil
            if not InCombatLockdown() then frame:Show() end
        end
    end)
    pinDriver:RegisterEvent("QUEST_ACCEPTED")
    pinDriver:RegisterEvent("QUEST_TURNED_IN")
    pinDriver:SetScript("OnEvent", function(_, event, questId, otherId)
        local target = mapTarget
        if not target then return end
        if IsDone(target.id) or (event == "QUEST_TURNED_IN" and questId == target.id) then return ClearPins() end
        -- QUEST_ACCEPTED has the quest ID second on older clients.
        if target.kind == "start" and (questId == target.id or otherId == target.id or (not target.inLog and IsInLog(target.id))) then
            ClearPins()
        end
    end)
end

local function OpenMap(mapId)
    if InCombatLockdown() then return false end
    if C_Map and C_Map.OpenWorldMap then
        pcall(C_Map.OpenWorldMap, mapId)
    elseif type(OpenWorldMap) == "function" then
        pcall(OpenWorldMap, mapId)
    end
    return WorldMapFrame ~= nil and WorldMapFrame:IsShown()
end

-- The map with the most objective spots; the player's own map first when it has some.
local function ObjectiveMap(info)
    local places = info.objectivePlaces
    if type(places) ~= "table" then return end
    local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if here and places[here] then return here, places[here] end
    local best
    for mapId, list in pairs(places) do
        if not best or #list > #places[best] then best = mapId end
    end
    return best, best and places[best]
end

local function ShowOnMap(info, kind)
    kind = kind or "start"
    local target = {id = info.id, name = info.name, kind = kind, inLog = IsInLog(info.id), points = {}}
    if kind == "objective" then
        local mapId, list = ObjectiveMap(info)
        if not mapId then return false end
        target.mapId, target.zone = mapId, MapName(mapId)
        -- Spread over all of them when there are more spots than pins.
        local count = math.min(#list, MAX_PINS)
        for i = 1, count do target.points[i] = list[math.floor((i - 1) * #list / count) + 1] end
    else
        local place = Place(info, kind)
        if not (place.mapId and place.x and place.y) then return false end
        target.mapId, target.zone = place.mapId, place.zone
        target.where = place.who and (place.who .. (place.zone and (", " .. place.zone) or ""))
        target.points[1] = {x = place.x, y = place.y}
        AddWaypoint(info, kind)
    end
    CreatePinDriver()
    mapTarget = target
    if OpenMap(target.mapId) then
        -- The map sits below this window: step aside while it is open.
        if frame and frame:IsShown() then
            frame.reopenAfterMap = true
            frame:Hide()
        end
    elseif InCombatLockdown() then
        print(("|cffffd100RXPBlizzStyle:|r %s: the %s is marked on the map (%s); the map cannot be opened in combat.")
            :format(info.name, kind == "end" and "turn-in" or kind == "objective" and "objective" or "start", target.zone or "?"))
    end
    PlacePins()
    return true
end

local function MapButton_OnClick(button)
    local info = button:GetParent().info
    if info and ShowOnMap(info, button.kind) then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
end

local function MapButton_OnEnter(button)
    local info = button:GetParent().info
    if not info then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    if button.kind == "objective" then
        GameTooltip:SetText("Show on Map: where to do it")
        if info.objective then GameTooltip:AddLine(info.objective, 1, 1, 1, true) end
        for _, name in ipairs(info.objectiveNames or {}) do GameTooltip:AddLine("- " .. name, 0.9, 0.9, 0.9, true) end
        local mapId, list = ObjectiveMap(info)
        if mapId then
            GameTooltip:AddLine(("%d spot%s in %s"):format(#list, #list == 1 and "" or "s", MapName(mapId) or "?"), 0.8, 0.8, 0.8)
        elseif info.objectiveGiven then
            GameTooltip:AddLine("The quest giver hands it to you with the quest; take it to where the quest ends (Ends).", 1, 0.82, 0, true)
        else
            GameTooltip:AddLine("Questie has no places for this quest's objectives.", 1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
        return
    end
    local isEnd = button.kind == "end"
    local place = Place(info, button.kind)
    GameTooltip:SetText(isEnd and "Show on Map: where it is handed in" or "Show on Map: where it starts")
    if place.mapId and place.x then
        GameTooltip:AddLine(("%s%s (%.1f, %.1f)"):format(place.who and (place.who .. ", ") or "", place.zone or "?", place.x, place.y), 1, 1, 1, true)
        if _G.TomTom then GameTooltip:AddLine("Also sets a TomTom waypoint.", 0.5, 0.8, 1, true) end
    elseif place.who then
        GameTooltip:AddLine(place.who, 1, 1, 1, true)
        GameTooltip:AddLine("Questie has no place for it on the map.", 1, 0.3, 0.3, true)
    else
        GameTooltip:AddLine(isEnd and "Questie does not know where this quest is handed in."
            or "Questie does not know where this quest starts.", 1, 0.3, 0.3, true)
    end
    GameTooltip:Show()
end

local SHARE_TIP = {
    share = {"Shareable Quest", 0.25, 1, 0.25, nil},
    group = {"Shareable Quest", 0.25, 1, 0.25, "Join a group to share it."},
    no = {"Not Shareable", 1, 0.15, 0.15, nil},
    log = {"Share", 1, 0.82, 0, "Accept this quest to share it with your group."},
}

local function ColorShareButton(button, hover)
    local state = button.state
    if state == "share" or state == "group" then
        button:SetBackdropColor(hover and 0.13 or 0.10, hover and 0.40 or 0.34, hover and 0.19 or 0.16, 1)
        button:SetBackdropBorderColor(0.48, 0.40, 0.27, 1)
        button.Text:SetTextColor(1, 0.82, 0.27)
    else
        local grey = hover and 0.22 or 0.18
        button:SetBackdropColor(grey, grey, grey, 0.96)
        button:SetBackdropBorderColor(0.34, 0.34, 0.34, 1)
        button.Text:SetTextColor(0.55, 0.55, 0.55)
    end
end

local function ShareButton_OnClick(button)
    local info = button:GetParent().info
    if not info then return end
    if IsModifiedClick and IsModifiedClick("CHATLINK") then
        LinkQuest(info)
    elseif button.state == "share" and ShareQuest(info.id) then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

local function ShareButton_OnEnter(button)
    local info = button:GetParent().info
    if not info then return end
    button.state = ShareState(info.id)
    ColorShareButton(button, true)
    local tip = SHARE_TIP[button.state]
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:SetText(tip[1], tip[2], tip[3], tip[4])
    if tip[5] then GameTooltip:AddLine(tip[5], 1, 1, 1, true) end
    GameTooltip:AddLine("Shift-click: link it in chat", 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function ShareButton_OnLeave(button)
    ColorShareButton(button, false)
    if GameTooltip:GetOwner() == button then GameTooltip:Hide() end
end

local function ChainRow_OnEnter(row)
    local info = row.info
    if not info then return end
    row.Hover:Show()
    if ns.ShowQuestieTooltip and ns.ShowQuestieTooltip(row, {questId = info.id, tag = "accept"}) then
        GameTooltip:Show()
        return
    end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(info.name, 1, 0.82, 0)
    if info.level then GameTooltip:AddLine("Level " .. info.level, 0.9, 0.9, 0.9) end
    if info.starter then GameTooltip:AddLine("Starts at " .. info.starter .. (info.zone and (", " .. info.zone) or ""), 0.9, 0.9, 0.9, true) end
    if info.objective then GameTooltip:AddLine(info.objective, 0.9, 0.9, 0.9, true) end
    GameTooltip:AddLine(StatusText(info), 0.8, 0.8, 0.8)
    if info.mapId and _G.TomTom then GameTooltip:AddLine("Click: TomTom waypoint to where it starts", 0.5, 0.8, 1) end
    GameTooltip:AddLine("Shift-click: link it in chat", 0.5, 0.8, 1)
    GameTooltip:Show()
end

local function ChainRow_OnLeave(row)
    row.Hover:Hide()
    if ns.HideQuestieTooltip then ns.HideQuestieTooltip(row) end
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
end

local function ChainRow_OnClick(row)
    if row.info and IsModifiedClick and IsModifiedClick("CHATLINK") then
        LinkQuest(row.info)
    elseif row.info and AddWaypoint(row.info) then
        PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
    end
end

local function CreateChainRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(CHAIN_HEIGHT)
    row.Hover = row:CreateTexture(nil, "BACKGROUND")
    row.Hover:SetAllPoints()
    row.Hover:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row.Hover:SetBlendMode("ADD")
    row.Hover:SetAlpha(0.35)
    row.Hover:Hide()
    row.Number = row:CreateFontString(nil, "OVERLAY")
    Font(row.Number, "QuestTitleFont", "GameFontNormalLarge")
    row.Number:SetPoint("TOPLEFT", 4, -6)
    row.Number:SetWidth(26)
    row.Number:SetJustifyH("RIGHT")
    row.Number:SetTextColor(unpack(INK_SOFT))
    row.Number:SetShadowColor(0, 0, 0, 0)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(18, 18)
    row.Icon:SetPoint("TOPLEFT", 34, -6)
    row.Status = row:CreateFontString(nil, "OVERLAY")
    Font(row.Status, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Status:SetPoint("TOPRIGHT", -8, -8)
    row.Status:SetJustifyH("RIGHT")
    row.Status:SetShadowColor(0, 0, 0, 0)
    row.Name = row:CreateFontString(nil, "OVERLAY")
    Font(row.Name, "QuestFont", "GameFontNormal")
    row.Name:SetPoint("TOPLEFT", 58, -6)
    row.Name:SetPoint("RIGHT", row.Status, "LEFT", -10, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row.Name:SetShadowColor(0, 0, 0, 0)
    row.Meta = row:CreateFontString(nil, "OVERLAY")
    Font(row.Meta, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Meta:SetPoint("TOPLEFT", row.Name, "BOTTOMLEFT", 0, -4)
    row.Meta:SetPoint("RIGHT", -8, 0)
    row.Meta:SetJustifyH("LEFT")
    row.Meta:SetWordWrap(false)
    row.Meta:SetShadowColor(0, 0, 0, 0)
    row.Objective = row:CreateFontString(nil, "OVERLAY")
    Font(row.Objective, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Objective:SetPoint("TOPLEFT", row.Meta, "BOTTOMLEFT", 0, -3)
    row.Objective:SetWidth(DETAIL_WIDTH - 16 - 58 - 8)
    row.Objective:SetJustifyH("LEFT")
    if row.Objective.SetMaxLines then row.Objective:SetMaxLines(4) end
    row.Objective:SetTextColor(unpack(INK))
    row.Objective:SetShadowColor(0, 0, 0, 0)
    row:SetScript("OnEnter", ChainRow_OnEnter)
    row:SetScript("OnLeave", ChainRow_OnLeave)
    row:SetScript("OnClick", ChainRow_OnClick)

    local function MapButton(kind, text, width)
        local button = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        button.kind = kind
        button:SetSize(width, 20)
        button:SetText(text)
        button:SetMotionScriptsWhileDisabled(true)
        button:SetScript("OnClick", MapButton_OnClick)
        button:SetScript("OnEnter", MapButton_OnEnter)
        button:SetScript("OnLeave", function(self) if GameTooltip:GetOwner() == self then GameTooltip:Hide() end end)
        return button
    end
    row.StartButton = MapButton("start", "Starts", 64)
    row.StartButton:SetPoint("TOPLEFT", row.Meta, "BOTTOMLEFT", -2, -5)
    row.EndButton = MapButton("end", "Ends", 56)
    row.EndButton:SetPoint("LEFT", row.StartButton, "RIGHT", 4, 0)
    row.ObjectiveButton = MapButton("objective", "Objective", 80)
    row.ObjectiveButton:SetPoint("LEFT", row.EndButton, "RIGHT", 4, 0)

    row.ShareButton = CreateFrame("Button", nil, row, "BackdropTemplate")
    row.ShareButton:SetSize(60, 20)
    row.ShareButton:SetPoint("LEFT", row.ObjectiveButton, "RIGHT", 6, 0)
    SetBackdrop(row.ShareButton, "Interface\\Buttons\\WHITE8X8", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 4)
    row.ShareButton:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.ShareButton.Text = row.ShareButton:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.ShareButton.Text:SetPoint("CENTER")
    row.ShareButton.Text:SetText("Share")
    row.ShareButton:SetScript("OnClick", ShareButton_OnClick)
    row.ShareButton:SetScript("OnEnter", ShareButton_OnEnter)
    row.ShareButton:SetScript("OnLeave", ShareButton_OnLeave)
    return row
end

local function UpdateScrollBar(scroll)
    local bar = scroll.ScrollBar or (scroll:GetName() and _G[scroll:GetName() .. "ScrollBar"])
    if not bar then return end
    scroll:UpdateScrollChildRect()
    local scrollable = (scroll:GetVerticalScrollRange() or 0) > 1
    bar:SetShown(scrollable)
    if not scrollable then scroll:SetVerticalScroll(0) end
end

local XP_COLOR = {0.10, 0.25, 0.55}

local function FormatXp(xp)
    return (BreakUpLargeNumbers and BreakUpLargeNumbers(xp) or tostring(xp)) .. " XP"
end

local function XpSum(list)
    local total = 0
    for _, info in ipairs(list or {}) do total = total + (info.xp or 0) end
    return total
end

-- The experience of the whole chain, to weigh doing it against skipping it: the missing quests before the guide's
-- quest, the guide's quest itself and the rest of the chain after it. A hand-in entry's chain already ends with
-- the guide's quest. Returns total, before, own, after.
local function ChainXp(entry)
    local before = XpSum(entry.chain)
    local own = entry.kind == "handin" and 0 or (entry.xp or 0)
    local after = XpSum(entry.after)
    return before + own + after, before, own, after
end

local function MetaLine(info)
    local parts = {}
    if info.level then parts[#parts + 1] = "Level " .. info.level end
    if info.xp then parts[#parts + 1] = FormatXp(info.xp) end
    if info.starter then parts[#parts + 1] = info.starter .. (info.zone and (", " .. info.zone) or "") end
    if info.guideStep then parts[#parts + 1] = ("guide: step %d"):format(info.guideStep) end
    return table.concat(parts, "  -  ")
end

--------------------------------------------------------------------------------------------------
-- The route for the ticked quests (Route.lua), on the parchment in place of the chosen quest.

local ROUTE_GAP = 2

local function Duration(seconds)
    local minutes = math.floor(seconds / 60 + 0.5)
    if minutes < 1 then return "under 1 min" end
    if minutes < 60 then return minutes .. " min" end
    return ("%d h %02d min"):format(math.floor(minutes / 60), minutes % 60)
end

-- "Booty Bay, Stranglethorn" is Booty Bay.
local function ShortPlace(name)
    return type(name) == "string" and name:match("^%s*([^,]+)") or tostring(name)
end

-- The way to a stop in words: "fly Sentinel Hill to Booty Bay, ship Booty Bay - Ratchet, walk 4 min (12 min)".
local function LegText(leg)
    if not leg then return end
    if leg.cross then return "on another continent, no way known" end
    local bits = {}
    for _, part in ipairs(leg.parts) do
        if part.mode == "fly" then
            bits[#bits + 1] = ("fly %s to %s"):format(ShortPlace(part.from), ShortPlace(part.to))
        elseif part.mode == "ride" then
            bits[#bits + 1] = ("%s %s"):format(part.kind, part.name)
        elseif part.mode == "teleport" then
            bits[#bits + 1] = "teleport to " .. part.name
        elseif part.mode == "hearth" then
            bits[#bits + 1] = "hearthstone to " .. part.name
        elseif #leg.parts == 1 then
            return "walk " .. Duration(part.seconds)
        elseif part.seconds >= 60 then
            bits[#bits + 1] = "walk " .. Duration(part.seconds)
        end
    end
    if #bits == 0 then return "right there" end
    return ("%s (%s)"):format(table.concat(bits, ", "), Duration(leg.seconds))
end

local function StopText(stop)
    local quest = stop.info.name
    if stop.kind == "finish" then
        return "Go to " .. quest
    elseif stop.kind == "pickup" then
        return "Pick up " .. quest .. (stop.who and ("  -  " .. stop.who) or "")
    elseif stop.kind == "item" then
        return ("Find %s, it starts %s"):format(stop.who or "the item", quest)
    elseif stop.kind == "objective" then
        return "Do " .. quest .. (stop.who and ("  -  " .. stop.who) or "")
    end
    return "Hand in " .. quest .. (stop.who and ("  -  " .. stop.who) or "")
end

-- The experience of the guide's own quests that the ticked entries open up.
local function UnlockedXp(entries)
    local xp = 0
    for _, entry in ipairs(entries) do xp = xp + (entry.xp or 0) end
    return xp
end

-- A planned route in a few short lines: stops, time and experience, then what is worth a word.
local function RouteSummary(route, entries)
    local head = {("%d stop%s"):format(#route.stops, #route.stops == 1 and "" or "s"), "about " .. Duration(route.seconds)}
    if route.xp > 0 then head[#head + 1] = FormatXp(route.xp) .. " on the way" end
    local lines = {table.concat(head, "  -  ")}
    local unlocked = UnlockedXp(entries)
    if unlocked > 0 then lines[#lines + 1] = ("Opens up %s in the guide"):format(FormatXp(unlocked)) end
    if route.hearth then lines[#lines + 1] = "Hearthstone to " .. route.hearth .. ", once" end
    if route.teleports > 0 then
        lines[#lines + 1] = ("%d teleport%s (%d rune%s in bags)"):format(route.teleports, route.teleports == 1 and "" or "s",
            route.runes or 0, (route.runes or 0) == 1 and "" or "s")
    end
    if route.rides > 0 then
        lines[#lines + 1] = ("%d ride%s by ship, zeppelin or tram (ship or zeppelin: %d min)"):format(route.rides,
            route.rides == 1 and "" or "s", (ns.TRANSPORT_BEST + ns.TRANSPORT_WORST) / 120)
    end
    if route.crossings > 0 then
        lines[#lines + 1] = ("%d way%s to another continent unknown, not counted"):format(route.crossings, route.crossings == 1 and "" or "s")
    end
    if route.unplaced > 0 then
        lines[#lines + 1] = ("%d stop%s without a known place"):format(route.unplaced, route.unplaced == 1 and "" or "s")
    end
    for _, note in ipairs(route.notes or {}) do lines[#lines + 1] = note end
    return lines
end

ns.RouteSummary, ns.RouteDuration, ns.FormatXp = RouteSummary, Duration, FormatXp
ns.RouteStopText, ns.RouteLegText, ns.RouteUnlockedXp = StopText, LegText, UnlockedXp

local function SelectedEntries()
    local entries = {}
    if not ns.RouteSelected then return entries end
    for _, entry in ipairs(data and data.quests or {}) do
        if ns.RouteSelected(entry.id) then entries[#entries + 1] = entry end
    end
    return entries
end

-- The route for these entries from where the player is now: true and the route, or false and the error.
local function PlanSelected(entries)
    return pcall(function()
        local env = ns.RouteEnvironment()
        local planned = ns.PlanRoute(entries, env)
        planned.runes = env.runes
        planned.source = {kind = "prereq"}
        return planned
    end)
end

-- The ticked quests of the guide as they stand now, for planning the route guide again (Route.lua).
function ns.SelectedRouteEntries()
    local result = ns.PrereqData(_G.RXP)
    local entries = {}
    for _, entry in ipairs(result and result.quests or {}) do
        if ns.RouteSelected and ns.RouteSelected(entry.id) then entries[#entries + 1] = entry end
    end
    return entries
end

local function UpdateRouteButton()
    local button = frame and frame.RouteButton
    if not button then return end
    -- Route.lua is a new file: until the game is restarted it is not there, and neither is the route.
    button:SetShown(ns.PlanRoute ~= nil)
    button:SetText("Generate route")
    button:SetEnabled(routeMode or #SelectedEntries() > 0)
end

-- Hovering the button: what the detour costs and brings.
local function RouteButton_OnEnter(button)
    GameTooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT")
    local entries = SelectedEntries()
    if #entries == 0 then
        GameTooltip:AddLine("Generate route", 1, 0.82, 0)
        GameTooltip:AddLine("Tick the quests to go for in the list first.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
        return
    end
    GameTooltip:AddLine(("Route for %d quest%s"):format(#entries, #entries == 1 and "" or "s"), 1, 0.82, 0)
    local ok, route = PlanSelected(entries)
    if not ok then
        GameTooltip:AddLine("Could not be planned: " .. tostring(route), 1, 0.3, 0.3, true)
        GameTooltip:Show()
        return
    end
    local unlocked = UnlockedXp(entries)
    GameTooltip:AddDoubleLine("Travel", "about " .. Duration(route.seconds), 0.9, 0.9, 0.9, 1, 1, 1)
    GameTooltip:AddDoubleLine(("XP on the way (%d hand-in%s)"):format(route.handins, route.handins == 1 and "" or "s"),
        FormatXp(route.xp), 0.9, 0.9, 0.9, 0.55, 0.75, 1)
    GameTooltip:AddDoubleLine("XP it opens up in the guide", FormatXp(unlocked), 0.9, 0.9, 0.9, 0.55, 0.75, 1)
    GameTooltip:AddDoubleLine("Total", FormatXp(route.xp + unlocked), 1, 0.82, 0, 0.55, 0.75, 1)
    local lines = RouteSummary(route, entries)
    for i = 3, #lines do GameTooltip:AddLine(lines[i], 0.8, 0.8, 0.8, true) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: put it into RestedXP as a guide of its own; RestedXP returns to your guide after it.", 0.5, 0.8, 1, true)
    GameTooltip:AddLine("Right-click: show the route here.", 0.5, 0.8, 1, true)
    GameTooltip:AddLine("Times are estimates: straight lines, your flight points.", 0.6, 0.6, 0.6, true)
    GameTooltip:Show()
end

-- A click on it: the route becomes a RestedXP guide of its own.
local function GenerateRouteGuide()
    local entries = SelectedEntries()
    if #entries == 0 then return end
    local ok, route = PlanSelected(entries)
    if not ok then return ns.Print("The route could not be planned: " .. tostring(route)) end
    local loaded, back = ns.LoadRouteGuide(route, nil, route.source)
    if not loaded then return ns.Print("The route guide could not be made: " .. tostring(back)) end
    ClearRouteWaypoint()
    ns.Print(("Route guide loaded: %d stops, about %s.%s"):format(#route.stops, Duration(route.seconds),
        type(back) == "table" and (" RestedXP returns to %s after it."):format(back.name) or ""))
    routeMode = false
    frame:Hide()
end

local function RouteRow_OnEnter(row)
    row.Hover:Show()
    local stop = row.stop
    if not stop then return end
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(StopText(stop), 1, 0.82, 0, true)
    if stop.entry and stop.entry.id ~= stop.info.id then
        GameTooltip:AddLine("For the guide's quest " .. stop.entry.name, 0.9, 0.9, 0.9, true)
    end
    if stop.mapId then
        GameTooltip:AddLine(_G.TomTom and "Click: TomTom waypoint to it" or "Click: show it on the map", 0.5, 0.8, 1)
    else
        GameTooltip:AddLine("No place is known for this one.", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end

local function RouteRow_OnLeave(row)
    row.Hover:Hide()
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
end

-- The TomTom waypoint of the stop clicked last: one at a time, and gone once the route is a guide (the guide's own
-- waypoints lead from then on).
function ClearRouteWaypoint()
    local tomtom = _G.TomTom
    if type(tomtom) ~= "table" or not tomtom.RemoveWaypoint then
        routeWaypoint = nil
        return
    end
    if routeWaypoint then pcall(tomtom.RemoveWaypoint, tomtom, routeWaypoint) end
    routeWaypoint = nil
    -- Leftovers of earlier clicks, which TomTom used to keep: every waypoint of this addon but the guide arrow's
    -- own (Arrow.lua sets that one silent).
    local stale = {}
    for _, list in pairs(type(tomtom.waypoints) == "table" and tomtom.waypoints or {}) do
        for _, uid in pairs(type(list) == "table" and list or {}) do
            if type(uid) == "table" and uid.from == addonName and not uid.silent then stale[#stale + 1] = uid end
        end
    end
    for _, uid in ipairs(stale) do pcall(tomtom.RemoveWaypoint, tomtom, uid) end
end

local function RouteRow_OnClick(row)
    local stop = row.stop
    if not (stop and stop.mapId and stop.x and stop.y) then return end
    local tomtom = _G.TomTom
    if type(tomtom) == "table" and tomtom.AddWaypoint then
        ClearRouteWaypoint()
        local ok, uid = pcall(tomtom.AddWaypoint, tomtom, stop.mapId, stop.x / 100, stop.y / 100,
            {title = StopText(stop), from = addonName, persistent = false})
        routeWaypoint = ok and uid or nil
    else
        ShowOnMap(stop.info, stop.kind == "turnin" and "end" or stop.kind == "objective" and "objective" or "start")
    end
    PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
end

local function CreateRouteRow(parent)
    local row = CreateFrame("Button", nil, parent)
    row.Hover = row:CreateTexture(nil, "BACKGROUND")
    row.Hover:SetAllPoints()
    row.Hover:SetColorTexture(0.45, 0.30, 0.10, 0.14)
    row.Hover:Hide()
    row.Number = row:CreateFontString(nil, "OVERLAY")
    Font(row.Number, "QuestFont", "GameFontNormal")
    row.Number:SetPoint("TOPLEFT", 4, -5)
    row.Number:SetWidth(26)
    row.Number:SetJustifyH("RIGHT")
    row.Number:SetTextColor(unpack(INK))
    row.Number:SetShadowColor(0, 0, 0, 0)
    row.Text = row:CreateFontString(nil, "OVERLAY")
    Font(row.Text, "QuestFont", "GameFontHighlight")
    row.Text:SetPoint("TOPLEFT", 38, -5)
    row.Text:SetPoint("RIGHT", -8, 0)
    row.Text:SetJustifyH("LEFT")
    row.Text:SetWordWrap(false)
    row.Text:SetTextColor(unpack(INK))
    row.Text:SetShadowColor(0, 0, 0, 0)
    row.Way = row:CreateFontString(nil, "OVERLAY")
    Font(row.Way, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Way:SetPoint("TOPLEFT", row.Text, "BOTTOMLEFT", 0, -3)
    row.Way:SetWidth(DETAIL_WIDTH - 38 - 16)
    row.Way:SetJustifyH("LEFT")
    if row.Way.SetMaxLines then row.Way:SetMaxLines(3) end
    row.Way:SetTextColor(unpack(INK_SOFT))
    row.Way:SetShadowColor(0, 0, 0, 0)
    row:SetScript("OnEnter", RouteRow_OnEnter)
    row:SetScript("OnLeave", RouteRow_OnLeave)
    row:SetScript("OnClick", RouteRow_OnClick)
    return row
end

-- Whether the player is somewhere else than where the shown route starts (more than REPLAN_YARDS away, on another
-- continent, or their place only became known).
local REPLAN_YARDS = 40
local function RouteMoved()
    if InCombatLockdown() then return false end     -- nothing is planned in a fight
    local ok, x, y, _, instance = pcall(UnitPosition, "player")
    local secret = issecretvalue and (issecretvalue(x) or issecretvalue(y) or issecretvalue(instance))
    if not ok or secret or type(x) ~= "number" or type(y) ~= "number" or not instance then return false end
    local from = frame.routeFrom
    if not from then return false end
    return from.instance ~= instance or (from.x - x) ^ 2 + (from.y - y) ^ 2 > REPLAN_YARDS ^ 2
end

local function ShowRoute()
    local detail = frame.Detail
    detail.Section:Hide()
    detail.ChainXp:Hide()
    detail.Then:Hide()
    detail.After:Hide()
    local entries = SelectedEntries()
    local ok, route = false, nil
    if #entries > 0 then ok, route = PlanSelected(entries) end
    -- Where this route starts, for RouteMoved; false: nothing that moving on would change.
    frame.routeFrom = ok and route.from or false
    if not ok then
        detail.Title:SetText("Route")
        detail.Intro:SetText(#entries == 0 and "Tick the quests to go for in the list."
            or ("The route could not be planned: " .. tostring(route)))
        detail.Content:SetHeight(200)
        return
    end
    detail.Title:SetText(("Route for %d quest%s"):format(#entries, #entries == 1 and "" or "s"))
    local intro = table.concat(RouteSummary(route, entries), "\n")
    detail.Intro:SetText(intro)
    local y = -(detail.Intro:GetStringHeight() + 52)
    for i, stop in ipairs(route.stops) do
        local row = routeRows[i]
        if not row then
            row = CreateRouteRow(detail.Content)
            routeRows[i] = row
        end
        row.stop = stop
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 8, y)
        row:SetPoint("RIGHT", detail.Content, "RIGHT", -8, 0)
        row.Number:SetText(i .. ".")
        row.Text:SetText(StopText(stop))
        local place = stop.mapId and ns.PlaceName and ns.PlaceName(stop.mapId, stop.x, stop.y) or "anywhere"
        local way = LegText(stop.leg)
        row.Way:SetText(place .. (way and ("  -  " .. way) or ""))
        local height = math.ceil(5 + row.Text:GetStringHeight() + 3 + row.Way:GetStringHeight() + 6)
        row:SetHeight(height)
        row:Show()
        y = y - height - ROUTE_GAP
    end
    detail.Content:SetHeight(-y + 30)
end

local function ShowDetail()
    local detail = frame.Detail
    for _, row in ipairs(chainRows) do row:Hide() end
    for _, row in ipairs(routeRows) do row:Hide() end
    UpdateRouteButton()
    if routeMode and ns.PlanRoute then return ShowRoute() end
    local item = data and data.display[selected]
    local entry = item and item.kind == "quest" and item.entry
    if item and item.kind == "unknown" then
        local unknown = item.entry
        detail.Title:SetText(unknown.name)
        local text = unknown.why == "guide"
            and ("The guide picks this quest up in step %d, but Questie's database does not know it (quest ID %d), so whatever comes before it cannot be listed.")
                :format(unknown.step or 0, unknown.id)
            or ("Questie names this quest (ID %d) as a prerequisite, but has nothing else on it."):format(unknown.id)
        detail.Intro:SetText(text .. "\n\nIts ID is saved with this addon's settings, so its prerequisites can be added by hand. Once they are, it is listed like the others.")
        detail.Section:Hide()
        detail.ChainXp:Hide()
        detail.Then:Hide()
        detail.After:Hide()
        detail.Content:SetHeight(200)
        return
    end
    if not entry then
        detail.Title:SetText(data and "Nothing missing" or "Missing prerequisites")
        detail.Intro:SetText(frame.reason or "Every quest this guide picks up is open to you, or the guide does the quests before it itself.")
        detail.Section:Hide()
        detail.ChainXp:Hide()
        detail.Then:Hide()
        detail.After:Hide()
        detail.Content:SetHeight(200)
        return
    end
    detail.Title:SetText(entry.name)
    local intro
    if entry.kind == "handin" then
        intro = entry.missed
            and ("The guide works on or hands in this quest in step %d, but you do not have it: you are past step %d, where the guide picks it up.")
                :format(entry.step, entry.missed)
            or ("The guide works on or hands in this quest in step %d, but you do not have it, and this guide does not pick it up."):format(entry.step)
        if entry.optional then
            intro = intro .. (ns.db.holdMissing
                and " That step is only for players who already have the quest: the guide keeps it with a red line, tick that off to skip the step."
                or " That step is only for players who already have the quest: without it, RestedXP skips the step on purpose.")
        end
        if entry.level then intro = intro .. (" It is a level %d quest."):format(entry.level) end
        local before = #entry.chain - 1
        if before > 0 then
            intro = intro .. (" %d quest%s before it %s not done either."):format(before, before == 1 and "" or "s", before == 1 and "is" or "are")
        end
    else
        intro = ("The guide picks this quest up in step %d."):format(entry.step)
        if entry.level then intro = intro .. (" It is a level %d quest."):format(entry.level) end
        intro = intro .. (" %d quest%s before it %s not done, and this guide does not do %s."):format(#entry.chain,
            #entry.chain == 1 and "" or "s", #entry.chain == 1 and "is" or "are", #entry.chain == 1 and "it" or "them")
    end
    local total, before, own, after = ChainXp(entry)
    if total > 0 then
        local parts = {}
        if before > 0 then
            parts[#parts + 1] = ("%s for the %d quest%s %s"):format(FormatXp(before), #entry.chain, #entry.chain == 1 and "" or "s",
                entry.kind == "handin" and "up to and with it" or "before it")
        end
        if own > 0 then parts[#parts + 1] = FormatXp(own) .. " for it" end
        if after > 0 then
            parts[#parts + 1] = ("%s for the %d after it"):format(FormatXp(after), #entry.after)
        end
        intro = intro .. ("\n\nThe whole chain is worth %s at your level: %s."):format(FormatXp(total), table.concat(parts, ", "))
    end
    detail.Intro:SetText(intro)
    detail.Section:Show()
    local y = -(detail.Intro:GetStringHeight() + 70)
    detail.Section:ClearAllPoints()
    detail.Section:SetPoint("TOPLEFT", 14, y + 26)
    -- The experience of the whole chain, above it on the right; at the player's level, like Questie's tooltips.
    detail.ChainXp:ClearAllPoints()
    detail.ChainXp:SetPoint("TOPRIGHT", detail.Content, "TOPRIGHT", -14, y + 24)
    detail.ChainXp:SetText(total > 0 and ("Whole chain: " .. FormatXp(total)) or "")
    detail.ChainXp:SetShown(total > 0)
    for i, info in ipairs(entry.chain) do
        local row = chainRows[i]
        if not row then
            row = CreateChainRow(detail.Content)
            chainRows[i] = row
        end
        row.info = info
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 8, y)
        row:SetPoint("RIGHT", detail.Content, "RIGHT", -8, 0)
        row.Number:SetText(i .. ".")
        SetQuestIcon(row.Icon, info.status)
        row.Name:SetText(info.name)
        row.Name:SetTextColor(unpack(INK))
        row.Meta:SetText(MetaLine(info))
        row.Status:SetText(StatusText(info))
        row.Status:SetTextColor(select(2, StatusText(info)))
        row.Meta:SetTextColor(unpack(INK_SOFT))
        -- What the quest asks for: Questie's objective text, else the names of what it is about.
        local objective = info.objective
            or (info.objectiveNames and #info.objectiveNames > 0 and table.concat(info.objectiveNames, ", "))
        objective = objective and ("Objective: " .. objective) or nil
        -- A quest waiting for the item that starts it: where that item comes from, above the objective.
        if info.status == "item" then
            local note = ("Starts from %s%s."):format(info.startItem,
                info.startItemSource and (", which " .. info.startItemSource) or ", which you do not have")
            objective = objective and (note .. "\n" .. objective) or note
        end
        row.Objective:SetText(objective or "")
        row.Objective:SetShown(objective ~= nil)
        row.StartButton:ClearAllPoints()
        row.StartButton:SetPoint("TOPLEFT", objective and row.Objective or row.Meta, "BOTTOMLEFT", -2, -5)
        row.StartButton:SetEnabled(info.mapId ~= nil and info.x ~= nil)
        row.EndButton:SetEnabled(info.endMapId ~= nil and info.endX ~= nil)
        row.ObjectiveButton:SetEnabled(ObjectiveMap(info) ~= nil)
        row.ShareButton.state = ShareState(info.id)
        ColorShareButton(row.ShareButton, false)
        local height = 6 + row.Name:GetStringHeight() + 4 + row.Meta:GetStringHeight()
            + (objective and (3 + row.Objective:GetStringHeight()) or 0) + 5 + 20 + 6
        height = math.max(math.ceil(height), CHAIN_HEIGHT)
        row:SetHeight(height)
        row:Show()
        y = y - height - CHAIN_GAP
    end
    detail.Then:ClearAllPoints()
    detail.Then:SetPoint("TOPLEFT", 40, y - 6)
    detail.Then:SetPoint("RIGHT", -14, 0)
    detail.Then:SetText(entry.kind == "handin" and ("Then the guide goes on with it in step %d."):format(entry.step)
        or ("Then the guide's quest: %s (step %d)%s"):format(entry.name, entry.step, entry.xp and ("  -  " .. FormatXp(entry.xp)) or ""))
    detail.Then:Show()
    -- The rest of the chain, as Questie's "Next in chain".
    local lines = {}
    if entry.after and #entry.after > 0 then
        lines[1] = ("After it, the chain goes on with %d more quest%s (%s):"):format(#entry.after, #entry.after == 1 and "" or "s", FormatXp(after))
        for _, info in ipairs(entry.after) do
            lines[#lines + 1] = ("%s%s%s"):format(info.level and ("[" .. info.level .. "] ") or "", info.name,
                info.xp and ("  -  " .. FormatXp(info.xp)) or "")
        end
    end
    detail.After:SetText(table.concat(lines, "\n"))
    detail.After:SetShown(#lines > 0)
    local height = -y + 6 + detail.Then:GetStringHeight()
    if #lines > 0 then height = height + 6 + detail.After:GetStringHeight() end
    detail.Content:SetHeight(height + 30)
end

local function ColorListRow(row)
    local chosen = row.index == selected
    row:SetBackdropBorderColor(chosen and 0.85 or 0.34, chosen and 0.65 or 0.27, chosen and 0.25 or 0.16, chosen and 1 or 0.85)
    row.Selected:SetShown(chosen)
end

local function ListRow_OnClick(row)
    selected = row.index
    routeMode = false
    for _, other in ipairs(listRows) do if other:IsShown() then ColorListRow(other) end end
    ShowDetail()
    frame.Detail.Scroll:SetVerticalScroll(0)
    UpdateScrollBar(frame.Detail.Scroll)
end

local function ListRow_OnEnter(row)
    local item = data and data.display[row.index]
    local entry = item and item.entry
    if not entry then return end
    if ns.ShowQuestieTooltip and ns.ShowQuestieTooltip(row, {questId = entry.id, tag = "accept"}) then
        GameTooltip:Show()
    end
end

local function ListRow_OnLeave(row)
    if ns.HideQuestieTooltip then ns.HideQuestieTooltip(row) end
    if GameTooltip:GetOwner() == row then GameTooltip:Hide() end
end

local function ListCheck_OnClick(check)
    local item = data and data.display and data.display[check:GetParent().index]
    if not (item and item.kind == "quest" and ns.SetRouteSelected) then return end
    ns.SetRouteSelected(item.entry.id, check:GetChecked() and true or false)
    PlaySound(check:GetChecked() and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
    if routeMode then
        ShowDetail()
        UpdateScrollBar(frame.Detail.Scroll)
    else
        UpdateRouteButton()
    end
end

local function CreateListRow(parent)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:SetHeight(ROW_HEIGHT)
    SetBackdrop(row, "Interface\\Buttons\\WHITE8X8", "Interface\\Tooltips\\UI-Tooltip-Border", 12, 3)
    row:SetBackdropColor(0.08, 0.065, 0.05, 0.92)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row:GetHighlightTexture():SetAlpha(0.35)
    row.Selected = row:CreateTexture(nil, "BACKGROUND", nil, 1)
    row.Selected:SetPoint("TOPLEFT", 3, -3)
    row.Selected:SetPoint("BOTTOMRIGHT", -3, 3)
    row.Selected:SetColorTexture(0.55, 0.40, 0.12, 0.25)
    row.Icon = row:CreateTexture(nil, "ARTWORK")
    row.Icon:SetSize(22, 22)
    row.Icon:SetPoint("TOPLEFT", 10, -9)
    row.Name = row:CreateFontString(nil, "OVERLAY")
    Font(row.Name, "QuestFont", "GameFontNormal")
    row.Xp = row:CreateFontString(nil, "OVERLAY")
    Font(row.Xp, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Xp:SetPoint("TOPRIGHT", -10, -11)
    row.Xp:SetJustifyH("RIGHT")
    row.Xp:SetTextColor(0.55, 0.75, 1)
    row.Name:SetPoint("TOPLEFT", 40, -9)
    row.Name:SetPoint("RIGHT", row.Xp, "LEFT", -8, 0)
    row.Name:SetJustifyH("LEFT")
    row.Name:SetWordWrap(false)
    row.Meta = row:CreateFontString(nil, "OVERLAY")
    Font(row.Meta, "QuestFontNormalSmall", "GameFontHighlightSmall")
    row.Meta:SetPoint("TOPLEFT", row.Name, "BOTTOMLEFT", 0, -5)
    row.Meta:SetPoint("RIGHT", -32, 0)
    row.Meta:SetJustifyH("LEFT")
    row.Meta:SetWordWrap(false)
    row.Meta:SetTextColor(0.78, 0.74, 0.66)
    -- On the route or not.
    row.Check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    row.Check:SetSize(24, 24)
    row.Check:SetPoint("BOTTOMRIGHT", -4, 3)
    row.Check:SetScript("OnClick", ListCheck_OnClick)
    row.Check:SetScript("OnEnter", function(check)
        GameTooltip:SetOwner(check, "ANCHOR_RIGHT")
        GameTooltip:AddLine("On the route", 1, 0.82, 0)
        GameTooltip:AddLine("The Route button plans one trip through everything that has to be done before the ticked quests.", 0.9, 0.9, 0.9, true)
        GameTooltip:Show()
    end)
    row.Check:SetScript("OnLeave", function(check)
        if GameTooltip:GetOwner() == check then GameTooltip:Hide() end
    end)
    row:SetScript("OnClick", ListRow_OnClick)
    row:SetScript("OnEnter", ListRow_OnEnter)
    row:SetScript("OnLeave", ListRow_OnLeave)
    return row
end

local function CreateGroupHeader(parent)
    local header = CreateFrame("Frame", nil, parent)
    header:SetHeight(HEADER_HEIGHT)
    header.Count = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    header.Count:SetPoint("BOTTOMRIGHT", -6, 6)
    header.Count:SetTextColor(0.78, 0.74, 0.66)
    header.Name = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header.Name:SetPoint("BOTTOMLEFT", 4, 5)
    header.Name:SetPoint("RIGHT", header.Count, "LEFT", -8, 0)
    header.Name:SetJustifyH("LEFT")
    header.Name:SetWordWrap(false)
    header.Name:SetTextColor(unpack(GOLD))
    local line = Line(header, "ARTWORK", 0.68, 0.52, 0.20, 0.45)
    line:SetPoint("BOTTOMLEFT", 2, 1)
    line:SetPoint("BOTTOMRIGHT", -2, 1)
    line:SetHeight(1)
    return header
end

-- The rows of the list: the quests grouped by the place their trip begins at (entry.place), the groups in the
-- order of the guide's steps, then the quests Questie does not know. The first row of a group carries its
-- header: {kind = "quest" / "unknown", entry, header = place, groupSize}.
function ns.PrereqDisplay(result)
    local display, groups, byPlace = {}, {}, {}
    for _, entry in ipairs(result and result.quests or {}) do
        local place = entry.place or "Unknown place"
        local group = byPlace[place]
        if not group then
            group = {}
            byPlace[place] = group
            groups[#groups + 1] = group
        end
        group[#group + 1] = {kind = "quest", entry = entry, header = #group == 0 and place or nil}
    end
    local unknown = {}
    for _, entry in ipairs(result and result.unknown or {}) do
        unknown[#unknown + 1] = {kind = "unknown", entry = entry, header = #unknown == 0 and "Not in Questie's database" or nil}
    end
    if #unknown > 0 then groups[#groups + 1] = unknown end
    for _, group in ipairs(groups) do
        group[1].groupSize = #group
        for _, item in ipairs(group) do display[#display + 1] = item end
    end
    return display
end

local function Refresh()
    if not frame or not frame:IsShown() then return end
    local reason, rxp = nil, _G.RXP
    frame.shownGuide = type(rxp) == "table" and rxp.currentGuide or nil
    -- The chosen quest stays chosen when the list changes around it.
    local before = data and data.display and data.display[selected]
    local chosenId = before and before.entry.id
    data, reason = ns.PrereqData(rxp)
    frame.reason = reason
    frame.Guide:SetText(data and data.guide or "")
    local quests = data and data.quests or {}
    local display = ns.PrereqDisplay(data)
    if data then data.display = display end
    for index, item in ipairs(display) do
        if chosenId and item.entry.id == chosenId then
            selected = index
            break
        end
    end
    if focusQuest then
        -- The entry for that quest, or the one whose chain has it.
        focusMissed = data ~= nil
        for index, item in ipairs(display) do
            local found = item.entry.id == focusQuest
            for _, info in ipairs(item.entry.chain or {}) do found = found or info.id == focusQuest end
            if found then
                selected = index
                focusMissed = false
                break
            end
        end
        focusQuest = nil
    end
    if not display[selected] then selected = display[1] and 1 or nil end
    local count = data and (#quests == 1 and "1 quest you cannot pick up" or (#quests .. " quests you cannot pick up")) or ""
    if data and #data.unknown > 0 then count = count .. (", %d unknown"):format(#data.unknown) end
    frame.Count:SetText(count)
    local y, headers = 0, 0
    for i, item in ipairs(display) do
        local entry = item.entry
        if item.header then
            headers = headers + 1
            local header = groupHeaders[headers]
            if not header then
                header = CreateGroupHeader(frame.List.Content)
                groupHeaders[headers] = header
            end
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", 0, -y)
            header:SetPoint("RIGHT", frame.List.Content, "RIGHT", 0, 0)
            header.Name:SetText(item.header)
            header.Count:SetText(item.groupSize == 1 and "1 quest" or (item.groupSize .. " quests"))
            header:Show()
            item.headerY = y
            y = y + HEADER_HEIGHT + ROW_GAP
        end
        local row = listRows[i]
        if not row then
            row = CreateListRow(frame.List.Content)
            listRows[i] = row
        end
        row.index = i
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetPoint("RIGHT", frame.List.Content, "RIGHT", 0, 0)
        item.y = y
        y = y + ROW_HEIGHT + ROW_GAP
        local meta, xp
        row.Name:SetText(entry.name)
        row.Check:SetShown(item.kind == "quest" and ns.PlanRoute ~= nil)
        row.Check:SetChecked(item.kind == "quest" and ns.RouteSelected ~= nil and ns.RouteSelected(entry.id))
        if item.kind == "unknown" then
            row.Icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            row.Icon:SetDesaturated(true)
            row.Icon:SetAlpha(0.8)
            row.Name:SetTextColor(0.6, 0.6, 0.6)
            meta = (entry.step and ("Step %d  -  "):format(entry.step) or "") .. "Not in Questie's database"
        else
            SetQuestIcon(row.Icon, "locked")
            row.Name:SetTextColor(LevelColor(entry.level))
            meta = ("Step %d"):format(entry.step)
            if entry.level then meta = ("Level %d  -  "):format(entry.level) .. meta end
            if entry.kind == "handin" then
                meta = meta .. (entry.optional and "  -  optional" or "  -  not picked up")
            else
                meta = meta .. ("  -  %d missing"):format(#entry.chain)
            end
            xp = ChainXp(entry)
        end
        row.Meta:SetText(meta)
        row.Xp:SetText(xp and xp > 0 and FormatXp(xp) or "")
        ColorListRow(row)
        row:Show()
    end
    for i = #display + 1, #listRows do listRows[i]:Hide() end
    for i = headers + 1, #groupHeaders do groupHeaders[i]:Hide() end
    frame.List.Content:SetHeight(math.max(y, 1))
    ShowDetail()
    UpdateScrollBar(frame.List)
    UpdateScrollBar(frame.Detail.Scroll)
end

local refreshPending = false
local function RefreshSoon()
    if refreshPending or not frame or not frame:IsShown() then return end
    refreshPending = true
    C_Timer.After(0.5, function()
        refreshPending = false
        Refresh()
    end)
end

local function CreateScroll(parent, name, width)
    local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
    scroll.scrollBarHideable = true    -- Blizzard's scroll frame hides the bar while there is nothing to scroll
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(width, 1)
    scroll:SetScrollChild(content)
    scroll.Content = content
    return scroll
end

local function CreateWindow()
    frame = CreateFrame("Frame", "RXPBlizzStylePrereqFrame", UIParent, "BackdropTemplate")
    frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
    frame:SetPoint("CENTER", 0, 10)
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    SetBackdrop(frame, "Interface\\FrameGeneral\\UI-Background-Rock", "Interface\\DialogFrame\\UI-DialogBox-Border", 24, 6)
    frame:SetBackdropColor(0.045, 0.042, 0.037, 0.99)
    tinsert(UISpecialFrames, frame:GetName())

    local strip = Line(frame, "BACKGROUND", 0.14, 0.10, 0.055, 0.96)
    strip:SetPoint("TOPLEFT", 12, -10)
    strip:SetPoint("TOPRIGHT", -12, -10)
    strip:SetHeight(34)
    local top = Line(frame, "ARTWORK", 0.68, 0.52, 0.20, 0.65)
    top:SetPoint("TOPLEFT", strip, "TOPLEFT")
    top:SetPoint("TOPRIGHT", strip, "TOPRIGHT")
    top:SetHeight(1)
    local bottom = Line(frame, "ARTWORK", 0.68, 0.52, 0.20, 0.45)
    bottom:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT")
    bottom:SetPoint("BOTTOMRIGHT", strip, "BOTTOMRIGHT")
    bottom:SetHeight(1)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Missing Prerequisites")
    title:SetTextColor(unpack(GOLD))
    frame.Guide = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.Guide:SetPoint("LEFT", strip, "LEFT", 12, 0)
    frame.Guide:SetWidth(220)
    frame.Guide:SetJustifyH("LEFT")
    frame.Guide:SetWordWrap(false)
    frame.Guide:SetTextColor(0.85, 0.78, 0.62)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("RIGHT", strip, "RIGHT", 2, 0)
    -- The template closes through HideUIPanel, which sets secure attributes and is blocked in a fight.
    close:SetScript("OnClick", function() frame:Hide() end)

    -- The route for the ticked quests, in place of the chosen quest's page, and back.
    frame.RouteButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.RouteButton:SetSize(110, 22)
    frame.RouteButton:SetPoint("RIGHT", close, "LEFT", -6, 0)
    frame.RouteButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    if frame.RouteButton.SetMotionScriptsWhileDisabled then frame.RouteButton:SetMotionScriptsWhileDisabled(true) end
    frame.RouteButton:SetScript("OnClick", function(_, mouseButton)
        GameTooltip:Hide()
        if mouseButton ~= "RightButton" then return GenerateRouteGuide() end
        routeMode = not routeMode
        ShowDetail()
        frame.Detail.Scroll:SetVerticalScroll(0)
        UpdateScrollBar(frame.Detail.Scroll)
    end)
    frame.RouteButton:SetScript("OnEnter", RouteButton_OnEnter)
    frame.RouteButton:SetScript("OnLeave", function(button)
        if GameTooltip:GetOwner() == button then GameTooltip:Hide() end
    end)

    -- Left: the guide's quests that cannot be picked up.
    frame.Count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.Count:SetPoint("TOPLEFT", 22, -56)
    frame.Count:SetTextColor(unpack(GOLD))
    frame.List = CreateScroll(frame, "RXPBlizzStylePrereqList", LIST_WIDTH)
    frame.List:SetPoint("TOPLEFT", 18, -76)
    frame.List:SetSize(LIST_WIDTH, WINDOW_HEIGHT - 96)

    -- Right: the selected quest on parchment.
    local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    inset:SetPoint("TOPLEFT", frame.List, "TOPRIGHT", 30, 20)
    inset:SetPoint("BOTTOMRIGHT", -18, 18)
    SetBackdrop(inset, "Interface\\Buttons\\WHITE8X8", "Interface\\Tooltips\\UI-Tooltip-Border", 10, 3)
    inset:SetBackdropColor(0.70, 0.58, 0.39, 1)
    inset:SetBackdropBorderColor(0.36, 0.23, 0.09, 1)
    local parchment = inset:CreateTexture(nil, "BACKGROUND", nil, -3)
    parchment:SetPoint("TOPLEFT", 4, -4)
    parchment:SetPoint("BOTTOMRIGHT", -4, 4)
    parchment:SetTexture("Interface\\QuestFrame\\QuestBG")
    parchment:SetVertexColor(1.00, 0.96, 0.84, 1.00)

    local detail = {}
    frame.Detail = detail
    detail.Scroll = CreateScroll(inset, "RXPBlizzStylePrereqDetail", DETAIL_WIDTH)
    detail.Scroll:SetPoint("TOPLEFT", 8, -10)
    detail.Scroll:SetPoint("BOTTOMRIGHT", -30, 10)
    detail.Content = detail.Scroll.Content
    detail.Title = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.Title, "QuestTitleFont", "GameFontNormalLarge")
    detail.Title:SetPoint("TOPLEFT", 14, -10)
    detail.Title:SetPoint("RIGHT", -14, 0)
    detail.Title:SetJustifyH("LEFT")
    detail.Title:SetTextColor(unpack(INK))
    detail.Title:SetShadowColor(0, 0, 0, 0)
    detail.Intro = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.Intro, "QuestFont", "GameFontHighlight")
    detail.Intro:SetPoint("TOPLEFT", detail.Title, "BOTTOMLEFT", 0, -10)
    detail.Intro:SetPoint("RIGHT", -14, 0)
    detail.Intro:SetJustifyH("LEFT")
    detail.Intro:SetTextColor(unpack(INK))
    detail.Intro:SetShadowColor(0, 0, 0, 0)
    detail.Section = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.Section, "QuestTitleFont", "GameFontNormal")
    detail.Section:SetText("Do these first, in this order")
    detail.Section:SetTextColor(unpack(INK))
    detail.Section:SetShadowColor(0, 0, 0, 0)
    detail.ChainXp = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.ChainXp, "QuestFont", "GameFontNormal")
    detail.ChainXp:SetJustifyH("RIGHT")
    detail.ChainXp:SetTextColor(unpack(XP_COLOR))
    detail.ChainXp:SetShadowColor(0, 0, 0, 0)
    detail.Then = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.Then, "QuestFontNormalSmall", "GameFontHighlightSmall")
    detail.Then:SetPoint("RIGHT", -14, 0)
    detail.Then:SetJustifyH("LEFT")
    detail.Then:SetTextColor(unpack(INK_SOFT))
    detail.Then:SetShadowColor(0, 0, 0, 0)
    detail.After = detail.Content:CreateFontString(nil, "OVERLAY")
    Font(detail.After, "QuestFontNormalSmall", "GameFontHighlightSmall")
    detail.After:SetPoint("TOPLEFT", detail.Then, "BOTTOMLEFT", 0, -6)
    detail.After:SetPoint("RIGHT", -14, 0)
    detail.After:SetJustifyH("LEFT")
    detail.After:SetSpacing(2)
    detail.After:SetTextColor(unpack(INK_SOFT))
    detail.After:SetShadowColor(0, 0, 0, 0)

    frame:SetScript("OnShow", Refresh)
    frame:RegisterEvent("QUEST_ACCEPTED")
    frame:RegisterEvent("QUEST_TURNED_IN")
    frame:RegisterEvent("QUEST_REMOVED")
    frame:RegisterEvent("PLAYER_LEVEL_UP")
    frame:SetScript("OnEvent", RefreshSoon)
    -- A different guide: list it anew.
    local elapsed = 0
    frame:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed < 1 then return end
        elapsed = 0
        local rxp = _G.RXP
        local guide = type(rxp) == "table" and rxp.currentGuide
        if (guide or nil) ~= frame.shownGuide then
            selected = nil
            Refresh()
        elseif routeMode and ns.PlanRoute and RouteMoved() then
            -- The player went on: the route starts where they are now, and the next stop is the one that is
            -- nearest in travel time from there.
            ShowDetail()
            UpdateScrollBar(frame.Detail.Scroll)
        end
    end)
    frame:Hide()
end

function ns.TogglePrereqs()
    if not frame then CreateWindow() end
    frame:SetShown(not frame:IsShown())
end

-- Opens the window at the entry of a quest (a click on a quest line of a quest the player does not have).
function ns.ShowPrereqsFor(id)
    if not frame then CreateWindow() end
    focusQuest, focusMissed = id, false
    if frame:IsShown() then Refresh() else frame:Show() end
    focusQuest = nil
    if focusMissed then
        -- Nothing to select: say why the list has no entry for it instead of showing another quest without a word.
        focusMissed = false
        local ok, hint = pcall(ns.QuestHint, id)
        hint = ok and type(hint) == "table" and hint or nil
        local why = "no quest has to be done before it"
        if hint and hint.status == "item" then
            why = ("it starts from the item %s, which you do not have"):format(hint.startItem)
        elseif hint and hint.status == "level" then
            why = ("it needs level %d"):format(hint.requiredLevel)
        elseif hint and hint.status == "available" then
            why = "you can pick it up now"
        end
        ns.Print(("Missing Prerequisites has no entry for %s: %s."):format(hint and hint.name or ("quest " .. id), why))
        return
    end
    if selected then
        local scroll = frame.List
        local range = scroll:GetVerticalScrollRange() or 0
        -- To the chosen row, with the header of its group when it is the group's first.
        local item = data and data.display and data.display[selected]
        local y = item and (item.headerY or item.y) or 0
        scroll:SetVerticalScroll(math.max(0, math.min(range, y)))
    end
end

-- Whether a quest is for this character's race and class; true without Questie or for a quest it does not know.
function ns.QuestForMe(id)
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle and type(id) == "number" and IsKnown(db, id)) then return true end
    return IsForMe(db, player, id) and true or false
end

--------------------------------------------------------------------------------------------------
-- Picking a guide that has missing prerequisites asks whether to review them. Only a guide the player picks (or
-- RestedXP moves on to): the one it restores after logging in or reloading is not asked about again, since the
-- player may have decided to skip some of them.

local PROMPT_GRACE = 10     -- seconds after loading in which the guide RestedXP restores does not count as picked
local PROMPT_WAIT = 30      -- how long a picked guide waits for Questie and its steps before it is not asked about

local prompt
local loadedAt, knownGuide, pending
local wasRoute = false      -- the guide before this one was the route guide

local function GuideKey(guide)
    if type(guide) ~= "table" or guide.empty then return "none" end
    return guide.key or (tostring(guide.group) .. "\031" .. tostring(guide.name))
end

local function OpenWindow()
    if not frame then CreateWindow() end
    if frame:IsShown() then Refresh() else frame:Show() end
end

local function PromptButton(text, onClick)
    local button = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
    button:SetSize(120, 24)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreatePrompt()
    prompt = CreateFrame("Frame", "RXPBlizzStylePrereqPrompt", UIParent, "BackdropTemplate")
    prompt:SetWidth(360)
    prompt:SetPoint("CENTER", 0, 160)
    prompt:SetFrameStrata("DIALOG")
    prompt:SetToplevel(true)
    prompt:SetClampedToScreen(true)
    prompt:EnableMouse(true)
    SetBackdrop(prompt, "Interface\\FrameGeneral\\UI-Background-Rock", "Interface\\DialogFrame\\UI-DialogBox-Border", 24, 6)
    prompt:SetBackdropColor(0.045, 0.042, 0.037, 0.99)
    tinsert(UISpecialFrames, prompt:GetName())

    prompt.Title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    prompt.Title:SetPoint("TOP", 0, -20)
    prompt.Title:SetText("Missing Prerequisites")
    prompt.Title:SetTextColor(unpack(GOLD))
    prompt.Text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    prompt.Text:SetPoint("TOP", prompt.Title, "BOTTOM", 0, -12)
    prompt.Text:SetWidth(310)
    prompt.Text:SetSpacing(2)

    local review = PromptButton("Review", function()
        prompt:Hide()
        OpenWindow()
    end)
    review:SetPoint("BOTTOMRIGHT", prompt, "BOTTOM", -6, 18)
    local later = PromptButton("Not now", function() prompt:Hide() end)
    later:SetPoint("BOTTOMLEFT", prompt, "BOTTOM", 6, 18)
    prompt:Hide()
end

local function ShowPrompt(guideName, count)
    if not prompt then CreatePrompt() end
    prompt.Text:SetText(("|cffffd100%s|r\n\n%d quest%s in this guide cannot be picked up yet: quests before %s are not done, and the guide does not do them.\n\nDo you want to review them?")
        :format(guideName or "This guide", count, count == 1 and "" or "s", count == 1 and "it" or "them"))
    prompt:SetHeight(20 + prompt.Title:GetStringHeight() + 12 + prompt.Text:GetStringHeight() + 18 + 24 + 18)
    prompt:Show()
end

ns.RegisterPart("missing prerequisites prompt", function(rxp)
    local now = GetTime()
    loadedAt = loadedAt or now
    local guide = rxp.currentGuide
    local key = GuideKey(guide)
    if now - loadedAt < PROMPT_GRACE or not knownGuide then
        knownGuide = key
        return
    end
    if key ~= knownGuide then
        knownGuide = key
        -- Not for the route guide, which is the answer to that question, nor on the way back from it.
        local route = ns.IsRouteGuide and (ns.IsRouteGuide(guide) or wasRoute)
        wasRoute = ns.IsRouteGuide and ns.IsRouteGuide(guide) or false
        pending = key ~= "none" and not route and {key = key, since = now} or nil
        if prompt then prompt:Hide() end
    end
    if not pending then return end
    if not ns.db.prereqPrompt or now - pending.since > PROMPT_WAIT then
        pending = nil
        return
    end
    -- Not in the middle of a fight, and only once the guide's steps and Questie are there.
    if InCombatLockdown() or not (type(guide.steps) == "table" and #guide.steps > 0) then return end
    local result = ns.PrereqData(rxp)
    if not result then return end
    pending = nil
    local count = 0
    for _, entry in ipairs(result.quests) do
        if not entry.optional then count = count + 1 end
    end
    if count > 0 and not (frame and frame:IsShown()) then ShowPrompt(result.guide, count) end
end, function()
    if prompt then prompt:Hide() end
end)
