# Changelog

## v1.4.0

This version adds two files: restart the game after updating, `/reload` is not enough.

- New option "Tag spell in the target macro": pick one of your spells, and RestedXP's target macro (RXPTargeting) also casts it, so one key press targets the mob of the current step and tags it. The line is kept through every step; in a fight it is added afterwards.
- Route planner in Missing Prerequisites: tick quests in the list (kept per character), then use Generate route.
  - Hover: travel time and the XP of the detour (handed in on the way, and opened up in the guide).
  - Click: the route becomes a RestedXP guide of its own; RestedXP returns to your guide after it.
  - Right-click: shows the route in the window; click a stop for a TomTom waypoint.
  - While the route guide runs, Missing Prerequisites still lists your own guide's quests.
  - Flight steps point the arrow at the flight master; a waypoint set by clicking a stop is removed when the guide is made.
  - The route guide reroutes itself: it is planned again from where you are when you leave the way, change zone, land, use your hearthstone, take or hand in a quest, or learn a flight point.
  - It keeps the order of the stops unless a new order saves more than a minute and a tenth of the trip, and is only loaded anew when the steps ahead change. Option "Reroute the route guide".
  - Starts with the stop nearest in travel time from where you are.
  - Knows your flight points (RestedXP's flight times), ships, zeppelins, skycutters and the tram, including Forever's new routes, your hearthstone (once) and a mage's teleports.
  - A ship or zeppelin counts 3 minutes (1 caught, 5 missed). On foot: straight lines inside a zone, through the passes between zones.
- With the DungeonJournal addon: a Generate route button on its quest list.
  - One trip that picks up the dungeon's quests, with the quests to do first, and ends at the entrance.
  - Hover: travel time, XP, the stops and what was left out. Click: the trip as a RestedXP guide.
  - Only there when DungeonJournal is installed. Option "Generate route in DungeonJournal".
- Other addons can use the route planner (`RXPBlizzStyleAPI`).
- `/rxpstyle report` has a "Map pins" section: RestedXP's pin settings, the waypoints of the next steps, and the pins on the map and minimap.
- Missing Prerequisites groups its list by where each quest's trip begins: the town or landmark when the first quest to pick up starts at one (Goldshire, Booty Bay), else the zone. Quests that start from an item have their own group.
- Missing Prerequisites now lists a quest the guide still works on or hands in when you are already past the step that picks it up and do not have it. Before, a click on its red line opened the window without an entry for it.
- A quest that starts from an item you do not have (like Crystal in the Mountains from the Pendant of Myzrael) no longer says "You can pick it up now": the tooltip and the window name the item and where it comes from.
- A click on a red quest line whose quest has no entry in Missing Prerequisites says so in chat instead of showing another quest.

## v1.3.2

- Fixed an error right after login ("attempt to index field 'currentGuide'"): the addon asked RestedXP to check the steps before RestedXP had loaded a guide.

## v1.3.1

- The close button of Missing Prerequisites works during a fight again.

## v1.3.0

- Picking a guide that has missing prerequisites asks whether you want to review them (not when the game loads or reloads the guide you already had). Option "Ask about missing prerequisites".
- Steps RestedXP skips on its own for a missing prerequisite ("Step skipped: Missing pre-requisites": the quest is not in your log, or a quest before it is not done) now stay in the guide with a red line naming the missing quest. Click the line to see it in Missing Prerequisites, tick it off to skip the step. Option "Keep steps with missing prerequisites".
- Scrolling up over the upcoming steps (or their header) goes on past the current step to the previous steps, like scrolling up in RestedXP's step list. A small arrow on the header jumps back; Shift-click a previous step to go back to it.
- Going back (back arrow or Shift-click on a previous step) now stays on that step even when it is done, instead of RestedXP jumping forward again at once. The next arrow walks forward step by step; a round arrow on the header returns to where you were.

## v1.2.0

- New settings page Options > AddOns > RestedXP Blizzard Style > Display: Scale, Width, Height and Anchor (Top / Bottom). Attached, the guide stays below the quest tracker and moves with it in Edit Mode.
- Anchor Bottom works like RestedXP's "Current step frame anchor": the current step at the bottom, the next steps above it, the guide growing upwards.
- The yellow line now sets the guide's height instead of a fixed line on the screen; the old line is taken over as the height. "Cut the guide off at a line" is now "Limit the guide's height".
- A small info button next to a step's title shows the quests that follow the step's quests in their chains (from Questie): level, experience, whether you did them, and whether this guide does them (with its step) or not.
- Missing Prerequisites no longer lists a quest the game hands out when the guide turns in the quest before it (like The Missing Diplomat after the fight at Sentry Point); quests whose step RestedXP only does when you already have them are marked optional.

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
