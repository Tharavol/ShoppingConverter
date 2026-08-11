local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME

-- Auctionator's public API requires every caller to identify itself.
ns.CALLER_ID = ADDON_NAME

local GetAddOnMetadataCompat = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
ns.IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
ns.VERSION = ns.FormatVersion(GetAddOnMetadataCompat(ADDON_NAME, "Version"))

-- The shopping list CraftSim generates from its craft queue
-- (CraftSim.CONST.AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME). Preferred as the
-- default selection when it exists.
ns.DEFAULT_LIST_NAME = "CraftSim CraftQueue"

--------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------

-- SavedVariables are only populated once this addon's own files have all
-- finished running, right before ADDON_LOADED fires for it - reading the
-- global any earlier than that always finds nil, so this has to wait for
-- that event rather than running at file load time.
local DB_VERSION = 2

-- Shared with Commands.lua's `reset`, so the two can't drift apart.
ns.DEFAULT_SETTINGS = {
  -- Off by default: the version is already shown on the tab itself, and
  -- unsolicited login spam is the most common complaint about small addons.
  printOnLogin = false,
  useCraftSim = true,
  useCache = true,
  -- Off by default: these are diagnostics for tracking down AH tab layout
  -- issues (ordering, window-width fitting), not something most players
  -- need to see.
  debug = false
}

local function InitializeDB()
  ShoppingConverterDB = ShoppingConverterDB or {}
  local db = ShoppingConverterDB

  -- v1 stored `lastList` at the top level and had no other structure. Nothing
  -- from it needs moving, but stamp the version so future migrations have a
  -- floor to work from.
  db.version = db.version or DB_VERSION

  db.settings = db.settings or {}
  for key, value in pairs(ns.DEFAULT_SETTINGS) do
    if db.settings[key] == nil then
      db.settings[key] = value
    end
  end

  db.itemCache = db.itemCache or {}

  db.version = DB_VERSION
  ns.db = db
end

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

-- Parented explicitly: an anonymous frame with no parent and no other Lua
-- reference (this one isn't captured by its own OnEvent closure) is eligible
-- for garbage collection, which silently stops event delivery with no error.
-- Parenting to UIParent keeps it alive for the life of the session.
local eventFrame = CreateFrame("Frame", nil, UIParent)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
eventFrame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
eventFrame:RegisterEvent("AUCTION_HOUSE_CLOSED")

eventFrame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      InitializeDB()
      eventFrame:UnregisterEvent("ADDON_LOADED")
    end
    return
  end

  if event == "PLAYER_LOGIN" then
    ns.Cache:Prepare()
    if ns.db.settings.printOnLogin then
      ns.Print("%s loaded. |cffaaaaaa/shopconv|r for options.", ns.VERSION)
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

SLASH_SHOPPINGCONVERTER1 = "/shopconv"
SLASH_SHOPPINGCONVERTER2 = "/shoppingconverter"

SlashCmdList["SHOPPINGCONVERTER"] = function(input)
  ns.Commands:Dispatch(input)
end
