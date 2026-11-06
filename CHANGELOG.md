# Changelog

## v1.0.14

- The guide no longer stays hidden when the quest tracker has no position: with nothing tracked, Blizzard hides its tracker and never lays it out, and the guide waited for it forever. It now stands where the hidden tracker would be, worked out from the frame the tracker is attached to.
- The guide remembers its last spot below the quest tracker across reloads and uses it until the tracker can be measured again, so it no longer appears late or at the wrong place after loading.

## v1.0.13

- The guide now takes the quest tracker's place instead of collapsing it: Blizzard's tracker is hidden while a guide is shown, and a copy of its header bar with the + button brings it back. Collapsing it from addon code tainted the tracker and the world map, which logged blocked actions in combat. This fixes the known issue of v1.0.12; the option is now called "Guide in place of the quest tracker".
- The guide no longer reads the quest tracker's position while the game is still laying it out. That read could taint the tracker even when it was not collapsed, and the world map then logged blocked actions in combat.
- The auction house button on guide lines also works with Auctionator: it puts the item with the quantity still needed on the Auctionator shopping list "RestedXP Guide".
- It also works with Auctioneer, which has no shopping list: it puts the item on the snatch list of Auctioneer's Search UI at up to its market price. An item already on that list keeps its price.

## v1.0.12

- With the Forever Auction addon: a small auction house button on guide lines that want an item from the auction house puts it on its shopping list.
- While the quest tracker is open, the guide keeps room for its current step below it, even past the cut-off line.
- Known issue: "Collapse the quest tracker" can log blocked actions when the world map loads quest pins in combat, and a right-click on such a pin may not zoom out. Turn the option off if that bothers you.

## v1.0.11

- New "?" button on the guide's header bar, or `/rxpstyle report`: shows the current step and the active quests as text to copy into a bug report.

## v1.0.10

- First public release.
- The header bar now stays visible when the character has no guide loaded, for example when the saved guide belongs to the other faction. Right-click it to pick a guide. Before, no guide window was reachable at all.
