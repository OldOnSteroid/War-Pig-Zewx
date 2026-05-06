-- Minimal external surface for cross-script queries.
-- WarPug is self-gating (runs only when in Temis with no quests) so it does
-- not need enable/disable orchestration from WarPigs or other plugins.
local M = {}

function M.status()
    local settings = require 'core.settings'
    local planner  = require 'core.planner'
    return {
        name    = 'WarPug',
        version = settings.plugin_version,
        enabled = settings.enabled,
        state   = planner.get_current_state(),
    }
end

return M
