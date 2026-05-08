local plugin_label   = 'war_pug'
local plugin_version = '1.0.0'
console.print('Lua Plugin - WarPug - War Plan Creator - v' .. plugin_version)

local gui = {}

local function ck(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

-- ── Captured click positions ─────────────────────────────────────────────────
-- Stored as RELATIVE coords (0..1 of screen w/h) so values stay correct if
-- the user changes resolution. Persisted to positions.txt in the plugin root.
-- The file format is plain `key=value` lines so we don't need a JSON parser
-- for four numbers.
--
-- We keep this in a side-table because pushing values back into a slider via
-- `:set()` is unreliable on this user's QQT host (past investigations showed
-- it can crash mid-frame / corrupt UI state).
gui.positions = {
    reroll_rx   = 0.0,
    reroll_ry   = 0.0,
    confirm_rx  = 0.0,
    confirm_ry  = 0.0,
    reroll_set  = false,
    confirm_set = false,
}

local function get_plugin_root_path()
    local plugin_root = string.gmatch(package.path, '.*?\\?')()
    plugin_root = plugin_root:gsub('?', '')
    return plugin_root
end

local POS_FILE = get_plugin_root_path() .. 'positions.txt'

local function save_positions()
    local file, err = io.open(POS_FILE, 'w')
    if not file then
        console.print('[WarPug] failed to open ' .. POS_FILE .. ' for write: ' .. tostring(err))
        return
    end
    file:write(string.format('reroll_rx=%.6f\n',  gui.positions.reroll_rx))
    file:write(string.format('reroll_ry=%.6f\n',  gui.positions.reroll_ry))
    file:write(string.format('confirm_rx=%.6f\n', gui.positions.confirm_rx))
    file:write(string.format('confirm_ry=%.6f\n', gui.positions.confirm_ry))
    file:write(string.format('reroll_set=%s\n',   tostring(gui.positions.reroll_set)))
    file:write(string.format('confirm_set=%s\n',  tostring(gui.positions.confirm_set)))
    file:close()
end

local function load_positions()
    local file = io.open(POS_FILE, 'r')
    if not file then return end  -- first run, file doesn't exist yet
    for line in file:lines() do
        local k, v = line:match('^([%w_]+)=(.+)$')
        if k and v then
            if k == 'reroll_set' or k == 'confirm_set' then
                gui.positions[k] = (v == 'true')
            else
                local n = tonumber(v)
                if n and gui.positions[k] ~= nil then
                    gui.positions[k] = n
                end
            end
        end
    end
    file:close()
end

load_positions()

-- ── GUI elements ─────────────────────────────────────────────────────────────
gui.elements = {
    main_tree   = tree_node:new(0),
    main_toggle = ck(false, 'main_toggle'),

    -- 0x0A = harness convention for "no key bound yet" (matches WarPigs/HordeDev).
    -- Second arg `true` matches the predominant working pattern across this
    -- codebase (Alfred / HordeDev / Batmobile / MapRevealPathTest). With
    -- `false`, presses weren't registering as state==1 on this host.
    keybind_set_reroll  = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_set_reroll')),
    keybind_set_confirm = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_set_confirm')),
    keybind_test_clicks = keybind:new(0x0A, true, get_hash(plugin_label .. '_kb_test_clicks')),

    show_click_points = ck(false, 'show_click_points'),
    verbose_logs      = ck(false, 'verbose_logs'),
}

local function fmt_pos(rx, ry, set)
    if not set then return 'not captured' end
    local sw, sh = get_screen_width(), get_screen_height()
    local px = math.floor(rx * sw)
    local py = math.floor(ry * sh)
    return string.format('rel %.3f, %.3f  (= %dpx, %dpx at %dx%d)',
                         rx, ry, px, py, sw, sh)
end

-- Polls the capture keybinds. Called every on_update tick (not gated by the
-- planner's TICK_INTERVAL) so a key press is never missed.
--
-- The `true`-mode keybind can return state==1 for several consecutive frames
-- while the key is held; without a debounce a tap would fire several captures
-- in a row. 0.5s comfortably covers a normal tap.
local CAPTURE_DEBOUNCE_S = 0.5
local last_capture_time  = -math.huge

function gui.poll_keybinds()
    local function capture(field_x, field_y, field_set, label)
        local now = get_time_since_inject()
        if (now - last_capture_time) < CAPTURE_DEBOUNCE_S then return end
        last_capture_time = now

        local cx, cy = utility.get_cursor_screen_position()
        if not cx or not cy then
            console.print('[WarPug] capture failed: cursor position unavailable')
            return
        end
        local sw, sh = get_screen_width(), get_screen_height()
        if sw <= 0 or sh <= 0 then
            console.print('[WarPug] capture failed: bad screen size')
            return
        end
        gui.positions[field_x]   = cx / sw
        gui.positions[field_y]   = cy / sh
        gui.positions[field_set] = true
        save_positions()
        console.print(string.format(
            '[WarPug] %s captured: %dpx, %dpx  -> rel %.4f, %.4f (saved)',
            label, cx, cy, gui.positions[field_x], gui.positions[field_y]))
    end

    local kb_r = gui.elements.keybind_set_reroll
    if kb_r:get_state() == 1 and kb_r:get_key() ~= 0x0A then
        capture('reroll_rx', 'reroll_ry', 'reroll_set', 'Reroll')
    end
    local kb_c = gui.elements.keybind_set_confirm
    if kb_c:get_state() == 1 and kb_c:get_key() ~= 0x0A then
        capture('confirm_rx', 'confirm_ry', 'confirm_set', 'RerollConfirm')
    end
end

-- ── Render ────────────────────────────────────────────────────────────────────
gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pug | War Plan Creator | v' .. plugin_version) then
        return
    end

    gui.elements.main_toggle:render('Enable',
        'When in Temis with no active WarPlans quests, auto-select and confirm\n' ..
        'a new war plan path. Warplans_NightmareDungeons nodes are always excluded.\n' ..
        'If no valid path exists, click the configured reroll target and confirm.')

    render_menu_header('Click position calibration')

    gui.elements.keybind_set_reroll:render('Set Reroll Pos',
        'Hover the war plan reroll/refresh button in-game, then press this key\n' ..
        'to capture its position. Values are saved as relative (0..1) coordinates\n' ..
        'so they stay valid at any resolution.\n\n' ..
        'Currently saved: ' .. fmt_pos(gui.positions.reroll_rx,
                                       gui.positions.reroll_ry,
                                       gui.positions.reroll_set))
    gui.elements.keybind_set_confirm:render('Set Confirm Pos',
        'Hover the confirm button on the reroll dialog, then press this key\n' ..
        'to capture its position.\n\n' ..
        'Currently saved: ' .. fmt_pos(gui.positions.confirm_rx,
                                       gui.positions.confirm_ry,
                                       gui.positions.confirm_set))
    gui.elements.keybind_test_clicks:render('Test Click Sequence',
        'Fires the same Reroll click \xe2\x86\x92 1.5s wait \xe2\x86\x92 Confirm click\n' ..
        'sequence the planner would. Uses the captured positions, the same\n' ..
        'mouse_move + mouse_click path, and the same yellow-fade overlay so\n' ..
        'you can verify both targets land on the right buttons before\n' ..
        'enabling WarPug.\n\n' ..
        'Disable WarPug before testing — the test refuses to run while the\n' ..
        'live state machine is active to avoid two click sequences fighting.')

    render_menu_header('Diagnostics')
    gui.elements.show_click_points:render('Show click positions',
        'Draw green crosshairs at both captured click targets. Recent scripted\n' ..
        'clicks also appear as a fading yellow circle for ~6s after firing.')
    gui.elements.verbose_logs:render('Verbose logs',
        'Print extra state-transition detail to the console.')

    gui.elements.main_tree:pop()
end

return gui
