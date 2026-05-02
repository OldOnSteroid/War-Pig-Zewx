local plugin_label = 'wonder_city'
-- kept plugin label instead of waiting for update_tracker to set it

local tracker = {
    name = plugin_label,
    undercity_start_time = get_time_since_inject(),
    exit_trigger_time = nil,
    exit_reset = false,
    boss_trigger_time = nil,
    boss_kill_time = nil,
    enticement = {},
}

return tracker