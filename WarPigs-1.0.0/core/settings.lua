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

local function get_screen_width()
    if utility and type(utility.get_screen_width) == 'function' then
        local ok, w = pcall(utility.get_screen_width)
        if ok and type(w) == 'number' then return w end
    end
    return 1920
end

settings.update_settings = function()
    settings.enabled        = gui.elements.main_toggle:get()
    settings.use_keybind    = gui.elements.use_keybind:get()
    settings.use_teleport_transition = gui.elements.use_teleport_transition:get()
    settings.run_pit_after_turnin = gui.elements.run_pit_after_turnin:get()

    -- Pick slider pair based on screen width: 8K (≥3840) vs 1920×1080.
    if get_screen_width() >= 3840 then
        settings.teleport_click_x = gui.elements.teleport_click_x_8k:get()
        settings.teleport_click_y = gui.elements.teleport_click_y_8k:get()
    else
        settings.teleport_click_x = gui.elements.teleport_click_x:get()
        settings.teleport_click_y = gui.elements.teleport_click_y:get()
    end
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
