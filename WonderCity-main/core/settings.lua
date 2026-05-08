local gui = require 'gui'

local settings = {
    plugin_label = gui.plugin_label,
    plugin_version = gui.plugin_version,
    enabled = false,
    -- Town defaults match gui.town_data[0] (Kurast) so reads before the first
    -- update_settings() pulse are valid.
    town_zone             = gui.town_data[0].zone_name,
    town_waypoint         = gui.town_data[0].waypoint_sno,
    town_long_path_target = gui.town_data[0].long_path_target,
    reset_timeout = 600,
    exit_undercity_delay = 10,
    exit_mode = 0,
    party_enabled = false,
    party_mode = 0,
    confirm_delay = 5,
    use_magoogle_tool = false,
    check_distance = 20,
    follower_explore = false,
    boss_delay = 0,
    loot_obols = true,
    beacon_timeout = 10,
    enticement_timeout = 4,
    skip_monsters = false,
    use_custom_explorer = false,
    max_enticement = 4,
    batmobile_priority = 'distance',
    tribute_priorities = {},
    show_click_points = false,
    accept_button_x = 960,
    accept_button_y = 540,
    enable_bargains = false,
    bargain_timeout = 10,
    bargain_priorities = {},
    bargain_cp = {
        sort_button           = {x = 960, y = 540},
        bargain_opener        = {x = 960, y = 540},
        scroll_bar            = {x = 960, y = 540},
        core_stats            = {x = 960, y = 540},
        primary_resource      = {x = 960, y = 540},
        resistances           = {x = 960, y = 540},
        offensive_legendaries = {x = 960, y = 540},
        defensive_legendaries = {x = 960, y = 540},
        utility_legendaries   = {x = 960, y = 540},
        mobility_legendaries  = {x = 960, y = 540},
        resource_legendaries  = {x = 960, y = 540},
    },
    inventory_slot_0_x   = 960,
    inventory_slot_0_y   = 540,
    inventory_cell_size_x = 50,
    inventory_cell_size_y = 50,
    portal_button_x = 960,
    portal_button_y = 540,
    manage_orbwalker = false,
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
    local town_data = gui.town_data[town_idx] or gui.town_data[0]
    settings.town_zone             = town_data.zone_name
    settings.town_waypoint         = town_data.waypoint_sno
    settings.town_long_path_target = town_data.long_path_target  -- nil for Kurast
    settings.reset_timeout = gui.elements.reset_timeout:get()
    settings.exit_undercity_delay = gui.elements.exit_undercity_delay:get()
    settings.exit_mode = gui.elements.exit_mode:get()
    settings.party_enabled = gui.elements.party_enabled:get()
    settings.party_mode = gui.elements.party_mode:get()
    settings.confirm_delay = gui.elements.confirm_delay:get()
    settings.use_magoogle_tool = gui.elements.use_magoogle_tool:get()
    settings.follower_explore = gui.elements.follower_explore:get()
    settings.boss_delay = gui.elements.boss_delay:get()
    settings.loot_obols = gui.elements.loot_obols:get()
    settings.beacon_timeout = gui.elements.beacon_timeout:get()
    settings.enticement_timeout = gui.elements.enticement_timeout:get()
    settings.skip_monsters = gui.elements.skip_monsters:get()
    settings.use_custom_explorer = gui.elements.use_custom_explorer:get()
    settings.max_enticement = gui.elements.max_enticement:get()
    settings.batmobile_priority = gui.batmobile_priority[gui.elements.batmobile_priority:get()+1]
    settings.tribute_priorities = {}
    for i, tribute in ipairs(gui.tributes_data) do
        local p = gui.elements['tribute_priority_' .. i]:get()
        if p > 0 then
            settings.tribute_priorities[tribute.sno_id] = p
        end
    end
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.accept_button_x = gui.elements.accept_button_x:get()
    settings.accept_button_y = gui.elements.accept_button_y:get()
    settings.enable_bargains = gui.elements.enable_bargains:get()
    settings.bargain_timeout = gui.elements.bargain_timeout:get()
    settings.bargain_priorities = {}
    for i in ipairs(gui.bargains_data) do
        local p = gui.elements['bargain_priority_' .. i]:get()
        if p > 0 then
            settings.bargain_priorities[i] = p
        end
    end
    for _, key in ipairs(gui.bargain_cp_keys) do
        settings.bargain_cp[key] = {
            x = gui.elements['bargain_cp_' .. key .. '_x']:get(),
            y = gui.elements['bargain_cp_' .. key .. '_y']:get(),
        }
    end
    settings.inventory_slot_0_x    = gui.elements.inventory_slot_0_x:get()
    settings.inventory_slot_0_y    = gui.elements.inventory_slot_0_y:get()
    settings.inventory_cell_size_x = gui.elements.inventory_cell_size_x:get()
    settings.inventory_cell_size_y = gui.elements.inventory_cell_size_y:get()
    settings.portal_button_x = gui.elements.portal_button_x:get()
    settings.portal_button_y = gui.elements.portal_button_y:get()
    settings.manage_orbwalker = gui.elements.manage_orbwalker:get()
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