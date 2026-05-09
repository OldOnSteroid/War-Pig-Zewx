-- ============================================================
--  Reaper - core/boss_rotation.lua
--
--  Builds the run queue from the user's selected bosses and the
--  available item pools.
--
--  Each boss specifies its own key tier in data/enums.lua:
--    key_tier = "lair"     → Lair Key (also matches "Initiate Lair Key" SNO)
--    key_tier = "greater"  → Greater Lair Key
--    key_tier = "husk"     → Belial: HUSK_COST_BELIAL Husks per run
--
--  Tiers are tracked separately — running Duriel does not consume
--  a Greater Lair Key, and vice versa. A boss is "done" when its
--  required tier is empty.
--
--  Three rotation modes (settings.boss_rotation_mode):
--    "manual"     → farm only settings.boss_target, ignore checkboxes
--    "roundrobin" → cycle through ticked bosses one run each (default)
--    "random"     → pick a random ticked boss with stock for each run
-- ============================================================

local enums     = require "data.enums"
local tracker   = require "core.tracker"
local materials = require "core.materials"

local rotation = {}

rotation.boss_list   = {}
rotation.current_idx = 1
rotation.initialized = false

-- Per-tier pool counters — drained as runs complete.
rotation.pools = {
    lair    = 0,
    greater = 0,
    husk    = 0,
}

-- When true, the rotation was injected externally (e.g. by WarMachine via
-- ReaperPlugin.run_boss). build() becomes a no-op so the inventory-derived
-- rotation does not overwrite the external request. Cleared on disable.
rotation.external    = false
-- Single-shot guard for external rotations.
rotation.external_consumed = false

local HUSK_COST = materials.HUSK_COST_BELIAL

-- -------------------------------------------------------
-- Helpers
-- -------------------------------------------------------
local function pool_runs_for(boss)
    local tier = boss.key_tier or "lair"
    if tier == "husk" then
        return math.floor(rotation.pools.husk / HUSK_COST)
    end
    return rotation.pools[tier] or 0
end

local function refresh_runs_remaining()
    for _, boss in ipairs(rotation.boss_list) do
        boss.runs_remaining = pool_runs_for(boss)
    end
end

local function any_runs_available()
    for _, boss in ipairs(rotation.boss_list) do
        if pool_runs_for(boss) > 0 then return true end
    end
    return false
end

-- Cached rotation mode. Updated by rotation.build (and resync_pools when
-- the settings module is reachable). Defaults to roundrobin so behaviour
-- is sane if build() is never called explicitly.
rotation.mode = "roundrobin"

-- Round-robin: advance current_idx to the next boss in the cycle that
-- still has resources.
local function advance_roundrobin(start_after)
    local n = #rotation.boss_list
    if n == 0 then return false end
    local base = start_after or rotation.current_idx
    for i = 1, n do
        local idx = ((base + i - 1) % n) + 1
        if pool_runs_for(rotation.boss_list[idx]) > 0 then
            rotation.current_idx = idx
            return true
        end
    end
    return false
end

-- Random: pick a random boss from the runnable subset.
local function advance_random()
    local candidates = {}
    for i, boss in ipairs(rotation.boss_list) do
        if pool_runs_for(boss) > 0 then
            candidates[#candidates + 1] = i
        end
    end
    if #candidates == 0 then return false end
    rotation.current_idx = candidates[math.random(#candidates)]
    return true
end

-- Manual: stay on the only boss in the list while it has resources;
-- otherwise we're done. boss_list is built with a single entry in this
-- mode, so this is essentially "is there still stock?".
local function advance_manual()
    local cur = rotation.boss_list[rotation.current_idx]
    if cur and pool_runs_for(cur) > 0 then return true end
    return false
end

-- Dispatch helper. start_after only meaningful for round-robin.
local function advance_to_runnable(start_after)
    if rotation.mode == "random" then
        return advance_random()
    elseif rotation.mode == "manual" then
        return advance_manual()
    end
    return advance_roundrobin(start_after)
end

local function load_pools_from_inventory()
    local k = materials.scan_keys()
    rotation.pools.lair    = k.lair_keys
    rotation.pools.greater = k.greater_lair_keys
    rotation.pools.husk    = k.husks
end

-- -------------------------------------------------------
-- Build
-- -------------------------------------------------------
function rotation.build(settings)
    if rotation.external then
        console.print("[Reaper] External rotation already set — skipping inventory build.")
        return
    end

    rotation.boss_list   = {}
    rotation.current_idx = 1
    rotation.mode        = (settings and settings.boss_rotation_mode) or "roundrobin"

    load_pools_from_inventory()

    console.print(string.format(
        "[Reaper] Building rotation (mode=%s)...", rotation.mode))
    console.print(string.format(
        "  pools: lair=%d  greater=%d  husks=%d  (Belial cost=%d)",
        rotation.pools.lair, rotation.pools.greater, rotation.pools.husk, HUSK_COST))

    if not settings then
        console.print("[Reaper] No settings — nothing to farm.")
        rotation.initialized = false
        return
    end

    local function add_entry(bd)
        local tier = bd.key_tier or "lair"
        table.insert(rotation.boss_list, {
            id             = bd.id,
            zone_prefix    = bd.zone_prefix,
            label          = bd.label,
            key_tier       = tier,
            run_type       = tier,   -- aliased so logs / external API stay readable
            runs_remaining = 0,
        })
        console.print(string.format("  [%s] %s", tier, bd.label))
    end

    if rotation.mode == "manual" then
        local target_id = settings.boss_target
        local boss_def
        for _, bd in ipairs(enums.boss_zones) do
            if bd.id == target_id then boss_def = bd; break end
        end
        if not boss_def then
            console.print(string.format(
                "[Reaper] Manual mode: target boss '%s' not found.", tostring(target_id)))
            rotation.initialized = false
            return
        end
        add_entry(boss_def)
    else
        if not settings.boss_enabled then
            console.print("[Reaper] No boss selection in settings — nothing to farm.")
            rotation.initialized = false
            return
        end
        for _, bd in ipairs(enums.boss_zones) do
            if settings.boss_enabled[bd.id] then add_entry(bd) end
        end
    end

    refresh_runs_remaining()

    if #rotation.boss_list == 0 then
        console.print("[Reaper] No bosses selected — nothing to farm.")
        rotation.initialized = false
        return
    end

    -- Position the cursor on the first runnable boss (skip ones that have no
    -- resources from the start, e.g. Belial selected with zero husks).
    local has_any
    if rotation.mode == "random" then
        has_any = advance_random()
    elseif rotation.mode == "manual" then
        has_any = advance_manual()
    else
        has_any = advance_roundrobin(0)
    end
    rotation.initialized = has_any

    if rotation.initialized then
        console.print(string.format("[Reaper] Rotation: %d boss(es) queued [%s]",
            #rotation.boss_list, rotation.mode))
        local first = rotation.boss_list[rotation.current_idx]
        console.print(string.format("[Reaper] Starting with: %s (%s, %d runs available)",
            first.label, first.key_tier, first.runs_remaining))
    else
        console.print("[Reaper] None of the selected bosses have the required keys/husks in inventory.")
    end
end

-- -------------------------------------------------------
-- Query
-- -------------------------------------------------------
function rotation.current()
    if not rotation.initialized then return nil end
    if rotation.current_idx > #rotation.boss_list then return nil end
    return rotation.boss_list[rotation.current_idx]
end

function rotation.is_done()
    if not rotation.initialized then return false end
    return not any_runs_available()
end

function rotation.pool_summary()
    return {
        lair        = rotation.pools.lair,
        greater     = rotation.pools.greater,
        husks       = rotation.pools.husk,
        belial_runs = math.floor(rotation.pools.husk / HUSK_COST),
    }
end

-- Runs available for a specific tier ("lair" | "greater" | "husk").
function rotation.runs_for_tier(tier)
    if tier == "husk" then
        return math.floor(rotation.pools.husk / HUSK_COST)
    end
    return rotation.pools[tier] or 0
end

-- -------------------------------------------------------
-- Mutation
-- -------------------------------------------------------
function rotation.consume_run()
    local boss = rotation.current()
    if not boss then return end

    -- External one-shot lockout: chest open + deadlock recovery can both end
    -- up calling consume_run, and we MUST NOT double-count the kill (would
    -- offset WarMachine's reaper_kill_disable_when timer) or leave any opening
    -- for the altar to re-fire. First call wins; rest are no-ops.
    if rotation.external and rotation.external_consumed then
        return
    end
    if rotation.external then
        rotation.external_consumed = true
    end

    local tier = boss.key_tier or "lair"
    if tier == "husk" then
        rotation.pools.husk = math.max(0, rotation.pools.husk - HUSK_COST)
    else
        rotation.pools[tier] = math.max(0, (rotation.pools[tier] or 0) - 1)
    end

    tracker.total_kills        = tracker.total_kills + 1
    tracker.current_boss_kills = tracker.current_boss_kills + 1

    refresh_runs_remaining()

    console.print(string.format(
        "[Reaper] %s (%s) – run complete. pools: lair=%d  greater=%d  husks=%d",
        boss.label, tier,
        rotation.pools.lair, rotation.pools.greater, rotation.pools.husk))

    if rotation.external then
        -- External callers want a single kill — leave current_idx alone and
        -- let is_done() report based on lockout.
        return
    end

    -- Cycle to the next selected boss that still has resources.
    if not advance_to_runnable() then
        console.print("[Reaper] All selected bosses out of keys/husks.")
        return
    end

    local next_boss = rotation.current()
    if next_boss and next_boss ~= boss then
        tracker.current_boss_kills = 0
        console.print(string.format("[Reaper] Next: %s (%s, %d runs available)",
            next_boss.label, next_boss.key_tier, next_boss.runs_remaining))
    end
end

-- Skip the current boss (e.g. unable to reach the dungeon). Moves to the
-- next runnable boss without consuming any resources.
function rotation.advance()
    local boss = rotation.current()
    if boss then
        console.print(string.format("[Reaper] Skipping %s.", boss.label))
    end
    if not advance_to_runnable() then
        console.print("[Reaper] No more runnable bosses.")
        return
    end
    tracker.current_boss_kills = 0
    local next_boss = rotation.current()
    if next_boss then
        console.print(string.format("[Reaper] Next: %s (%s, %d runs available)",
            next_boss.label, next_boss.key_tier, next_boss.runs_remaining))
    end
end

-- Re-scan inventory and update pool counters in place. Used by deadlock
-- recovery paths that suspect the in-script counter has drifted from reality.
function rotation.resync_pools()
    if rotation.external then return end
    load_pools_from_inventory()
    refresh_runs_remaining()
end

-- -------------------------------------------------------
-- External one-shot rotation (orchestrators)
-- -------------------------------------------------------
function rotation.set_external(boss_id, run_type)
    local boss_def
    for _, bd in ipairs(enums.boss_zones) do
        if bd.id == boss_id then boss_def = bd; break end
    end
    if not boss_def then
        console.print(string.format("[Reaper] set_external: unknown boss_id '%s'", tostring(boss_id)))
        return false
    end

    -- Resolve run_type to a current-system tier. Accepts:
    --   nil / "lair_key" / "material" / "sigil"  → resolve from enum (legacy
    --                                              orchestrators don't know
    --                                              about the new tiers)
    --   "lair" / "greater" / "husk"              → explicit override
    local tier = run_type
    if tier == nil or tier == "lair_key" or tier == "material" or tier == "sigil" then
        tier = boss_def.key_tier or "lair"
    end

    rotation.boss_list = { {
        id             = boss_def.id,
        zone_prefix    = boss_def.zone_prefix,
        label          = boss_def.label,
        runs_remaining = 1,
        key_tier       = tier,
        run_type       = tier,
    } }
    rotation.current_idx       = 1
    rotation.initialized       = true
    rotation.external          = true
    rotation.external_consumed = false
    -- External rotations bypass real pool counters: the orchestrator owns when
    -- to stop, and we don't want is_done() to short-circuit on a coincidentally
    -- empty inventory.
    rotation.pools.lair    = (tier == "lair")    and 1 or rotation.pools.lair
    rotation.pools.greater = (tier == "greater") and 1 or rotation.pools.greater
    rotation.pools.husk    = (tier == "husk")    and HUSK_COST or rotation.pools.husk
    tracker.current_boss_kills = 0

    console.print(string.format("[Reaper] External rotation set: %s [%s]",
        boss_def.label, tier))
    return true
end

function rotation.clear_external()
    if rotation.external then
        console.print("[Reaper] Clearing external rotation flag.")
    end
    rotation.external          = false
    rotation.external_consumed = false
end

return rotation
