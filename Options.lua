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
        name = "Limit the guide's height",
        tooltip = "The guide gets no taller than its height (Display > Height), so it does not cover what sits underneath. Move the mouse over the guide and drag the yellow line at its free end.",
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

-- Options > AddOns > RestedXP Blizzard Style > Display
local DISPLAY = {
    {
        key = "scale",
        name = "Scale",
        tooltip = "Size of the guide, on top of the quest tracker's own scale.",
        percent = true,
    }, {
        key = "width",
        name = "Width",
        tooltip = "Width of the guide.",
    }, {
        key = "height",
        name = "Height",
        tooltip = "How tall the guide may get. You can also drag the yellow line that shows while the mouse is on the guide. Turns on \"Limit the guide's height\".",
    }, {
        key = "anchor",
        name = "Anchor",
        tooltip = "Top: the current step at the top, the next steps below it (as the quest tracker does). Bottom: the current step at the bottom, the next steps above it, and the guide grows upwards from its lower end (like RestedXP's \"Current step frame anchor\"). With Bottom, turn on the height limit to keep the current step in one place below the quest tracker.",
        values = {{"TOP", "Top"}, {"BOTTOM", "Bottom"}},
    },
}

for _, option in ipairs(DISPLAY) do
    local range = ns.RANGES[option.key]
    if range then option.min, option.max, option.step = range[1], range[2], range[3] end
end

ns.settings = {}

local function AddControl(category, option)
    local default = ns.defaults[option.key]
    local setting = Settings.RegisterAddOnSetting(category, "RXPBlizzStyle_" .. option.key, option.key,
                                                  ns.db, type(default), option.name, default)
    ns.settings[option.key] = setting
    setting:SetValueChangedCallback(function()
        if option.key == "height" and not ns.db.limit then ns.SetOption("limit", true) end
        ns.Refresh()
    end)
    if type(default) == "boolean" then
        Settings.CreateCheckbox(category, setting, option.tooltip)
    elseif option.values then
        local function Values()
            local container = Settings.CreateControlTextContainer()
            for _, value in ipairs(option.values) do container:Add(value[1], value[2]) end
            return container:GetData()
        end
        local create = Settings.CreateDropdown or Settings.CreateDropDown
        create(category, setting, Values, option.tooltip)
    else
        local slider = Settings.CreateSliderOptions(option.min, option.max, option.step or 1)
        if MinimalSliderWithSteppersMixin and MinimalSliderWithSteppersMixin.Label then
            if option.percent then
                slider:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right,
                    function(value) return ("%d%%"):format(value * 100 + 0.5) end)
            else
                slider:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
            end
        end
        Settings.CreateSlider(category, setting, slider, option.tooltip)
    end
end

function ns.InitOptions()
    local category = Settings.RegisterVerticalLayoutCategory(TITLE)
    for _, option in ipairs(OPTIONS) do AddControl(category, option) end
    local display = Settings.RegisterVerticalLayoutSubcategory(category, "Display")
    for _, option in ipairs(DISPLAY) do AddControl(display, option) end
    Settings.RegisterAddOnCategory(category)
    ns.category = category
end

-- Changes a setting from the guide itself (dragging it, the yellow line) so that an open settings panel shows it.
function ns.SetOption(key, value)
    local setting = ns.settings[key]
    if setting then
        -- The setting reads the saved variable itself: a value that is already there would not count as a change.
        ns.db[key] = nil
        if not pcall(setting.SetValue, setting, value) then
            ns.db[key] = value
            ns.Refresh()
        end
    else
        ns.db[key] = value
        ns.Refresh()
    end
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
    local function Add(option, order)
        tab.args[option.key] = {
            type = option.values and "select" or option.max and "range" or "toggle",
            name = option.name,
            desc = option.tooltip,
            order = order,
            width = "full",
            min = option.min,
            max = option.max,
            step = option.max and (option.step or 1) or nil,
            isPercent = option.percent,
        }
        if option.values then
            local values = {}
            for _, value in ipairs(option.values) do values[value[1]] = value[2] end
            tab.args[option.key].values = values
        end
    end
    for order, option in ipairs(OPTIONS) do Add(option, order) end
    tab.args.displayHeader = {type = "header", name = "Display", order = 100}
    for order, option in ipairs(DISPLAY) do Add(option, 100 + order) end
    tab.set = function(info, value)
        local key = info[#info]
        if key == "height" and not ns.db.limit then ns.db.limit = true end
        ns.db[key] = value
        ns.Refresh()
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
