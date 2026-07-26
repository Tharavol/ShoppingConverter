local ADDON_NAME, ns = ...

local AHTab = {}
ns.AHTab = AHTab

local TAB_ID = "ShoppingConverterTab"

-- Tab ordering and the Auction House width fix both reach into LibAHTab's
-- private state, which carries no compatibility promise. Pinned to the minor
-- version those workarounds were written against: on a newer library we skip
-- them rather than risk erroring on a changed structure. The tab itself
-- still works, it just sits wherever the library puts it.
local SUPPORTED_LIB_MINOR = 4

local TSM_TAB_ID = "TSM_AH_TAB"
local AUCTIONATOR_SHOPPING_TAB_ID = "AuctionatorTabs_Shopping"

-- Matches LibAHTab's own retail spacing between adjacent tab buttons.
local TAB_OFFSET_X = 3

local originalAHWidth

local function GetLib()
  return LibStub("LibAHTab-1-0", true)
end

-- True when it's safe to touch the library's internals.
local function GetInternalState()
  local lib = GetLib()
  if not lib or not lib.internalState then
    return nil
  end

  local _, minor = LibStub:GetLibrary("LibAHTab-1-0", true)
  if minor and minor > SUPPORTED_LIB_MINOR then
    return nil
  end

  return lib.internalState
end

--------------------------------------------------------------------------
-- Creation
--------------------------------------------------------------------------

local function CreateTab()
  local lib = GetLib()
  if not lib or lib:DoesIDExist(TAB_ID) then
    return
  end

  lib:CreateTab(TAB_ID, ns.UI:CreateTabContent(), "Converter", "Shopping List Converter")

  -- LibAHTab resizes the tab button to fit its text with no max width,
  -- and this button template renders far wider than expected for it.
  -- Re-clamp it ourselves rather than patching the vendored library.
  local button = lib:GetButton(TAB_ID)
  if button then
    PanelTemplates_TabResize(button, 20, nil, 70, 100)
  end
end

--------------------------------------------------------------------------
-- Ordering
--
-- Other AH-tab addons (TSM, Auctionator) add their tabs off their own hooks
-- into the AH opening, in no guaranteed order relative to ours, so
-- LibAHTab's default left-to-right order (tab creation order) lands us in a
-- different spot each session. Rebuild the anchor chain so our tab always
-- sits directly between TSM's tab and Auctionator's Shopping tab, keeping
-- every other known tab in its original relative order.
--------------------------------------------------------------------------

local function PositionTab()
  local lib = GetLib()
  local internalState = GetInternalState()
  if not lib or not internalState then
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
-- Auction House width
--
-- Adding a tab can push the tab row past the right edge of the (fixed
-- width) Auction House window. Widen the window by just enough to fit it.
-- This always recomputes from the ORIGINAL width captured on first run,
-- rather than from the window's current (possibly already-widened) width,
-- so repeated calls across AH opens never compound on top of a previous
-- resize.
--------------------------------------------------------------------------

local function EnsureWidth()
  local lib = GetLib()
  local internalState = GetInternalState()
  if not lib or not internalState or not AuctionHouseFrame then
    return
  end

  if not lib:GetButton(TAB_ID) then
    return
  end

  -- Our tab is no longer necessarily the rightmost after repositioning,
  -- so measure the whole row's right edge, not just our own button.
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

-- Leaving the window wide after the player closes the Auction House affects
-- every other addon that measures or anchors to it, so hand it back.
function AHTab:RestoreAuctionHouseWidth()
  if originalAHWidth and AuctionHouseFrame then
    AuctionHouseFrame:SetWidth(originalAHWidth)
  end
end

--------------------------------------------------------------------------
-- Entry points
--------------------------------------------------------------------------

function AHTab:OnAuctionHouseShow()
  CreateTab()

  -- Deferred a frame: other addons that also add AH tabs off this same
  -- event may not have added theirs yet, and positioning or measuring the
  -- tab row before they do would miss them.
  C_Timer.After(0, function()
    PositionTab()
    EnsureWidth()
  end)
end

function AHTab:IsAvailable()
  local lib = GetLib()
  return lib ~= nil
    and AuctionHouseFrame ~= nil
    and AuctionHouseFrame:IsShown()
    and lib:DoesIDExist(TAB_ID)
end

-- Selects the Converter tab. Returns false when the Auction House isn't
-- open, so the caller can say something more useful than nothing happening.
function AHTab:SelectTab()
  if not self:IsAvailable() then
    return false
  end
  local ok = pcall(function()
    GetLib():SetSelected(TAB_ID)
  end)
  return ok
end
