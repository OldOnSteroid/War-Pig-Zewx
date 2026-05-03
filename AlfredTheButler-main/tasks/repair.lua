local plugin_label = 'alfred_the_butler'

local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local explorerlite = require 'core.explorerlite'
local base_task = require 'tasks.base'

local task = base_task.new_task()
local status_enum = {
    IDLE = 'Idle',
    EXECUTE = 'Repairing',
    MOVING = 'Moving to blacksmith',
    INTERACTING = 'Interacting with blacksmith',
    RESETTING = 'Re-trying repair',
    FAILED = 'Failed to repair'
}

local extension = {}
function extension.get_npc()
    return utils.get_npc(utils.npc_enum['BLACKSMITH'])
end
function extension.move()
    local npc_location = utils.compute_move_target(utils.get_npc_location('BLACKSMITH'))
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, npc_location)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(npc_location)
        explorerlite:move_to_target()
    end
end
function extension.interact()
    local npc = extension.get_npc()
    if npc then interact_vendor(npc) end
end
function extension.execute()
    local local_player = get_local_player()
    if not local_player then return end
    tracker.last_task = task.name
    loot_manager.repair_all_items()
end
function extension.reset()
    local local_player = get_local_player()
    if not local_player then return end
    local new_position = vec3:new(2575.3134765625, -481.890625, 31.5029296875)
    if task.reset_state == status_enum['MOVING'] then
        new_position = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875)
    end
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, new_position)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(new_position)
        explorerlite:move_to_target()
    end
end
function extension.is_done()
    local local_player = get_local_player()
    if not local_player then return false end
    local is_done = true
    local items = local_player:get_equipped_items()
    for _, item in pairs(items) do
        if item:get_durability() < 95 then
            is_done = false
        end
    end
    return is_done
end
function extension.done()
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.repair_done = true
end
function extension.failed()
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.repair_failed = true
end
function extension.is_in_vendor_screen()
    return loot_manager:is_in_vendor_screen()
end

task.name = 'repair'
task.extension = extension
task.status_enum = status_enum

task.shouldExecute = function ()
    if tracker.trigger_tasks == false then
        task.retry = 0
    end
    if utils.is_in_town() and
        tracker.trigger_tasks and
        not tracker.repair_failed and
        not tracker.repair_done and
        (tracker.sell_done or tracker.sell_failed) and
        (tracker.gamble_done or tracker.gamble_failed or tracker.gamble_paused) and
        (tracker.salvage_done or tracker.salvage_failed)
    then
        if task.check_status(task.status_enum['FAILED']) then
            task.set_status(task.status_enum['IDLE'])
        end
        return true
    end
    return false
end

return task