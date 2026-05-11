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

local function get_alfred()
    return AlfredTheButlerPlugin
end

-- SteroidAlfredButler exposes create_task; AlfredTheButler-main does not.
-- See HelltideRevamped/tasks/alfred.lua for the full rationale — short
-- version: Steroid's Status task monopolises the loop on external_pause,
-- so calling pause(plugin_label) in reset is poison on that fork.
local function is_steroid()
    local a = get_alfred()
    return a ~= nil and type(a.create_task) == 'function'
end

local function get_alfred_status()
    local a = get_alfred()
    if a then return a.get_status() end
    return {enabled = false}
end

local floor_has_loot = function ()
    return loot_manager.any_item_around(get_player_position(), 30, true, true)
end

local teleport_with_debounce = function ()
    if task.debounce_time + task.debounce_timeout > get_time_since_inject() then return end
    task.debounce_time = get_time_since_inject()
    teleport_to_waypoint(settings.town_waypoint)
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local reset = function ()
    local a = get_alfred()
    if a and not is_steroid() then
        a.pause(plugin_label)
    end
    -- Steroid: skip pause to avoid Status-task monopolising the loop.
    if floor_has_loot() then
        task.loot_start = get_time_since_inject()
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
    last_completion_at = get_time_since_inject()
end

local function trigger_alfred(use_teleport)
    local a = get_alfred()
    if not a then return end
    if not is_steroid() then a.resume() end
    if use_teleport then
        a.trigger_tasks_with_teleport(plugin_label, reset)
    else
        a.trigger_tasks(plugin_label, reset)
    end
end

task.shouldExecute = function ()
    local status = get_alfred_status()
    if not status.enabled then return false end

    -- Hold while we have our own cycle in flight or floor-loot to grab.
    if task.status == status_enum['WAITING']
        or task.status == status_enum['LOOTING']
    then
        return true
    end

    -- Yield while Alfred is busy under any caller (WarPigs preamble, etc.).
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if alfred_busy then return true end

    -- need_trigger covers inventory_full, repair, restock, etc. — the
    -- documented Steroid signal and also accurate on AlfredTheButler-main.
    -- Restock-stickiness escape: don't re-fire on persistent need_trigger
    -- when the last cycle already completed without progress and the only
    -- sticky flags are restock/stash-extras (see HelltideRevamped for the
    -- same shape; also mirrors WarPigs orchestrator's alfred_idle escape).
    if status.need_trigger then
        local now = get_time_since_inject()
        local cycle_just_completed = last_completion_at
            and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE
        if cycle_just_completed
            and not status.inventory_full
            and not status.need_repair
        then
            -- stuck need_trigger — skip
        else
            return true
        end
    end

    return false
end

task.Execute = function ()
    BatmobilePlugin.pause(plugin_label)
    local status = get_alfred_status()

    -- Don't overwrite another caller's in-flight cycle.
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if task.status == status_enum['IDLE']
        and alfred_busy
        and status.external_caller ~= nil
        and status.external_caller ~= plugin_label
    then
        return
    end

    if task.status == status_enum['IDLE'] then
        -- Mode selection mirrors upstream: if we're already in town, no
        -- teleport. If we have floor loot and the setting wants us to
        -- return for it, use the teleport variant (Alfred handles the
        -- round-trip). Else do a plain trigger and teleport ourselves
        -- via teleport_with_debounce so we don't double-channel.
        if utils.player_in_zone(settings.town_zone) then
            trigger_alfred(false)
        elseif not floor_has_loot() or not settings.return_for_loot then
            trigger_alfred(false)
            teleport_with_debounce()
        else
            trigger_alfred(true)
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

if settings.enabled and get_alfred() then reset() end

return task
