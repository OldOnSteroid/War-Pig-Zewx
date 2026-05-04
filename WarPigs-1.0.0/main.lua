local gui          = require 'gui'
local settings     = require 'core.settings'
local orchestrator = require 'core.orchestrator'
local external     = require 'core.external'

local last_tick      = 0
local tick_interval  = 0.5
local was_enabled    = false

local main_pulse = function()
    if get_time_since_inject() - last_tick < tick_interval then return end
    last_tick = get_time_since_inject()
    settings:update_settings()

    -- Treat the keybind as a gate stacked on top of the main toggle: if
    -- keybind mode is on but the key isn't held/toggled, behave exactly like
    -- the main toggle being off (release any plugins WarPigs has paused so
    -- they resume autonomously).
    local active = settings.enabled and settings.get_keybind_state()
    if not active then
        if was_enabled then orchestrator.release_all() end
        was_enabled = false
        return
    end
    was_enabled = true

    if not get_local_player() then return end
    orchestrator.tick()
end

-- Crosshair drawer matching WonderCity's draw_crosshair: short cross arms,
-- small inner circle, label offset to the upper-right. Used for the teleport
-- click target so the user can verify the position visually.
local TELEPORT_CROSSHAIR = color_green(220)
local TELEPORT_CLICK_HIT = color_yellow(255)

local function draw_crosshair(cx, cy, label, color)
    local arm = 12
    graphics.line(vec2:new(cx - arm, cy), vec2:new(cx + arm, cy), color, 2)
    graphics.line(vec2:new(cx, cy - arm), vec2:new(cx, cy + arm), color, 2)
    graphics.circle_2d(vec2:new(cx, cy), 5, color, 1)
    graphics.text_2d(label, vec2:new(cx + 14, cy - 8), 14, color)
end

local render_pulse = function()
    -- Click-point overlay is independent of the main enable gate so the user
    -- can calibrate the click target with the bot paused. Mirrors WonderCity.
    if settings.show_click_points
        and settings.use_teleport_transition
        and settings.teleport_click_x and settings.teleport_click_x > 0
        and settings.teleport_click_y and settings.teleport_click_y > 0
    then
        draw_crosshair(
            settings.teleport_click_x,
            settings.teleport_click_y,
            'Teleport',
            TELEPORT_CROSSHAIR)
    end

    -- Recent-click fade markers: yellow ring + label, fades over CLICK_FADE
    -- seconds. Lets you see exactly where each scripted click landed.
    local clicks, fade = orchestrator.get_recent_clicks()
    if clicks and fade and #clicks > 0 then
        local now = get_time_since_inject()
        for _, c in ipairs(clicks) do
            local age   = now - c.t
            local alpha = math.max(0, math.min(255, math.floor(255 * (1 - age / fade))))
            local col   = color_yellow(alpha)
            graphics.circle_2d(vec2:new(c.x, c.y), 14, col, 2)
            graphics.circle_2d(vec2:new(c.x, c.y), 3,  col, 2)
            graphics.text_2d(string.format('%s (%.1fs)', c.label, age),
                vec2:new(c.x + 18, c.y + 10), 13, col)
        end
    end

    if not (settings.enabled and settings.get_keybind_state()) then return end
    local msg = orchestrator.get_status_line()
    if not msg then return end
    local x_pos = get_screen_width() / 2 - (#msg * 5.5)
    graphics.text_2d(msg, vec2:new(x_pos, 100), 20, color_white(255))
end

on_update(main_pulse)
on_render_menu(function() gui.render() end)
on_render(render_pulse)

WarPigsPlugin = external
