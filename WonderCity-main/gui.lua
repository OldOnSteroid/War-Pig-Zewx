local plugin_label = 'wonder_city'
local plugin_version = '1.0.4'
console.print("Lua Plugin - WonderCity - Leoric - v" .. plugin_version)

local gui = {}

local create_checkbox = function (value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.party_modes_enum = {
    LEADER = 0,
    FOLLOWER = 1
}
gui.party_mode = { 'Leader', 'Follower'}

gui.exit_modes_enum = {
    RESET = 0,
    TELEPORT = 1,
}
gui.exit_mode = { 'Reset', 'Teleport'}

gui.tributes = {}
gui.tributes_enum = {}
gui.tributes_data = {
    {sno_id = 2125049, skin_name = 'Tribute of Ascendance', name = 'Ascendance', enum = 'ASCENDANCE'},
    {sno_id = 2485152, skin_name = 'Major Tribute of Andariel', name = 'Major Andariel', enum = 'MAJOR_ANDARIEL'},
    {sno_id = 2485144, skin_name = 'Tribute of Andariel', name = 'Andariel', enum = 'ANDARIEL'},
    {sno_id = 2090358, skin_name = 'Tribute of Titans', name = 'Titans', enum = 'TITANS'},
    {sno_id = 2447394, skin_name = 'Minor Tribute of Andariel', name = 'Minor Andariel', enum = 'MINOR_ANDARIEL'},
    {sno_id = 2077995, skin_name = 'Tribute of Refinement', name = 'Refinement', enum = 'REFINEMENT'},
    {sno_id = 2090362, skin_name = 'Tribute of Ascendance (Resolute)', name = 'Ascendance (R)', enum = 'ASCENDANCE_RESOLUTE'},
    {sno_id = 2125691, skin_name = 'Tribute of Harmony', name = 'Harmony', enum = 'HARMONY'},
    {sno_id = 2131528, skin_name = 'Tribute of Mystique', name = 'Mystique', enum = 'MYSTIQUE'},
    {sno_id = 2125047, skin_name = 'Tribute of Radiance', name = 'Radiance', enum = 'RADIANCE'},
    {sno_id = 2090360, skin_name = 'Tribute of Pride', name = 'Pride', enum = 'PRIDE'},
    {sno_id = 2077998, skin_name = 'Tribute of Radiance (Resolute)', name = 'Radiance (R)', enum = 'RADIUS_RESOLUTE'},
    {sno_id = 2125688, skin_name = 'Tribute of Growth', name = 'Growth', enum = 'GROWTH'},
    {sno_id = 2077993, skin_name = 'Tribute of Heritage', name = 'Heritage', enum = 'HERITAGE'},
}
gui.batmobile_priority = {
    'direction',
    'distance'
}
gui.batmobile_priority_enum = {
    DIRECTION = 0,
    DISTANCE = 1
}

-- Working town for the run loop. Used everywhere Kurast was hardcoded
-- (teleport_kurast, walk_kurast, enter_undercity, alfred). Resolved to
-- zone/waypoint in settings.lua.
gui.town = { 'Kurast', 'Temis' }
gui.town_enum = {
    KURAST = 0,
    TEMIS  = 1,
}
gui.town_data = {
    -- Kurast: walk_kurast follows the recorded waypoints in data/path.lua.
    [0] = {
        zone_name        = 'Naha_Kurast',
        waypoint_sno     = 0x1EAACC,  -- Kurast Bazaar
        long_path_target = nil,       -- nil → use data/path.lua waypoint sequence
    },
    -- Temis: walk uses BatmobilePlugin.navigate_long_path (uncapped A*) to
    -- the brazier/entrance position. No recorded waypoint path needed.
    [1] = {
        zone_name        = 'Skov_Temis',
        waypoint_sno     = 0x1CE51E,
        long_path_target = vec3:new(2556.9951171875, -506.392578125, 30.5966796875),
    },
}
for _, tribute in ipairs(gui.tributes_data) do
    gui.tributes[#gui.tributes+1] = tribute.name
    gui.tributes_enum[#gui.tributes_enum+1] = tribute.sno_id
end

-- Bargain options: needs_scroll=true means click scroll_bar first, then use cp_key click point
gui.bargains_data = {
    {name = 'Core Stats',            cp_key = 'core_stats',            needs_scroll = false},
    {name = 'Primary Resource',      cp_key = 'primary_resource',      needs_scroll = false},
    {name = 'Resistances',           cp_key = 'resistances',           needs_scroll = false},
    {name = 'Offensive Legendaries', cp_key = 'offensive_legendaries', needs_scroll = false},
    {name = 'Defensive Legendaries', cp_key = 'defensive_legendaries', needs_scroll = false},
    {name = 'Utility Legendaries',   cp_key = 'utility_legendaries',   needs_scroll = false},
    {name = 'Mobility Legendaries',  cp_key = 'mobility_legendaries',  needs_scroll = false},
    {name = 'Resource Legendaries',  cp_key = 'resource_legendaries',  needs_scroll = false},
    {name = 'Chaotic Uniques',       cp_key = 'defensive_legendaries', needs_scroll = true},
    {name = 'More Weapons',          cp_key = 'utility_legendaries',   needs_scroll = true},
    {name = 'More Armor',            cp_key = 'mobility_legendaries',  needs_scroll = true},
    {name = 'More Jewelry',          cp_key = 'resource_legendaries',  needs_scroll = true},
}
-- Ordered list of click point keys (used for both element creation and render)
gui.bargain_cp_keys = {
    'sort_button',
    'bargain_opener',
    'scroll_bar',
    'core_stats',
    'primary_resource',
    'resistances',
    'offensive_legendaries',
    'defensive_legendaries',
    'utility_legendaries',
    'mobility_legendaries',
    'resource_legendaries',
}
gui.bargain_cp_labels = {
    sort_button           = 'Sort Button (inventory)',
    bargain_opener        = 'Bargain Menu Opener',
    scroll_bar            = 'Scroll Down Bar',
    core_stats            = 'Core Stats',
    primary_resource      = 'Primary Resource',
    resistances           = 'Resistances',
    offensive_legendaries = 'Offensive Legendaries',
    defensive_legendaries = 'Defensive Legendaries (also Chaotic Uniques)',
    utility_legendaries   = 'Utility Legendaries (also More Weapons)',
    mobility_legendaries  = 'Mobility Legendaries (also More Armor)',
    resource_legendaries  = 'Resource Legendaries (also More Jewelry)',
}


gui.plugin_label = plugin_label
gui.plugin_version = plugin_version
gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, 'main_toggle'),
    use_keybind = create_checkbox(false, 'use_keybind'),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle' )),
    undercity_settings_tree = tree_node:new(1),
    town = combo_box:new(0, get_hash(plugin_label .. '_' .. 'town')),
    reset_timeout = slider_int:new(30, 900, 600, get_hash(plugin_label .. '_' .. 'reset_timeout')),
    boss_delay = slider_int:new(0, 30, 10, get_hash(plugin_label .. '_' .. 'boss_delay')),
    exit_undercity_delay = slider_int:new(0, 300, 10, get_hash(plugin_label .. '_' .. 'exit_undercity_delay')),
    exit_mode = combo_box:new(0, get_hash(plugin_label .. '_' .. 'exit_mode')),
    loot_obols = create_checkbox(true, 'loot_obols'),
    max_enticement = slider_int:new(0, 9, 5, get_hash(plugin_label .. '_' .. 'max_enticement')),
    enticement_timeout = slider_int:new(0, 10, 4, get_hash(plugin_label .. '_' .. 'enticement_timeout')),
    beacon_timeout = slider_int:new(0, 30, 10, get_hash(plugin_label .. '_' .. 'beacon_timeout')),
    skip_monsters = create_checkbox(false, 'skip_monsters'),
    manage_orbwalker = create_checkbox(false, 'manage_orbwalker'),
    use_custom_explorer = create_checkbox(false, 'use_custom_explorer'),
    batmobile_priority = combo_box:new(1, get_hash(plugin_label .. '_' .. 'batmobile_priority')),

    tribute_priority_tree = tree_node:new(1),

    enable_bargains = create_checkbox(false, 'enable_bargains'),
    bargain_timeout = slider_int:new(3, 60, 10, get_hash(plugin_label .. '_' .. 'bargain_timeout')),
    bargain_priority_tree = tree_node:new(1),

    click_points_tree = tree_node:new(1),
    show_click_points = create_checkbox(false, 'show_click_points'),
    accept_button_x = slider_int:new(0, 3840, 960, get_hash(plugin_label .. '_' .. 'accept_button_x')),
    accept_button_y = slider_int:new(0, 2160, 540, get_hash(plugin_label .. '_' .. 'accept_button_y')),
    portal_button_x = slider_int:new(0, 3840, 960, get_hash(plugin_label .. '_' .. 'portal_button_x')),
    portal_button_y = slider_int:new(0, 2160, 540, get_hash(plugin_label .. '_' .. 'portal_button_y')),
    inventory_slot_0_x = slider_int:new(0, 3840, 960, get_hash(plugin_label .. '_' .. 'inventory_slot_0_x')),
    inventory_slot_0_y = slider_int:new(0, 2160, 540, get_hash(plugin_label .. '_' .. 'inventory_slot_0_y')),
    inventory_cell_size_x = slider_int:new(20, 120, 50, get_hash(plugin_label .. '_' .. 'inventory_cell_size_x')),
    inventory_cell_size_y = slider_int:new(20, 120, 50, get_hash(plugin_label .. '_' .. 'inventory_cell_size_y')),

    party_settings_tree = tree_node:new(1),
    party_enabled = create_checkbox(false, 'party_enabled'),
    party_mode = combo_box:new(0, get_hash(plugin_label .. '_' .. 'party_mode')),
    confirm_delay = slider_int:new(1, 300, 5, get_hash(plugin_label .. '_' .. 'confirm_delay')),
    use_magoogle_tool = create_checkbox(false, 'use_magoogle_tool'),
    follower_explore = create_checkbox(false, 'follower_explore'),
}
-- Dynamic: tribute priority sliders
for i in ipairs(gui.tributes_data) do
    gui.elements['tribute_priority_' .. i] = slider_int:new(0, #gui.tributes_data, 0, get_hash(plugin_label .. '_tribute_priority_' .. i))
end
-- Dynamic: bargain priority sliders + click point sliders
for i in ipairs(gui.bargains_data) do
    gui.elements['bargain_priority_' .. i] = slider_int:new(0, #gui.bargains_data, 0, get_hash(plugin_label .. '_bargain_priority_' .. i))
end
for _, key in ipairs(gui.bargain_cp_keys) do
    gui.elements['bargain_cp_' .. key .. '_x'] = slider_int:new(0, 3840, 960, get_hash(plugin_label .. '_bargain_cp_' .. key .. '_x'))
    gui.elements['bargain_cp_' .. key .. '_y'] = slider_int:new(0, 2160, 540, get_hash(plugin_label .. '_bargain_cp_' .. key .. '_y'))
end

gui.render = function ()
    if not gui.elements.main_tree:push('Z | WonderCity | Leoric | v' .. gui.plugin_version) then return end
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
    gui.elements.main_toggle:render('Enable', 'Enable WonderCity')
    gui.elements.use_keybind:render('Use keybind', 'Keybind to quick toggle the bot')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Toggle the bot for quick enable')
    end
    if gui.elements.undercity_settings_tree:push('Undercity Settings') then
        gui.elements.town:render('Town', gui.town, 'Working town: where the bot teleports/returns to and where Alfred runs salvage. Should match your AlfredTheButler town setting.')
        gui.elements.batmobile_priority:render('Batmobile priority', gui.batmobile_priority, 'Select whether to priortize direction or distance while exploring')
        if gui.elements.batmobile_priority:get() == 1 then
            render_menu_header('[EXPERIMENTAL] Priortizing distance will use more processing power. ' ..
                'Depending on layout, might result in more backtracking.' ..
                'In general, it should be better for undercity.....')
        end
        gui.elements.reset_timeout:render("Reset Time (s)", "Set the time in seconds for resetting all dungeons")
        gui.elements.exit_undercity_delay:render('Exit delay (s)', 'time in seconds to wait before ending undercity')
        gui.elements.exit_mode:render('Exit mode', gui.exit_mode, 'Select reset or teleport to exit undercity')
        gui.elements.boss_delay:render('Boss delay (s)', 'time in seconds to wait before engaging undercity boss')
        gui.elements.max_enticement:render('Max Enticement', 'maximum number of enticement to interact excluding beacon')
        gui.elements.enticement_timeout:render('Enticement delay (s)', 'time in seconds to wait before leaving enticement')
        gui.elements.beacon_timeout:render('Beacon delay (s)', 'time in seconds to wait before leaving beacon')
        gui.elements.loot_obols:render('Loot Obols', 'Loot Obols')
        gui.elements.manage_orbwalker:render('Manage orbwalker', 'When enabled, this script will toggle orbwalker clear/block-movement during undercity tasks. Off by default — leaves orbwalker fully under your rotation\'s control.')
        if gui.elements.manage_orbwalker:get() then
            gui.elements.skip_monsters:render('Skip monsters', 'Disable orbwalker until reaching an enticement, beacon, elite or boss')
        end
        gui.elements.use_custom_explorer:render('Use custom explorer', 'Use the WonderCity targeted explorer instead of Batmobile full-coverage (objective-first BFS)')

        if gui.elements.tribute_priority_tree:push('Tribute Priority') then
            render_menu_header('Set priority for each tribute (0 = skip, 1 = highest priority)')
            for i, tribute in ipairs(gui.tributes_data) do
                gui.elements['tribute_priority_' .. i]:render(tribute.name, 'Priority for ' .. tribute.name .. ' (0 = skip)')
            end
            gui.elements.tribute_priority_tree:pop()
        end

        gui.elements.enable_bargains:render('Enable Bargains', 'Select a bargain from the obelisk before opening portal')
        if gui.elements.enable_bargains:get() then
            gui.elements.bargain_timeout:render('Bargain timeout (s)', 'Seconds to wait for portal before assuming bargain failed and trying next')
            if gui.elements.bargain_priority_tree:push('Bargain Priority') then
                render_menu_header('Set priority for each bargain (0 = skip, 1 = try first). Scrolled options reuse click points from the matching non-scrolled option.')
                for i, bargain in ipairs(gui.bargains_data) do
                    local scroll_note = bargain.needs_scroll and ' [scroll]' or ''
                    gui.elements['bargain_priority_' .. i]:render(bargain.name .. scroll_note, 'Priority for ' .. bargain.name .. ' (0 = skip)')
                end
                gui.elements.bargain_priority_tree:pop()
            end
        end

        if gui.elements.click_points_tree:push('Click Points Setup') then
            gui.elements.show_click_points:render('Show Click Points', 'Show crosshairs on screen for all configured click point positions')

            -- Tribute right-click target (used by both flows)
            render_menu_header('Inventory - 11x3 grid, Slot 0 is top-left')
            gui.elements.inventory_slot_0_x:render('Slot 0 X', 'Screen X of the CENTER of the top-left inventory cell')
            gui.elements.inventory_slot_0_y:render('Slot 0 Y', 'Screen Y of the CENTER of the top-left inventory cell')
            gui.elements.inventory_cell_size_x:render('Cell Size X (px)', 'Horizontal center-to-center distance between adjacent cells')
            gui.elements.inventory_cell_size_y:render('Cell Size Y (px)', 'Vertical center-to-center distance between adjacent cells')

            -- Open Portal click (used by both flows)
            render_menu_header('Open Portal Button')
            gui.elements.portal_button_x:render('Portal Button X', 'Screen X coordinate of the Open Portal button')
            gui.elements.portal_button_y:render('Portal Button Y', 'Screen Y coordinate of the Open Portal button')

            -- Accept click (used by both flows)
            render_menu_header('Accept Button')
            gui.elements.accept_button_x:render('Accept Button X', 'Screen X coordinate of the Accept button')
            gui.elements.accept_button_y:render('Accept Button Y', 'Screen Y coordinate of the Accept button')

            -- Bargain-only click points
            if gui.elements.enable_bargains:get() then
                render_menu_header('Bargain Click Points')
                for _, key in ipairs(gui.bargain_cp_keys) do
                    local label = gui.bargain_cp_labels[key]
                    gui.elements['bargain_cp_' .. key .. '_x']:render(label .. ' X', 'Screen X for ' .. label)
                    gui.elements['bargain_cp_' .. key .. '_y']:render(label .. ' Y', 'Screen Y for ' .. label)
                end
            end
            gui.elements.click_points_tree:pop()
        end

        gui.elements.undercity_settings_tree:pop()
    end
    if gui.elements.party_settings_tree:push('Party Settings') then
        render_menu_header('Coming soon')
        -- gui.elements.party_enabled:render('enable party mode', 'enable party mode')
        -- if gui.elements.party_enabled:get() then
        --     -- gui.elements.use_magoogle_tool:render('use magoogle tools', 'use magoogle tools')
        --     gui.elements.party_mode:render('party mode', gui.party_mode, 'Select if your character is leader or follower')
        --     if gui.elements.party_mode:get() == 0 then
        --         gui.elements.confirm_delay:render('Accept delay (s)', 'time in seconds to wait for accept start/reset from party member')
        --     else
        --         gui.elements.follower_explore:render('Follower explore?', 'explore undercity as a follow')
        --     end
        -- end
        -- gui.elements.party_settings_tree:pop()
    end
    gui.elements.main_tree:pop()
end

return gui
