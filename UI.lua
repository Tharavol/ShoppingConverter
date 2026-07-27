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
-- Output pane
--
-- A copyable text box plus the paging controls for lists too long to fit in
-- one TSM search. Shared by the Auction House tab and the standalone window
-- the slash command opens.
--------------------------------------------------------------------------

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
  -- Never steal focus on its own: the Auction House tab is shown as a side
  -- effect of clicking a tab, and an auto-focused edit box swallows the
  -- movement keys until the player thinks to press Escape.
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  scrollFrame.CharCount:Hide()

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
  if result.unresolved > 0 then
    table.insert(warnings, ("%d matched by name only - no item ID found, so quality rank may be wrong")
      :format(result.unresolved))
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
        -- Unlike the tab opening, the player asked for this: the string is
        -- now ready and copying it is the whole point, so grab focus and
        -- select it instead of waiting on the Select All button.
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
  frame:SetPoint("BOTTOMRIGHT", -4, 27)

  local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  label:SetPoint("TOPLEFT", 16, -16)
  label:SetText("Shopping List")

  dropdown = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
  dropdown:SetSize(240, 26)
  -- The generator runs every time the menu opens, so lists added or removed
  -- while the tab sits open show up without needing a refresh.
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

  statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  statusText:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 0, -10)
  statusText:SetPoint("RIGHT", -16, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetText("")

  warningText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  warningText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -4)
  warningText:SetPoint("RIGHT", -16, 0)
  warningText:SetJustifyH("LEFT")
  warningText:SetText("")

  local outputLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  outputLabel:SetPoint("TOPLEFT", warningText, "BOTTOMLEFT", 0, -12)
  outputLabel:SetText("TSM Search String")

  local pane = CreateOutputPane(frame)
  frame.pane = pane

  pane.selectButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -16)
  pane.nextButton:SetPoint("RIGHT", pane.selectButton, "LEFT", -8, 0)
  pane.prevButton:SetPoint("RIGHT", pane.nextButton, "LEFT", -2, 0)
  pane.partLabel:SetPoint("RIGHT", pane.prevButton, "LEFT", -6, 0)

  pane.scrollFrame:SetPoint("TOPLEFT", outputLabel, "BOTTOMLEFT", 8, -8)
  pane.scrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

  local versionText = frame:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  versionText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 4)
  versionText:SetText("v" .. ns.VERSION)

  frame:SetScript("OnShow", function()
    -- Only safe to read the scroll frame's real width once it (and its
    -- ancestors) have actually been laid out, which is guaranteed by the
    -- time this tab is shown. Setting it earlier, at creation time, can
    -- read a bogus pre-layout size and leave the box far too wide.
    pane.editBox:SetWidth(pane.scrollFrame:GetWidth())
    UI:Refresh()
  end)

  frame:SetScript("OnHide", function()
    -- Leaving the tab mid-conversion used to leave live Auction House
    -- queries running, competing with whatever the player did next.
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

  pane.scrollFrame:SetPoint("TOPLEFT", 18, -78)
  pane.scrollFrame:SetPoint("BOTTOMRIGHT", -32, 16)

  frame:SetScript("OnShow", function(self)
    self.pane.editBox:SetWidth(self.pane.scrollFrame:GetWidth())
  end)

  return frame
end

function UI:ShowCopyDialog(result, title)
  copyDialog = copyDialog or CreateCopyDialog()
  copyDialog.title:SetText(title or ADDON_NAME)

  local status, warning = DescribeResult(result)
  copyDialog.status:SetText(warning and (status .. " " .. warning) or status)

  copyDialog:Show()
  copyDialog.pane.editBox:SetWidth(copyDialog.pane.scrollFrame:GetWidth())
  copyDialog.pane:SetChunks(result.chunks)
  copyDialog.pane.editBox:SetFocus()
  copyDialog.pane.editBox:HighlightText()
end
