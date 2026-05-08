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
InfernalHordesPlugin = {
    enable = function ()
        console.print('HORDE ACTIVATING')
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
    -- True once all chests have been looted this run. WarPigs uses this to
    -- delay disabling HordeDev when the player leaves BSK temporarily for
    -- a mid-run salvage trip (Alfred TPs to town → player exits BSK →
    -- disable_when would fire too early without this guard).
    chests_done = function()
        return tracker.finished_chest_looting == true
    end,
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