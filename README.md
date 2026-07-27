# Shopping Converter

A World of Warcraft addon that adds a **Converter** tab to the Blizzard
Auction House frame, converting an [Auctionator](https://www.curseforge.com/wow/addons/auctionator)
shopping list into a [TradeSkillMaster](https://www.tradeskillmaster.com/)-compatible
search string, ready to paste into TSM.

## Features

- Adds a "Converter" tab to the Auction House window (via the embedded
  LibAHTab library, avoiding taint issues from manual AH tab hacks).
- Reads a shopping list from Auctionator through its public API and
  converts each entry to TSM's `i:<itemID>/x<qty>` search syntax, joined
  with semicolons.
- Preserves crafting-reagent quality (Auctionator's tier field), so a
  rank 1 reagent doesn't silently become rank 3.
- Reads item IDs straight out of [CraftSim](https://www.curseforge.com/wow/addons/craftsim)'s
  craft queue when it's installed, making the common case instant.
- Caches every resolved item ID across sessions, so repeat conversions of
  an evolving craft queue don't re-query the Auction House.
- Splits output too long for TSM's search box into parts you can page
  through and paste one at a time.
- Dropdown to pick which shopping list to convert, a Refresh button, and a
  `/shopconv` command for use away from the Auction House.

## Requirements

- [Auctionator](https://www.curseforge.com/wow/addons/auctionator) — required.
  The addon reads shopping lists through its API and will not load without it.
- [CraftSim](https://www.curseforge.com/wow/addons/craftsim) — optional, but
  makes conversion of its `CraftSim CraftQueue` list dramatically faster.
- [TradeSkillMaster](https://www.tradeskillmaster.com/) — optional; this is
  the tool the output string is meant for. Shopping Converter never calls
  into TSM, it just produces text.

## Installation

1. Copy the `ShoppingConverter` folder into your
   `World of Warcraft/_retail_/Interface/AddOns/` directory.
2. Make sure Auctionator is installed and enabled.
3. Restart or reload the game client.

## Usage

1. Open the Auction House.
2. Click the **Converter** tab.
3. Pick a shopping list from the dropdown.
4. The TSM search string is generated automatically and selected as soon as
   it's ready - copy it and paste it into TSM's search field. Click
   **Select All** to reselect it later.
5. Click **Refresh** to re-run the conversion at any time.

If the string was split into several parts, use the **`<`** and **`>`**
buttons to page through them and paste each one separately.

### Slash commands

| Command | Effect |
| --- | --- |
| `/shopconv` | Jump to the Converter tab (Auction House must be open) |
| `/shopconv lists` | List the available Auctionator shopping lists |
| `/shopconv convert <name>` | Convert a list into a copyable window, no AH needed |
| `/shopconv cache` | Show item cache statistics |
| `/shopconv cache clear` | Empty the item cache |
| `/shopconv cache on\|off` | Reuse resolved item IDs between sessions |
| `/shopconv craftsim on\|off` | Read item IDs from CraftSim's craft queue |
| `/shopconv login on\|off` | Print a version message at login |

## How it works

The hard part is turning an item *name* into an item *ID*, because that's
all an Auctionator shopping list stores. Crafting reagents make it harder:
each quality rank is a separate item ID sharing one display name, so a name
lookup alone can silently resolve to the wrong rank.

Shopping Converter tries four sources, cheapest first:

1. **CraftSim's craft queue.** CraftSim already knows the exact item ID and
   quality of every reagent it queued, and discards that when it writes the
   Auctionator list as plain names. Reading the queue back recovers them for
   free, with no Auction House traffic at all.
2. **The persistent cache**, keyed by name and quality rank and dropped
   whenever the game build changes.
3. **A local client lookup**, which only works for items already in the
   client's item cache.
4. **A live Auction House browse query** — correct but slow, and it replaces
   whatever you had searched on the Browse tab. Queries are serialized one at
   a time with a courtesy delay, respect the server's throttle, and verify
   the returned item's name and quality rank actually match what was asked
   for (browse queries match on substring, so `Ironclaw Ore` will also
   return `Ironclaw Ore Fragment`).

Anything that still can't be resolved falls back to a plain name search term
rather than being dropped, and the status line says how many did so.

Auctionator search terms can also carry price caps, level ranges and
category filters that have no TSM search-string equivalent. Those are
counted and reported rather than silently discarded.

## Development

The conversion logic and the item cache have no dependency on the game
client and are covered by an offline test suite:

```sh
lua Tests/run.lua
```

The resolver is injected as a stub, so the tests exercise term parsing,
quality-rank handling, delimiter escaping, ordering across asynchronous
resolutions, and output chunking without WoW running.

## License

MIT — see [LICENSE](LICENSE). Third-party libraries embedded in `Libs/`
are under their own licenses; see [ATTRIBUTIONS.md](ATTRIBUTIONS.md).
