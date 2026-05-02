local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require "core.tracker"
local gui = require "gui"

local status_enum = {
    IDLE = 'idle',
}
local task = {
    name = 'd4_assitant', -- change to your choice of task name
    status = status_enum['IDLE'],
}
task.shouldExecute = function ()
    return utils.player_in_undercity() and
        tracker.done and
        tracker.boss_kill_time == nil and
        settings.party_enabled and
        settings.party_mode == 0 and
        settings.use_magoogle_tool

end
task.Execute = function ()
    tracker.boss_kill_time = get_time_since_inject()
    -- contact magoogle tool for boss killed
end

return task