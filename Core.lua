local ADDON_NAME, ns = ...

ns.ADDON_NAME = ADDON_NAME

-- Auctionator's public API requires every caller to identify itself.
ns.CALLER_ID = ADDON_NAME

ns.IsAddOnLoaded = C_AddOns.IsAddOnLoaded
ns.VERSION = ns.FormatVersion(C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version"))

-- CraftSim's craft-queue list (CraftSim.CONST.AUCTIONATOR_SHOPPING_LIST_QUEUE_NAME);
-- the default selection when it exists.
ns.DEFAULT_LIST_NAME = "CraftSim CraftQueue"

--------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------

-- SavedVariables are only available from this addon's ADDON_LOADED.
local DB_VERSION = 2

-- Shared with Commands.lua's `reset`, so the two can't drift apart.
ns.DEFAULT_SETTINGS = {
  printOnLogin = false,
  useCraftSim = true,
  useCache = true,
  -- AH tab layout diagnostics.
  debug = false
}

local function InitializeDB()
  ShoppingConverterDB = ShoppingConverterDB or {}
  local db = ShoppingConverterDB

  -- v1 had no structure worth migrating; stamp a version for future migrations.
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

-- Parented so it can't be garbage collected and silently stop receiving events.
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
    -- In-flight and queued browse queries can no longer succeed.
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
