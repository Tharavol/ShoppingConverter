-- Offline tests for the parts of Shopping Converter that don't need the game
-- client: the shopping-list-to-TSM conversion and the item ID cache.
--
--   lua Tests/run.lua        (run from the addon folder)
--
-- The resolver is injected as a stub, which is the whole reason the
-- conversion lives in its own module.

local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/?.lua;" .. package.path

local stubs = require("wow_stubs")
stubs.install(_G)

--------------------------------------------------------------------------
-- Tiny test harness
--------------------------------------------------------------------------

local passed, failed = 0, 0
local failures = {}

local function check(condition, name, detail)
  if condition then
    passed = passed + 1
  else
    failed = failed + 1
    table.insert(failures, name .. (detail and ("\n      " .. detail) or ""))
  end
end

local function equals(actual, expected, name)
  check(actual == expected, name,
    ("expected %s, got %s"):format(tostring(expected), tostring(actual)))
end

--------------------------------------------------------------------------
-- Module loading
--------------------------------------------------------------------------

local printedMessages = {}

local ns = {
  ADDON_NAME = "ShoppingConverter",
  CALLER_ID = "ShoppingConverter",
  VERSION = "test",
  DEFAULT_LIST_NAME = "CraftSim CraftQueue",
  Print = function(fmt, ...)
    table.insert(printedMessages, select("#", ...) > 0 and fmt:format(...) or fmt)
  end,
  IsAddOnLoaded = function() return true end,
}

ns.db = {
  settings = { useCache = true, useCraftSim = true, printOnLogin = false },
  itemCache = {},
}

stubs.loadModule(here .. "/../Version.lua", "ShoppingConverter", ns)
stubs.loadModule(here .. "/../Cache.lua", "ShoppingConverter", ns)
stubs.loadModule(here .. "/../Converter.lua", "ShoppingConverter", ns)

ns.Cache:Prepare()

--------------------------------------------------------------------------
-- Fake Auctionator + resolver
--------------------------------------------------------------------------

-- Auctionator stores a shopping list entry as a divider-joined string; the
-- tests go through the same ConvertFromSearchString the addon calls, so the
-- term shape stays honest.
local DIVIDER = "^"

local function searchString(fields)
  return table.concat({
    fields.name or "",
    fields.categoryKey or "",
    fields.minItemLevel or "",
    fields.maxItemLevel or "",
    fields.minLevel or "",
    fields.maxLevel or "",
    fields.minCraftedLevel or "",
    fields.maxCraftedLevel or "",
    fields.minPrice or "",
    fields.maxPrice or "",
    fields.quality or "",
    fields.tier or "",
    fields.expansion or "",
    fields.quantity or "",
  }, DIVIDER)
end

local currentList = {}

Auctionator = {
  API = {
    v1 = {
      GetShoppingListItems = function(_, listName)
        return currentList[listName]
      end,
      ConvertFromSearchString = function(_, raw)
        local parts = {}
        for field in (raw .. DIVIDER):gmatch("(.-)%" .. DIVIDER) do
          table.insert(parts, field)
        end
        local function number(value)
          local n = tonumber(parts[value])
          if n == 0 then return nil end
          return n
        end
        local name = parts[1] or ""
        local isExact = name:match('^"(.*)"$') ~= nil
        return {
          searchString = name:gsub('^"(.*)"$', "%1"),
          isExact = isExact,
          categoryKey = parts[2] or "",
          minItemLevel = number(3), maxItemLevel = number(4),
          minLevel = number(5), maxLevel = number(6),
          minCraftedLevel = number(7), maxCraftedLevel = number(8),
          minPrice = number(9), maxPrice = number(10),
          quality = number(11), tier = number(12),
          expansion = number(13), quantity = number(14),
        }
      end,
    },
  },
  Shopping = {
    ListManager = {
      GetCount = function() return 0 end,
      GetByIndex = function() return nil end,
    },
  },
}

-- Resolves from a name+tier table, so tests state exactly what the game
-- would have known. `async` names resolve on a later "frame" to exercise the
-- asynchronous path.
local function makeResolver(known, asyncNames)
  return {
    BeginSession = function() end,
    NeedsLiveQuery = function(_, term)
      return asyncNames ~= nil and asyncNames[term.searchString] == true
    end,
    Resolve = function(_, term, callback)
      local key = term.searchString .. "|" .. tostring(term.tier or 0)
      local itemID = known[key]
      local source = itemID and "craftsim" or "none"
      if asyncNames and asyncNames[term.searchString] then
        source = itemID and "live" or "none"
        C_Timer.After(0, function() callback(itemID, source) end)
      else
        callback(itemID, source)
      end
    end,
    Abort = function() end,
  }
end

local function convert(items, resolver)
  currentList["Test"] = items
  ns.Resolver = resolver
  local captured
  ns.Converter:Build("Test", function(result) captured = result end)
  stubs.drainTimers()
  return captured
end

--------------------------------------------------------------------------
-- Conversion
--------------------------------------------------------------------------

do
  local result = convert(
    {
      searchString { name = '"Ironclaw Ore"', tier = 2, quantity = 40 },
      searchString { name = '"Bismuth"', quantity = 5 },
    },
    makeResolver({ ["Ironclaw Ore|2"] = 210930, ["Bismuth|0"] = 210796 })
  )

  equals(result.tsm, "i:210930/x40;i:210796/x5", "resolved items become i:<id>/x<qty>")
  equals(result.total, 2, "term count")
  equals(result.resolved, 2, "resolved count")
  equals(result.unresolved, 0, "unresolved count")
  equals(#result.chunks, 1, "short list is a single chunk")
end

do
  local result = convert(
    { searchString { name = '"Mystery Widget"', quantity = 3 } },
    makeResolver({})
  )

  equals(result.tsm, "Mystery Widget/x3", "unresolved item falls back to its name")
  equals(result.unresolved, 1, "unresolved is counted")
end

do
  local result = convert(
    { searchString { name = '"Weird;Name/With Delimiters"', quantity = 1 } },
    makeResolver({})
  )

  equals(result.tsm, "Weird Name With Delimiters/x1",
    "TSM delimiters are stripped from a name fallback")
end

do
  local result = convert(
    { searchString { name = '"Bismuth"' } },
    makeResolver({ ["Bismuth|0"] = 210796 })
  )

  equals(result.tsm, "i:210796", "a term with no quantity omits the /x suffix")
end

do
  -- Same display name, two quality ranks: the tier has to reach the resolver
  -- or the string silently points at the wrong item.
  local result = convert(
    {
      searchString { name = '"Ironclaw Ore"', tier = 1, quantity = 10 },
      searchString { name = '"Ironclaw Ore"', tier = 3, quantity = 20 },
    },
    makeResolver({ ["Ironclaw Ore|1"] = 210930, ["Ironclaw Ore|3"] = 210932 })
  )

  equals(result.tsm, "i:210930/x10;i:210932/x20", "quality ranks resolve to distinct item IDs")
end

do
  local result = convert(
    { searchString { name = '"Bismuth"', maxPrice = 500, minItemLevel = 10, quantity = 2 } },
    makeResolver({ ["Bismuth|0"] = 210796 })
  )

  equals(result.tsm, "i:210796/x2", "unconvertible filters don't reach the output")
  equals(result.droppedFilters, 2, "unconvertible filters are counted for reporting")
end

do
  local result = convert({}, makeResolver({}))
  equals(result.total, 0, "empty list yields no terms")
  equals(result.tsm, "", "empty list yields an empty string")
end

do
  -- Order has to survive the asynchronous path: the second item resolves a
  -- "frame" later than the first and third.
  local result = convert(
    {
      searchString { name = '"Bismuth"', quantity = 1 },
      searchString { name = '"Slow Item"', quantity = 2 },
      searchString { name = '"Aqirite"', quantity = 3 },
    },
    makeResolver(
      { ["Bismuth|0"] = 1, ["Slow Item|0"] = 2, ["Aqirite|0"] = 3 },
      { ["Slow Item"] = true }
    )
  )

  equals(result.tsm, "i:1/x1;i:2/x2;i:3/x3", "list order survives an async resolution")
  equals(result.liveQueries, 1, "only the slow item counts as a live query")
end

do
  -- AH closed: the resolver reports no live query is needed (nothing to
  -- pace) even though the item can't be resolved from any other source.
  local result = convert(
    { searchString { name = '"Mystery Widget"', quantity = 1 } },
    {
      BeginSession = function() end,
      NeedsLiveQuery = function() return false end,
      Resolve = function(_, term, callback) callback(nil, "closed") end,
      Abort = function() end,
    }
  )

  equals(result.tsm, "Mystery Widget/x1", "an AH-closed item still falls back to its name")
  equals(result.liveQueries, 0, "an AH-closed item is not counted as a live query")
  equals(result.sources.closed, 1, "an AH-closed source is tracked separately from a live miss")
end

--------------------------------------------------------------------------
-- Chunking
--------------------------------------------------------------------------

do
  local items = {}
  for i = 1, 200 do
    items[i] = searchString { name = ('"Item %d"'):format(i), quantity = 99 }
  end

  local known = {}
  for i = 1, 200 do
    known[("Item %d|0"):format(i)] = 100000 + i
  end

  local result = convert(items, makeResolver(known))

  check(#result.chunks > 1, "a long list is split into multiple chunks",
    ("got %d chunk(s)"):format(#result.chunks))

  local longest = 0
  for _, chunk in ipairs(result.chunks) do
    longest = math.max(longest, #chunk)
  end
  check(longest <= ns.Converter.MAX_CHUNK_LENGTH, "no chunk exceeds the length limit",
    ("longest chunk was %d, limit is %d"):format(longest, ns.Converter.MAX_CHUNK_LENGTH))

  equals(table.concat(result.chunks, ";"), result.tsm,
    "chunks rejoin into exactly the full string")
  equals(result.total, 200, "every item survives chunking")
end

--------------------------------------------------------------------------
-- Version formatting
--------------------------------------------------------------------------

do
  equals(ns.FormatVersion("1.4.0"), "v1.4.0", "a bare version number gets a v prefix")
  equals(ns.FormatVersion("v1.4.0"), "v1.4.0", "a tag that already has a v prefix isn't doubled")
  equals(ns.FormatVersion("V1.4.0"), "v1.4.0", "an uppercase V prefix is normalized to lowercase")
  equals(ns.FormatVersion("@project-version@"), "vdev", "an unsubstituted placeholder falls back to vdev")
  equals(ns.FormatVersion(nil), "vdev", "a missing version falls back to vdev")
  equals(ns.FormatVersion(""), "vdev", "an empty version falls back to vdev")
end

--------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------

do
  ns.Cache:Wipe()
  ns.Cache:Set("Ironclaw Ore", 2, 210931)

  equals(ns.Cache:Get("Ironclaw Ore", 2), 210931, "cache round-trips a value")
  equals(ns.Cache:Get("ironclaw ore", 2), 210931, "cache lookup is case insensitive")
  equals(ns.Cache:Get("Ironclaw Ore", 3), nil, "a different quality rank is a different key")
  equals(ns.Cache:Get("Ironclaw Ore", nil), nil, "no tier is a different key from a tier")
  equals(ns.Cache:Count(), 1, "count tracks distinct entries")

  ns.Cache:Set("Ironclaw Ore", 2, 210931)
  equals(ns.Cache:Count(), 1, "rewriting the same value doesn't double count")
end

do
  ns.Cache:Wipe()
  ns.Cache:Set("Bismuth", nil, 210796)

  -- A patch can move item IDs, so everything is dropped when the build moves.
  ns.db.itemCache.build = "old-build"
  ns.Cache:Prepare()

  equals(ns.Cache:Get("Bismuth", nil), nil, "cache is dropped when the game build changes")
  equals(ns.Cache:Count(), 0, "count resets with the cache")
end

do
  ns.Cache:Wipe()
  ns.db.settings.useCache = false
  ns.Cache:Set("Bismuth", nil, 210796)
  equals(ns.Cache:Get("Bismuth", nil), nil, "a disabled cache stores nothing")
  ns.db.settings.useCache = true
end

--------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------

-- Commands.lua doesn't call CreateFrame or touch SlashCmdList itself (that
-- stays in Core.lua, which isn't loaded here), so it's loadable the same
-- way as the other pure modules. ns.AHTab and ns.UI are faked just enough
-- to exercise the two handlers that reach into them.
local ahTabSelected
ns.AHTab = {
  SelectTab = function(_self)
    ahTabSelected = true
    return true
  end,
}

local shownDialog
ns.UI = {
  ShowCopyDialog = function(_self, result, title)
    shownDialog = { result = result, title = title }
  end,
}

stubs.loadModule(here .. "/../Commands.lua", "ShoppingConverter", ns)

local originalPrint = print
local plainLines

-- Dispatches one command, capturing both ns.Print (into printedMessages)
-- and the bare print() calls PrintUsage and "lists" use (into plainLines).
local function dispatch(input)
  printedMessages = {}
  plainLines = {}
  print = function(msg) table.insert(plainLines, msg) end
  ns.Commands:Dispatch(input)
  print = originalPrint
  stubs.drainTimers()
end

do
  dispatch("bogus")
  equals(#plainLines, 8, "an unknown command falls back to usage, one line per help entry")
  equals(plainLines[1], "  |cffffff00/shopconv|r - open the Converter tab (Auction House must be open)",
    "usage is generated from the same table Dispatch matches against")
end

do
  ahTabSelected = false
  dispatch("")
  check(ahTabSelected, "an empty command opens the Converter tab")
  equals(#printedMessages, 0, "opening the tab prints nothing when it succeeds")
end

do
  dispatch("lists")
  equals(printedMessages[1], "No Auctionator shopping lists found.",
    "lists reports when there are none")
end

do
  dispatch("convert")
  equals(#printedMessages, 1, "convert with no list name prints a usage message")
end

do
  shownDialog = nil
  currentList["Test"] = { searchString { name = '"Bismuth"', quantity = 5 } }
  ns.Resolver = makeResolver({ ["Bismuth|0"] = 210796 })

  dispatch("Convert Test")

  check(shownDialog ~= nil, "convert opens the copy dialog for a non-empty list")
  equals(shownDialog and shownDialog.title, "ShoppingConverter - Test",
    "the list name reaches the dialog in its original case despite the command being mixed-case")
end

do
  ns.Cache:Set("Widget", nil, 55555)
  dispatch("cache clear")
  equals(ns.Cache:Count(), 0, "cache clear empties the item cache")
end

do
  dispatch("CACHE OFF")
  equals(ns.db.settings.useCache, false, "cache on/off is matched case-insensitively")
  dispatch("cache on")
  equals(ns.db.settings.useCache, true, "cache on re-enables the cache")
end

do
  dispatch("craftsim off")
  equals(ns.db.settings.useCraftSim, false, "craftsim off disables CraftSim lookups")
  dispatch("craftsim on")
  equals(ns.db.settings.useCraftSim, true, "craftsim on re-enables CraftSim lookups")
end

do
  dispatch("login on")
  equals(ns.db.settings.printOnLogin, true, "login on enables the login message")
  dispatch("login off")
  equals(ns.db.settings.printOnLogin, false, "login off disables the login message")
end

--------------------------------------------------------------------------

print(("%d passed, %d failed"):format(passed, failed))
for _, failure in ipairs(failures) do
  print("  FAIL: " .. failure)
end
os.exit(failed == 0 and 0 or 1)
