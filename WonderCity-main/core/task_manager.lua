local task_manager = {}
local tasks = {}
local current_task = { name = 'Idle', status = 'Idle' } -- Default state when no task is active

task_manager.register_task = function (task)
    table.insert(tasks, task)
end

local last_call_time = 0.0
task_manager.execute_tasks = function ()
    local current_core_time = get_time_since_inject()
    if current_core_time - last_call_time < 0.05 then
        return -- quick ej slide frames
    end
    last_call_time = current_core_time

    for _, task in ipairs(tasks) do
        if task.shouldExecute() then
            current_task = task
            task:Execute()
            break -- Execute only one task per pulse
        end
    end

    -- The if statement has been removed, and current_task is always assigned
    current_task = current_task or { name = 'Idle', status = 'Idle' }
end

task_manager.get_current_task = function ()
    return current_task
end

local task_files = {
    -- 'd4assistant',
    'alfred',
    'teleport_kurast',
    'walk_kurast',
    'enter_undercity',
    'interact_enticement',
    'loot_obols',
    'portal',
    'kill_monster',
    'goto_chest',
    'exit_undercity',
    -- 'follower',
    'explore_undercity',
    'idle'
}
for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
end

return task_manager