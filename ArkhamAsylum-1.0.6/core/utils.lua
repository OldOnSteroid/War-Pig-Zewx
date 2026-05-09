local tracker = require 'core.tracker'

local utils    = {
    settings = {},
}
-- True once the pit reset timer has expired. Higher-priority movement tasks
-- (portal, cross_traversal) consult this and yield so exit_pit can run.
-- Without the yield, force_move / interact spam keeps the player moving and
-- cancels the teleport_to_waypoint channel every frame.
utils.exit_pit_forced = function ()
    if not tracker.pit_start_time then return false end
    local settings = require 'core.settings'
    if not settings.reset_timeout then return false end
    return tracker.pit_start_time + settings.reset_timeout < get_time_since_inject()
end
utils.player_in_zone = function (zname)
    return get_current_world():get_current_zone_name() == zname
end
utils.player_in_pit = function ()
    local world = get_current_world()
    if not world then return false end
    local name = world:get_name()
    return name ~= nil and name:match("^PIT_") ~= nil
end
utils.is_looting = function ()
    if LooteerPlugin then
        return LooteerPlugin.getSettings('looting')
    end
    return false
end
utils.get_glyph_upgrade_gizmo = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'Gizmo_Paragon_Glyph_Upgrade' then
            return actor
        end
    end
    return nil
end
utils.distance = function (a, b)
    if a.get_position then a = a:get_position() end
    if b.get_position then b = b:get_position() end
    local dx = math.abs(a:x() - b:x())
    local dy = math.abs(a:y() - b:y())
    return math.max(dx, dy) + (math.sqrt(2) - 1) * math.min(dx, dy)
end

return utils