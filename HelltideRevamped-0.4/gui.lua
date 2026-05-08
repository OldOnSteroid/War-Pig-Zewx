local gui = {}
local version = "v0.4"
local plugin_label = "helltide_revamped"

local function create_checkbox(value, key)
    return checkbox:new(value, get_hash(plugin_label .. "_" .. key))
end

-- Town options for the idle / give-up teleport target. Order matches Alfred's
-- ordering (Temis, Cerrigar). Resolved to zone/waypoint in core/settings.lua.
gui.town = { "Temis", "Cerrigar" }
gui.town_data = {
    [0] = { zone_name = "Skov_Temis",    waypoint_sno = 0x1CE51E },
    [1] = { zone_name = "Scos_Cerrigar", waypoint_sno = 0x76D58 },
}

gui.elements = {
    main_tree = tree_node:new(0),
    main_toggle = create_checkbox(false, "main_toggle"),
    settings_tree = tree_node:new(1),
    town = combo_box:new(0, get_hash(plugin_label .. "_town")),
    salvage_toggle = create_checkbox(true, plugin_label .. "salvage_toggle"),
    silent_chest_toggle = create_checkbox(true, plugin_label .. "silent_chest_toggle"),
    helltide_chest_toggle = create_checkbox(true, plugin_label .. "helltide_chest_toggle"),
    ore_toggle = create_checkbox(true, plugin_label .. "ore_toggle"),
    herb_toggle = create_checkbox(true, plugin_label .. "herb_toggle"),
    shrine_toggle = create_checkbox(true, plugin_label .. "shrine_toggle"),
    goblin_toggle = create_checkbox(true, plugin_label .. "goblin_toggle"),
    event_toggle = create_checkbox(true, plugin_label .. "event_toggle"),
    chaos_rift_toggle = create_checkbox(true, plugin_label .. "chaos_rift_toggle"),
    prioritize_traversals_toggle = create_checkbox(false, plugin_label .. "prioritize_traversals_toggle"),
    kill_monsters_toggle = create_checkbox(true, plugin_label .. "kill_monsters_toggle"),
    experimental_explorer_toggle = create_checkbox(false, plugin_label .. "experimental_explorer_toggle"),
    farm_cinder_threshold = slider_int:new(0, 250, 0, get_hash(plugin_label .. "_farm_cinder_threshold")),
    do_maiden_toggle = create_checkbox(false, plugin_label .. "do_maiden_toggle"),
    maiden_disable_cinders = slider_int:new(0, 1000, 0, get_hash(plugin_label .. "_maiden_disable_cinders")),
    manage_orbwalker = create_checkbox(false, plugin_label .. "manage_orbwalker"),
}

function gui.render()
    if not gui.elements.main_tree:push("Z | Helltide Revamped | Letrico | " .. version) then return end

    gui.elements.main_toggle:render("Enable", "Enable the bot")
    
    if gui.elements.settings_tree:push("Settings") then
        gui.elements.manage_orbwalker:render("Manage orbwalker", "When enabled, this script will toggle orbwalker clear during helltide tasks. Off by default — leaves orbwalker fully under your rotation's control.")
        gui.elements.town:render("Idle town", gui.town, "Town to teleport to between helltides and after Batmobile gives up. Match this to your Alfred town setting to avoid bouncing.")
        gui.elements.salvage_toggle:render("Salvage with alfred", "Enable salvaging items with alfred")
        gui.elements.silent_chest_toggle:render("Open Silent Chest (key required)", "Open silent chest")
        gui.elements.helltide_chest_toggle:render("Open Helltide Chest", "Open helltide chest")
        gui.elements.ore_toggle:render("Collect Ore", "Collect ore")
        gui.elements.herb_toggle:render("Collect Herb", "Collect herb")
        gui.elements.shrine_toggle:render("Use Shrine", "Use shrine")
        gui.elements.goblin_toggle:render("Chase goblin", "Chase goblin")
        gui.elements.event_toggle:render("Do events (flame pillar/ravenous soul)", "Do events")
        gui.elements.chaos_rift_toggle:render("Do chaos rift", "Do chaos rift")
        gui.elements.prioritize_traversals_toggle:render("Prioritize Traversals", "Move to nearby traversals (ladders/portals) before kill monsters; blacklists unreachable ones for 30s")
        gui.elements.kill_monsters_toggle:render("Kill Monsters", "Navigate to and kill nearby monsters while exploring")
        gui.elements.experimental_explorer_toggle:render("Experimental Explorer", "Zone-wide grid coverage instead of Batmobile frontier. Tracks chest locations across the full helltide hour. Resets only when helltide ends.")
        gui.elements.farm_cinder_threshold:render("Farm Cinder Threshold (beta)", "Stay near a remembered chest and kill monsters when you are within this many cinders of affording it (0 = disabled)")
        gui.elements.do_maiden_toggle:render("Do Maiden", "Walk to the maiden altar, insert hearts (up to 3) and stay pinned to fight the maiden. Requires Helltide Coin Hearts in your inventory.")
        if gui.elements.do_maiden_toggle:get() then
            gui.elements.maiden_disable_cinders:render("Disable Maiden at Cinders", "Stop running maiden once you reach this cinder count (0 = never disable). Useful so the bot can spend cinders before saving more for chests.", 1)
        end
        gui.elements.settings_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui