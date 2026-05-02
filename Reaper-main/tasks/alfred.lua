-- ============================================================
--  Reaper - tasks/alfred.lua
--  Yields to Alfred butler plugin when he needs to work.
--  Matches the reference implementation from BossTosser.
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

local function reset()
    if AlfredTheButlerPlugin then
        AlfredTheButlerPlugin.pause(plugin_label)
    elseif PLUGIN_alfred_the_butler then
        PLUGIN_alfred_the_butler.pause(plugin_label)
    end
    task.status = status_enum.IDLE
end

function task.shouldExecute()
    if not settings.use_alfred then return false end

    if AlfredTheButlerPlugin then
        local st = AlfredTheButlerPlugin.get_status()
        if (st.enabled and st.need_trigger) or task.status == status_enum.WAITING then
            return true
        end
    elseif PLUGIN_alfred_the_butler then
        local st = PLUGIN_alfred_the_butler.get_status()
        if st.enabled and (
            st.inventory_full or
            st.restock_count > 0 or
            st.need_repair or
            st.teleport or
            task.status == status_enum.WAITING
        ) then
            return true
        end
    end

    return false
end

function task.Execute()
    if task.status == status_enum.IDLE then
        if AlfredTheButlerPlugin then
            AlfredTheButlerPlugin.resume()
            AlfredTheButlerPlugin.trigger_tasks_with_teleport(plugin_label, reset)
        elseif PLUGIN_alfred_the_butler then
            PLUGIN_alfred_the_butler.resume()
            PLUGIN_alfred_the_butler.trigger_tasks_with_teleport(plugin_label, reset)
        end
        task.status = status_enum.WAITING
    end
end

-- Initial reset on load if Alfred is active
if settings.enabled and settings.use_alfred
    and (AlfredTheButlerPlugin or PLUGIN_alfred_the_butler)
then
    reset()
end

return task
