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
local WAYPOINT_LOOKAHEAD   = 10  -- skip 10 waypoints (~20m ahead) — normal mode
local NUDGE_LOOKAHEAD      = 3   -- ~6m — stage 1 stuck recovery
local WAYPOINT_ARRIVAL_DIST = 8  -- advance when within 8m of current target
local MICRO_ARRIVAL_DIST   = 2   -- per-waypoint micro-step arrival radius
local last_target_wi = nil       -- track which waypoint was last sent to Batmobile

-- Graded stuck recovery. Earlier the task only had a single 12s re-teleport
-- watchdog — too coarse: if Batmobile got hung up at the Library waypoint the
-- player would just stand for a full 12s before resetting. Now there are
-- three escalating stages, each cheaper than the next, before the teleport.
--
--   stage 1 "nudge"  (>= NUDGE_AFTER_S):  re-snap to nearest waypoint, force
--                                         fresh target with reduced lookahead
--                                         so BM gets a closer, simpler goal.
--   stage 2 "micro"  (>= MICRO_AFTER_S):  bypass BM, drive explorer per
--                                         waypoint at MICRO_ARRIVAL_DIST.
--                                         "Smaller exact steps" fallback.
--   stage 3 "tele"   (>= STUCK_WINDOW_S): re-teleport to Library (existing).
local STUCK_THRESHOLD_M    = 1.5
local NUDGE_AFTER_S        = 4.0
local MICRO_AFTER_S        = 8.0
local STUCK_WINDOW_S       = 12.0
local RECOVERY_COOLDOWN_S  = 20.0
local last_progress_pos    = nil
local last_progress_time   = 0
local last_recovery_time   = -999
local nudge_applied        = false
local micro_applied        = false

local function reset_progress_tracker()
    last_progress_pos  = nil
    last_progress_time = 0
    nudge_applied      = false
    micro_applied      = false
end

-- Returns recovery mode: "ok" | "nudge" | "micro" | "tele"
local function watchdog_tick(player_pos)
    if not player_pos then return "ok" end
    local now = get_time_since_inject()
    if last_progress_pos == nil then
        last_progress_pos  = player_pos
        last_progress_time = now
        nudge_applied      = false
        micro_applied      = false
        return "ok"
    end
    local dist = player_pos:dist_to(last_progress_pos)
    if dist > STUCK_THRESHOLD_M then
        last_progress_pos  = player_pos
        last_progress_time = now
        nudge_applied      = false
        micro_applied      = false
        return "ok"
    end
    local stuck_s = now - last_progress_time
    if stuck_s >= STUCK_WINDOW_S and (now - last_recovery_time) >= RECOVERY_COOLDOWN_S then
        last_recovery_time = now
        return "tele"
    end
    if stuck_s >= MICRO_AFTER_S then return "micro" end
    if stuck_s >= NUDGE_AFTER_S then return "nudge" end
    return "ok"
end

local function snap_to_nearest_waypoint(waypoints, total, player_pos)
    if not player_pos then return nil end
    local best_i, best_d = 1, math.huge
    for i, wp in ipairs(waypoints) do
        local d = player_pos:dist_to(wp)
        if d < best_d then best_d = d; best_i = i end
    end
    return math.min(best_i + 1, total), best_i, best_d
end

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
    local player_pos = get_player_position()

    -- Stuck recovery: only arms once the post-teleport cooldown has elapsed
    -- (during cooldown the player is supposed to be standing still).
    local recovery_mode = "ok"
    if tracker.teleported_from_town and
        (current_time - walking_to_horde_task.last_teleport_time) >= walking_to_horde_task.teleport_wait_time
    then
        recovery_mode = watchdog_tick(player_pos)
        if recovery_mode == "tele" then
            console.print(string.format(
                "[walking_to_horde] STAGE 3 stuck %.1fs at (%.1f,%.1f) — re-teleporting to Library and resetting state",
                current_time - last_progress_time, player_pos:x(), player_pos:y()))
            if BatmobilePlugin then
                BatmobilePlugin.clear_target(plugin_label)
                BatmobilePlugin.clear_traversal_blacklist(plugin_label)
                BatmobilePlugin.clear_giving_up(plugin_label)
                BatmobilePlugin.reset(plugin_label)
            end
            tracker.teleported_from_town = false
            last_target_wi               = nil
            reset_progress_tracker()
            return false
        end
    else
        reset_progress_tracker()
    end

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
        reset_progress_tracker()

        console.print("Teleported to Library waypoint, waiting for " .. walking_to_horde_task.teleport_wait_time .. " seconds")
    elseif current_time - walking_to_horde_task.last_teleport_time >= walking_to_horde_task.teleport_wait_time then
        local waypoints = walking_to_horde_task.waypoints
        local total = #waypoints
        local wi = walking_to_horde_task.current_waypoint_index

        -- First tick after teleport: snap to nearest waypoint so we don't walk
        -- backwards through obstacles near the Library waypoint shrine.
        if last_target_wi == nil and wi == 1 then
            local snap_wi, best_i, best_d = snap_to_nearest_waypoint(waypoints, total, player_pos)
            if snap_wi then
                wi = snap_wi
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
            reset_progress_tracker()
            console.print("Walking to Horde task completed")
            return true
        end

        -- STAGE 2 micro-step: bypass Batmobile entirely. Drive HordeDev's own
        -- explorer one waypoint at a time, ~2m arrival. This is the same path
        -- used when BatmobilePlugin isn't loaded; falling back to it gives BM
        -- a clean break to recover its trap state.
        if recovery_mode == "micro" and BatmobilePlugin then
            if not micro_applied then
                BatmobilePlugin.clear_target(plugin_label)
                BatmobilePlugin.clear_traversal_blacklist(plugin_label)
                BatmobilePlugin.clear_giving_up(plugin_label)
                BatmobilePlugin.reset(plugin_label)
                last_target_wi = nil
                micro_applied = true
                console.print(string.format("[walking_to_horde] STAGE 2 micro — bypassing Batmobile, per-waypoint explorer at wi=%d/%d", wi, total))
            end
            local current_waypoint = waypoints[wi]
            if current_waypoint then
                explorer:set_custom_target(current_waypoint)
                explorer:move_to_target()
                if utils.distance_to(current_waypoint) < MICRO_ARRIVAL_DIST then
                    walking_to_horde_task.current_waypoint_index = wi + 1
                    console.print(string.format("[WALK] micro reached wi %d, advancing", wi))
                end
            end
        elseif BatmobilePlugin then
            -- STAGE 1 nudge: re-snap to nearest waypoint and force a fresh
            -- BM target with reduced lookahead so BM gets a closer goal it
            -- can actually reach.
            if recovery_mode == "nudge" and not nudge_applied then
                local snap_wi, best_i, best_d = snap_to_nearest_waypoint(waypoints, total, player_pos)
                if snap_wi then
                    wi = snap_wi
                    walking_to_horde_task.current_waypoint_index = wi
                end
                BatmobilePlugin.clear_target(plugin_label)
                BatmobilePlugin.clear_traversal_blacklist(plugin_label)
                BatmobilePlugin.clear_giving_up(plugin_label)
                last_target_wi = nil
                nudge_applied = true
                console.print(string.format("[walking_to_horde] STAGE 1 nudge — re-snapping to wp=%s (dist=%.1f), wi=%d/%d, lookahead=%d",
                    tostring(best_i), best_d or -1, wi, total, NUDGE_LOOKAHEAD))
            end

            local lookahead = (recovery_mode == "nudge") and NUDGE_LOOKAHEAD or WAYPOINT_LOOKAHEAD
            local arrival = WAYPOINT_ARRIVAL_DIST
            local dist_to_wp = utils.distance_to(waypoints[wi])
            if dist_to_wp < arrival then
                local old_wi = wi
                wi = math.min(wi + lookahead, total)
                walking_to_horde_task.current_waypoint_index = wi
                console.print(string.format("[WALK] Arrived wi %d (dist=%.1f), advancing to %d/%d (la=%d)", old_wi, dist_to_wp, wi, total, lookahead))
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
            -- No BatmobilePlugin: original step-by-step explorer movement
            local current_waypoint = waypoints[wi]
            if current_waypoint then
                explorer:set_custom_target(current_waypoint)
                explorer:move_to_target()
                if utils.distance_to(current_waypoint) < MICRO_ARRIVAL_DIST then
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
