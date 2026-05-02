local utils = require "core.utils"
local settings = require "core.settings"
local tracker = require "core.tracker"
local explorer = require "core.explorer"

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
