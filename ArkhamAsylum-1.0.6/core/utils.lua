local tracker = require 'core.tracker'

local utils    = {
    settings = {},
}
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