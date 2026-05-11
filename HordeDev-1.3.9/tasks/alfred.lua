local plugin_label = "infernal_horde" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
-- need use_alfred to enable
-- settings.use_alfred = true

local status_enum = {
    IDLE = 'idle',
    WAITING = 'waiting for alfred to complete',
}
local task = {
    name = 'alfred_running', -- change to your choice of task name
    status = status_enum['IDLE']
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

-- SteroidAlfredButler exposes create_task; AlfredTheButler-main does not.
-- See HelltideRevamped/tasks/alfred.lua for the full rationale.
local function is_steroid()
    local a = get_alfred()
    return a ~= nil and type(a.create_task) == 'function'
end

local function get_alfred_status()
    local a = get_alfred()
    if a then return a.get_status() end
    return {enabled = false}
end

local function reset()
    local a = get_alfred()
    if a and not is_steroid() then
        a.pause(plugin_label)
    end
    -- Steroid: skip pause to avoid Status-task monopolising the loop.
    tracker.has_salvaged = true
    tracker.needs_salvage = false
    task.status = status_enum['IDLE']
end

local function trigger_alfred()
    local a = get_alfred()
    if not a then return end
    if not is_steroid() then a.resume() end
    a.trigger_tasks_with_teleport(plugin_label, reset)
end

function task.shouldExecute()
    if not settings.use_alfred then return false end
    local status = get_alfred_status()
    if not status.enabled then return false end

    -- Yield while Alfred is busy under any caller.
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if alfred_busy then return true end

    -- Hold while we have our own cycle in flight.
    if task.status == status_enum['WAITING'] then return true end

    -- Horde-specific gating: don't react to need_trigger while inside BSK
    -- — exiting the horde world mid-run loses the wave. Outside BSK is
    -- fine (only fires between hordes, which is when this task's parent
    -- script wants Alfred to run anyway). tracker.needs_salvage is set
    -- explicitly by horde-exit logic and is always safe to honour.
    if tracker.needs_salvage then return true end

    return false
end

function task.Execute()
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
        trigger_alfred()
        task.status = status_enum['WAITING']
    end
end

if settings.enabled and settings.salvage and get_alfred() then
    -- do an initial reset
    reset()
end

return task
