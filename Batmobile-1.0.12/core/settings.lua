local gui = require 'gui'

local settings = {
    plugin_label = gui.plugin_label,
    plugin_version = gui.plugin_version,
    draw = false,
    step = 0.5,
    normalizer = 2, -- *10/5 to get steps of 0.5
    use_movement = false,
    use_evade = false,
    use_teleport = false,
    use_teleport_enchanted = false,
    use_dash = false,
    use_soar = false,
    use_hunter = false,
    use_leap = false,
    use_charge = false,
    use_advance = false,
    use_falling_star = false,
    use_aoj = false,
    log_level = gui.log_levels_enum['INFO'],
    nav_viz = false
}

settings.update_settings = function ()
    settings.draw = gui.elements.draw_keybind_toggle:get_state() == 1
    settings.use_movement = gui.elements.move_keybind_toggle:get_state() == 1
    settings.use_evade = gui.elements.use_evade:get()
    settings.use_teleport = gui.elements.use_teleport:get()
    settings.use_teleport_enchanted = gui.elements.use_teleport_enchanted:get()
    settings.use_dash = gui.elements.use_dash:get()
    settings.use_soar = gui.elements.use_soar:get()
    settings.use_hunter = gui.elements.use_hunter:get()
    settings.use_leap = gui.elements.use_leap:get()
    settings.use_charge = gui.elements.use_charge:get()
    settings.use_advance = gui.elements.use_advance:get()
    settings.use_falling_star = gui.elements.use_falling_star:get()
    settings.use_aoj = gui.elements.use_aoj:get()
    settings.log_level = gui.elements.log_level:get()
    settings.nav_viz   = gui.elements.nav_viz:get()
end

return settings