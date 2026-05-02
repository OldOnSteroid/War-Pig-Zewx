local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local ignore_list = {}
local prority_list = {
    ['X1_Undercity_Chest_Goblin'] = true,
    ['X1_Undercity_Treasure_Goblin'] = true,
}

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to enemy',
    WAITING = 'waiting for boss delay',
}
local task = {
    name = 'kill_monster', -- change to your choice of task name
    status = status_enum['IDLE'],
}
local get_closest_enemies = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    local enemies = target_selector.get_near_target_list(player_pos, 50)
    local closest_enemy, closest_enemy_dist
    local closest_elite, closest_elite_dist
    local closest_champ, closest_champ_dist
    local closest_boss, closest_boss_dist
    local closest_priority, closest_priority_dist
    for _, enemy in pairs(enemies) do
        if ignore_list[enemy:get_skin_name()] then goto continue end
        local health = enemy:get_current_health()
        local dist = utils.distance(player_pos, enemy)
        if prority_list[enemy:get_skin_name()] and
            (closest_priority_dist == nil or dist < closest_priority_dist)
        then
            closest_priority = enemy
            closest_priority_dist = dist
        end
        if enemy:is_boss() and
            (closest_boss_dist == nil or dist < closest_boss_dist)
        then
            closest_boss = enemy
            closest_boss_dist = dist
        end
        if health > 1 and dist <= settings.check_distance then
            if closest_enemy_dist == nil or dist < closest_enemy_dist then
                closest_enemy = enemy
                closest_enemy_dist = dist
            end
            if enemy:is_elite() and
                (closest_elite_dist == nil or dist < closest_elite_dist)
            then
                closest_elite = enemy
                closest_elite_dist = dist
            end
            if enemy:is_champion() and
                (closest_champ_dist == nil or dist < closest_champ_dist)
            then
                closest_champ = enemy
                closest_champ_dist = dist
            end
        end
        ::continue::
    end
    return closest_enemy, closest_elite, closest_champ, closest_boss, closest_priority
end

local bosses = {
    ['S11_Andariel_Boss_KUC'] = 'S11_Andariel_Boss_KUC',
    ['X1_Undercity_Ghost_Caster_Miniboss'] = 'X1_Undercity_Ghost_Caster_Miniboss',
    ['X1_Undercity_Lacuni_Boss'] = 'X1_Undercity_Lacuni_Boss',
    ['X1_Undercity_Snake_Brute_Miniboss'] = 'X1_Undercity_Snake_Brute_Miniboss',
}

task.shouldExecute = function ()
    local _, _, _, boss, priority = get_closest_enemies()
    local target = boss or priority
    return target ~= nil and
        utils.player_in_undercity
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local _, _, _, boss, priority = get_closest_enemies()
    local target = boss or priority

    if target and target:is_boss() and
        bosses[target:get_skin_name()] ~= nil and
        tracker.boss_trigger_time == nil
    then
        tracker.boss_trigger_time = get_time_since_inject()
    end

    if tracker.boss_trigger_time ~= nil and
        tracker.boss_trigger_time + settings.boss_delay > get_time_since_inject()
    then
        orbwalker.set_clear_toggle(false)
        task.status = status_enum['WAITING']
        return
    end
    orbwalker.set_clear_toggle(true)

    if target and utils.distance(local_player, target) > 1 then
        BatmobilePlugin.set_target(plugin_label, target)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    else
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
    end
end

return task