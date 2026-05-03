local plugin_label = 'wonder_city' -- change to your plugin name

local utils    = require 'core.utils'
local settings = require 'core.settings'
local path     = require 'data.path'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to spirit brazier'
}
local task = {
    name = 'walk_kurast', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = -1,
    debounce_timeout = 3,
    last_long_path_attempt = -999,
}

local LONG_PATH_RETRY    = 2.0  -- seconds between navigate_long_path retries on failure
local LONG_PATH_ARRIVED  = 5.0  -- meters from target to consider arrived

-- Stuck watchdog: if the player hasn't moved meaningfully for STUCK_WINDOW_S
-- while this task is the active executor, re-teleport to the town waypoint
-- to recover. Covers two failure modes seen in the wild:
--   1) Temis long-path: navigator reports navigating=true but A* is not
--      progressing (or we end up >5m from target with no movement).
--   2) Kurast waypoint follow: BatmobilePlugin gets caught on geometry and
--      can't reach the next path[] waypoint.
local STUCK_THRESHOLD_M    = 1.5
local STUCK_WINDOW_S       = 8.0
local RECOVERY_COOLDOWN_S  = 15.0
task.last_pos          = nil
task.last_pos_time     = 0
task.last_recovery     = -999

local function reset_progress()
    task.last_pos      = nil
    task.last_pos_time = 0
end

-- Returns true if recovery fired (caller should bail out of the rest of
-- Execute for this tick).
local function watchdog(player_pos)
    local now = get_time_since_inject()
    if task.last_pos == nil
        or utils.distance(task.last_pos, player_pos) > STUCK_THRESHOLD_M
    then
        task.last_pos      = player_pos
        task.last_pos_time = now
        return false
    end
    if now - task.last_pos_time < STUCK_WINDOW_S then return false end
    if now - task.last_recovery < RECOVERY_COOLDOWN_S then return false end
    task.last_recovery = now
    console.print(string.format(
        '[wonder_city walk_kurast] stuck %.1fs near (%.1f,%.1f) — re-teleporting to town waypoint',
        now - task.last_pos_time, player_pos:x(), player_pos:y()))
    BatmobilePlugin.stop_long_path(plugin_label)
    BatmobilePlugin.clear_target(plugin_label)
    BatmobilePlugin.reset(plugin_label)
    teleport_to_waypoint(settings.town_waypoint)
    reset_progress()
    return true
end

-- Pick the "destination" position used to detect arrival in shouldExecute.
-- For long-path towns it's the configured target; for waypoint towns it's
-- the second-to-last waypoint (matches original behavior).
local function destination_proxy()
    if settings.town_long_path_target then
        return settings.town_long_path_target
    end
    return path[#path-1]
end

task.shouldExecute = function ()
    local local_player = get_local_player()
    if not local_player then return false end
    local player_pos = local_player:get_position()
    local brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()
    -- Yield at the same distance Execute considers "arrived" — otherwise the
    -- distance window (LONG_PATH_ARRIVED-1, LONG_PATH_ARRIVED] makes
    -- shouldExecute return true while Execute does nothing, blocking
    -- enter_undercity from taking over and walking the last few meters to
    -- the brazier.
    return utils.player_in_zone(settings.town_zone) and
        player_pos:x() ~= 0 and player_pos:y() ~= 0 and
        (portal == nil or utils.distance(player_pos, portal) > 5 ) and
        (brazier == nil or utils.distance(player_pos, destination_proxy()) > LONG_PATH_ARRIVED)
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = local_player:get_position()

    -- Temis (or any town with a long_path_target): hand navigation off to
    -- BatmobilePlugin's uncapped A* and let it drive. No recorded waypoints.
    if settings.town_long_path_target then
        local target = settings.town_long_path_target
        if utils.distance(player_pos, target) <= LONG_PATH_ARRIVED then
            BatmobilePlugin.stop_long_path(plugin_label)
            BatmobilePlugin.clear_target(plugin_label)
            task.status = status_enum['IDLE']
            reset_progress()
            return
        end
        if watchdog(player_pos) then return end
        BatmobilePlugin.resume(plugin_label)
        if not BatmobilePlugin.is_long_path_navigating() then
            local now = get_time_since_inject()
            if (now - task.last_long_path_attempt) < LONG_PATH_RETRY then return end
            task.last_long_path_attempt = now
            BatmobilePlugin.navigate_long_path(plugin_label, target)
        end
        task.status = status_enum['WALKING']
        return
    end

    -- Kurast (default): follow recorded data/path.lua waypoints sequentially.
    if watchdog(player_pos) then return end
    BatmobilePlugin.pause(plugin_label)
    local closest_distance = nil
    local closest_key = nil
    for key,point in pairs(path) do
        if closest_distance == nil or utils.distance(player_pos, point) < closest_distance then
            closest_distance = utils.distance(player_pos, point)
            closest_key = key
        end
    end
    if path[closest_key+2] ~= nil then
        BatmobilePlugin.set_target(plugin_label, path[closest_key+2])
    elseif path[closest_key+1] ~= nil then
        BatmobilePlugin.set_target(plugin_label, path[closest_key+1])
    elseif path[closest_key] ~= nil and
        utils.distance(path[closest_key], player_pos) < 30
    then
        BatmobilePlugin.set_target(plugin_label, path[closest_key])
    else
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['IDLE']
        reset_progress()
        return
    end
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['WALKING']
end

return task