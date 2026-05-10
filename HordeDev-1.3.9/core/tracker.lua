local tracker = {
    finished_time = 0,
    pit_start_time = 0,
    ga_chest_opened = false,
    talisman_chest_opened = false,
    selected_chest_opened = false,
    gold_chest_opened = false,
    finished_chest_looting = false,
    has_salvaged = false,
    exit_horde_start_time = 0,
    has_entered = false,
    start_dungeon_time = nil,
    horde_opened = false,
    first_run = false,
    exit_horde_completion_time = 0,
    exit_horde_completed = true,
    wave_start_time = 0,
    needs_salvage = false,
    victory_lap = false,
    victory_positions = nil,
    locked_door_found = false,
    boss_killed = false,
    teleported_from_town = false,
    keep_items = 0,
    sigil_used = false
}

local runtime_timer = {}

function tracker.check_time(key, delay)
    local current_time = get_time_since_inject()
    if not tracker[key] then
        tracker[key] = current_time
        table.insert(runtime_timer, key)
    end
    if current_time - tracker[key] >= delay then
        return true
    end
    return false
end

function tracker.set_teleported_from_town(value)
    tracker.teleported_from_town = value
end

function tracker.clear_runtime_timers()
    console.print("Clear runtime timers")
    for _, timer in pairs(runtime_timer) do
        tracker.clear_key(timer)
    end
end

-- The plan is to have a separate table that stores all the key added by check_time and clear them all on exit
function tracker.clear_key(key)
    tracker[key] = nil
end

-- Wipes all tracker state that needs to be cleared between horde runs.
-- Called from InfernalHordesPlugin.enable() so a WarPigs-driven mid-BSK
-- re-enable doesn't inherit the previous run's chest flags and skip looting.
-- The normal Library->sigil flow already resets chest state via start_dungeon's
-- reset_chest_flags(), so this is a superset that's idempotent on first enable.
function tracker.fresh_run_reset()
    console.print("[tracker] fresh_run_reset")
    tracker.finished_chest_looting    = false
    tracker.ga_chest_opened           = false
    tracker.talisman_chest_opened     = false
    tracker.selected_chest_opened     = false
    tracker.gold_chest_opened         = false
    tracker.has_salvaged              = false
    tracker.needs_salvage             = false
    tracker.victory_lap               = false
    tracker.victory_positions         = nil
    tracker.locked_door_found         = false
    tracker.boss_killed               = false
    tracker.horde_opened              = false
    tracker.sigil_used                = false
    tracker.first_run                 = false
    tracker.keep_items                = 0
    tracker.teleported_from_town      = false
    tracker.start_dungeon_time        = nil
    tracker.exit_horde_start_time     = nil
    tracker.has_entered               = false
    tracker.clear_runtime_timers()
end

return tracker