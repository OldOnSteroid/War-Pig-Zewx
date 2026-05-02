-- ============================================================
--  Reaper - tasks/interact_altar.lua
--
--  Finds the summoning altar inside the boss zone and
--  interacts with it to spawn the boss.
--  Keeps retrying as long as the altar is present.
--  Success = altar disappears from the actor list after an
--  interact attempt.
-- ============================================================

local utils        = require "core.utils"
local enums        = require "data.enums"
local explorerlite = require "core.explorerlite"
local tracker      = require "core.tracker"
local rotation     = require "core.boss_rotation"

local CERRIGAR_WP    = 0x76D58
local STUCK_TIMEOUT  = 60.0  -- seconds after altar_activated before declaring stuck

local plugin_label = 'reaper'

-- ---- Unstuck helpers ----
local last_pos          = nil
local last_move_time    = 0
local stuck_threshold   = 3
local last_unstuck_time = 0
local unstuck_cooldown  = 3
local unstuck_start     = 0
local unstuck_timeout   = 5

local last_interact_time = 0
local INTERACT_COOLDOWN  = 2.0  -- seconds between interact attempts

local function check_if_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_time > stuck_threshold then
            if t - last_unstuck_time >= unstuck_cooldown then
                last_unstuck_time = t
                return true
            end
        end
    else
        last_move_time = t
    end
    last_pos = pos
    return false
end

-- -------------------------------------------------------
-- shouldExecute
-- -------------------------------------------------------
local task = { name = "Interact Altar" }

local function any_chest_visible()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return false end
    for _, a in pairs(actors) do
        local ok, inter = pcall(function() return a:is_interactable() end)
        if ok and inter then
            local n = a:get_skin_name()
            if type(n) == "string" then
                if n:find("^EGB_Chest") or n:find("^Chest_Boss")
                    or n:find("^Boss_WT_Belial_") or n:find("^S12_Prop_Theme_Chest_") then
                    return true
                end
            end
        end
    end
    return false
end

function task.shouldExecute()
    if tracker.altar_activated then
        -- Deadlock recovery: altar was activated but no chest appeared after STUCK_TIMEOUT.
        if tracker.altar_activate_time > 0 then
            local elapsed = get_time_since_inject() - tracker.altar_activate_time
            if elapsed > STUCK_TIMEOUT and not any_chest_visible() then
                console.print(string.format(
                    "[Reaper] Altar activated %.0fs ago — no chest found. Resetting run.",
                    elapsed))
                last_interact_time = 0
                tracker.reset_run()
                teleport_to_waypoint(CERRIGAR_WP)
            end
        end
        return false
    end

    local boss = rotation.current()
    if not boss then return false end

    local zone = utils.get_zone()
    local in_zone
    if boss.run_type == "sigil" then
        in_zone = zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")      ~= nil
            or zone:find("Boss_WT")       ~= nil
            or zone:find("Boss_Kehj")     ~= nil
    else
        in_zone = zone:match(boss.zone_prefix) ~= nil
    end
    if not in_zone then return false end

    -- Boss chest already visible — boss is already dead, skip
    local actors = actors_manager.get_all_actors()
    if type(actors) == "table" then
        for _, actor in pairs(actors) do
            local ok, inter = pcall(function() return actor:is_interactable() end)
            if ok and inter then
                local name = actor:get_skin_name()
                if type(name) == "string" then
                    if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_")
                            or name:find("^Chest_Boss") or name:find("^S12_Prop_Theme_Chest_") then
                        return false
                    end
                end
            end
        end
    end

    -- Brief pause after a chest open before re-activating
    if tracker.chest_opened_time then
        if os.time() < tracker.chest_opened_time + 6 then return false end
    end

    -- Keep running while last_interact_time is set (waiting for altar to disappear)
    if last_interact_time > 0 then return true end

    return utils.get_altar() ~= nil
end

function task.Execute()
    local t     = get_time_since_inject()
    local altar = utils.get_altar()

    -- Altar gone after an interact attempt — success
    if not altar then
        if last_interact_time > 0 then
            console.print("[Reaper] Altar gone — activated successfully.")
            if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
            tracker.altar_activated     = true
            tracker.altar_activate_time = t
            last_interact_time = 0
        end
        return
    end

    -- ---- Unstuck logic ----
    if check_if_stuck() then
        if unstuck_start == 0 then
            unstuck_start = t
        elseif t - unstuck_start > unstuck_timeout then
            unstuck_start = 0
            return
        end
        local ut = explorerlite.find_unstuck_target()
        if ut then
            explorerlite:set_custom_target(ut)
            utils.try_movement_spell(ut)
            pathfinder.force_move_raw(ut)
        end
        return
    else
        unstuck_start = 0
    end

    local dist = utils.distance_to(altar)
    if dist > 2.5 then
        if BatmobilePlugin and dist > 15 then
            if not BatmobilePlugin.is_long_path_navigating() then
                console.print(string.format("[Reaper] Altar at dist=%.1f — starting long path.", dist))
                local ok = BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                if not ok then
                    console.print("[Reaper] Long path failed — using direct move.")
                    pathfinder.request_move(altar:get_position())
                end
            else
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
            end
        else
            if BatmobilePlugin and BatmobilePlugin.is_long_path_navigating() then
                BatmobilePlugin.stop_long_path(plugin_label)
            end
            pathfinder.request_move(altar:get_position())
        end
        return
    end

    -- Close enough — stop any active long path before interacting
    if BatmobilePlugin and BatmobilePlugin.is_long_path_navigating() then
        BatmobilePlugin.stop_long_path(plugin_label)
    end

    -- Enforce cooldown between attempts
    if (t - last_interact_time) < INTERACT_COOLDOWN then return end

    console.print("[Reaper] Interacting with altar.")
    interact_object(altar)
    last_interact_time = t
end

return task
