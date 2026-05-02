# ArkhamAsylum + Batmobile — Diablo Pit Runner

## Project structure
Two plugins work together:
- **ArkhamAsylum-1.0.6** (this dir) — task orchestration, pit management
- **Batmobile-1.0.12** (sibling dir) — navigation, exploration, pathfinding

Changes to navigation/pathfinding logic almost always happen in Batmobile. Changes to task priorities, kill logic, and pit-flow happen in ArkhamAsylum.

## Key files
- `ArkhamAsylum-1.0.6/core/task_manager.lua` — task priority order
- `ArkhamAsylum-1.0.6/tasks/kill_monster.lua` — enemy targeting + progress tracking
- `ArkhamAsylum-1.0.6/tasks/explore_pit.lua` — delegates to BatmobilePlugin
- `Batmobile-1.0.12/core/navigator.lua` — movement, pathfinding loop, traversal handling
- `Batmobile-1.0.12/core/explorer.lua` — frontier BFS exploration
- `Batmobile-1.0.12/core/pathfinder.lua` — A* implementation
- `Batmobile-1.0.12/core/external.lua` — public API (BatmobilePlugin)

## Task priority (highest first)
teleport_cerrigar > d4assistant > upgrade_glyph > alfred > enter_pit > portal > exit_pit > follower > interact_shrine > push_monsters > **kill_monster** > **explore_pit** > idle

## Pit detection
- Zone is `PIT_Subzone` on every floor; world name varies per floor and per pit, but always starts with `PIT_` (e.g. `PIT_Ancients_Sand`, `PIT_ProtoDun_Root`)
- Use `utils.player_in_pit()` (matches world-name prefix `PIT_`) for the in-pit gate
- Up to 5 floors per pit; no dedicated boss room — boss spawns on the final floor and a sigil NPC appears after the kill
- Floor portal actor: `Prefab_Portal_Dungeon_Generic` (same actor descends to the next floor)
- The `EGD_MSWK_World_02` branch in [kill_monster.lua](tasks/kill_monster.lua) (`effective_distance=50`) is dead code — kept pending boss/sigil rework

## Navigation concepts
- `navigator.paused=true` means an external task (kill_monster) has taken control
- `navigator.is_custom_target=true` means kill_monster set the target (not the explorer)
- Traversals are `Traversal_Gizmo` actors — interactive teleport points (cliffs, ropes, jumps)
- The A* pathfinder works on flat 2D walkable tiles; it CANNOT route through traversals
- `utils.distance` is XY-only (Chebyshev) — ignores Z level entirely

## Debugging
- Logs print to in-game console (look for `[nav]`, `[select_target]`, `[BATMOBILE PERF]`)
- User provides log files for diagnosis; work iteratively from logs
- Do not remove existing `console.print` calls — they are needed for ongoing debugging
