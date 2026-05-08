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
    interact_time = nil,
    -- Debounce stamp for interact_object. Without this, when the game keeps
    -- a beacon flagged as is_interactable() after attunement is already
    -- complete (stale ally-actor state), the bot spams interact_object every
    -- 50ms — locking the player in the ignite cast and never letting the
    -- timeout fire. 1s gap between calls covers the beacon's ignite anim.
    last_interact_call = nil,
}
local INTERACT_REFIRE_COOLDOWN = 1.0

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
            task.last_interact_call = nil
            task.status = status_enum['IDLE']
        elseif utils.distance(local_player, enticement) > 3 then
            BatmobilePlugin.set_target(plugin_label, enticement)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING']
        else
            BatmobilePlugin.clear_target(plugin_label)
            -- Start the timeout clock as soon as we're in interact range,
            -- not only when is_interactable() returns false. The Grand
            -- Beacon can stay flagged interactable even after attunement is
            -- complete, in which case the previous logic (start timer in
            -- the `elseif` branch) never started a timer and the bot was
            -- locked spamming interact_object on a no-op beacon.
            if task.interact_time == nil then
                task.interact_time = get_time_since_inject()
            end
            if enticement:is_interactable() then
                settings.orb_set_clear(false)
                -- Debounce: don't refire interact_object every tick. The
                -- beacon ignite animation needs the previous call to
                -- complete or the player just stutters in cast.
                if task.last_interact_call == nil
                    or (get_time_since_inject() - task.last_interact_call) >= INTERACT_REFIRE_COOLDOWN
                then
                    interact_object(enticement)
                    task.last_interact_call = get_time_since_inject()
                end
                task.status = status_enum['INTERACTING']
            else
                settings.orb_set_clear(true)
                local remaining = task.interact_time + timeout - get_time_since_inject()
                local timer = string.format('%.2f', remaining) .. 's'
                task.status = status_enum['WAITING'] .. timer
            end
        end
    end
end

return task