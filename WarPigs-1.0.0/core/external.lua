local gui      = require 'gui'
local settings = require 'core.settings'

local external = {
    enable  = function() gui.elements.main_toggle:set(true) end,
    disable = function() gui.elements.main_toggle:set(false) end,
    status  = function()
        return {
            name    = settings.plugin_label,
            version = settings.plugin_version,
            enabled = settings.enabled,
        }
    end,
}

return external
