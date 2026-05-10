local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local utils        = require "core.utils"
local meteor       = require "Meteor"

local local_player, player_position

local function update_locals()
    local_player = get_local_player()
    player_position = local_player and local_player:get_position()
end

local function main_pulse()
    settings:update_settings()
    if not local_player or not (settings.enabled and utils.get_keybind_state() ) then return end
    if settings.manage_orbwalker and orbwalker.get_orb_mode() ~= 3 then
        orbwalker.set_clear_toggle(true);
    end
    task_manager.execute_tasks()
end

local function render_pulse()
    if not local_player or not (settings.enabled and utils.get_keybind_state() ) then return end
    local current_task = task_manager.get_current_task()
    if current_task then
        local px, py, pz = player_position:x(), player_position:y(), player_position:z()
        local draw_pos = vec3:new(px, py - 2, pz + 3)
        graphics.text_3d("Current Task: " .. current_task.name, draw_pos, 14, color_white(255))
    end
end

-- Set Global access for other plugins
local tracker = require "core.tracker"
local open_chests_task = require "tasks.open_chests"
InfernalHordesPlugin = {
    enable = function ()
        console.print('HORDE ACTIVATING')
        -- Wipe leftover run state before activating. WarPigs re-enables the
        -- plugin mid-BSK after a prior wave; without this, finished_chest_looting
        -- and the per-chest opened flags survive and the next run skips
        -- open_chests entirely (exit_horde fires the moment the player is back
        -- in BSK). fresh_run_reset() also covers the normal Library->sigil flow
        -- as a no-op because start_dungeon's reset_chest_flags() runs anyway.
        tracker.fresh_run_reset()
        -- open_chests has its own internal state machine (current_state etc.)
        -- that finishes at chest_state.FINISHED on the prior run; reset it so
        -- the SM re-enters at INIT.
        open_chests_task:reset()
        -- Stamp the enable time so the horde task's settle gate (in horde.lua's
        -- shouldExecute) can wait for world/zone to stabilize before firing
        -- the wave loop. Read by horde.shouldExecute alongside a world-name
        -- check ('BSK' substring) — both must hold before the bomber pulses.
        tracker.enable_time = get_time_since_inject()
        gui.elements.main_toggle:set(true)
        gui.elements.keybind_toggle:set(true)
        settings:update_settings()
    end,
    disable = function ()
        console.print('HORDE DEACTIVATING')
        gui.elements.main_toggle:set(false)
        gui.elements.keybind_toggle:set(false)
        settings:update_settings()
    end,
    status = function ()
        return {
            ['enabled'] = gui.elements.main_toggle:get(),
            ['task'] = task_manager.get_current_task()
        }
    end,
    getState = function ()
        local current = task_manager.get_current_task()
        if current then
            if current.name == "Walking to Horde" then
                return "WALKING_TO_HORDE"
            end
            if current.name == "Infernal Horde" and tracker.interacting_pylon then
                return "INTERACTING_PYLON"
            end
            if current.name == "Open Chests" then
                return "OPENING_CHESTS"
            end
            if current.name == "Exit Horde" then
                return "EXITING_HORDE"
            end
        end
        return "IDLE"
    end,
    -- True once HordeDev is committed to leaving BSK. WarPigs uses this to
    -- delay disabling HordeDev when the player leaves BSK temporarily for
    -- a mid-run salvage trip (Alfred TPs to town → player exits BSK →
    -- disable_when would fire too early without this guard).
    --
    -- Gate: current task must be "Exit Horde" for CHESTS_DONE_HOLD_S seconds.
    -- exit_horde.shouldExecute requires player_in_zone(BSK) AND stash visible
    -- AND finished_chest_looting=true (tasks/exit_horde.lua:49-53), so we're
    -- looking at the strongest possible "we're done with chests" signal — the
    -- task that runs only after every chest has been resolved AND the player
    -- is at the post-boss stash. The hold filters out single-tick blips where
    -- some other task briefly preempts (e.g. alfred kicking in for salvage)
    -- before exit_horde re-takes the queue.
    --
    -- Why not gate on chest flags directly: open_chests can reach FINISHED
    -- prematurely (indexing skip in try_next_chest, chest-not-found give-up)
    -- which flips finished_chest_looting=true after only the first chest. The
    -- exit_horde task gate is harder to spoof — it requires the boss-room
    -- stash actor, which only appears once the wave is fully complete.
    --
    -- A 300s safety cap exists in WarPigs (max_disable_defer_seconds) so a
    -- malformed run can't deadlock forever.
    chests_done = (function()
        local CHESTS_DONE_HOLD_S = 2.0
        local first_seen = nil
        return function()
            local current = task_manager.get_current_task()
            local in_exit_horde = current and current.name == "Exit Horde"
            if not in_exit_horde then
                first_seen = nil
                return false
            end
            first_seen = first_seen or get_time_since_inject()
            return (get_time_since_inject() - first_seen) >= CHESTS_DONE_HOLD_S
        end
    end)(),
    getSettings = function (setting)
        if settings[setting] then
            return settings[setting]
        else
            return nil
        end
    end,
    setSettings = function (setting, value)
        if settings[setting] then
            settings[setting] = value
            return true
        else
            return false
        end
    end,
}

on_update(function()
    update_locals()
    meteor.initialize()
    main_pulse()
end)

on_render_menu(gui.render)
on_render(render_pulse)