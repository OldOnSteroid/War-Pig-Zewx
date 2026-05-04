local gui = require 'gui'

local settings = {
    plugin_label    = gui.plugin_label,
    plugin_version  = gui.plugin_version,
    enabled         = false,
    use_keybind     = false,
    use_teleport_transition = false,
    run_pit_after_turnin = false,
    teleport_click_x = 0,
    teleport_click_y = 0,
    show_click_points = false,
    verbose_logs    = false,
    log_all_quests  = false,
}

settings.update_settings = function()
    settings.enabled        = gui.elements.main_toggle:get()
    settings.use_keybind    = gui.elements.use_keybind:get()
    settings.use_teleport_transition = gui.elements.use_teleport_transition:get()
    settings.run_pit_after_turnin = gui.elements.run_pit_after_turnin:get()

    -- Keybind capture: when the user presses the bound key (default F5)
    -- while hovering an in-game target, capture the cursor's screen pixel
    -- position into the X/Y sliders. Rising-edge consumed via :get_state().
    if gui.elements.teleport_capture_keybind:get_state() == 1 then
        if utility and type(utility.get_cursor_screen_position) == 'function' then
            local cx, cy = utility.get_cursor_screen_position()
            if cx and cy then
                gui.elements.teleport_click_x:set(math.floor(cx))
                gui.elements.teleport_click_y:set(math.floor(cy))
                console.print(string.format(
                    '[WarPigs] captured teleport click target = (%d, %d)',
                    math.floor(cx), math.floor(cy)))
            end
        end
    end

    settings.teleport_click_x = gui.elements.teleport_click_x:get()
    settings.teleport_click_y = gui.elements.teleport_click_y:get()
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.verbose_logs   = gui.elements.verbose_logs:get()
    settings.log_all_quests = gui.elements.log_all_quests:get()
end

-- Mirrors HordeDev's get_keybind_state(): when the keybind feature is off,
-- always returns true. When on, returns true only while the bound key is in
-- the active state (toggled on). 0x0A is the harness "no key bound" sentinel.
settings.get_keybind_state = function()
    if not settings.use_keybind then return true end
    local kb = gui.elements.keybind_toggle
    return kb:get_key() ~= 0x0A and kb:get_state() == 1
end

return settings
