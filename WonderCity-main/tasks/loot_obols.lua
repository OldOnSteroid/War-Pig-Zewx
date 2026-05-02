local plugin_label = 'wonder_city' -- change to your plugin name

local settings = require 'core.settings'
local utils = require "core.utils"

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to obols'
}
local task = {
    name = 'loot_obols', -- change to your choice of task name
    status = status_enum['IDLE']
}
local get_obols = function ()
    local enticement = utils.get_closest_enticement(true)
    local items = actors_manager:get_all_items()

    local obols = nil
    for _, item in pairs(items) do
        local item_info = item:get_item_info()
        local display_name = item_info:get_display_name()
        if display_name:match('[Oo]bol') then
            obols = item
            break
        end
    end

    if obols ~= nil and enticement ~= nil then
        local name = enticement:get_skin_name()
        local is_switch = name:match('SpiritHearth_Switch')
        if not is_switch and utils.distance(obols, enticement) <= 3 then
            return nil
        end
    end
    return obols
end
task.shouldExecute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local obols_maxed = tonumber(local_player:get_obols()) == 2500
    return settings.loot_obols and get_obols() ~= nil and not obols_maxed
end
task.Execute = function ()
    local obols = get_obols()
    if obols ~= nil then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.set_target(plugin_label, obols)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    else
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
    end
end

return task