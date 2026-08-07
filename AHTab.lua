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

-- Guards below silently skip the tab-ordering/width-fix workarounds rather
-- than error, per the compatibility note above. That's correct behavior,
-- but a silent skip is exactly how a tab row running off the window edge
-- can happen with no Lua error to point at. Warn once per session instead
-- so it shows up in chat.
local warnedInternalStateUnavailable = false

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
    if ns.db.settings.debug and not warnedInternalStateUnavailable then
      warnedInternalStateUnavailable = true
      ns.Print(
        "LibAHTab is running a newer version (minor %d) than this addon supports (minor %d). "
          .. "Tab ordering and auto-widening are disabled this session to avoid touching a "
          .. "changed internal structure - the Converter tab still works, but may run past "
          .. "the window edge. An update to Shopping Converter may be needed.",
        minor, SUPPORTED_LIB_MINOR)
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

-- Pure width math, pulled out of EnsureWidth so it can be unit tested
-- without a real AuctionHouseFrame. Given the original (un-widened) frame
-- width, that frame's current right edge, how far right the tab row
-- reaches, and a hard ceiling, returns the width the frame should be set
-- to. Exposed on AHTab so Tests/run.lua can exercise it directly.
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

  -- Safety net: never let the window grow past the screen, no matter what
  -- the width math below produces.
  local maxWidth = GetScreenWidth() - 40
  local newWidth = AHTab.ComputeNewWidth(
    originalAHWidth, AuctionHouseFrame:GetRight(), rowRight, maxWidth)

  AuctionHouseFrame:SetWidth(newWidth)

  -- Confirm the resize actually closed the gap. It should always, since
  -- newWidth is derived from rowRight - but the screen-width ceiling above
  -- can still leave the row hanging off the edge on a very cluttered tab
  -- bar, and a stale rowRight (measured before a sibling addon finished
  -- adding its tab) could too. Either way, that's the exact "tabs run past
  -- the window edge, no error" symptom, so surface it instead of letting
  -- it pass quietly.
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

local hookedCreateTab = false

-- Fires every time ANY addon adds a tab to the shared AH tab row, including
-- ones that show up well after the AH first opens (e.g. an addon that waits
-- on its own async data before adding its tab). A fixed-delay retry can only
-- guess how long to wait and guesses wrong some of the time, silently and
-- without a scale to warn against - reacting to the actual event that
-- changes the row's width is exact regardless of timing.
local function OnLibTabCreated(_, tabID)
  if tabID == TAB_ID then
    -- Our own creation is handled by the deferred pass below, which runs
    -- after CreateTab()'s own re-clamp of this button's width - reacting to
    -- it here would measure the row before that clamp has applied.
    return
  end

  -- Deferred a frame, same as the initial pass below: PositionTab()'s
  -- SetPoint calls don't take effect for GetRight() purposes until the next
  -- layout pass, so measuring in the same tick that just repositioned
  -- everything reads stale (too-narrow) anchors and undershoots the resize.
  C_Timer.After(0, function()
    PositionTab()
    EnsureWidth()
  end)
end

function AHTab:OnAuctionHouseShow()
  CreateTab()

  local lib = GetLib()
  if lib and not hookedCreateTab then
    hookedCreateTab = true
    hooksecurefunc(lib, "CreateTab", OnLibTabCreated)
  end

  -- Deferred a frame: other addons that also add AH tabs off this same
  -- event may not have added theirs yet, and positioning or measuring the
  -- tab row before they do would miss them. Tabs added later than this are
  -- now caught by the CreateTab hook above instead of a second guess here.
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
