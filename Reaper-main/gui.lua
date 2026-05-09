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

local TREE_MAIN          = 0
local TREE_BOSSES        = 1
local TREE_RESET         = 2
local TREE_BELIAL        = 3
local TREE_BELIAL_ALIGN  = 4
local TREE_MISC          = 5

local chest_boss_labels = {}
for _, bd in ipairs(enums.belial_chest_bosses) do
    chest_boss_labels[#chest_boss_labels + 1] = bd.label
end

local boss_zone_labels = {}
for _, bd in ipairs(enums.boss_zones) do
    boss_zone_labels[#boss_zone_labels + 1] = bd.label
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

    boss_tree   = tree_node:new(TREE_BOSSES),
    reset_tree  = tree_node:new(TREE_RESET),
    belial_tree = tree_node:new(TREE_BELIAL),
    misc_tree   = tree_node:new(TREE_MISC),

    dungeon_reset_enabled  = cb(false,      "dr_en"),
    dungeon_reset_interval = si(1, 200, 10, "dr_int"),

    use_alfred       = cb(true,  "alfred"),
    use_batmobile    = cb(false, "batmobile"),
    manage_orbwalker = cb(false, "manage_orb"),

    -- Default 0 = Temis (matches ArkhamAsylum's default).
    town          = cbo(0,    "town"),

    -- Boss rotation mode + targets
    -- 0 = Manual, 1 = Round Robin, 2 = Random.  Default 1 (Round Robin).
    boss_rotation_mode = cbo(1, "boss_mode"),
    boss_target        = cbo(0, "boss_target"),
    boss_enabled       = {},  -- per-boss toggles for RR / Random pool

    belial_chest_enabled = cb(false, "bel_en"),
    belial_sel_mode      = cbo(0,    "bel_mode"),
    belial_target_boss   = cbo(0,    "bel_target"),
    belial_party_delay   = si(0, 5000, 0, "bel_delay"),
    belial_pool          = {},

    -- Belial chest dialog calibration. Sliders store **pixel coordinates at
    -- a 1920x1080 reference resolution**; tasks/belial_chest.lua applies
    -- center-aware scaling at click time so 21:9 / 32:9 displays don't drift.
    belial_align_tree   = tree_node:new(TREE_BELIAL_ALIGN),
    belial_show_xhairs  = cb(false, "bel_xhairs"),
    -- Boss list column (X) and the seven row Y positions
    belial_slot_x       = si(0, 5120, 349, "bel_slot_x"),
    belial_slot_y_1     = si(0, 2160, 397, "bel_slot_y1"),
    belial_slot_y_2     = si(0, 2160, 495, "bel_slot_y2"),
    belial_slot_y_3     = si(0, 2160, 585, "bel_slot_y3"),
    belial_slot_y_4     = si(0, 2160, 683, "bel_slot_y4"),
    belial_slot_y_5     = si(0, 2160, 773, "bel_slot_y5"),
    belial_slot_y_6     = si(0, 2160, 875, "bel_slot_y6"),
    belial_slot_y_7     = si(0, 2160, 971, "bel_slot_y7"),
    -- Static dialog buttons
    belial_modify_x     = si(0, 5120, 349, "bel_mod_x"),
    belial_modify_y     = si(0, 2160, 816, "bel_mod_y"),
    belial_scroll_x     = si(0, 5120, 629, "bel_scr_x"),
    belial_scroll_y     = si(0, 2160, 858, "bel_scr_y"),
    belial_open_x       = si(0, 5120, 349, "bel_open_x"),
    belial_open_y       = si(0, 2160, 956, "bel_open_y"),
}

for _, bd in ipairs(enums.boss_zones) do
    gui.elements.boss_enabled[bd.id] = cb(false, "boss_" .. bd.id)
end

for _, bd in ipairs(enums.belial_chest_bosses) do
    gui.elements.belial_pool[bd.id] = cb(false, "bpool_" .. bd.id)
end

-- -------------------------------------------------------
function gui.render()
    if not gui.elements.main_tree:push(plugin_label .. "  v1.8  by Magoogle") then return end

    gui.elements.main_toggle:render("Enable", "Start / stop the boss farmer")

    -- ---- Bosses ----
    if gui.elements.boss_tree:push("Bosses to Farm") then
        gui.elements.boss_rotation_mode:render("Rotation Mode", SEL_MODES,
            "Manual = farm one specific boss only.  Round Robin = cycle through the ticked bosses, one run each.  Random = pick a random ticked boss each run.")

        local mode = gui.elements.boss_rotation_mode:get()
        if mode == 0 then
            -- Manual: dropdown of every defined boss
            gui.elements.boss_target:render("Target Boss", boss_zone_labels,
                "The single boss the script will farm. Uses that boss's required key tier.")
        else
            -- Round Robin / Random: per-boss checkboxes
            for _, bd in ipairs(enums.boss_zones) do
                local tier = bd.key_tier or "lair"
                local tier_label = ({
                    lair    = "Lair Key",
                    greater = "Greater Lair Key",
                    husk    = "Betrayer's Husks",
                })[tier] or tier
                local hint
                if tier == "husk" then
                    hint = "Consumes Betrayer's Husks each run."
                else
                    hint = "Consumes one " .. tier_label .. " per run."
                end
                local label = string.format("%s  [%s]", bd.label, tier_label)
                gui.elements.boss_enabled[bd.id]:render(label, hint)
            end
        end
        gui.elements.boss_tree:pop()
    end

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

            -- ---- Alignment (sub-tree) ----
            if gui.elements.belial_align_tree:push("Chest Dialog Alignment") then
                gui.elements.belial_show_xhairs:render("Show crosshairs on screen",
                    "Render coloured crosshairs at every stored click position so you can eyeball them against the live Ritual of Lies dialog.")

                gui.elements.belial_slot_x:render("Slot X (column)",
                    "Boss-list column position, in pixels at a 1920x1080 reference. Auto-scaled (center-aware) on other resolutions.")

                gui.elements.belial_slot_y_1:render("Slot Y1 (row 1)", "")
                gui.elements.belial_slot_y_2:render("Slot Y2 (row 2)", "")
                gui.elements.belial_slot_y_3:render("Slot Y3 (row 3)", "")
                gui.elements.belial_slot_y_4:render("Slot Y4 (row 4)", "")
                gui.elements.belial_slot_y_5:render("Slot Y5 (row 5)", "")
                gui.elements.belial_slot_y_6:render("Slot Y6 (row 6)", "")
                gui.elements.belial_slot_y_7:render("Slot Y7 (row 7)", "")

                gui.elements.belial_modify_x:render("Modify Reward X", "")
                gui.elements.belial_modify_y:render("Modify Reward Y", "")
                gui.elements.belial_scroll_x:render("Scroll X", "")
                gui.elements.belial_scroll_y:render("Scroll Y", "")
                gui.elements.belial_open_x:render("Open X", "")
                gui.elements.belial_open_y:render("Open Y", "")

                gui.elements.belial_align_tree:pop()
            end
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
            "Always use BatmobilePlugin for navigation. When off, path files are tried first and Batmobile is engaged automatically as a fallback.")
        gui.elements.manage_orbwalker:render("Manage Orbwalker",
            "When OFF (default), Reaper never touches orbwalker — your rotation owns it. When ON, Reaper forces clear-mode + block-movement during boss combat.")

        gui.elements.misc_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
