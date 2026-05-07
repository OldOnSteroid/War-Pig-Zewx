-- ============================================================
--  Reaper - gui.lua
-- ============================================================

local gui          = {}
local plugin_label = "Reaper"
local enums        = require "data.enums"

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. "_" .. key))
end
local function si(min, max, default, key)
    return slider_int:new(min, max, default, get_hash(plugin_label .. "_" .. key))
end
local function cbo(default_idx, key)
    return combo_box:new(default_idx, get_hash(plugin_label .. "_" .. key))
end

local TREE_MAIN   = 0
local TREE_RESET  = 1
local TREE_BELIAL = 2
local TREE_MISC   = 3

local chest_boss_labels = {}
for _, bd in ipairs(enums.belial_chest_bosses) do
    chest_boss_labels[#chest_boss_labels + 1] = bd.label
end

local SEL_MODES = { "Manual", "Round Robin", "Random" }

-- Town options match ArkhamAsylum's order so a user picking the same town
-- across plugins keeps Alfred / Reaper / Arkham in sync. Index resolved to
-- zone/waypoint in core/settings.lua.
gui.town = { 'Temis', 'Cerrigar' }
gui.town_enum = {
    TEMIS    = 0,
    CERRIGAR = 1,
}
gui.town_data = {
    [0] = {
        zone_name    = 'Skov_Temis',
        waypoint_sno = 0x1CE51E,
    },
    [1] = {
        zone_name    = 'Scos_Cerrigar',
        waypoint_sno = 0x76D58,
    },
}

gui.elements = {
    main_tree   = tree_node:new(TREE_MAIN),
    main_toggle = cb(false, "main_toggle"),

    reset_tree  = tree_node:new(TREE_RESET),
    belial_tree = tree_node:new(TREE_BELIAL),
    misc_tree   = tree_node:new(TREE_MISC),

    dungeon_reset_enabled  = cb(false,      "dr_en"),
    dungeon_reset_interval = si(1, 200, 10, "dr_int"),

    use_alfred    = cb(true,  "alfred"),
    use_batmobile = cb(false, "batmobile"),

    -- Default 0 = Temis (matches ArkhamAsylum's default).
    town          = cbo(0,    "town"),

    -- Run type toggles
    run_materials = cb(true,  "run_mats"),
    run_sigils    = cb(true,  "run_sigils"),

    belial_chest_enabled = cb(false, "bel_en"),
    belial_sel_mode      = cbo(0,    "bel_mode"),
    belial_target_boss   = cbo(0,    "bel_target"),
    belial_party_delay   = si(0, 5000, 0, "bel_delay"),
    belial_pool          = {},
}

for _, bd in ipairs(enums.belial_chest_bosses) do
    gui.elements.belial_pool[bd.id] = cb(false, "bpool_" .. bd.id)
end

-- -------------------------------------------------------
function gui.render()
    if not gui.elements.main_tree:push(plugin_label .. "  v1.1  by Magoogle") then return end

    gui.elements.main_toggle:render("Enable", "Start / stop the boss farmer")

    -- ---- Dungeon Reset ----
    if gui.elements.reset_tree:push("Dungeon Reset") then
        gui.elements.dungeon_reset_enabled:render("Enable", "Reset all dungeons every N runs")
        if gui.elements.dungeon_reset_enabled:get() then
            gui.elements.dungeon_reset_interval:render("Every N runs", "")
        end
        gui.elements.reset_tree:pop()
    end

    -- ---- Belial Chest ----
    if gui.elements.belial_tree:push("Belial Chest Automation") then
        gui.elements.belial_chest_enabled:render("Enable", "Auto-click Ritual of Lies chest after killing Belial")
        if gui.elements.belial_chest_enabled:get() then
            gui.elements.belial_sel_mode:render("Mode", SEL_MODES, "Manual / Round Robin / Random")
            local mode = gui.elements.belial_sel_mode:get()
            if mode == 0 then
                gui.elements.belial_target_boss:render("Target Boss", chest_boss_labels, "")
            else
                for _, bd in ipairs(enums.belial_chest_bosses) do
                    gui.elements.belial_pool[bd.id]:render(bd.label, "Include in pool")
                end
            end
            gui.elements.belial_party_delay:render("Party Delay (ms)", "Extra ms before clicking Open")
        end
        gui.elements.belial_tree:pop()
    end

    -- ---- Settings ----
    if gui.elements.misc_tree:push("Settings") then
        gui.elements.town:render("Home town", gui.town,
            "Town to teleport to between runs. Match this to your Alfred / Arkham town setting.")
        gui.elements.use_alfred:render("Use Alfred",
            "Hand off inventory/repair/restock tasks to Alfred.")
        gui.elements.use_batmobile:render("Use Batmobile Navigation",
            "Use BatmobilePlugin autonomous navigation instead of pre-recorded path files.")

        gui.elements.run_materials:render("Run Material Runs",
            "Farm bosses using consumable summoning materials (Shards of Agony, Living Steel, etc.)")
        gui.elements.run_sigils:render("Run Lair Boss Sigils",
            "Farm bosses using Bloodied and Bloodsoaked Lair Boss Sigils from your dungeon key inventory.")

        gui.elements.misc_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
