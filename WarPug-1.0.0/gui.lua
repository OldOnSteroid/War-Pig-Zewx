local plugin_label   = 'war_pug'
local plugin_version = '1.0.0'
console.print('Lua Plugin - WarPug - War Plan Creator - v' .. plugin_version)

local gui = {}

local function ck(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = ck(false, 'main_toggle'),

    -- Reroll click: opens the reroll/refresh dialog on the war plan panel.
    -- Same slider-pair pattern as WarPigs teleport: 1920x1080 and 8K variants.
    reroll_click_x     = slider_int:new(0, 1920, 0, get_hash(plugin_label .. '_reroll_click_x')),
    reroll_click_y     = slider_int:new(0, 1080, 0, get_hash(plugin_label .. '_reroll_click_y')),
    reroll_click_x_8k  = slider_int:new(0, 7680, 0, get_hash(plugin_label .. '_reroll_click_x_8k')),
    reroll_click_y_8k  = slider_int:new(0, 4320, 0, get_hash(plugin_label .. '_reroll_click_y_8k')),

    -- Reroll confirm click: confirms the reroll in the dialog that opens after click 1.
    reroll_confirm_x    = slider_int:new(0, 1920, 0, get_hash(plugin_label .. '_reroll_confirm_x')),
    reroll_confirm_y    = slider_int:new(0, 1080, 0, get_hash(plugin_label .. '_reroll_confirm_y')),
    reroll_confirm_x_8k = slider_int:new(0, 7680, 0, get_hash(plugin_label .. '_reroll_confirm_x_8k')),
    reroll_confirm_y_8k = slider_int:new(0, 4320, 0, get_hash(plugin_label .. '_reroll_confirm_y_8k')),

    show_click_points = ck(false, 'show_click_points'),
    verbose_logs      = ck(false, 'verbose_logs'),
}

gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pug | War Plan Creator | v' .. plugin_version) then
        return
    end

    gui.elements.main_toggle:render('Enable',
        'When in Temis with no active WarPlans quests, auto-select and confirm\n' ..
        'a new war plan path. Warplans_NightmareDungeons nodes are always excluded.\n' ..
        'If no valid path exists, click the configured reroll target and confirm.')

    render_menu_header('Reroll click target  (1920x1080)')
    gui.elements.reroll_click_x:render('Reroll X',
        'Pixel X of the reroll/refresh button on the war plan panel (1920x1080).\n' ..
        'Used when screen width < 3840.')
    gui.elements.reroll_click_y:render('Reroll Y',
        'Pixel Y of the reroll/refresh button on the war plan panel (1920x1080).')

    render_menu_header('Reroll confirm click  (1920x1080)')
    gui.elements.reroll_confirm_x:render('Confirm X',
        'Pixel X of the confirm button in the reroll dialog (1920x1080).')
    gui.elements.reroll_confirm_y:render('Confirm Y',
        'Pixel Y of the confirm button in the reroll dialog (1920x1080).')

    render_menu_header('8K  (7680x4320)')
    gui.elements.reroll_click_x_8k:render('Reroll X (8K)',
        'Pixel X of the reroll button at 8K resolution (screen width >= 3840).')
    gui.elements.reroll_click_y_8k:render('Reroll Y (8K)', '')
    gui.elements.reroll_confirm_x_8k:render('Confirm X (8K)', '')
    gui.elements.reroll_confirm_y_8k:render('Confirm Y (8K)', '')

    gui.elements.show_click_points:render('Show click positions',
        'Draw green crosshairs at both configured click targets. Recent scripted\n' ..
        'clicks also appear as a fading yellow circle for ~6s after firing.')
    gui.elements.verbose_logs:render('Verbose logs',
        'Print extra state-transition detail to the console.')

    gui.elements.main_tree:pop()
end

return gui
