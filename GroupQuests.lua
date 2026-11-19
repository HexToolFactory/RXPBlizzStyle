local addonName, ns = ...

-- In the DungeonJournal addon's track windows (its Track button): hovering a quest, or a step of its chain, adds where
-- each group member stands with it: completed, has it, can take it, or cannot (level, class or race, earlier quests).
-- Members with RXPBlizzStyle answer for themselves through addon messages (any of them answers, with or without
-- DungeonJournal). For the others: Questie's shared quest logs, the game's IsUnitOnQuest, their level and faction,
-- and what the game reports when the player shares a quest ("X has completed that quest").
-- Option groupQuests. DungeonJournal's files are not changed: its windows are read and its lines' OnEnter hooked.

local PREFIX = "RXPBSQuests"
local ASK_EVERY = 5       -- seconds between questions to the group
local WAIT = 3            -- seconds a member shows "Asking" before it counts as no answer
local SCAN_EVERY = 1      -- seconds between looks for new lines in the track windows
local MAX_LEN = 240       -- characters per addon message
local MAX_IDS = 80        -- quests answered per question
local WINDOW = "ForeverDungeonJournalQuestTracker"
local MAX_WINDOWS = 10

local CODES = {done = "d", ready = "r", log = "l", level = "v", notforyou = "f", locked = "p", available = "a"}
local STATES = {}
for state, code in pairs(CODES) do STATES[code] = state end

-- What a state reads like: text (with %d for its number), colour.
local TEXT = {
    done = {"Completed", 0.25, 1, 0.25},
    ready = {"Has it, ready to turn in", 0.25, 1, 0.25},
    log = {"Has it", 1, 0.82, 0},
    available = {"Can take it", 1, 1, 1},
    level = {"Level %d needed", 1, 0.3, 0.3},
    lowlevel = {"Level too low", 1, 0.3, 0.3},
    notforyou = {"Not eligible", 1, 0.3, 0.3},
    locked = {"%d earlier quests missing", 1, 0.3, 0.3},
    locked1 = {"1 earlier quest missing", 1, 0.3, 0.3},
    nolog = {"Does not have it", 0.8, 0.8, 0.8},
    asking = {"Asking", 0.6, 0.6, 0.6},
    unknown = {"No answer", 0.6, 0.6, 0.6},
}

local answers = {}        -- [name key] = {[quest id] = {state = , number = }}
local silent = {}         -- [name key] = true: asked, and no answer came within WAIT seconds
local shared = {}         -- [name key] = {[quest id] = {state = , number = }}: what sharing a quest reported
local askedAt = -100
local current, hookRan    -- the line whose tooltip shows the group

local function Now() return GetTime and GetTime() or 0 end

local function Plain(value)
    if issecretvalue and issecretvalue(value) then return nil end
    return value
end

-- Names compared without spaces, dashes and case: the sender of an addon message reads "First Surname", a whisper
-- target may be "First-Surname".
local function Key(name)
    name = Plain(name)
    if type(name) ~= "string" or name == "" then return end
    return (name:gsub("[%s%-']", ""):lower())
end

local function FullName(unit)
    local name = GetUnitName and Plain(GetUnitName(unit, true)) or nil
    return name or Plain(UnitName(unit))
end

-- The group members other than the player: {{unit, name, key}, ...}.
local function Members()
    local list = {}
    local raid = IsInRaid and IsInRaid()
    local count = raid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
    for i = 1, count do
        local unit = (raid and "raid" or "party") .. i
        if UnitExists(unit) and not UnitIsUnit(unit, "player") then
            local full = FullName(unit)
            local key = Key(full)
            if key then list[#list + 1] = {unit = unit, name = Plain(UnitName(unit)) or full, key = key} end
        end
    end
    return list
end

local function Channel()
    local home = LE_PARTY_CATEGORY_HOME
    if IsInGroup and (home == nil or IsInGroup(home)) then
        if IsInRaid and IsInRaid() then return "RAID" end
        if IsInGroup() then return "PARTY" end
    end
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
end

-- One message per MAX_LEN characters: kind, a colon, the parts with commas.
local function Send(kind, parts)
    local channel = Channel()
    local send = C_ChatInfo and C_ChatInfo.SendAddonMessage or _G.SendAddonMessage
    if not channel or not send or #parts == 0 then return end
    local line = ""
    for _, part in ipairs(parts) do
        if line ~= "" and #kind + 1 + #line + 1 + #part > MAX_LEN then
            pcall(send, PREFIX, kind .. ":" .. line, channel)
            line = ""
        end
        line = line == "" and part or (line .. "," .. part)
    end
    pcall(send, PREFIX, kind .. ":" .. line, channel)
end

--------------------------------------------------------------------------------------------------
-- Answering: where this character stands with the quests a group member asks about.

local function Answer(text)
    if not ns.QuestStatus then return end
    local parts, count = {}, 0
    for id in text:gmatch("%d+") do
        id = tonumber(id)
        count = count + 1
        if count > MAX_IDS then break end
        local ok, state, number = pcall(ns.QuestStatus, id)
        local code = ok and CODES[state]
        if code then parts[#parts + 1] = ("%d=%s%s"):format(id, code, type(number) == "number" and math.floor(number) or "") end
    end
    Send("A", parts)
end

local RefreshTooltip

local function Store(sender, text)
    local list = answers[sender] or {}
    answers[sender] = list
    silent[sender] = nil
    for id, code, number in text:gmatch("(%d+)=(%a)(%d*)") do
        local state = STATES[code]
        if state then list[tonumber(id)] = {state = state, number = tonumber(number)} end
    end
    RefreshTooltip()
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, _, prefix, message, _, sender)
    if prefix ~= PREFIX or type(message) ~= "string" then return end
    local from = Key(sender)
    if not from or from == Key(FullName("player")) then return end
    local kind, text = message:match("^(%a):(.*)$")
    if kind == "Q" then
        Answer(text)
    elseif kind == "A" then
        Store(from, text)
    end
end)
if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
elseif _G.RegisterAddonMessagePrefix then
    pcall(_G.RegisterAddonMessagePrefix, PREFIX)
end

--------------------------------------------------------------------------------------------------
-- Sharing a quest (Blizzard's Share button, RestedXP's auto share): the game reports each member's state with it as
-- a system line. The quest is the one just shared; ACCEPTED and DECLINED come when the member clicks.

local SHARE_WAIT = 60     -- seconds the lines count for the quest just shared
local SHARE_RESULTS = {
    {"ERR_QUEST_PUSH_ALREADY_DONE_S", "done"},
    {"ERR_QUEST_PUSH_ONQUEST_S", "log"},
    {"ERR_QUEST_PUSH_ACCEPTED_S", "log"},
    {"ERR_QUEST_PUSH_DECLINED_S", "available"},
    {"ERR_QUEST_PUSH_INVALID_S", "notforyou"},
    {"ERR_QUEST_PUSH_LOW_LEVEL_S", "level"},
    {"ERR_QUEST_PUSH_HIGH_LEVEL_S", "notforyou"},
    {"ERR_QUEST_PUSH_CLASS_S", "notforyou"},
    {"ERR_QUEST_PUSH_RACE_S", "notforyou"},
    {"ERR_QUEST_PUSH_PREREQUISITE_S", "locked"},
}
local sharedQuest, sharedAt
local patterns

-- "%s has completed that quest." -> "^(.+) has completed that quest%.$"
local function Patterns()
    if patterns then return patterns end
    patterns = {}
    for _, result in ipairs(SHARE_RESULTS) do
        local text = _G[result[1]]
        if type(text) == "string" and text:find("%%s") then
            local pattern = text:gsub("[%^%$%(%)%.%[%]%*%+%-%?%%]", "%%%0"):gsub("%%%%s", "(.+)")
            patterns[#patterns + 1] = {"^" .. pattern .. "$", result[2]}
        end
    end
    return patterns
end

local function QuestOfLogIndex(index)
    if type(index) ~= "number" then
        if C_QuestLog and C_QuestLog.GetSelectedQuest then
            local ok, id = pcall(C_QuestLog.GetSelectedQuest)
            if ok and type(Plain(id)) == "number" and id > 0 then return id end
        end
        index = GetQuestLogSelection and GetQuestLogSelection()
        if type(index) ~= "number" then return end
    end
    if C_QuestLog and C_QuestLog.GetQuestIDForLogIndex then
        local ok, id = pcall(C_QuestLog.GetQuestIDForLogIndex, index)
        if ok and type(Plain(id)) == "number" and id > 0 then return id end
    end
    if GetQuestLogTitle then
        local id = select(8, GetQuestLogTitle(index))
        if type(Plain(id)) == "number" and id > 0 then return id end
    end
end

if hooksecurefunc and type(_G.QuestLogPushQuest) == "function" then
    hooksecurefunc("QuestLogPushQuest", function(index)
        local id = QuestOfLogIndex(index)
        if id then sharedQuest, sharedAt = id, Now() end
    end)
end

-- System lines, and the info / error lines some clients use for them (their text is the second value).
local function OnShareLine(...)
    if not sharedQuest or Now() - sharedAt > SHARE_WAIT then return end
    for i = 1, math.min(select("#", ...), 2) do
        local line = Plain((select(i, ...)))
        if type(line) == "string" then
            for _, pattern in ipairs(Patterns()) do
                local name = line:match(pattern[1])
                -- In case the name comes as a player link or in colour.
                if name then name = name:gsub("|H[^|]*|h%[?([^%]|]*)%]?|h", "%1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") end
                local key = name and Key(name)
                if key then
                    shared[key] = shared[key] or {}
                    shared[key][sharedQuest] = {state = pattern[2]}
                    RefreshTooltip()
                    return
                end
            end
        end
    end
end

local shares = CreateFrame("Frame")
shares:RegisterEvent("CHAT_MSG_SYSTEM")
shares:RegisterEvent("UI_INFO_MESSAGE")
shares:RegisterEvent("UI_ERROR_MESSAGE")
shares:SetScript("OnEvent", function(_, _, ...) OnShareLine(...) end)

--------------------------------------------------------------------------------------------------
-- Asking: the lines under DungeonJournal's tooltip of a quest in its track window.

-- A member's state without an answer of their own: Questie's shared quest log, the game, their level and faction.
-- Questie shares only the quest log: a member Questie knows who lacks the quest "does not have it" (done or not).
local function Guess(member, quest)
    local id = quest.id
    local comms = ns.QuestieModule and ns.QuestieModule("QuestieComms")
    local logs = type(comms) == "table" and type(comms.remoteQuestLogs) == "table" and comms.remoteQuestLogs or {}
    for name, objectives in pairs(type(logs[id]) == "table" and logs[id] or {}) do
        if Key(name) == member.key then
            local finished = type(objectives) == "table" and #objectives > 0
            for _, objective in ipairs(type(objectives) == "table" and objectives or {}) do
                if type(objective) ~= "table" or not objective.finished then finished = false end
            end
            return finished and "ready" or "log"
        end
    end
    if C_QuestLog and C_QuestLog.IsUnitOnQuest then
        local ok, on = pcall(C_QuestLog.IsUnitOnQuest, member.unit, id)
        if ok and Plain(on) == true then return "log" end
    end
    local classes = type(comms) == "table" and type(comms.remotePlayerClasses) == "table" and comms.remotePlayerClasses or {}
    for name in pairs(classes) do
        if Key(name) == member.key then return "nolog" end
    end
    for _, players in pairs(logs) do
        for name in pairs(type(players) == "table" and players or {}) do
            if Key(name) == member.key then return "nolog" end
        end
    end
end

local function MemberState(member, quest)
    local got = answers[member.key] and answers[member.key][quest.id]
    local state, number
    if got then
        state, number = got.state, got.number
    else
        state = Guess(member, quest)
        -- A share's result is older than Questie's log: a quest in the log wins over it.
        local share = shared[member.key] and shared[member.key][quest.id]
        if share and state ~= "ready" and state ~= "log" then state, number = share.state, share.number end
    end
    if state == "level" and not number then
        if type(quest.requires) ~= "number" then return "lowlevel" end
        number = quest.requires
    end
    -- DungeonJournal knows Forever's level and faction for quests Questie does not have.
    if state == nil or state == "available" or state == "locked" or state == "nolog" then
        local level, need = Plain(UnitLevel(member.unit)), quest.requires
        if type(level) == "number" and level > 0 and type(need) == "number" and level < need then return "level", need end
        local side = Plain(UnitFactionGroup(member.unit))
        if (quest.faction == "Alliance" or quest.faction == "Horde") and side and side ~= quest.faction then return "notforyou" end
    end
    if state then return state, number end
    if silent[member.key] or Now() - askedAt >= WAIT then return "unknown" end
    return "asking"
end

local function Details(id)
    local journal = _G.ForeverDungeonJournal_NS
    local all = type(journal) == "table" and type(journal.QUEST_PREREQ_DETAILS) == "table" and journal.QUEST_PREREQ_DETAILS
    return all and type(all[id]) == "table" and all[id] or {}
end

-- The quest a hovered line of a track window stands for: {id, requires, faction}. A quest's row (row.info.quest),
-- a step of an unfolded chain (line.entry) or the chain step under a quest (row.step, the row's info.step).
local function Target(button)
    local info = type(button.info) == "table" and button.info
    if info and type(info.quest) == "table" then return info.quest end
    local entry = type(button.entry) == "table" and button.entry
    if entry and type(entry.step) == "table" and type(entry.step.id) == "number" then
        local details = type(entry.details) == "table" and entry.details or Details(entry.step.id)
        return {id = entry.step.id, requires = details.requires, faction = details.faction}
    end
    local parent = button.GetParent and button:GetParent()
    info = type(parent) == "table" and parent.step == button and type(parent.info) == "table" and parent.info
    if info and type(info.step) == "table" and type(info.step.id) == "number" then
        local details = Details(info.step.id)
        return {id = info.step.id, requires = details.requires, faction = details.faction}
    end
end

local function WindowOf(button)
    while type(button) == "table" and not button.fdjTracker do button = button.GetParent and button:GetParent() or nil end
    return button
end

-- The quests of a track window: its quests and every step of their chains.
local function WindowIds(window)
    local ids, seen = {}, {}
    local function add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = tostring(id)
        end
    end
    local journal = _G.ForeverDungeonJournal_NS
    local chains = type(journal) == "table" and type(journal.QUEST_PREREQ_CHAINS) == "table" and journal.QUEST_PREREQ_CHAINS or {}
    for _, row in ipairs(type(window) == "table" and type(window.rows) == "table" and window.rows or {}) do
        local quest = type(row.info) == "table" and row.info.quest
        if type(quest) == "table" then
            add(quest.id)
            for _, step in ipairs(type(chains[quest.id]) == "table" and chains[quest.id] or {}) do
                if type(step) == "table" then add(step.id) end
            end
        end
        for _, line in ipairs(type(row.chainLines) == "table" and row.chainLines or {}) do
            local step = Target(line)
            if step then add(step.id) end
        end
    end
    return ids
end

-- Every hover asks again (quests change), but not more often than every ASK_EVERY seconds.
local function Ask(button, members)
    if Now() - askedAt < ASK_EVERY then return end
    askedAt = Now()
    Send("Q", WindowIds(WindowOf(button)))
    if C_Timer and C_Timer.After then
        C_Timer.After(WAIT + 0.1, function()
            for _, member in ipairs(members) do
                if not answers[member.key] then silent[member.key] = true end
            end
            RefreshTooltip()
        end)
    end
end

local function OnLineEnter(button)
    hookRan = true
    current = button
    if not (ns.db and ns.db.groupQuests ~= false) then return end
    local quest = Target(button)
    if type(quest) ~= "table" or type(quest.id) ~= "number" then return end
    if GameTooltip:GetOwner() ~= button then return end
    local members = Members()
    if #members == 0 then return end
    Ask(button, members)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Group", 1, 0.82, 0)
    local quiet = false
    for _, member in ipairs(members) do
        local state, number = MemberState(member, quest)
        if state == "locked" and number == 1 then state = "locked1" end
        local text = TEXT[state] or TEXT.unknown
        local right = text[1]:find("%%d") and text[1]:format(number or 0) or text[1]
        if state == "locked" and not number then right = "Earlier quests missing" end
        GameTooltip:AddDoubleLine(member.name, right, 0.9, 0.9, 0.9, text[2], text[3], text[4])
        if state == "unknown" then quiet = true end
    end
    if quiet then GameTooltip:AddLine("No answer: needs RXPBlizzStyle or Questie, or share the quest.", 0.55, 0.55, 0.55) end
    GameTooltip:Show()
end

-- Answers came in while a quest's tooltip is up: show it again.
function RefreshTooltip()
    local button = current
    if not button or not GameTooltip:IsShown() or GameTooltip:GetOwner() ~= button then return end
    local show = button:GetScript("OnEnter")
    if not show then return end
    hookRan = false
    show(button)
    if not hookRan then OnLineEnter(button) end
end

local function Hook(button)
    if type(button) == "table" and not button.rxpbsGroupHooked and button.HookScript then
        button.rxpbsGroupHooked = true
        button:HookScript("OnEnter", OnLineEnter)
    end
end

-- New rows and lines: DungeonJournal makes them as its track windows fill and chains unfold.
local function HookRows()
    for index = 1, MAX_WINDOWS do
        local window = _G[WINDOW .. (index > 1 and index or "")]
        if type(window) == "table" and type(window.rows) == "table" then
            for _, row in ipairs(window.rows) do
                Hook(row)
                Hook(row.step)
                for _, line in ipairs(type(row.chainLines) == "table" and row.chainLines or {}) do Hook(line) end
            end
        end
    end
end

local driver = CreateFrame("Frame")
local waited = 0
driver:SetScript("OnUpdate", function(_, elapsed)
    waited = waited + elapsed
    if waited < SCAN_EVERY then return end
    waited = 0
    if type(_G.ForeverDungeonJournal_NS) == "table" then HookRows() end
end)

ns.GroupQuestsHookRows = HookRows
