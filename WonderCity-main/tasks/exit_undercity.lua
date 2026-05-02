local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXIT = 'exiting undercity',
    WAITING = 'waiting'
}
local task = {
    name = 'exit_undercity', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = nil
}
local exit_with_debounce = function (delay)
    if tracker.exit_trigger_time + settings.exit_undercity_delay >= get_time_since_inject() then
        local wait_time = tracker.exit_trigger_time + settings.exit_undercity_delay - get_time_since_inject()
        task.status = status_enum['WAITING'] ..
        ' exit delay ' .. string.format("%.2f", wait_time) .. 's'
    else
        if delay and task.debounce_time ~= nil and
            task.debounce_time + settings.confirm_delay > get_time_since_inject()
        then
            task.status = status_enum['WAITING'] .. ' for confirmation'
            return
        end
        task.debounce_time = get_time_since_inject()
        task.status = status_enum['EXIT']
        console.print('reset dungeon')
        reset_all_dungeons()
    end
end

task.shouldExecute = function ()
    return not utils.is_looting() and utils.player_in_undercity() and
        (tracker.undercity_start_time + settings.reset_timeout < get_time_since_inject() or
        tracker.done or BatmobilePlugin.is_done())
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    if BatmobilePlugin.is_done() and not tracker.exit_reset then
        BatmobilePlugin.reset(plugin_label)
        tracker.exit_reset = true
        tracker.boss_trigger_time = nil
        return
    end
    if tracker.exit_trigger_time == nil then
        tracker.exit_trigger_time = get_time_since_inject()
    end
    if not settings.party_enabled then
        exit_with_debounce(false)
    elseif settings.party_mode == 0 then
        exit_with_debounce(true)
    else
        if tracker.exit_trigger_time == get_time_since_inject() and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting exit
        end
        task.status = status_enum['WAITING'] .. ' for d4 assistant'
    end
end

return task