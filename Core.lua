local ADDON_NAME = ...

local API_CALLER_ID = ADDON_NAME
local TAB_ID = "ShoppingConverterTab"
local DEFAULT_LIST_NAME = "CraftSim CraftQueue"

local IsAddOnLoadedCompat = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded

ShoppingConverterDB = ShoppingConverterDB or {}

--------------------------------------------------------------------------
-- Auctionator shopping list -> TSM search string conversion
--------------------------------------------------------------------------

-- Crafting-reagent quality (Auctionator's term.tier) is normally a
-- separate itemID per rank that shares the same display name, so a
-- name lookup alone can't tell which rank is meant, and can silently
-- resolve to the wrong one. Only trust a local, synchronous lookup
-- when there's no tier requirement, or the resolved item's own tier
-- actually matches what was asked for.
local function TryLocalResolve(term)
  local itemID = C_Item.GetItemInfoInstant(term.searchString)
  if not itemID then
    return nil
  end
  if term.tier and C_TradeSkillUI and C_TradeSkillUI.GetItemReagentQualityByItemInfo then
    local ok, actualTier = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
    if not ok or actualTier ~= term.tier then
      return nil
    end
  end
  return itemID
end

-- Serializes all live Auction House browse queries (across overlapping
-- calls too) so we never have two in flight at once, which would let
-- one query's results be misread as another's.
local ahQueryBusy = false
local function WithAHQueryLock(fn)
  local function tryStart()
    if ahQueryBusy then
      C_Timer.After(0.2, tryStart)
      return
    end
    ahQueryBusy = true
    fn(function()
      ahQueryBusy = false
    end)
  end
  tryStart()
end

-- Resolves a search term to an itemID via a live Auction House browse
-- query, which works even for items the client hasn't cached locally,
-- and (when term.tier is set) picks the specific quality-rank itemID
-- rather than trusting a possibly-ambiguous name match. Calls
-- callback(itemID or nil) exactly once.
local function LiveResolve(term, callback)
  WithAHQueryLock(function(releaseLock)
    local queryFrame = CreateFrame("Frame")
    local done = false

    local function Finish(itemID)
      if done then return end
      done = true
      queryFrame:SetScript("OnEvent", nil)
      queryFrame:UnregisterAllEvents()
      releaseLock()
      callback(itemID)
    end

    -- Scheduled before anything below that could throw, so the shared
    -- query lock is *always* eventually released no matter what.
    C_Timer.After(5, function() Finish(nil) end)

    local setupOk = pcall(function()
      local function PickMatch(results)
        for _, browseResult in ipairs(results or {}) do
          local itemID = browseResult.itemKey and browseResult.itemKey.itemID
          if itemID then
            if not term.tier then
              return itemID
            end
            local ok, actualTier = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
            if ok and actualTier == term.tier then
              return itemID
            end
          end
        end
        return nil
      end

      queryFrame:SetScript("OnEvent", function(_, eventName, ...)
        if eventName == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
          local itemID = PickMatch(...)
          if itemID then
            Finish(itemID)
          end
        elseif eventName == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
          local itemID = PickMatch(C_AuctionHouse.GetBrowseResults())
          if itemID or C_AuctionHouse.HasFullBrowseResults() then
            Finish(itemID)
          end
        elseif eventName == "AUCTION_HOUSE_BROWSE_FAILURE" then
          Finish(nil)
        end
      end)

      queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
      queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
      queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")

      C_AuctionHouse.SendBrowseQuery({
        searchString = term.searchString,
        filters = {},
        itemClassFilters = {},
        sorts = {},
      })
    end)

    if not setupOk then
      Finish(nil)
    end
  end)
end

-- Builds a TSM-compatible "i:<id>[/x<qty>];..." string from the named
-- Auctionator shopping list, resolving item IDs locally where safe and
-- falling back to a live AH query where a quality rank needs picking
-- out or the item isn't cached locally. Calls
-- onComplete(tsmString, totalCount, resolvedWithIDCount, nameOnlyCount)
-- exactly once. onProgress(index, total), if given, is called before
-- each item that needs a live lookup.
local currentBuildGeneration = 0
local function BuildTSMStringAsync(listName, onComplete, onProgress)
  currentBuildGeneration = currentBuildGeneration + 1
  local generation = currentBuildGeneration

  if not listName or not Auctionator or not Auctionator.API or not Auctionator.API.v1 then
    onComplete("", 0, 0, 0)
    return
  end

  local ok, items = pcall(Auctionator.API.v1.GetShoppingListItems, API_CALLER_ID, listName)
  if not ok or not items then
    onComplete("", 0, 0, 0)
    return
  end

  local terms = {}
  for _, rawSearchString in ipairs(items) do
    local okTerm, term = pcall(Auctionator.API.v1.ConvertFromSearchString, API_CALLER_ID, rawSearchString)
    if okTerm and term and term.searchString and term.searchString ~= "" then
      table.insert(terms, term)
    end
  end

  local parts = {}
  local resolvedByID = 0
  local resolvedLive = 0
  local nameOnly = 0

  local function AppendPart(term, itemID)
    local part = itemID and ("i:" .. itemID) or term.searchString
    if term.quantity and term.quantity > 0 then
      part = part .. "/x" .. term.quantity
    end
    table.insert(parts, part)
  end

  local index = 0
  local function ProcessNext()
    if generation ~= currentBuildGeneration then return end

    index = index + 1
    local term = terms[index]
    if not term then
      onComplete(table.concat(parts, ";"), #terms, resolvedByID + resolvedLive, nameOnly)
      return
    end

    local localID = TryLocalResolve(term)
    if localID then
      resolvedByID = resolvedByID + 1
      AppendPart(term, localID)
      ProcessNext()
      return
    end

    if onProgress then
      onProgress(index, #terms)
    end

    LiveResolve(term, function(itemID)
      if generation ~= currentBuildGeneration then return end
      if itemID then
        resolvedLive = resolvedLive + 1
      else
        nameOnly = nameOnly + 1
      end
      AppendPart(term, itemID)
      -- A courtesy delay between successive AH queries.
      C_Timer.After(0.6, ProcessNext)
    end)
  end

  ProcessNext()
end

local function GetShoppingListNames()
  local names = {}
  if Auctionator and Auctionator.Shopping and Auctionator.Shopping.ListManager then
    local ok, count = pcall(function() return Auctionator.Shopping.ListManager:GetCount() end)
    if ok and count then
      for i = 1, count do
        local okList, list = pcall(function() return Auctionator.Shopping.ListManager:GetByIndex(i) end)
        if okList and list then
          table.insert(names, list:GetName())
        end
      end
    end
  end
  return names
end

--------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------

local tabContent
local dropdown
local editBox
local statusText
local selectedList

local function UpdateOutput()
  if not editBox then return end

  if not IsAddOnLoadedCompat("Auctionator") then
    editBox:SetText("")
    statusText:SetText("Auctionator is not loaded.")
    return
  end

  local names = GetShoppingListNames()

  if not selectedList or not tContains(names, selectedList) then
    selectedList = ShoppingConverterDB.lastList
    if not selectedList or not tContains(names, selectedList) then
      selectedList = tContains(names, DEFAULT_LIST_NAME) and DEFAULT_LIST_NAME or names[1]
    end
  end

  UIDropDownMenu_SetText(dropdown, selectedList or "No shopping lists")

  if not selectedList then
    editBox:SetText("")
    statusText:SetText("No Auctionator shopping lists found.")
    return
  end

  ShoppingConverterDB.lastList = selectedList

  statusText:SetText("Converting...")

  BuildTSMStringAsync(
    selectedList,
    function(tsmString, total, resolvedWithID, nameOnly)
      editBox:SetText(tsmString)
      if editBox:IsShown() then
        editBox:SetFocus()
      end
      editBox:HighlightText()

      if total == 0 then
        statusText:SetText(("\"%s\" is empty."):format(selectedList))
      elseif nameOnly > 0 then
        statusText:SetText(("%d item(s) converted (%d matched by name only, no item ID found)."):format(total, nameOnly))
      else
        statusText:SetText(("%d item(s) converted."):format(total))
      end
    end,
    function(index, total)
      statusText:SetText(("Resolving item %d of %d..."):format(index, total))
    end
  )
end

local function InitializeDropdown(self, level)
  local names = GetShoppingListNames()
  for _, name in ipairs(names) do
    local info = UIDropDownMenu_CreateInfo()
    info.text = name
    info.checked = (name == selectedList)
    info.func = function()
      selectedList = name
      ShoppingConverterDB.lastList = name
      UpdateOutput()
    end
    UIDropDownMenu_AddButton(info, level)
  end
end

local function CreateTabContent()
  local frame = CreateFrame("Frame", "ShoppingConverterTabFrame", AuctionHouseFrame)
  frame:SetPoint("TOP", 0, -40)
  frame:SetPoint("LEFT")
  frame:SetPoint("BOTTOMRIGHT", -4, 27)

  local label = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  label:SetPoint("TOPLEFT", 16, -16)
  label:SetText("Shopping List")

  dropdown = CreateFrame("Frame", "ShoppingConverterListDropdown", frame, "UIDropDownMenuTemplate")
  dropdown:SetPoint("TOPLEFT", label, "BOTTOMLEFT", -16, -4)
  UIDropDownMenu_SetWidth(dropdown, 220)
  UIDropDownMenu_Initialize(dropdown, InitializeDropdown)

  local refreshButton = CreateFrame("Button", "ShoppingConverterRefreshButton", frame, "UIPanelButtonTemplate")
  refreshButton:SetSize(90, 22)
  refreshButton:SetText("Refresh")
  refreshButton:SetPoint("LEFT", dropdown, "RIGHT", 24, 2)
  refreshButton:SetScript("OnClick", function()
    UpdateOutput()
  end)

  statusText = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  statusText:SetPoint("TOPLEFT", dropdown, "BOTTOMLEFT", 16, -8)
  statusText:SetPoint("RIGHT", -16, 0)
  statusText:SetJustifyH("LEFT")
  statusText:SetText("")

  local outputLabel = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  outputLabel:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -12)
  outputLabel:SetText("TSM Search String (select all and copy)")

  local scrollFrame = CreateFrame("ScrollFrame", "ShoppingConverterOutputScroll", frame, "InputScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", outputLabel, "BOTTOMLEFT", 8, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", -30, 16)

  editBox = scrollFrame.EditBox
  editBox:SetMultiLine(true)
  editBox:SetMaxLetters(0)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  editBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
  scrollFrame.CharCount:Hide()

  frame:SetScript("OnShow", function()
    -- Only safe to read the scroll frame's real width once it (and its
    -- ancestors) have actually been laid out, which is guaranteed by the
    -- time this tab is shown. Setting it earlier, at creation time, can
    -- read a bogus pre-layout size and leave the box far too wide.
    editBox:SetWidth(scrollFrame:GetWidth())
    UpdateOutput()
  end)

  return frame
end

--------------------------------------------------------------------------
-- Tab registration
--------------------------------------------------------------------------

local function CreateShoppingConverterTab()
  local LibAHTab = LibStub("LibAHTab-1-0")
  if LibAHTab:DoesIDExist(TAB_ID) then return end

  tabContent = CreateTabContent()
  LibAHTab:CreateTab(TAB_ID, tabContent, "Converter", "Shopping List Converter")

  -- LibAHTab resizes the tab button to fit its text with no max width,
  -- and this button template renders far wider than expected for it.
  -- Re-clamp it ourselves rather than patching the vendored library.
  local button = LibAHTab:GetButton(TAB_ID)
  if button then
    PanelTemplates_TabResize(button, 20, nil, 70, 100)
  end
end

-- Other AH-tab addons (TSM, Auctionator) add their tabs off their own
-- hooks into the AH opening, in no guaranteed order relative to ours, so
-- LibAHTab's default left-to-right order (tab creation order) lands us
-- in a different spot each session. Rebuild the anchor chain so our tab
-- always sits directly between TSM's tab and Auctionator's Shopping tab,
-- keeping every other known tab in its original relative order.
local TSM_TAB_ID = "TSM_AH_TAB"
local AUCTIONATOR_SHOPPING_TAB_ID = "AuctionatorTabs_Shopping"
local TAB_OFFSET_X = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE) and 3 or -14

local function PositionShoppingConverterTab()
  local LibAHTab = LibStub("LibAHTab-1-0")
  local ourButton = LibAHTab:GetButton(TAB_ID)
  if not ourButton or not LibAHTab.internalState then return end

  local tsmButton = LibAHTab:DoesIDExist(TSM_TAB_ID) and LibAHTab:GetButton(TSM_TAB_ID) or nil
  local shoppingButton = LibAHTab:DoesIDExist(AUCTIONATOR_SHOPPING_TAB_ID) and LibAHTab:GetButton(AUCTIONATOR_SHOPPING_TAB_ID) or nil

  local ordered, placed = {}, {}
  local function place(button)
    if button and not placed[button] then
      table.insert(ordered, button)
      placed[button] = true
    end
  end

  place(tsmButton)
  place(ourButton)
  place(shoppingButton)
  for _, tab in ipairs(LibAHTab.internalState.Tabs) do
    place(tab)
  end

  for i, tab in ipairs(ordered) do
    tab:ClearAllPoints()
    if i == 1 then
      tab:SetPoint("TOPLEFT", LibAHTab.internalState.rootFrame, "TOPLEFT", TAB_OFFSET_X, 0)
    else
      tab:SetPoint("TOPLEFT", ordered[i - 1], "TOPRIGHT", TAB_OFFSET_X, 0)
    end
  end

  LibAHTab.internalState.Tabs = ordered
end

-- Adding a tab can push the tab row past the right edge of the (fixed
-- width) Auction House window. Widen the window by just enough to fit it.
-- This always recomputes from the ORIGINAL width captured on first run,
-- rather than from the window's current (possibly already-widened)
-- width, so repeated calls across AH opens never compound on top of a
-- previous resize.
local originalAHWidth

local function EnsureAuctionHouseWidth()
  local LibAHTab = LibStub("LibAHTab-1-0")
  local button = LibAHTab:GetButton(TAB_ID)
  if not button or not LibAHTab.internalState then return end

  -- Our tab is no longer necessarily the rightmost after repositioning,
  -- so measure the whole row's right edge, not just our own button.
  local rowRight
  for _, tab in ipairs(LibAHTab.internalState.Tabs) do
    local right = tab:GetRight()
    if right and (not rowRight or right > rowRight) then
      rowRight = right
    end
  end
  if not rowRight then return end

  originalAHWidth = originalAHWidth or AuctionHouseFrame:GetWidth()
  AuctionHouseFrame:SetWidth(originalAHWidth)

  local overflow = rowRight - AuctionHouseFrame:GetRight()
  local newWidth = originalAHWidth
  if overflow > 0 then
    newWidth = originalAHWidth + overflow + 8
  end

  -- Safety net: never let the window grow past the screen, no matter
  -- what the above math produces.
  local maxWidth = GetScreenWidth() - 40
  if newWidth > maxWidth then
    newWidth = maxWidth
  end

  AuctionHouseFrame:SetWidth(newWidth)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:SetScript("OnEvent", function(_, _, panelType)
  if panelType == Enum.PlayerInteractionType.Auctioneer then
    CreateShoppingConverterTab()
    -- Deferred a frame: other addons that also add AH tabs off this
    -- same event may not have added theirs yet, and positioning or
    -- measuring the tab row before they do would miss them.
    C_Timer.After(0, function()
      PositionShoppingConverterTab()
      EnsureAuctionHouseWidth()
    end)
  end
end)
