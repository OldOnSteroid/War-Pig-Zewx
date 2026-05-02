local plugin_label = 'wonder_city' -- change to your plugin name
local settings = require 'core.settings'


local status_enum = {
    IDLE = 'idle',
}
local task = {
    name = 'follower', -- change to your choice of task name
    status = status_enum['IDLE']
}
task.shouldExecute = function ()
    return settings.party_enabled and
        settings.party_mode == 1 and
        not settings.follower_explore
end
task.Execute = function () end

return task