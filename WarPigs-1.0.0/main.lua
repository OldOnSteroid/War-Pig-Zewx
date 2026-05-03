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

local render_pulse = function()
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
