local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking'
}
local task = {
    name = 'goto_chest', -- change to your choice of task name
    status = status_enum['IDLE'],
}
task.shouldExecute = function ()
    return utils.player_in_undercity() and
        utils.get_undercity_chest() ~= nil and
        not tracker.done

end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    local chest = utils.get_undercity_chest()
    if chest ~= nil then
        if utils.distance(local_player, chest) > 3 then
            BatmobilePlugin.set_target(plugin_label, chest)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING']
        else
            BatmobilePlugin.clear_target(plugin_label)
            task.status = status_enum['IDLE']
            tracker.done = true
        end
    end
end

return task