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
    -- Steroid: skip pause. Cycle-completion naturally clears
    -- external_caller; Steroid's Status task won't monopolise the loop.
    if floor_has_loot() then
        task.loot_start = get_time_since_inject()
        task.status = status_enum['LOOTING']
    else
        task.status = status_enum['IDLE']
    end
    last_completion_at = get_time_since_inject()
end

local function trigger_alfred()
    local a = get_alfred()
    if not a then return end
    if not is_steroid() then a.resume() end
    a.trigger_tasks_with_teleport(plugin_label, reset)
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

    -- Yield while Alfred is busy for any caller. trigger_tasks is the
    -- live flag (both forks); external_trigger is the queued window
    -- (AlfredTheButler-main only — nil on Steroid). status.paused is
    -- also nil on Steroid, so (not nil) is true and the gate collapses
    -- to "trigger_tasks=true" — the right answer.
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if alfred_busy then return true end

    -- need_trigger is the documented Steroid signal AND the unified
    -- AlfredTheButler-main signal. WonderCity has zone-specific gating
    -- AND a restock-stickiness escape (last cycle just finished + only
    -- sticky flags set → skip; see HelltideRevamped for the same shape).
    if status.need_trigger then
        local now = get_time_since_inject()
        local cycle_just_completed = last_completion_at
            and (now - last_completion_at) < STUCK_NEED_TRIGGER_GRACE
        local sticky_only = cycle_just_completed
            and not status.inventory_full
            and not status.need_repair
        if not sticky_only then
            local in_uc = utils.player_in_undercity()
            local in_sno_none = utils.player_in_zone('[sno none]')
            if in_uc then
                if status.inventory_full then return true end
            elseif not in_sno_none then
                return true
            end
        end
    end

    return false
end

task.Execute = function ()
    BatmobilePlugin.pause(plugin_label)
    local status = get_alfred_status()

    -- Don't overwrite another caller's in-flight cycle (WarPigs handoff).
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
        trigger_alfred()
        task.status = status_enum['WAITING']
    elseif task.status == status_enum['LOOTING'] and get_time_since_inject() > task.loot_start + task.loot_timeout then
        task.status = status_enum['IDLE']
    elseif task.status == status_enum['WAITING'] and
        not utils.player_in_zone(settings.town_zone)
    then
        teleport_with_debounce()
    end
end

if settings.enabled and get_alfred() then reset() end

return task
