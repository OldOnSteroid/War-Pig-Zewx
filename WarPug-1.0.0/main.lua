local gui      = require 'gui'
local settings = require 'core.settings'
local planner  = require 'core.planner'
local external = require 'core.external'

local last_tick     = 0
local TICK_INTERVAL = 0.5

local main_pulse = function()
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
    if settings.show_click_points then
        local rx = settings.reroll_click_x
        local ry = settings.reroll_click_y
        if rx > 0 and ry > 0 then
            draw_crosshair(rx, ry, 'Reroll', COL_CROSSHAIR)
        end
        local cx = settings.reroll_confirm_x
        local cy = settings.reroll_confirm_y
        if cx > 0 and cy > 0 then
            draw_crosshair(cx, cy, 'RerollConfirm', COL_CROSSHAIR)
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
