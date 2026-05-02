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
    orbwalker.set_clear_toggle(true)
    orbwalker.set_block_movement(true)

    -- Freeze movement after boss kill while glyphstone spawns.
    -- Still allow orbwalker to cast spells on nearby trash.
    if tracker.boss_kill_time and
        (get_time_since_inject() - tracker.boss_kill_time) < 10
    then
        BatmobilePlugin.pause(plugin_label)
        task.status = 'waiting for glyphstone'
        return
    end

    if settings.speed_mode then
        local player_pos = get_player_position()
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
