-- ============================================================
--  Reaper - tasks/navigate_to_boss.lua
--
--  Flow (material runs):
--    MAP_NAV      → teleport_to_boss_dungeon via map_nav.lua
--    PATHWALKING  → fire BatmobilePlugin.navigate_long_path to altar/seed
--                   (if long path fails, falls back to path-file waypoints)
--    LONG_PATHING → Batmobile drives navigation to altar
--                   (on failure/timeout, falls back to path-file waypoints)
--    WALKING      → walk to dungeon entrance portal
--    ENTERING     → interact with portal to enter
--
--  Flow (sigil runs):
--    USE_SIGIL    → activate sigil item, confirm dialog
--    MAP_NAV      → navigate to boss dungeon via map_nav.lua
--    (then same PATHWALKING / LONG_PATHING)
--
--  Batmobile BFS exploration is NEVER used.  When long path (uncapped A*)
--  cannot find a route, we fall back to sequential path-file waypoints which
--  are guaranteed walkable (recorded in-game).
-- ============================================================

local utils      = require "core.utils"
local enums      = require "data.enums"
local map_nav    = require "core.map_nav"
local rotation   = require "core.boss_rotation"
local tracker    = require "core.tracker"
local pathwalker = require "core.pathwalker"
local settings   = require "core.settings"

local plugin_label  = 'reaper'
-- Home town resolved per pulse from settings.town_zone / settings.town_waypoint.

-- -------------------------------------------------------
-- Path-file variant loader (used when Batmobile is off)
-- -------------------------------------------------------
local cached_variants = {}

local function load_variants(boss_id)
    if cached_variants[boss_id] then return cached_variants[boss_id] end
    local variants = {}
    for _, letter in ipairs({"a","b","c","d","e"}) do
        local mod = "paths/" .. boss_id .. "_" .. letter
        local ok, pts = pcall(require, mod)
        if ok and type(pts) == "table" and #pts > 0 then
            variants[#variants + 1] = pts
        end
    end
    cached_variants[boss_id] = variants
    return variants
end

local function pick_best_path(variants)
    if not variants or #variants == 0 then return nil end
    if #variants == 1 then return variants[1] end
    local pp = get_player_position()
    if not pp then return variants[1] end
    local best, best_dist = variants[1], math.huge
    for _, pts in ipairs(variants) do
        if pts[1] then
            local d = pp:dist_to(pts[1])
            if d < best_dist then best = pts; best_dist = d end
        end
    end
    return best
end

-- -------------------------------------------------------
-- Zone helpers
-- -------------------------------------------------------
local function in_target_zone(boss)
    local zone = utils.get_zone()
    if boss.run_type == "sigil" then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    return zone:match(boss.zone_prefix) ~= nil
end

local function chest_visible()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return false end
    for _, a in pairs(actors) do
        local ok, inter = pcall(function() return a:is_interactable() end)
        if ok and inter then
            local name = a:get_skin_name()
            if type(name) == "string" then
                if name:find("^EGB_Chest") or name:find("^Boss_WT_Belial_") or name:find("^Chest_Boss") then
                    return true
                end
            end
        end
    end
    return false
end

-- -------------------------------------------------------
-- Sigil helpers
-- -------------------------------------------------------
local SIGIL_SNO = 2565553

local function find_sigil_for_boss(boss_id)
    local lp = get_local_player()
    if not lp then return nil end
    local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)
    if not ok or type(keys) ~= "table" then return nil end

    local mats = require "core.materials"
    local first_sigil = nil

    for _, item in ipairs(keys) do
        local ok_sno, sno = pcall(function() return item:get_sno_id() end)
        if ok_sno and sno == SIGIL_SNO then
            if not first_sigil then first_sigil = item end

            local ok_d, display = pcall(function() return item:get_display_name() end)
            if ok_d and display then
                local mapped = mats.boss_from_display(display)
                if mapped == boss_id then
                    return item
                end
            end
        end
    end

    return first_sigil
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE         = "IDLE",
    USE_SIGIL    = "USE_SIGIL",    -- activate sigil item, confirm dialog
    MAP_NAV      = "MAP_NAV",      -- teleport via map_nav.lua
    PATHWALKING  = "PATHWALKING",  -- Batmobile: retry navigate_long_path  |  pathwalker: walk path file
    LONG_PATHING = "LONG_PATHING", -- Batmobile driving navigation to altar
    TRAVERSAL    = "TRAVERSAL",    -- navigating to/crossing a traversal gizmo blocking the path
    WALKING      = "WALKING",      -- walk to dungeon entrance portal
    ENTERING     = "ENTERING",     -- interact with portal to enter
    WAIT_EXIT    = "WAIT_EXIT",    -- waiting to leave completed sigil dungeon
}

local MAX_LONG_PATH_RETRIES   = 8
local LONG_PATH_WAIT_FRAMES   = 150   -- frames to wait between retries (~5s at 30fps); frame-counted
                                      -- to avoid game-time freeze during blocking pathfind calls
local TRAVERSAL_TRIGGER       = 1     -- long-path failures before searching for a traversal
local TRAVERSAL_NAV_TIMEOUT   = 20.0  -- seconds before giving up on crossing a traversal
local MAX_TRAVERSAL_ATTEMPTS  = 3     -- give up entirely after this many failed traversal attempts

local T_CONFIRM      = 0.8    -- wait after use_item before confirming
local T_SIGIL_SETTLE = 10.0   -- wait after arriving in Cerrigar before activating sigil
local T_SETTLE       = 2.5
local T_ENTER        = 15.0

local nav = {
    state               = STATE.IDLE,
    target_boss         = nil,
    phase_start         = -999,
    attempts            = 0,
    max_attempts        = 5,
    last_enter_try      = 0,
    path_exhausted      = false,
    long_path_goal      = nil,    -- destination vec3 for the current LONG_PATHING phase
    long_path_retries     = 0,      -- consecutive failed navigate_long_path attempts
    long_path_wait_frames = 0,      -- frame cap safety net while exploring between retries
    long_path_explore_start = nil,  -- player position when exploration began (for distance check)
    -- traversal fields
    trav_target_pos     = nil,    -- vec3 position of the traversal gizmo
    trav_start_pos      = nil,    -- player position when we started approaching traversal
    trav_got_close      = false,  -- true once player was within 3m of traversal
    trav_attempts       = 0,      -- how many traversal crossing attempts this run
}

-- Tracks when we first arrived in Cerrigar for the sigil settle timer
local _sigil_settle_t = -999

local function now() return get_time_since_inject() end
local function set_state(s) nav.state = s; nav.phase_start = now() end

local function reset_nav()
    nav.state              = STATE.IDLE
    nav.target_boss        = nil
    nav.phase_start        = now()
    nav.attempts           = 0
    nav.path_exhausted     = false
    nav.long_path_goal          = nil
    nav.long_path_retries       = 0
    nav.long_path_wait_frames   = 0
    nav.long_path_explore_start = nil
    nav.trav_target_pos    = nil
    nav.trav_start_pos     = nil
    nav.trav_got_close     = false
    nav.trav_attempts      = 0
    map_nav.reset()
    pathwalker.stop_walking()
    if BatmobilePlugin then
        BatmobilePlugin.stop_long_path(plugin_label)
        BatmobilePlugin.clear_target(plugin_label)
    end
end

-- Returns the best-known walkable position near the altar for this boss.
-- Tries path-file endpoints first (recorded in-game positions), then the
-- enums seed, then nil if nothing is available.
local function get_altar_approach_target(boss)
    local variants = load_variants(boss.id)
    local path = pick_best_path(variants)
    if path and #path > 0 then
        return path[#path], "path endpoint"
    end
    local seed = enums.positions.getBossRoomPosition(boss.zone_prefix)
    if seed:x() ~= 0 or seed:y() ~= 0 then
        return seed, "boss room seed"
    end
    return nil, nil
end

-- -------------------------------------------------------
-- shouldExecute
-- -------------------------------------------------------
local task = { name = "Navigate to Boss" }

function task.reset()
    reset_nav()
end

function task.shouldExecute()
    local boss = rotation.current()
    -- If rotation is done and we're not in Cerrigar yet, run so Execute can teleport us out
    if rotation.is_done() then
        return utils.get_zone() ~= settings.town_zone
    end
    if not boss then return false end

    if tracker.just_revived then
        nav.path_exhausted   = false
        tracker.just_revived = false
        console.print("[Reaper] Post-revive: re-enabling path walk.")
    end

    -- Reset settle timer whenever we leave Cerrigar (entered dungeon or zone changed)
    if utils.get_zone() ~= settings.town_zone then
        _sigil_settle_t = -999
    end

    -- If we left the dungeon while mid-navigation, reset and yield this tick
    -- so other tasks (sigil_complete WAIT_TOWN) can run first.
    local active_nav = nav.state == STATE.PATHWALKING
                    or nav.state == STATE.LONG_PATHING
    if active_nav and not in_target_zone(boss) then
        console.print("[Reaper] Left target zone mid-nav — resetting.")
        reset_nav()
        return false
    end

    -- Always run while map_nav is active
    if nav.state == STATE.MAP_NAV then return true end

    -- In Cerrigar between sigil runs: yield to sigil_complete until the run
    -- is counted (sigil_entry_t reset to -999), then apply a settle delay.
    if nav.state == STATE.IDLE and boss.run_type == "sigil"
            and utils.get_zone() == settings.town_zone then
        -- sigil_entry_t > 0 means we're still in the old run; yield to sigil_complete
        if tracker.sigil_entry_t > 0 then return false end
        -- Run is reset. Start (or check) the settle timer.
        if _sigil_settle_t < 0 then
            _sigil_settle_t = now()
            console.print(string.format("[Reaper] Run reset — waiting %.0fs before sigil.", T_SIGIL_SETTLE))
        end
        if (now() - _sigil_settle_t) < T_SIGIL_SETTLE then return false end
        -- Settle complete — fall through to Execute to activate the sigil
    end

    -- Block navigation only while INSIDE the boss zone with altar already activated.
    -- If we've left the zone (e.g. Alfred restocked mid-run), allow navigating back
    -- so the run can be completed (EGB chest opened, reset_run called).
    if tracker.altar_activated and in_target_zone(boss) then return false end
    if in_target_zone(boss) and chest_visible() then return false end
    -- Altar visible inside the zone: reset any active navigation and yield to interact_altar.
    -- interact_altar handles both movement to the altar and interaction; no need to navigate.
    local _altar = in_target_zone(boss) and utils.get_altar()
    if _altar then
        if nav.state ~= STATE.IDLE then reset_nav() end
        return false
    end

    if in_target_zone(boss) then
        -- path_exhausted: only truly done if altar is visible; otherwise restart
        if nav.path_exhausted then
            nav.path_exhausted = false  -- altar not found yet — try navigating again
        end

        if nav.state == STATE.IDLE or nav.state == STATE.PATHWALKING
                or nav.state == STATE.LONG_PATHING or nav.state == STATE.TRAVERSAL then
            -- After 60s in a sigil dungeon with no enemies, yield to sigil_complete
            if boss.run_type == "sigil" and tracker.sigil_entry_t > 0
                    and (now() - tracker.sigil_entry_t) >= 60.0 then
                local has_enemy = utils.get_closest_enemy() ~= nil
                               or utils.get_suppressor() ~= nil
                if not has_enemy then
                    return false  -- let sigil_complete handle the exit
                end
            end
            return true
        end

        if nav.state ~= STATE.IDLE then
            -- Arrived via MAP_NAV/WALKING/ENTERING — reset and record entry time
            local fresh = nav.state == STATE.MAP_NAV
                       or nav.state == STATE.WALKING
                       or nav.state == STATE.ENTERING
            reset_nav()
            if fresh and boss.run_type == "sigil" then
                tracker.sigil_entry_t = now()
            end
        end
        return false
    end

    if nav.state ~= STATE.IDLE then return true end
    return true
end

-- -------------------------------------------------------
-- Execute
-- -------------------------------------------------------
function task.Execute()
    -- Rotation finished — get back to Cerrigar so main.lua can disable cleanly
    if rotation.is_done() then
        if utils.get_zone() ~= settings.town_zone then
            if nav.state ~= STATE.WAIT_EXIT then
                console.print("[Reaper] Rotation complete — returning to " .. settings.town_zone .. ".")
                teleport_to_waypoint(settings.town_waypoint)
                set_state(STATE.WAIT_EXIT)
            end
        end
        return
    end

    local boss = rotation.current()
    if not boss then return end
    local t = now()

    -- ---- IDLE ----
    if nav.state == STATE.IDLE then
        nav.target_boss    = boss
        nav.attempts       = 0
        nav.path_exhausted = false

        if in_target_zone(boss) then
            if utils.get_altar() ~= nil then reset_nav(); return end
            -- Stale sigil dungeon: sigil_entry_t expired with no altar found
            if boss.run_type == "sigil" and tracker.sigil_entry_t > 0
                    and (now() - tracker.sigil_entry_t) > 60.0 then
                console.print("[Reaper] Sigil zone with no altar and entry expired — stale dungeon, teleporting out.")
                teleport_to_waypoint(settings.town_waypoint)
                set_state(STATE.WAIT_EXIT)
                return
            end
            -- Use Batmobile to navigate to the altar area
            console.print("[Reaper] In zone — using Batmobile to navigate to altar area.")
            if BatmobilePlugin then
                BatmobilePlugin.reset(plugin_label)
                BatmobilePlugin.resume(plugin_label)
            end
            set_state(STATE.PATHWALKING)
            return
        end

        -- Sigil run: shouldExecute already enforced the settle delay — just activate
        if boss.run_type == "sigil" then
            if utils.get_zone() ~= settings.town_zone then return end
            local sigil = find_sigil_for_boss(boss.id)
            if not sigil then
                console.print("[Reaper] No sigil found for " .. boss.label .. " — skipping.")
                rotation.advance()
                reset_nav()
                return
            end
            console.print("[Reaper] Using sigil for " .. boss.label)
            _sigil_settle_t = -999  -- clear so next return to Cerrigar gets a fresh settle
            tracker.sigil_entry_t = now()
            local ok, err = pcall(use_item, sigil)
            if not ok then
                console.print("[Reaper] use_item failed: " .. tostring(err))
                tracker.sigil_entry_t = -999
                reset_nav()
                return
            end
            set_state(STATE.USE_SIGIL)
            return
        end

        -- Material run: teleport via map_nav
        map_nav.start(boss.id, boss.zone_prefix, false)
        set_state(STATE.MAP_NAV)
        return
    end

    -- ---- USE_SIGIL: confirm dialog then navigate to boss dungeon ----
    if nav.state == STATE.USE_SIGIL then
        if (t - nav.phase_start) >= T_CONFIRM then
            console.print("[Reaper] Confirming sigil notification...")
            utility.confirm_sigil_notification()
            map_nav.start(boss.id, boss.zone_prefix, true)
            set_state(STATE.MAP_NAV)
        end
        return
    end

    -- ---- MAP_NAV: drive teleport state machine ----
    if nav.state == STATE.MAP_NAV then
        map_nav.update()

        if map_nav.is_done() or in_target_zone(boss) then
            console.print("[Reaper] Arrived: " .. utils.get_zone())
            nav.attempts = 0
            if boss.run_type == "sigil" then
                tracker.sigil_entry_t = now()
            end
            map_nav.reset()
            if BatmobilePlugin then
                BatmobilePlugin.stop_long_path(plugin_label)
                BatmobilePlugin.reset(plugin_label)
                if BatmobilePlugin.clear_traversal_blacklist then
                    BatmobilePlugin.clear_traversal_blacklist(plugin_label)
                end
                BatmobilePlugin.resume(plugin_label)
            end
            set_state(STATE.PATHWALKING)
            return
        end

        if not map_nav.is_active() then
            nav.attempts = nav.attempts + 1
            console.print(string.format("[Reaper] Map nav attempt %d/%d failed — retrying.",
                nav.attempts, nav.max_attempts))
            if nav.attempts >= nav.max_attempts then
                console.print("[Reaper] Giving up after " .. nav.max_attempts .. " attempts.")
                reset_nav(); return
            end
            map_nav.start(boss.id, boss.zone_prefix, boss.run_type == "sigil")
        end
        return
    end

    -- ---- PATHWALKING ----
    if nav.state == STATE.PATHWALKING then
        local altar = utils.get_altar()
        if altar and utils.distance_to(altar) <= 5.0 then
            console.print("[Reaper] Altar in range — navigation done.")
            reset_nav()
            return
        end

        if settings.use_batmobile then
            -- ---- Batmobile-ONLY branch ----
            -- Primary nav: navigate_long_path (uncapped A* to altar/seed).
            -- On failure: Batmobile standard nav (set_target/update/move) walks us
            -- closer for LONG_PATH_WAIT_FRAMES frames, then long path is retried.
            -- pathfinder.request_move is never used — it can't route around walls.

            if not BatmobilePlugin then
                console.print("[Reaper] BatmobilePlugin not available — cannot navigate.")
                return
            end

            -- Determine target: visible altar first, then path-file endpoint or seed
            local target, target_label
            if altar then
                target       = altar:get_position()
                target_label = "altar"
            else
                target, target_label = get_altar_approach_target(boss)
            end

            if not target then
                console.print(string.format(
                    "[Reaper] No known position for %s — check path files / enums seed.",
                    boss.label))
                -- Nothing we can do; wait and re-check in case altar spawns nearby
                return
            end

            -- If we're already standing at the target and the altar isn't visible,
            -- the altar was activated and is now gone (e.g. Alfred reset tracker state
            -- mid-run). Stop navigating — open_chest / sigil_complete will take over.
            if utils.distance_to(target) <= 8.0 and not altar then
                console.print("[Reaper] Already at altar position, no altar visible — yielding.")
                reset_nav()
                return
            end

            -- Frame-count rate-limit: navigate_long_path blocks the game loop while
            -- computing, so get_time_since_inject() does NOT advance during the call.
            -- Counting real game frames (each Execute() call = one frame) guarantees
            -- the player actually moves and loads navmesh tiles between retries.
            if nav.long_path_wait_frames > 0 then
                nav.long_path_wait_frames = nav.long_path_wait_frames - 1
                local pp = get_player_position()
                local moved = nav.long_path_explore_start
                              and pp:dist_to(nav.long_path_explore_start) or 0
                if moved >= 30 then
                    -- Moved far enough — stop exploring and retry long path now.
                    console.print(string.format(
                        "[Reaper] Explored %.1f units — retrying navigate_long_path.", moved))
                    nav.long_path_wait_frames   = 0
                    nav.long_path_explore_start = nil
                    BatmobilePlugin.clear_target(plugin_label)
                    return
                end
                -- Still exploring: free BFS, no custom target so Batmobile expands
                -- the navmesh frontier without thrashing on an unreachable destination.
                BatmobilePlugin.clear_target(plugin_label)
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
                return
            end

            -- Debug: show exactly what we're trying to path to
            local pp = get_player_position()
            nav.long_path_retries  = nav.long_path_retries + 1
            console.print(string.format(
                "[Reaper] navigate_long_path #%d → %s  target=(%.1f, %.1f)  player=(%.1f, %.1f)  dist=%.1f",
                nav.long_path_retries, target_label,
                target:x(), target:y(),
                pp:x(), pp:y(),
                utils.distance_to(target)))

            local ok = BatmobilePlugin.navigate_long_path(plugin_label, target)
            if ok then
                nav.long_path_goal          = target
                nav.long_path_retries       = 0
                nav.long_path_wait_frames   = 0
                nav.long_path_explore_start = nil
                set_state(STATE.LONG_PATHING)
            else
                console.print(string.format(
                    "[Reaper] Long path failed (attempt %d) — retrying after %d frames.",
                    nav.long_path_retries, LONG_PATH_WAIT_FRAMES))
                nav.long_path_wait_frames   = LONG_PATH_WAIT_FRAMES
                nav.long_path_explore_start = get_player_position()
                BatmobilePlugin.clear_target(plugin_label)

                -- After TRAVERSAL_TRIGGER consecutive failures, look for a traversal blocking us
                if nav.long_path_retries >= TRAVERSAL_TRIGGER then
                    if nav.trav_attempts >= MAX_TRAVERSAL_ATTEMPTS then
                        console.print("[Reaper] Traversal attempts exhausted — giving up on this boss.")
                        reset_nav()
                        return
                    end
                    local pp2 = get_player_position()
                    local pp2_z = pp2:z()
                    local actors = actors_manager.get_all_actors()
                    local nearest_trav, nearest_dist = nil, math.huge
                    if type(actors) == "table" then
                        for _, actor in pairs(actors) do
                            local ok_name, name = pcall(function() return actor:get_skin_name() end)
                            if ok_name and type(name) == "string" and name:match("[Tt]raversal_Gizmo") then
                                local ok_pos, apos = pcall(function() return actor:get_position() end)
                                if ok_pos and math.abs(apos:z() - pp2_z) <= 3 then
                                    local d = utils.distance_to(apos)
                                    if d < nearest_dist then
                                        nearest_trav = actor
                                        nearest_dist = d
                                    end
                                end
                            end
                        end
                    end
                    if nearest_trav then
                        console.print(string.format(
                            "[Reaper] Found traversal at dist=%.1f — switching to TRAVERSAL state.",
                            nearest_dist))
                        nav.trav_target_pos         = nearest_trav:get_position()
                        nav.trav_start_pos          = pp2
                        nav.trav_got_close          = false
                        nav.trav_attempts           = nav.trav_attempts + 1
                        nav.long_path_retries       = 0
                        nav.long_path_wait_frames   = 0
                        nav.long_path_explore_start = nil
                        if BatmobilePlugin then
                            BatmobilePlugin.clear_target(plugin_label)
                        end
                        set_state(STATE.TRAVERSAL)
                    end
                end

            end
            return
        end

        -- ---- Path-file branch (use_batmobile = false) ----
        if not pathwalker.is_walking then
            local variants = load_variants(boss.id)
            local path = pick_best_path(variants)
            if path then
                pathwalker.start_walking_path_with_points(path, boss.id)
            else
                console.print("[Reaper] No path variants found for " .. boss.id .. " — skipping.")
                nav.path_exhausted = true
                reset_nav()
                return
            end
        end
        if pathwalker.is_path_completed() then
            console.print("[Reaper] Path complete.")
            pathwalker.stop_walking()
            reset_nav()
            return
        end
        pathwalker.update_path_walking()
        return
    end

    -- ---- LONG_PATHING: Batmobile drives navigation; we wait for arrival ----
    -- When use_batmobile=true this is the ONLY navigation.  All failure paths
    -- return to PATHWALKING which retries navigate_long_path.  No other nav runs.
    if nav.state == STATE.LONG_PATHING then
        local altar = utils.get_altar()

        -- Primary success: altar reached
        if altar and utils.distance_to(altar) <= 5.0 then
            console.print("[Reaper] Altar in range — long path done.")
            reset_nav()
            return
        end

        -- Arrival detection: is_long_path_navigating() never auto-clears (manual flag),
        -- so detect completion by proximity to the stored destination.
        local at_goal = nav.long_path_goal
                     and utils.distance_to(nav.long_path_goal) <= 8.0

        if at_goal then
            if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
            if altar then
                -- Visible but not yet in interact range — re-fire directly to altar
                console.print(string.format(
                    "[Reaper] At goal, altar at dist=%.1f — re-firing to altar.",
                    utils.distance_to(altar)))
                local ok = BatmobilePlugin and BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                if ok then
                    nav.long_path_goal = altar:get_position()
                    nav.phase_start    = now()
                else
                    -- Re-fire failed: back to PATHWALKING to retry with delay
                    console.print("[Reaper] Re-fire to altar failed — returning to PATHWALKING.")
                    set_state(STATE.PATHWALKING)
                end
            else
                -- Arrived at known position but altar not visible — retry from PATHWALKING
                console.print("[Reaper] At goal, altar not visible — returning to PATHWALKING.")
                set_state(STATE.PATHWALKING)
            end
            return
        end

        -- Fallback: long path was stopped externally or ended without reaching goal
        if not BatmobilePlugin or not BatmobilePlugin.is_long_path_navigating() then
            if altar then
                local dist = utils.distance_to(altar)
                if dist <= 5.0 then
                    reset_nav()
                    return
                end
                console.print(string.format(
                    "[Reaper] Long path ended early, altar dist=%.1f — re-firing.",
                    dist))
                local ok = BatmobilePlugin and BatmobilePlugin.navigate_long_path(plugin_label, altar:get_position())
                if ok then
                    nav.long_path_goal = altar:get_position()
                    nav.phase_start    = now()
                else
                    console.print("[Reaper] Re-fire failed — returning to PATHWALKING.")
                    set_state(STATE.PATHWALKING)
                end
            else
                console.print("[Reaper] Long path ended, no altar — returning to PATHWALKING.")
                set_state(STATE.PATHWALKING)
            end
            return
        end

        -- Timeout guard (90s)
        if (now() - nav.phase_start) > 90.0 then
            console.print("[Reaper] Long path timeout (90s) — returning to PATHWALKING.")
            if BatmobilePlugin then BatmobilePlugin.stop_long_path(plugin_label) end
            set_state(STATE.PATHWALKING)
        end
        return
    end

    -- ---- TRAVERSAL: cross a gizmo blocking navigate_long_path ----
    if nav.state == STATE.TRAVERSAL then
        local pp = get_player_position()
        local tgt = nav.trav_target_pos
        if not tgt then
            -- No target stored — bail back to PATHWALKING
            set_state(STATE.PATHWALKING)
            return
        end

        local dist = utils.distance_to(tgt)

        -- Track once we're within interaction range
        if not nav.trav_got_close and dist < 3 then
            nav.trav_got_close = true
        end

        -- Crossing detection: Z-height change (ladder) OR teleport away after getting close (portal)
        local z_crossed     = nav.trav_start_pos and math.abs(pp:z() - nav.trav_start_pos:z()) > 2
        local portal_crossed = nav.trav_got_close and dist > 20
        if z_crossed or portal_crossed then
            console.print(string.format(
                "[Reaper] Traversal crossed (%s) — resuming long-path navigation.",
                z_crossed and "z-change" or "portal"))
            nav.trav_target_pos         = nil
            nav.trav_start_pos          = nil
            nav.trav_got_close          = false
            nav.long_path_retries       = 0
            nav.long_path_wait_frames   = 0
            nav.long_path_explore_start = nil
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            set_state(STATE.PATHWALKING)
            return
        end

        -- Timeout: give up on this traversal
        if (t - nav.phase_start) > TRAVERSAL_NAV_TIMEOUT then
            console.print(string.format(
                "[Reaper] Traversal timeout (%.0fs) — returning to PATHWALKING.",
                TRAVERSAL_NAV_TIMEOUT))
            nav.trav_target_pos         = nil
            nav.trav_start_pos          = nil
            nav.trav_got_close          = false
            nav.long_path_retries       = 0
            nav.long_path_wait_frames   = 0
            nav.long_path_explore_start = nil
            if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
            set_state(STATE.PATHWALKING)
            return
        end

        -- Navigate toward the traversal gizmo
        if BatmobilePlugin then
            BatmobilePlugin.set_target(plugin_label, tgt)
            BatmobilePlugin.update(plugin_label)
            BatmobilePlugin.move(plugin_label)
        else
            pathfinder.request_move(tgt)
        end
        return
    end

    -- ---- WALKING: walk to dungeon entrance ----
    if nav.state == STATE.WALKING then
        if in_target_zone(boss) and not utils.get_dungeon_entrance() then
            reset_nav(); return
        end
        if (t - nav.phase_start) < T_SETTLE then return end

        local entrance = utils.get_dungeon_entrance()
        if entrance then
            if utils.distance_to(entrance) <= 3.5 then
                if BatmobilePlugin then BatmobilePlugin.clear_target(plugin_label) end
                nav.last_enter_try = 0
                set_state(STATE.ENTERING)
            else
                if BatmobilePlugin then
                    BatmobilePlugin.set_target(plugin_label, entrance)
                    BatmobilePlugin.update(plugin_label)
                    BatmobilePlugin.move(plugin_label)
                else
                    pathfinder.request_move(entrance:get_position())
                end
            end
        else
            local seed = enums.positions.getBossRoomPosition(boss.zone_prefix)
            if utils.distance_to(seed) > 5.0 then
                pathfinder.request_move(seed)
            end
        end
        return
    end

    -- ---- ENTERING ----
    if nav.state == STATE.ENTERING then
        if in_target_zone(boss) and not utils.get_dungeon_entrance() then
            console.print("[Reaper] Entered " .. utils.get_zone())
            reset_nav(); return
        end
        if (t - nav.phase_start) > T_ENTER then reset_nav(); return end
        if (t - nav.last_enter_try) >= 1.5 then
            nav.last_enter_try = t
            local entrance = utils.get_dungeon_entrance()
            if entrance then
                loot_manager.interact_with_object(entrance)
            else
                set_state(STATE.WALKING)
            end
        end
        return
    end

    -- ---- WAIT_EXIT: waiting to leave a completed sigil dungeon ----
    if nav.state == STATE.WAIT_EXIT then
        if not in_target_zone(boss) then
            console.print("[Reaper] Left completed dungeon — restarting run.")
            reset_nav()
            return
        end
        if (now() - nav.phase_start) > 20.0 then
            console.print("[Reaper] WAIT_EXIT timeout — retrying teleport.")
            teleport_to_waypoint(settings.town_waypoint)
            nav.phase_start = now()
        end
        return
    end
end

return task
