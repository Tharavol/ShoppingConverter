local ADDON_NAME, ns = ...

--------------------------------------------------------------------------
-- Persistent (name, tier) -> itemID cache, saving live AH queries. Stable
-- within a game build, so it is wiped when the build changes.
--------------------------------------------------------------------------

local Cache = {}
ns.Cache = Cache

-- Bounds SavedVariables growth.
local MAX_ENTRIES = 5000

local SEPARATOR = "\30"

local function BuildKey(name, tier)
  return (name or ""):lower() .. SEPARATOR .. tostring(tier or 0)
end

local function Store()
  local store = ns.db.itemCache
  store.entries = store.entries or {}
  return store
end

-- Drops everything if the client build changed: a patch can add quality
-- ranks or rename items.
function Cache:Prepare()
  local store = Store()
  local build = select(2, GetBuildInfo())
  if store.build ~= build then
    store.build = build
    store.entries = {}
    store.count = 0
  end
  store.count = store.count or 0
end

function Cache:GetBuild()
  return Store().build
end

function Cache:Get(name, tier)
  if not ns.db.settings.useCache then
    return nil
  end
  return Store().entries[BuildKey(name, tier)]
end

function Cache:Set(name, tier, itemID)
  if not ns.db.settings.useCache or not itemID then
    return
  end

  local store = Store()
  local key = BuildKey(name, tier)
  if store.entries[key] == itemID then
    return
  end

  if store.entries[key] == nil then
    if store.count >= MAX_ENTRIES then
      -- No usage data to evict on, so start over.
      store.entries = {}
      store.count = 0
    end
    store.count = store.count + 1
  end

  store.entries[key] = itemID
end

function Cache:Wipe()
  local store = Store()
  store.entries = {}
  store.count = 0
  store.build = select(2, GetBuildInfo())
end

function Cache:Count()
  return Store().count or 0
end
