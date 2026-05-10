local gui = require "gui"
local settings = {
    enabled = false,
    -- Resolved from gui.town selection in update_settings(). Defaults match
    -- gui.town_data[0] (Temis); first-frame reads before the GUI pulse runs
    -- still get a valid zone/waypoint.
    town_zone = gui.town_data[0].zone_name,
    town_waypoint = gui.town_data[0].waypoint_sno,
    salvage = true,
    path_angle = 1,
    silent_chest = true,
    helltide_chest = true,
    ore = true,
    herb = true,
    shrine = true,
    goblin = true,
    event = true,
    prioritize_traversals = false,
    kill_monsters = true,
    experimental_explorer = false,
    farm_cinder_threshold = 0,
    do_maiden = false,
    maiden_disable_cinders = 0,
    manage_orbwalker = false,
}

function settings:update_settings()
    settings.enabled = gui.elements.main_toggle:get()
    local town_idx = gui.elements.town:get()
    local town_data = gui.town_data[town_idx] or gui.town_data[0]
    settings.town_zone = town_data.zone_name
    settings.town_waypoint = town_data.waypoint_sno
    settings.salvage = gui.elements.salvage_toggle:get()
    settings.silent_chest = gui.elements.silent_chest_toggle:get()
    settings.helltide_chest = gui.elements.helltide_chest_toggle:get()
    settings.ore = gui.elements.ore_toggle:get()
    settings.herb = gui.elements.herb_toggle:get()
    settings.shrine = gui.elements.shrine_toggle:get()
    settings.goblin = gui.elements.goblin_toggle:get()
    settings.event = gui.elements.event_toggle:get()
    settings.chaos_rift = gui.elements.chaos_rift_toggle:get()
    settings.prioritize_traversals = gui.elements.prioritize_traversals_toggle:get()
    settings.kill_monsters = gui.elements.kill_monsters_toggle:get()
    settings.experimental_explorer = gui.elements.experimental_explorer_toggle:get()
    settings.farm_cinder_threshold = gui.elements.farm_cinder_threshold:get()
    settings.do_maiden = gui.elements.do_maiden_toggle:get()
    settings.maiden_disable_cinders = gui.elements.maiden_disable_cinders:get()
    settings.manage_orbwalker = gui.elements.manage_orbwalker:get()
end

-- Above this cinder count, force orbwalker clear OFF so the bot stops lingering
-- to fight for cinders we don't need and can prioritize finding/opening chests.
local CINDER_CLEAR_OFF_THRESHOLD = 150

local function cinder_gate_active()
    return get_helltide_coin_cinders() > CINDER_CLEAR_OFF_THRESHOLD
end

-- Temporary override timestamp: until this time, force_orb_clear_for() callers
-- want orbwalker clear ON regardless of the cinder gate. Used by chest combat
-- detection so monsters can't park us at >149 cinders forever.
local force_clear_until = -math.huge

local function force_active()
    return get_time_since_inject() <= force_clear_until
end

settings.orb_set_clear = function (v)
    if not settings.manage_orbwalker then return end
    if v and cinder_gate_active() and not force_active() then
        v = false
    end
    orbwalker.set_clear_toggle(v)
end

-- Tick driver: call from the main task pulse so the gate is asserted every
-- frame, regardless of which state handler is running. Previously this only
-- forced OFF above threshold, which left orbwalker stuck OFF after cinders
-- dropped back below 150 (e.g. we just opened a chest) until the next state
-- that explicitly called orb_set_clear(true). Now it's symmetric.
settings.apply_cinder_orb_gate = function ()
    if not settings.manage_orbwalker then return end
    if force_active() then
        orbwalker.set_clear_toggle(true)
    elseif cinder_gate_active() then
        orbwalker.set_clear_toggle(false)
    else
        orbwalker.set_clear_toggle(true)
    end
end

-- Force orbwalker clear ON for `seconds` regardless of the cinder gate. Used
-- when monsters are interrupting a chest channel: we'd rather burn the cinders
-- we don't need than stand there getting hit while never killing anything.
settings.force_orb_clear_for = function (seconds)
    if not settings.manage_orbwalker then return end
    force_clear_until = get_time_since_inject() + (seconds or 5)
    orbwalker.set_clear_toggle(true)
end

settings.orb_set_block = function (v)
    if settings.manage_orbwalker then
        orbwalker.set_block_movement(v)
    end
end

return settings