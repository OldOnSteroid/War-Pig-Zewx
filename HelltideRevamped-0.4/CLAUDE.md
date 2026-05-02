# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

HelltideRevamped is a Lua automation plugin (v0.4) for Diablo IV that farms Helltide events. It runs inside a game scripting framework that provides globals like `get_local_player()`, `get_player_position()`, `actors_manager`, `pathfinder`, `loot_manager`, `graphics`, `console`, `vec3`, `utility`, `cast_spell`, etc. These are **not** standard Lua — they are injected by the host environment at runtime.

## Architecture

**Entry point**: `main.lua` — registers `on_update`, `on_render_menu`, and `on_render` callbacks. Exposes `HelltideRevampedPlugin` global for inter-plugin communication (enable/disable/status/getSettings/setSettings).

**Task system** (`core/task_manager.lua`): Priority-ordered task list. Each tick, iterates tasks and executes the first whose `shouldExecute()` returns true, then breaks (one task per pulse). Tasks are registered in order: `alfred` → `helltide` → `search_helltide`.

**Task priority and flow**:
1. **alfred** — Triggers when inventory is full and salvage is enabled. Delegates to the external AlfredTheButler plugin for town salvage runs. Blocks until Alfred completes.
2. **helltide** (`tasks/helltide.lua`) — Core state machine. Runs when player has the Helltide buff (hash `1066539`). States: INIT → EXPLORE_HELLTIDE → various interaction states (pyre, chests, ore, herb, shrine, goblin, chaos rift) → GO_NEAREST_COORDINATE → BACK_TO_TOWN. The `check_events()` function scans nearby actors by skin name to trigger state transitions.
3. **search_helltide** (`tasks/search_helltide.lua`) — Runs when NOT in Helltide. Cycles through 5 town waypoints (from `data/enums.lua` `helltide_tps`) teleporting to each to find an active Helltide zone. Falls back to Cerrigar when no Helltide is active (minute 55-59 window).

**Navigation**:
- `core/explorerlite.lua` — Lightweight A* pathfinder with MinHeap, grid-based (0.5m cells), 8-directional movement. Handles stuck detection, unstuck recovery, and path smoothing via angle threshold. Used for short-range movement to targets (chests, shrines, etc.).
- `core/explorer.lua` — Full explorer with explored-area tracking (circle-based), dungeon reset timer, and start-location logic. Not actively used by the Helltide task (helltide uses explorerlite + waypoint following).
- Waypoint files (`waypoints/*.lua`) — Large arrays of `vec3` coordinates defining patrol routes per region. Paired files: `<city>.lua` (patrol route) and `<city>_to_maiden.lua` (maiden event route). The helltide task follows these sequentially, randomizing each point slightly (±1.5m).

**Settings** (`core/settings.lua`): Syncs boolean toggles from GUI checkboxes. All feature toggles (salvage, silent_chest, helltide_chest, ore, herb, shrine, goblin, event, chaos_rift) are checked in the helltide task's `check_events()`.

**Data**:
- `data/enums.lua` — Chest type cinder costs and helltide teleport destinations (zone name, waypoint ID, file references, region prefix).
- `data/filter.lua` — Affix filters per equipment slot with SNO IDs. Color-codes items by match count (3+ = green, 2 = yellow, 1 = red). Currently informational/unused by the main loop.

**Key patterns**:
- Actor finding: `find_closest_target(skin_name_pattern)` uses `actors_manager:get_all_actors()` with `:get_skin_name():match()`.
- Movement: For waypoint patrol, uses `pathfinder.request_move()` directly. For target approach, sets `explorerlite:set_custom_target()` then calls `explorerlite:move_to_target()`.
- `explorerlite.is_task_running` flag prevents explorer's `on_update` from overriding task-driven movement.
- Time gating: `tracker.check_time(key, delay)` provides cooldown-style delays using `get_time_since_inject()`.

## External Plugin Integration

The plugin communicates with two optional external plugins:
- **AlfredTheButler** (`AlfredTheButlerPlugin` or `PLUGIN_alfred_the_butler` global) — Handles inventory salvage, repair, and restocking. Uses `trigger_tasks_with_teleport` / `pause` / `resume` API.
- **Looteer** (`LooteerPlugin` global) — When its `looting` setting is true, helltide task yields by setting `explorerlite.is_task_running = true`.

## Adding a New Waypoint Route

1. Create `waypoints/<name>.lua` returning a table of `vec3:new(x, y, z)` points.
2. Add an entry to `enums.helltide_tps` with zone name, waypoint ID, file name, maiden file, and region prefix.
3. Add the file name case to `load_waypoints()` in `tasks/helltide.lua`.

## Adding a New Interactable Target

Add detection logic to `check_events()` in `tasks/helltide.lua` following the existing pattern: check setting → `find_closest_target(skin_name)` → check interactable/distance → set state. Then add the corresponding state handler method to `helltide_task`.
