local utils = require "core.utils"
local enums = require "data.enums"
local explorer = require "core.explorer"
local tracker = require "core.tracker"

-- Batmobile pause-mode movement along the known waypoint path
local plugin_label = "infernal_horde"
local bm_pulse_time = -math.huge
local BM_PULSE_INTERVAL = 0.1

local function bm_pulse(force)
    if not BatmobilePlugin then return end
    local now = get_time_since_inject()
    if not force and (now - bm_pulse_time) < BM_PULSE_INTERVAL then return end
    bm_pulse_time = now
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
end

local function bm_move_to(pos)
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.set_target(plugin_label, pos, false)
    bm_pulse(true)
end

local function move_to(pos)
    if BatmobilePlugin then
        bm_move_to(pos)
    else
        explorer:set_custom_target(pos)
        explorer:move_to_target()
    end
end

-- Batmobile waypoint tuning: waypoints are ~2m apart, so skip ahead to give
-- Batmobile a real distance target instead of micro-stepping one node at a time.
local WAYPOINT_LOOKAHEAD   = 10  -- skip 10 waypoints (~20m ahead)
local WAYPOINT_ARRIVAL_DIST = 8  -- advance when within 8m of current target
local last_target_wi = nil       -- track which waypoint was last sent to Batmobile

local walking_to_horde_task = {
    name = "Walking to Horde",
    last_teleport_time = 0,
    teleport_wait_time = 10, -- Wait time in seconds
    current_waypoint_index = 1,
    waypoints = require "data.library",
    arrived_destination = false
}

local function near_horde_gate()
    local gate = utils.get_horde_gate()
    if gate then
        if utils.distance_to(gate) < 10 then
            return true
        else
            return false
        end
    else
        return false
    end
end

local function is_loading_or_limbo()
    local current_world = world.get_current_world()
    if not current_world then
        return true
    end
    local world_name = current_world:get_name()
    return world_name:find("Limbo") ~= nil or world_name:find("Loading") ~= nil
end

-- Task should execute function (without self)
function walking_to_horde_task.shouldExecute()
    return not is_loading_or_limbo() and not (utils.player_in_zone("Kehj_Caldeum") or utils.player_in_zone("S05_BSK_Prototype02")) or
        (utils.player_in_zone("Kehj_Caldeum") and not near_horde_gate())
end

-- Task execute function (without self)
function walking_to_horde_task.Execute()
    console.print("Executing Walking to Horde task")

    local current_time = get_time_since_inject()

    if utils.get_horde_gate() and utils.distance_to(utils.get_horde_gate()) < 25 then
        move_to(utils.get_horde_gate():get_position())
    elseif not tracker.teleported_from_town or not (utils.player_in_zone("Kehj_Caldeum") or utils.player_in_zone("S05_BSK_Prototype02")) then
        -- Teleport to the Library waypoint
        teleport_to_waypoint(enums.waypoints.LIBRARY)

        -- Set the flag to true after teleporting
        tracker.teleported_from_town = true
        walking_to_horde_task.last_teleport_time = current_time
        walking_to_horde_task.current_waypoint_index = 1
        last_target_wi = nil

        console.print("Teleported to Library waypoint, waiting for " .. walking_to_horde_task.teleport_wait_time .. " seconds")
    elseif current_time - walking_to_horde_task.last_teleport_time >= walking_to_horde_task.teleport_wait_time then
        local waypoints = walking_to_horde_task.waypoints
        local total = #waypoints
        local wi = walking_to_horde_task.current_waypoint_index

        -- First tick after teleport: snap to nearest waypoint so we don't walk
        -- backwards through obstacles near the Library waypoint shrine.
        if last_target_wi == nil and wi == 1 then
            local player_pos = get_player_position()
            if player_pos then
                local best_i = 1
                local best_d = math.huge
                for i, wp in ipairs(waypoints) do
                    local d = player_pos:dist_to(wp)
                    if d < best_d then
                        best_d = d
                        best_i = i
                    end
                end
                -- Start from the waypoint AFTER the nearest one (it's ahead on the path)
                wi = math.min(best_i + 1, total)
                walking_to_horde_task.current_waypoint_index = wi
                console.print(string.format("[WALK] Post-teleport: nearest wp=%d (dist=%.1f), starting from %d/%d", best_i, best_d, wi, total))
            end
        end

        if wi > total then
            -- All waypoints have been reached
            tracker.teleported_from_town = false
            walking_to_horde_task.current_waypoint_index = 1
            walking_to_horde_task.arrived_destination = true
            last_target_wi = nil
            console.print("Walking to Horde task completed")
            return true
        end

        if BatmobilePlugin then
            -- Batmobile: use lookahead so it gets a real ~20m target
            local arrival = WAYPOINT_ARRIVAL_DIST
            local dist_to_wp = utils.distance_to(waypoints[wi])
            if dist_to_wp < arrival then
                local old_wi = wi
                wi = math.min(wi + WAYPOINT_LOOKAHEAD, total)
                walking_to_horde_task.current_waypoint_index = wi
                console.print(string.format("[WALK] Arrived wi %d (dist=%.1f), advancing to %d/%d", old_wi, dist_to_wp, wi, total))
            end

            -- Only send target to Batmobile when waypoint index changes
            if wi ~= last_target_wi then
                last_target_wi = wi
                bm_move_to(waypoints[wi])
                console.print(string.format("[WALK] Batmobile target wi=%d/%d dist=%.1f", wi, total, utils.distance_to(waypoints[wi])))
            else
                bm_pulse()
            end
        else
            -- Fallback: original step-by-step explorer movement
            local current_waypoint = waypoints[wi]
            if current_waypoint then
                explorer:set_custom_target(current_waypoint)
                explorer:move_to_target()
                if utils.distance_to(current_waypoint) < 2 then
                    walking_to_horde_task.current_waypoint_index = wi + 1
                    console.print("Reached waypoint " .. wi .. ", moving to next")
                end
            end
        end
    else
        console.print("Waiting for teleport cooldown... " .. string.format("%.2f", walking_to_horde_task.teleport_wait_time - (current_time - walking_to_horde_task.last_teleport_time)) .. " seconds left")
    end

    return false
end

return walking_to_horde_task
