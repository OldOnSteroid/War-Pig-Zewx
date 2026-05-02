local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local ignore_list = {
    ['S11_BabyBelial_Apparition'] = true
}
-- Track enemies that couldn't be pathed to (position-based, expires after timeout)
local unreachable = {}
local unreachable_timeout = 30
local nav_tracking = { pos = nil, time = 0, dist = nil }

local is_enemy_unreachable = function(enemy_pos)
    local now = get_time_since_inject()
    local px = math.floor(enemy_pos:x())
    local py = math.floor(enemy_pos:y())
    for key, t in pairs(unreachable) do
        if now - t > unreachable_timeout then
            unreachable[key] = nil
        end
    end
    local key = px .. ',' .. py
    return unreachable[key] ~= nil
end
local mark_enemy_unreachable = function(enemy_pos)
    local key = math.floor(enemy_pos:x()) .. ',' .. math.floor(enemy_pos:y())
    unreachable[key] = get_time_since_inject()
end

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to enemy',
}
-- Tracks the target position we last called navigate_long_path for.
-- Prevents re-running expensive A* every tick when the target hasn't moved.
local long_path_target = nil
local task = {
    name = 'kill_monster', -- change to your choice of task name
    status = status_enum['IDLE'],
}
local get_closest_enemies = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    -- Floor 2: aggressively hunt all monsters instead of just nearby ones
    local effective_distance = settings.check_distance
    if utils.player_in_zone("EGD_MSWK_World_02") then
        effective_distance = 50
    end
    local enemies = target_selector.get_near_target_list(player_pos, 50)
    local closest_enemy, closest_enemy_dist
    local closest_elite, closest_elite_dist
    local closest_champ, closest_champ_dist
    local closest_boss, closest_boss_dist
    for _, enemy in pairs(enemies) do
        if ignore_list[enemy:get_skin_name()] then goto continue end
        if is_enemy_unreachable(enemy:get_position()) then goto continue end
        -- Skip enemies on a different floor level (different Z) — they're only reachable
        -- via a traversal, which the pathfinder can't model. Targeting them causes pathfind
        -- failures that corrupt the unreachable cache.
        local enemy_pos = enemy:get_position()
        if math.abs(player_pos:z() - enemy_pos:z()) > 5 then goto continue end
        local health = enemy:get_current_health()
        local dist = utils.distance(player_pos, enemy)
        if enemy:is_boss() and
            (closest_boss_dist == nil or dist < closest_boss_dist)
        then
            closest_boss = enemy
            closest_boss_dist = dist
        end
        if health > 1 and dist <= effective_distance then
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
    return closest_enemy, closest_elite, closest_champ, closest_boss
end

local BOSS_KILL_FREEZE = 10 -- seconds to freeze movement after boss dies (wait for glyphstone)

task.shouldExecute = function ()
    if settings.speed_mode then return false end
    -- Glyphstone present = boss already dead. Player is invulnerable within ~8 of it,
    -- so don't peel off to chase trash and risk drifting out of range / losing the gizmo.
    -- upgrade_glyph keeps us pinned during upgrades; exit_pit takes over after.
    if utils.get_glyph_upgrade_gizmo() then return false end
    local enemy, elite, champion, boss = get_closest_enemies()
    -- Track boss presence so we can detect when it dies
    if boss then
        tracker.boss_seen = true
    elseif tracker.boss_seen and tracker.boss_kill_time == nil then
        -- Boss was alive last frame but is gone now = just died
        tracker.boss_kill_time = get_time_since_inject()
        tracker.boss_seen = false
        console.print('[kill_monster] boss killed — freezing movement for ' .. BOSS_KILL_FREEZE .. 's while glyphstone spawns')
    end
    -- Don't chase trash for N seconds after boss kill (glyphstone needs time to spawn)
    if tracker.boss_kill_time and
        (get_time_since_inject() - tracker.boss_kill_time) < BOSS_KILL_FREEZE
    then
        return false
    end
    return (enemy ~= nil or elite ~= nil or
        champion ~= nil or boss ~= nil) and
        utils.player_in_pit()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    orbwalker.set_clear_toggle(true)
    orbwalker.set_block_movement(true)

    local enemy, elite, champion, boss = get_closest_enemies()
    local target = boss or champion or elite or enemy

    if target and utils.distance(local_player, target) > 1 then
        local target_pos = target:get_position()
        local cur_dist = utils.distance(local_player, target)
        -- Track navigation progress to detect unreachable enemies
        if nav_tracking.pos == nil or utils.distance(target_pos, nav_tracking.pos) > 5 then
            -- New target area, reset tracking
            nav_tracking.pos = target_pos
            nav_tracking.time = get_time_since_inject()
            nav_tracking.dist = cur_dist
        elseif cur_dist < nav_tracking.dist - 2 then
            -- Making progress
            nav_tracking.dist = cur_dist
            nav_tracking.time = get_time_since_inject()
        elseif get_time_since_inject() - nav_tracking.time > 12 then
            -- No progress for 12 seconds, mark unreachable
            -- (longer timeout to allow traversal routing: walk to trav ~3s + delay ~2s + walk to enemy ~3s)
            mark_enemy_unreachable(target_pos)
            nav_tracking.pos = nil
            BatmobilePlugin.clear_target(plugin_label)
            task.status = status_enum['IDLE']
            return
        end
        if settings.use_long_path then
            -- Only call navigate_long_path when the target changes significantly
            if long_path_target == nil or utils.distance(target_pos, long_path_target) > 5 then
                console.print(string.format("[kill_monster] long path to target (dist=%.1f)", cur_dist))
                local started = BatmobilePlugin.navigate_long_path(plugin_label, target_pos)
                if started then
                    long_path_target = target_pos
                else
                    -- A* couldn't find a path — treat as unreachable
                    mark_enemy_unreachable(target_pos)
                    long_path_target = nil
                    nav_tracking.pos = nil
                    BatmobilePlugin.stop_long_path(plugin_label)
                    task.status = status_enum['IDLE']
                    return
                end
            end
            BatmobilePlugin.move(plugin_label)
        else
            long_path_target = nil
            local accepted = BatmobilePlugin.set_target(plugin_label, target)
            if accepted == false then
                -- Navigator rejected target (area marked unreachable by pathfinder)
                mark_enemy_unreachable(target_pos)
                nav_tracking.pos = nil
                BatmobilePlugin.clear_target(plugin_label)
                task.status = status_enum['IDLE']
                return
            end
            BatmobilePlugin.move(plugin_label)
        end
        task.status = status_enum['WALKING']
    else
        nav_tracking.pos = nil
        long_path_target = nil
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
    end
end

return task