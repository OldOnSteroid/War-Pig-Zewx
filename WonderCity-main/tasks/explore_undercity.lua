local plugin_label = 'wonder_city' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
}
local task = {
    name = 'explore_undercity', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1
}

-- ── Objective detection logging ───────────────────────────────────────────────
-- Scans all ally actors every tick (no distance cap) and logs the first time
-- each enticement, beacon, warp pad, or portal switch enters the actor list.
-- This gives us real observed-distance data to tune the custom explorer.
local scan_seen = {}
local scan_last_run_time = nil  -- tracker.undercity_start_time at last reset

local SCAN_ACTORS = {
    { pattern = 'X1_Undercity_Enticements_SpiritBeaconSwitch', label = 'BEACON'        },
    { pattern = 'SpiritHearth_Switch',                          label = 'ENTICEMENT'    },
    { pattern = 'X1_Undercity_WarpPad',                         label = 'WARP_PAD'      },
    { pattern = 'X1_Undercity_PortalSwitch',                    label = 'PORTAL_SWITCH' },
}

local function scan_log_objectives()
    -- Reset first-seen table on each new undercity run
    if scan_last_run_time ~= tracker.undercity_start_time then
        scan_seen = {}
        scan_last_run_time = tracker.undercity_start_time
    end

    local player = get_local_player()
    if not player then return end

    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        for _, def in ipairs(SCAN_ACTORS) do
            if name:match(def.pattern) then
                local pos = actor:get_position()
                local key = name .. string.format('%.0f%.0f', pos:x(), pos:y())
                if not scan_seen[key] then
                    scan_seen[key] = true
                    local dist = utils.distance(player, actor)
                    console.print(string.format(
                        '[WonderCity:scan] FIRST_SEEN %-14s | dist=%5.1f | name=%s | pos=(%.1f, %.1f)',
                        def.label, dist, name, pos:x(), pos:y()))
                end
                break
            end
        end
    end
end

task.shouldExecute = function ()
    if settings.use_custom_explorer then return false end
    return utils.player_in_undercity()
end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end

    scan_log_objectives()

    -- stop exploring after seeing boss
    if tracker.boss_trigger_time ~= nil then
        task.status = status_enum['IDLE']
        return
    end
    if settings.skip_monsters then
        -- Orbwalker off during exploration; re-enable only for elites/champions
        -- (bosses and enticements are handled by higher-priority tasks that own
        -- their own orbwalker state, so we never reach this branch for those).
        local player_pos = get_player_position()
        local near = target_selector.get_near_target_list(player_pos, settings.check_distance)
        local has_notable = false
        for _, e in pairs(near) do
            if (e:is_elite() or e:is_champion()) and e:get_current_health() > 1 then
                has_notable = true
                break
            end
        end
        settings.orb_set_clear(has_notable)
    else
        settings.orb_set_clear(true)
    end
    BatmobilePlugin.set_priority(plugin_label, settings.batmobile_priority)
    BatmobilePlugin.resume(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['EXPLORING']
    -- BatmobilePlugin.pause(plugin_label)
    -- BatmobilePlugin.update(plugin_label)
    -- BatmobilePlugin.set_target(plugin_label, vec3:new(41.7841796875,-25.6171875,0))
    -- BatmobilePlugin.move(plugin_label)
end

return task