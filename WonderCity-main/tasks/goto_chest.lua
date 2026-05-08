local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking',
    INTERACTING = 'interacting with chest',
    WAITING = 'waiting for chest'
}
local INTERACT_REFIRE_COOLDOWN = 1.0
local INTERACT_TIMEOUT = 8.0
local task = {
    name = 'goto_chest', -- change to your choice of task name
    status = status_enum['IDLE'],
    interact_time = nil,
    last_interact_call = nil,
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
    if chest == nil then return end

    if utils.distance(local_player, chest) > 2 then
        BatmobilePlugin.set_target(plugin_label, chest)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
        return
    end

    BatmobilePlugin.clear_target(plugin_label)

    -- Arm the timeout once we're in interact range so a chest stuck flagged
    -- interactable (or one we've already opened but still see in the actor
    -- list) doesn't pin us here forever.
    if task.interact_time == nil then
        task.interact_time = get_time_since_inject()
    end
    if task.interact_time + INTERACT_TIMEOUT < get_time_since_inject() then
        console.print('[WonderCity:chest] interact timeout — marking done')
        tracker.done = true
        task.interact_time = nil
        task.last_interact_call = nil
        task.status = status_enum['IDLE']
        return
    end

    if chest:is_interactable() then
        settings.orb_set_clear(false)
        if task.last_interact_call == nil
            or (get_time_since_inject() - task.last_interact_call) >= INTERACT_REFIRE_COOLDOWN
        then
            console.print('[WonderCity:chest] interact_object dist=' ..
                string.format('%.2f', utils.distance(local_player, chest)))
            interact_object(chest)
            task.last_interact_call = get_time_since_inject()
        end
        task.status = status_enum['INTERACTING']
    else
        settings.orb_set_clear(true)
        -- No longer interactable — either we opened it or it never was.
        -- If we'd already issued at least one interact, treat as done.
        if task.last_interact_call ~= nil then
            tracker.done = true
            task.interact_time = nil
            task.last_interact_call = nil
            task.status = status_enum['IDLE']
        else
            task.status = status_enum['WAITING']
        end
    end
end

return task