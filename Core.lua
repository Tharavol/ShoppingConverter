local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME

-- Auctionator's public API requires every caller to identify itself.
ns.CALLER_ID = ADDON_NAME

local GetAddOnMetadataCompat = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
ns.VERSION = GetAddOnMetadataCompat(ADDON_NAME, "Version") or "?"

-- The shopping list CraftSim generates from its craft queue
-- (CraftSim.CONST.AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME). Preferred as the
-- default selection when it exists.
ns.DEFAULT_LIST_NAME = "CraftSim CraftQueue"

--------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------

-- SavedVariables are populated before the addon's files run, so it's safe to
-- read and normalize the table here rather than waiting for ADDON_LOADED.
local DB_VERSION = 2

local function InitializeDB()
  ShoppingConverterDB = ShoppingConverterDB or {}
  local db = ShoppingConverterDB

  -- v1 stored `lastList` at the top level and had no other structure. Nothing
  -- from it needs moving, but stamp the version so future migrations have a
  -- floor to work from.
  db.version = db.version or DB_VERSION

  db.settings = db.settings or {}
  if db.settings.printOnLogin == nil then
    -- Off by default: the version is already shown on the tab itself, and
    -- unsolicited login spam is the most common complaint about small addons.
    db.settings.printOnLogin = false
  end
  if db.settings.useCraftSim == nil then
    db.settings.useCraftSim = true
  end
  if db.settings.useCache == nil then
    db.settings.useCache = true
  end

  db.itemCache = db.itemCache or {}

  db.version = DB_VERSION
  ns.db = db
end

InitializeDB()

--------------------------------------------------------------------------
-- Output helpers
--------------------------------------------------------------------------

local PREFIX = "|cff33ff99" .. ADDON_NAME .. "|r: "

function ns.Print(fmt, ...)
  local msg = select("#", ...) > 0 and fmt:format(...) or fmt
  print(PREFIX .. msg)
end

--------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "PLAYER_LOGIN" then
    ns.Cache:Prepare()
    if ns.db.settings.printOnLogin then
      ns.Print("v%s loaded. |cffaaaaaa/shopconv|r for options.", ns.VERSION)
    end
    return
  end

  if event == "AUCTION_HOUSE_CLOSED" then
    -- Any live browse query in flight is now dead, and continuing to walk the
    -- list would just queue queries that can never succeed.
    ns.Resolver:Abort()
    ns.Converter:Abort()
    ns.AHTab:RestoreAuctionHouseWidth()
    return
  end

  if arg1 == Enum.PlayerInteractionType.Auctioneer then
    if event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
      ns.AHTab:OnAuctionHouseShow()
    else
      ns.Resolver:Abort()
      ns.Converter:Abort()
      ns.AHTab:RestoreAuctionHouseWidth()
    end
  end
end)

--------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------

local function PrintUsage()
  ns.Print("v%s commands:", ns.VERSION)
  print("  |cffffff00/shopconv|r - open the Converter tab (Auction House must be open)")
  print("  |cffffff00/shopconv lists|r - show the available Auctionator shopping lists")
  print("  |cffffff00/shopconv convert <name>|r - convert a list into a copyable window")
  print("  |cffffff00/shopconv cache|r - show item cache statistics")
  print("  |cffffff00/shopconv cache clear|r - empty the item cache")
  print("  |cffffff00/shopconv cache on / off|r - reuse item IDs between sessions")
  print("  |cffffff00/shopconv craftsim on / off|r - use CraftSim's queue for item IDs")
  print("  |cffffff00/shopconv login on / off|r - print a message at login")
end

local function Toggle(key, value, label)
  if value == "on" then
    ns.db.settings[key] = true
  elseif value == "off" then
    ns.db.settings[key] = false
  end
  ns.Print("%s is %s.", label, ns.db.settings[key] and "|cff00ff00on|r" or "|cffff0000off|r")
end

SLASH_SHOPPINGCONVERTER1 = "/shopconv"
SLASH_SHOPPINGCONVERTER2 = "/shoppingconverter"

SlashCmdList["SHOPPINGCONVERTER"] = function(input)
  local command, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  -- `rest` needs the original casing: shopping list names are case sensitive.
  local _, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")

  if command == "" then
    if ns.AHTab:SelectTab() then
      return
    end
    ns.Print("Open the Auction House to use the Converter tab, or try |cffffff00/shopconv convert <list>|r.")
    return
  end

  if command == "lists" then
    local names = ns.Converter:GetShoppingListNames()
    if #names == 0 then
      ns.Print("No Auctionator shopping lists found.")
      return
    end
    ns.Print("Auctionator shopping lists:")
    for _, name in ipairs(names) do
      print("  " .. name)
    end
    return
  end

  if command == "convert" then
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
    return
  end

  if command == "cache" then
    if rest == "clear" then
      ns.Cache:Wipe()
      ns.Print("Item cache cleared.")
    else
      Toggle("useCache", rest, "Item cache")
      ns.Print("%d cached item ID(s) for game build %s.", ns.Cache:Count(), ns.Cache:GetBuild() or "?")
    end
    return
  end

  if command == "craftsim" then
    Toggle("useCraftSim", rest, "CraftSim item ID lookup")
    return
  end

  if command == "login" then
    Toggle("printOnLogin", rest, "Login message")
    return
  end

  PrintUsage()
end
