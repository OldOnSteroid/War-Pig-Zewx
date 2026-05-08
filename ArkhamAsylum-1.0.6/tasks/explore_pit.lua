local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
    RESETING = 'reseting explorer',
    INTERACTING = 'interacting with portal',
    WALKING = 'walking to portal'
}
local task = {
    name = 'explore_pit', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1
}

-- After the boss dies the bot must hold near the glyphstone anchor (boss death
-- position, snapped onto the gizmo when it spawns). ANCHOR_RADIUS is the
-- "we're close enough — sit still" threshold; past it we long-path back.
local ANCHOR_RADIUS = 6
local _anchor_long_path_target = nil  -- vec3 we last issued a long_path to
local _anchor_path_issue_time = -math.huge
local ANCHOR_PATH_RETRY_INTERVAL = 2  -- seconds between repath attempts

-- Progress orb targeting
local _orb_long_path_target = nil
local _orb_path_issue_time = -math.huge
local ORB_PATH_RETRY_INTERVAL = 2
local ORB_ARRIVAL_DIST = 5

local function find_nearest_progress_orb(player_pos)
    local actors = actors_manager:get_all_actors()
    local nearest, nearest_dist = nil, math.huge
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == 'TWR_ProgressOrb' then
            local pos = actor:get_position()
            local dist = player_pos:dist_to(pos)
            if dist < nearest_dist then
                nearest = actor
                nearest_dist = dist
            end
        end
    end
    return nearest, nearest_dist
end

-- Speed mode: charge-through state
local speed_target = nil              -- vec3 through-point we're heading toward
local speed_reject_time = -math.huge  -- timestamp of last rejection
local speed_stuck_pos = nil           -- last known position for stuck detection
local speed_stuck_time = 0            -- when we last moved
local speed_charge_best_dist = math.huge  -- best (closest) distance achieved while charging
local speed_charge_progress_time = -1     -- last time best_dist improved
local SPEED_MIN_ENEMIES = 3           -- minimum pack size to trigger a charge
local SPEED_SCAN_RANGE = 40           -- how far to scan for enemies
local SPEED_THROUGH_DIST = 15         -- how far past the centroid to target
local SPEED_MIN_CENTROID_DIST = 8     -- ignore packs that are already on top of us
local SPEED_ARRIVAL_DIST = 5          -- how close before we consider through-point reached
local SPEED_REJECT_COOLDOWN = 5       -- seconds to wait before retrying pack targeting after rejection
local SPEED_CHARGE_NO_PROGRESS = 4    -- abandon through-point after this many seconds without getting closer

local function find_pack_through_point(player_pos)
    local enemies = target_selector.get_near_target_list(player_pos, SPEED_SCAN_RANGE)
    local positions = {}
    for _, enemy in pairs(enemies) do
        local epos = enemy:get_position()
        if math.abs(player_pos:z() - epos:z()) <= 5 then
            positions[#positions + 1] = epos
        end
    end

    if #positions < SPEED_MIN_ENEMIES then
        return nil, 0
    end

    -- Compute centroid of the pack
    local cx, cy, cz = 0, 0, 0
    for _, pos in ipairs(positions) do
        cx = cx + pos:x()
        cy = cy + pos:y()
        cz = cz + pos:z()
    end
    cx = cx / #positions
    cy = cy / #positions
    cz = cz / #positions

    local dx = cx - player_pos:x()
    local dy = cy - player_pos:y()
    local len = math.sqrt(dx * dx + dy * dy)

    if len < SPEED_MIN_CENTROID_DIST then
        return nil, #positions -- pack is on top of us, just keep moving
    end

    -- Through-point: extend past the centroid in the same direction
    local nx, ny = dx / len, dy / len
    local tx = cx + nx * SPEED_THROUGH_DIST
    local ty = cy + ny * SPEED_THROUGH_DIST
    return vec3:new(tx, ty, cz), #positions
end

task.shouldExecute = function ()
    return utils.player_in_pit()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    settings.orb_set_clear(true)
    settings.orb_set_block(true)

    -- Boss is alive / mid-fight: kill_boss owns movement. Defense in depth —
    -- kill_boss is higher priority so we shouldn't reach here, but if it does
    -- yield (e.g. transient state) don't explore away.
    if tracker.boss_seen and not tracker.boss_dead then
        BatmobilePlugin.pause(plugin_label)
        task.status = 'boss active — yielding'
        return
    end

    -- Boss dead: hold near the anchor (boss death pos, or the glyphstone once
    -- it spawns). This replaces the old fixed-duration freeze so the bot can't
    -- wander off chasing trash if the glyphstone takes a while to appear, and
    -- always returns if it gets pulled away.
    if tracker.boss_dead then
        local glyph = utils.get_glyph_upgrade_gizmo()
        if glyph then
            -- Snap anchor onto the gizmo (precise) and stop here — exit_pit
            -- (or upgrade_glyph) will take over via higher priority.
            local gp = glyph:get_position()
            tracker.glyph_anchor_pos = vec3:new(gp:x(), gp:y(), gp:z())
            BatmobilePlugin.pause(plugin_label)
            _anchor_long_path_target = nil
            task.status = 'holding at glyphstone'
            return
        end
        if tracker.glyph_anchor_pos then
            local anchor = tracker.glyph_anchor_pos
            local dist = utils.distance(local_player, anchor)
            if dist > ANCHOR_RADIUS then
                -- Pull back to the anchor; don't explore, don't chase trash.
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.update(plugin_label)
                local now = get_time_since_inject()
                local need_repath = false
                if _anchor_long_path_target == nil then
                    need_repath = (now - _anchor_path_issue_time) > ANCHOR_PATH_RETRY_INTERVAL
                elseif utils.distance(anchor, _anchor_long_path_target) > 3 then
                    need_repath = true
                elseif not BatmobilePlugin.is_long_path_navigating()
                    and (now - _anchor_path_issue_time) > ANCHOR_PATH_RETRY_INTERVAL
                then
                    need_repath = true
                end
                if need_repath then
                    local started = BatmobilePlugin.navigate_long_path(plugin_label, anchor)
                    if started then
                        _anchor_long_path_target = vec3:new(anchor:x(), anchor:y(), anchor:z())
                        _anchor_path_issue_time = now
                    else
                        _anchor_long_path_target = nil
                        _anchor_path_issue_time = now
                        console.print('[explore_pit] long_path back to glyph anchor failed — retrying soon')
                    end
                end
                BatmobilePlugin.move(plugin_label)
                task.status = string.format('returning to glyph anchor (%.1f)', dist)
                return
            end
            -- Within anchor radius and no glyphstone yet — wait.
            BatmobilePlugin.pause(plugin_label)
            _anchor_long_path_target = nil
            task.status = 'waiting at anchor for glyphstone'
            return
        end
        -- boss_dead but no anchor recorded (shouldn't happen): just pause.
        BatmobilePlugin.pause(plugin_label)
        task.status = 'boss dead (no anchor) — pausing'
        return
    end
    _anchor_long_path_target = nil

    -- Progress orbs (Choron's Soul): move directly to them instead of exploring
    do
        local orb, orb_dist = find_nearest_progress_orb(player_pos)
        if orb then
            if orb_dist > ORB_ARRIVAL_DIST then
                local orb_pos = orb:get_position()
                BatmobilePlugin.pause(plugin_label)
                local now = get_time_since_inject()
                local need_repath = _orb_long_path_target == nil
                    or _orb_long_path_target:dist_to(orb_pos) > 3
                    or (not BatmobilePlugin.is_long_path_navigating()
                        and (now - _orb_path_issue_time) > ORB_PATH_RETRY_INTERVAL)
                if need_repath then
                    local started = BatmobilePlugin.navigate_long_path(plugin_label, orb_pos)
                    if started then
                        _orb_long_path_target = vec3:new(orb_pos:x(), orb_pos:y(), orb_pos:z())
                        _orb_path_issue_time = now
                        console.print(string.format('[explore_pit] progress orb %.1f away — navigating', orb_dist))
                    else
                        _orb_long_path_target = nil
                        _orb_path_issue_time = now
                    end
                end
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
                task.status = string.format('moving to progress orb (%.1f)', orb_dist)
                return
            end
            _orb_long_path_target = nil
        else
            _orb_long_path_target = nil
        end
    end

    if settings.speed_mode then
        local now = get_time_since_inject()

        -- Active charge: keep heading toward through-point
        if speed_target then
            local dist = player_pos:dist_to(speed_target)
            if dist < SPEED_ARRIVAL_DIST then
                console.print(string.format("[speed] reached through-point (dist=%.1f)", dist))
                speed_target = nil
                speed_charge_best_dist = math.huge
                speed_charge_progress_time = -1
                -- fall through to scan for next pack or explore
            elseif dist < speed_charge_best_dist - 1 then
                -- Made real progress (>1 unit closer): bump the no-progress timer
                speed_charge_best_dist = dist
                speed_charge_progress_time = now
            elseif speed_charge_progress_time > 0
                and now - speed_charge_progress_time > SPEED_CHARGE_NO_PROGRESS
            then
                -- Through-points sit 15 units past the pack centroid and frequently
                -- land in unwalkable terrain. Without this guard the bot stays in
                -- "charging (N)" forever because set_target keeps being accepted
                -- and the navigator's partial-path retries make tiny oscillations
                -- that never close the gap.
                console.print(string.format(
                    "[speed] charge stalled (best=%.1f cur=%.1f), abandoning through-point",
                    speed_charge_best_dist, dist))
                speed_target = nil
                speed_reject_time = now
                speed_charge_best_dist = math.huge
                speed_charge_progress_time = -1
                BatmobilePlugin.resume(plugin_label)
                -- fall through to normal exploration
            end
            if speed_target then
                local accepted = BatmobilePlugin.set_target(plugin_label, speed_target, false)
                if accepted == false then
                    console.print("[speed] through-point rejected, resuming exploration")
                    speed_target = nil
                    speed_reject_time = now
                    speed_charge_best_dist = math.huge
                    speed_charge_progress_time = -1
                    BatmobilePlugin.resume(plugin_label)
                    -- fall through to normal exploration
                else
                    BatmobilePlugin.update(plugin_label)
                    BatmobilePlugin.move(plugin_label)
                    task.status = string.format('charging (%.0f)', dist)
                    return
                end
            end
        end

        -- Scan for dense pack (only if not on cooldown from rejection)
        if now - speed_reject_time >= SPEED_REJECT_COOLDOWN then
            local through_point, count = find_pack_through_point(player_pos)
            if through_point then
                BatmobilePlugin.pause(plugin_label)
                local accepted = BatmobilePlugin.set_target(plugin_label, through_point, false)
                if accepted ~= false then
                    speed_target = through_point
                    speed_charge_best_dist = player_pos:dist_to(through_point)
                    speed_charge_progress_time = now
                    console.print(string.format("[speed] charging through %d enemies -> (%.1f, %.1f)",
                        count, through_point:x(), through_point:y()))
                    BatmobilePlugin.update(plugin_label)
                    BatmobilePlugin.move(plugin_label)
                    task.status = string.format('charging (%d enemies)', count)
                    return
                else
                    console.print("[speed] pack through-point rejected, exploring instead")
                    speed_reject_time = now
                    BatmobilePlugin.resume(plugin_label)
                    -- fall through to normal exploration
                end
            end
        end

        -- Stuck recovery: if we haven't moved in 5 seconds, clear stale nav state
        -- (traversal blacklists, failed-target zones) so the explorer can find new targets
        if speed_stuck_pos == nil or player_pos:dist_to(speed_stuck_pos) > 3 then
            speed_stuck_pos = player_pos
            speed_stuck_time = now
        elseif now - speed_stuck_time > 5 then
            console.print("[speed] stuck for 5s, clearing traversal blacklist and resetting movement")
            BatmobilePlugin.clear_traversal_blacklist(plugin_label)
            BatmobilePlugin.reset_movement(plugin_label)
            speed_stuck_pos = nil
            speed_stuck_time = now
            speed_reject_time = -math.huge -- also allow immediate pack scan
        end

        -- No pack, pack too close, or rejected: normal exploration
        BatmobilePlugin.set_priority(plugin_label, settings.batmobile_priority)
        BatmobilePlugin.resume(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.move(plugin_label)
        task.status = 'speed exploring'
        return
    end

    -- Normal mode (unchanged)
    BatmobilePlugin.set_priority(plugin_label, settings.batmobile_priority)
    BatmobilePlugin.resume(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['EXPLORING']
end

return task
