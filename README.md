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
- Auto-populates a copyable, select-all text box as soon as the tab is
  opened.
- Dropdown to pick which Auctionator shopping list to convert. Defaults
  to a list named "CraftSim CraftQueue" if one exists, otherwise
  remembers the last list you picked (saved per account).
- Preserves crafting-reagent quality (Auctionator's tier field): items
  with a quality requirement, or that aren't in the local item cache,
  are resolved via a live Auction House search so the correct quality
  rank is picked rather than guessed from name alone.
- Refresh button to re-run the conversion on demand.

## Requirements

- [Auctionator](https://www.curseforge.com/wow/addons/auctionator) (required — the addon reads shopping lists through its API)
- [TradeSkillMaster](https://www.tradeskillmaster.com/) (optional — this is the tool the output string is meant for)

## Installation

1. Copy the `ShoppingConverter` folder into your
   `World of Warcraft/_retail_/Interface/AddOns/` directory.
2. Make sure Auctionator is installed and enabled.
3. Restart or reload the game client.

## Usage

1. Open the Auction House.
2. Click the **Converter** tab.
3. Pick a shopping list from the dropdown.
4. The TSM search string is generated automatically and selected in the
   text box — copy it and paste it into TSM's search field.
5. Click **Refresh** to re-run the conversion at any time.

## How it works

For each item in the shopping list, the addon first tries a local,
synchronous item lookup. If the item has no quality-tier requirement, or
the locally resolved item's tier matches what was asked for, that result
is used directly. Otherwise (an ambiguous tier, or an item not cached
locally), it falls back to a live Auction House browse query — the same
approach Auctionator itself uses — to find the itemID whose quality rank
actually matches. Items that can't be resolved either way fall back to a
plain name search term so nothing is silently dropped. Live lookups are
serialized with a short courtesy delay between queries, so the status
line shows progress while the conversion completes asynchronously.

## License

See [ATTRIBUTIONS.md](ATTRIBUTIONS.md) for third-party library licenses.
