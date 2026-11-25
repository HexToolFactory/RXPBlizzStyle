local addonName, ns = ...

-- RestedXP's Active Items and Active Targets windows in the look of the quest tracker: a section header bar
-- (the tracker's atlas and font) in place of RestedXP's title tab, no background box, and the quest item
-- button border around each button. Option sideFrames.
--
-- Both windows are AceGUI "RXPV2MiniFrame" widgets: rxp.activeItemWindow and rxp.targeting.activeTargetWindow.
-- Their buttons are secure (SecureActionButtonTemplate), so the windows are protected: nothing here moves or
-- sizes them. Only textures are shown or hidden and our own header frame is drawn, and only out of a fight.
-- RestedXP draws its backdrop again in UpdateSubTheme; a hook on that widget's method takes it off again.
-- The windows stay where RestedXP keeps them and are dragged through RestedXP's own StartMoving.

local HEADER_HEIGHT = 25
local BORDER = 1.83   -- the quick slot border's size against its button, as on action buttons

local windows = {}    -- widget -> our pieces: header, borders, label
local ui              -- RestedXP's addon.ui.v2

local function Widgets(rxp)
    local list = {}
    if rxp.activeItemWindow then list[#list + 1] = {rxp.activeItemWindow, "Active Items", "buttonList"} end
    local targeting = rxp.targeting
    if targeting and targeting.activeTargetWindow then
        list[#list + 1] = {targeting.activeTargetWindow, "Active Targets", "enemyTargetButtons", "friendlyTargetButtons"}
    end
    return list
end

local function Header(w, label)
    local header = CreateFrame("Frame", nil, w.frame)
    header:SetPoint("TOPLEFT", w.frame, "TOPLEFT", 0, 12)
    header:SetPoint("TOPRIGHT", w.frame, "TOPRIGHT", 0, 12)
    header:SetHeight(HEADER_HEIGHT)
    header:EnableMouse(true)

    header.Background = header:CreateTexture(nil, "BACKGROUND")
    header.Background:SetAtlas("UI-QuestTracker-Secondary-Objective-Header")
    header.Background:SetAllPoints(header)

    header.Text = header:CreateFontString(nil, "ARTWORK",
        ObjectiveTrackerHeaderFont and "ObjectiveTrackerHeaderFont" or "GameFontNormalMed2")
    header.Text:SetPoint("LEFT", 7, 0)
    header.Text:SetJustifyH("LEFT")
    header.Text:SetWordWrap(false)
    header.Text:SetText(label)

    -- RestedXP's own drag: its lock setting (Alt) and its saved positions.
    header:SetScript("OnMouseDown", function(_, button) if button == "LeftButton" then w:StartMoving() end end)
    header:SetScript("OnMouseUp", function(_, button) if button == "LeftButton" then w:StopMovingOrSizing() end end)
    return header
end

local function Border(btn)
    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Buttons\\UI-Quickslot2")
    border:SetPoint("CENTER", btn, "CENTER")
    local width, height = btn:GetWidth(), btn:GetHeight()
    border:SetSize((width > 0 and width or 25) * BORDER, (height > 0 and height or 25) * BORDER)
    return border
end

-- RestedXP sizes each window from its title tab's width: that width is made room for the header's text.
local function TitleRoom(w, piece)
    local room = math.ceil(piece.header.Text:GetStringWidth() + 24)
    if w.title:GetWidth() ~= room then w.title:SetWidth(room) end
end

local function Apply(w, piece, lists)
    if InCombatLockdown() then return end
    piece.header = piece.header or Header(w, piece.label)
    piece.header:Show()
    ui:SetFrameBackdropShown(w.frame, false)
    ui:SetFrameBackdropShown(w.title, false)
    w.title.text:Hide()
    TitleRoom(w, piece)
    for _, key in ipairs(lists) do
        for _, btn in ipairs(w[key] or {}) do
            piece.borders[btn] = piece.borders[btn] or Border(btn)
            piece.borders[btn]:Show()
        end
    end
    piece.styled = true
end

local function Restore(w, piece)
    if not piece.styled or InCombatLockdown() then return end
    piece.styled = nil
    if piece.header then piece.header:Hide() end
    for _, border in pairs(piece.borders) do border:Hide() end
    w.title.text:Show()
    w:SetTitle(w.title.text:GetText())   -- RestedXP's width for its title tab
    w:UpdateTheme()                      -- RestedXP's backdrop, with its own background setting
end

local function Update(rxp)
    ui = rxp.ui and rxp.ui.v2
    for _, entry in ipairs(Widgets(rxp)) do
        local w, label = entry[1], entry[2]
        local lists = {unpack(entry, 3)}
        local piece = windows[w]
        if not piece then
            assert(w.frame and w.title and w.title.text and ui and ui.SetFrameBackdropShown,
                "RestedXP's mini frames changed")
            piece = {label = label, borders = {}, lists = lists}
            windows[w] = piece
            hooksecurefunc(w, "UpdateSubTheme", function(this)
                if ns.db.sideFrames and windows[this].styled then Apply(this, windows[this], windows[this].lists) end
            end)
        end
        if ns.db.sideFrames then Apply(w, piece, lists) else Restore(w, piece) end
    end
end

local function Disable()
    for w, piece in pairs(windows) do pcall(Restore, w, piece) end
end

ns.RegisterPart("tracker style for active items and targets", Update, Disable)
