local addonName, ns = ...

-- Route planner for Missing Prerequisites: one trip through the chains of the quests ticked in its list. Every
-- chain quest becomes up to three stops (pick up, objective, hand in) that keep their order and wait for the
-- quests before them; the stops are then ordered for the shortest trip from where the player stands.
-- Travel times are estimates: on foot in a straight line inside a zone and through the passes of ns.ZONE_LINKS
-- between zones (no walls or mountains known otherwise), by flight between the flight points the character
-- knows, with RestedXP's flight times, and by the ships, zeppelins and the tram of
-- ns.TRANSPORTS. A mage's teleports count from anywhere, and the hearthstone once, on the way it saves most.

local RUN_SPEED = 7             -- yards per second on foot
local MOUNT_FACTOR = 1.6        -- from MOUNT_LEVEL on
local MOUNT_LEVEL = 40
local DETOUR = 1.25             -- a walk is longer than its straight line
local FLIGHT_SPEED = 30         -- yards per second, for flights RestedXP has no time for
local FLIGHT_OVERHEAD = 20      -- seconds at the flight master
local NEAR_NODES = 3            -- flight points tried at each end of a leg
local CROSSING = 1800           -- stands in for a change of continent no transport is known for
local MAX_IMPROVE = 80          -- more stops than this keep the first order
local IMPROVE_WORTH = 10        -- seconds a change of the order has to save
local NO_PATH = 4               -- a walk between zones that no pass joins counts this many times its straight line
-- A ship, zeppelin or tram, waiting included: one minute when it is caught just right, five when it was just
-- missed. The trip is planned with the middle of the two.
local TRANSPORT_BEST, TRANSPORT_WORST = 60, 300
local TRANSPORT_SECONDS = (TRANSPORT_BEST + TRANSPORT_WORST) / 2
ns.TRANSPORT_BEST, ns.TRANSPORT_WORST = TRANSPORT_BEST, TRANSPORT_WORST
local TELEPORT_SECONDS = 25     -- a teleport or the hearthstone: the cast and the loading screen
local HEARTH_WORTH = 60         -- the hearthstone is only used where it saves more than this
local HEARTH_READY = 60         -- and only when its cooldown is no longer than this

--------------------------------------------------------------------------------------------------
-- Which quests of the list go on the trip: kept per character.

local function CharacterKey()
    return (UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
end

local function Selection(create)
    local db = ns.db or RXPBlizzStyleDB
    if type(db) ~= "table" then return end
    local all = db.routeQuests
    if type(all) ~= "table" then
        if not create then return end
        all = {}
        db.routeQuests = all
    end
    local key = CharacterKey()
    if type(all[key]) ~= "table" and create then all[key] = {} end
    return all[key]
end

function ns.RouteSelected(id)
    local chosen = Selection(false)
    return chosen and chosen[id] and true or false
end

function ns.SetRouteSelected(id, on)
    local chosen = Selection(true)
    if chosen then chosen[id] = on and true or nil end
end

--------------------------------------------------------------------------------------------------
-- Travel

-- A number the game hands out freely, or nil: in a fight some values come as secrets, which cannot be compared
-- or calculated with.
local function PlainNumber(value)
    if issecretvalue and issecretvalue(value) then return end
    if type(value) == "number" then return value end
end

local function Distance(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
end

-- Where one zone is left for the next on foot: {zone, neighbour, x, y}, the spot on the first zone's map (0-100).
-- Zones are uiMapIds. From memory of the classic world, so a pass may be off by a few hundred yards: enough to
-- know which zones join at all and roughly where. Zones that are not here (the ones new in Forever) are walked
-- in a straight line.
ns.ZONE_LINKS = {
    -- Kalimdor
    {1411, 1454, 45.5, 12.0},   -- Durotar - Orgrimmar
    {1411, 1413, 34.5, 42.5},   -- Durotar - The Barrens
    {1412, 1456, 37.5, 32.0},   -- Mulgore - Thunder Bluff
    {1412, 1413, 69.0, 60.5},   -- Mulgore - The Barrens
    {1413, 1440, 48.8, 7.0},    -- The Barrens - Ashenvale
    {1413, 1442, 35.0, 27.5},   -- The Barrens - Stonetalon Mountains
    {1413, 1445, 50.0, 78.5},   -- The Barrens - Dustwallow Marsh
    {1413, 1441, 44.5, 91.0},   -- The Barrens - Thousand Needles (the Great Lift)
    {1441, 1444, 8.5, 18.5},    -- Thousand Needles - Feralas
    {1441, 1446, 75.5, 97.0},   -- Thousand Needles - Tanaris
    {1446, 1449, 27.0, 56.0},   -- Tanaris - Un'Goro Crater
    {1449, 1451, 29.0, 22.0},   -- Un'Goro Crater - Silithus
    {1444, 1443, 44.5, 6.5},    -- Feralas - Desolace
    {1443, 1442, 53.0, 4.5},    -- Desolace - Stonetalon Mountains
    {1442, 1440, 78.0, 43.0},   -- Stonetalon Mountains - Ashenvale (Talondeep Path)
    {1440, 1439, 27.5, 14.0},   -- Ashenvale - Darkshore
    {1440, 1448, 55.5, 29.0},   -- Ashenvale - Felwood
    {1440, 1447, 94.5, 47.5},   -- Ashenvale - Azshara
    {1448, 1452, 65.0, 8.5},    -- Felwood - Winterspring (Timbermaw Hold)
    {1448, 1450, 64.5, 6.5},    -- Felwood - Moonglade (Timbermaw Hold)
    {1438, 1457, 36.5, 54.0},   -- Teldrassil - Darnassus
    -- Eastern Kingdoms
    {1429, 1453, 32.0, 49.5},   -- Elwynn Forest - Stormwind City
    {1429, 1436, 22.5, 73.0},   -- Elwynn Forest - Westfall
    {1429, 1431, 62.0, 86.0},   -- Elwynn Forest - Duskwood
    {1429, 1433, 91.5, 72.0},   -- Elwynn Forest - Redridge Mountains
    {1436, 1431, 66.5, 60.5},   -- Westfall - Duskwood
    {1433, 1431, 9.5, 79.0},    -- Redridge Mountains - Duskwood
    {1433, 1428, 30.0, 9.5},    -- Redridge Mountains - Burning Steppes
    {1431, 1434, 44.5, 88.0},   -- Duskwood - Stranglethorn Vale
    {1431, 1430, 88.5, 40.5},   -- Duskwood - Deadwind Pass
    {1430, 1435, 60.0, 42.0},   -- Deadwind Pass - Swamp of Sorrows
    {1435, 1419, 33.5, 73.0},   -- Swamp of Sorrows - Blasted Lands
    {1428, 1427, 30.0, 37.0},   -- Burning Steppes - Searing Gorge (Blackrock Mountain)
    {1427, 1418, 79.0, 76.0},   -- Searing Gorge - Badlands
    {1418, 1432, 51.0, 15.0},   -- Badlands - Loch Modan
    {1426, 1455, 53.0, 35.0},   -- Dun Morogh - Ironforge
    {1426, 1432, 86.5, 51.0},   -- Dun Morogh - Loch Modan (South Gate Pass)
    {1432, 1437, 25.5, 10.5},   -- Loch Modan - Wetlands (Dun Algaz)
    {1437, 1417, 51.5, 10.0},   -- Wetlands - Arathi Highlands (Thandol Span)
    {1417, 1424, 19.5, 29.5},   -- Arathi Highlands - Hillsbrad Foothills
    {1424, 1425, 86.0, 30.5},   -- Hillsbrad Foothills - The Hinterlands
    {1424, 1416, 54.5, 19.0},   -- Hillsbrad Foothills - Alterac Mountains
    {1424, 1421, 13.5, 46.0},   -- Hillsbrad Foothills - Silverpine Forest
    {1416, 1422, 80.5, 33.0},   -- Alterac Mountains - Western Plaguelands
    {1421, 1420, 67.0, 5.0},    -- Silverpine Forest - Tirisfal Glades
    {1420, 1458, 61.8, 65.0},   -- Tirisfal Glades - Undercity
    {1420, 1422, 83.5, 70.0},   -- Tirisfal Glades - Western Plaguelands (the Bulwark)
    {1422, 1423, 69.5, 50.0},   -- Western Plaguelands - Eastern Plaguelands
}

-- The zones of ns.ZONE_LINKS as a network: where each zone's map lies in the world (rects, for telling which
-- zone a spot is in), the passes (gates) and the shortest walk between every two passes (dist, in yards).
local function ZoneGraph(env)
    if env.zoneGraph then return env.zoneGraph end
    local graph = {rects = {}, gates = {}, byZone = {}, dist = {}}
    env.zoneGraph = graph
    local function rect(zone)
        if graph.rects[zone] ~= nil then return graph.rects[zone] end
        local corner, opposite = env.point and env.point(zone, 0, 0), env.point and env.point(zone, 100, 100)
        local found = false
        if corner and opposite and corner.instance == opposite.instance and corner.x ~= opposite.x and corner.y ~= opposite.y then
            -- In the game the world's x runs along the map's y: seen from a third corner.
            local across = env.point(zone, 100, 0)
            found = {x0 = corner.x, y0 = corner.y, x1 = opposite.x, y1 = opposite.y, instance = corner.instance,
                name = env.mapName and env.mapName(zone) or nil,
                turned = across ~= nil and math.abs(across.x - corner.x) < math.abs(across.y - corner.y)}
        end
        graph.rects[zone] = found
        return found
    end
    for _, link in ipairs(ns.ZONE_LINKS) do
        local point = rect(link[1]) and rect(link[2]) and env.point(link[1], link[3], link[4])
        if point then
            local index = #graph.gates + 1
            graph.gates[index] = {point = point, zones = {link[1], link[2]}}
            for _, zone in ipairs(graph.gates[index].zones) do
                graph.byZone[zone] = graph.byZone[zone] or {}
                table.insert(graph.byZone[zone], index)
            end
        end
    end
    for zone, found in pairs(graph.rects) do
        if not found then graph.rects[zone] = nil end
    end
    local count = #graph.gates
    for i = 1, count do
        graph.dist[i] = {}
        for j = 1, count do
            local a, b = graph.gates[i], graph.gates[j]
            local shared = a.zones[1] == b.zones[1] or a.zones[1] == b.zones[2] or a.zones[2] == b.zones[1] or a.zones[2] == b.zones[2]
            graph.dist[i][j] = i == j and 0 or (shared and a.point.instance == b.point.instance and Distance(a.point, b.point)) or math.huge
        end
    end
    for k = 1, count do
        for i = 1, count do
            local viaK = graph.dist[i][k]
            if viaK < math.huge then
                for j = 1, count do
                    if viaK + graph.dist[k][j] < graph.dist[i][j] then graph.dist[i][j] = viaK + graph.dist[k][j] end
                end
            end
        end
    end
    return graph
end

-- The zone of the network a spot of the world lies in; `name` ("Gadgetzan, Tanaris") settles it where the maps
-- of two zones overlap. nil for a spot outside all of them.
local function ZoneAt(env, point, name)
    local graph = ZoneGraph(env)
    local town, region
    if type(name) == "string" then
        town, region = name:match("^%s*([^,]+)%s*,%s*(.-)%s*$")
        town = (town or name):lower()
        region = region and region ~= "" and region:lower() or nil
    end
    local best, bestScore
    for zone, rect in pairs(graph.rects) do
        if rect.instance == point.instance then
            local fx, fy = (point.x - rect.x0) / (rect.x1 - rect.x0), (point.y - rect.y0) / (rect.y1 - rect.y0)
            if fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 then
                -- How far inside the map the spot is, and whether the map's name fits the spot's.
                local score = math.min(fx, 1 - fx, fy, 1 - fy)
                local mapName = rect.name and rect.name:lower()
                if mapName and town and mapName:find(town, 1, true) then
                    score = score + 2
                elseif mapName and region and mapName:find(region, 1, true) then
                    score = score + 1
                end
                if not bestScore or score > bestScore then best, bestScore = zone, score end
            end
        end
    end
    return best
end

-- A spot of the world on its zone's map: {uiMapId, x, y} (0-100), as a guide's .goto takes it; nil outside the
-- zones of the network.
local function MapSpot(env, point, name)
    local zone = point.zone or ZoneAt(env, point, name)
    local rect = zone and ZoneGraph(env).rects[zone]
    if not rect or rect.instance ~= point.instance then return end
    local fx, fy = (point.x - rect.x0) / (rect.x1 - rect.x0), (point.y - rect.y0) / (rect.y1 - rect.y0)
    if rect.turned then fx, fy = fy, fx end
    if fx < 0 or fx > 1 or fy < 0 or fy > 1 then return end
    return {zone, fx * 100, fy * 100}
end

ns.RouteMapSpot = MapSpot

-- The map itself or the nearest map above it that the network knows.
local function KnownZone(env, mapId)
    local graph = ZoneGraph(env)
    for _ = 1, 4 do
        if not mapId then return end
        if graph.rects[mapId] then return mapId end
        local ok, info = pcall(function() return C_Map.GetMapInfo(mapId) end)
        mapId = ok and type(info) == "table" and info.parentMapID or nil
    end
end

-- Yards on foot from a to b (points with .zone): straight inside a zone, through the passes between zones the
-- network joins, NO_PATH times the straight line between zones it does not join.
local function WalkYards(env, a, b)
    local straight = Distance(a, b)
    local from, to = a.zone, b.zone
    if not from or not to or from == to then return straight end
    local graph = ZoneGraph(env)
    local leaving, entering = graph.byZone[from], graph.byZone[to]
    if not leaving or not entering then return straight end     -- a zone the network does not know
    local best = math.huge
    for _, i in ipairs(leaving) do
        local first = Distance(a, graph.gates[i].point)
        if first < best then
            for _, j in ipairs(entering) do
                local total = first + graph.dist[i][j] + Distance(graph.gates[j].point, b)
                if total < best then best = total end
            end
        end
    end
    if best == math.huge then return straight * NO_PATH end
    return math.max(best, straight)
end

local function Walk(env, a, b)
    return WalkYards(env, a, b) * DETOUR / env.speed
end

-- The flight points nearest to a point on foot, on its continent.
local function NearNodes(env, point)
    local list = {}
    for _, node in ipairs(env.nodes or {}) do
        if node.instance == point.instance then
            if node.zone == nil then node.zone = ZoneAt(env, node, node.name) or false end
            list[#list + 1] = {node = node, distance = WalkYards(env, point, node)}
        end
    end
    table.sort(list, function(a, b) return a.distance < b.distance end)
    for i = #list, NEAR_NODES + 1, -1 do list[i] = nil end
    return list
end

local function FlightTime(env, from, to)
    local seconds = env.flightTime and env.flightTime(from.id, to.id)
    if type(seconds) == "number" and seconds > 0 then return seconds end
    return Distance(from, to) / FLIGHT_SPEED
end

-- On one continent, on foot or by flight: seconds, and how: {mode = "walk"} or {mode = "fly", from = node,
-- to = node, before = seconds on foot to the flight master, flight = seconds, after = seconds on foot}.
local WALK = {mode = "walk"}
local function Local(env, a, b)
    local best, how = Walk(env, a, b), WALK
    local nearA, nearB = a.near, b.near
    if not nearA then
        nearA = NearNodes(env, a)
        a.near = nearA
    end
    if not nearB then
        nearB = NearNodes(env, b)
        b.near = nearB
    end
    for _, from in ipairs(nearA) do
        for _, to in ipairs(nearB) do
            if from.node ~= to.node then
                local before, after = from.distance * DETOUR / env.speed, to.distance * DETOUR / env.speed
                local flight = FLIGHT_OVERHEAD + FlightTime(env, from.node, to.node)
                if before + flight + after < best then
                    best = before + flight + after
                    how = {mode = "fly", from = from.node, to = to.node, before = before, flight = flight, after = after}
                end
            end
        end
    end
    return best, how
end

-- The transports as a network: the ends of all of them (env.links[...].a / .b), and between every two ends the
-- shortest time (dist), the end to go to next on that way (hop) and whether that step is the ride itself (ride).
local function Network(env)
    if env.network then return env.network end
    local ends = {}
    for _, link in ipairs(env.links or {}) do
        link.a.link, link.b.link, link.a.other, link.b.other = link, link, link.b, link.a
        ends[#ends + 1] = link.a
        ends[#ends + 1] = link.b
    end
    local count = #ends
    local dist, hop, ride = {}, {}, {}
    for i = 1, count do
        dist[i], hop[i], ride[i] = {}, {}, {}
        for j = 1, count do
            local seconds = math.huge
            if i == j then
                seconds = 0
            else
                if ends[i].instance == ends[j].instance then seconds = Local(env, ends[i], ends[j]) end
                -- The ride itself, in the direction the transport goes.
                local link = ends[i].link
                if ends[i].other == ends[j] and (not link.oneWay or ends[i] == link.a) and link.seconds < seconds then
                    seconds = link.seconds
                    ride[i][j] = true
                end
                if seconds < math.huge then hop[i][j] = j end
            end
            dist[i][j] = seconds
        end
    end
    for k = 1, count do
        for i = 1, count do
            local viaK = dist[i][k]
            if viaK < math.huge then
                for j = 1, count do
                    if viaK + dist[k][j] < dist[i][j] then
                        dist[i][j] = viaK + dist[k][j]
                        hop[i][j] = hop[i][k]
                    end
                end
            end
        end
    end
    env.network = {ends = ends, dist = dist, hop = hop, ride = ride}
    return env.network
end

-- From a point to every transport end on its continent: {[index of the end] = seconds}.
local function EndTimes(env, network, point)
    local times = point.toEnds
    if times then return times end
    times = {}
    for index, stop in ipairs(network.ends) do
        if stop.instance == point.instance then times[index] = Local(env, point, stop) end
    end
    point.toEnds = times
    return times
end

-- The fastest way from a to b without a spell: seconds, and the transport ends it boards and leaves at (nil:
-- without transport). Without any way (another continent no transport goes to): CROSSING, nil, nil, true.
local function Ground(env, a, b)
    local best, first, last = math.huge, nil, nil
    if a.instance == b.instance then best = Local(env, a, b) end
    local network = Network(env)
    if #network.ends > 0 then
        local fromA, toB = EndTimes(env, network, a), EndTimes(env, network, b)
        for i, before in pairs(fromA) do
            if before < best then
                local row = network.dist[i]
                for j, after in pairs(toB) do
                    local total = before + row[j] + after
                    if i ~= j and total < best then best, first, last = total, i, j end
                end
            end
        end
    end
    if best == math.huge then return CROSSING, nil, nil, true end
    return best, first, last
end

-- The fastest way from a to b, a teleport of env.teleports ({{name, point, seconds}, ...}, usable from anywhere)
-- first where that is faster: as Ground, and the index of that teleport.
local function Best(env, a, b)
    local best, first, last, cross = Ground(env, a, b)
    local teleport
    for index, spell in ipairs(env.teleports or {}) do
        local onward = b.fromTeleport and b.fromTeleport[index]
        if onward == nil then
            local seconds, _, _, none = Ground(env, spell.point, b)
            onward = not none and seconds
            b.fromTeleport = b.fromTeleport or {}
            b.fromTeleport[index] = onward
        end
        if onward and spell.seconds + onward < best then
            best, first, last, cross, teleport = spell.seconds + onward, nil, nil, nil, index
        end
    end
    return best, first, last, cross, teleport
end

local function AddLocal(env, parts, a, b)
    local seconds, how = Local(env, a, b)
    if how.mode == "fly" then
        if how.before >= 1 then parts[#parts + 1] = {mode = "walk", seconds = how.before} end
        parts[#parts + 1] = {mode = "fly", seconds = how.flight, from = how.from.name, to = how.to.name,
            at = MapSpot(env, how.from, how.from.name)}
        if how.after >= 1 then parts[#parts + 1] = {mode = "walk", seconds = how.after} end
    elseif seconds >= 1 then
        parts[#parts + 1] = {mode = "walk", seconds = seconds}
    end
end

-- The way from a to b on the ground, added to parts; true when no way is known.
local function AddGround(env, parts, a, b)
    local _, first, last, cross = Ground(env, a, b)
    if cross then return true end
    if not first then return AddLocal(env, parts, a, b) end
    local network = Network(env)
    AddLocal(env, parts, a, network.ends[first])
    local at = first
    while at ~= last do
        local nextEnd = network.hop[at][last]
        if not nextEnd then break end
        if network.ride[at][nextEnd] then
            local link = network.ends[at].link
            parts[#parts + 1] = {mode = "ride", seconds = link.seconds, name = link.name, kind = link.kind,
                from = network.ends[at].at, to = network.ends[nextEnd].at}
        else
            AddLocal(env, parts, network.ends[at], network.ends[nextEnd])
        end
        at = nextEnd
    end
    AddLocal(env, parts, network.ends[last], b)
end

-- The way from a to b in full: {seconds = all of it, cross = true when no way is known, parts = {{mode = "walk",
-- seconds} / {mode = "fly", seconds, from, to} / {mode = "ride", seconds, name, kind} / {mode = "teleport",
-- seconds, name} / {mode = "hearth", seconds, name}, ...}}.
local function Travel(env, a, b)
    local seconds, _, _, cross, teleport = Best(env, a, b)
    local leg = {seconds = seconds, cross = cross, parts = {}}
    if teleport then
        local spell = env.teleports[teleport]
        leg.parts[1] = {mode = "teleport", seconds = spell.seconds, name = spell.name, at = spell.at}
        AddGround(env, leg.parts, spell.point, b)
    elseif not cross then
        AddGround(env, leg.parts, a, b)
    end
    return leg
end

--------------------------------------------------------------------------------------------------
-- Stops

-- One spot standing for all the places of an objective: the spot nearest to their middle, on the map with the
-- most of them.
local function ObjectiveSpot(info)
    local places = info.objectivePlaces
    if type(places) ~= "table" then return end
    local mapId, list
    for id, spots in pairs(places) do
        if type(spots) == "table" and #spots > 0 and (not list or #spots > #list or (#spots == #list and id < mapId)) then
            mapId, list = id, spots
        end
    end
    if not list then return end
    local sumX, sumY = 0, 0
    for _, spot in ipairs(list) do sumX, sumY = sumX + spot.x, sumY + spot.y end
    local midX, midY = sumX / #list, sumY / #list
    local best, bestDistance
    for _, spot in ipairs(list) do
        local distance = (spot.x - midX) ^ 2 + (spot.y - midY) ^ 2
        if not bestDistance or distance < bestDistance then best, bestDistance = spot, distance end
    end
    return mapId, best.x, best.y
end

-- The stops of the chosen entries: {key, kind = "pickup" / "item" / "objective" / "turnin", info, who, mapId, x, y,
-- after = {stops that come first}, entry = the guide's quest it is for}.
local function BuildStops(entries, env)
    local infos, full, entryOf, order = {}, {}, {}, {}
    for _, entry in ipairs(entries) do
        for _, info in ipairs(entry.chain or {}) do
            if not infos[info.id] then
                infos[info.id] = info
                entryOf[info.id] = entry
                order[#order + 1] = info.id
            end
            -- The guide's own quest is only picked up: the guide goes on with it. Quests before it are done whole.
            if not (entry.kind == "handin" and info.id == entry.id) then full[info.id] = true end
        end
    end
    local stops, first, last = {}, {}, {}
    local function add(info, kind, who, mapId, x, y, after)
        local stop = {key = kind .. ":" .. info.id, kind = kind, info = info, who = who, mapId = mapId, x = x, y = y,
            after = {after}, entry = entryOf[info.id]}
        if mapId and x and y and env.point then stop.point = env.point(mapId, x, y) end
        stops[#stops + 1] = stop
        first[info.id] = first[info.id] or stop
        last[info.id] = stop
        return stop
    end
    for _, id in ipairs(order) do
        local info = infos[id]
        local previous
        if info.status == "item" then
            previous = add(info, "item", info.startItem)
        elseif info.status ~= "log" then
            previous = add(info, "pickup", info.starter, info.mapId, info.x, info.y)
        end
        if full[id] then
            local complete = info.status == "log" and env.isComplete and env.isComplete(id)
            local mapId, x, y = ObjectiveSpot(info)
            if mapId and not complete and not info.objectiveGiven then
                previous = add(info, "objective", info.objectiveNames and info.objectiveNames[1], mapId, x, y, previous)
            end
            add(info, "turnin", info.ender, info.endMapId, info.endX, info.endY, previous)
        end
    end
    -- A quest waits for the quests before it to be handed in.
    for _, id in ipairs(order) do
        local stop = first[id]
        for _, need in ipairs(infos[id].needs or {}) do
            if stop and last[need] and full[need] then stop.after[#stop.after + 1] = last[need] end
        end
    end
    -- Where the trip ends (env.finish = {name, mapId, x, y}): after everything else.
    local finish = env.finish
    if type(finish) == "table" and finish.mapId and finish.x and finish.y then
        local stop = {key = "finish", kind = "finish", info = {id = 0, name = finish.name or "the end"},
            mapId = finish.mapId, x = finish.x, y = finish.y, after = {}}
        for i, other in ipairs(stops) do stop.after[i] = other end
        if env.point then stop.point = env.point(finish.mapId, finish.x, finish.y) end
        stops[#stops + 1] = stop
    end
    return stops
end

--------------------------------------------------------------------------------------------------
-- Order

local function Planner(env, stops)
    local memo = {}
    local start = env.start
    local function seconds(a, b)
        -- a, b: stops with a point, or nil / the start
        local from = a and a.point or (a == nil and start) or nil
        if not from or not b.point then return 0 end
        local key = (a and a.key or "start") .. ">" .. b.key
        local value = memo[key]
        if not value then
            value = Best(env, from, b.point)
            memo[key] = value
        end
        return value
    end
    -- To a stop by hearthstone (env.hearth = {name, point, seconds}) and on from there.
    local hearth = env.hearth
    local function byHearth(stop)
        local key = "hearth>" .. stop.key
        local value = memo[key]
        if not value then
            value = hearth.seconds + Best(env, hearth.point, stop.point)
            memo[key] = value
        end
        return value
    end
    -- The length of an order: stops without a known place are done on the way and move nobody. The hearthstone
    -- is used once, on the way it shortens most.
    local function length(sequence)
        local total, at, saved = 0, nil, 0
        for _, stop in ipairs(sequence) do
            if stop.point then
                local way = seconds(at, stop)
                total = total + way
                if hearth and (at or start) and way - byHearth(stop) > saved then saved = way - byHearth(stop) end
                at = stop
            end
        end
        return total - saved
    end
    return seconds, length
end

local function Greedy(stops, seconds)
    local sequence, done, at = {}, {}, nil
    while #sequence < #stops do
        local pick, pickCost
        for _, stop in ipairs(stops) do
            if not done[stop] then
                local free = true
                for _, before in ipairs(stop.after) do free = free and done[before] end
                if free then
                    local cost = stop.point and seconds(at, stop) or -1
                    if not pickCost or cost < pickCost then pick, pickCost = stop, cost end
                end
            end
        end
        if not pick then break end     -- a circle in the prerequisites: leave the rest out
        done[pick] = true
        sequence[#sequence + 1] = pick
        if pick.point then at = pick end
    end
    return sequence
end

-- Moves single stops to a better place in the order while that keeps every stop after the ones it waits for and
-- saves more than IMPROVE_WORTH seconds. The first `fixed` stops stay where they are.
local function Improve(sequence, length, fixed)
    if #sequence > MAX_IMPROVE then return sequence end
    local best = length(sequence)
    for _ = 1, 4 do
        local improved = false
        for i = fixed + 1, #sequence do
            local stop = sequence[i]
            local index = {}
            for position, other in ipairs(sequence) do index[other] = position end
            local low, high = fixed + 1, #sequence
            for _, before in ipairs(stop.after) do low = math.max(low, (index[before] or 0) + 1) end
            for position, other in ipairs(sequence) do
                for _, before in ipairs(other.after) do
                    if before == stop then high = math.min(high, position - 1) end
                end
            end
            local bestAt
            for target = low, high do
                if target ~= i then
                    table.remove(sequence, i)
                    table.insert(sequence, target, stop)
                    local total = length(sequence)
                    if total < best - IMPROVE_WORTH then best, bestAt = total, target end
                    table.remove(sequence, target)
                    table.insert(sequence, i, stop)
                end
            end
            if bestAt then
                table.remove(sequence, i)
                table.insert(sequence, bestAt, stop)
                improved = true
            end
        end
        if not improved then break end
    end
    return sequence
end

-- The stops in the order of a list of their keys; nil when a stop is not in the list or would come before one it
-- waits for.
local function InOrder(stops, order)
    local byKey, sequence, placed = {}, {}, {}
    for _, stop in ipairs(stops) do byKey[stop.key] = stop end
    for _, key in ipairs(order) do
        local stop = byKey[key]
        if stop and not placed[stop] then
            for _, before in ipairs(stop.after) do
                if not placed[before] then return end
            end
            placed[stop] = true
            sequence[#sequence + 1] = stop
        end
    end
    if #sequence ~= #stops then return end
    return sequence
end

-- The trip for the chosen entries of ns.PrereqData: {stops = {stop, ...} in order, each with leg = the way to it
-- as Travel gives it (nil without a known place), seconds = the estimated travel time (ways nothing is known
-- for left out), rides = ships, zeppelins and trams taken, teleports = teleports cast, hearth = the place the
-- hearthstone is used to, crossings = ways to another continent nothing is known for, unplaced = stops without a
-- known place, xp = the experience of the handins quests handed in on the way, from = where it starts, notes =
-- what the game's side had to say (env.notes)}.
function ns.PlanRoute(entries, env)
    local stops = BuildStops(entries, env)
    local seconds, length = Planner(env, stops)
    local sequence
    if env.order then
        -- The stops in an order given (env.order = their keys): nil when that order no longer fits them.
        sequence = InOrder(stops, env.order)
        if not sequence then return end
    else
        sequence = Greedy(stops, seconds)
        -- The next stop is always the one that can be done now and is nearest in travel time from where the
        -- player is: the order after it is what gets improved. (Stops without a place before it cost no way.)
        local fixed = 0
        if env.start then
            for index, stop in ipairs(sequence) do
                fixed = index
                if stop.point then break end
            end
        end
        sequence = Improve(sequence, length, fixed)
    end
    local route = {stops = sequence, seconds = 0, rides = 0, teleports = 0, crossings = 0, unplaced = 0,
        xp = 0, handins = 0, from = env.start, notes = env.notes or {}, order = {}}
    for index, stop in ipairs(sequence) do route.order[index] = stop.key end
    local at = env.start
    local hearthStop, hearthFrom, hearthSaves
    for _, stop in ipairs(sequence) do
        if stop.point then
            if at then
                stop.leg = Travel(env, at, stop.point)
                local hearth = env.hearth
                if hearth then
                    local saves = stop.leg.seconds - (hearth.seconds + Best(env, hearth.point, stop.point))
                    if saves > HEARTH_WORTH and (not hearthSaves or saves > hearthSaves) then
                        hearthStop, hearthFrom, hearthSaves = stop, at, saves
                    end
                end
            end
            at = stop.point
        else
            route.unplaced = route.unplaced + 1
        end
    end
    if hearthStop then
        local hearth = env.hearth
        local onward = Travel(env, hearth.point, hearthStop.point)
        local leg = {seconds = hearth.seconds + onward.seconds, cross = onward.cross,
            parts = {{mode = "hearth", seconds = hearth.seconds, name = hearth.name}}}
        for _, part in ipairs(onward.parts) do leg.parts[#leg.parts + 1] = part end
        hearthStop.leg = leg
        route.hearth = hearth.name
    end
    for _, stop in ipairs(sequence) do
        if stop.kind == "turnin" then
            route.handins = route.handins + 1
            route.xp = route.xp + (stop.info.xp or 0)
        end
        local leg = stop.leg
        if leg then
            if leg.cross then route.crossings = route.crossings + 1 else route.seconds = route.seconds + leg.seconds end
            for _, part in ipairs(leg.parts) do
                if part.mode == "ride" then route.rides = route.rides + 1 end
                if part.mode == "teleport" then route.teleports = route.teleports + 1 end
            end
        end
    end
    return route
end

--------------------------------------------------------------------------------------------------
-- Ships, zeppelins, skycutters and the tram: both ends as {uiMapId, x, y} (0-100 on that zone's map), the faction
-- that can use it (nil: both), oneWay for a ride that only goes from a to b, and seconds where the ride is not
-- counted with the usual time.
-- The classic routes and their docks are Classic Era data (HandyNotes TravelGuide), reported as unchanged in
-- Forever. The routes new in Forever are from Blizzard's announcement and fan guides (November 2026); where no
-- dock position was published, the end is the town ("about"), close enough for an estimate of the way there.

local TRAM_SECONDS = 95         -- a minute's ride and half a tram's interval
local LOOP_EXTRA = 150          -- staying aboard for one more leg of a loop: that leg's ride and its stop

local MENETHIL_NORTH, MENETHIL_SOUTH = {1437, 4.63, 57.10}, {1437, 5.02, 63.48}
local AUBERDINE_SOUTH, AUBERDINE_NORTH = {1439, 32.40, 43.80}, {1439, 33.19, 40.06}
local SOUTHSHORE = {1424, 51.0, 60.5}           -- about: no dock position published
local STORMWIND_HARBOR = {1453, 22.5, 56.0}     -- about: "the southernmost dock", no position published

ns.TRANSPORTS = {
    {name = "Menethil Harbor - Theramore", kind = "ship", faction = "Alliance", a = MENETHIL_SOUTH, b = {1445, 71.62, 56.48}},
    {name = "Auberdine - Rut'theran Village", kind = "ship", faction = "Alliance", a = AUBERDINE_NORTH, b = {1438, 54.85, 96.80}},
    {name = "Booty Bay - Ratchet", kind = "ship", a = {1434, 25.86, 73.11}, b = {1413, 63.68, 38.62}},
    {name = "Orgrimmar - Undercity", kind = "zeppelin", faction = "Horde", a = {1411, 50.82, 13.85}, b = {1420, 60.69, 58.77}},
    {name = "Orgrimmar - Grom'gol", kind = "zeppelin", faction = "Horde", a = {1411, 50.57, 12.65}, b = {1434, 31.36, 30.15}},
    {name = "Undercity - Grom'gol", kind = "zeppelin", faction = "Horde", a = {1420, 61.88, 59.07}, b = {1434, 31.58, 29.11}},
    {name = "Deeprun Tram: Stormwind - Ironforge", kind = "tram", faction = "Alliance", seconds = TRAM_SECONDS,
        a = {1453, 63.91, 8.17}, b = {1455, 76.98, 51.53}},
    {name = "Feathermoon Stronghold - Forgotten Coast", kind = "ship", faction = "Alliance", a = {1444, 31.0, 39.9}, b = {1444, 43.3, 42.8}},
    -- New in Forever.
    {name = "Stormwind Harbor - Auberdine", kind = "ship", faction = "Alliance", a = STORMWIND_HARBOR, b = AUBERDINE_SOUTH},
    {name = "Steamwheedle Port - Powderfuse Port", kind = "ship", a = {1446, 68.6, 23.0}, b = {2548, 78.1, 51.9}},
    -- The skycutters of Valanaar on Zephras Isle. Who may ride which is told both ways; Dalaran attacks the Horde.
    {name = "Valanaar - Dalaran", kind = "skycutter", faction = "Alliance", a = {2521, 65.9, 83.5}, b = {1416, 12.5, 51.8}},
    {name = "Valanaar - Skywatcher Plateau", kind = "skycutter", faction = "Horde", a = {2521, 57.9, 80.9}, b = {1412, 34.3, 25.8}},
    -- The loop that took the place of the direct ship between Menethil Harbor and Auberdine: one ship, one way
    -- round, Menethil Harbor > Southshore > Auberdine > Menethil Harbor. Two legs of it are one ride without
    -- getting off.
    {name = "Menethil Harbor > Southshore", kind = "ship", faction = "Alliance", oneWay = true, a = MENETHIL_NORTH, b = SOUTHSHORE},
    {name = "Southshore > Auberdine", kind = "ship", faction = "Alliance", oneWay = true, a = SOUTHSHORE, b = AUBERDINE_SOUTH},
    {name = "Auberdine > Menethil Harbor", kind = "ship", faction = "Alliance", oneWay = true, a = AUBERDINE_SOUTH, b = MENETHIL_NORTH},
    {name = "Menethil Harbor > Auberdine (by Southshore)", kind = "ship", faction = "Alliance", oneWay = true,
        seconds = TRANSPORT_SECONDS + LOOP_EXTRA, a = MENETHIL_NORTH, b = AUBERDINE_SOUTH},
    {name = "Southshore > Menethil Harbor (by Auberdine)", kind = "ship", faction = "Alliance", oneWay = true,
        seconds = TRANSPORT_SECONDS + LOOP_EXTRA, a = SOUTHSHORE, b = MENETHIL_NORTH},
    {name = "Auberdine > Southshore (by Menethil Harbor)", kind = "ship", faction = "Alliance", oneWay = true,
        seconds = TRANSPORT_SECONDS + LOOP_EXTRA, a = AUBERDINE_SOUTH, b = SOUTHSHORE},
}

--------------------------------------------------------------------------------------------------
-- A mage's teleports: the spell, and where it sets the mage down ({uiMapId, x, y}, about).

local RUNE_OF_TELEPORTATION, HEARTHSTONE = 17031, 6948
local MAGE_TELEPORTS = {
    {spell = 3561, name = "Stormwind", at = {1453, 39.6, 79.6}},
    {spell = 3562, name = "Ironforge", at = {1455, 27.2, 7.0}},
    {spell = 3565, name = "Darnassus", at = {1457, 40.5, 81.8}},
    {spell = 3567, name = "Orgrimmar", at = {1454, 38.6, 85.7}},
    {spell = 3563, name = "Undercity", at = {1458, 84.6, 16.3}},
    {spell = 3566, name = "Thunder Bluff", at = {1456, 22.2, 16.9}},
}

-- How many of an item the player carries; 0 when the game does not say.
local function Carried(itemId)
    local count = C_Item and C_Item.GetItemCount or GetItemCount
    if not count then return 0 end
    local ok, have = pcall(function() return count(itemId) + 0 end)
    return ok and have or 0
end

local function Knows(spellId)
    local known = IsPlayerSpell or IsSpellKnown
    if not known then return false end
    local ok, yes = pcall(known, spellId)
    return ok and yes and true or false
end

-- Seconds until an item can be used again; nil when the game does not say.
local function CooldownLeft(itemId)
    local get = C_Container and C_Container.GetItemCooldown or GetItemCooldown
    if not get then return 0 end
    local ok, left = pcall(function()
        local start, duration = get(itemId)
        if not start or not duration or start == 0 or duration == 0 then return 0 end
        return math.max(0, start + duration - GetTime())
    end)
    return ok and left or nil
end

-- Where the hearthstone leads: the spot it was set at when this addon saw that (db.hearths), else the place of
-- that name on the maps.
local function HearthPlace()
    local name = GetBindLocation and GetBindLocation()
    if type(name) ~= "string" or name == "" then return end
    local db = ns.db or RXPBlizzStyleDB
    local saved = type(db) == "table" and type(db.hearths) == "table" and db.hearths[CharacterKey()]
    if type(saved) == "table" and saved.name == name and saved.x and saved.y and saved.instance then
        return name, {x = saved.x, y = saved.y, instance = saved.instance, map = saved.map}
    end
    return name, ns.FindPlace and ns.FindPlace(name) or nil
end

-- Setting the hearthstone: the player stands at the innkeeper, which is where it will lead.
if CreateFrame then
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("HEARTHSTONE_BOUND")
    watcher:SetScript("OnEvent", function()
        local db = ns.db or RXPBlizzStyleDB
        local name = GetBindLocation and GetBindLocation()
        local ok, x, y, _, instance = pcall(UnitPosition, "player")
        local secret = issecretvalue and (issecretvalue(x) or issecretvalue(y) or issecretvalue(instance))
        if type(db) ~= "table" or type(name) ~= "string" or not ok or secret or type(x) ~= "number" or not instance then return end
        db.hearths = type(db.hearths) == "table" and db.hearths or {}
        local found, map = pcall(function() return C_Map.GetBestMapForUnit("player") end)
        db.hearths[CharacterKey()] = {name = name, x = x, y = y, instance = instance, map = found and map or nil}
    end)
end

--------------------------------------------------------------------------------------------------
-- The game's side of it: where the player is, how fast, the flight points the character knows, the teleports a
-- mage has and where the hearthstone leads.

function ns.RouteEnvironment()
    local env = {speed = RUN_SPEED, nodes = {}, teleports = {}, notes = {}}
    if (PlainNumber(UnitLevel("player")) or 1) >= MOUNT_LEVEL then env.speed = RUN_SPEED * MOUNT_FACTOR end
    local ok, x, y, _, instance = pcall(UnitPosition, "player")
    local secret = issecretvalue and (issecretvalue(x) or issecretvalue(y) or issecretvalue(instance))
    if ok and not secret and type(x) == "number" and type(y) == "number" and instance then
        env.start = {x = x, y = y, instance = instance}
    end
    env.point = function(mapId, mapX, mapY)
        if not ns.WorldPoint then return end
        local wx, wy, where = ns.WorldPoint(mapId, mapX / 100, mapY / 100)
        if wx and where then return {x = wx, y = wy, instance = where, zone = mapId} end
    end
    env.mapName = function(mapId)
        local ok, info = pcall(function() return C_Map.GetMapInfo(mapId) end)
        return ok and type(info) == "table" and info.name or nil
    end
    if env.start then
        local ok2, here = pcall(function() return C_Map.GetBestMapForUnit("player") end)
        env.start.zone = ok2 and KnownZone(env, here) or nil
    end
    env.links = {}
    local side = UnitFactionGroup and UnitFactionGroup("player")
    for _, transport in ipairs(ns.TRANSPORTS) do
        if not transport.faction or transport.faction == side then
            local a = env.point(transport.a[1], transport.a[2], transport.a[3])
            local b = env.point(transport.b[1], transport.b[2], transport.b[3])
            if a and b then
                a.at, b.at = transport.a, transport.b
                env.links[#env.links + 1] = {name = transport.name, kind = transport.kind, a = a, b = b,
                    oneWay = transport.oneWay, seconds = transport.seconds or TRANSPORT_SECONDS}
            end
        end
    end
    env.isComplete = function(id)
        local ok2, complete = pcall(function() return C_QuestLog.IsComplete(id) and true or false end)
        return ok2 and complete
    end
    -- A mage's teleports, each needing a rune.
    local _, class = UnitClass("player")
    if class == "MAGE" then
        local spells = {}
        for _, teleport in ipairs(MAGE_TELEPORTS) do
            local point = Knows(teleport.spell) and env.point(teleport.at[1], teleport.at[2], teleport.at[3])
            if point then
                spells[#spells + 1] = {name = teleport.name, point = point, seconds = TELEPORT_SECONDS, at = teleport.at}
            end
        end
        env.runes = Carried(RUNE_OF_TELEPORTATION)
        if #spells > 0 and env.runes == 0 then
            env.notes[#env.notes + 1] = "No Rune of Teleportation: teleports left out"
        elseif #spells > 0 then
            env.teleports = spells
        end
    end
    -- The hearthstone, when it is ready and its place is known.
    if Carried(HEARTHSTONE) > 0 then
        local name, point = HearthPlace()
        local left = CooldownLeft(HEARTHSTONE)
        if not name then
            -- no place set: nothing to say
        elseif left and left > HEARTH_READY then
            env.notes[#env.notes + 1] = ("Hearthstone (%s): on cooldown, %d min"):format(name, math.ceil(left / 60))
        elseif not point then
            env.notes[#env.notes + 1] = ("Hearthstone (%s): place unknown, set it at an innkeeper again"):format(name)
        else
            point.zone = KnownZone(env, point.map) or ZoneAt(env, point, name)
            env.hearth = {name = name, point = point, seconds = TELEPORT_SECONDS}
        end
    end
    -- RestedXP: where the flight points are (taxiPos), how long the flights take (FPDB) and which ones the
    -- character has (RXPCData.flightPaths).
    local rxp = _G.RXP
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    local times = type(rxp) == "table" and type(rxp.FPDB) == "table" and rxp.FPDB[faction]
    local known = type(RXPCData) == "table" and RXPCData.flightPaths
    if type(rxp) == "table" and type(rxp.taxiPos) == "table" and type(times) == "table" and type(known) == "table" then
        for where, nodes in pairs(rxp.taxiPos) do
            for id, node in pairs(type(nodes) == "table" and nodes or {}) do
                if known[id] and type(node) == "table" and type(node.wx) == "number" and type(node.wy) == "number" then
                    local name = type(times[id]) == "table" and times[id].name or (type(known[id]) == "string" and known[id])
                    env.nodes[#env.nodes + 1] = {id = id, name = name or ("flight point " .. id), x = node.wx, y = node.wy, instance = where}
                end
            end
        end
        env.flightTime = function(from, to)
            local row = times[from]
            return type(row) == "table" and row[to] or nil
        end
    end
    return env
end

--------------------------------------------------------------------------------------------------
-- The route as a RestedXP guide of its own: its stops and the flights, rides, teleports and the hearthstone on
-- the way become steps, and RestedXP goes back to the guide it came from when the last one is done (#next).

local ROUTE_GROUP, ROUTE_NAME = "RestedXP Blizzard Style", "Prerequisites route"

-- Text for a guide line: no line breaks, and nothing RestedXP's parser reads as a comment or a tag.
local function Clean(text)
    return (tostring(text):gsub("[\r\n]+", " "):gsub("%-%-+", "-"):gsub(">>", ""):gsub("<<", ""))
end

-- "Booty Bay, Stranglethorn" is Booty Bay: what a .fly line takes, and no comma in it.
local function Town(name)
    return Clean(tostring(name):match("^%s*([^,]+)") or name)
end

-- The guide's text for a planned route; back = {group, name} of the guide to return to (nil: none); title = what
-- RestedXP shows as the guide's name (nil: its own name).
function ns.RouteGuideText(route, back, title)
    local lines = {"#forever", "#version 1", "#group " .. ROUTE_GROUP, "#name " .. ROUTE_NAME}
    if title and title ~= "" then lines[#lines + 1] = "#displayname " .. Clean(title) end
    if back and back.group and back.name then lines[#lines + 1] = ("#next %s\\%s"):format(back.group, back.name) end
    local function step(...)
        lines[#lines + 1] = "step"
        for i = 1, select("#", ...) do
            local line = select(i, ...)
            if line then lines[#lines + 1] = "    " .. line end
        end
    end
    local function spot(at, radius, text)
        return (".goto %d,%.2f,%.2f%s%s"):format(at[1], at[2], at[3], radius and ("," .. radius) or "", text and (" >> " .. text) or "")
    end
    for _, stop in ipairs(route.stops) do
        for _, part in ipairs(stop.leg and stop.leg.parts or {}) do
            if part.mode == "fly" then
                -- With the flight master's spot, so that the arrow leads there.
                step(part.at and spot(part.at) or nil, (".fly %s >> Fly to %s"):format(Town(part.to), Town(part.to)))
            elseif part.mode == "ride" then
                local what = part.kind .. " " .. Clean(part.name)
                if part.from then step(spot(part.from, 40, "Go to the " .. what)) end
                if part.to then step(spot(part.to, 80, "Take the " .. what)) end
            elseif part.mode == "teleport" then
                step((".zone %d >> Teleport to %s"):format(part.at[1], Clean(part.name)))
            elseif part.mode == "hearth" then
                step(".hs >> Hearth to " .. Clean(part.name))
            end
        end
        local info = stop.info
        local id, name = info.id, Clean(info.name)
        local place = stop.mapId and stop.x and stop.y and spot({stop.mapId, stop.x, stop.y}) or nil
        if stop.kind == "finish" then
            step(spot({stop.mapId, stop.x, stop.y}, 30, "Go to " .. name))
        elseif stop.kind == "pickup" then
            step(place, (".accept %d >> Accept %s"):format(id, name))
        elseif stop.kind == "item" then
            local item = Clean(info.startItem or "the item")
            if info.startItemId then
                step((".collect %d,1 >> Find %s, it starts %s"):format(info.startItemId, item, name))
                step((".use %d"):format(info.startItemId), (".accept %d >> Accept %s"):format(id, name))
            else
                step((">> Find %s, it starts %s"):format(item, name), (".accept %d >> Accept %s"):format(id, name))
            end
        elseif stop.kind == "objective" then
            local objectives = {place}
            for index = 1, math.max(info.objectiveCount or 1, 1) do
                objectives[#objectives + 1] = (".complete %d,%d"):format(id, index)
            end
            step(unpack(objectives))
        else
            step(place, (".turnin %d >> Turn in %s"):format(id, name))
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

function ns.IsRouteGuide(guide)
    return type(guide) == "table" and guide.group == ROUTE_GROUP and guide.name == ROUTE_NAME
end

local function SavedGuides(create)
    local db = ns.db or RXPBlizzStyleDB
    if type(db) ~= "table" then return end
    if type(db.routeGuides) ~= "table" then
        if not create then return end
        db.routeGuides = {}
    end
    return db.routeGuides
end

-- Hands a guide text to RestedXP; true when it took it.
local function Register(text)
    local rxpGuides = _G.RXPGuides
    if type(rxpGuides) ~= "table" or type(rxpGuides.RegisterGuide) ~= "function" then return false, "RestedXP takes no guides" end
    local ok, err = pcall(rxpGuides.RegisterGuide, text)
    if not ok then return false, tostring(err) end
    return true
end

-- The guide the route guide stands in for, with its steps: while the route guide is the current one, the missing
-- prerequisites are still those of the guide it leads back to. nil when the current guide is not the route guide.
local origin = {}
function ns.RouteOrigin(rxp)
    if type(rxp) ~= "table" or not ns.IsRouteGuide(rxp.currentGuide) then return end
    local saved = SavedGuides(false)
    local kept = saved and saved[CharacterKey()]
    local back = type(kept) == "table" and kept.back
    if type(back) ~= "table" or not back.group or not back.name then return end
    if origin.group == back.group and origin.name == back.name and origin.guide then return origin.guide end
    local guide = type(rxp.GetGuideTable) == "function" and rxp.GetGuideTable(back.group, back.name)
    -- RestedXP keeps a guide packed until it is loaded: have it unpacked for its steps.
    if type(guide) == "table" and type(guide.steps) ~= "table" and type(rxp.FetchGuide) == "function" then
        local ok, fetched = pcall(rxp.FetchGuide, rxp, guide)
        guide = ok and fetched or guide
    end
    if type(guide) ~= "table" or type(guide.steps) ~= "table" then return end
    origin = {group = back.group, name = back.name, guide = guide}
    return guide
end

-- Puts the route into RestedXP as a guide of its own and loads it: true, or false and why not. title: see
-- ns.RouteGuideText. source: what the route was planned from, so that it can be planned again on the way
-- ({kind = "prereq"}: the quests ticked in Missing Prerequisites; {kind = "quests", ids, finish}: those quests).
function ns.LoadRouteGuide(route, title, source)
    local rxp = ns.GetRXP and ns.GetRXP() or _G.RXP
    if type(rxp) ~= "table" or type(rxp.GetGuideTable) ~= "function" or type(rxp.LoadGuide) ~= "function" then
        return false, "RestedXP is not ready"
    end
    if not route or #route.stops == 0 then return false, "the route has no stops" end
    -- Back to the guide the player is in; from the route guide itself, to the one it already leads back to.
    local current, back = rxp.currentGuide, nil
    local saved = SavedGuides(true)
    local key = CharacterKey()
    if type(current) == "table" and not current.empty and current.group and current.name then
        if ns.IsRouteGuide(current) then
            back = saved and type(saved[key]) == "table" and saved[key].back or nil
        else
            back = {group = current.group, name = current.name}
            origin = {group = current.group, name = current.name, guide = current}
        end
    end
    local text = ns.RouteGuideText(route, back, title)
    local ok, err = Register(text)
    if not ok then return false, err end
    local guide = rxp.GetGuideTable(ROUTE_GROUP, ROUTE_NAME)
    if not guide then return false, "RestedXP did not take the guide" end
    -- Kept, so that RestedXP finds the guide again after a reload (see the watcher below).
    if saved then saved[key] = {text = text, back = back, title = title, source = source or route.source, order = route.order} end
    rxp:LoadGuide(guide)
    if type(rxp.SetStep) == "function" then pcall(rxp.SetStep, 1) end
    return true, back
end

--------------------------------------------------------------------------------------------------
-- Rerouting. The route guide is fixed text, but the way changes: the player leaves it, lands somewhere else, the
-- hearthstone comes off cooldown. So the route is planned again from where the player is, when they have moved on
-- (REROUTE_MOVED yards, at most every REROUTE_EVERY seconds) and after the events that change the way (a new
-- zone, landing from a flight, a hearthstone or teleport cast, a quest taken or handed in, a new flight point).
-- The stops keep their order unless a new order saves more than REROUTE_GAIN seconds and REROUTE_SHARE of the
-- trip; the guide is only loaded anew when the steps still ahead come out different.

local REROUTE_EVERY, REROUTE_MOVED = 30, 50
local REROUTE_GAIN, REROUTE_SHARE = 60, 0.10
local REROUTE_SOON = 2          -- seconds after an event, for the game to settle
local RIDING_YARDS = 3          -- moved this far in a second while standing still: on a ship, zeppelin or tram

local function Steps(text)
    local steps = {}
    local body = type(text) == "string" and text:match("\nstep\n(.*)$")
    if not body then return steps end
    for step in (body .. "step\n"):gmatch("(.-)step\n") do steps[#steps + 1] = step end
    return steps
end

-- Whether the steps of the loaded guide from `progress` on are the steps of a new text.
local function SameAhead(loaded, progress, new)
    local old, fresh = Steps(loaded), Steps(new)
    if #old - progress + 1 ~= #fresh then return false end
    for index, step in ipairs(fresh) do
        if old[progress + index - 1] ~= step then return false end
    end
    return true
end

local function SourceEntries(source)
    if source.kind == "quests" then return ns.QuestEntries and ns.QuestEntries(source.ids) or {} end
    return ns.SelectedRouteEntries and ns.SelectedRouteEntries() or {}
end

-- Plans the loaded route guide again from where the player is and loads the result when it differs from what is
-- still ahead: true and whether the order of the stops changed; false when nothing was done.
function ns.Reroute()
    local rxp = ns.GetRXP and ns.GetRXP() or _G.RXP
    if type(rxp) ~= "table" or not ns.IsRouteGuide(rxp.currentGuide) then return false end
    local saved = SavedGuides(false)
    local kept = saved and saved[CharacterKey()]
    if type(kept) ~= "table" or type(kept.source) ~= "table" or type(kept.text) ~= "string" then return false end
    local entries = SourceEntries(kept.source)
    local function plan(order)
        local env = ns.RouteEnvironment()
        env.finish, env.order = kept.source.finish, order
        local route = ns.PlanRoute(entries, env)
        if route then route.runes = env.runes end
        return route
    end
    local free = plan(nil)
    if not free or #free.stops == 0 then return false end
    local function weight(route) return route.seconds + route.crossings * CROSSING end
    local same = type(kept.order) == "table" and plan(kept.order) or nil
    local chosen, reordered = free, same ~= nil
    if same then
        local identical = #same.order == #free.order
        for index, key in ipairs(same.order) do identical = identical and free.order[index] == key end
        if identical or weight(free) > weight(same) - math.max(REROUTE_GAIN, weight(same) * REROUTE_SHARE) then
            chosen, reordered = same, false
        end
    end
    local text = ns.RouteGuideText(chosen, kept.back, kept.title)
    local progress = 1
    if type(rxp.GetGuideProgress) == "function" then
        local ok, step = pcall(rxp.GetGuideProgress)
        progress = ok and tonumber(step) or 1
    end
    if SameAhead(kept.text, progress, text) then return false end
    local ok = Register(text)
    local guide = ok and rxp.GetGuideTable(ROUTE_GROUP, ROUTE_NAME)
    if not guide then return false end
    kept.text, kept.order = text, chosen.order
    rxp:LoadGuide(guide)
    if type(rxp.SetStep) == "function" then pcall(rxp.SetStep, 1) end
    return true, reordered
end

if CreateFrame then
    local TRAVEL_SPELLS = {[8690] = true, [556] = true}     -- hearthstone, astral recall
    for _, teleport in ipairs(MAGE_TELEPORTS) do TRAVEL_SPELLS[teleport.spell] = true end
    local watcher = CreateFrame("Frame")
    for _, event in ipairs({"PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_CONTROL_GAINED", "UNIT_SPELLCAST_SUCCEEDED",
        "QUEST_ACCEPTED", "QUEST_TURNED_IN", "UI_INFO_MESSAGE"}) do
        watcher:RegisterEvent(event)
    end
    local due           -- when an event's reroute is to run
    local origin        -- where the player was at the last try
    local lastTry, lastSpot, ridingUntil, waited = 0, nil, 0, 0
    watcher:SetScript("OnEvent", function(_, event, a, b, c)
        -- (unit, cast, spell) of a cast; (kind, text) of a message
        if event == "UNIT_SPELLCAST_SUCCEEDED" and (a ~= "player" or not TRAVEL_SPELLS[c]) then return end
        if event == "UI_INFO_MESSAGE" and b ~= _G.ERR_NEWTAXIPATH then return end
        due = GetTime() + REROUTE_SOON
    end)
    watcher:SetScript("OnUpdate", function(_, elapsed)
        waited = waited + elapsed
        if waited < 1 then return end
        waited = 0
        local db = ns.db or RXPBlizzStyleDB
        local rxp = _G.RXP
        if type(db) ~= "table" or db.reroute == false or type(rxp) ~= "table" or not ns.IsRouteGuide(rxp.currentGuide) then
            due, origin, lastSpot = nil, nil, nil
            return
        end
        -- Not in a fight: nothing is planned then, and the game hands out position and speed as secret values
        -- that cannot be compared.
        if InCombatLockdown() then return end
        local ok, x, y, _, instance = pcall(UnitPosition, "player")
        x, y = PlainNumber(x), PlainNumber(y)
        if not ok or not x or not y or not instance or (issecretvalue and issecretvalue(instance)) then return end
        local speed = 0
        if GetUnitSpeed then speed = PlainNumber(GetUnitSpeed("player")) end
        if not speed then return end
        local now = GetTime()
        -- Carried along while standing still: not the time to plan from the middle of the sea.
        if lastSpot and lastSpot.instance == instance and speed == 0
            and (lastSpot.x - x) ^ 2 + (lastSpot.y - y) ^ 2 > RIDING_YARDS ^ 2 then
            ridingUntil = now + 5
        end
        lastSpot = {x = x, y = y, instance = instance}
        origin = origin or lastSpot
        if (UnitOnTaxi and UnitOnTaxi("player")) or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) or now < ridingUntil then
            return
        end
        local moved = origin.instance ~= instance or (origin.x - x) ^ 2 + (origin.y - y) ^ 2 > REROUTE_MOVED ^ 2
        if (due and now >= due) or (moved and now - lastTry >= REROUTE_EVERY) then
            due, lastTry, origin = nil, now, lastSpot
            local fine, changed, reordered = pcall(ns.Reroute)
            if fine and changed and reordered and ns.Print then ns.Print("Route updated: a better order from here.") end
        end
    end)
end

-- After a reload RestedXP looks for the guide the character was in: hand the kept route guide back to it before.
if CreateFrame then
    local loader = CreateFrame("Frame")
    loader:RegisterEvent("ADDON_LOADED")
    loader:SetScript("OnEvent", function(self, _, name)
        if name ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        local all = type(RXPBlizzStyleDB) == "table" and RXPBlizzStyleDB.routeGuides
        local kept = type(all) == "table" and all[CharacterKey()]
        if type(kept) == "table" and type(kept.text) == "string" then Register(kept.text) end
    end)
end

--------------------------------------------------------------------------------------------------
-- For other addons: the route planner on any list of quests.
--   local entries, skipped = RXPBlizzStyleAPI.QuestEntries({2770, 2846})   -- nil, reason without Questie
--   local ok, route = RXPBlizzStyleAPI.Plan(entries, {name = "Zul'Farrak", mapId = 1446, x = 38.7, y = 20.0})
--   RXPBlizzStyleAPI.Summary(route, entries)       -- a few short lines
--   RXPBlizzStyleAPI.LoadGuide(route, "Zul'Farrak quests")   -- true and the guide it leads back to, or false, why

_G.RXPBlizzStyleAPI = {
    version = 1,
    QuestEntries = function(ids) return ns.QuestEntries(ids) end,
    -- The trip for the entries from where the player is now; finish (optional) is where it ends.
    Plan = function(entries, finish)
        return pcall(function()
            local env = ns.RouteEnvironment()
            env.finish = finish
            local route = ns.PlanRoute(entries, env)
            route.runes = env.runes
            route.source = {kind = "quests", ids = {}, finish = finish}
            for index, entry in ipairs(entries) do route.source.ids[index] = entry.id end
            return route
        end)
    end,
    Summary = function(route, entries) return ns.RouteSummary(route, entries) end,
    UnlockedXp = function(entries) return ns.RouteUnlockedXp(entries) end,
    StopText = function(stop) return ns.RouteStopText(stop) end,
    LegText = function(leg) return ns.RouteLegText(leg) end,
    Duration = function(seconds) return ns.RouteDuration(seconds) end,
    FormatXp = function(xp) return ns.FormatXp(xp) end,
    PlaceName = function(mapId, x, y) return ns.PlaceName(mapId, x, y) end,
    LoadGuide = function(route, title) return ns.LoadRouteGuide(route, title, route and route.source) end,
}
