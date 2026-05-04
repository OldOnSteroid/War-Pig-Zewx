local utils = require "core.utils"
local settings = require "core.settings"
local tracker = require "core.tracker"
local explorer = require "core.explorer"
local enums = require "data.enums"

-- Reference the position from horde.lua
local horde_boss_room_position = vec3:new(-36.17675, -36.3222, 2.200)

-- Batmobile pause-mode movement
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

local function move_to(pos)
    if not settings.aggresive_movement and BatmobilePlugin then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.set_target(plugin_label, pos, false)
        bm_pulse(true)
    else
        explorer:set_custom_target(pos)
        explorer:move_to_target()
    end
end

local exit_started = false
-- Debounce for teleport_to_waypoint. The teleport is a multi-second channel
-- that gets CANCELLED if fired again before completion. shouldExecute keeps
-- returning true for the whole channel (still in BSK zone), so without this
-- guard Execute spams teleport every pulse and the channel never finishes.
-- 5s window covers the channel + brief settle on arrival.
local TELEPORT_DEBOUNCE_S = 5.0
local teleport_fired_time = nil

local exit_horde_task = {
    name = "Exit Horde",
    delay_start_time = nil,
    moved_to_center = false,

    shouldExecute = function()
        return utils.player_in_zone("S05_BSK_Prototype02")
            and utils.get_stash() ~= nil
            and tracker.finished_chest_looting
    end,

    Execute = function(self)

        local current_time = get_time_since_inject()

        -- On first entry, clear stale Batmobile target from horde task
        if not exit_started then
            exit_started = true
            if BatmobilePlugin then
                BatmobilePlugin.clear_target(plugin_label)
            end
        end

        if settings.exit_mode == 1 then
            -- Teleport mode: skip walking to center / 5s wait, just leave.
            -- Stop any in-flight long_path navigation BEFORE pausing.
            -- Batmobile's main_pulse re-runs navigator.unpause+update+move
            -- every frame while long_path.navigating is true, which overrides
            -- our pause and walks the player around — that movement cancels
            -- the teleport channel.
            if BatmobilePlugin then
                if BatmobilePlugin.is_long_path_navigating
                    and BatmobilePlugin.is_long_path_navigating()
                then
                    BatmobilePlugin.stop_long_path(plugin_label)
                end
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
            end
            -- Debounce so the channel can complete instead of being
            -- re-fired every 50ms. Once the player lands in the Library,
            -- shouldExecute returns false (zone changed) and we stop.
            if teleport_fired_time
                and current_time - teleport_fired_time < TELEPORT_DEBOUNCE_S
            then
                return
            end
            console.print("Teleporting out of Horde to Library.")
            teleport_to_waypoint(enums.waypoints.LIBRARY)
            teleport_fired_time = current_time
            tracker.clear_runtime_timers()
            tracker.victory_lap = false
            tracker.victory_positions = nil
            tracker.locked_door_found = false
            tracker.exit_horde_start_time = nil
            tracker.exit_horde_completion_time = current_time
            tracker.horde_opened = false
            tracker.sigil_used = false
            tracker.start_dungeon_time = nil
            tracker.boss_killed = false
            exit_started = false
            return
        end

        if utils.distance_to(horde_boss_room_position) > 2 then
            console.print("Moving to boss room position.")
            move_to(horde_boss_room_position)
            return
        else
            console.print("Reached Central Room Postion.")
        end

        if not tracker.exit_horde_start_time then
            console.print("Starting 5-second timer before exiting Horde")
            tracker.exit_horde_start_time = current_time
        end

        local elapsed_time = current_time - tracker.exit_horde_start_time
        if elapsed_time >= 5 then
            console.print("5-second timer completed. Resetting all dungeons")
            reset_all_dungeons()
            tracker.clear_runtime_timers()
            tracker.victory_lap = false
            tracker.victory_positions = nil
            tracker.locked_door_found = false
            tracker.exit_horde_start_time = nil
            tracker.exit_horde_completion_time = current_time
            tracker.horde_opened = false
            tracker.sigil_used = false
            tracker.start_dungeon_time = nil
            tracker.boss_killed = false
            exit_started = false
        else
            -- Stop Batmobile movement while waiting for timer
            if BatmobilePlugin then
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.clear_target(plugin_label)
            end
            console.print(string.format("Waiting to exit Horde. Time remaining: %.2f seconds", 5 - elapsed_time))
        end
    end
}

return exit_horde_task
