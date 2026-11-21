local ADDON_NAME, ns = ...

local UI = {}
ns.UI = UI

local tabFrame
local dropdown
local statusText
local warningText

local selectedList
local copyDialog

--------------------------------------------------------------------------
-- Output pane: copyable text box plus paging for multi-part output. Shared
-- by the AH tab and the slash-command window.
--------------------------------------------------------------------------

-- InputScrollFrameTemplate draws its border this far outside the scroll frame.
local BOX_BORDER_INSET = 5

-- Scroll bar gutter, matching Blizzard's InputScrollFrame_OnLoad.
local SCROLL_BAR_GUTTER = 18

-- Space between the window's edges and the Converter tab's content. The tab
-- frame is already inset CONTENT_FRAME_RIGHT_INSET from the window's right.
local CONTENT_MARGIN = 16
local CONTENT_FRAME_RIGHT_INSET = 4
local CONTENT_RIGHT = CONTENT_MARGIN - CONTENT_FRAME_RIGHT_INSET

local function CreateOutputPane(parent)
  local pane = {}
  pane.chunks = { "" }
  pane.index = 1

  local scrollFrame = CreateFrame("ScrollFrame", nil, parent, "InputScrollFrameTemplate")
  pane.scrollFrame = scrollFrame

  local editBox = scrollFrame.EditBox
  pane.editBox = editBox
  editBox:SetMultiLine(true)
  editBox:SetMaxLetters(0)
  -- An auto-focused box would swallow movement keys when the tab opens.
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  scrollFrame.CharCount:Hide()

  function pane:SyncEditBoxWidth()
    self.editBox:SetWidth(math.max(1, self.scrollFrame:GetWidth() - SCROLL_BAR_GUTTER))
  end

  -- The window can widen while shown (another addon adding a tab late).
  scrollFrame:HookScript("OnSizeChanged", function() pane:SyncEditBoxWidth() end)

  local selectButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  pane.selectButton = selectButton
  selectButton:SetSize(90, 22)
  selectButton:SetText("Select All")
  selectButton:SetScript("OnClick", function()
    editBox:SetFocus()
    editBox:HighlightText()
  end)

  local partLabel = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  pane.partLabel = partLabel

  local prevButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  pane.prevButton = prevButton
  prevButton:SetSize(24, 22)
  prevButton:SetText("<")

  local nextButton = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  pane.nextButton = nextButton
  nextButton:SetSize(24, 22)
  nextButton:SetText(">")

  function pane:ShowChunk(index)
    self.index = math.max(1, math.min(index, #self.chunks))
    self.editBox:SetText(self.chunks[self.index] or "")
    self.editBox:SetCursorPosition(0)

    local multiple = #self.chunks > 1
    self.partLabel:SetShown(multiple)
    self.prevButton:SetShown(multiple)
    self.nextButton:SetShown(multiple)

    if multiple then
      self.partLabel:SetText(("Part %d of %d"):format(self.index, #self.chunks))
      self.prevButton:SetEnabled(self.index > 1)
      self.nextButton:SetEnabled(self.index < #self.chunks)
    end
  end

  function pane:SetChunks(chunks)
    self.chunks = (chunks and #chunks > 0) and chunks or { "" }
    self:ShowChunk(1)
  end

  prevButton:SetScript("OnClick", function() pane:ShowChunk(pane.index - 1) end)
  nextButton:SetScript("OnClick", function() pane:ShowChunk(pane.index + 1) end)

  return pane
end

--------------------------------------------------------------------------
-- Clear List confirmation: clearing cannot be undone, so it always asks.
--------------------------------------------------------------------------

StaticPopupDialogs["SHOPPINGCONVERTER_CLEAR_LIST"] = {
  text = "Remove every item from Auctionator shopping list \"%s\"?\n\nThis cannot be undone.",
  button1 = "Clear List",
  button2 = CANCEL,
  OnAccept = function(_, data)
    if ns.Converter:ClearList(data.listName) then
      ns.Print("Cleared \"%s\".", data.listName)
    end
    UI:Refresh()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

-- Shared by the Clear List button and /shopconv clear.
function UI:ConfirmClearList(listName)
  if not listName or listName == "" then
    return
  end

  if not tContains(ns.Converter:GetShoppingListNames(), listName) then
    ns.Print("\"%s\" is not an Auctionator shopping list.", listName)
    return
  end

  if ns.Converter:GetShoppingListItemCount(listName) == 0 then
    ns.Print("\"%s\" is already empty.", listName)
    return
  end

  StaticPopup_Show("SHOPPINGCONVERTER_CLEAR_LIST", listName, nil, { listName = listName })
end

--------------------------------------------------------------------------
-- Status reporting
--------------------------------------------------------------------------

local function DescribeResult(result)
  if result.total == 0 then
    return ("\"%s\" is empty."):format(result.listName), nil
  end

  local status = ("%d item(s) converted."):format(result.total)

  local sources = {}
  if result.sources.craftsim > 0 then
    table.insert(sources, ("%d from CraftSim"):format(result.sources.craftsim))
  end
  if result.sources.cache > 0 then
    table.insert(sources, ("%d cached"):format(result.sources.cache))
  end
  if result.sources["local"] > 0 then
    table.insert(sources, ("%d local"):format(result.sources["local"]))
  end
  if result.sources.live > 0 then
    table.insert(sources, ("%d looked up"):format(result.sources.live))
  end
  if #sources > 0 then
    status = status .. " (" .. table.concat(sources, ", ") .. ")"
  end

  local warnings = {}
  if result.sources.none > 0 then
    table.insert(warnings, ("%d matched by name only - no item ID found, so quality rank may be wrong")
      :format(result.sources.none))
  end
  if result.sources.closed > 0 then
    table.insert(warnings, ("%d could not be looked up - the Auction House was closed")
      :format(result.sources.closed))
  end
  if result.droppedFilters > 0 then
    table.insert(warnings, ("%d Auctionator filter(s) dropped - price and level limits have no TSM search equivalent")
      :format(result.droppedFilters))
  end
  if #result.chunks > 1 then
    table.insert(warnings, ("output split into %d parts - paste them into TSM one at a time"):format(#result.chunks))
  end

  local warning
  if #warnings > 0 then
    warning = "|cffffd100" .. table.concat(warnings, ". ") .. ".|r"
  end

  return status, warning
end

--------------------------------------------------------------------------
-- Auction House tab
--------------------------------------------------------------------------

local function ResolveSelectedList()
  local names = ns.Converter:GetShoppingListNames()

  if not selectedList or not tContains(names, selectedList) then
    selectedList = ns.db.lastList
  end
  if not selectedList or not tContains(names, selectedList) then
    selectedList = tContains(names, ns.DEFAULT_LIST_NAME) and ns.DEFAULT_LIST_NAME or names[1]
  end

  return selectedList, names
end

function UI:Refresh()
  if not tabFrame or not tabFrame.pane then
    return
  end

  local pane = tabFrame.pane

  if not ns.IsAddOnLoaded("Auctionator") then
    pane:SetChunks({ "" })
    statusText:SetText("Auctionator is not loaded.")
    warningText:SetText("")
    return
  end

  local listName = ResolveSelectedList()
  dropdown:SetDefaultText(listName or "No shopping lists")

  if not listName then
    pane:SetChunks({ "" })
    statusText:SetText("No Auctionator shopping lists found.")
    warningText:SetText("")
    return
  end

  ns.db.lastList = listName

  statusText:SetText("Converting...")
  warningText:SetText("")

  ns.Converter:Build(
    listName,
    function(result)
      pane:SetChunks(result.chunks)
      local status, warning = DescribeResult(result)
      statusText:SetText(status)
      warningText:SetText(warning or "")
      if result.total > 0 then
        -- The player asked for this conversion, so select it for copying.
        pane.editBox:SetFocus()
        pane.editBox:HighlightText()
      end
    end,
    function(index, total)
      statusText:SetText(("Looking up item %d of %d at the Auction House..."):format(index, total))
    end
  )
end

function UI:CreateTabContent()
  local frame = CreateFrame("Frame", "ShoppingConverterTabFrame", AuctionHouseFrame)
  frame:SetPoint("TOP", 0, -40)
  frame:SetPoint("LEFT")
  frame:SetPoint("BOTTOMRIGHT", -CONTENT_FRAME_RIGHT_INSET, 27)

  local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  label:SetPoint("TOPLEFT", CONTENT_MARGIN, -16)
  label:SetText("Shopping List")

  dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
  dropdown:SetSize(240, 26)
  -- Runs on every open, so list changes show without a refresh.
  dropdown:SetupMenu(function(_, rootDescription)
    local names = ns.Converter:GetShoppingListNames()
    if #names == 0 then
      rootDescription:CreateTitle("No Auctionator shopping lists")
      return
    end
    for _, name in ipairs(names) do
      rootDescription:CreateRadio(
        name,
        function() return selectedList == name end,
        function()
          selectedList = name
          ns.db.lastList = name
          UI:Refresh()
        end
      )
    end
  end)

  local refreshButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  refreshButton:SetSize(90, 22)
  refreshButton:SetText("Refresh")
  refreshButton:SetPoint("LEFT", dropdown, "RIGHT", 12, 0)
  refreshButton:SetScript("OnClick", function()
    UI:Refresh()
  end)

  local clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  clearButton:SetSize(90, 22)
  clearButton:SetText("Clear List")
  clearButton:SetPoint("LEFT", refreshButton, "RIGHT", 8, 0)
  clearButton:SetScript("OnClick", function()
    UI:ConfirmClearList(selectedList)
  end)

  statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  statusText:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -10)
  statusText:SetPoint("RIGHT", -CONTENT_RIGHT, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetText("")

  warningText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  warningText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -4)
  warningText:SetPoint("RIGHT", -CONTENT_RIGHT, 0)
  warningText:SetJustifyH("LEFT")
  warningText:SetText("")

  local outputLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  outputLabel:SetPoint("TOPLEFT", warningText, "BOTTOMLEFT", 0, -12)
  outputLabel:SetText("TSM Search String")

  local pane = CreateOutputPane(frame)
  frame.pane = pane

  -- Offset so the visible border lines up with the labels and margin.
  pane.scrollFrame:SetPoint("TOPLEFT", outputLabel, "BOTTOMLEFT", BOX_BORDER_INSET, -8)
  pane.scrollFrame:SetPoint("BOTTOMRIGHT", -(CONTENT_RIGHT + BOX_BORDER_INSET), 28)

  -- Anchored to the box so it follows the row down when a warning appears.
  pane.selectButton:SetPoint("BOTTOMRIGHT", pane.scrollFrame, "TOPRIGHT", BOX_BORDER_INSET, BOX_BORDER_INSET + 4)
  pane.nextButton:SetPoint("RIGHT", pane.selectButton, "LEFT", -8, 0)
  pane.prevButton:SetPoint("RIGHT", pane.nextButton, "LEFT", -2, 0)
  pane.partLabel:SetPoint("RIGHT", pane.prevButton, "LEFT", -6, 0)

  local versionText = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  -- Anchored to the box so the two can't collide.
  versionText:SetPoint("TOPRIGHT", pane.scrollFrame, "BOTTOMRIGHT", BOX_BORDER_INSET, -12)
  versionText:SetText(ns.VERSION)

  frame:SetScript("OnShow", function()
    -- The scroll frame's width is only reliable once laid out.
    pane:SyncEditBoxWidth()
    UI:Refresh()
  end)

  frame:SetScript("OnHide", function()
    -- Stop live AH queries when leaving the tab.
    ns.Converter:Abort()
    ns.Resolver:Abort()
  end)

  pane:SetChunks({ "" })
  tabFrame = frame

  return frame
end

function UI:GetTabFrame()
  return tabFrame
end

--------------------------------------------------------------------------
-- Standalone copy window (slash command)
--------------------------------------------------------------------------

local function CreateCopyDialog()
  local frame = CreateFrame("Frame", "ShoppingConverterCopyDialog", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(560, 300)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  table.insert(UISpecialFrames, frame:GetName())

  frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.title:SetPoint("TOP", frame.TitleBg, "TOP", 0, -5)

  frame.status = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  frame.status:SetPoint("TOPLEFT", 14, -32)
  frame.status:SetPoint("RIGHT", -14, 0)
  frame.status:SetJustifyH("LEFT")

  local pane = CreateOutputPane(frame)
  frame.pane = pane

  pane.selectButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -50)
  pane.nextButton:SetPoint("RIGHT", pane.selectButton, "LEFT", -8, 0)
  pane.prevButton:SetPoint("RIGHT", pane.nextButton, "LEFT", -2, 0)
  pane.partLabel:SetPoint("RIGHT", pane.prevButton, "LEFT", -6, 0)

  -- Same border offset as the tab.
  pane.scrollFrame:SetPoint("TOPLEFT", 14 + BOX_BORDER_INSET, -78)
  pane.scrollFrame:SetPoint("BOTTOMRIGHT", -(14 + BOX_BORDER_INSET), 16)

  frame:SetScript("OnShow", function(self)
    self.pane:SyncEditBoxWidth()
  end)

  return frame
end

function UI:ShowCopyDialog(result, title)
  copyDialog = copyDialog or CreateCopyDialog()
  copyDialog.title:SetText(title or ADDON_NAME)

  local status, warning = DescribeResult(result)
  copyDialog.status:SetText(warning and (status .. " " .. warning) or status)

  copyDialog:Show()
  copyDialog.pane:SyncEditBoxWidth()
  copyDialog.pane:SetChunks(result.chunks)
  copyDialog.pane.editBox:SetFocus()
  copyDialog.pane.editBox:HighlightText()
end
