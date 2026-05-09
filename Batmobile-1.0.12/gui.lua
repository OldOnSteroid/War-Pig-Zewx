local plugin_label = 'batmobile'
local plugin_version = '1.0.12'
console.print("Lua Plugin - Batmobile - Leoric - v" .. plugin_version)

local get_character_class = function (local_player)
    if not local_player then
        local_player = get_local_player();
    end
    if not local_player then return end
    local class_id = local_player:get_character_class_id()
    local character_classes = {
        [0] = 'sorcerer',
        [1] = 'barbarian',
        [3] = 'rogue',
        [5] = 'druid',
        [6] = 'necromancer',
        [7] = 'spiritborn',
        [8] = 'default', -- new class in expansion, dont know name yet
        [9] = 'paladin',
        [10] = 'warlock'
    }
    if character_classes[class_id] then
        return character_classes[class_id]
    else
        return 'default'
    end
end

local gui = {}

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label = plugin_label
gui.plugin_version = plugin_version
gui.log_levels_enum = {
    DISABLED = 0,
    INFO = 1,
    DEBUG = 2
}
gui.log_level = { 'Disabled', 'Info', 'Debug'}

gui.elements = {
    main_tree = tree_node:new(0),
    reset_keybind = keybind:new(0x0A, true, get_hash(plugin_label .. '_reset_keybind' )),
    draw_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_draw_keybind_toggle' )),
    movement_tree = tree_node:new(1),
    move_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_move_keybind_toggle' )),
    use_evade = create_checkbox(true, "use_evade"),
    use_teleport = create_checkbox(true, "use_teleport"),
    use_teleport_enchanted = create_checkbox(true, "use_teleport_enchanted"),
    use_dash = create_checkbox(true, "use_dash"),
    use_soar = create_checkbox(true, "use_soar"),
    use_hunter = create_checkbox(true, "use_hunter"),
    use_leap = create_checkbox(true, "use_leap"),
    use_charge = create_checkbox(true, "use_charge"),
    use_advance = create_checkbox(true, "use_advance"),
    use_falling_star = create_checkbox(true, "use_falling_star"),
    use_aoj = create_checkbox(true, "use_aoj"),
    use_wraith_step = create_checkbox(true, "use_wraith_step"),
    use_demonic_slash = create_checkbox(true, "use_demonic_slash"),
    demonic_slash_los = create_checkbox(true, "demonic_slash_los"),
    min_spell_dist = slider_float:new(1.0, 20.0, 3.0, get_hash(plugin_label .. '_min_spell_dist')),
    require_full_path_explore = create_checkbox(false, "require_full_path_explore"),
    explore_path_budget_ms = slider_int:new(50, 500, 150, get_hash(plugin_label .. '_explore_path_budget_ms')),
    path_smooth_step = slider_float:new(0.0, 10.0, 1.0, get_hash(plugin_label .. '_path_smooth_step')),
    wall_path = create_checkbox(false, "wall_path"),
    wall_path_dist = slider_float:new(0.5, 10.0, 4.0, get_hash(plugin_label .. '_wall_path_dist')),
    advanced_tree = tree_node:new(1),
    max_iteration = slider_int:new(250, 5000, 1500, get_hash(plugin_label .. '_' .. 'max_iteration')),
    debug_tree = tree_node:new(1),
    log_level = combo_box:new(0, get_hash(plugin_label .. '_' .. 'log_level')),
    nav_viz = create_checkbox(false, "nav_viz"),
    freeroam_keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. '_freeroam_keybind_toggle' )),
    long_path_tree = tree_node:new(1),
    long_path_set_target        = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_set_target')),
    long_path_set_target_cursor = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_set_target_cursor')),
    long_path_test              = keybind:new(0x0A, true, get_hash(plugin_label .. '_long_path_test')),
}
gui.long_path_target_str  = nil    -- updated by main.lua after set_target()
gui.long_path_navigating  = false  -- updated by main.lua each frame
function gui.render()
    if not gui.elements.main_tree:push('Z | Batmobile | Leoric | v' .. gui.plugin_version) then return end
    gui.elements.draw_keybind_toggle:render('Toggle Drawing', 'Toggle drawing')
    gui.elements.move_keybind_toggle:render('use movement spells', 'use movement spells')
    gui.elements.reset_keybind:render('Reset batmobile', 'Keybind to reset batmobile')
    if gui.elements.movement_tree:push('Movement Spells') then
        render_menu_header("Need 'use movement spell' to be toggled on to work")
        local class = get_character_class()
        gui.elements.use_evade:render('evade', 'use evade for movement')
        if class == 'sorcerer' then
            gui.elements.use_teleport:render('teleport', 'use teleport for movement')
            gui.elements.use_teleport_enchanted:render('teleport enchanted', 'use teleport enchanted for movement')
        elseif class == 'rogue' then
            gui.elements.use_dash:render('dash', 'use dash for movement')
        elseif class == 'spiritborn' then
            gui.elements.use_soar:render('soar', 'use soar for movement')
            gui.elements.use_hunter:render('hunter', 'use hunter for movement')
        elseif class == 'barbarian' then
            gui.elements.use_leap:render('leap', 'use leap for movement')
            gui.elements.use_charge:render('charge', 'use charge for movement')
        elseif class == 'paladin' then
            gui.elements.use_advance:render('advance', 'use advance for movement')
            gui.elements.use_falling_star:render('falling star', 'use falling star for movement')
            gui.elements.use_aoj:render('Arbiter of Justice', 'use Arbiter of Justice for movement')
        elseif class == 'warlock' then
            gui.elements.use_wraith_step:render('wraith step', 'use wraith step for movement (position-cast mobility, the proper warlock movement skill)')
            gui.elements.use_demonic_slash:render('demonic slash', 'use demonic slash for movement (NOTE: target-cast cooldown — may not fire via Batmobile position-cast)')
            gui.elements.demonic_slash_los:render('  demonic slash requires LOS',
                'On = require line-of-sight raycast to the destination (charge-style: blocked by walls).\n' ..
                'Off = skip the LOS check (blink-style: phases through obstacles).\n' ..
                'Try OFF first if the cast never fires.')
        end
        gui.elements.min_spell_dist:render('Min spell distance',
            'Minimum distance (in units) from the player to a path node before a movement\n' ..
            'spell will target that node. Raise to stop the bot from burning movement\n' ..
            'cooldowns on tiny hops; lower to let it cast more aggressively on short paths.\n' ..
            'Default 3.0.', 1)
        gui.elements.movement_tree:pop()
    end
    gui.elements.require_full_path_explore:render('Full path only (explore)',
        'Skip any frontier the pathfinder cannot fully reach from the current position.\n' ..
        'Prevents the bot from walking toward unreachable cells (cliffs, walls across floors).\n' ..
        'Only applies to explorer targets — custom targets (kill, chest) are unaffected.')
    if gui.elements.require_full_path_explore:get() then
        gui.elements.explore_path_budget_ms:render('Path budget (ms)',
            'A* time budget per frontier pathfind when Full path only is on.\n' ..
            'Higher = handles longer winding paths correctly but costs more CPU per pick.\n' ..
            '150ms is reasonable; 300ms+ will cause noticeable lag on busy floors.')
    end
    gui.elements.path_smooth_step:render('Path smoothing step',
        'LOS sample interval used when simplifying A* paths (string-pull).\n' ..
        '0 = disabled (raw A* grid path, maximum safety near thin walls).\n' ..
        '0.5-1.0 = conservative (tight sampling, follows grid closely).\n' ..
        '1.0-3.0 = normal range (default 1.0).\n' ..
        '3.0-10.0 = super smooth (very few LOS samples, longest straight segments).\n' ..
        'Raise if paths look jagged or the bot over-corrects; lower/disable if it clips small pillars.', 1)
    gui.elements.wall_path:render('Wall path avoidance',
        'Heavily penalize partial paths whose endpoint lands within N units of an unwalkable cell.\n' ..
        'When the pathfinder cannot reach the goal and dumps the player against a wall/cliff,\n' ..
        'this skips that partial path so the explorer picks a different frontier instead.\n' ..
        'Only applies to explorer targets; custom targets (kill, chest, traversal) are unaffected.')
    if gui.elements.wall_path:get() then
        gui.elements.wall_path_dist:render('Wall path distance',
            'How many units around the partial-path endpoint to scan for unwalkable cells.\n' ..
            'Higher = more aggressive avoidance (rejects paths even with walls farther away).\n' ..
            'Lower = only rejects paths that hug a wall closely.\n' ..
            'Default 4.0; raise to 6-8 if the bot keeps wedging against ledges, lower if it refuses\n' ..
            'legitimate frontiers near tight corridors.', 1)
    end
    if gui.elements.debug_tree:push('Debug') then
        gui.elements.freeroam_keybind_toggle:render('Toggle explorer', 'enable freeroam explorer')
        render_menu_header('WARNING running explorer in overworld can cause big lag spike due to multiple elevation and traversals close by')
        gui.elements.log_level:render('logging', gui.log_level, 'Select log level')
        gui.elements.nav_viz:render('Nav viz (walkable grid)', 'Show walkable/wall grid + nav vectors around player. Green=walkable, Red=blocked. Rescans every 0.3s.')
        gui.elements.debug_tree:pop()
    end
    -- if gui.elements.advanced_tree:push('Advanced settings') then
    --     gui.elements.max_iteration:render('Max iteration', 'smaller = weaker but less lag, bigger = better pathfinding but laggier')

    --     gui.elements.advanced_tree:pop()
    -- end
    if gui.elements.long_path_tree:push('Long Path Debug') then
        render_menu_header('1. Walk to destination, click Set Target.')
        render_menu_header('2. Walk far away, click Test Long Path.')
        render_menu_header('   Draws route + moves to target. Click again to stop.')
        local target_display = gui.long_path_target_str or '(none pinned)'
        render_menu_header('Pinned: ' .. target_display)
        if gui.long_path_navigating then
            render_menu_header('Status: NAVIGATING — click Test Long Path to stop')
        end
        gui.elements.long_path_set_target:render('Set Target (Player)', 'Pin current player position as path goal')
        gui.elements.long_path_set_target_cursor:render('Set Target (Cursor)', 'Pin current cursor world position as path goal')
        local test_label = gui.long_path_navigating and 'Stop Navigation' or 'Test Long Path'
        gui.elements.long_path_test:render(test_label, 'Run uncapped A* from here to pinned target (click again to stop)')
        gui.elements.long_path_tree:pop()
    end
    gui.elements.main_tree:pop()
end

return gui