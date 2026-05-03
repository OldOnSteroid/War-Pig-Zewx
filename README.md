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
| `WarPlans_QST_BossLair_S2VampireLord` | zir |
| `WarPlans_QST_BossLair_MegaDemon` | beast |
| `WarPlans_QST_BossLair_Urivar` | urivar |
| `WarPlans_QST_BossLair_Butcher` | butcher |
| `WarPlans_QST_BossLair_Belial` | belial |

A few quest suffixes are best-guesses (anything not marked CONFIRMED in `WarPigs-1.0.0/core/orchestrator.lua`). If a boss plan never triggers, enable **Log ALL quests** in the WarPigs menu, run that plan once to capture the real quest name, and update the map in `core/orchestrator.lua`.

## GUI options (WarPigs)

- **Enable** — master toggle. Off = no quest watching, all managed plugins forced off.
- **Verbose logs** — print quest match/unmatch diffs to console.
- **Log ALL quests** — print every newly-seen quest name + id to console. Use this when adding a new activity or fixing a wrong boss-lair guess.

## Troubleshooting

- **Plugin not loaded** warning in the WarPigs menu → that plugin global wasn't published. Check load order, missing files, or a script error in that plugin.
- **Plan starts but plugin never activates** → flip on **Log ALL quests**, run the plan, and confirm the actual quest name contains the substring in the orchestrator map.
- **Plugin won't disable when plan ends** → some plans (Pit, Hordes) defer disabling for post-quest wrap-up. Pit waits until you leave `PIT_Subzone`; Hordes waits until you leave the BSK world or 60 s, whichever comes first.

## Credits

Each sub-plugin lists its own author/contributors in its folder's `README.md`. This suite is a curated bundle, not a single-author project — credit goes to the original plugin authors:

- Zewx · Pinguu · NotNeer · Letrico · SupraDad13 · Lanvi · RadicalDadical55 · Diobyte · TesXter · and the HordeDev community thread

Bundled and orchestrated by **Zewx**.
