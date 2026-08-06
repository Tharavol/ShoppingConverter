# Changelog

All notable changes to this addon are documented in this file.

## [Unreleased]

### Added
- Settings panel (Blizzard Settings -> AddOns -> Shopping Converter) for
  the toggles previously only reachable through `/shopconv`: the item ID
  cache, CraftSim lookups, and the login message. Also adds a **Clear Item
  Cache** button, which had no equivalent outside `/shopconv cache clear`.
  The panel and the slash commands read and write the same settings, so
  either one reflects whatever the other last set.

### Fixed
- The version label in the Converter tab could overlap the TSM search
  string output box, since the two were positioned independently with
  only a few pixels between them. The label is now anchored below the
  output box instead, so the two can't collide regardless of font size or
  UI scale.
- **None of the addon's settings, or the item ID cache, actually survived a
  reload or relog.** `ShoppingConverterDB` was read and initialized at file
  load time, but SavedVariables aren't injected into that global until
  this addon's own files have finished loading, right before
  `ADDON_LOADED` fires for it — reading it any earlier always finds `nil`,
  so every session silently started from a fresh, disconnected table. Any
  setting changed with `/shopconv` (or, as of this release, the Settings
  panel) looked like it took effect, and did for the rest of that session,
  but was never actually the table the client saves to disk. Initialization
  now waits for `ADDON_LOADED` as it should have from the start.
- The event frame handling the login message and Auction House open/close
  was created with no parent and no other Lua reference to it, which was
  safe on the client this addon was originally written against — frames
  used to live forever regardless — but current clients garbage collect
  exactly that shape of object, with no error at all. Both this frame and
  the Auction House query frame are now parented explicitly so neither can
  be collected out from under the addon. (This turned out not to be why
  the login message wasn't showing — the SavedVariables timing bug above
  was — but it's a real latent bug in its own right and worth having
  either way.)

## [1.5.0]

Packaging and internals only — no player-visible change.

### Changed
- The slash-command handlers moved out of `Core.lua`'s if-chain into a
  table of `{ name, help, handler }` in a new `Commands.lua`, so the usage
  text printed by `/shopconv` is generated from the same data the
  dispatcher matches against instead of a hand-maintained copy that could
  silently drift out of sync. The input is now parsed once instead of
  twice. `Commands.lua` doesn't touch the game API directly, so it's
  loadable — and now covered — by the offline test suite.
- `release.yml` no longer passes `CF_API_KEY`, `WOWI_API_TOKEN` or
  `WAGO_API_TOKEN`: this addon isn't published to CurseForge, WoWInterface
  or Wago, and the unused env vars implied a distribution path that wasn't
  actually configured.

## [1.4.0]

### Fixed
- The version shown in the AH tab and at login was wrong in every build
  since 1.3.2 — doubled to `vv1.3.2` in packaged releases, and showing the
  raw, unsubstituted TOC placeholder in dev installs. The packager
  substitutes the version keyword with the release tag verbatim, which
  already carries a `v` prefix, and the hand-written `v` doubled it.
  Version formatting is now handled by a single, tested function.
- Converting with the Auction House closed spent 0.6 seconds pacing a live
  lookup for every unresolved item even though no query was ever sent,
  turning a large cold-cache conversion into a multi-minute stall with no
  status output on the slash-command path. Items now skip straight to the
  name fallback when the Auction House isn't open, and the status line
  distinguishes "matched by name only" from "the Auction House was closed".
- Items a live Auction House query couldn't resolve are now remembered for
  the rest of the session, so a shopping list with a few unresolvable items
  no longer pays for a fresh browse query (plus the pacing delay) on every
  conversion.
- `## Author:` in the TOC was misspelled `Thaaravol`.

### Changed
- Added a `BigWigsMods/packager` dry run to CI, so a packaging regression
  (like the version doubling above) is caught on every pull request instead
  of only once a release is already being cut.

## [1.3.2]

Packaging and tooling only — no functional changes.

### Changed
- Releases are now built by [BigWigsMods/packager](https://github.com/BigWigsMods/packager), so the zip contains only what the addon needs — `.github/`, `.luacheckrc`, `.pkgmeta` and `Tests/` no longer ship.
- The version in the TOC now comes from the release tag rather than being maintained by hand, so it can no longer disagree with the release it was published under. Versions now carry a leading `v`.
- Added GitHub Actions running luacheck and the offline test suite on every push and pull request.

## [1.3.1]

### Changed
- The output box now takes focus and selects its text as soon as a
  conversion finishes, instead of waiting for the player to click
  **Select All**. This is separate from the 1.3.0 change that stopped it
  from stealing focus when the tab merely opens - that still applies, since
  opening the tab isn't the player asking for the string.

## [1.3.0]

### Added
- Item IDs are now read directly from CraftSim's craft queue when CraftSim
  is installed. CraftSim already knows the exact item ID and quality of
  every reagent it queued and discards that when it writes the Auctionator
  shopping list as plain names, which is what forced the slow live Auction
  House lookups in the first place. Converting the `CraftSim CraftQueue`
  list is now effectively instant, with no Auction House traffic.
- Resolved item IDs are cached in saved variables and reused between
  sessions, so a queue that grows over time only ever looks up the items
  it hasn't seen before. The cache is dropped whenever the game build
  changes, since a patch can move item IDs.
- Output longer than TSM's search box will take is split into parts, with
  `<` / `>` buttons to page through them and paste one at a time.
- Auctionator filters with no TSM search-string equivalent (price caps,
  level and item level ranges, category, expansion) are now counted and
  reported instead of being silently discarded.
- `/shopconv` slash command: jump to the tab, list shopping lists, convert
  a list into a copyable window without the Auction House open, inspect or
  clear the item cache, and toggle the CraftSim lookup, the cache, and the
  login message.
- Offline test suite for the conversion logic and the item cache
  (`lua Tests/run.lua`), with the resolver injected as a stub.

### Fixed
- Live Auction House lookups could return the wrong item. Browse queries
  match on substring, so searching `Ironclaw Ore` also returns
  `Ironclaw Ore Fragment`, and the first result was accepted regardless of
  its name. Results are now verified against the term's actual name, and a
  substring match is only accepted for a term Auctionator did not flag as
  exact, and only once the result set is known to be complete.
- The query timeout defeated the query lock it was meant to protect: it
  released the lock while the abandoned query was still in flight, so the
  next query could start and misread the old one's results. The lock is
  now held until the Auction House actually finishes with the abandoned
  query.
- Sending a browse query while the server throttle was active threw, and
  the error was swallowed and misreported as "item not found". The
  throttle is now checked and waited on.
- Leaving the Converter tab or closing the Auction House mid-conversion
  left live queries running, competing with whatever the player did next.
  Conversions are now aborted on both.
- The Auction House window is restored to its original width when closed,
  instead of staying widened for every other addon that measures it.

### Changed
- Split the single `Core.lua` into `Core`, `Cache`, `Resolver`,
  `Converter`, `UI` and `AHTab` modules sharing the addon namespace. The
  conversion logic no longer touches the game API directly, which is what
  makes the offline tests possible.
- Replaced the deprecated `UIDropDownMenu` with Blizzard's current
  `WowStyle1DropdownTemplate` / menu API. The old one has been deprecated
  since 11.0, survives on a compatibility shim, and is a known taint
  vector.
- The output box no longer steals keyboard focus when the tab opens, which
  used to swallow movement keys until you pressed Escape. Use the new
  **Select All** button instead.
- The login message is now off by default; re-enable it with
  `/shopconv login on`.
- Auctionator is declared as a hard dependency rather than an optional
  one, so a missing or disabled Auctionator gives a clear message in the
  addon list instead of a silent failure at runtime. TradeSkillMaster is
  no longer listed at all — the addon never calls into it, it only
  produces text for it. CraftSim is listed as an optional dependency.
- Tab ordering and the Auction House width fix reach into LibAHTab's
  private state, so they are now pinned to the library minor version they
  were written against and skipped on anything newer, rather than risking
  an error on a changed structure.
- Release notes are no longer duplicated in the `.toc`; this file is the
  only copy.

## [1.2.2]

### Added
- The addon version now shows in the bottom-right corner of the
  Converter tab, and is printed to chat on login.
- MIT `LICENSE` file for the addon's own code, separate from the
  third-party license notices in `ATTRIBUTIONS.md`.

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
