# Batmobile (explorer/navigator)
#### V1.0.12
## Description
Batmobile itself does not do anything, but it provides other plugins to utilize it for exploring and path finding.
For exploration:
    - it normalizes coordinate system to 0.5 accuracy
    - it uses DFS and closests direction to previous target to choose exploration target
    - it passes the target to A* pathfinder to find the best route to target

Batmobile also handles any traversals in game if move command is given.

## Settings
- Toggle Drawings -- toggle to draw path, backtrack and status
- Use movement spells -- toggle to use movement spell as part of movement or not
- Reset Batmobile -- keybind to reset visited, frontier, backtrack, path and retries

### Movement spells
- checkboxes for movement spells available to your class. requires "Use movement spells" to be toggled on.

### Debug
- Toggle Explorer -- toggle to freeroam with explorer
- Logging -- set log level

## Example integrations
TBD (Arkham Asylum is integrated, so check there in the mean time)

## Changelog
### V1.0.12
Added paladin advance skill as movement spell

### V1.0.11
Optimized distance priority to correctly change direction after 2x travelling closer to start

### V1.0.10
Optimized handling of backtrack for distance priorty

### V1.0.9
Adjusted frontier_max_dist to 27 (sqrt(frontier_radius^2*2) + backtrack dist)
Added new priority option for exploration
    - previously only closest distance
    - [experimental] added priortizing furthest distance from 1st backtrack node (starting point)

### V1.0.8
Fixed bug sometimes it doesnt ignore nodes next to wall properly.
Fixed bug where if starting point is close to wall, it failed to navigate away.

### V1.0.7
Improved pathfinder logic to reduce overall processing power
Updated pathfinder to only ignore nodes if the target is given by explorer

### V1.0.6
Updated navigator to have delay of 0.5 seconds between movement spell cast
Updated pathfinder to ignore nodes that is right next to wall
Updated explorer to keep direction of frontier and backtrack
Adjusted multiple radii

### V1.0.5
Adjusted multiple radii for explorations and backtrack to reduce number of backtrack nodes

### V1.0.4
Fixed backtrack logic not working properly when no path is found.

### V1.0.3
Updated movement spell logic to follow path instead of direct to target and also blacklist node from repeated movement spell

### V1.0.2
Added disable_spell to set_target parameter
setting disable_spell to true, will disable all movement spell while navigating to target

### V1.0.1
Added debug section
Added toggle explorer to debug section
Moved logging to debug section

### V1.0.0
Initial release

### V0.0.1 - V0.0.13
Beta test

## To do
- expose settings that can be configurable

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
