# Arkham Asylum (Pit)
#### V1.0.6
## Description
Arkham Asylum is the new pit utilizing a newer (and possibly more efficient) explorer (batmobile).
Fully integrated and requires Alfred the butler, Batmobile and Looteer v2.

## Settings
- Enable -- checkbox to enable or disable arkham asylum
- Use Keybind -- checkbox to use keybind to quick pause/resume arkham asylum
    - Toggle keybind - toggle pause/resume

### Pit Settings
- Batmobile priority -- set batmobile's exploration priority
    - DIRECTION -- batmobile will priortize exploring the same direction
    - DISTANCE -- batmobile will prioritize exploring furthest distance from start. May result in more backtracking
- Pit level -- which pit level to run
- Reset time -- how long in seconds to give up on current pit
- Exit delay -- how long to wait in seconds before initiating exit when all task are done or when reset time is up
- Exit mode -- choose to either exit by reset dungeon or teleport out
- Return for loot -- checkbox to return for loot after alfred is done or abandon remaining loot on floor to start new pit
- Enable shrine interaction -- checkbox to interact with shrine while exploring pit
- Enable glyph upgrade -- checkbox to choose to upgrade glyphs or not
- Upgrade mode -- choose between upgrading higest glyph first or lowest glyphs first
- Upgrade threshold -- only upgrade glyph have have upgrade % > than threshold
- Minimum level -- only upgrade glyphs that are >= minimum level
- Maximum level -- only upgrade glyphs that are <= maximum level
- Upgrade to legendary -- choose to upgrade glyph to legendary or not

### Party Settings
- Enable Party mode -- checkbox to enable party specific interaction, only needed if you are planing to play in party
- Party mode -- choose whether you are the party leader (the one that will complete the pit) or follower
- Accept delay -- choose how long to wait for followers to accept start pit/reset pit notification before retrying
- Follower explore? -- choose whether or not to explore pit as follower 

## Changelog
### V1.0.6
Added option to set batmobile priority
Set portal priority to be higher than follower afk (so that follower still goes in portal)

### V1.0.5
fix missing betrayer eye due to blizzard making it not interactable

### V1.0.4
optimized enter pit
removed raycast check for monsters

### V1.0.3
Reduced distance for disabling batmobile's movement spell to <= 4 so that it still uses movement spell to close the gap until distance of <= 4.
It improves movement to shrine/portal/glyphs for both evade spiritborn and other classes

### V1.0.2
Disable batmobile's movement spell while navigating to shrine and glyph (for evade spiritborn)

### V1.0.1
Disable batmobile's movement spell while navigating to portal (for evade spiritborn)

### V1.0.0
Initial release

### V0.0.1 - V0.0.11
Beta test

## To do
Magoogle D4 assistant integration

## Credits
In no particular order, the following have provided help in various form:
- Zewx
- Pinguu
- NotNeer
- Letrico
- SupraDad13
- Lanvi
- RadicalDadical55
- Diobyte