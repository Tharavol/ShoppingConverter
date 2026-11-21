local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Item resolution
--
-- Auctionator search term -> itemID, cheapest source first:
--   1. CraftSim's craft queue (it writes the list as names but knows the IDs).
--   2. The persistent cache.
--   3. A local client lookup (items in the client's item cache only).
--   4. A live Auction House browse query (slow; clobbers the Browse tab).
-- Each reagent quality rank is its own itemID with the same name, so
-- name-based sources must check term.tier.
--------------------------------------------------------------------------

local Resolver = {}
ns.Resolver = Resolver

local LIVE_QUERY_TIMEOUT = 5
local LIVE_DRAIN_TIMEOUT = 3
local THROTTLE_RETRY_DELAY = 0.5
local MAX_THROTTLE_RETRIES = 10

local SEPARATOR = "\30"

local function BuildKey(name, tier)
  return (name or ""):lower() .. SEPARATOR .. tostring(tier or 0)
end

--------------------------------------------------------------------------
-- Name and quality checks
--------------------------------------------------------------------------

local function NormalizeName(name)
  if type(name) ~= "string" then
    return nil
  end
  -- Auctionator stores exact searches wrapped in quotes and strips them on
  -- the way out, but hand-entered terms can still carry them.
  name = name:gsub('^"(.*)"$', "%1")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return nil
  end
  return name:lower()
end

local function NamesMatch(candidate, wanted)
  local a, b = NormalizeName(candidate), NormalizeName(wanted)
  return a ~= nil and a == b
end

local function GetItemName(itemID)
  local name = C_Item.GetItemNameByID(itemID)
  if name and name ~= "" then
    return name
  end
  return nil
end

local function GetReagentTier(itemID)
  return C_TradeSkillUI.GetItemReagentQualityByItemInfo(itemID)
end

local function TierMatches(itemID, term)
  if not term.tier then
    return true
  end
  return GetReagentTier(itemID) == term.tier
end

--------------------------------------------------------------------------
-- Session-scoped miss cache: skips repeat live queries for a term that
-- already missed. Not persisted, since a miss may only mean nobody is
-- selling the item right now.
--------------------------------------------------------------------------

local missIndex = {}

local function IsKnownMiss(term)
  return missIndex[BuildKey(term.searchString, term.tier)] == true
end

local function MarkMiss(term)
  missIndex[BuildKey(term.searchString, term.tier)] = true
end

--------------------------------------------------------------------------
-- Source 1: CraftSim's craft queue
--------------------------------------------------------------------------

local craftSimIndex = {}

-- `item` is a Blizzard ItemMixin taken from CraftSim's reagent data.
local function IndexItem(index, item, tier)
  if type(item) ~= "table" or not item.GetItemID then
    return
  end

  local itemID = item:GetItemID()
  if not itemID then
    return
  end

  local name = item:GetItemName()
  if not name or name == "" then
    name = GetItemName(itemID)
  end
  if not name or name == "" then
    return
  end

  index[BuildKey(name, tier)] = itemID
end

-- Mirrors CraftSim.CRAFTQ.CreateAuctionatorShoppingList's traversal so the
-- indexed names match the list; used only as a name -> itemID lookup.
-- CraftSim has no stable API for the queue, so the whole walk is guarded:
-- a structural change just falls through to the slower sources.
local function BuildCraftSimIndex()
  local index = {}

  if not ns.db.settings.useCraftSim then
    return index
  end

  pcall(function()
    local queue = CraftSim and CraftSim.CRAFTQ and CraftSim.CRAFTQ.craftQueue
    if not queue or not queue.craftQueueItems then
      return
    end

    for _, craftQueueItem in pairs(queue.craftQueueItems) do
      local recipeData = craftQueueItem.recipeData
      local reagentData = recipeData and recipeData.reagentData

      if reagentData then
        for _, reagent in pairs(reagentData.requiredReagents or {}) do
          for qualityID, reagentItem in pairs(reagent.items or {}) do
            IndexItem(index, reagentItem.item, reagent.hasQuality and qualityID or nil)
          end
        end

        if reagentData.GetActiveOptionalReagents then
          for _, optionalReagent in pairs(reagentData:GetActiveOptionalReagents() or {}) do
            if optionalReagent.item and not (optionalReagent.IsCurrency and optionalReagent:IsCurrency()) then
              local itemID = optionalReagent.item:GetItemID()
              IndexItem(index, optionalReagent.item, itemID and GetReagentTier(itemID) or nil)
            end
          end
        end

        local slot = reagentData.requiredSelectableReagentSlot
        if slot and slot.activeReagent and slot.activeReagent.item then
          local item = slot.activeReagent.item
          local itemID = item:GetItemID()
          IndexItem(index, item, itemID and GetReagentTier(itemID) or nil)
        end
      end
    end
  end)

  return index
end

local function ResolveFromCraftSim(term)
  local itemID = craftSimIndex[BuildKey(term.searchString, term.tier)]
  if not itemID then
    return nil
  end
  -- Verified because the index comes from another addon's internals.
  if not TierMatches(itemID, term) then
    return nil
  end
  return itemID
end

--------------------------------------------------------------------------
-- Source 3: local synchronous lookup
--------------------------------------------------------------------------

local function ResolveLocally(term)
  local itemID = C_Item.GetItemInfoInstant(term.searchString)
  if not itemID then
    return nil
  end
  if not TierMatches(itemID, term) then
    return nil
  end
  -- GetItemInfoInstant's name matching is not necessarily exact.
  if term.isExact and not NamesMatch(GetItemName(itemID), term.searchString) then
    return nil
  end
  return itemID
end

--------------------------------------------------------------------------
-- Source 4: live Auction House browse query
--------------------------------------------------------------------------

-- Bumped by Abort(); every asynchronous continuation checks it first.
local generation = 0

-- One browse query at a time: the AH has a single shared result set.
local lockHeld = false
local waiting = {}

local function AcquireLock(fn)
  if lockHeld then
    table.insert(waiting, fn)
    return
  end
  lockHeld = true
  fn()
end

local function ReleaseLock()
  local nextFn = table.remove(waiting, 1)
  if not nextFn then
    lockHeld = false
    return
  end
  -- Trampoline so a long queue doesn't grow the call stack.
  C_Timer.After(0, nextFn)
end

-- AuctionHouseFrame is load-on-demand.
local function IsAuctionHouseAvailable()
  return AuctionHouseFrame ~= nil and AuctionHouseFrame:IsShown()
end

local function ItemKeyName(itemKey)
  local info = C_AuctionHouse.GetItemKeyInfo(itemKey)
  if info and info.itemName then
    return info.itemName
  end
  return GetItemName(itemKey.itemID)
end

-- Browse queries match on substring ("Ironclaw Ore" also finds "Ironclaw Ore
-- Fragment"). Returns the exact-name match, plus the first substring match,
-- which the caller uses only once results are complete and the term is not exact.
local function PickMatch(term)
  local substringMatch
  for _, browseResult in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    local itemID = browseResult.itemKey and browseResult.itemKey.itemID
    if itemID and TierMatches(itemID, term) then
      if NamesMatch(ItemKeyName(browseResult.itemKey), term.searchString) then
        return itemID, substringMatch
      elseif not substringMatch then
        substringMatch = itemID
      end
    end
  end

  return nil, substringMatch
end

local function SendBrowseQuery(term, attempt, onFailure)
  if not IsAuctionHouseAvailable() then
    onFailure()
    return
  end

  -- Sending while throttled throws, so wait for the throttle first.
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    if attempt >= MAX_THROTTLE_RETRIES then
      onFailure()
      return
    end
    local myGeneration = generation
    C_Timer.After(THROTTLE_RETRY_DELAY, function()
      if myGeneration ~= generation then
        onFailure()
        return
      end
      SendBrowseQuery(term, attempt + 1, onFailure)
    end)
    return
  end

  local ok = pcall(C_AuctionHouse.SendBrowseQuery, {
    searchString = term.searchString,
    filters = {},
    itemClassFilters = {},
    sorts = {},
  })

  if not ok then
    onFailure()
  end
end

-- One shared frame for all queries; the lock gives it a single owner. Parented
-- because an anonymous, parentless frame can be collected and stop getting events.
local queryFrame = CreateFrame("Frame", nil, UIParent)

-- Calls callback(itemID or nil) exactly once.
local function ResolveLive(term, callback)
  if not IsAuctionHouseAvailable() then
    callback(nil)
    return
  end

  -- Captured before queuing: the conversion may be aborted while waiting.
  local myGeneration = generation

  AcquireLock(function()
    if myGeneration ~= generation then
      callback(nil)
      ReleaseLock()
      return
    end

    local delivered = false
    local released = false

    local function Cleanup()
      queryFrame:SetScript("OnEvent", nil)
      queryFrame:UnregisterAllEvents()
    end

    local function Release()
      if released then return end
      released = true
      Cleanup()
      ReleaseLock()
    end

    local function Deliver(itemID)
      if delivered then return end
      delivered = true
      callback(itemID)
    end

    local function Settle(itemID)
      Deliver(itemID)
      Release()
    end

    -- On timeout the caller is unblocked, but the lock is held until the
    -- abandoned query finishes so two queries never share the result set.
    local function Drain()
      Deliver(nil)
      if released then return end
      queryFrame:SetScript("OnEvent", Release)
      C_Timer.After(LIVE_DRAIN_TIMEOUT, Release)
    end

    C_Timer.After(LIVE_QUERY_TIMEOUT, Drain)

    queryFrame:SetScript("OnEvent", function(_, eventName)
      if myGeneration ~= generation then
        Settle(nil)
        return
      end

      if eventName == "AUCTION_HOUSE_BROWSE_FAILURE" then
        Settle(nil)
        return
      end

      local exactMatch, substringMatch = PickMatch(term)
      if exactMatch then
        Settle(exactMatch)
        return
      end

      if C_AuctionHouse.HasFullBrowseResults() then
        -- No exact name match; a substring hit only counts for non-exact terms.
        Settle(not term.isExact and substringMatch or nil)
      end
    end)

    queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    queryFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_FAILURE")

    SendBrowseQuery(term, 1, function()
      Settle(nil)
    end)
  end)
end

--------------------------------------------------------------------------
-- Public interface
--------------------------------------------------------------------------

-- Rebuilds the CraftSim index; the craft queue changes between conversions.
function Resolver:BeginSession()
  craftSimIndex = BuildCraftSimIndex()
  missIndex = {}
end

function Resolver:CraftSimIndexSize()
  local count = 0
  for _ in pairs(craftSimIndex) do
    count = count + 1
  end
  return count
end

-- True when this term would need a (slow) live AH query. False when the AH
-- isn't open, since no query could be sent.
function Resolver:NeedsLiveQuery(term)
  return IsAuctionHouseAvailable()
    and not IsKnownMiss(term)
    and ResolveFromCraftSim(term) == nil
    and ns.Cache:Get(term.searchString, term.tier) == nil
    and ResolveLocally(term) == nil
end

-- Calls callback(itemID or nil, source) exactly once. `source` is one of
-- "craftsim", "cache", "local", "live", "closed" (AH not open) or "none".
function Resolver:Resolve(term, callback)
  local itemID = ResolveFromCraftSim(term)
  if itemID then
    ns.Cache:Set(term.searchString, term.tier, itemID)
    callback(itemID, "craftsim")
    return
  end

  itemID = ns.Cache:Get(term.searchString, term.tier)
  if itemID then
    callback(itemID, "cache")
    return
  end

  itemID = ResolveLocally(term)
  if itemID then
    ns.Cache:Set(term.searchString, term.tier, itemID)
    callback(itemID, "local")
    return
  end

  if not IsAuctionHouseAvailable() then
    callback(nil, "closed")
    return
  end

  if IsKnownMiss(term) then
    callback(nil, "none")
    return
  end

  local myGeneration = generation
  ResolveLive(term, function(liveID)
    if myGeneration ~= generation then
      return
    end
    if liveID then
      ns.Cache:Set(term.searchString, term.tier, liveID)
      callback(liveID, "live")
    else
      MarkMiss(term)
      callback(nil, "none")
    end
  end)
end

-- Invalidates every in-flight resolution. Pending callbacks are dropped, so
-- callers must not rely on being called back after this.
function Resolver:Abort()
  generation = generation + 1
  wipe(waiting)
end

function Resolver:GetGeneration()
  return generation
end
