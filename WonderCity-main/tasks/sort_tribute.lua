local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require 'core.utils'
local settings = require 'core.settings'
local path = require 'data.path'

local status_enum = {
    IDLE = 'idle',
    INTERACTING = 'interacting to stash',
    WALKING = 'walking to stash',
    SORTING = 'sorting dungeon keys',
    FAILED = 'no selected tributes'
}
local task = {
    name = 'sort_tribute', -- change to your choice of task name
    status = status_enum['IDLE'],
    stash_item_count = -1
}
local is_correct_tribute = function ()
    local local_player = get_local_player()
    if not local_player then return false end
    local key_items = local_player:get_dungeon_key_items()
    local item = key_items[1]
    local item_id = item:get_sno_id()
    local is_first = local_player:get_item_slot_index(item, 4) == 0
    local is_correct_item = item_id == settings.tribute_1 or
        item_id == settings.tribute_2 or item_id == settings.tribute_3
    return is_first and is_correct_item
end
local get_stash = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        if actor:is_interactable() then
            local actor_name = actor:get_skin_name()
            if actor_name == 'Stash' then
                return actor
            end
        end
    end
    return nil
end
local is_in_vendor_screen = function ()
    local is_in_vendor_screen = false
    local stash_count = #get_local_player():get_stash_items()
    if stash_count > 0 and task.stash_item_count == stash_count then
        is_in_vendor_screen = true
    end
    task.stash_item_count = stash_count
    return is_in_vendor_screen
end
local walk_to_stash = function (stash)
    BatmobilePlugin.set_target(plugin_label, stash)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING']
end
local sort_tribute = function (local_player)
    task.status = status_enum['SORTING']
    local key_items = local_player:get_dungeon_key_items()
    local item = key_items[1]
    local item_id = item:get_sno_id()
    local is_first = local_player:get_item_slot_index(item, 4) == 0
    local is_correct_item = item_id == settings.tribute_1 or
        item_id == settings.tribute_2 or item_id == settings.tribute_3
    if is_first and not is_correct_item then
        loot_manager.move_item_to_stash(item)
    elseif not is_first then
        local items = local_player:get_stash_items()
        local secondary, tertiary
        for _,item in pairs(items) do
            item_id = item:get_sno_id()
            if item_id == settings.tribute_1 then
                loot_manager.move_item_from_stash(item)
                return
            elseif item_id == settings.tribute_2 and secondary == nil then
                secondary = item
            elseif item_id == settings.tribute_3 and tertiary == nil then
                tertiary = item
            end
        end
        if secondary ~= nil then
            loot_manager.move_item_from_stash(secondary)
            return
        elseif tertiary ~= nil then
            loot_manager.move_item_from_stash(tertiary)
            return
        end
    end
    -- move back to stash so that it can be move to first slot, if none in stash
    local secondary, tertiary
    for _, item in ipairs(key_items) do
        item_id = item:get_sno_id()
        if item_id == settings.tribute_1 then
            loot_manager.move_item_to_stash(item)
            return
        elseif item_id == settings.tribute_2 and secondary == nil then
            secondary = item
        elseif item_id == settings.tribute_3 and tertiary == nil then
            tertiary = item
        end
    end
    if secondary ~= nil then
        loot_manager.move_item_to_stash(secondary)
        return
    elseif tertiary ~= nil then
        loot_manager.move_item_to_stash(tertiary)
        return
    end
    task.status = status_enum['FAILED']
end
task.shouldExecute = function ()
    local local_player = get_local_player()
    if not local_player then return false end
    local player_pos = local_player:get_position()
    return utils.player_in_zone('Naha_Kurast') and
        player_pos:x() ~= 0 and player_pos:y() ~= 0 and
        utils.distance(player_pos, path[#path-1]) < 5 and
        not is_correct_tribute() and get_stash() ~= nil and
        settings.reorder_tribute
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)

    local player_pos = local_player:get_position()
    local stash = get_stash()
    if utils.distance(player_pos, stash) > 2 then
        walk_to_stash(stash)
    elseif not is_in_vendor_screen() then
        task.status = status_enum['INTERACTING']
        interact_object(stash)
    else
        sort_tribute(local_player)
    end
end

return task