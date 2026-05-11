local plugin_label = "helltide_revamped" -- change to your plugin name

local settings = require 'core.settings'
local tracker = require "core.tracker"
local utils = require "core.utils"
-- need use_alfred to enable
-- settings.salvage = true

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
-- Used to fork-gate behavior that differs between the two implementations:
-- Steroid's Status task monopolises task_manager.execute_tasks on
-- tracker.external_pause=true, so calling pause(plugin_label) inside our
-- reset() callback is poison there — it parks Alfred indefinitely.
-- AlfredTheButler-main exposes status.paused and treats external_pause
-- correctly, so the legacy pause-in-reset pattern still works on that fork.
local function is_steroid()
    local a = get_alfred()
    return a ~= nil and type(a.create_task) == 'function'
end

local function get_alfred_status()
    local a = get_alfred()
    if a then return a.get_status() end
    return {enabled = false}
end

-- Tracks when our last Alfred cycle finished. Used to short-circuit the
-- Steroid restock-stickiness loop: tracker.need_trigger stays true forever
-- when restock_count > 0 can't be cleared (configured restock items with
-- nothing in stash to pull). Without this, shouldExecute fires every tick
-- on need_trigger, retriggering Alfred every ~10s for no-progress cycles
-- (observed in logzewx 31/42/43/57/58 — five rapid-fire stash cycles with
-- inventory empty). Mirrors WarPigs orchestrator's alfred_idle escape.
local last_completion_at = nil
local STUCK_NEED_TRIGGER_GRACE = 30.0

local function reset()
    local a = get_alfred()
    if a and not is_steroid() then
        -- AlfredTheButler-main: park Alfred via pause(plugin_label). Its
        -- status.paused field surfaces this to other consumers (WarPigs)
        -- so they know Alfred is held, not busy.
        a.pause(plugin_label)
    end
    -- Steroid: do NOT pause. Steroid leaves Alfred idle naturally once the
    -- cycle completes (external_caller cleared, external_trigger=false).
    -- Calling pause(plugin_label) here would set tracker.external_pause=true
    -- and Steroid's tasks/status.lua:57 would then monopolise the loop —
    -- the "Paused by helltide_revamped" deadlock.
    tracker.has_salvaged = true
    tracker.needs_salvage = false
    task.status = status_enum['IDLE']
    last_completion_at = get_time_since_inject()
end

local function trigger_alfred()
    local a = get_alfred()
    if not a then return end
    if not is_steroid() then
        -- AlfredTheButler-main: resume in case a prior reset paused us.
        a.resume()
    end
    a.trigger_tasks_with_teleport(plugin_label, reset)
end

function task.shouldExecute()
    local status = get_alfred_status()
    if not status.enabled then return false end

    -- Yield while Alfred is busy under any caller (WarPigs preamble,
    -- other activity plugin transition). trigger_tasks is the live flag
    -- on both forks; external_trigger covers the queued-but-not-picked-up
    -- window on AlfredTheButler-main (nil on Steroid). On Steroid
    -- status.paused is also nil, so (not nil) is true and the gate
    -- collapses to "trigger_tasks=true" which is the right answer.
    local alfred_busy = (not status.paused)
        and (status.trigger_tasks or status.external_trigger)
    if alfred_busy then return true end

    -- Hold while we have a cycle in flight (set by Execute below).
    if task.status == status_enum['WAITING'] then return true end

    if not settings.salvage then return false end

    -- Steroid's documented integration (README §create_task) reacts to
    -- need_trigger directly. We apply two gates on top:
    --
    -- (1) Activity-scope gate: only react when actually farming
    --     (utils.is_in_helltide() — buff present). Without this, when
    --     helltide ends mid-hour (minute >=55) or the buff drops between
    --     zones, HR alfred.lua would keep firing on persistent need_trigger
    --     and bounce the player town↔portal for the 5min off-window.
    --     tracker.needs_salvage below still handles "HR transitioned to
    --     BACK_TO_TOWN explicitly" (set in helltide.lua:back_to_town), so
    --     the legitimate end-of-helltide salvage flow is unaffected.
    --     Steroid's own Status task self-triggers on tracker.need_trigger
    --     (status.lua:121) when no external script is driving — so
    --     genuine inventory_full / need_repair work isn't lost, it just
    --     stops going through our channel during the off-window.
    -- (2) Restock-stickiness escape: skip if our last cycle finished
    --     within STUCK_NEED_TRIGGER_GRACE and only restock/stash-extras
    --     flags are sticky (no inventory_full, no need_repair) — the
    --     prior cycle couldn't clear it, re-running won't either.
    if status.need_trigger and utils.is_in_helltide() then
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

    -- Legacy back_to_town signal set in helltide.lua:back_to_town. Kept
    -- so the original "transitioning to BACK_TO_TOWN → run Alfred" path
    -- still fires. With need_trigger above this is partially redundant
    -- on Steroid but harmless.
    if tracker.needs_salvage then return true end

    return false
end

function task.Execute()
    local status = get_alfred_status()

    -- Don't overwrite another caller's in-flight cycle. If Alfred is
    -- busy under a different external_caller, just hold — firing
    -- trigger_tasks would replace their external_caller/callback and
    -- break the orchestrator handoff (see feedback_alfred_yield_rule).
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
    -- Initial reset: parks Alfred on AlfredTheButler-main (via pause), or
    -- just normalises local state on Steroid.
    reset()
end

return task
