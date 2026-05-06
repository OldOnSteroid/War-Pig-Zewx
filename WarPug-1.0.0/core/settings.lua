local gui = require 'gui'

-- War plan table actor skin name. Update this constant once confirmed in-game
-- (use the debug/actor-dump tools — look for an actor near the war plan board
-- in Temis). When blank, WarPug relies on warplan.is_ready() being true
-- already; if the panel is also closed it will log a warning and stay IDLE.
local TABLE_ACTOR_NAME = ''

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

local function get_screen_width()
    if utility and type(utility.get_screen_width) == 'function' then
        local ok, w = pcall(utility.get_screen_width)
        if ok and type(w) == 'number' then return w end
    end
    return 1920
end

settings.update_settings = function()
    settings.enabled          = gui.elements.main_toggle:get()
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.verbose_logs     = gui.elements.verbose_logs:get()

    if get_screen_width() >= 3840 then
        settings.reroll_click_x   = gui.elements.reroll_click_x_8k:get()
        settings.reroll_click_y   = gui.elements.reroll_click_y_8k:get()
        settings.reroll_confirm_x = gui.elements.reroll_confirm_x_8k:get()
        settings.reroll_confirm_y = gui.elements.reroll_confirm_y_8k:get()
    else
        settings.reroll_click_x   = gui.elements.reroll_click_x:get()
        settings.reroll_click_y   = gui.elements.reroll_click_y:get()
        settings.reroll_confirm_x = gui.elements.reroll_confirm_x:get()
        settings.reroll_confirm_y = gui.elements.reroll_confirm_y:get()
    end
end

return settings
