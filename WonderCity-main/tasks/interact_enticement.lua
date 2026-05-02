local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to enticement',
    INTERACTING = 'interacting with enticement',
    WAITING = 'waiting '
}
local task = {
    name = 'interact_enticement', -- change to your choice of task name
    status = status_enum['IDLE'],
    interact_time = nil
}

task.shouldExecute = function ()
    return utils.get_closest_enticement() ~= nil and
        utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local enticement = utils.get_closest_enticement()
    if enticement ~= nil then
        local name = enticement:get_skin_name()
        local timeout = settings.enticement_timeout
        local is_switch = name:match('SpiritHearth_Switch')
        if not is_switch then
            timeout = settings.beacon_timeout
        end
        local timed_out = task.interact_time ~= nil and
            task.interact_time + timeout < get_time_since_inject()
        if timed_out then
            local enticement_pos = enticement:get_position()
            local enticement_str = name .. tostring(enticement_pos:x()) .. tostring(enticement_pos:y())
            tracker.enticement[enticement_str] = true
            task.interact_time = nil
            task.status = status_enum['IDLE']
        elseif utils.distance(local_player, enticement) > 3 then
            BatmobilePlugin.set_target(plugin_label, enticement)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING']
        else
            BatmobilePlugin.clear_target(plugin_label)
            if enticement:is_interactable() then
                orbwalker.set_clear_toggle(false)
                interact_object(enticement)
                task.status = status_enum['INTERACTING']
            elseif task.interact_time == nil then
                task.interact_time = get_time_since_inject()
                orbwalker.set_clear_toggle(true)
            else
                orbwalker.set_clear_toggle(true)
                local remaining = task.interact_time + timeout - get_time_since_inject()
                local timer = string.format('%.2f', remaining) .. 's'
                task.status = status_enum['WAITING'] .. timer
            end
        end
    end
end

return task