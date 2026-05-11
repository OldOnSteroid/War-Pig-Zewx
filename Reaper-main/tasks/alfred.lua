-- ============================================================
--  Reaper - tasks/alfred.lua
--  Yields to Alfred butler plugin when he needs to work.
--  Fork-aware: SteroidAlfredButler vs AlfredTheButler-main.
-- ============================================================

local plugin_label = "Reaper"
local settings     = require "core.settings"

local status_enum = {
    IDLE    = "idle",
    WAITING = "waiting for alfred to complete",
}

local task = {
    name   = "alfred_running",
    status = status_enum.IDLE,
}

local function get_alfred()
    return AlfredTheButlerPlugin or PLUGIN_alfred_the_butler
end

-- SteroidAlfredButler exposes create_task; AlfredTheButler-main does not.
-- See HelltideRevamped/tasks/alfred.lua for the full rationale — short
-- version: on Steroid, pause(plugin_label) sets external_pause which
-- monopolises its Status task and locks out sell/salvage/etc. AlfredTheButler-
-- main exposes status.paused and the legacy pattern works there.
local function is_steroid()
    local a = get_alfred()
    return a ~= nil and type(a.create_task) == "function"
end

local function get_alfred_status()
    local a = get_alfred()
    if a then return a.get_status() end
    return {enabled = false}
end

-- Tracks last cycle completion for restock-stickiness escape. See
-- HelltideRevamped/tasks/alfred.lua for the full rationale.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local function reset()
    local a = get_alfred()
    if a and not is_steroid() then
        a.pause(plugin_label)
    end
    -- Steroid: skip pause to avoid Status-task monopolising the loop.
    task.status = status_enum.IDLE
    last_completion_at = get_time_since_inject()
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
    if task.status == status_enum.WAITING then return true end

    -- need_trigger is the unified signal across both forks. Restock-
    -- stickiness escape: skip if last cycle just completed and only
    -- restock/stash-extras flags are sticky (see HelltideRevamped).
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

    -- AlfredTheButler-main-only legacy fallback path: when the upstream
    -- get_status() shape was thinner the original Reaper code reacted
    -- to individual flags directly. Keep it gated behind PLUGIN_alfred_the_butler
    -- which only exists on the legacy fork.
    if PLUGIN_alfred_the_butler then
        if status.inventory_full or
            (status.restock_count and status.restock_count > 0) or
            status.need_repair or
            status.teleport
        then
            return true
        end
    end

    return false
end

function task.Execute()
    local status = get_alfred_status()

    -- Don't overwrite another caller's in-flight cycle.
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if task.status == status_enum.IDLE
        and alfred_busy
        and status.external_caller ~= nil
        and status.external_caller ~= plugin_label
    then
        return
    end

    if task.status == status_enum.IDLE then
        trigger_alfred()
        task.status = status_enum.WAITING
    end
end

-- Initial reset on load if Alfred is active
if settings.enabled and settings.use_alfred and get_alfred() then
    reset()
end

return task
