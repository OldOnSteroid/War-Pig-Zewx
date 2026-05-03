local plugin_label   = 'war_pigs'
local plugin_version = '1.0.0'
console.print('Lua Plugin - WarPigs - v' .. plugin_version)

local gui = {}

local create_checkbox = function(value, key)
    return checkbox:new(value, get_hash(plugin_label .. '_' .. key))
end

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version

gui.elements = {
    main_tree     = tree_node:new(0),
    main_toggle   = create_checkbox(false, 'main_toggle'),
    use_keybind   = create_checkbox(false, 'use_keybind'),
    -- 0x0A is the harness convention for "no key bound yet" — same default as HordeDev.
    keybind_toggle= keybind:new(0x0A, true, get_hash(plugin_label .. '_keybind_toggle')),
    verbose_logs  = create_checkbox(false, 'verbose_logs'),
    log_all_quests= create_checkbox(false, 'log_all_quests'),
}

gui.render = function()
    if not gui.elements.main_tree:push('Z | War Pigs | Orchestrator | v' .. gui.plugin_version) then return end
    local orchestrator = require 'core.orchestrator'
    for quest_name, raw_entry in pairs(orchestrator.quest_plugin_map) do
        local plugin_name
        if type(raw_entry) == 'string' then
            plugin_name = raw_entry
        elseif type(raw_entry) == 'table' then
            plugin_name = raw_entry.plugin  -- nil for task-only entries
        end
        if plugin_name and _G[plugin_name] == nil then
            render_menu_header(plugin_name .. ' not loaded — ' .. quest_name .. ' will not be managed')
        end
    end
    gui.elements.main_toggle:render('Enable', 'Watch active quests and toggle managed plugins')
    gui.elements.use_keybind:render('Use keybind', 'Quick on/off toggle via a hotkey')
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render('Toggle Keybind', 'Press to toggle WarPigs on/off')
    end
    gui.elements.verbose_logs:render('Verbose logs', 'Print WarPlans quest diffs to console')
    gui.elements.log_all_quests:render('Log ALL quests', 'Print every newly-seen quest name + id to console (use to capture quest names for new activities)')
    gui.elements.main_tree:pop()
end

return gui
