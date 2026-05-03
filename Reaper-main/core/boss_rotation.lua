-- ============================================================
--  Reaper - core/boss_rotation.lua
--
--  Builds the run queue from all enabled run types:
--    1. Bloodsoaked sigils  (disabled until SNO confirmed)
--    2. Bloodied sigils
--    3. Material runs
--
--  Each entry in boss_list has a run_type field so the rest
--  of the system knows how to handle it:
--    run_type = "material"   → use consumables
--    run_type = "bloodied"   → use Bloodied sigil from bag
--    run_type = "bloodsoaked"→ use Bloodsoaked sigil (future)
-- ============================================================

local enums     = require "data.enums"
local tracker   = require "core.tracker"
local materials = require "core.materials"

local rotation = {}

rotation.boss_list   = {}
rotation.current_idx = 1
rotation.initialized = false
-- When true, the rotation was injected externally (e.g. by WarPigs via
-- ReaperPlugin.run_boss). build() becomes a no-op so the inventory-derived
-- rotation does not overwrite the external request. Cleared on disable.
rotation.external    = false
-- Single-shot guard for external rotations. Set true the first time
-- consume_run fires for an external rotation; subsequent calls (duplicate
-- chest events, deadlock recovery, etc.) no-op so total_kills never
-- double-counts and the altar can't re-arm.
rotation.external_consumed = false

local function add_runs(label, counts, run_type)
    local added = 0
    for _, boss_def in ipairs(enums.boss_zones) do
        local runs = counts[boss_def.id] or 0
        if runs > 0 then
            table.insert(rotation.boss_list, {
                id             = boss_def.id,
                zone_prefix    = boss_def.zone_prefix,
                label          = boss_def.label,
                runs_remaining = runs,
                run_type       = run_type,
            })
            console.print(string.format("  [%s] %-20s %d runs",
                run_type, boss_def.label, runs))
            added = added + 1
        end
    end
    return added
end

function rotation.build(settings)
    if rotation.external then
        console.print("[Reaper] External rotation already set — skipping inventory build.")
        return
    end

    rotation.boss_list   = {}
    rotation.current_idx = 1

    console.print("[Reaper] Building rotation...")

    -- Priority 1: Sigil runs
    if settings and settings.run_sigils then
        local counts = materials.scan_sigils()
        add_runs("sigil", counts, "sigil")

        -- If any sigils came back as "unknown" location, queue them as generic
        -- sigil runs so they still get used (location doesn't affect farming flow)
        local unknown = counts["unknown"] or 0
        if unknown > 0 then
            console.print(string.format("  [sigil] %d unmapped sigil(s) — will run as generic", unknown))
            table.insert(rotation.boss_list, {
                id             = "sigil_generic",
                zone_prefix    = "",
                label          = "Lair Boss (unmapped)",
                runs_remaining = unknown,
                run_type       = "sigil",
            })
        end
    end

    -- Priority 2: Material runs
    if not settings or settings.run_materials then
        local counts = materials.scan()
        add_runs("material", counts, "material")
    end

    rotation.initialized = (#rotation.boss_list > 0)

    if rotation.initialized then
        console.print(string.format("[Reaper] Rotation: %d boss(es) queued", #rotation.boss_list))
        local first = rotation.boss_list[1]
        console.print(string.format("[Reaper] Starting with: %s (%s, %d runs)",
            first.label, first.run_type, first.runs_remaining))
    else
        console.print("[Reaper] Nothing to farm — check run type settings and inventory.")
    end
end

function rotation.current()
    if not rotation.initialized then return nil end
    if rotation.current_idx > #rotation.boss_list then return nil end
    return rotation.boss_list[rotation.current_idx]
end

function rotation.consume_run()
    local boss = rotation.current()
    if not boss then return end

    -- External one-shot lockout: chest open + deadlock recovery can both end
    -- up calling consume_run, and we MUST NOT double-count the kill (would
    -- offset WarPigs's reaper_kill_disable_when timer) or leave any opening
    -- for the altar to re-fire. First call wins; rest are no-ops.
    if rotation.external and rotation.external_consumed then
        return
    end
    if rotation.external then
        rotation.external_consumed = true
    end

    boss.runs_remaining       = boss.runs_remaining - 1
    tracker.total_kills       = tracker.total_kills + 1
    tracker.current_boss_kills = tracker.current_boss_kills + 1

    console.print(string.format("[Reaper] %s (%s) – run complete. Remaining: %d",
        boss.label, boss.run_type, boss.runs_remaining))

    if boss.runs_remaining <= 0 then
        -- Re-verify inventory before advancing: if materials are still present the
        -- in-script counter drifted and we should correct it rather than skip the boss.
        --
        -- IMPORTANT: skip the material-correction reset for externally-injected
        -- rotations (WarPigs etc.). External rotations are explicitly single-shot
        -- (runs_remaining=1), and resetting the counter from inventory would loop
        -- the altar interaction forever — the orchestrator only wanted ONE kill.
        if boss.run_type == "material" and not rotation.external then
            local mats   = materials.scan()
            local actual = mats[boss.id] or 0
            if actual > 0 then
                console.print(string.format(
                    "[Reaper] %s counter hit 0 but %d run(s) remain in inventory — correcting.",
                    boss.label, actual))
                boss.runs_remaining = actual
                return
            end
        end
        if rotation.external then
            console.print(string.format(
                "[Reaper] %s external one-shot complete — locking out altar (rotation done).",
                boss.label))
        end
        console.print(string.format("[Reaper] %s done – moving to next.", boss.label))
        rotation.current_idx       = rotation.current_idx + 1
        tracker.current_boss_kills = 0
        local next_boss = rotation.current()
        if next_boss then
            console.print(string.format("[Reaper] Next: %s (%s, %d runs)",
                next_boss.label, next_boss.run_type, next_boss.runs_remaining))
        end
    end
end

function rotation.is_done()
    return rotation.initialized and rotation.current_idx > #rotation.boss_list
end

-- External (one-shot) rotation injection. Called from ReaperPlugin.run_boss().
-- Replaces any existing queue with a single-entry rotation for boss_id and
-- marks the rotation as external so build() will not overwrite it.
function rotation.set_external(boss_id, run_type)
    local boss_def
    for _, bd in ipairs(enums.boss_zones) do
        if bd.id == boss_id then boss_def = bd; break end
    end
    if not boss_def then
        console.print(string.format("[Reaper] set_external: unknown boss_id '%s'", tostring(boss_id)))
        return false
    end

    run_type = run_type or "material"
    rotation.boss_list = { {
        id             = boss_def.id,
        zone_prefix    = boss_def.zone_prefix,
        label          = boss_def.label,
        runs_remaining = 1,
        run_type       = run_type,
    } }
    rotation.current_idx       = 1
    rotation.initialized       = true
    rotation.external          = true
    rotation.external_consumed = false
    tracker.current_boss_kills = 0

    console.print(string.format("[Reaper] External rotation set: %s [%s]",
        boss_def.label, run_type))
    return true
end

function rotation.clear_external()
    if rotation.external then
        console.print("[Reaper] Clearing external rotation flag.")
    end
    rotation.external          = false
    rotation.external_consumed = false
end

function rotation.advance()
    local boss = rotation.current()
    if boss then
        console.print(string.format("[Reaper] Skipping %s (out of %s).",
            boss.label, boss.run_type))
    end
    rotation.current_idx       = rotation.current_idx + 1
    tracker.current_boss_kills = 0
    local next_boss = rotation.current()
    if next_boss then
        console.print(string.format("[Reaper] Next: %s (%s, %d runs)",
            next_boss.label, next_boss.run_type, next_boss.runs_remaining))
    else
        console.print("[Reaper] No more bosses in rotation.")
    end
end

return rotation
