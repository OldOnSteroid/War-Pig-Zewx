-- ============================================================
--  Reaper - core/task_manager.lua
-- ============================================================

local task_manager   = {}
local tasks          = {}
local current_task   = { name = "Idle" }
local last_call_time = 0.0

function task_manager.register_task(task)
    table.insert(tasks, task)
end

function task_manager.execute_tasks()
    local t = get_time_since_inject()
    if t - last_call_time < 0.1 then return end
    last_call_time = t

    for _, task in ipairs(tasks) do
        local ok, should = pcall(task.shouldExecute)
        if ok and should then
            current_task = task
            local ok2, err = pcall(task.Execute, task)
            if not ok2 then
                console.print("[Reaper] Task error in '" .. task.name .. "': " .. tostring(err))
            end
            return
        end
    end
    current_task = { name = "Idle" }
end

function task_manager.get_current_task()
    return current_task
end

function task_manager.reset_all()
    for _, task in ipairs(tasks) do
        if task.reset then task.reset() end
    end
    current_task = { name = "Idle" }
end

-- Priority order (first = highest)
local task_files = {
    "alfred",           -- yield to Alfred when needed
    "revive",           -- handle death before anything else
    "dungeon_reset",    -- reset dungeons every N runs (between boss zones)
    "belial_chest",     -- handle Belial chest UI before generic chest task
    "navigate_to_boss", -- teleport + walk to entrance
    "interact_altar",   -- summon boss
    "kill_monsters",    -- fight
    "open_chest",       -- open reward chest (must run before sigil_complete yields)
    "sigil_complete",   -- detect sigil run clear, return to town, count run
}

for _, f in ipairs(task_files) do
    local task = require("tasks." .. f)
    task_manager.register_task(task)
end

return task_manager
