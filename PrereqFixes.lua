local addonName, ns = ...

-- Prerequisites added by hand, for quests Questie's database does not know or gets wrong. The prerequisites window
-- lists the quests Questie does not know; they are also saved in RXPBlizzStyleDB.unknownQuests.
--
-- [questId] = {
--     name = "Quest name",
--     level = 12,                    -- quest level
--     requiredLevel = 10,            -- level needed to pick it up
--     preQuestSingle = {101, 102},   -- any one of these must be done first
--     preQuestGroup = {103, 104},    -- all of these must be done first
--     starter = "Npc name",          -- who or what starts it
--     zone = "Zone name",
--     mapId = 1426, x = 46.5, y = 52.1,  -- uiMapId and coordinates (0-100) of where it starts
--     ender = "Npc name",            -- who it is handed in to
--     endZone = "Zone name",
--     endMapId = 1426, endX = 46.5, endY = 52.1,  -- where it is handed in
--     objective = "Bring 8 Gnoll Paws to Marshal Dughan.",  -- objective text shown in the list
-- },
--
-- Only the fields given here replace Questie's; the others still come from Questie.
ns.PREREQ_FIXES = {
}
