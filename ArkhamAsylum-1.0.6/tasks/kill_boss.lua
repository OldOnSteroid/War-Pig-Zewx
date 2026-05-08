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

-- Remembered-hunt suppression: when the player respawns far from the cached
-- boss_position (typical: died at boss, revived at pit entrance, cached pos is
-- deep on another floor), navigate_long_path keeps returning false and the
-- task pauses Batmobile with no target — `[nav] no target, selecting new
-- (prev=nil)` loops forever.  When we detect either consecutive long_path
-- failures OR no-progress on the remembered approach, we yield to lower-
-- priority tasks (portal / explore_pit / kill_monster) for a cooldown.  If
-- the boss is still alive on this floor it'll come back into find_boss()'s
-- 60-unit scan as we move; if it's gone we never re-engage.
local REMEMBERED_HUNT_FAIL_THRESHOLD     = 3      -- consecutive long_path failures
local REMEMBERED_HUNT_NO_PROGRESS_SECS   = 25     -- no improvement to dist
local REMEMBERED_HUNT_COOLDOWN_SECS      = 60     -- suppression duration after give-up
local REMEMBERED_HUNT_PROGRESS_DELTA     = 2.0    -- min meters of dist improvement to count as progress

local long_path_target              = nil
local remembered_hunt_fail_count    = 0
local remembered_hunt_best_dist     = nil
local remembered_hunt_progress_time = nil
local remembered_hunt_giveup_time   = nil

local function reset_remembered_hunt_state()
    long_path_target              = nil
    remembered_hunt_fail_count    = 0
    remembered_hunt_best_dist     = nil
    remembered_hunt_progress_time = nil
    remembered_hunt_giveup_time   = nil
end

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
            reset_remembered_hunt_state()
        end
        return false
    end
    update_boss_state()
    if tracker.boss_dead then
        reset_remembered_hunt_state()
        return false
    end
    -- Active hunt: boss visible right now.  Always wins — clear any active
    -- suppression so the post-revive re-engagement is immediate when we
    -- finally see the boss again.
    if find_boss() then
        if remembered_hunt_giveup_time ~= nil then
            console.print('[kill_boss] boss visible again — clearing remembered-hunt suppression')
        end
        reset_remembered_hunt_state()
        return true
    end
    -- Remembered hunt: we've seen one and it's still alive somewhere on this floor.
    -- This branch primarily handles death+revive ("path back to remembered boss
    -- pos without exploring") — gated behind the post-death-recovery beta flag.
    -- When disabled, kill_boss only engages while the boss is in find_boss()
    -- scan range; otherwise we yield to portal / explore_pit / kill_monster and
    -- let normal exploration walk us back into scan range.
    if not settings.death_recovery then
        reset_remembered_hunt_state()
        return false
    end
    if tracker.boss_seen and tracker.boss_position then
        -- Suppression cooldown active (post-revive unreachable cache, etc.)
        -- — yield to portal / explore_pit / kill_monster.  When the cooldown
        -- expires we'll try the remembered hunt again from a fresh position.
        if remembered_hunt_giveup_time
            and (get_time_since_inject() - remembered_hunt_giveup_time) < REMEMBERED_HUNT_COOLDOWN_SECS
        then
            return false
        end
        -- Cooldown elapsed (or never set): clear it and resume the hunt.
        if remembered_hunt_giveup_time then
            console.print('[kill_boss] remembered-hunt suppression cooldown elapsed — re-engaging')
            remembered_hunt_giveup_time   = nil
            remembered_hunt_best_dist     = nil
            remembered_hunt_progress_time = nil
            remembered_hunt_fail_count    = 0
        end
        return true
    end
    return false
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    settings.orb_set_clear(true)
    settings.orb_set_block(true)

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
            local now = get_time_since_inject()

            -- No-progress watchdog: track best-ever distance to remembered pos.
            -- After a revive at the pit entrance with cached pos on a deep
            -- floor, dist won't shrink because we can't actually path there.
            if remembered_hunt_best_dist == nil
                or dist < remembered_hunt_best_dist - REMEMBERED_HUNT_PROGRESS_DELTA
            then
                remembered_hunt_best_dist     = dist
                remembered_hunt_progress_time = now
            end
            if remembered_hunt_progress_time
                and (now - remembered_hunt_progress_time) > REMEMBERED_HUNT_NO_PROGRESS_SECS
            then
                console.print(string.format(
                    '[kill_boss] no progress toward remembered boss pos for %ds (best=%.1f cur=%.1f) — suppressing remembered hunt for %ds',
                    REMEMBERED_HUNT_NO_PROGRESS_SECS, remembered_hunt_best_dist, dist,
                    REMEMBERED_HUNT_COOLDOWN_SECS))
                remembered_hunt_giveup_time = now
                BatmobilePlugin.stop_long_path(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
                BatmobilePlugin.resume(plugin_label)
                long_path_target           = nil
                remembered_hunt_fail_count = 0
                return
            end

            if long_path_target == nil
                or utils.distance(pos, long_path_target) > 5
            then
                local started = BatmobilePlugin.navigate_long_path(plugin_label, pos)
                if started then
                    long_path_target           = copy_vec3(pos)
                    remembered_hunt_fail_count = 0
                else
                    remembered_hunt_fail_count = remembered_hunt_fail_count + 1
                    console.print(string.format(
                        '[kill_boss] long_path to remembered boss pos failed (#%d/%d)',
                        remembered_hunt_fail_count, REMEMBERED_HUNT_FAIL_THRESHOLD))
                    long_path_target = nil
                    -- Consecutive-failure suppression: the cached pos is
                    -- genuinely unreachable from here.  Yield to other tasks
                    -- so the bot can make progress.
                    if remembered_hunt_fail_count >= REMEMBERED_HUNT_FAIL_THRESHOLD then
                        console.print(string.format(
                            '[kill_boss] %d consecutive long_path failures — suppressing remembered hunt for %ds',
                            REMEMBERED_HUNT_FAIL_THRESHOLD, REMEMBERED_HUNT_COOLDOWN_SECS))
                        remembered_hunt_giveup_time = get_time_since_inject()
                        BatmobilePlugin.stop_long_path(plugin_label)
                        BatmobilePlugin.clear_target(plugin_label)
                        BatmobilePlugin.resume(plugin_label)
                        return
                    end
                    -- Below the failure threshold — don't pause+spin while
                    -- waiting for the next attempt; let the navigator move
                    -- with whatever target it had (or nothing) for this tick.
                    BatmobilePlugin.resume(plugin_label)
                    return
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
            reset_remembered_hunt_state()
            task.status = status_enum.ARRIVED_NO_BOSS
        end
    end
end

return task
