local plugin_label = 'alfred_the_butler'

local gui          = require 'gui'
local utils        = require 'core.utils'
local settings     = require 'core.settings'
local task_manager = require 'core.task_manager'
local tracker      = require 'core.tracker'
local external     = require 'core.external'
local drawing      = require 'core.drawing'

local local_player
local debounce_time = nil
local debounce_timeout = 1
local keybind_data = checkbox:new(false, get_hash(plugin_label .. '_keybind_data'))
if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false then
    gui.elements.keybind_toggle:set(keybind_data:get())
end

local function update_locals()
    local_player = get_local_player()
end

local function main_pulse()
    settings:update_settings()
    if PERSISTENT_MODE ~= nil and PERSISTENT_MODE ~= false  then
        if keybind_data:get() ~= (gui.elements.keybind_toggle:get_state() == 1) then
            keybind_data:set(gui.elements.keybind_toggle:get_state() == 1)
        end
    end

    if not local_player or not settings.enabled then return end
    utils.update_tracker_count(local_player)

    if gui.elements.manual_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.manual_keybind:set(false)
        debounce_time = get_time_since_inject()
        -- orbwalker.set_clear_toggle(false)
        external.resume()
        utils.reset_restock_stash_count()
        utils.reset_all_task()
        tracker.manual_trigger = true
        if not utils.is_in_town() then
            tracker.teleport = true
        end
    end

    if gui.elements.dump_keybind:get_state() == 1 then
        if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
        gui.elements.dump_keybind:set(false)
        debounce_time = get_time_since_inject()
        utils.dump_tracker_info(tracker)
    end

    if not (settings.get_keybind_state() or tracker.external_trigger or tracker.manual_trigger) then
        return
    end

    task_manager.execute_tasks()
end

local INVENTORY_COLS = 11
local INVENTORY_ROWS = 3

local function draw_inventory_calibration()
    -- Render every predicted inventory slot center as a small crosshair so the
    -- user can confirm Slot 0 + Cell Size before relying on the right-click
    -- stash fallback. Mirrors WonderCity's show_click_points overlay.
    local color_grid = color_white(200)
    local color_origin = color_yellow(220)
    for i = INVENTORY_COLS * INVENTORY_ROWS - 1, 1, -1 do
        local col = i % INVENTORY_COLS
        local row = math.floor(i / INVENTORY_COLS)
        local sx = settings.inventory_slot_0_x + col * settings.inventory_cell_size_x
        local sy = settings.inventory_slot_0_y + row * settings.inventory_cell_size_y
        graphics.line(vec2:new(sx - 6, sy), vec2:new(sx + 6, sy), color_grid, 1)
        graphics.line(vec2:new(sx, sy - 6), vec2:new(sx, sy + 6), color_grid, 1)
        graphics.text_2d(string.format('%d,%d', col, row),
            vec2:new(sx + 8, sy - 6), 11, color_grid)
    end
    -- Slot 0 last so it draws on top, with a labeled crosshair
    local sx0, sy0 = settings.inventory_slot_0_x, settings.inventory_slot_0_y
    local arm = 12
    graphics.line(vec2:new(sx0 - arm, sy0), vec2:new(sx0 + arm, sy0), color_origin, 2)
    graphics.line(vec2:new(sx0, sy0 - arm), vec2:new(sx0, sy0 + arm), color_origin, 2)
    graphics.circle_2d(vec2:new(sx0, sy0), 5, color_origin, 1)
    graphics.text_2d('Slot 0 (0,0)', vec2:new(sx0 + 14, sy0 - 8), 14, color_origin)
end

local function render_pulse()
    if not local_player or not settings.enabled then return end

    if gui.elements.draw_status:get() then
        drawing.draw_status()
    end
    if is_inventory_open() and get_open_inventory_bag() == 0 and
        (gui.elements.draw_stash:get() or
        gui.elements.draw_sell:get() or
        gui.elements.draw_salvage:get())
    then
        drawing.draw_inventory_boxes()
    end
    if settings.show_inventory_calibration then
        draw_inventory_calibration()
    end
end

on_update(function()
    update_locals()
    main_pulse()
end)
on_render_menu(function ()
    gui.render()
    if gui.elements.affix_export_button:get() then
        utils.export_filters(gui.elements,false)
    elseif gui.elements.affix_import_button:get() then
        if gui.elements.affix_import_name:get() ~= '' then
            utils.import_filters(gui.elements)
        else
            utils.log('no import file name')
        end
    end
end)
on_render(render_pulse)

-- incase for some reason settings is not set for utils
if not utils.settings then
    utils.settings = settings
end
PLUGIN_alfred_the_butler = external
AlfredTheButlerPlugin = external