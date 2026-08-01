std = "lua51"
max_line_length = 120

-- LibStub and LibAHTab are vendored verbatim under Libs/ so the repository can
-- be cloned straight into Interface/AddOns; they are not ours to lint.
exclude_files = {"Libs/**"}

-- WoW event handlers always receive (self, event, ...); ignore unused args
-- entirely since callbacks must match Blizzard's fixed signatures.
ignore = {
    "212",            -- unused argument
    "211/ADDON_NAME", -- every file starts `local ADDON_NAME, ns = ...`
}

globals = {
    -- SavedVariables declared in the .toc
    "ShoppingConverterDB",

    "SLASH_SHOPPINGCONVERTER1",
    "SLASH_SHOPPINGCONVERTER2",
    "SlashCmdList",
}

read_globals = {
    -- Namespaced API tables
    "C_AddOns", "C_AuctionHouse", "C_Item", "C_Timer", "C_TradeSkillUI", "Enum",

    -- Frame / UI globals
    "CreateFrame", "UIParent", "UISpecialFrames", "AuctionHouseFrame",
    "ChatFontNormal", "GetScreenWidth", "PanelTemplates_TabResize",

    -- Lua extensions exposed by WoW
    "tContains", "wipe",

    -- Addon metadata
    "GetAddOnMetadata", "GetBuildInfo", "IsAddOnLoaded", "LibStub",

    -- Dependencies declared in the .toc
    "Auctionator", -- ## Dependencies
    "CraftSim",    -- ## OptionalDeps
}

-- The offline test harness installs its own WoW stubs into _G on purpose.
files["Tests/**"] = {
    ignore = {"111", "112", "113", "121", "122"},
}
