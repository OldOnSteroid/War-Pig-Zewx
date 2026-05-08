local plugin_label = 'arkham_asylum'
local plugin_version = '1.0.6'
console.print("Lua Plugin - Arkham Asylum - Leoric - v" .. plugin_version)

local gui = {}

local create_checkbox = function (value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.upgrade_modes_enum = {
    HIGHEST = 0,
    LOWEST = 1,
    PRIORITY = 2
}
gui.upgrade_mode = { 'Highest to lowest', 'Lowest to highest'}
gui.exit_modes_enum = {
    RESET = 0,
    TELEPORT = 1,
}
gui.exit_mode = { 'Reset', 'Teleport'}
gui.party_modes_enum = {
    LEADER = 0,
    FOLLOWER = 1
}
gui.party_mode = { 'Leader', 'Follower'}
gui.batmobile_priority = {
    'direction',
    'distance'
}
gui.batmobile_priority_enum = {
    DIRECTION = 0,
    DISTANCE = 1
}
-- Town options match AlfredTheButler's order so the user picks the same town
-- they configured in Alfred. Index resolved to zone/waypoint in settings.lua.
gui.town = { 'Temis', 'Cerrigar' }
gui.town_enum = {
    TEMIS = 0,
    CERRIGAR = 1,
}
gui.town_data = {
    [0] = {
        zone_name        = 'Skov_Temis',
        waypoint_sno     = 0x1CE51E,
        pit_tower_pos    = vec3:new(2572.708984375, -498.4921875, 30.5166015625),
    },
    [1] = {
        zone_name        = 'Scos_Cerrigar',
        waypoint_sno     = 0x76D58,
        pit_tower_pos    = vec3:new(-1659.1735839844, -613.06573486328, 37.2822265625),
    },
}

gui.plugin_label = plugin_label
gui.plugin_version = plugin_version
gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, 'main_toggle'),
    use_keybind = create_checkbox(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle' )),
    pit_settings_tree = tree_node:new(1),
    town = combo_box:new(0, get_hash(plugin_label .. '_' .. 'town')),
    batmobile_priority = combo_box:new(0, get_hash(plugin_label .. '_' .. 'batmobile_priority')),
    pit_level = slider_int:new(1, 150, 1, get_hash(plugin_label .. '_' .. 'pit_level')),
    reset_timeout = slider_int:new(30, 900, 600, get_hash(plugin_label .. '_' .. 'reset_timeout')),
    exit_pit_delay = slider_int:new(0, 300, 10, get_hash(plugin_label .. '_' .. 'exit_pit_delay')),
    exit_mode = combo_box:new(0, get_hash(plugin_label .. '_' .. 'exit_mode')),
    return_for_loot = create_checkbox(true, 'return_for_loot'),
    upgrade_toggle = create_checkbox(true, 'upgrade_toggle'),
    use_chorons_soul = create_checkbox(false, 'use_chorons_soul'),
    upgrade_mode = combo_box:new(1, get_hash(plugin_label .. '_' .. 'upgrade_mode')),
    upgrade_threshold = slider_int:new(1, 100, 1, get_hash('upgrade_threshold')),
    upgrade_legendary_toggle = create_checkbox(true, plugin_label .. '_' .. 'upgrade_legendary_toggle'),
    minimum_glyph_level = slider_int:new(1, 100, 1, get_hash(plugin_label .. '_' .. 'minimum_glyph_level')),
    maximum_glyph_level = slider_int:new(1, 150, 100, get_hash(plugin_label .. '_' .. 'maximum_glyph_level')),
    interact_shrine = create_checkbox(true, 'interact_shrine'),
    party_settings_tree = tree_node:new(1),
    party_enabled = create_checkbox(false, 'party_enabled'),
    party_mode = combo_box:new(0, get_hash(plugin_label .. '_' .. 'party_mode')),
    -- start_pit_delay = slider_int:new(1, 300, 5, get_hash(plugin_label .. '_' .. 'start_pit_delay')),
    confirm_delay = slider_int:new(1, 300, 5, get_hash(plugin_label .. '_' .. 'confirm_delay')),
    use_magoogle_tool = create_checkbox(false, 'use_magoogle_tool'),
    follower_explore = create_checkbox(false, 'follower_explore'),
    disable_orbwalker_at_glyphstone = create_checkbox(false, 'disable_orbwalker_at_glyphstone'),
    manage_orbwalker = create_checkbox(false, 'manage_orbwalker'),
    use_long_path = create_checkbox(false, 'use_long_path'),
    speed_mode = create_checkbox(false, 'speed_mode'),
    push_mode = create_checkbox(false, 'push_mode'),
    push_threshold = slider_int:new(3, 30, 10, get_hash(plugin_label .. '_' .. 'push_threshold')),
    push_champion_weight = slider_int:new(1, 10, 3, get_hash(plugin_label .. '_' .. 'push_champion_weight')),
    push_elite_weight = slider_int:new(1, 10, 5, get_hash(plugin_label .. '_' .. 'push_elite_weight')),
    push_boss_weight = slider_int:new(1, 20, 10, get_hash(plugin_label .. '_' .. 'push_boss_weight')),
    push_max_pull_dist = slider_int:new(15, 80, 40, get_hash(plugin_label .. '_' .. 'push_max_pull_dist')),
    push_min_cluster_weight = slider_int:new(1, 20, 5, get_hash(plugin_label .. '_' .. 'push_min_cluster_weight')),
    death_recovery = create_checkbox(false, 'death_recovery'),
}
gui.render = function ()
    if not gui.elements.main_tree:push('Z | Arkham Asylum (pit) | Leoric | v' .. gui.plugin_version) then return end
    if AlfredTheButlerPlugin == nil then
        render_menu_header('This plugin requires AlfredTheButlerPlugin to work')
    end
    if BatmobilePlugin == nil then
        render_menu_header('This plugin requires BatmobilePlugin to work')
    end
    if LooteerPlugin == nil then
        render_menu_header('This plugin requires LooteerPlugin to work')
    end
    if BatmobilePlugin == nil or AlfredTheButlerPlugin == nil or LooteerPlugin == nil then
        gui.elements.main_tree:pop()
        return
    end
    gui.elements.main_toggle:render('Enable', 'Enable Arkham Asylum')
    gui.elements.use_keybind:render('Use keybind', 'Keybind to quick toggle the bot')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot for quick enable')
    end
    if gui.elements.pit_settings_tree:push('Pit Settings') then
        gui.elements.town:render('Home town', gui.town, 'Town to teleport to / start the run from. Match this to your Alfred town setting.')
        gui.elements.batmobile_priority:render('Batmobile priority', gui.batmobile_priority, 'Select whether to priortize direction or distance while exploring')
        if gui.elements.batmobile_priority:get() == 1 then
            render_menu_header('[EXPERIMENTAL] Priortizing distance will use more processing power. ' ..
                'Depending on layout, might result in more backtracking.')

        end
        gui.elements.pit_level:render('Pit Level', 'Which Pit level do you want to enter?')
        gui.elements.reset_timeout:render("Reset Time (s)", "Set the time in seconds for resetting all dungeons")
        gui.elements.exit_pit_delay:render('Exit delay (s)', 'time in seconds to wait before ending pit')
        gui.elements.exit_mode:render('Exit mode', gui.exit_mode, 'Select reset or teleport to exit pit')
        gui.elements.return_for_loot:render('Return for loot', 'return for loot after alfred run')
        gui.elements.interact_shrine:render('Enable shrine interaction (and belial eye)', 'Enable shrine interaction (and belial eye)')
        gui.elements.speed_mode:render('Speed Mode (beta test)', 'Never stop for monsters — path through dense packs and let AltClick + evade explosions handle kills')
        gui.elements.push_mode:render('Push Mode (beta test)', 'Aggro small groups and pull them together before engaging — maximizes AoE value')
        if gui.elements.push_mode:get() then
            gui.elements.push_threshold:render('Group threshold', 'Weighted group size required before engaging (normal=1, champions/elites/bosses use weights below)')
            gui.elements.push_champion_weight:render('Champion weight', 'How much a champion counts toward the group threshold')
            gui.elements.push_elite_weight:render('Elite weight', 'How much an elite counts toward the group threshold')
            gui.elements.push_boss_weight:render('Boss weight', 'How much a boss counts toward the group threshold')
            gui.elements.push_max_pull_dist:render('Max pull distance', 'How far to travel when pulling monsters together (higher = bigger pulls, lower = tighter grouping)')
            gui.elements.push_min_cluster_weight:render('Min cluster density', 'Minimum weighted size a distant group must have to be worth pulling toward (ignores solo monsters and tiny groups)')
        end
        gui.elements.use_long_path:render('Use long path for monster targeting', 'Use uncapped A* to find paths to monsters (better for long-range or complex terrain)')
        gui.elements.upgrade_toggle:render('Enable Glyph Upgrade', 'Toggle glyph upgrade on/off')
        if gui.elements.upgrade_toggle:get() then
            gui.elements.upgrade_mode:render('Upgrade mode', gui.upgrade_mode, 'Select how to upgrade glyphs')
            gui.elements.upgrade_threshold:render('Upgrade threshold', 'only upgrade glyph if the %% chance is greater or equal to upgrade threshold')
            gui.elements.minimum_glyph_level:render('Minimum level', 'Only upgrade glyphs with level greater than or equal to this value')
            gui.elements.maximum_glyph_level:render('Maximum level', 'Only upgrade glyphs with level less than or equal to this value')
            gui.elements.upgrade_legendary_toggle:render('Upgrade to legendary glyph', 'Disable this to save gem fragments')
        end
        gui.elements.manage_orbwalker:render('Manage orbwalker', 'When enabled, this script will toggle orbwalker clear/block-movement during pit tasks. Off by default — leaves orbwalker fully under your rotation\'s control.')
        if gui.elements.manage_orbwalker:get() then
            gui.elements.disable_orbwalker_at_glyphstone:render('Disable orbwalker at glyphstone', 'When enabled, suspends orbwalker skill casts while standing within 5 units of the glyphstone after the boss dies')
        end
        gui.elements.death_recovery:render('Post-death recovery (BETA)',
            'WIP. After dying mid-pit, route back to the last-seen portal/boss/glyph/Choron\'s Soul ' ..
            'and walk back to the remembered boss position. Disabled by default while this is being tested.')
        gui.elements.use_chorons_soul:render("Use Choron's Soul",
            "After the boss dies, interact with the Choron's Soul actor to consume " ..
            "remaining glyph upgrade chances for experience.")
        gui.elements.pit_settings_tree:pop()
    end
    if gui.elements.party_settings_tree:push('Party Settings') then
        gui.elements.party_enabled:render('enable party mode', 'enable party mode')
        if gui.elements.party_enabled:get() then
            -- gui.elements.use_magoogle_tool:render('use magoogle tools', 'use magoogle tools')
            gui.elements.party_mode:render('party mode', gui.party_mode, 'Select if your character is leader or follower')
            if gui.elements.party_mode:get() == 0 then
                gui.elements.confirm_delay:render('Accept delay (s)', 'time in seconds to wait for accept start/reset from party member')
            else
                gui.elements.follower_explore:render('Follower explore?', 'explore pit as a follow')
            end
        end
        gui.elements.party_settings_tree:pop()
    end
    gui.elements.main_tree:pop()
end

return gui