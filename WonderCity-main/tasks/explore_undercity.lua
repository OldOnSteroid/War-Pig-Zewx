local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
}
local task = {
    name = 'explore_undercity', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1
}
task.shouldExecute = function ()
    return utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    -- stop exploring after seeing boss
    if tracker.boss_trigger_time ~= nil then
        task.status = status_enum['IDLE']
        return
    end
    orbwalker.set_clear_toggle(true)
    BatmobilePlugin.set_priority(plugin_label, settings.batmobile_priority)
    BatmobilePlugin.resume(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['EXPLORING']
    -- BatmobilePlugin.pause(plugin_label)
    -- BatmobilePlugin.update(plugin_label)
    -- BatmobilePlugin.set_target(plugin_label, vec3:new(41.7841796875,-25.6171875,0))
    -- BatmobilePlugin.move(plugin_label)
end

return task