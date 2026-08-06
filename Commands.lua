local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Slash command dispatch
--
-- A table of { name, help, handler } rather than an if-chain, so PrintUsage
-- can be derived from the same data Dispatch uses instead of duplicating
-- the command list by hand where it could silently drift out of sync.
--
-- Doesn't touch the game API directly - no CreateFrame, no SlashCmdList
-- registration, both of which stay in Core.lua - which is what lets the
-- offline suite load this module.
--------------------------------------------------------------------------

local Commands = {}
ns.Commands = Commands

local function Toggle(key, value, label)
  if value == "on" then
    ns.db.settings[key] = true
  elseif value == "off" then
    ns.db.settings[key] = false
  end
  ns.Print("%s is %s.", label, ns.db.settings[key] and "|cff00ff00on|r" or "|cffff0000off|r")
end

-- `argument` keeps the original case of everything after the command word,
-- since shopping list names are case sensitive. `rest` is the same text
-- lowercased, for the on/off/clear values the other commands compare against.
local COMMANDS = {
  {
    name = "",
    help = { "|cffffff00/shopconv|r - open the Converter tab (Auction House must be open)" },
    handler = function()
      if ns.AHTab:SelectTab() then
        return
      end
      ns.Print("Open the Auction House to use the Converter tab, or try |cffffff00/shopconv convert <list>|r.")
    end,
  },
  {
    name = "options",
    help = { "|cffffff00/shopconv options|r - open the settings panel" },
    handler = function()
      ns.Options:Open()
    end,
  },
  {
    name = "lists",
    help = { "|cffffff00/shopconv lists|r - show the available Auctionator shopping lists" },
    handler = function()
      local names = ns.Converter:GetShoppingListNames()
      if #names == 0 then
        ns.Print("No Auctionator shopping lists found.")
        return
      end
      ns.Print("Auctionator shopping lists:")
      for _, name in ipairs(names) do
        print("  " .. name)
      end
    end,
  },
  {
    name = "convert",
    help = { "|cffffff00/shopconv convert <name>|r - convert a list into a copyable window" },
    handler = function(argument)
      if argument == "" then
        ns.Print("Usage: |cffffff00/shopconv convert <list name>|r")
        return
      end
      ns.Print("Converting \"%s\"...", argument)
      ns.Converter:Build(argument, function(result)
        if result.total == 0 then
          ns.Print("\"%s\" is empty, or does not exist.", argument)
          return
        end
        ns.UI:ShowCopyDialog(result, ("%s - %s"):format(ADDON_NAME, argument))
      end)
    end,
  },
  {
    name = "cache",
    help = {
      "|cffffff00/shopconv cache|r - show item cache statistics",
      "|cffffff00/shopconv cache clear|r - empty the item cache",
      "|cffffff00/shopconv cache on / off|r - reuse item IDs between sessions",
    },
    handler = function(_, rest)
      if rest == "clear" then
        ns.Cache:Wipe()
        ns.Print("Item cache cleared.")
      else
        Toggle("useCache", rest, "Item cache")
        ns.Print("%d cached item ID(s) for game build %s.", ns.Cache:Count(), ns.Cache:GetBuild() or "?")
      end
    end,
  },
  {
    name = "craftsim",
    help = { "|cffffff00/shopconv craftsim on / off|r - use CraftSim's queue for item IDs" },
    handler = function(_, rest)
      Toggle("useCraftSim", rest, "CraftSim item ID lookup")
    end,
  },
  {
    name = "login",
    help = { "|cffffff00/shopconv login on / off|r - print a message at login" },
    handler = function(_, rest)
      Toggle("printOnLogin", rest, "Login message")
    end,
  },
}

local function PrintUsage()
  ns.Print("%s commands:", ns.VERSION)
  for _, command in ipairs(COMMANDS) do
    for _, line in ipairs(command.help) do
      print("  " .. line)
    end
  end
end

local function Parse(input)
  local raw = input or ""
  -- Parsed once: `command` and `rest` are lowercased for matching, while
  -- `argument` keeps the case the player typed.
  local command, argument = raw:match("^%s*(%S*)%s*(.-)%s*$")
  return command:lower(), argument, argument:lower()
end

function Commands:Dispatch(input)
  local command, argument, rest = Parse(input)

  for _, entry in ipairs(COMMANDS) do
    if entry.name == command then
      entry.handler(argument, rest)
      return
    end
  end

  PrintUsage()
end
