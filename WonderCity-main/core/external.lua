local gui = require 'gui'
local settings = require 'core.settings'
local task_manager = require 'core.task_manager'

local external = {
    get_status = function ()
        local current_task = task_manager.get_current_task()
        local msg
        if current_task.status ~= nil then
            msg = "Current Task: " .. current_task.name .. ' (' .. current_task.status .. ')'
        else
            msg = "Current Task: " .. current_task.name
        end
        return {
            name            = settings.plugin_label,
            version         = settings.plugin_version,
            enabled         = settings.enabled and settings.get_keybind_state(),
            task            = msg
        }
    end,
    enable = function ()
        gui.elements.main_toggle:set(true)
        gui.elements.keybind_toggle:set(true)
        settings.update_settings()  -- refresh settings.enabled immediately
    end,
    disable = function ()
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
        settings.update_settings()
    end,
}
return external