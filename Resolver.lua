local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Item resolution
--
-- Turning an Auctionator search term into an itemID, cheapest source first:
--
--   1. CraftSim's live craft queue. CraftSim knows the exact itemID and
--      quality of every reagent it queued, then throws that away when it
--      writes the Auctionator shopping list as plain item *names*. Reading
--      the queue back gives us the IDs for free, synchronously.
--   2. The persistent cache from a previous conversion.
--   3. A local, synchronous client lookup, which only works for items in
--      the client's item cache.
--   4. A live Auction House browse query - correct but slow, and it
--      clobbers whatever the player had searched on the Browse tab.
--
-- Crafting-reagent quality (Auctionator's term.tier) is a separate itemID
-- per rank sharing one display name, so any name-based source has to have
-- its quality rank checked before it can be trusted.
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
  local ok, name = pcall(C_Item.GetItemNameByID, itemID)
  if ok and name and name ~= "" then
    return name
  end
  return nil
end

local function GetReagentTier(itemID)
  if not C_TradeSkillUI or not C_TradeSkillUI.GetItemReagentQualityByItemInfo then
    return nil
  end
  local ok, tier = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
  if ok then
    return tier
  end
  return nil
end

local function TierMatches(itemID, term)
  if not term.tier then
    return true
  end
  return GetReagentTier(itemID) == term.tier
end

--------------------------------------------------------------------------
-- Session-scoped miss cache
--
-- A term that a live query genuinely couldn't resolve would otherwise pay
-- for another full browse query - plus the pacing delay - every time it's
-- seen again in the same session. Not persisted to ns.Cache: unlike a
-- successful resolution, a miss isn't stable for the life of a game build.
-- It can mean "no such item" or merely "nobody is selling one right now",
-- and persisting the latter would permanently poison the cache for an item
-- that's fine.
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

local function IndexItem(index, item, tier)
  if type(item) ~= "table" or not item.GetItemID then
    return
  end

  local ok, itemID = pcall(item.GetItemID, item)
  if not ok or not itemID then
    return
  end

  local name
  if item.GetItemName then
    local okName, value = pcall(item.GetItemName, item)
    if okName then
      name = value
    end
  end
  if not name or name == "" then
    name = GetItemName(itemID)
  end
  if not name or name == "" then
    return
  end

  index[BuildKey(name, tier)] = itemID
end

-- Mirrors the traversal CraftSim itself uses to build its shopping list
-- (CraftSim.CRAFTQ.CreateAuctionatorShoppingList), so the names we index
-- are exactly the names that ended up in the list. Deliberately does *not*
-- reimplement CraftSim's inventory subtraction or soulbound substitution -
-- quantities and item selection still come from the Auctionator list, and
-- this is only ever used as a name -> itemID oracle.
--
-- Entirely best-effort: CraftSim exposes no stable API for the queue, so
-- any structural change just means we fall through to the slower sources.
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
              local okID, itemID = pcall(optionalReagent.item.GetItemID, optionalReagent.item)
              IndexItem(index, optionalReagent.item, okID and itemID and GetReagentTier(itemID) or nil)
            end
          end
        end

        local slot = reagentData.requiredSelectableReagentSlot
        if slot and slot.activeReagent and slot.activeReagent.item then
          local item = slot.activeReagent.item
          local okID, itemID = pcall(item.GetItemID, item)
          IndexItem(index, item, okID and itemID and GetReagentTier(itemID) or nil)
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
  -- CraftSim keyed this itself, but verify anyway: the index is built from
  -- another addon's internals and a mismatch here would be silent.
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
  -- GetItemInfoInstant does its own name matching, which is not necessarily
  -- the exact match the term asked for.
  if term.isExact and not NamesMatch(GetItemName(itemID), term.searchString) then
    return nil
  end
  return itemID
end

--------------------------------------------------------------------------
-- Source 4: live Auction House browse query
--------------------------------------------------------------------------

-- Bumped by Abort(); every asynchronous continuation checks it before doing
-- anything, so an aborted conversion can't resurrect itself.
local generation = 0

-- Only one browse query may be in flight at a time: the Auction House has a
-- single shared result set with no way to tell which query produced it.
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
  -- Trampoline so a long queue doesn't build an equally long call stack.
  C_Timer.After(0, nextFn)
end

local function IsAuctionHouseAvailable()
  return C_AuctionHouse ~= nil
    and C_AuctionHouse.SendBrowseQuery ~= nil
    and AuctionHouseFrame ~= nil
    and AuctionHouseFrame:IsShown()
end

local function ItemKeyName(itemKey)
  if C_AuctionHouse.GetItemKeyInfo then
    local ok, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
    if ok and info and info.itemName then
      return info.itemName
    end
  end
  return GetItemName(itemKey.itemID)
end

-- Browse queries match on substring, so "Ironclaw Ore" also returns
-- "Ironclaw Ore Fragment". Returns the exact-name match if there is one,
-- plus the best substring match as a separate value - the caller may only
-- fall back to the latter once the result set is known to be complete, and
-- never for a term Auctionator flagged as exact.
local function PickMatch(term)
  local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
  if not ok then
    return nil, nil
  end

  local substringMatch
  for _, browseResult in ipairs(results or {}) do
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

  -- The throttle is a hard server-side gate; sending anyway throws, which
  -- would otherwise be swallowed and misreported as "item not found".
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
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

-- One frame for every query, not one per query: frames are never garbage
-- collected, and a cold conversion of a large list would otherwise leak one
-- per item. Safe to share because the lock guarantees a single query owns it
-- at a time, including while a timed-out query drains.
local queryFrame = CreateFrame("Frame")

-- Calls callback(itemID or nil) exactly once.
local function ResolveLive(term, callback)
  if not IsAuctionHouseAvailable() then
    callback(nil)
    return
  end

  -- Captured before queuing: by the time the lock is granted the conversion
  -- that asked for this may have been aborted.
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

    -- On timeout the caller is unblocked immediately, but the lock is held
    -- until the Auction House actually finishes with the abandoned query.
    -- Releasing straight away would let the next query start while the old
    -- one is still in flight, and the shared result set gives no way to
    -- tell the two apart. (Exact-name checking in PickMatch means stale
    -- results would be rejected rather than misused, but not overlapping in
    -- the first place is cheaper than relying on that.)
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

      local ok, complete = pcall(C_AuctionHouse.HasFullBrowseResults)
      if ok and complete then
        -- Nothing matched the name exactly. A substring hit is only what
        -- the player asked for if they didn't ask for an exact match.
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

-- Rebuilds the per-conversion CraftSim index. Cheap, and the craft queue
-- changes whenever the player queues or crafts something.
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

-- True when resolving this term would need a live Auction House query, i.e.
-- when it is going to be slow. Lets the caller decide whether to show
-- progress, and whether a conversion is worth starting at all. False when
-- the Auction House isn't open: no query could be sent regardless of what
-- the cheap sources find, so there's nothing to pace or show progress for.
function Resolver:NeedsLiveQuery(term)
  return IsAuctionHouseAvailable()
    and not IsKnownMiss(term)
    and ResolveFromCraftSim(term) == nil
    and ns.Cache:Get(term.searchString, term.tier) == nil
    and ResolveLocally(term) == nil
end

-- Calls callback(itemID or nil, source) exactly once. `source` is one of
-- "craftsim", "cache", "local", "live", "closed" or "none". "closed" means
-- the Auction House wasn't open to query, as distinct from "none", which
-- means it was queried and came up empty.
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
