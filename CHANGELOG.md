# Changelog

All notable changes to this addon are documented in this file.

## [1.2.1]

### Fixed
- Item resolver hanging forever: it registered for an event
  (`AUCTION_HOUSE_THROTTLED_MESSAGE`) that doesn't actually exist, which
  errored out immediately and skipped past the code that sends the
  query and arms the safety timeout, permanently stuck holding the
  shared query lock so every later item just waited on it. Removed that
  event and wrapped query setup so the lock is always released even if
  something in it throws.
- Tightened the tab button's max width (130 -> 100), since it was a bit
  wider than the other AH tabs.
- The Auction House width fix is now deferred a frame so it measures
  the tab row after any other AH-tab-adding addons have added theirs
  too, instead of measuring before they get a chance to and being
  pushed past the window's edge again once they do.

## [1.2.0]

### Added
- Preserves crafting-reagent quality (Auctionator's tier field), which
  was previously dropped entirely. Since each quality rank is usually a
  separate itemID sharing the same display name, a plain local name
  lookup can't tell them apart and could silently resolve to the wrong
  rank. Tier-sensitive items (and anything not in the local item cache)
  are now resolved via a live Auction House search, same as Auctionator
  itself does, picking the itemID whose actual quality rank matches.
  This makes conversion asynchronous: items that need a live lookup
  take a moment, with the status line showing progress.

## [1.1.2]

### Changed
- Removed the surrounding quotes from name-fallback search terms (items
  with no local item ID) in the output string; TSM's search box doesn't
  need them.

## [1.1.1]

### Changed
- Renamed the tab button to "Converter".

### Fixed
- Output text not reliably showing as selected: focus is now set
  before highlighting, instead of after, so the selection actually
  takes visually.

## [1.1.0]

### Added
- Refresh button to the converter pane to re-run the conversion on
  demand, without needing to leave and reopen the tab.

### Changed
- Renamed the tab button to "Shop Conv".

## [1.0.3]

### Fixed
- The "TSM Convert" tab button rendering much wider than a normal tab.
  Shortened the label to "TSM" and explicitly re-clamped the button's
  width after creation, since the library that adds it doesn't cap tab
  width on its own.

## [1.0.2]

### Fixed
- The Auction House window (and the tab, which sizes itself relative to
  it) growing wider every time the AH was reopened, eventually running
  off the edge of the screen. The width fix now always recomputes from
  the original window width instead of compounding on top of an
  already-widened one, and is hard-capped to never exceed the screen
  width.

## [1.0.1]

### Fixed
- Output box sizing itself to a bogus width on first load (it read the
  frame's size before layout had resolved).
- Items the client can't resolve to a local item ID (never linked or
  looked up this session) now fall back to a quoted name search term
  instead of being silently dropped, so no items are lost.
- The Auction House window is now widened as needed to fit the new tab
  button, since the extra tab could push the tab row past the window's
  right edge.

## [1.0.0]

### Added
- "TSM Convert" tab to the Blizzard Auction House frame (via embedded
  LibAHTab, avoiding the taint issues of manual AH tab hacks).
- Reads an Auctionator shopping list through Auctionator's public API
  and converts each entry into TradeSkillMaster's `i:<itemID>/x<qty>`
  search syntax, joined with semicolons.
- The tab auto-populates a copyable, select-all text box as soon as
  it's opened, so the string is ready to paste into TSM immediately.
- Dropdown to pick which Auctionator shopping list to convert. Defaults
  to a list named "CraftSim CraftQueue" if one exists, otherwise
  remembers the last list you picked (saved per account).
