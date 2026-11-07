local addonName, ns = ...

-- The same switches in two places: as a "Blizzard Style" tab inside RestedXP's own settings, and
-- as a category of the game's Options > AddOns list (/rxpstyle opens that one).
local TITLE = "RestedXP Blizzard Style"

local OPTIONS = {
    {
        key = "tracker",
        name = "Quest tracker style",
        tooltip = "Shows the guide like a section of the quest tracker (current step and upcoming steps) instead of the RestedXP guide window.",
    }, {
        key = "attach",
        name = "Attach to the quest tracker",
        tooltip = "Keeps the guide directly below the quest tracker. Turn this off to drag the guide anywhere by its header bar.",
    }, {
        key = "limit",
        name = "Cut the guide off at a line",
        tooltip = "Hides whatever would reach below a line of your choice, so the guide does not cover what sits underneath. Move the mouse over the guide and drag the yellow line at its lower end.",
    }, {
        key = "hideQuests",
        name = "Guide in place of the quest tracker",
        tooltip = "While a guide is shown, Blizzard's quest tracker is hidden and the guide takes its place under a copy of its header bar. The + button on that bar brings your quests back until the guide is hidden or the interface reloads. During a fight they come back when it is over.",
    }, {
        key = "questie",
        name = "Questie tooltips on quest lines",
        tooltip = "With Questie: hovering a line that picks up, works on or hands in a quest shows the tooltip of that quest's pin on the map. Hold Shift for experience, money and the rest of the quest chain. Questie has it only for quests it marks on the map.",
    }, {
        key = "upcoming",
        name = "Upcoming steps",
        tooltip = "How many of the next steps are listed below the current step. Scroll over the list to look further ahead.",
        min = 0,
        max = 10,
    }, {
        key = "arrowText",
        name = "Current step on the arrow",
        tooltip = "Writes what is left to do in the current step below the waypoint arrow.",
    }, {
        key = "tomtom",
        name = "Use TomTom's arrow",
        tooltip = "Lets TomTom's arrow point to the current step and hides the RestedXP arrow. Only has an effect while TomTom is installed.",
    },
}

function ns.InitOptions()
    local category = Settings.RegisterVerticalLayoutCategory(TITLE)
    for _, option in ipairs(OPTIONS) do
        local default = ns.defaults[option.key]
        local setting = Settings.RegisterAddOnSetting(category, "RXPBlizzStyle_" .. option.key, option.key,
                                                      ns.db, type(default), option.name, default)
        setting:SetValueChangedCallback(function() ns.Refresh() end)
        if type(default) == "boolean" then
            Settings.CreateCheckbox(category, setting, option.tooltip)
        else
            local slider = Settings.CreateSliderOptions(option.min, option.max, 1)
            if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
                slider:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
            end
            Settings.CreateSlider(category, setting, slider, option.tooltip)
        end
    end
    Settings.RegisterAddOnCategory(category)
    ns.category = category
end

function ns.OpenOptions()
    if ns.category then Settings.OpenToCategory(ns.category:GetID()) end
end

-- RestedXP builds its settings with AceConfig; its options table can be fetched from the registry
-- by the name it was registered under (the addon's title) and extended with one more tab.
local function AddRestedXPTab(rxp)
    local registry = LibStub and LibStub("AceConfigRegistry-3.0", true)
    local getOptions = registry and rxp.title and registry:GetOptionsTable(rxp.title)
    local options = getOptions and getOptions("dialog", "AceConfigDialog-3.0")
    if not (options and options.args) then return end

    local tab = {
        type = "group",
        name = "Blizzard Style",
        order = 19,
        get = function(info) return ns.db[info[#info]] end,
        set = function(info, value)
            ns.db[info[#info]] = value
            ns.Refresh()
        end,
        args = {},
    }
    for order, option in ipairs(OPTIONS) do
        tab.args[option.key] = {
            type = option.max and "range" or "toggle",
            name = option.name,
            desc = option.tooltip,
            order = order,
            width = "full",
            min = option.min,
            max = option.max,
            step = option.max and 1 or nil,
        }
    end
    options.args.blizzardStyle = tab
    registry:NotifyChange(rxp.title)
    return true
end

local tabAdded
ns.RegisterPart("settings tab", function(rxp)
    -- RestedXP registers its options a moment after login; keep trying until they are there.
    if not tabAdded then tabAdded = AddRestedXPTab(rxp) end
end, function() end)
