local gui = {}
local plugin_label = "infernal_horde"
local version = "v1.3.9"
console.print("Lua Plugin - Infernal Hordes - Letrico - " .. version);

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. "_" .. key))
end

-- Add chest types enum
gui.chest_types_enum = {
    MATERIALS = 0,
    GOLD = 1,
}

gui.chest_types_options = {
    "Materials",
    "Gold",
}

gui.exit_modes_enum = {
    RESET = 0,
    TELEPORT = 1,
}
gui.exit_mode = { 'Reset', 'Teleport'}

gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, "main_toggle"),
    use_keybind = create_checkbox(false, "use_keybind"),
    keybind_toggle = keybind:new(0x0A, true, get_hash(plugin_label .. "_keybind_toggle" )),
    settings_tree = tree_node:new(1),
    advanced_tree = tree_node:new(2),
    movement_tree = tree_node:new(3),
    run_pit_toggle = create_checkbox(false, "run_pit"),
    party_mode_toggle = create_checkbox(false, "party_mode"),
    do_bartuc_toggle = create_checkbox(false, "do_bartuc"),
    salvage_toggle = create_checkbox(true, "salvage_toggle"),
    aggresive_movement_toggle = create_checkbox(true, "aggresive_movement_toggle"),
    path_angle_slider = slider_int:new(0, 360, 10, get_hash(plugin_label .. "path_angle_slider")), -- 10 is a default value
    chest_type_selector = combo_box:new(0, get_hash(plugin_label .. "chest_type_selector")),
    always_open_ga_chest = create_checkbox(true, "always_open_ga_chest"),
    always_open_talisman_chest = create_checkbox(false, "always_open_talisman_chest"),
    merry_go_round = create_checkbox(true, "merry_go_round"),
    pick_pylon_delay = slider_float:new(1.5, 8.0, 1.5, get_hash(plugin_label .. "pick_pylon_delay")), -- 3.0 is the default value
    open_ga_chest_delay = slider_float:new(3, 10.0, 3.0, get_hash(plugin_label .. "open_ga_chest_delay")), -- 3.0 is the default value
    open_chest_delay = slider_float:new(1.0, 3.0, 1.5, get_hash(plugin_label .. "open_chest_delay")), -- 1.5 is the default value
    wait_loot_delay = slider_int:new(1, 20, 10, get_hash(plugin_label .. "wait_loot_delay")), -- 10 is a default value
    boss_kill_delay = slider_int:new(1, 15, 6, get_hash(plugin_label .. "boss_kill_delay")), -- 6 is a default value
    chest_move_attempts = slider_int:new(20, 400, 40, get_hash(plugin_label .. "chest_move_attempts")), -- 40 is a default value
    use_salvage_filter_toggle = create_checkbox(false, "use_salvage_filter_toggle"),
    greater_affix_count = slider_int:new(0, 3, 0, get_hash(plugin_label .. "greater_affix_count")), -- 0 is the default value
    affix_salvage_count = slider_int:new(0, 3, 1, get_hash(plugin_label .. "affix_salvage_count")), -- 0 is a default value
    movement_spell_to_objective = create_checkbox(true, "movement_spell_to_objective"),
    use_evade_as_movement_spell = create_checkbox(true, "use_evade_as_movement_spell"),
    use_teleport = create_checkbox(true, "use_teleport"),
    use_teleport_enchanted = create_checkbox(true, "use_teleport_enchanted"),
    use_dash = create_checkbox(true, "use_dash"),
    use_shadow_step = create_checkbox(true, "use_shadow_step"),
    use_the_hunter = create_checkbox(true, "use_the_hunter"),
    use_soar = create_checkbox(true, "use_soar"),
    use_rushing_claw = create_checkbox(true, "use_rushing_claw"),
    use_leap = create_checkbox(true, "use_leap"),
    use_alfred = create_checkbox(true, "use_alfred"),
    use_6_wave = create_checkbox(true, "use_6_wave"),
    use_8_wave = create_checkbox(true, "use_8_wave"),
    use_10_wave = create_checkbox(true, "use_10_wave"),
    use_bloodied = create_checkbox(false, "use_bloodied"),
    exit_mode = combo_box:new(0, get_hash(plugin_label .. "_exit_mode")),
    manage_orbwalker = create_checkbox(false, "manage_orbwalker"),
}

function gui.render()
    if not gui.elements.main_tree:push("Z | Infernal Horde | Letrico | " .. version) then return end

    gui.elements.main_toggle:render("Enable", "Enable the bot")
    gui.elements.use_keybind:render("Use keybind", "Keybind to quick toggle the bot");
    if gui.elements.use_keybind:get() then
        gui.elements.keybind_toggle:render("Toggle Keybind", "Toggle the bot for quick enable");
    end
    if gui.elements.settings_tree:push("Settings") then
        gui.elements.manage_orbwalker:render("Manage orbwalker", "When enabled, this script will toggle orbwalker clear during horde tasks. Off by default — leaves orbwalker fully under your rotation's control.");
        gui.elements.run_pit_toggle:render("Run pit when finish compasses", "Run pit when finish compasses");
        gui.elements.party_mode_toggle:render("Party mode (Does not pick pylon)", "Does not activate Pylon");
        gui.elements.do_bartuc_toggle:render("Do Bartuc", "Choose Bartuc as first choice");
        gui.elements.aggresive_movement_toggle:render("Aggresive movement", "Move directly to target, will fight close to target");
        if not gui.elements.aggresive_movement_toggle:get() then
            gui.elements.path_angle_slider:render("Path Angle", "Adjust the angle for path filtering (0-360 degrees)")
        end
        gui.elements.movement_spell_to_objective:render("Attempt to use movement spell for objective", "Will attempt to use movement spell towards objective")
        if gui.elements.movement_spell_to_objective:get() then
            if gui.elements.movement_tree:push("Movement Spells") then
                gui.elements.use_evade_as_movement_spell:render("Default Evade", "Will attempt to use evade as movement spell")
                gui.elements.use_teleport:render("Sorceror Teleport", "Will attempt to use Sorceror Teleport as movement spell")
                gui.elements.use_teleport_enchanted:render("Sorceror Teleport Enchanted", "Will attempt to use Sorceror Teleport Enchanted as movement spell")
                gui.elements.use_dash:render("Rogue Dash", "Will attempt to use Rogue Dash as movement spell")
                gui.elements.use_shadow_step:render("Rogue Shadow Step", "Will attempt to use Rogue Shadow Step as movement spell")
                gui.elements.use_the_hunter:render("Spiritborn The Hunter", "Will attempt to use Spiritborn The Hunter as movement spell")
                gui.elements.use_soar:render("Spiritborn Soar", "Will attempt to use Spiritborn Soar as movement spell")
                gui.elements.use_rushing_claw:render("Spiritborn Rushing Claw", "Will attempt to use Spiritborn Rushing Claw as movement spell")
                gui.elements.use_leap:render("Barbarian Leap", "Will attempt to use Barbarian Leap as movement spell")
                gui.elements.movement_tree:pop()
            end
        end

        -- Updated chest type selector to use the new enum structure
        gui.elements.exit_mode:render("Exit mode", gui.exit_mode, "Select reset or teleport to exit horde")
        gui.elements.merry_go_round:render("Circle arena when wave completes", "Toggle to circle arene when wave completes to pick up stray Aethers")
        gui.elements.always_open_ga_chest:render("Always Open GA Chest", "Toggle to always open Greater Affix chest when available")
        gui.elements.always_open_talisman_chest:render("Always Open WarPlans Talisman Chest", "Open the WarPlans Talisman Chest (Warplans_BSK_TalismanChest) FIRST, before GA / selected. Only spawns when the WarPlans quest is active.")
        gui.elements.chest_type_selector:render("Select Chest Type", gui.chest_types_options, "Select the type of chest to open")
        gui.elements.salvage_toggle:render("Salvage", "Enable salvaging items")
        if gui.elements.salvage_toggle:get() then
            if PLUGIN_alfred_the_butler then
                local alfred_status = PLUGIN_alfred_the_butler.get_status()
                if alfred_status.enabled then
                    gui.elements.use_alfred:render("Use alfred (salvage/sell/stash/restock)", "use alfred to manage town tasks")
                end
            end
            if not gui.elements.use_alfred:get() then
                gui.elements.use_salvage_filter_toggle:render("Use salvage filter logic (update filter)", "Salvage based on filter logic. Update filter") 
                gui.elements.greater_affix_count:render("Min Greater Affixes to Keep", "Select minimum number of Greater Affixes to keep an item (0-3, 0 = off)")
                if gui.elements.salvage_toggle:get() and gui.elements.use_salvage_filter_toggle:get() then
                    gui.elements.affix_salvage_count:render("Min No. affixes to keep", "Minimum number of matching affixes to keep")
                end
            end
        end
        gui.elements.settings_tree:pop()
    end

    if gui.elements.advanced_tree:push("Advanced settings") then
        gui.elements.use_6_wave:render("Use 6 wave compasses", "Use 6 wave compasses")
        gui.elements.use_8_wave:render("Use 8 wave compasses", "Use 8 wave compasses")
        gui.elements.use_10_wave:render("Use 10 wave compasses", "Use 10 wave compasses")
        gui.elements.use_bloodied:render("Use bloodied", "Use bloodied (S12_DungeonSigil_BSK_SpecialButcher)")
        gui.elements.pick_pylon_delay:render("Pick Pylon delay", "Adjust delay for the picking pylon. DO NOT GO LOWER THAN 1.5!", 1)
        gui.elements.open_ga_chest_delay:render("GA Chest open delay", "Adjust delay for the chest opening (1.0-3.0)", 1)
        gui.elements.open_chest_delay:render("Chest open delay", "Adjust delay for the chest opening (1.0-3.0)", 1)
        gui.elements.wait_loot_delay:render("Wait loot delay", "Adjust delay for the waiting loot (12)")
        gui.elements.boss_kill_delay:render("Boss kill delay", "Adjust delay after killing boss (1-15)")
        gui.elements.chest_move_attempts:render("Chest move attempts", "Adjust the amount of times it tries to reach a chest (20-400)")
        gui.elements.advanced_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
