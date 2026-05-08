local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
    RESETING = 'reseting explorer',
    INTERACTING = 'interacting with portal',
    WALKING = 'walking to portal'
}
local task = {
    name = 'portal', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1
}
local get_portal = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        if actor:is_interactable() then
            local actor_name = actor:get_skin_name()
            if actor_name == 'X1_Undercity_PortalSwitch' then
                local dist = utils.distance(local_player, actor)
                if dist <= settings.check_distance then
                    return actor
                end
            end
        end
    end
    return nil
end
local get_portal_warp_pad = function ()
    local local_player = get_local_player()
    if not local_player then return end
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        if actor_name == 'X1_Undercity_WarpPad' then
            local dist = utils.distance(local_player, actor)
            if dist <= settings.check_distance then
                return actor
            end
        end
    end
    return nil
end

local boss_room_scan_last_run = nil
local is_in_boss_room = function ()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == 'Healing_Well_Basic' then
            return true
        end
    end
    -- One-shot actor dump per undercity run so we can find the real healing well name
    if utils.player_in_undercity() and boss_room_scan_last_run ~= tracker.undercity_start_time then
        boss_room_scan_last_run = tracker.undercity_start_time
        local seen = {}
        for _, actor in pairs(actors_manager:get_all_actors()) do
            local name = actor:get_skin_name()
            if not seen[name] then
                seen[name] = true
                console.print('[WonderCity:portal] actor_scan | ' .. name)
            end
        end
    end
    return false
end

task.shouldExecute = function ()
    if is_in_boss_room() then return false end
    return utils.player_in_undercity() and
        (get_portal_warp_pad() ~= nil or task.portal_found or
        task.portal_exit + 1 >= get_time_since_inject())
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    settings.orb_set_clear(true)
    local portal = get_portal()
    local warp_pad = get_portal_warp_pad()
    local target = portal
    if portal == nil then
        if task.portal_found then
            task.portal_found = false
            task.status = status_enum['RESETING']
            task.portal_exit = get_time_since_inject()
            BatmobilePlugin.reset(plugin_label)
            return
        elseif warp_pad ~= nil and utils.distance(local_player, warp_pad) > 2 then
            target = warp_pad
        end
    elseif utils.distance(local_player, portal) < 2 then
        task.portal_found = true
        interact_object(portal)
        task.status = status_enum['INTERACTING']
        -- contact magoogle tool to ask follower to teleport?
        return
    end
    if target ~= nil then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.set_target(plugin_label, target)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    end
end

return task