local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXIT = 'exiting pit',
    WAITING = 'waiting'
}
local task = {
    name = 'exit_pit', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = nil
}
local exit_with_debounce = function (delay)
    if tracker.exit_trigger_time + settings.exit_pit_delay >= get_time_since_inject() then
        local wait_time = tracker.exit_trigger_time + settings.exit_pit_delay - get_time_since_inject()
        task.status = status_enum['WAITING'] ..
        ' exit delay ' .. string.format("%.2f", wait_time) .. 's'
    else
        -- Always debounce. teleport_to_waypoint and reset_all_dungeons each
        -- have a multi-second cast/channel that gets CANCELLED if the call
        -- fires again before the previous one completes. Without this guard,
        -- the action fires every 50ms — the channel never finishes, the
        -- player runs around (input returns between cancellations), and the
        -- bot looks like it's stuck in the pit. The original `delay` flag
        -- only enabled this check in party mode, leaving non-party users
        -- spamming the teleport. confirm_delay (default 5s) covers the
        -- channel.
        if task.debounce_time ~= nil and
            task.debounce_time + settings.confirm_delay > get_time_since_inject()
        then
            task.status = status_enum['WAITING'] .. ' for ' ..
                (settings.exit_mode == 1 and 'teleport' or 'reset') .. ' to complete'
            return
        end
        task.debounce_time  = get_time_since_inject()
        if settings.exit_mode == 1 then
            console.print('teleport out')
            teleport_to_waypoint(settings.town_waypoint)
        else
            console.print('reset dungeon')
            reset_all_dungeons()
        end
    end
end

task.shouldExecute = function ()
    if not utils.player_in_pit() then return false end
    -- Reset timer is a hard override — always exit even if looting or waiting
    -- at the anchor for a glyphstone that may never spawn.
    if tracker.pit_start_time + settings.reset_timeout < get_time_since_inject() then
        console.print(string.format('[exit_pit] reset timer expired (%.0fs) — forcing exit',
            get_time_since_inject() - tracker.pit_start_time))
        return true
    end
    return not utils.is_looting() and
        (utils.get_glyph_upgrade_gizmo() ~= nil or BatmobilePlugin.is_done())
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    -- Stop any in-flight long_path navigation BEFORE pausing. Batmobile's
    -- main_pulse re-runs navigator.unpause() + update() + move() every frame
    -- while long_path.navigating is true (see Batmobile main.lua:85), which
    -- overrides our pause and keeps the player walking toward the previous
    -- long_path target — that movement cancels the teleport channel and
    -- looks like the bot is "running around like crazy" while exiting.
    if BatmobilePlugin.is_long_path_navigating
        and BatmobilePlugin.is_long_path_navigating()
    then
        BatmobilePlugin.stop_long_path(plugin_label)
    end
    BatmobilePlugin.clear_target(plugin_label)
    BatmobilePlugin.pause(plugin_label)
    settings.orb_set_clear(true)
    if tracker.exit_trigger_time == nil then
        tracker.exit_trigger_time = get_time_since_inject()
    end
    if not settings.party_enabled then
        exit_with_debounce(false)
    elseif settings.party_mode == 0 then
        exit_with_debounce(true)
    else
        if tracker.exit_trigger_time == get_time_since_inject() and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting exit
        end
        task.status = status_enum['WAITING'] .. ' for d4 assistant'
    end
end

return task