local plugin_label = 'wonder_city' -- change to your plugin name

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
        -- Yield to Alfred whenever it's actively processing its queue,
        -- regardless of who triggered it. Without this, walk_kurast (and
        -- other lower-priority tasks) win priority and pull Batmobile
        -- away from the stash/salvage NPCs while Alfred is mid-cycle —
        -- Alfred only sets `need_trigger` on full-inventory/repair, but
        -- WarPigs can trigger Alfred externally for greater-affix gear
        -- with a non-full inventory. trigger_tasks is the live "queue
        -- running" flag; external_trigger is the queued-but-not-yet-
        -- picked-up window. Skip when paused (Alfred can't act paused;
        -- yielding would deadlock against our own LOOTING state).
        local alfred_busy = status.enabled and not status.paused
            and (status.trigger_tasks or status.external_trigger)
        if task.status == status_enum['WAITING'] or
            task.status == status_enum['LOOTING'] or
            alfred_busy or
            (status.enabled and status.need_trigger and
            ((not utils.player_in_undercity() and not utils.player_in_zone('[sno none]')) or
            (status.inventory_full and utils.player_in_undercity())))
        then
            return true
        end
    end
    return false
end

task.Execute = function ()
    BatmobilePlugin.pause(plugin_label)
    -- If Alfred is busy from a DIFFERENT caller (e.g. WarPigs triggered it
    -- between activities), just hold Batmobile paused — don't re-trigger,
    -- which would overwrite external_caller/callback/teleport-flag and
    -- disrupt the orchestrator's handoff. We resume on the next tick when
    -- Alfred clears its queue (shouldExecute returns false).
    local status = AlfredTheButlerPlugin and AlfredTheButlerPlugin.get_status() or {}
    if task.status == status_enum['IDLE']
        and status.enabled and not status.paused
        and (status.trigger_tasks or status.external_trigger)
        and status.external_caller ~= plugin_label
    then
        return
    end
    if task.status == status_enum['IDLE'] then
        if AlfredTheButlerPlugin then
            AlfredTheButlerPlugin.resume()
            AlfredTheButlerPlugin.trigger_tasks_with_teleport(plugin_label,reset)
        end
        task.status = status_enum['WAITING']
    elseif task.status == status_enum['LOOTING'] and get_time_since_inject() > task.loot_start + task.loot_timeout then
        task.status = status_enum['IDLE']
    elseif task.status == status_enum['WAITING'] and
        not utils.player_in_zone(settings.town_zone)
    then
        teleport_with_debounce()
    end
end

if settings.enabled and AlfredTheButlerPlugin then reset() end

return task