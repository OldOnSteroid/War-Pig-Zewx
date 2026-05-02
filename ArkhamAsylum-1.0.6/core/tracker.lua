local plugin_label = 'arkham_asylum'
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name        = plugin_label,
    pit_start_time = get_time_since_inject(),
    exit_trigger_time = nil,
    glyph_done = false,
    glyph_trigger_time = nil,
    boss_kill_time = nil,
    boss_seen = false,
}

return tracker