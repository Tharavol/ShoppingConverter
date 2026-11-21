local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Auctionator shopping list -> TSM search string. Slow or stateful work
-- lives behind ns.Resolver, so this runs offline with a stub resolver.
--------------------------------------------------------------------------

local Converter = {}
ns.Converter = Converter

-- TSM's search box rejects unbounded strings; longer output is split.
local MAX_CHUNK_LENGTH = 1000

-- Auctionator filters with no TSM equivalent; counted and reported.
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

-- Auctionator's v1 API has no call to enumerate list names, so this reaches
-- into the internal ListManager; any failure there just means no names.
function Converter:GetShoppingListNames()
  local names = {}
  pcall(function()
    local manager = Auctionator.Shopping.ListManager
    for i = 1, manager:GetCount() do
      table.insert(names, manager:GetByIndex(i):GetName())
    end
  end)
  return names
end

-- API.v1 raises for a missing list; treat that as no items.
local function GetListItems(listName)
  local ok, items = pcall(Auctionator.API.v1.GetShoppingListItems, ns.CALLER_ID, listName)
  return ok and items or nil
end

function Converter:GetShoppingListItemCount(listName)
  local items = GetListItems(listName)
  return items and #items or 0
end

-- Empties `listName` but keeps the list. v1 has no bulk clear, so each item is
-- removed by its search string. Returns true if anything was removed.
function Converter:ClearList(listName)
  local items = GetListItems(listName)
  if not items or #items == 0 then
    return false
  end

  pcall(function()
    for index = #items, 1, -1 do
      Auctionator.API.v1.DeleteShoppingListItem(ns.CALLER_ID, listName, items[index])
    end
  end)

  return true
end

local function GetTerms(listName)
  local items = GetListItems(listName)
  if not items then
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
    -- Name fallback: strip TSM's delimiters so it can't corrupt the string.
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

-- Delay between live AH queries, as a courtesy to the server.
local LIVE_QUERY_INTERVAL = 0.6

-- Builds the TSM string for `listName`.
--
-- onComplete(result) is called exactly once unless the build is aborted, with
--   result = {
--     listName, tsm, chunks,
--     total, resolved, unresolved,
--     sources = { craftsim, cache, ["local"], live, closed, none },
--     droppedFilters, liveQueries,
--   }
--
-- onProgress(index, total) is called before each item needing a live AH query.
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
    sources = { craftsim = 0, cache = 0, ["local"] = 0, live = 0, closed = 0, none = 0 },
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

  -- Iterative: synchronous resolutions would otherwise recurse once per item.
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
