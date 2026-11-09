# Changelog

## v1.1.1

- Hovering a red quest line (a quest you do not have) now says which quest it is, where it starts and which quests have to be done first, or that you can pick it up now; clicking the line opens Missing Prerequisites at that quest.

## v1.1.0

The same as v1.0.16, which went out a few minutes earlier under the old numbering; the new window starts version 1.1.

This version adds two files: restart the game after updating, `/reload` is not enough.

- New window "Missing Prerequisites" (the quest-giver icon on the guide's header bar, or `/rxpstyle prereqs`), in the look of the DungeonJournal addon. It lists every quest of the current guide that you cannot pick up yet because a quest before it is not done and the guide does not do it, or that the guide hands in but you never picked up, and for the selected quest the whole chain of quests that unlocks it, earliest first: level, who starts it and where, and whether you can take it now. Hovering one shows Questie's tooltip; clicking one sets a TomTom waypoint to where it starts. Needs Questie for the prerequisites.
- Quests Questie's database does not know are listed there too, greyed out, and saved with the addon's settings; their prerequisites can be added by hand in PrereqFixes.lua, which comes before Questie's data.
- Quest experience (at your level, as in Questie's tooltips), to weigh doing a chain against skipping it: the whole chain's (the missing quests, the guide's quest and the rest of the chain after it) above the list and in the left list, with a breakdown, each quest's in its row, and the quests after the guide's quest listed with theirs.
- Every quest in a chain shows its objective and has three Show on Map buttons: Starts and Ends open the world map with a pin where the quest starts or is handed in, Objective marks every spot where it is done (the NPCs to kill, the objects to use, whoever drops the items, the places to find), on your own map when it has some, else the map with the most (plus a TomTom waypoint with TomTom; the window steps aside until the map closes), and a Share button in the DungeonJournal look, which shares the quest with your group once it is in your quest log. Shift-click on Share or on the quest links it in chat.

## v1.0.15

- With Questie: hovering a quest line (pick up, work on, hand in; current and upcoming steps) shows the tooltip of that quest's pin on Questie's map, and Shift shows experience, money and the rest of the quest chain there too. Option "Questie tooltips on quest lines".

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
