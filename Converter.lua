local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Auctionator shopping list -> TSM search string
--
-- The conversion itself is pure: terms in, string out. Everything slow or
-- stateful lives behind ns.Resolver, which is why this is the one piece of
-- the addon that could be exercised outside the game with a stub resolver.
--------------------------------------------------------------------------

local Converter = {}
ns.Converter = Converter

-- TradeSkillMaster's search box will not accept an unbounded string, so long
-- queues are split into parts the player pastes one at a time. Chosen
-- conservatively; adjust if TSM turns out to take more.
local MAX_CHUNK_LENGTH = 1000

-- Auctionator search terms carry filters that have no TSM search-string
-- equivalent. Silently dropping them would misrepresent what the player
-- asked for, so they get counted and reported instead.
local UNCONVERTIBLE_FILTERS = {
  "minPrice", "maxPrice",
  "minLevel", "maxLevel",
  "minItemLevel", "maxItemLevel",
  "minCraftedLevel", "maxCraftedLevel",
  "quality", "expansion",
}

local function CountDroppedFilters(term)
  local dropped = 0
  for _, field in ipairs(UNCONVERTIBLE_FILTERS) do
    if term[field] ~= nil then
      dropped = dropped + 1
    end
  end
  if term.categoryKey and term.categoryKey ~= "" then
    dropped = dropped + 1
  end
  return dropped
end

--------------------------------------------------------------------------
-- Shopping lists
--------------------------------------------------------------------------

-- Auctionator's v1 API can read a list's contents but has no call to
-- enumerate list names, so this reaches into ListManager. Guarded
-- accordingly - a failure here just means an empty dropdown.
function Converter:GetShoppingListNames()
  local names = {}

  if not (Auctionator and Auctionator.Shopping and Auctionator.Shopping.ListManager) then
    return names
  end

  local ok, count = pcall(function()
    return Auctionator.Shopping.ListManager:GetCount()
  end)
  if not ok or not count then
    return names
  end

  for i = 1, count do
    local okList, list = pcall(function()
      return Auctionator.Shopping.ListManager:GetByIndex(i)
    end)
    if okList and list then
      local okName, name = pcall(function() return list:GetName() end)
      if okName and name then
        table.insert(names, name)
      end
    end
  end

  return names
end

local function GetTerms(listName)
  if not listName or not (Auctionator and Auctionator.API and Auctionator.API.v1) then
    return nil
  end

  local ok, items = pcall(Auctionator.API.v1.GetShoppingListItems, ns.CALLER_ID, listName)
  if not ok or not items then
    return nil
  end

  local terms = {}
  for _, rawSearchString in ipairs(items) do
    local okTerm, term = pcall(Auctionator.API.v1.ConvertFromSearchString, ns.CALLER_ID, rawSearchString)
    if okTerm and term and term.searchString and term.searchString ~= "" then
      table.insert(terms, term)
    end
  end

  return terms
end

--------------------------------------------------------------------------
-- String building
--------------------------------------------------------------------------

local function BuildPart(term, itemID)
  local part
  if itemID then
    part = "i:" .. itemID
  else
    -- A bare name is the last-resort fallback. Strip the characters TSM uses
    -- as delimiters so an odd item name can't corrupt the rest of the string.
    part = term.searchString:gsub("[;/]", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  end

  if term.quantity and term.quantity > 0 then
    part = part .. "/x" .. term.quantity
  end

  return part
end

local function BuildChunks(parts)
  local chunks = {}
  local current = {}
  local currentLength = 0

  for _, part in ipairs(parts) do
    -- +1 for the ";" that will join it to what's already there.
    local addedLength = #part + (currentLength > 0 and 1 or 0)
    if currentLength > 0 and currentLength + addedLength > MAX_CHUNK_LENGTH then
      table.insert(chunks, table.concat(current, ";"))
      current = {}
      currentLength = 0
      addedLength = #part
    end
    table.insert(current, part)
    currentLength = currentLength + addedLength
  end

  if #current > 0 then
    table.insert(chunks, table.concat(current, ";"))
  end

  if #chunks == 0 then
    chunks[1] = ""
  end

  return chunks
end

--------------------------------------------------------------------------
-- Conversion
--------------------------------------------------------------------------

local currentGeneration = 0

-- Delay between successive live Auction House queries. Purely a courtesy to
-- the server; resolutions that don't hit the AH skip it entirely.
local LIVE_QUERY_INTERVAL = 0.6

-- Builds the TSM string for `listName`.
--
-- onComplete(result) is called exactly once unless the build is aborted, with
--   result = {
--     listName, tsm, chunks,
--     total, resolved, unresolved,
--     sources = { craftsim, cache, ["local"], live, none },
--     droppedFilters, liveQueries,
--   }
--
-- onProgress(index, total) is called before each item that needs a live
-- Auction House query, which are the only ones slow enough to notice.
function Converter:Build(listName, onComplete, onProgress)
  currentGeneration = currentGeneration + 1
  local generation = currentGeneration

  local result = {
    listName = listName,
    tsm = "",
    chunks = { "" },
    total = 0,
    resolved = 0,
    unresolved = 0,
    sources = { craftsim = 0, cache = 0, ["local"] = 0, live = 0, none = 0 },
    droppedFilters = 0,
    liveQueries = 0,
  }

  local terms = GetTerms(listName)
  if not terms or #terms == 0 then
    onComplete(result)
    return
  end

  result.total = #terms

  ns.Resolver:BeginSession()

  local parts = {}
  local index = 0

  local function Finish()
    result.tsm = table.concat(parts, ";")
    result.chunks = BuildChunks(parts)
    onComplete(result)
  end

  -- Iterative rather than recursive: a list resolved entirely from CraftSim
  -- or the cache calls back synchronously for every item, which as recursion
  -- would put one stack frame per item on a list that can run to hundreds.
  local function ProcessNext()
    while true do
      if generation ~= currentGeneration then
        return
      end

      index = index + 1
      local term = terms[index]
      if not term then
        Finish()
        return
      end

      result.droppedFilters = result.droppedFilters + CountDroppedFilters(term)

      local needsLiveQuery = ns.Resolver:NeedsLiveQuery(term)
      if needsLiveQuery then
        result.liveQueries = result.liveQueries + 1
        if onProgress then
          onProgress(index, #terms)
        end
      end

      local resolvedInline = false

      ns.Resolver:Resolve(term, function(itemID, source)
        if generation ~= currentGeneration then
          return
        end

        result.sources[source] = (result.sources[source] or 0) + 1
        if itemID then
          result.resolved = result.resolved + 1
        else
          result.unresolved = result.unresolved + 1
        end

        table.insert(parts, BuildPart(term, itemID))

        if needsLiveQuery then
          -- Pace the Auction House rather than the loop.
          C_Timer.After(LIVE_QUERY_INTERVAL, ProcessNext)
        else
          resolvedInline = true
        end
      end)

      if not resolvedInline then
        return
      end
    end
  end

  ProcessNext()
end

-- Stops an in-progress build. Its onComplete will not be called.
function Converter:Abort()
  currentGeneration = currentGeneration + 1
end

Converter.MAX_CHUNK_LENGTH = MAX_CHUNK_LENGTH
