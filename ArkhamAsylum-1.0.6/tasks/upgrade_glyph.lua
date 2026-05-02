local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require "core.tracker"
local gui = require "gui"

local status_enum = {
    IDLE = 'idle',
    UPGRADING = 'upgrading glyphs',
    WALKING = 'walking to Awakened Glyphstone',
    INTERACTING = 'interacting with Awakened Glyphstone',
}
local task = {
    name = 'upgrade_glyph', -- change to your choice of task name
    status = status_enum['IDLE'],
    last_interaction_time = -1,
    blacklist = {},
    last_glyph = nil,
    failed_count = 0
}
local should_upgrade = function(glyph)
    if task.last_attempted_glyph ~= nil and
        task.last_attempted_glyph.glyph_name_hash == glyph.glyph_name_hash and
        task.last_attempted_glyph:get_level() == glyph:get_level()
    then
        if glyph:get_level() == 45 or task.failed_count >= 5 then
            task.blacklist[glyph.glyph_name_hash] = true
            task.failed_count = 0
        else
            task.failed_count = task.failed_count + 1
        end
    else
        task.failed_count = 0
    end
    -- rounding upgrade chance to the nearest %
    -- can_upgrade() is bugged for lvl 45 for some reason
    local upgrade_chance = math.floor((glyph:get_upgrade_chance() + 0.005) * 100)
    if upgrade_chance >= settings.upgrade_threshold and
        task.blacklist[glyph.glyph_name_hash] == nil and
        glyph:get_level() >= settings.minimum_glyph_level and
        glyph:get_level() <= settings.maximum_glyph_level and
        (glyph:can_upgrade() or (settings.upgrade_legendary_toggle and glyph:get_level() == 45))
    then
        return true
    end
    return false
end
local upgrade_glyphs = function (glyphs)
    local current_time = get_time_since_inject()
    if task.last_interaction_time + 2 > current_time then return end
    task.last_interaction_time = get_time_since_inject()
    if settings.upgrade_mode == gui.upgrade_modes_enum.HIGHEST then
        for i = 1, glyphs:size() do
            local current_glyph = glyphs:get(i)
            if should_upgrade(current_glyph) then
                console.print('Upgrading ' .. tostring(current_glyph.glyph_name_hash))
                task.last_attempted_glyph = current_glyph
                upgrade_glyph(current_glyph)
                task.last_interaction_time = get_time_since_inject()
                return
            end
        end
    elseif settings.upgrade_mode == gui.upgrade_modes_enum.LOWEST then
        local lowest_glyph = nil
        for i = 1, glyphs:size() do
            local current_glyph = glyphs:get(i)
            if should_upgrade(current_glyph) and
                (lowest_glyph == nil or lowest_glyph:get_level() >= current_glyph:get_level())
            then
                lowest_glyph = current_glyph
            end
        end
        if lowest_glyph ~= nil then
            console.print('Upgrading ' .. tostring(lowest_glyph.glyph_name_hash))
            task.last_attempted_glyph = lowest_glyph
            upgrade_glyph(lowest_glyph)
            task.last_interaction_time = get_time_since_inject()
            return
        end
    end
    -- nothing to upgrade
    task.status = status_enum['IDLE']
    tracker.glyph_done = true
end
task.shouldExecute = function ()
    local should_execute = not utils.is_looting() and
        settings.upgrade_toggle and
        utils.get_glyph_upgrade_gizmo() and
        utils.player_in_pit()
    if should_execute then
        local glyphs = get_glyphs()
        if glyphs ~= nil then
            for i = 1, glyphs:size() do
                if should_upgrade(glyphs:get(i)) then return true end
            end
            should_execute = not (glyphs:size() > 0 and tracker.glyph_done)
        end
    end
    return should_execute

end
task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    local gizmo = utils.get_glyph_upgrade_gizmo()
    local glyphs = get_glyphs()
    if gizmo ~= nil and utils.distance(local_player, gizmo) > 2 then
        local disable_spell = false
        if utils.distance(local_player, gizmo) <= 4 then
            disable_spell = true
        end
        BatmobilePlugin.set_target(plugin_label, gizmo, disable_spell)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    elseif glyphs ~= nil and glyphs:size() > 0 and
        tracker.glyph_trigger_time ~= nil and
        tracker.glyph_trigger_time + 1 < get_time_since_inject()
    then
        interact_object(gizmo)
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['UPGRADING']
        upgrade_glyphs(glyphs)
    elseif gizmo ~= nil and tracker.glyph_trigger_time == nil then
        tracker.glyph_trigger_time = get_time_since_inject()
        task.last_interaction_time = -1
        task.blacklist = {}
        task.last_glyph = nil
        task.failed_count = 0
        BatmobilePlugin.clear_target(plugin_label)
        interact_object(gizmo)
        task.status = status_enum['INTERACTING']
    elseif gizmo ~= nil then
        BatmobilePlugin.clear_target(plugin_label)
        interact_object(gizmo)
        task.status = status_enum['INTERACTING']
    end
end

return task