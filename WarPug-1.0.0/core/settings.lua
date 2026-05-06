local gui = require 'gui'

-- War plan table actor skin name. Update this constant once confirmed in-game
-- (use the debug/actor-dump tools — look for an actor near the war plan board
-- in Temis). When blank, WarPug relies on warplan.is_ready() being true
-- already; if the panel is also closed it will log a warning and stay IDLE.
local TABLE_ACTOR_NAME = 'Warplans_Vendor'

local settings = {
    plugin_label     = gui.plugin_label,
    plugin_version   = gui.plugin_version,
    -- Runtime values populated by update_settings()
    enabled          = false,
    table_actor_name = TABLE_ACTOR_NAME,
    reroll_click_x   = 0,
    reroll_click_y   = 0,
    reroll_confirm_x = 0,
    reroll_confirm_y = 0,
    show_click_points = false,
    verbose_logs     = false,
}

settings.update_settings = function()
    settings.enabled           = gui.elements.main_toggle:get()
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.verbose_logs      = gui.elements.verbose_logs:get()

    -- Pick the resolution preset whose width best matches the actual screen.
    local res     = gui.pick_resolution(gui.get_screen_width())
    local sliders = gui.res_sliders[res.key]
    settings.reroll_click_x   = sliders.reroll_x:get()
    settings.reroll_click_y   = sliders.reroll_y:get()
    settings.reroll_confirm_x = sliders.confirm_x:get()
    settings.reroll_confirm_y = sliders.confirm_y:get()
end

return settings
