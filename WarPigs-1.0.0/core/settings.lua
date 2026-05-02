local gui = require 'gui'

local settings = {
    plugin_label    = gui.plugin_label,
    plugin_version  = gui.plugin_version,
    enabled         = true,
    verbose_logs    = false,
    log_all_quests  = false,
}

settings.update_settings = function()
    settings.enabled        = gui.elements.main_toggle:get()
    settings.verbose_logs   = gui.elements.verbose_logs:get()
    settings.log_all_quests = gui.elements.log_all_quests:get()
end

return settings
