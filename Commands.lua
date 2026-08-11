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

-- `bareToggles` controls what an empty value does: true means bare toggles
-- the current state and reports the result (S8 of the cross-addon slash
-- command standard), false means bare leaves the state alone and just
-- reports it -- used only by `cache`, whose bare form is documented as a
-- read-only stats query, not a toggle.
local function Toggle(key, value, label, bareToggles)
  if value == "on" then
    ns.db.settings[key] = true
  elseif value == "off" then
    ns.db.settings[key] = false
  elseif value == "" then
    if bareToggles then
      ns.db.settings[key] = not ns.db.settings[key]
    end
  else
    -- Reject rather than silently ignore: an unrecognised value must not
    -- report the unchanged state as though it had applied.
    ns.Print("'%s' - expected 'on' or 'off'.", value)
    return
  end
  ns.Print("%s is %s.", label, ns.db.settings[key] and "|cff00ff00on|r" or "|cffff0000off|r")
end

-- `argument` keeps the original case of everything after the command word,
-- since shopping list names are case sensitive. `rest` is the same text
-- lowercased, for the on/off/clear values the other commands compare against.
--
-- "", "config" and "gui" are silent aliases of "options" (S5): each opens the
-- panel but carries no help text of its own, so PrintUsage doesn't repeat
-- the same line four times.
local function OpenPanel() ns.Options:Open() end

-- Forward-declared so the "help" entry below can close over it before its
-- body (which needs COMMANDS to exist) is assigned further down.
local PrintUsage

local COMMANDS = {
  {
    name = "",
    help = {},
    handler = OpenPanel,
  },
  {
    name = "options",
    help = {
      "|cffffff00/shopconv|r, |cffffff00/shopconv options|r, |cffffff00/shopconv config|r, "
        .. "|cffffff00/shopconv gui|r - open the settings panel",
    },
    handler = OpenPanel,
  },
  {name = "config", help = {}, handler = OpenPanel},
  {name = "gui", help = {}, handler = OpenPanel},
  {
    name = "tab",
    help = { "|cffffff00/shopconv tab|r - open the Converter tab (Auction House must be open)" },
    handler = function()
      if ns.AHTab:SelectTab() then
        return
      end
      ns.Print("Open the Auction House to use the Converter tab, or try |cffffff00/shopconv convert <list>|r.")
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
        -- bareToggles=false: the bare form is documented above as a stats
        -- query, not a toggle, so it stays that way.
        Toggle("useCache", rest, "Item cache", false)
        ns.Print("%d cached item ID(s) for game build %s.", ns.Cache:Count(), ns.Cache:GetBuild() or "?")
      end
    end,
  },
  {
    name = "craftsim",
    help = { "|cffffff00/shopconv craftsim [on|off]|r - toggle or set CraftSim's queue for item IDs" },
    handler = function(_, rest)
      Toggle("useCraftSim", rest, "CraftSim item ID lookup", true)
    end,
  },
  {
    name = "login",
    help = { "|cffffff00/shopconv login [on|off]|r - toggle or set the login message" },
    handler = function(_, rest)
      Toggle("printOnLogin", rest, "Login message", true)
    end,
  },
  {
    name = "debug",
    help = { "|cffffff00/shopconv debug [on|off]|r - toggle or set AH tab layout diagnostic messages" },
    handler = function(_, rest)
      Toggle("debug", rest, "Debug messages", true)
    end,
  },
  {
    name = "status",
    help = { "|cffffff00/shopconv status|r - show current settings" },
    handler = function()
      ns.Print("%s settings:", ns.VERSION)
      for _, definition in ipairs(ns.Options.CHECKBOXES) do
        print(("  %s: %s"):format(definition.label,
          ns.db.settings[definition.key] and "|cff00ff00on|r" or "|cffff0000off|r"))
      end
      print(("  %d cached item ID(s) for game build %s."):format(
        ns.Cache:Count(), ns.Cache:GetBuild() or "?"))
    end,
  },
  {
    name = "version",
    help = { "|cffffff00/shopconv version|r - show the addon version" },
    handler = function() ns.Print(ns.VERSION) end,
  },
  {
    name = "reset",
    help = { "|cffffff00/shopconv reset|r - restore settings to defaults" },
    handler = function()
      for key, value in pairs(ns.DEFAULT_SETTINGS) do
        ns.db.settings[key] = value
      end
      ns.Print("Settings restored to defaults.")
    end,
  },
  {
    name = "help",
    help = { "|cffffff00/shopconv help|r - show this list" },
    handler = function() PrintUsage() end,
  },
}

PrintUsage = function()
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

  -- A typo must be visibly a typo, never a silent fallback (S4).
  ns.Print("Unknown command: %s", command)
  PrintUsage()
end
