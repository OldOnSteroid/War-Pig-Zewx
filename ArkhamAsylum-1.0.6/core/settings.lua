local gui = require 'gui'

-- Defaults mirror gui.town_data[0] (Temis). pit_tower_pos held as a plain
-- {x, y, z} triple so this module can load even if vec3 isn't injected yet
-- (gui.lua used to vec3:new() at module load and crash silently inside its
-- table literal, leaving the cached gui without town_data). vec3 is built
-- on demand via to_vec3() at runtime when injection is guaranteed complete.
local TOWN_DEFAULTS = {
    zone_name     = 'Skov_Temis',
    waypoint_sno  = 0x1CE51E,
    pit_tower_pos = { 2572.708984375, -498.4921875, 30.5166015625 },
}

local function to_vec3 (xyz)
    if not xyz then return nil end
    if xyz.x ~= nil then return xyz end -- already a vec3
    return vec3:new(xyz[1], xyz[2], xyz[3])
end

local settings = {
    plugin_label = gui.plugin_label,
    plugin_version = gui.plugin_version,
    enabled = false,
    town_zone = TOWN_DEFAULTS.zone_name,
    town_waypoint = TOWN_DEFAULTS.waypoint_sno,
    -- Resolved to a vec3 in update_settings(); kept nil until the first pulse
    -- so module load doesn't depend on vec3 being injected.
    town_pit_tower_pos = nil,
    pit_level = 1,
    reset_timeout = 600,
    exit_mode = 0,
    exit_pit_delay = 10,
    return_for_loot = false,
    upgrade_toggle = false,
    use_chorons_soul = false,
    upgrade_mode = 1,
    upgrade_threshold = 1,
    upgrade_legendary_toggle = true,
    minimum_glyph_level = 1,
    maximum_glyph_level = 100,
    interact_shrine = true,
    chase_goblin = true,
    pickup_heart_of_stone = true,
    use_burden_altar = true,
    party_enabled = false,
    party_mode = 0,
    confirm_delay = 5,
    use_magoogle_tool = false,
    check_distance = 12,
    follower_explore = false,
    batmobile_priority = 'distance',
    disable_orbwalker_at_glyphstone = false,
    manage_orbwalker = false,
    use_long_path = false,
    speed_mode = false,
    speed_mode_2 = false,
    push_mode = false,
    push_threshold = 10,
    push_champion_weight = 3,
    push_elite_weight = 5,
    push_boss_weight = 10,
    push_max_pull_dist = 40,
    push_min_cluster_weight = 5,
    death_recovery = false,
}

settings.get_keybind_state = function ()
    local toggle_key = gui.elements.keybind_toggle:get_key();
    local toggle_state = gui.elements.keybind_toggle:get_state();
    local use_keybind = gui.elements.use_keybind:get()
    -- If not using keybind, skip
    if not use_keybind then
        return true
    end

    if use_keybind and toggle_key ~= 0x0A and toggle_state == 1 then
        return true
    end
    return false
end

settings.update_settings = function ()
    settings.enabled = gui.elements.main_toggle:get()
    local town_idx = gui.elements.town:get()
    -- gui.town_data may be nil if gui.lua somehow loaded partially; fall back
    -- to the hardcoded Temis defaults so we don't crash mid-pulse.
    local town_table = gui.town_data
    local town_data = (town_table and (town_table[town_idx] or town_table[0])) or TOWN_DEFAULTS
    settings.town_zone = town_data.zone_name
    settings.town_waypoint = town_data.waypoint_sno
    settings.town_pit_tower_pos = to_vec3(town_data.pit_tower_pos)
    settings.return_for_loot = gui.elements.return_for_loot:get()
    settings.pit_level = gui.elements.pit_level:get()
    settings.reset_timeout = gui.elements.reset_timeout:get()
    settings.exit_mode = gui.elements.exit_mode:get()
    settings.exit_pit_delay = gui.elements.exit_pit_delay:get()
    settings.upgrade_toggle = gui.elements.upgrade_toggle:get()
    settings.use_chorons_soul = gui.elements.use_chorons_soul:get()
    settings.upgrade_mode = gui.elements.upgrade_mode:get()
    settings.upgrade_threshold = gui.elements.upgrade_threshold:get()
    settings.upgrade_legendary_toggle = gui.elements.upgrade_legendary_toggle:get()
    settings.minimum_glyph_level = gui.elements.minimum_glyph_level:get()
    settings.maximum_glyph_level = gui.elements.maximum_glyph_level:get()
    settings.interact_shrine = gui.elements.interact_shrine:get()
    settings.chase_goblin = gui.elements.chase_goblin:get()
    settings.pickup_heart_of_stone = gui.elements.pickup_heart_of_stone:get()
    settings.use_burden_altar = gui.elements.use_burden_altar:get()
    settings.party_enabled = gui.elements.party_enabled:get()
    settings.party_mode = gui.elements.party_mode:get()
    settings.confirm_delay = gui.elements.confirm_delay:get()
    settings.use_magoogle_tool = gui.elements.use_magoogle_tool:get()
    settings.follower_explore = gui.elements.follower_explore:get()
    settings.batmobile_priority = gui.batmobile_priority[gui.elements.batmobile_priority:get()+1]
    settings.disable_orbwalker_at_glyphstone = gui.elements.disable_orbwalker_at_glyphstone:get()
    settings.manage_orbwalker = gui.elements.manage_orbwalker:get()
    settings.use_long_path = gui.elements.use_long_path:get()
    settings.speed_mode = gui.elements.speed_mode:get()
    settings.speed_mode_2 = gui.elements.speed_mode_2:get()
    settings.push_mode = gui.elements.push_mode:get()
    settings.push_threshold = gui.elements.push_threshold:get()
    settings.push_champion_weight = gui.elements.push_champion_weight:get()
    settings.push_elite_weight = gui.elements.push_elite_weight:get()
    settings.push_boss_weight = gui.elements.push_boss_weight:get()
    settings.push_max_pull_dist = gui.elements.push_max_pull_dist:get()
    settings.push_min_cluster_weight = gui.elements.push_min_cluster_weight:get()
    settings.death_recovery = gui.elements.death_recovery:get()

end

settings.orb_set_clear = function (v)
    if settings.manage_orbwalker then
        orbwalker.set_clear_toggle(v)
    end
end

settings.orb_set_block = function (v)
    if settings.manage_orbwalker then
        orbwalker.set_block_movement(v)
    end
end

return settings