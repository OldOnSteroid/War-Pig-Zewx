local gui      = require 'gui'
local settings = require 'core.settings'
local planner  = require 'core.planner'
local external = require 'core.external'

local last_tick     = 0
local TICK_INTERVAL = 0.5

-- ── Test click sequencer ─────────────────────────────────────────────────────
-- Mirrors the planner's REROLL_CLICK1 → 1.5s wait → REROLL_CLICK2 sequence
-- but lives outside planner.tick() so it can fire while WarPug is disabled
-- (which is the common calibration scenario). Refuses to run when the live
-- planner is enabled so two click sequences never overlap.
local TEST_S = {
    IDLE   = 'IDLE',
    CLICK1 = 'CLICK1',
    WAIT   = 'WAIT',
    CLICK2 = 'CLICK2',
}
local TEST_INTER_CLICK_DELAY = 1.5  -- matches planner.REROLL_CLICK1_DELAY
local TEST_KB_DEBOUNCE       = 0.5
local test_state    = TEST_S.IDLE
local test_state_t  = -math.huge
local last_test_kb  = -math.huge

local function test_click(field_x, field_y, label)
    local sw, sh = get_screen_width(), get_screen_height()
    local p = gui.positions
    local x = math.floor(p[field_x] * sw)
    local y = math.max(1, math.floor(p[field_y] * sh))
    planner.fire_click(x, y, label)
end

local function tick_test()
    local now = get_time_since_inject()

    if test_state == TEST_S.IDLE then
        local kb = gui.elements.keybind_test_clicks
        if kb:get_state() == 1 and kb:get_key() ~= 0x0A
           and (now - last_test_kb) >= TEST_KB_DEBOUNCE then
            last_test_kb = now
            if not (gui.positions.reroll_set and gui.positions.confirm_set) then
                console.print('[WarPug] test: capture both Reroll and Confirm positions first')
                return
            end
            if gui.elements.main_toggle:get() then
                console.print('[WarPug] test: disable WarPug first — the live state machine is active')
                return
            end
            console.print('[WarPug] test: firing Reroll click')
            test_click('reroll_rx', 'reroll_ry', 'Reroll')
            test_state   = TEST_S.WAIT
            test_state_t = now
        end
        return
    end

    if test_state == TEST_S.WAIT then
        if (now - test_state_t) >= TEST_INTER_CLICK_DELAY then
            console.print('[WarPug] test: firing Confirm click')
            test_click('confirm_rx', 'confirm_ry', 'RerollConfirm')
            console.print('[WarPug] test: sequence complete')
            test_state = TEST_S.IDLE
        end
        return
    end
end

local main_pulse = function()
    -- Poll capture keybinds every tick so a press is never missed by the
    -- planner's TICK_INTERVAL gate below.
    gui.poll_keybinds()
    tick_test()

    if get_time_since_inject() - last_tick < TICK_INTERVAL then return end
    last_tick = get_time_since_inject()
    settings:update_settings()
    if not get_local_player() then return end
    planner.tick()
end

-- ── Rendering ────────────────────────────────────────────────────────────────

local COL_CROSSHAIR = color_green(220)

local function draw_crosshair(cx, cy, label, col)
    local arm = 12
    graphics.line(vec2:new(cx - arm, cy), vec2:new(cx + arm, cy), col, 2)
    graphics.line(vec2:new(cx, cy - arm), vec2:new(cx, cy + arm), col, 2)
    graphics.circle_2d(vec2:new(cx, cy), 5, col, 1)
    graphics.text_2d(label, vec2:new(cx + 14, cy - 8), 14, col)
end

local render_pulse = function()
    -- Click-position overlays are shown regardless of enable state so the
    -- user can calibrate coordinates with the plugin paused.
    if gui.elements.show_click_points:get() then
        local sw, sh = get_screen_width(), get_screen_height()
        local p = gui.positions
        if p.reroll_set then
            draw_crosshair(math.floor(p.reroll_rx * sw),
                           math.floor(p.reroll_ry * sh),
                           'Reroll', COL_CROSSHAIR)
        end
        if p.confirm_set then
            draw_crosshair(math.floor(p.confirm_rx * sw),
                           math.floor(p.confirm_ry * sh),
                           'RerollConfirm', COL_CROSSHAIR)
        end
    end

    -- Fading yellow circle for each recent scripted click (~6s TTL)
    local clicks, fade = planner.get_recent_clicks()
    if clicks and #clicks > 0 then
        local t = get_time_since_inject()
        for _, c in ipairs(clicks) do
            local age   = t - c.t
            local alpha = math.max(0, math.min(255, math.floor(255 * (1 - age / fade))))
            local col   = color_yellow(alpha)
            graphics.circle_2d(vec2:new(c.x, c.y), 14, col, 2)
            graphics.circle_2d(vec2:new(c.x, c.y),  3, col, 2)
            graphics.text_2d(
                string.format('%s (%.1fs)', c.label, age),
                vec2:new(c.x + 18, c.y + 10), 13, col)
        end
    end

    if not settings.enabled then return end
    local msg = planner.get_status_line()
    if not msg then return end
    local x_pos = get_screen_width() / 2 - (#msg * 5.5)
    graphics.text_2d(msg, vec2:new(x_pos, 120), 20, color_white(255))
end

on_update(main_pulse)
on_render_menu(function() gui.render() end)
on_render(render_pulse)

WarPugPlugin = external
