local gui = require 'gui'

local settings = {
    plugin_label    = gui.plugin_label,
    plugin_version  = gui.plugin_version,
    enabled         = false,
    use_keybind     = false,
    use_teleport_transition = false,
    run_pit_after_turnin = false,
    verbose_logs    = false,
    log_all_quests  = false,
}

settings.update_settings = function()
    settings.enabled        = gui.elements.main_toggle:get()
    settings.use_keybind    = gui.elements.use_keybind:get()
    settings.use_teleport_transition = gui.elements.use_teleport_transition:get()
    settings.run_pit_after_turnin = gui.elements.run_pit_after_turnin:get()
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
