local ADDON_NAME, ns = ...

local AHTab = {}
ns.AHTab = AHTab

local TAB_ID = "ShoppingConverterTab"

-- Tab ordering and the width fix reach into LibAHTab's private state. Another
-- addon's newer copy may win in LibStub, so they are gated on that state's
-- shape rather than the minor version, and skipped (with a one-time warning)
-- if it changes.

local TSM_TAB_ID = "TSM_AH_TAB"
local AUCTIONATOR_SHOPPING_TAB_ID = "AuctionatorTabs_Shopping"

-- Matches LibAHTab's own retail spacing between adjacent tab buttons.
local TAB_OFFSET_X = 3

local originalAHWidth

local warnedInternalStateUnavailable = false

local function GetLib()
  return LibStub("LibAHTab-1-0")
end

-- True when the internals still have every field PositionTab and EnsureWidth
-- use. Exposed for Tests/run.lua.
function AHTab.IsInternalStateUsable(internalState)
  return internalState ~= nil
    and internalState.Tabs ~= nil
    and internalState.rootFrame ~= nil
end

-- Returns the library's internals when it's safe to touch them. They stay
-- nil until the first tab is created.
local function GetInternalState()
  local lib = GetLib()
  if not lib.internalState then
    return nil
  end

  if not AHTab.IsInternalStateUsable(lib.internalState) then
    if not warnedInternalStateUnavailable then
      warnedInternalStateUnavailable = true
      local _, minor = LibStub:GetLibrary("LibAHTab-1-0", true)
      ns.Print(
        "LibAHTab (minor %s) has changed its internal structure. Tab ordering and "
          .. "auto-widening are disabled this session to avoid touching it - the Converter "
          .. "tab still works, but may run past the window edge. An update to Shopping "
          .. "Converter may be needed.",
        tostring(minor))
    end
    return nil
  end

  return lib.internalState
end

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

local function CreateTab()
  local lib = GetLib()
  if lib:DoesIDExist(TAB_ID) then
    return
  end

  lib:CreateTab(TAB_ID, ns.UI:CreateTabContent(), "Converter", "Shopping List Converter")

  -- LibAHTab sizes the button to its text with no max width; clamp it here
  -- rather than patching the vendored library.
  PanelTemplates_TabResize(lib:GetButton(TAB_ID), 20, nil, 70, 100)
end

--------------------------------------------------------------------------
-- Ordering: LibAHTab orders tabs by creation, which varies per session.
-- Re-anchor so ours sits between TSM's tab and Auctionator's Shopping tab,
-- keeping every other tab in its relative order.
--------------------------------------------------------------------------

local function PositionTab()
  local lib = GetLib()
  local internalState = GetInternalState()
  if not internalState then
    return
  end

  local ourButton = lib:GetButton(TAB_ID)
  if not ourButton then
    return
  end

  local tsmButton = lib:DoesIDExist(TSM_TAB_ID) and lib:GetButton(TSM_TAB_ID) or nil
  local shoppingButton = lib:DoesIDExist(AUCTIONATOR_SHOPPING_TAB_ID)
    and lib:GetButton(AUCTIONATOR_SHOPPING_TAB_ID) or nil

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
  for _, tab in ipairs(internalState.Tabs) do
    place(tab)
  end

  for i, tab in ipairs(ordered) do
    tab:ClearAllPoints()
    if i == 1 then
      tab:SetPoint("TOPLEFT", internalState.rootFrame, "TOPLEFT", TAB_OFFSET_X, 0)
    else
      tab:SetPoint("TOPLEFT", ordered[i - 1], "TOPRIGHT", TAB_OFFSET_X, 0)
    end
  end

  internalState.Tabs = ordered
end

--------------------------------------------------------------------------
-- Auction House width: widen the fixed-width window just enough to fit the
-- tab row, always from the original width so resizes never compound.
--
-- Blizzard's AH result lists size their columns once, on first show, so
-- after widening, each list's layout function is re-run to fill the new width.
--------------------------------------------------------------------------

local function RearrangeItemList(itemList)
  itemList:SetTableBuilderLayout(itemList.tableBuilderLayoutFunction)

  -- AuctionHouseBackgroundMixin.OnLoad sizes .Background to the atlas with a
  -- single TOPLEFT anchor; anchor it like the NineSlice so it stretches too.
  if itemList.Background and itemList.backgroundAtlas then
    local xOffset = itemList.backgroundXOffset or 0
    local yOffset = itemList.backgroundYOffset or 0
    itemList.Background:SetAtlas(itemList.backgroundAtlas, false)
    itemList.Background:ClearAllPoints()
    itemList.Background:SetPoint("TOPLEFT", xOffset + 3, yOffset - 3)
    itemList.Background:SetPoint("BOTTOMRIGHT")
  end
end

-- Finds every Blizzard item list in the AH frame tree by shape rather than
-- by hard-coded frame paths.
local function RearrangeItemLists(frame)
  for _, child in ipairs({ frame:GetChildren() }) do
    if type(child.SetTableBuilderLayout) == "function" and child.tableBuilderLayoutFunction then
      RearrangeItemList(child)
    end
    RearrangeItemLists(child)
  end
end

-- Debounced: tab additions arrive in bursts, each EnsureWidth() briefly
-- resets the width, and a rearrange mid-burst measures a too-narrow list.
local rearrangeGeneration = 0

local function ScheduleRearrange()
  rearrangeGeneration = rearrangeGeneration + 1
  local thisGeneration = rearrangeGeneration
  C_Timer.After(0.2, function()
    if thisGeneration == rearrangeGeneration then
      RearrangeItemLists(AuctionHouseFrame)
    end
  end)
end

-- Pure width math from EnsureWidth, exposed for Tests/run.lua.
function AHTab.ComputeNewWidth(originalWidth, frameRight, rowRight, maxWidth)
  local overflow = rowRight - frameRight
  local newWidth = originalWidth
  if overflow > 0 then
    newWidth = originalWidth + overflow + 8
  end
  if newWidth > maxWidth then
    newWidth = maxWidth
  end
  return newWidth
end

local warnedOverflow = false

local function EnsureWidth()
  local lib = GetLib()
  local internalState = GetInternalState()
  if not internalState or not AuctionHouseFrame then
    return
  end

  if not lib:GetButton(TAB_ID) then
    return
  end

  -- Measure the whole row; our tab isn't necessarily rightmost.
  local rowRight
  for _, tab in ipairs(internalState.Tabs) do
    local right = tab:GetRight()
    if right and (not rowRight or right > rowRight) then
      rowRight = right
    end
  end
  if not rowRight then
    return
  end

  originalAHWidth = originalAHWidth or AuctionHouseFrame:GetWidth()
  local previousWidth = AuctionHouseFrame:GetWidth()
  AuctionHouseFrame:SetWidth(originalAHWidth)

  -- Never grow the window past the screen.
  local maxWidth = GetScreenWidth() - 40
  local newWidth = AHTab.ComputeNewWidth(
    originalAHWidth, AuctionHouseFrame:GetRight(), rowRight, maxWidth)

  AuctionHouseFrame:SetWidth(newWidth)

  if newWidth ~= previousWidth then
    ScheduleRearrange()
  end

  -- The screen ceiling or a stale rowRight can still leave the row overflowing.
  if rowRight > AuctionHouseFrame:GetRight() + 1 then
    if ns.db.settings.debug and not warnedOverflow then
      warnedOverflow = true
      ns.Print(
        "The Auction House tab row still runs past the window edge after widening "
          .. "(row extends to %.0f, window edge at %.0f). This may self-correct as other "
          .. "addons finish adding their tabs.",
        rowRight, AuctionHouseFrame:GetRight())
    end
  else
    warnedOverflow = false
  end
end

-- Other addons measure or anchor to the window, so restore it on close.
function AHTab:RestoreAuctionHouseWidth()
  if originalAHWidth and AuctionHouseFrame then
    AuctionHouseFrame:SetWidth(originalAHWidth)
  end
end

--------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------

local hookedCreateTab = false

-- SetPoint changes don't show in GetRight() until the next layout pass, so
-- EnsureWidth is deferred a frame after PositionTab.
local function PositionAndEnsureWidth()
  PositionTab()
  C_Timer.After(0, EnsureWidth)
end

-- Fires whenever any addon adds a tab, including late async ones.
local function OnLibTabCreated(_, tabID)
  if tabID == TAB_ID then
    -- Handled by OnAuctionHouseShow's deferred pass, after CreateTab's clamp.
    return
  end

  C_Timer.After(0, PositionAndEnsureWidth)
end

function AHTab:OnAuctionHouseShow()
  CreateTab()

  if not hookedCreateTab then
    hookedCreateTab = true
    hooksecurefunc(GetLib(), "CreateTab", OnLibTabCreated)
  end

  -- Deferred so tabs other addons add off this same event are included.
  C_Timer.After(0, PositionAndEnsureWidth)
end

function AHTab:IsAvailable()
  return AuctionHouseFrame ~= nil
    and AuctionHouseFrame:IsShown()
    and GetLib():DoesIDExist(TAB_ID)
end

-- Selects the Converter tab. Returns false when the Auction House isn't open.
function AHTab:SelectTab()
  if not self:IsAvailable() then
    return false
  end
  GetLib():SetSelected(TAB_ID)
  return true
end
