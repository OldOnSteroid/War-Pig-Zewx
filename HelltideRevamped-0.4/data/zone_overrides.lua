-- Zone overrides for helltides reached via external triggers (WarPigs auto-TP,
-- in-game quest buttons, etc.) where the player lands in a zone whose region
-- prefix isn't in `enums.helltide_tps` — so the standard waypoint patrol can't
-- run.  Each entry pairs the in-game world + zone name with an entry-point
-- vec3 the bot walks to before handing off to Batmobile's free-explore.
--
-- Behavior when an override is active for the current world+zone:
--   • search_helltide is suppressed → no town teleport cycling
--   • helltide task fires whenever helltide hour is active, even without buff
--   • not in helltide buff yet → walk to entry vec3 (then idle if buff still off)
--   • once buff appears → no_waypoint_region fallback → Batmobile free-explore

local overrides = {
    -- WarPigs Helltide_TorturedGifts trigger drops the player here on the
    -- Sanctuary_Eastern_Continent map.  The actual helltide farming area is
    -- ~700 units west; walk there first so the buff applies and there's
    -- something to do.
    {
        world_name = "Sanctuary_Eastern_Continent",
        zone_name  = "Skov_Celestia",
        entry      = vec3:new(-728.0, 731.0, -0.1),
    },
}

-- Zones where the helltide task should never run (bot teleports away instead).
local excluded_zones = {
    { world_name = "Sanctuary_Eastern_Continent", zone_name = "Hawe_ZakFort" },
}

local M = {}

-- Returns the override entry that matches the current world+zone, or nil.
-- Cheap (linear scan over a tiny list), called from shouldExecute on both
-- helltide and search_helltide tasks.
function M.get_current()
    local world = get_current_world()
    if not world then return nil end
    local wname = world:get_name()
    local zname = world:get_current_zone_name()
    for _, o in ipairs(overrides) do
        if o.world_name == wname and o.zone_name == zname then
            return o
        end
    end
    return nil
end

-- Returns true when the current zone is explicitly excluded from helltide farming.
function M.is_excluded_zone()
    local world = get_current_world()
    if not world then return false end
    local wname = world:get_name()
    local zname = world:get_current_zone_name()
    for _, e in ipairs(excluded_zones) do
        if e.world_name == wname and e.zone_name == zname then
            return true
        end
    end
    return false
end

return M
