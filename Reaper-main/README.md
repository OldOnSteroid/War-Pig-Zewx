# Reaper v1.1

Farms bosses in a configured rotation using materials and/or lair boss sigils from your inventory. Each successful chest open counts as one completed run. When a boss's run count hits zero the script moves to the next queued boss, and disables itself when all are done.

## Requirements

- An active combat / orbwalker script — Reaper handles navigation and interaction only.
- **D4Assistant** (recommended) or the built-in map-click navigation (see below).
- Optionally **Alfred** for inventory management between runs.

## Setup

1. Drop the `Reaper` folder into your scripts directory.
2. Open the in-game menu → **Reaper**.
3. Under **Settings**, choose your run types (Materials, Sigils, or both).
4. If using D4Assistant, enable **Use D4Assistant for teleport** (default on).
5. If using built-in navigation, disable D4Assistant and calibrate **Boss Icon Alignment** (see below).
6. Enable **Alfred** if you want automatic stash/repair between runs.
7. Make sure your combat script is running.
8. Click **Enable**.

## Run Types

| Type | Description |
|---|---|
| **Material Runs** | Consumes summoning materials (Shards of Agony, Living Steel, etc.) to summon and farm bosses. The script counts available materials at startup and farms each boss down to zero. |
| **Lair Boss Sigils** | Uses Bloodied and Bloodsoaked Lair Boss Sigils from your dungeon key inventory. Each sigil teleports you into a boss lair, clears it, and returns to town. |

Both run types can be enabled simultaneously. Material runs are queued first.

## Navigation Modes

### D4Assistant (default)
Reaper writes a teleport command to `command.txt` and waits for D4Assistant to move you to the boss zone. No calibration needed.

### Built-in Map Navigation (D4Assistant disabled)
Reaper navigates to the boss using the in-game waypoint map:

1. Teleports to the anchor waypoint (Nevesk for most bosses, Zarbinzet for Urivar / Harbinger).
2. Walks to the Waypoint stone and interacts with it to open the map.
3. Clicks the boss icon on the map, then clicks Accept.
4. Waits up to 15 seconds for the boss zone to load. Retries from the anchor on failure.

Calibrate click positions under **Boss Icon Alignment** before use (see below).

## Boss Icon Alignment (built-in navigation only)

All coordinates are **screen pixels** measured from the top-left of your display.
Supported resolutions up to **5120×2160** (4K ultrawide).

1. Open the in-game menu → **Reaper** → **Boss Icon Alignment**.
2. Enable **Show crosshairs on screen** — coloured crosshairs appear at each stored position.
3. Open the in-game world map and zoom to where all boss icons are visible.
4. For each boss, expand its entry, adjust X and Y until the crosshair sits on the icon.
5. Set the **Accept Button** X/Y to match the confirmation button that appears after clicking a boss.
6. Disable **Show crosshairs** when done.

> **Zir** requires two clicks: the gateway icon (Step 1) then the boss portal icon (Step 2). Both have separate sliders.

## Belial Chest Automation

After Belial dies a "Ritual of Lies – Choose Reward" chest UI appears. This section automates clicking through it.

| Setting | Description |
|---|---|
| **Enable** | Turn on automated chest clicking |
| **Mode** | Manual / Round Robin / Random |
| **Target Boss** *(Manual)* | Fixed boss to always select |
| **Boss Pool** *(RR / Random)* | Which bosses to include in the pool |
| **Party Delay** | Extra ms before clicking Open (helps sync with party members) |

**Click sequence:**
1. Detects the Ritual of Lies chest via actor scan.
2. Clicks **Modify Reward** (skipped for Andariel, which is the default selection).
3. Scrolls if needed (Varshan requires a scroll).
4. Clicks the target boss button.
5. Waits for the party delay, then clicks **Open**.

## Dungeon Reset

Resets all dungeons after every N completed runs (configurable). Useful for keeping sigil dungeon layouts fresh.

## Combat Behaviour

During boss fights Reaper keeps the player within **15 units of the altar/anchor position**. If the player drifts further away (e.g. chasing a stray enemy), it walks back before re-engaging. Suppressor orbs are always chased regardless of distance since they need to be burst to unblock combat.

## Settings Reference

| Setting | Default | Description |
|---|---|---|
| Use D4Assistant | On | Delegate teleports to D4Assistant via `command.txt` |
| Use Alfred | On | Hand off inventory/repair/restock to Alfred |
| Run Material Runs | On | Farm bosses using consumable materials |
| Run Lair Boss Sigils | On | Farm bosses using lair sigils |
| Dungeon Reset | Off | Reset dungeons every N runs |
| Dungeon Reset Interval | 10 | Runs between dungeon resets |

## Notes

- Run counts and inventory are scanned once at enable time. Re-enable to refresh.
- If a sigil boss zone is not reached within 60 seconds the script retries up to 5 times, then skips that boss.
- If the built-in map navigation fails to reach the boss zone after 3 retries it gives up and the outer task manager attempts again on the next cycle.
- Paths from your zone entrance to the altar are stored in `paths/<boss>_<variant>.lua`. Multiple variants are supported and the closest one is picked at runtime.
