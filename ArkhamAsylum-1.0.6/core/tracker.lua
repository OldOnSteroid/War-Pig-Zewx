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
    -- Boss memory: vec3 of last known boss position. Survives player death so
    -- the bot can path back without exploring after revive.
    boss_position = nil,
    -- Set true after the boss disappears from the actor list while we were
    -- nearby (or when the glyphstone appears, which implies the kill).
    boss_dead = false,
    -- Anchor we hold near after boss dies (boss death position, then snapped to
    -- the glyphstone once it spawns). explore_pit / kill_monster are gated by
    -- this so the bot can't wander away to chase trash.
    glyph_anchor_pos = nil,
}

tracker.reset_pit_state = function ()
    tracker.pit_start_time = get_time_since_inject()
    tracker.exit_trigger_time = nil
    tracker.glyph_trigger_time = nil
    tracker.glyph_done = false
    tracker.boss_kill_time = nil
    tracker.boss_seen = false
    tracker.boss_position = nil
    tracker.boss_dead = false
    tracker.glyph_anchor_pos = nil
end

return tracker