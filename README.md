# War Pig — Zewx

A curated plugin suite for Diablo IV that runs **War Plans** end-to-end. WarPigs is the master orchestrator: it watches your active War Plan quests and toggles the right sub-plugin for each activity. You play the meta-game — pick the plans you want to run — and WarPigs drives the rest.

## Important: build your War Plan first

Before enabling WarPigs, **open the War Plan board in-game and queue the activities you want to run**. WarPigs only activates a plugin when its matching `WarPlans_QST_*` quest is active in your log.

Supported activity types:
- **Helltides** (Tortured Gifts)
- **The Pit**
- **Infernal Hordes**
- **Boss Lairs** (boss runs via Reaper)
- **Kurast Undercity**

> **Nightmare Dungeons are NOT supported.** If you queue an NMD War Plan, WarPigs will not pick it up — no plugin in this suite drives NMDs. Skip NMD plans when building your War Plan.

The reward turn-in step (`WarPlans_QST_TurnIn_Rewards`) is handled internally — WarPigs teleports to Temis and walks to Tyrael for you.

## What's in the suite

| Plugin | Activity | Notes |
|---|---|---|
| **WarPigs-1.0.0** | Master orchestrator | The brain. Watches quests, enables/disables sub-plugins. Always required. |
| **AlfredTheButler-main** | Town services | Stash / salvage / sell / repair / restock between activities. Now ships with a **right-click stash fallback** for cases where the standard `move_item_to_stash` API stops making progress. |
| **ArkhamAsylum-1.0.6** | The Pit | Pit runner. Requires Batmobile + Alfred + Looteer v2. |
| **Batmobile-1.0.12** | (shared library) | Pathfinder/explorer used by ArkhamAsylum and WonderCity. Does nothing on its own. |
| **HelltideRevamped-0.4** | Helltides | Maiden routes, chests, ore/herb, shrines, goblins, chaos rifts. |
| **HordeDev-1.3.9** | Infernal Hordes | Spires/masses, pylons, aether, boss room, chest rewards. |
| **Reaper-main** | Boss Runs | Material + Lair Sigil farming for all boss lairs (Andariel, Duriel, Varshan, Grigoire, Zir, Beast, Harbinger, Urivar, Butcher, Belial). |
| **WonderCity-main** | Kurast Undercity | Tribute selection, enticements, beacons, boss, final chest. |

## Required companion plugins (not bundled)

These are external prerequisites — install them separately into your scripts directory:

- **Looteer v2** — loot pickup. Required by Arkham and WonderCity; recommended for everything else.
- **Orbwalker** (with Clear toggled on + Block Orbwalker Movement enabled) — combat for HordeDev and a hard requirement for Infernal Hordes.

## Quickstart

1. Drop every folder in this repo into your scripts directory (alongside `Alfred`, `Looteer`, `Orbwalker`, etc.).
2. Launch the game and load the framework.
3. Open each sub-plugin's menu once and configure to taste (loot modes, exit timers, glyph upgrade thresholds, tribute order, boss alignment for Reaper, etc.). Sub-plugin docs are in each subfolder's `README.md`.
4. **In-game**, open the War Plan board and queue plans for the supported activities listed above.
5. Open `Z | War Pigs | Orchestrator` and tick **Enable**.
6. Start your combat / orbwalker script if your queued plans need one.

WarPigs takes over from there: it enables the correct sub-plugin while a War Plan quest is active, defers disabling during post-quest wrap-up windows (e.g. Arkham collecting the glyphstone reward), and force-disables every managed plugin when no plan is active so nothing is left running.

## Boss Lair plan → boss mapping (Reaper)

WarPigs maps each boss-lair War Plan quest to a Reaper boss id:

| Quest substring | Boss |
|---|---|
| `WarPlans_QST_BossLair_Andariel` | andariel |
| `WarPlans_QST_BossLair_Harby` | harbinger |
| `WarPlans_QST_BossLair_Duriel` | duriel |
| `WarPlans_QST_BossLair_Varshan` | varshan |
| `WarPlans_QST_BossLair_PenitentKnight` | grigoire |
| `WarPlans_QST_BossLair_Zir` | zir |
| `WarPlans_QST_BossLair_MegaDemon` / `_Beast` / `_BeastInIce` | beast |
| `WarPlans_QST_BossLair_Urivar` | urivar |
| `WarPlans_QST_BossLair_Butcher` | butcher |
| `WarPlans_QST_BossLair_Belial` | belial |

A few quest suffixes are best-guesses (anything not marked CONFIRMED in `WarPigs-1.0.0/core/orchestrator.lua`). If a boss plan never triggers, enable **Log ALL quests** in the WarPigs menu, run that plan once to capture the real quest name, and update the map in `core/orchestrator.lua`.

## GUI options (WarPigs)

- **Enable** — master toggle. Off = no quest watching, all managed plugins forced off. Defaults to off on first load (don't auto-activate before you've configured anything).
- **Use keybind** — show the keybind row below. Off = the master toggle is the only gate.
- **Toggle Keybind** — when **Use keybind** is on, this hotkey gates WarPigs on top of the master toggle (key off / not toggled = same as Enable being off, releases all managed plugins). Mirrors HordeDev's keybind pattern.
- **Verbose logs** — print quest match/unmatch diffs to console.
- **Log ALL quests** — print every newly-seen quest name + id to console. Use this when adding a new activity or fixing a wrong boss-lair guess.

## Troubleshooting

- **Plugin not loaded** warning in the WarPigs menu → that plugin global wasn't published. Check load order, missing files, or a script error in that plugin.
- **Plan starts but plugin never activates** → flip on **Log ALL quests**, run the plan, and confirm the actual quest name contains the substring in the orchestrator map.
- **Plugin won't disable when plan ends** → most plans defer disabling for post-quest wrap-up. Pit / Undercity wait until you're back in town. Boss runs wait 60 s after the boss kill (loot + travel). Hordes waits until you leave the BSK world or 60 s. Helltide cuts immediately when the quest ends. All defers are force-capped at 120 s so a stuck activity can't block the orchestrator forever.
- **Two plugins start at the same time** → can't happen anymore. WarPigs sequences handoffs: previous plugin must report disabled, then a 5 s settle gap, then the next plugin enables.

## Changelog

### 2026-05-04
- **WarPigs: teleport transition — loot-safe trigger + reliability fixes**. The teleport sequence now fires from `plugin_disable()` (after the previous activity's `disable_when` predicate satisfies — Reaper kill+60 s, Pit/Undercity arrival in town, etc.) instead of on the next WarPlan's pattern-match edge. WarPlan quests unmatch the moment the boss dies, so the old trigger was Tab+clicking out of the dungeon before chests were opened or Alfred had salvaged. Now the orchestrator waits for chest loot, Alfred to finish, and `PLAYER_IN_TOWN_LEVEL_AREA` to flip true before tabbing out. Cold-start (first activity of a session) is handled explicitly. Click delay bumped 1.0 s → 1.5 s (the Quest panel fade-in was outracing the click on slower frames), and an explicit mouse-move now precedes the click so panels that gate clicks on a fresh mouse-position event actually register it. Holding-state logs explain *why* the sequence is paused (`in_town=… alfred_idle=…`).
- **WarPigs: teleport transition (experimental)**. New "Use teleport" toggle in the WarPigs menu. Between activities, the orchestrator can press **Tab** (open map / quest list), click a configured pixel target (typically the next WarPlan's quest icon), then wait for the teleport channel to settle before enabling the next plugin. Sub-options: X/Y pixel sliders, **F5 capture-cursor** keybind (hover the in-game target, press F5 to set X/Y), and a "Show click position" overlay that draws a green crosshair at the target plus a fading yellow ring on every scripted click. The enable gate and any task ticks (e.g. turn-in) are held until the sequence settles so nothing competes with the click.
- **HordeDev: pylon priority rebalanced**. `data/pylons.lua` reordered for the current season — Thriving / Fiendish Masses, Fiendish Legions, Blistering Hordes, and Surging Elites pushed up; Spire-focused boons demoted; a few stale entries removed.
- **Suite-wide: teleport & interact channel debouncing**. `teleport_to_waypoint`, `reset_all_dungeons`, and `interact_object` are multi-second channels — re-firing them every tick *cancels* the previous channel, so the bot was running around in place instead of arriving / interacting. Added per-task debounces in `WarPigs/turn_in_rewards` (6 s), `HelltideRevamped/search_helltide` idle-town TP (6 s), `HordeDev/exit_horde` Teleport mode (5 s), `WonderCity/exit_undercity` (always-on, was party-only — `confirm_delay` covers it), `ArkhamAsylum/exit_pit` (always-on, was party-only), and `WonderCity/interact_enticement` for beacons (1 s; the timeout clock now also starts on range entry instead of `is_interactable() == false` so a stale-flagged Grand Beacon can't lock the bot).
- **Suite-wide: stop Batmobile `long_path` before exit-task pauses**. Batmobile's main pulse re-runs `navigator.unpause() + update() + move()` every frame while `long_path.navigating` is true, which overrode our `pause` and walked the player toward the previous target — that movement cancelled the exit teleport channel. `ArkhamAsylum/exit_pit`, `WonderCity/exit_undercity`, and `HordeDev/exit_horde` (Teleport mode) now `stop_long_path()` and `clear_target()` before pausing.
- **WarPigs: activity-plugin preemption priority**. When multiple WarPlan quests match simultaneously, only the highest-priority one stays active. Static priorities: Pit (100) > Hordes (90) > Boss runs (80) > Undercity (50) > Helltide (40). Fixes the case where finishing a Kurast boss with an active Pit WarPlan would loop back into another Undercity run instead of handing off to Arkham. Demoted plugins fall through the normal disable path so an in-flight activity still gets to wrap up.
- **WarPigs: turn-in-rewards waits for town**. The IDLE→teleport branch now reads `PLAYER_IN_TOWN_LEVEL_AREA` and stays put while a dungeon plugin is still mid-exit. Stops the case where the dungeon's exit teleport and the reward turn-in's teleport fired together and cancelled each other's channels.
- **ArkhamAsylum + WonderCity: short-range `force_move_raw` near the pit obelisk / spirit brazier**. Both targets sit on non-walkable terrain, so Batmobile's A* returns `limit_partial`, the partial-path watchdog clears the custom target, and the explorer drags the bot off to a frontier ~17 units away — cue ping-pong: walk to objective → "no target, selecting new" → walk to frontier → re-fire → loop. Inside 7 m the navigator now skips Batmobile entirely and uses `pathfinder.force_move_raw`, so the bot holds position long enough to interact.
- **ArkhamAsylum: max glyph level slider 100 → 150**. Future-proofing for season patches that raise the cap.
- **Reaper: configurable home town**. New "Home town" combo box (Temis / Cerrigar) in the Reaper settings tab. All hard-coded Cerrigar references in `main.lua`, `interact_altar.lua`, `navigate_to_boss.lua`, and `sigil_complete.lua` now resolve through `settings.town_zone` / `settings.town_waypoint`. Defaults to **Temis** to match ArkhamAsylum and Alfred — set this to whatever your other plugins use so all the between-run TPs land in the same place.
- **WarPigs: re-fire enable on pattern change**. ReaperPlugin can be driven by multiple WarPlan quests (e.g. `_Zir` → `_Varshan`). Previously, when the matched pattern changed for an already-owned plugin the orchestrator's edge-trigger short-circuited and the plugin kept running the old boss. Now the orchestrator tracks `last_enabled_reason` per plugin; on a pattern change it re-fires `enable()` so the plugin's hook (e.g. `run_boss('varshan')`) takes effect, and clears the stale defer (the old boss's kill+60 s timer is irrelevant once we hand off).
- **WarPigs: keybind toggle + safer default**. New `Use keybind` checkbox + `Toggle Keybind` row gates WarPigs on/off via a hotkey on top of the master toggle (mirrors HordeDev's pattern). When the keybind is unset/untoggled WarPigs acts as if disabled — managed plugins are released and run autonomously again. The master `Enable` checkbox now defaults to **off** so a fresh load doesn't immediately seize control of every plugin in the suite before you've configured it.
- **WarPigs: Zir quest name confirmed**. `WarPlans_QST_BossLair_Zir` is the real quest name (id=2317384, captured 2026-05-03). Replaces the `_S2VampireLord` asset-name guess in the orchestrator map and README boss-lair table.
- **ArkhamAsylum: dedicated boss task + glyphstone anchor**. Pit guardian now has its own `kill_boss` task (higher priority than portal / explore_pit / kill_monster) so trash can't pull the bot off the boss. Boss position is remembered across player death — after revive the bot pathfinds back without exploring or chasing trash. After the kill, an anchor is set on the death position (then snapped onto the glyphstone when it spawns) and `explore_pit` holds within 6 m of it indefinitely instead of relying on the old 10 s fixed freeze, so a slow-spawning glyphstone can't cause a wander-off.
- **HordeDev: Exit mode toggle (Reset / Teleport)**. New GUI option. Teleport mode skips the boss-room walk and the 5 s wait — straight TP to the Library waypoint after the run.
- **HordeDev: graded stuck recovery in `walking_to_horde`**. Replaces the single 12 s "re-teleport to Library" watchdog with three escalating stages: 4 s nudge (re-snap to nearest waypoint, force fresh Batmobile target with smaller lookahead) → 8 s micro (bypass Batmobile, drive per-waypoint with the explorer fallback) → 12 s tele (re-teleport to Library, existing behavior). 20 s recovery cooldown so it can't thrash.
- **Reaper: Doom/theme chest removed**. D4's 2026-05-03 patch removed the seasonal `S12_Prop_Theme_Chest_*` actor entirely. The whole THEME phase, doom-chest scanning, `sigil_chest_done` state, and 20 s post-chest hunts are gone (~190 lines from `open_chest.lua`, ~30 from `sigil_complete.lua`). Material runs now complete on the EGB/boss chest open; sigil runs complete on the enemy-cleared timer alone.
- **WonderCity: Exit mode toggle (Reset / Teleport)**. Same option as HordeDev — Teleport mode tps back to the configured town waypoint instead of resetting all dungeons.
- **WonderCity: brazier/portal actor lookup fix**. `get_spirit_brazier()` and `get_entrance_portal()` switched from `get_ally_actors()` (which returned nil — the brazier and entrance portal are not in the ally list) to `get_all_actors()`. Previously the enter task would stick on idle waiting for an actor it could never see.
- **WonderCity: brazier interact watchdog**. If `interact_object` is spammed at the brazier for 3 s with no vendor screen response, lower the close-enough threshold (2.0 m → floor 0.6 m, 0.4 m steps) so the next tick walks closer instead of looping forever at "almost there." Resets on success.
- **WonderCity: `walk_kurast` yield-window fix**. `shouldExecute` now yields at the same distance `Execute` considers "arrived" — closes a small window where the walk task returned true while doing nothing, blocking `enter_undercity` from walking the last few meters to the brazier.

### 2026-05-03
- **Reaper: external rotations are now strictly single-shot**. Fixes a bug seen in the wild where a stuck/non-despawning chest (butcher this season) let the altar re-arm up to 6× before WarPigs's 120 s force-disable kicked in. New `external_consumed` flag locks `consume_run` to one call per rotation; the altar task hard-rejects any further interaction once that fires; the material-inventory recheck (which would otherwise re-extend the run) is skipped entirely for external rotations.
- **Reaper: 25 s "no chest still counts" window for external runs**. Some war plans now complete on the kill alone — no chest drops at all. After 25 s post-altar with no chest, the rotation force-completes so WarPigs's 60 s post-kill timer can start cleanly and the plan moves on. Inventory-driven (non-orchestrator) runs keep the original 60 s deadlock-retry path.
- **WarPigs: extra Beast-in-Ice quest aliases**. Map now lists `WarPlans_QST_BossLair_MegaDemon` (asset-name guess), `_Beast`, and `_BeastInIce` — whichever name Blizzard actually used will match. Use the WarPigs **Log ALL quests** option to confirm and trim the misses.

### 2026-05-02
- **WarPigs orchestrator: transition sequencer**. Adds a 5 s settle gap between disabling the outgoing plugin and enabling the next one, plus a 120 s safety cap so a stuck activity can never block the orchestrator forever. Pit / Undercity share an in-town disable predicate (waits for `PLAYER_IN_TOWN_LEVEL_AREA`); Helltide cuts immediately when the quest ends. Boss runs use a Reaper kill tracker (snapshots `total_runs` at enable; defers disable for 60 s after the counter ticks).
- **WarPigs orchestrator: enable hardened**. Wraps plugin `enable()` in `pcall` and trusts `status()` over the exit path — a partial enable (e.g. HR setting `main_toggle` then crashing on a missing `keybind_toggle`) no longer infinite-loops re-enabling. Self-disabled plugins (e.g. Reaper "Nothing to farm — Stopping") short-circuit, clearing deferrals so the next plan can start immediately.
- **HelltideRevamped: missing GUI element guard**. `HelltideRevampedPlugin.enable()` / `disable()` no longer crash when `gui.elements.keybind_toggle` is absent — important for headless / orchestrator-driven enables.
- **HordeDev: walking-to-horde stuck watchdog**. If the player hasn't moved 1.5 m in 12 s while the `walking_to_horde` task is active (post-teleport cooldown elapsed), re-teleport to the Library waypoint and reset Batmobile state. 20 s recovery cooldown so it doesn't thrash.

## Credits

Each sub-plugin lists its own author/contributors in its folder's `README.md`. This suite is a curated bundle, not a single-author project — credit goes to the original plugin authors:

- Zewx · Pinguu · NotNeer · Letrico · SupraDad13 · Lanvi · RadicalDadical55 · Diobyte · TesXter · and the HordeDev community thread

Bundled and orchestrated by **Zewx**.
