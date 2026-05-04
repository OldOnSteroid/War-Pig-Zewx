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
    'teleport_cerrigar',
    'd4assistant',
    -- consume_chorons_soul runs ABOVE upgrade_glyph: the soul converts unspent
    -- upgrade chances into XP, so if upgrade_glyph fired first it would burn
    -- through the chances on glyphs instead.  When the soul setting is off
    -- (default) consume_chorons_soul.shouldExecute returns false immediately
    -- and upgrade_glyph proceeds normally.  Both gate on "no soul left or
    -- already maxed out" so the chain proceeds to alfred / portal / exit_pit.
    'consume_chorons_soul',
    'upgrade_glyph',
    'alfred',
    'enter_pit',
    -- cross_traversal must run before portal: when the portal is across a
    -- climb gizmo, portal task can't pathfind to it and locks the priority
    -- chain. cross_traversal preempts when portal task signals a recent
    -- pathfind failure AND a Traversal_Gizmo is interactable nearby, so the
    -- bot uses the climb instead of staring at the cliff.
    'cross_traversal',
    -- kill_boss must run above portal/explore_pit/kill_monster: once the pit
    -- guardian spawns, nothing else should be able to pull the bot away. Also
    -- handles "remembered hunt" — pathing back to the last known boss position
    -- after death/revive without exploring.
    'kill_boss',
    -- portal must run before exit_pit: exit_pit fires on BatmobilePlugin.is_done(),
    -- which can happen on intermediate floors before the bot has descended. With portal
    -- higher priority, any visible non-back descend portal wins; on the final floor
    -- (only the blacklisted back-portal in sight) portal returns false and exit_pit fires.
    'portal',
    'exit_pit',
    'follower',
    'interact_shrine',
    'push_monsters',
    'kill_monster',
    'explore_pit',
    'idle'
}
for _, file in ipairs(task_files) do
    local task = require('tasks.' .. file)
    task_manager.register_task(task)
end

return task_manager