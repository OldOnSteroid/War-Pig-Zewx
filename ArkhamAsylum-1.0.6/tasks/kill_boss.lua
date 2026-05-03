local plugin_label = 'arkham_asylum'

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

-- Pit guardian (boss) handler. Higher priority than portal / explore_pit /
-- kill_monster so once the boss spawns nothing else can pull the bot away.
--
-- Behaviour:
--   * While the boss is visible: pause Batmobile, route to it, attack it.
--   * Player dies & respawns far from the boss: tracker.boss_position is
--     remembered so we navigate back without exploring or chasing trash.
--   * Boss disappears from the actor list while we were close = killed.
--     Mark boss_dead and snapshot glyph_anchor_pos at the death position so
--     explore_pit / kill_monster (handled in their files) can hold near it
--     until upgrade_glyph or exit_pit takes over.
--   * Glyphstone gizmo present implies the kill (e.g. teammate killed it,
--     or detection missed): mark dead, anchor at the gizmo.

local status_enum = {
    IDLE = 'idle',
    KILLING = 'killing pit guardian',
    WALKING_REMEMBERED = 'walking to remembered boss pos',
    ARRIVED_NO_BOSS = 'no boss at remembered pos — marking dead',
}

local task = {
    name = 'kill_boss',
    status = status_enum.IDLE,
}

-- Wider scan than kill_monster (50): boss is what we care about and it can be
-- visible at the edge of perception when we first arrive on the floor.
local BOSS_SCAN_RANGE = 60
-- We declare the boss dead when it disappears from the scan list AND we were
-- close enough that it can't have just walked out of range.
local DEATH_PROXIMITY = 25
-- Distance to remembered position considered "arrived" when the boss isn't
-- currently visible. Past this, we stop pathing and fall through.
local REMEMBERED_ARRIVAL = 5

local long_path_target = nil

local function copy_vec3(v)
    return vec3:new(v:x(), v:y(), v:z())
end

local function find_boss()
    local player_pos = get_player_position()
    if not player_pos then return nil end
    local enemies = target_selector and target_selector.get_near_target_list
        and target_selector.get_near_target_list(player_pos, BOSS_SCAN_RANGE)
        or nil
    if not enemies then return nil end
    local closest, closest_dist
    for _, enemy in pairs(enemies) do
        if enemy:is_boss() and enemy:get_current_health() > 1 then
            local d = utils.distance(player_pos, enemy)
            if not closest_dist or d < closest_dist then
                closest = enemy
                closest_dist = d
            end
        end
    end
    return closest
end

-- Detect transitions:
--   boss visible → remember it
--   boss vanished while we were close → declare dead, set anchor
local function update_boss_state()
    if tracker.boss_dead then return end

    -- Glyphstone presence is conclusive evidence the boss is dead.
    local glyph = utils.get_glyph_upgrade_gizmo()
    if glyph then
        tracker.boss_dead = true
        tracker.glyph_anchor_pos = copy_vec3(glyph:get_position())
        if tracker.boss_kill_time == nil then
            tracker.boss_kill_time = get_time_since_inject()
        end
        console.print('[kill_boss] glyphstone present — marking boss dead, anchor at gizmo')
        return
    end

    local boss = find_boss()
    if boss then
        tracker.boss_seen = true
        tracker.boss_position = copy_vec3(boss:get_position())
        return
    end

    -- Not visible. If we'd seen one and we're standing where it was,
    -- treat as killed.
    if tracker.boss_seen and tracker.boss_position then
        local pp = get_player_position()
        if pp and utils.distance(pp, tracker.boss_position) < DEATH_PROXIMITY then
            tracker.boss_dead = true
            tracker.boss_kill_time = get_time_since_inject()
            tracker.glyph_anchor_pos = copy_vec3(tracker.boss_position)
            console.print(string.format(
                '[kill_boss] boss vanished within %.0f of remembered pos — marking dead, anchor at boss death pos',
                DEATH_PROXIMITY))
        end
    end
end

task.shouldExecute = function ()
    if not utils.player_in_pit() then
        -- Outside pit: full reset so the next pit run starts clean.
        if tracker.boss_seen or tracker.boss_dead or tracker.boss_position then
            tracker.boss_seen = false
            tracker.boss_dead = false
            tracker.boss_position = nil
            tracker.glyph_anchor_pos = nil
            tracker.boss_kill_time = nil
            long_path_target = nil
        end
        return false
    end
    update_boss_state()
    if tracker.boss_dead then return false end
    -- Active hunt: boss visible right now.
    if find_boss() then return true end
    -- Remembered hunt: we've seen one and it's still alive somewhere on this floor.
    if tracker.boss_seen and tracker.boss_position then return true end
    return false
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    orbwalker.set_clear_toggle(true)
    orbwalker.set_block_movement(true)

    local boss = find_boss()
    if boss then
        tracker.boss_seen = true
        tracker.boss_position = copy_vec3(boss:get_position())
        local dist = utils.distance(local_player, boss)
        if dist > 1 then
            local target_pos = boss:get_position()
            if settings.use_long_path then
                if long_path_target == nil
                    or utils.distance(target_pos, long_path_target) > 5
                then
                    local started = BatmobilePlugin.navigate_long_path(plugin_label, target_pos)
                    if started then
                        long_path_target = copy_vec3(target_pos)
                    else
                        -- Pathfinder couldn't route — fall back to short-range set_target.
                        long_path_target = nil
                        BatmobilePlugin.stop_long_path(plugin_label)
                        BatmobilePlugin.set_target(plugin_label, boss)
                    end
                end
                BatmobilePlugin.move(plugin_label)
            else
                long_path_target = nil
                BatmobilePlugin.set_target(plugin_label, boss)
                BatmobilePlugin.move(plugin_label)
            end
        else
            long_path_target = nil
            BatmobilePlugin.clear_target(plugin_label)
        end
        task.status = status_enum.KILLING
        return
    end

    -- Boss not visible: walk to remembered position (covers death + revive far away).
    if tracker.boss_position then
        local pos = tracker.boss_position
        local dist = utils.distance(local_player, pos)
        if dist > REMEMBERED_ARRIVAL then
            if long_path_target == nil
                or utils.distance(pos, long_path_target) > 5
            then
                local started = BatmobilePlugin.navigate_long_path(plugin_label, pos)
                if started then
                    long_path_target = copy_vec3(pos)
                else
                    -- Can't path there — give up on remembered hunt; let the
                    -- next pulse re-evaluate. If boss truly is alive it'll
                    -- come back into scan range as we move.
                    console.print('[kill_boss] long_path to remembered boss pos failed')
                    long_path_target = nil
                end
            end
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum.WALKING_REMEMBERED
        else
            -- Arrived at the remembered spot, no boss in scan list:
            -- treat as already dead (handles silent kills).
            console.print('[kill_boss] arrived at remembered pos, no boss visible — marking dead')
            tracker.boss_dead = true
            tracker.boss_kill_time = get_time_since_inject()
            tracker.glyph_anchor_pos = copy_vec3(pos)
            BatmobilePlugin.stop_long_path(plugin_label)
            long_path_target = nil
            task.status = status_enum.ARRIVED_NO_BOSS
        end
    end
end

return task
