local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Settings panel: the /shopconv toggles plus a cache-clear button, backed
-- by the same ns.db.settings keys as the slash commands.
--------------------------------------------------------------------------

local Options = {}
ns.Options = Options

-- Also listed by Commands.lua's `status`.
local CHECKBOXES = {
  {
    key = "useCache",
    label = "Reuse item ID cache between sessions",
    tooltip = "Resolved item IDs are remembered across conversions and sessions, "
      .. "so a shopping list that grows over time only looks up items it hasn't seen before.",
  },
  {
    key = "useCraftSim",
    label = "Use CraftSim's craft queue for item IDs",
    tooltip = "When CraftSim is installed, read item IDs directly from its craft queue "
      .. "instead of looking them up.",
  },
  {
    key = "printOnLogin",
    label = "Show a message at login",
    tooltip = "Print the addon name and version to chat when you log in.",
  },
  {
    key = "debug",
    label = "Show diagnostic messages",
    tooltip = "Print a chat message when the Auction House tab row or window "
      .. "width can't be fixed up as expected. Only useful when troubleshooting a layout issue.",
  },
}
Options.CHECKBOXES = CHECKBOXES

local function CreatePanel()
  local panel = CreateFrame("Frame")
  panel.name = ADDON_NAME

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText(ADDON_NAME)

  local checkboxes = {}
  local anchor = title
  for _, definition in ipairs(CHECKBOXES) do
    local checkbox = CreateFrame("CheckButton", nil, panel, "InterfaceOptionsCheckButtonTemplate")
    checkbox:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", anchor == title and -2 or 0, -12)
    checkbox.Text:SetText(definition.label)
    checkbox.tooltipText = definition.label
    checkbox.tooltipRequirement = definition.tooltip
    checkbox:SetScript("OnClick", function(self)
      ns.db.settings[definition.key] = self:GetChecked() and true or false
    end)
    checkboxes[#checkboxes + 1] = { checkbox = checkbox, key = definition.key }
    anchor = checkbox
  end

  local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
  clearButton:SetSize(140, 22)
  clearButton:SetText("Clear Item Cache")
  clearButton:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 2, -20)

  local cacheStatus = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  cacheStatus:SetPoint("LEFT", clearButton, "RIGHT", 10, 0)

  local function RefreshCacheStatus()
    cacheStatus:SetText(("%d cached item ID(s) for game build %s."):format(
      ns.Cache:Count(), ns.Cache:GetBuild() or "?"))
  end

  clearButton:SetScript("OnClick", function()
    ns.Cache:Wipe()
    RefreshCacheStatus()
  end)

  panel:SetScript("OnShow", function()
    for _, entry in ipairs(checkboxes) do
      entry.checkbox:SetChecked(ns.db.settings[entry.key] and true or false)
    end
    RefreshCacheStatus()
  end)

  return panel
end

-- Registered at load so the category is always listed.
function Options:Register()
  local panel = CreatePanel()
  local category = Settings.RegisterCanvasLayoutCategory(panel, ADDON_NAME)
  Settings.RegisterAddOnCategory(category)
  self.category = category
end

-- Opens the Settings window straight to this panel, e.g. from /shopconv options.
function Options:Open()
  if self.category then
    Settings.OpenToCategory(self.category:GetID())
  end
end

Options:Register()
