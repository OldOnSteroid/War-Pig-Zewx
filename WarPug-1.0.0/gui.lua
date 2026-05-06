local plugin_label   = 'war_pug'
local plugin_version = '1.0.0'
console.print('Lua Plugin - WarPug - War Plan Creator - v' .. plugin_version)

local gui = {}

local function ck(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

-- ── Resolution presets ────────────────────────────────────────────────────────
-- Settings picks the closest match to the actual screen width at runtime.
-- The combo in the GUI controls which preset you are currently configuring.
gui.RESOLUTIONS = {
    { label = '1920 \xc3\x97 1080  (Full HD)',           w = 1920, h = 1080, key = '1080p'   },
    { label = '1920 \xc3\x97 1200  (WUXGA)',             w = 1920, h = 1200, key = '1200p'   },
    { label = '2560 \xc3\x97 1080  (UltraWide FHD)',     w = 2560, h = 1080, key = '1080uw'  },
    { label = '2560 \xc3\x97 1440  (QHD / 2K)',          w = 2560, h = 1440, key = '1440p'   },
    { label = '2560 \xc3\x97 1600  (WQXGA)',             w = 2560, h = 1600, key = '1600p'   },
    { label = '3440 \xc3\x97 1440  (UltraWide QHD)',     w = 3440, h = 1440, key = '1440uw'  },
    { label = '3840 \xc3\x97 1600  (UltraWide QHD+)',    w = 3840, h = 1600, key = '1600uw'  },
    { label = '3840 \xc3\x97 2160  (4K UHD)',            w = 3840, h = 2160, key = '4k'      },
    { label = '5120 \xc3\x97 1440  (Super UltraWide)',   w = 5120, h = 1440, key = '5120uw'  },
    { label = '7680 \xc3\x97 4320  (8K UHD)',            w = 7680, h = 4320, key = '8k'      },
}

-- Per-resolution slider pairs: reroll X/Y and confirm X/Y.
-- Only the sliders for the selected resolution are shown; all sets are always
-- created so their hashed values persist across resolution switches.
gui.res_sliders = {}
for _, res in ipairs(gui.RESOLUTIONS) do
    local k = res.key
    gui.res_sliders[k] = {
        reroll_x  = slider_int:new(0, res.w, 0, get_hash(plugin_label .. '_rx_'  .. k)),
        reroll_y  = slider_int:new(0, res.h, 0, get_hash(plugin_label .. '_ry_'  .. k)),
        confirm_x = slider_int:new(0, res.w, 0, get_hash(plugin_label .. '_cx_'  .. k)),
        confirm_y = slider_int:new(0, res.h, 0, get_hash(plugin_label .. '_cy_'  .. k)),
    }
end

-- ── Screen-width helper (used both here and in settings.lua via gui) ──────────
function gui.get_screen_width()
    if utility and type(utility.get_screen_width) == 'function' then
        local ok, w = pcall(utility.get_screen_width)
        if ok and type(w) == 'number' then return w end
    end
    return 1920
end

-- Returns the resolution preset whose width is closest to `screen_w`.
function gui.pick_resolution(screen_w)
    local best, best_diff = gui.RESOLUTIONS[1], math.huge
    for _, res in ipairs(gui.RESOLUTIONS) do
        local diff = math.abs(res.w - screen_w)
        if diff < best_diff then
            best      = res
            best_diff = diff
        end
    end
    return best
end

-- ── GUI elements ─────────────────────────────────────────────────────────────
gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = ck(false, 'main_toggle'),

    -- Combo index selects which resolution's sliders to display (0-based).
    res_combo = combo_box:new(0, get_hash(plugin_label .. '_res_combo')),

    show_click_points = ck(false, 'show_click_points'),
    verbose_logs      = ck(false, 'verbose_logs'),
}

-- ── Render ────────────────────────────────────────────────────────────────────
gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pug | War Plan Creator | v' .. plugin_version) then
        return
    end

    gui.elements.main_toggle:render('Enable',
        'When in Temis with no active WarPlans quests, auto-select and confirm\n' ..
        'a new war plan path. Warplans_NightmareDungeons nodes are always excluded.\n' ..
        'If no valid path exists, click the configured reroll target and confirm.')

    -- ── Click calibration ────────────────────────────────────────────────────

    -- Build the label list for the combo.
    local res_labels = {}
    for _, res in ipairs(gui.RESOLUTIONS) do
        res_labels[#res_labels + 1] = res.label
    end

    -- Detect which preset will actually be used at runtime.
    local active_res   = gui.pick_resolution(gui.get_screen_width())
    local active_label = active_res.label

    render_menu_header('Click position calibration  [active: ' .. active_label .. ']')

    gui.elements.res_combo:render('Configure resolution', res_labels,
        'Select which resolution to configure below.\n' ..
        'At runtime the closest preset to your actual screen width is used automatically.\n' ..
        'Currently detected: ' .. active_label)

    -- Clamp combo index to valid range (safety against stale saved value).
    local idx = math.max(0, math.min(#gui.RESOLUTIONS - 1, gui.elements.res_combo:get()))
    local res     = gui.RESOLUTIONS[idx + 1]
    local sliders = gui.res_sliders[res.key]

    render_menu_header(string.format('Reroll click  (%d \xc3\x97 %d)', res.w, res.h))
    sliders.reroll_x:render('Reroll X \xe2\x86\x94',
        string.format('Pixel X of the reroll/refresh button on the war plan panel.\n' ..
            'Range: 0 \xe2\x80\x93 %d  (left \xe2\x86\x92 right)', res.w))
    sliders.reroll_y:render('Reroll Y \xe2\x86\x95',
        string.format('Pixel Y of the reroll/refresh button on the war plan panel.\n' ..
            'Range: 0 \xe2\x80\x93 %d  (top \xe2\x86\x92 bottom)', res.h))

    render_menu_header(string.format('Confirm click  (%d \xc3\x97 %d)', res.w, res.h))
    sliders.confirm_x:render('Confirm X \xe2\x86\x94',
        string.format('Pixel X of the confirm button in the reroll dialog.\n' ..
            'Range: 0 \xe2\x80\x93 %d  (left \xe2\x86\x92 right)', res.w))
    sliders.confirm_y:render('Confirm Y \xe2\x86\x95',
        string.format('Pixel Y of the confirm button in the reroll dialog.\n' ..
            'Range: 0 \xe2\x80\x93 %d  (top \xe2\x86\x92 bottom)', res.h))

    -- ── Diagnostics ──────────────────────────────────────────────────────────
    render_menu_header('Diagnostics')
    gui.elements.show_click_points:render('Show click positions',
        'Draw green crosshairs at both configured click targets. Recent scripted\n' ..
        'clicks also appear as a fading yellow circle for ~6s after firing.')
    gui.elements.verbose_logs:render('Verbose logs',
        'Print extra state-transition detail to the console.')

    gui.elements.main_tree:pop()
end

return gui
