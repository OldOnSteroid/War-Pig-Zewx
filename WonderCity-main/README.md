# WonderCity
#### V1.0.4
## Description
WonderCity is the new undercity utilizing a newer (and possibly more efficient) explorer (batmobile).
Fully integrated and requires Alfred the butler, Batmobile and Looter.

WARNING: the only build that I have reliably able to complete Mythic tributes is crackling sorc with both tele enchant and teleport enabled on batmobile.

## Settings
- Enable -- checkbox to enable or disable WonderCity
- Use Keybind -- checkbox to use keybind to quick pause/resume WonderCity
    - Toggle keybind - toggle pause/resume

### undercity Settings
- Batmobile priority -- set batmobile's exploration priority
    - DIRECTION -- batmobile will priortize exploring the same direction
    - DISTANCE -- batmobile will prioritize exploring furthest distance from start. May result in more backtracking
- Reset time -- how long in seconds to give up on current undercity
- Exit delay -- how long to wait in seconds before initiating exit when all task are done or when reset time is up
- Boss delay -- how long to wait in seconds before start attacking boss
- Max enticement -- maximum number of enticement to activate
- Enticement timeout -- how long to wait in seconds around enticement
- Beacon timeout -- how long to wait in seconds around beacon
- Loot obols -- checkbox to move and pick up obols
- Reorder tribute -- checkbox to use stash to reorder tributes to the first slot if first slot is not correct tribute
- Tribute 1/2/3 -- choose which tribute that should be on the first slot

### Party Settings (coming soon™)
- Enable Party mode -- checkbox to enable party specific interaction, only needed if you are planing to play in party
- Party mode -- choose whether you are the party leader (the one that will complete the undercity) or follower
- Accept delay -- choose how long to wait for followers to accept start undercity/reset undercity notification before retrying
- Follower explore? -- choose whether or not to explore undercity as follower 

## Changelog
### V1.0.4
Fix  reorder tribute triggering even when not enabled

### V1.0.3
Implemented Reorder tribute

### V1.0.2
Fix bug where exit triggered too early due to exploration is done but boss is not dead

### V1.0.1
Added safeguard to only exit if final chest is seen

### V1.0.0
Initial release

### V0.0.8
Added option to set batmobile priority
Added spirit brazier as final point in path (fix janky movement after exit)
Changed logic for enticement timeout so that it doesnt move back if timer expired while far away
Added goblins to priority for kill_monsters

### V0.0.7
increased check distance
reduce priority of loot obols below enticement
added max enticement

### V0.0.6
disable explore once boss is found

### V0.0.5
fix obols again

### V0.0.4
added goto_chest file!
fix obols not near enticement not picking up

### V0.0.3
added distance check (16) to portal and enticement.
ignore obols that spawned in beacon.
Added goto_chest task to mark as done

### V0.0.2
Priortize enticement/beacon over portal.
kill_monsters only target boss now. 
Introduced enticement/beacon delay. 
Target portal warppoint instead of just portal.
Updated enticement logic

### V0.0.1
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
- TesXter