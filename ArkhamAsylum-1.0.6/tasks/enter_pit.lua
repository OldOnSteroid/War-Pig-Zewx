local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local pit_levels = require 'data.pitlevels'

local status_enum = {
    IDLE = 'idle',
    WALKING = 'walking to ',
    OPENING = 'opening pit ',
    ENTERING = 'entering pit ',
    WAITING = 'waiting '
}
local task = {
    name = 'enter_pit', -- change to your choice of task name
    status = status_enum['IDLE'],
    debounce_time = -1
}
local get_portal_activator = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        if actor:is_interactable() then
            local actor_name = actor:get_skin_name()
            if actor_name == 'TWN_Kehj_IronWolves_PitKey_Crafter' then
                return actor
            end
        end
    end
    return settings.town_pit_tower_pos
end
local get_portal = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        if actor:is_interactable() then
            local actor_name = actor:get_skin_name()
            if actor_name == 'EGD_MSWK_World_Portal_01' then
                return actor
            end
        end
    end
    return nil
end

local open_portal = function (delay)
    task.status = status_enum['OPENING'] .. tostring(settings.pit_level)
    local portal_activator = get_portal_activator()
    if portal_activator.get_position == nil then return end
    if not loot_manager:is_in_vendor_screen() then
        interact_object(portal_activator)
    elseif delay and task.debounce_time + settings.confirm_delay > get_time_since_inject() then
        task.status = status_enum['WAITING'] .. 'for confirmation'
        return
    else
        task.debounce_time = get_time_since_inject()
        local pit_address = pit_levels[settings.pit_level]
        utility.open_pit_portal(pit_address)
    end
end
local enter_portal = function (portal)
    interact_object(portal)
    BatmobilePlugin.reset(plugin_label)
    tracker.reset_pit_state()
    task.status = status_enum['ENTERING'] .. tostring(settings.pit_level)
end
-- Close-range threshold (matches portal.lua). The pit obelisk sits on
-- non-walkable terrain, so A* returns limit_partial; the partial-path
-- watchdog later clears the custom target and the explorer drags us back
-- to a frontier 17 units away — cue ping-pong: walk to obelisk → "no
-- target, selecting new" → walk to frontier → enter_pit re-fires → loop.
-- Below this distance, drive movement with pathfinder.force_move_raw,
-- which is a direct move command Batmobile won't second-guess.
local FORCE_MOVE_RANGE = 7

local walk_to_activator = function (activator)
    -- activator may be a live actor (interactable, get_position()) or the
    -- vec3 fallback (settings.town_pit_tower_pos). Resolve to a vec3.
    local target_pos = activator
    if activator and activator.get_position then
        target_pos = activator:get_position()
    end
    local local_player = get_local_player()
    local player_pos = local_player and local_player:get_position()
    local dist = (player_pos and target_pos)
        and utils.distance(player_pos, target_pos)
        or math.huge
    if dist <= FORCE_MOVE_RANGE then
        -- Hold position via direct move + clear any stale Batmobile target so
        -- the navigator's "no target or reached" branch is a no-op next tick
        -- (it returns early when paused with target=nil).
        BatmobilePlugin.clear_target(plugin_label)
        pathfinder.force_move_raw(target_pos)
    else
        BatmobilePlugin.set_target(plugin_label, activator)
        BatmobilePlugin.move(plugin_label)
    end
    task.status = status_enum['WALKING'] .. 'portal activator'
end
task.shouldExecute = function ()
    local should_execute =  utils.player_in_zone(settings.town_zone)
    return should_execute
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)

    local player_pos = local_player:get_position()
    local portal_activator = get_portal_activator()
    local portal = get_portal()

    if portal ~= nil then
        if utils.distance(player_pos, portal) > 2 then
            BatmobilePlugin.set_target(plugin_label, portal)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING'] .. 'portal'
        else
            enter_portal(portal)
        end
    elseif utils.distance(player_pos, portal_activator) > 2 then
        walk_to_activator(portal_activator)
    elseif not settings.party_enabled then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(false)
    elseif settings.party_mode == 0 then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(true)
    else
        BatmobilePlugin.clear_target(plugin_label)
        if task.status ~= status_enum['WAITING'] .. 'for portal' and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting portal
        end
        task.status = status_enum['WAITING'] .. 'for portal'
    end
end

return task