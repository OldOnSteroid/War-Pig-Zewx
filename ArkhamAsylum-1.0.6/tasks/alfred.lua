local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
    LOOTING = 'looting stuff on floor'
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE'],
    loot_start = get_time_since_inject(),
    loot_timeout = 3,
    debounce_time = -1,
    debounce_timeout = 3
}

local floor_has_loot = function ()
    return loot_manager.any_item_around(get_player_position(), 30, true, true)
end

local teleport_with_debounce = function ()
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    task.debounce_time = get_time_since_inject()
    teleport_to_waypoint(settings.town_waypoint)
end

local reset = function ()
    if AlfredTheButlerPlugin then
        AlfredTheButlerPlugin.pause(plugin_label)
    end
    -- add more stuff here if you need to do something after alfred is done
    if floor_has_loot() then
        task.loot_start = get_time_since_inject()
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
end

task.shouldExecute = function ()
    local status = {enabled = false}
    if AlfredTheButlerPlugin then
        status = AlfredTheButlerPlugin.get_status()
        -- add additional conditions to trigger if required
        if (status.enabled and status.need_trigger) or
            task.status == status_enum['WAITING'] or
            task.status == status_enum['LOOTING']
        then
            return true
        end
    end
    return false
end

task.Execute = function ()
    BatmobilePlugin.pause(plugin_label)
    if task.status == status_enum['IDLE'] then
        if AlfredTheButlerPlugin then
            AlfredTheButlerPlugin.resume()
            if utils.player_in_zone(settings.town_zone) then
                AlfredTheButlerPlugin.trigger_tasks(plugin_label,reset)
            elseif not floor_has_loot() or not settings.return_for_loot then
                AlfredTheButlerPlugin.trigger_tasks(plugin_label,reset)
                teleport_with_debounce()
            else
                AlfredTheButlerPlugin.trigger_tasks_with_teleport(plugin_label,reset)
            end
        end
        task.status = status_enum['WAITING']
    elseif task.status == status_enum['LOOTING'] and get_time_since_inject() > task.loot_start + task.loot_timeout then
        task.status = status_enum['IDLE']
    elseif task.status == status_enum['WAITING'] and
        not utils.player_in_zone(settings.town_zone) and
        (not floor_has_loot() or not settings.return_for_loot)
    then
        teleport_with_debounce()
    end
end

if settings.enabled and AlfredTheButlerPlugin then reset() end

return task