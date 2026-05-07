-- ============================================================
--  Reaper  v1.1
--  by Magoogle
--
--  Flow per run:
--    1. Teleport directly to boss dungeon
--    2. Navigate to altar and interact to summon the boss
--    3. Kill the boss (your combat script handles casting)
--    4. Open the boss chest
--    5. Decrement run count by 1
--    6. When run count hits 0, move to the next boss
--    7. When all bosses are done, disable
-- ============================================================

local gui          = require "gui"
local task_manager = require "core.task_manager"
local settings     = require "core.settings"
local rotation     = require "core.boss_rotation"
local tracker      = require "core.tracker"
local enums        = require "data.enums"
local materials    = require "core.materials"

-- Home town now resolved per pulse from settings.town_zone / settings.town_waypoint
-- (driven by the gui.town combo_box). Defaults to Temis to match Arkham/Alfred.

-- -------------------------------------------------------
-- Enable guard — only fires once per toggle-on
-- -------------------------------------------------------
local enabled_last_frame = false
local enable_time        = 0   -- time when toggle was first turned on

local function on_enable()
    local lp = get_local_player()
    if not lp then return false end

    -- Give the game's inventory API a moment to be ready
    if (get_time_since_inject() - enable_time) < 0.5 then return false end

    console.print("=============================================")
    console.print("  REAPER STARTING")
    console.print("=============================================")

    settings:update_settings()

    -- Debug: log what settings and inventory look like
    console.print(string.format("[Reaper] run_materials=%s  run_sigils=%s",
        tostring(settings.run_materials), tostring(settings.run_sigils)))

    if settings.run_sigils then
        local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)
        if ok and type(keys) == "table" then
            console.print(string.format("[Reaper] dungeon_key_items: %d items", #keys))
        else
            console.print("[Reaper] dungeon_key_items: unavailable")
        end
    end

    if settings.run_materials then
        local ok, cons = pcall(function() return lp:get_consumable_items() end)
        if ok and type(cons) == "table" then
            console.print(string.format("[Reaper] consumable_items: %d items", #cons))
        else
            console.print("[Reaper] consumable_items: unavailable")
        end
        materials.print_all_consumables()
    end

    rotation.build(settings)

    if not rotation.initialized then
        console.print("[Reaper] No materials or sigils in inventory. Stopping.")
        return false
    end

    return true
end

local function on_disable()
    task_manager.reset_all()
    -- Drop any one-shot rotation injected by an external orchestrator so the
    -- next manual enable goes back to inventory-derived farming.
    rotation.clear_external()
    console.print("[Reaper] Stopped.")
    console.print(string.format("[Reaper] Total runs completed this session: %d", tracker.total_kills))
end

-- -------------------------------------------------------
-- Main update
-- -------------------------------------------------------
local enabled_last_frame = false
local enable_time        = 0
local startup_done       = false  -- true once on_enable has been attempted
local finishing          = false  -- true while teleporting to Cerrigar before shutdown
local finish_tp_time     = 0

on_update(function()
    settings:update_settings()
    local enabled = settings.enabled

    -- Detect toggle-on edge
    if enabled and not enabled_last_frame then
        enable_time        = get_time_since_inject()
        enabled_last_frame = true
        startup_done       = false
        return
    end

    -- Detect toggle-off edge
    if not enabled and enabled_last_frame then
        on_disable()
        enabled_last_frame = false
        startup_done       = false
        finishing          = false
        return
    end

    if not enabled then return end

    -- Startup: attempt on_enable once inventory is ready
    if not startup_done then
        local lp = get_local_player()
        if not lp or (get_time_since_inject() - enable_time) < 0.5 then return end

        startup_done = true  -- mark attempted regardless of outcome
        local ok = on_enable()
        if not ok then
            gui.elements.main_toggle:set(false)
            enabled_last_frame = false
        end
        return
    end

    -- Normal running
    local lp = get_local_player()
    if not lp then return end

    -- When rotation is done, return to home town then disable
    if rotation.is_done() or finishing then
        if not finishing then
            console.print("[Reaper] All runs complete — returning to " .. settings.town_zone .. ".")
            task_manager.reset_all()
            teleport_to_waypoint(settings.town_waypoint)
            finishing     = true
            finish_tp_time = get_time_since_inject()
            return
        end
        local world   = get_current_world()
        local zone    = world and world:get_current_zone_name() or ""
        local elapsed = get_time_since_inject() - finish_tp_time
        if zone == settings.town_zone or elapsed > 30.0 then
            console.print("[Reaper] All runs complete. Disabling.")
            finishing          = false
            gui.elements.main_toggle:set(false)
            enabled_last_frame = false
            startup_done       = false
        end
        return
    end

    task_manager.execute_tasks()
end)

-- -------------------------------------------------------
-- Render
-- -------------------------------------------------------
on_render(function()
    local lp = get_local_player()
    if not lp or not settings.enabled then return end

    local current_task = task_manager.get_current_task()
    local boss         = rotation.current()
    local mat_counts   = materials.scan()

    -- Centered task label above the character (same style as ArkhamAsylum)
    if current_task then
        local msg  = "Reaper: " .. current_task.name
        local cx   = get_screen_width() / 2 - (#msg * 5.5)
        graphics.text_2d(msg, vec2:new(cx, 80), 20, color_white(255))
    end

    local x, y = 20, 60
    graphics.text_2d("=== REAPER  by Magoogle ===", vec2:new(x, y), 14, color_orange(255))
    y = y + 20

    if boss then
        graphics.text_2d(
            string.format("Farming: %s  [%s]  (%d runs left)",
                boss.label, boss.run_type, boss.runs_remaining),
            vec2:new(x, y), 13, color_white(255))
        y = y + 16
    end
    if current_task then
        graphics.text_2d("Task: " .. current_task.name, vec2:new(x, y), 12, color_yellow(255))
        y = y + 16
    end
    graphics.text_2d("Total kills: " .. tracker.total_kills, vec2:new(x, y), 12, color_green(255))
    y = y + 20

    graphics.text_2d("── Materials ──", vec2:new(x, y), 12, color_white(180))
    y = y + 14
    for _, bd in ipairs(enums.boss_zones) do
        local runs = mat_counts[bd.id] or 0
        local col  = runs > 0 and color_white(220) or color_red(180)
        graphics.text_2d(
            string.format("%-22s %d", bd.label, runs),
            vec2:new(x, y), 12, col)
        y = y + 13
    end
end)

on_render_menu(gui.render)

-- External plugin API
ReaperPlugin = {
    enable  = function() gui.elements.main_toggle:set(true)  end,
    disable = function() gui.elements.main_toggle:set(false) end,

    -- Externally request a single-boss run. boss_id must match an entry in
    -- enums.boss_zones (e.g. "duriel", "andariel", "varshan"). run_type is
    -- "material" (default) or "sigil". Resets prior task state and enables
    -- the plugin. Returns true on success, false if boss_id is unknown.
    run_boss = function(boss_id, run_type)
        if not rotation.set_external(boss_id, run_type) then
            return false
        end
        task_manager.reset_all()
        gui.elements.main_toggle:set(true)
        return true
    end,

    -- Drop the external rotation without disabling. Useful if an orchestrator
    -- wants to hand control back to inventory-driven farming.
    clear_external = function() rotation.clear_external() end,

    status  = function()
        return {
            enabled    = gui.elements.main_toggle:get(),
            boss       = rotation.current() and rotation.current().label or "None",
            external   = rotation.external,
            total_runs = tracker.total_kills,
            task       = task_manager.get_current_task(),
        }
    end,
}

console.print("=============================================")
console.print("  Reaper  v1.1  by Magoogle  - Loaded")
console.print("  Enable in menu to start reaping")
console.print("=============================================")
