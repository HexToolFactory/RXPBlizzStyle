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
local function GuideQuests(rxp, guide, player)
    local covered, order, stepOf, accepted = {}, {}, {}, {}
    local work = {}
    for index, step in ipairs(guide.steps or {}) do
        for _, element in ipairs(step.elements or {}) do
            local id = element.questId
            local tag = element.tag
            if type(id) == "number" and id > 0 and (tag == "accept" or tag == "turnin" or tag == "complete") then
                local real = rxp.GetQuestId and rxp.GetQuestId(id, nil, true) or id
                if tag == "accept" then
                    accepted[real] = true
                    covered[id], covered[real] = true, true
                    if not stepOf[real] then
                        stepOf[real] = index
                        order[#order + 1] = {id = real, step = index, kind = "accept"}
                    end
                else
                    if tag == "turnin" and IsInLog(real, player) then covered[id], covered[real] = true, true end
                    work[#work + 1] = {id = real, step = index}
                end
            end
        end
    end
    for _, item in ipairs(work) do
        if not accepted[item.id] and not stepOf[item.id] then
            stepOf[item.id] = item.step
            order[#order + 1] = {id = item.id, step = item.step, kind = "handin"}
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
                AddSpawns(db, "QueryNPCSingle", {o[1]}, Named(o[2] or Query(db, "QueryNPCSingle", o[1], "name")), places)
            end
        end
        for _, o in ipairs(type(objectives[2]) == "table" and objectives[2] or {}) do
            if type(o) == "table" then
                AddSpawns(db, "QueryObjectSingle", {o[1]}, Named(o[2] or Query(db, "QueryObjectSingle", o[1], "name")), places)
            end
        end
        for _, o in ipairs(type(objectives[3]) == "table" and objectives[3] or {}) do
            if type(o) == "table" then
                local name = Named(o[2] or Query(db, "QueryItemSingle", o[1], "name"))
                AddSpawns(db, "QueryNPCSingle", Query(db, "QueryItemSingle", o[1], "npcDrops"), name, places)
                AddSpawns(db, "QueryObjectSingle", Query(db, "QueryItemSingle", o[1], "objectDrops"), name, places)
            end
        end
        for _, o in ipairs(type(objectives[5]) == "table" and objectives[5] or {}) do
            if type(o) == "table" then
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
    return places, names, given
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
    info.ender, info.endZone, info.endMapId, info.endX, info.endY = Ender(db, id)
    info.objective = ObjectiveText(db, id)
    info.objectivePlaces, info.objectiveNames, info.objectiveGiven = Objectives(db, id)
    info.xp = QuestXp(id)
    if not IsKnown(db, id) then
        info.status = "unknown"
    elseif IsInLog(id, player) then
        info.status = "log"
    elseif info.requiredLevel and info.requiredLevel > UnitLevel("player") then
        info.status = "level"
    elseif #Requirements(db, player, covered, id) == 0 then
        info.status = "available"
    else
        info.status = "locked"
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

-- {guide = name, quests = {{info, step, chain = {info, ...}}, ...}, unknown = {{id, name, step, why}, ...}}
-- or nil, reason
function ns.PrereqData(rxp)
    if type(rxp) ~= "table" or not rxp.currentGuide or rxp.currentGuide.empty then
        return nil, "No guide is loaded."
    end
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle) then
        return nil, "This list needs Questie: its quest database knows which quests come before which."
    end
    local guide = rxp.currentGuide
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
            -- A quest the guide only hands in has to be picked up elsewhere too: it ends its own chain.
            if item.kind == "handin" then chain[#chain + 1] = id end
            if #chain > 0 then
                local entry = QuestInfo(db, player, covered, id)
                entry.step, entry.kind = item.step, item.kind
                entry.after = FollowingQuests(db, player, id)
                entry.chain = {}
                for i, pre in ipairs(chain) do
                    entry.chain[i] = QuestInfo(db, player, covered, pre)
                    if entry.chain[i].status == "unknown" then unknown(pre, item.step, "prerequisite of " .. id) end
                end
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

-- For the tracker's tooltip on a quest line of a quest the player does not have: the quest's info (name, starter,
-- zone, status, ...) with before = {names of the quests to do first, earliest first}; nil without Questie.
function ns.QuestHint(id)
    local db, player = Questie("QuestieDB"), Questie("QuestiePlayer")
    if not (db and db.QueryQuestSingle and type(id) == "number" and id > 0 and IsKnown(db, id)) then return end
    local rxp = _G.RXP
    local guide = type(rxp) == "table" and rxp.currentGuide
    local covered = type(guide) == "table" and guide.steps and GuideQuests(rxp, guide, player) or {}
    local info = QuestInfo(db, player, covered, id)
    info.before = {}
    for i, pre in ipairs(Chain(db, player, covered, id)) do
        info.before[i] = QuestValue(db, pre, "name") or ("Quest " .. pre)
    end
    return info
end

--------------------------------------------------------------------------------------------------
-- Window

local frame, listRows, chainRows = nil, {}, {}
local data, selected
local focusQuest    -- a quest to select at the next refresh (ns.ShowPrereqsFor)

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
    if row.Objective.SetMaxLines then row.Objective:SetMaxLines(3) end
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

local function ShowDetail()
    local detail = frame.Detail
    for _, row in ipairs(chainRows) do row:Hide() end
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
        intro = ("The guide works on or hands in this quest in step %d, but you do not have it, and this guide does not pick it up."):format(entry.step)
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
        row.Objective:SetText(objective and ("Objective: " .. objective) or "")
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
    row.Meta:SetPoint("RIGHT", -8, 0)
    row.Meta:SetJustifyH("LEFT")
    row.Meta:SetWordWrap(false)
    row.Meta:SetTextColor(0.78, 0.74, 0.66)
    row:SetScript("OnClick", ListRow_OnClick)
    row:SetScript("OnEnter", ListRow_OnEnter)
    row:SetScript("OnLeave", ListRow_OnLeave)
    return row
end

local function Refresh()
    if not frame or not frame:IsShown() then return end
    local reason, rxp = nil, _G.RXP
    frame.shownGuide = type(rxp) == "table" and rxp.currentGuide or nil
    data, reason = ns.PrereqData(rxp)
    frame.reason = reason
    frame.Guide:SetText(data and data.guide or "")
    local quests = data and data.quests or {}
    local display = {}
    for _, entry in ipairs(quests) do display[#display + 1] = {kind = "quest", entry = entry} end
    for _, entry in ipairs(data and data.unknown or {}) do display[#display + 1] = {kind = "unknown", entry = entry} end
    if data then data.display = display end
    if focusQuest then
        -- The entry for that quest, or the one whose chain has it.
        for index, item in ipairs(display) do
            local found = item.entry.id == focusQuest
            for _, info in ipairs(item.entry.chain or {}) do found = found or info.id == focusQuest end
            if found then
                selected = index
                break
            end
        end
        focusQuest = nil
    end
    if not display[selected] then selected = display[1] and 1 or nil end
    local count = data and (#quests == 1 and "1 quest you cannot pick up" or (#quests .. " quests you cannot pick up")) or ""
    if data and #data.unknown > 0 then count = count .. (", %d unknown"):format(#data.unknown) end
    frame.Count:SetText(count)
    for i, item in ipairs(display) do
        local entry = item.entry
        local row = listRows[i]
        if not row then
            row = CreateListRow(frame.List.Content)
            listRows[i] = row
        end
        row.index = i
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -(i - 1) * (ROW_HEIGHT + ROW_GAP))
        row:SetPoint("RIGHT", frame.List.Content, "RIGHT", 0, 0)
        local meta, xp
        row.Name:SetText(entry.name)
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
                meta = meta .. "  -  not picked up"
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
    frame.List.Content:SetHeight(math.max(#display * (ROW_HEIGHT + ROW_GAP), 1))
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
    focusQuest = id
    if frame:IsShown() then Refresh() else frame:Show() end
    focusQuest = nil
    if selected then
        local scroll = frame.List
        local range = scroll:GetVerticalScrollRange() or 0
        scroll:SetVerticalScroll(math.max(0, math.min(range, (selected - 1) * (ROW_HEIGHT + ROW_GAP))))
    end
end
