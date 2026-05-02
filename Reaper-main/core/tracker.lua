-- ============================================================
--  Reaper - core/tracker.lua
-- ============================================================

local tracker = {
    -- timing
    start_time          = 0,
    finished_time       = 0,
    chest_opened_time   = nil,
    altar_activate_time = 0,   -- get_time_since_inject() when altar was activated

    -- per-run flags
    altar_activated         = false,
    boss_killed             = false,
    chest_opened            = false,
    belial_chest_interacted = false,  -- set when the physical Belial chest is interacted with
    just_revived            = false,  -- set by revive task, cleared by navigate_to_boss

    -- sigil run coordination
    sigil_entry_t    = -999,   -- get_time_since_inject() when dungeon was entered
    sigil_chest_done = false,  -- true once the Doom chest has been opened this run

    -- session stats
    total_kills        = 0,
    current_boss_kills = 0,
}

function tracker.reset_run()
    tracker.altar_activated         = false
    tracker.altar_activate_time     = 0
    tracker.boss_killed             = false
    tracker.chest_opened            = false
    tracker.belial_chest_interacted = false
    tracker.just_revived            = false
    tracker.start_time              = 0
    tracker.finished_time           = 0
    tracker.chest_opened_time       = nil
    tracker.sigil_chest_done        = false
    tracker.sigil_entry_t           = -999
end

function tracker.check_time(key, delay)
    local t = get_time_since_inject()
    if not tracker[key] then tracker[key] = t end
    return (t - tracker[key]) >= delay
end

function tracker.clear_key(key)
    tracker[key] = nil
end

return tracker
