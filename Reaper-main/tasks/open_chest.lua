-- ============================================================
--  Reaper - tasks/open_chest.lua
--
--  Phases:
--    MAIN          → walk to EGB/Belial chest, interact
--    WAIT_GONE     → wait for main chest to despawn (up to WAIT_GONE_SECS)
--                    if it never despawns = out of materials → stop
--    WAIT_COMPLETE → brief pause to loot, then consume_run + reset for next cycle
--
--  Doom/seasonal "theme" chest was removed from D4 (2026-05-03 patch);
--  the entire THEME phase and S12_Prop_Theme_Chest_* logic is gone. For
--  material runs the EGB/boss chest IS the run-completion signal. For sigil
--  runs (no EGB chest) tasks/sigil_complete.lua drives the wrap-up via
--  enemy-cleared detection.
-- ============================================================

local utils     = require "core.utils"
local tracker   = require "core.tracker"
local rotation  = require "core.boss_rotation"
local enums     = require "data.enums"
local materials = require "core.materials"

-- ---- Config ----
local CHEST_INTERACT_COOLDOWN = 0.5  -- min seconds between EGB chest interact attempts
local WAIT_GONE_SECS          = 10   -- if chest still here after this → out of mats
local WAIT_COMPLETE_SECS      = 3    -- pause after chest before next run
local OUT_OF_MATS_RETRIES     = 3    -- times chest can fail to despawn before stopping

-- ---- State ----
local phase              = "IDLE"
local phase_start        = 0
local last_interact_time = 0
local last_chest_pos     = nil
local no_despawn_count   = 0    -- counts consecutive failures to despawn

local function set_phase(p)
    phase       = p
    phase_start = os.time()
    console.print("[Chest] Phase: " .. p)
end

local function phase_elapsed()
    return os.time() - phase_start
end

local function cooldown_ok()
    return (get_time_since_inject() - last_interact_time) >= CHEST_INTERACT_COOLDOWN
end

-- ---- Actor finders ----
local function _interactable(a)
    if not a then return false end
    local ok, v = pcall(function() return a:is_interactable() end)
    return ok and v == true
end

local function find_egb_chest()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    local best, best_dist = nil, math.huge
    local lp = get_local_player()
    local pp = lp and lp:get_position()
    for _, a in pairs(actors) do
        if _interactable(a) then
            local n = a:get_skin_name()
            if type(n) == "string" then
                if n:find("^EGB_Chest") or n:find("^Boss_WT_Belial_") or n:find("^Chest_Boss") then
                    local d = pp and pp:dist_to(a:get_position()) or 0
                    if d < best_dist then best = a; best_dist = d end
                end
            end
        end
    end
    return best
end

local function in_target_boss_zone()
    local boss = rotation.current()
    if not boss then return false end
    local zone = utils.get_zone()
    if boss.run_type == "sigil" then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    return zone:match(boss.zone_prefix) ~= nil
end

-- ---- Stuck helpers ----
local last_pos = nil
local last_move_t = 0

local function check_stuck()
    local pos = get_player_position()
    local t   = os.time()
    if last_pos and utils.distance_to(last_pos) < 0.1 then
        if t - last_move_t > 20 then
            if t - last_move_t >= 30 then last_move_t = t; return true end
        end
    else
        last_move_t = t
    end
    last_pos = pos
    return false
end

local function try_movement_spell(target)
    local lp = get_local_player()
    if not lp then return end
    for _, sid in ipairs({288106,358761,355606,1663206,1871821,337031}) do
        if lp:is_spell_ready(sid) then
            if cast_spell.position(sid, target, 3.0) then return end
        end
    end
end

-- -------------------------------------------------------
local task = { name = "Open Chest" }

function task.shouldExecute()
    if not in_target_boss_zone() then
        if phase ~= "IDLE" then
            set_phase("IDLE")
            no_despawn_count = 0
        end
        return false
    end
    -- Active mid-sequence
    if phase == "WAIT_GONE" or phase == "WAIT_COMPLETE" then
        return true
    end
    -- Sigil runs have no EGB chest and (with the doom chest removed) no chest
    -- at all — sigil_complete drives wrap-up via enemy-cleared detection.
    local boss = rotation.current()
    if boss and boss.run_type == "sigil" then
        return false
    end
    -- Trigger on EGB/boss chest visibility
    return find_egb_chest() ~= nil
end

function task.Execute()
    -- Stuck recovery
    if check_stuck() then
        local pos = get_player_position()
        if pos then
            try_movement_spell(pos)
            pathfinder.force_move_raw(pos)
        end
        return
    end

    -- ---- IDLE / MAIN: find and open the EGB chest ----
    if phase == "IDLE" or phase == "MAIN" then
        local chest = find_egb_chest()
        if not chest then return end

        local dist = utils.distance_to(chest:get_position())
        if dist > 2.5 then
            pathfinder.request_move(chest:get_position())
            return
        end

        if not cooldown_ok() then return end

        interact_object(chest)
        last_interact_time = get_time_since_inject()
        tracker.chest_opened_time = os.time()
        last_chest_pos = chest:get_position()

        -- Signal Belial chest UI task
        local n = chest:get_skin_name()
        if type(n) == "string" and n:find("^Boss_WT_Belial_") then
            tracker.belial_chest_interacted = true
            console.print("[Chest] Belial chest interacted – signalling UI task.")
        end

        set_phase("WAIT_GONE")
        return
    end

    -- ---- WAIT_GONE: wait for chest to despawn ----
    if phase == "WAIT_GONE" then
        local chest = find_egb_chest()

        if chest == nil then
            -- Chest gone – run is complete (no theme chest to chase any more).
            no_despawn_count = 0
            set_phase("WAIT_COMPLETE")
            return
        end

        if phase_elapsed() < WAIT_GONE_SECS then return end

        -- Chest still here after timeout
        no_despawn_count = no_despawn_count + 1
        console.print(string.format("[Chest] Chest didn't despawn (%d/%d) – out of materials?",
            no_despawn_count, OUT_OF_MATS_RETRIES))

        if no_despawn_count >= OUT_OF_MATS_RETRIES then
            no_despawn_count = 0
            local boss = rotation.current()

            -- Re-verify actual inventory before declaring out of materials.
            -- Chest may have failed to despawn due to lag or a missed interact.
            -- BUT: external (orchestrator-injected) rotations are explicit
            -- one-shots — never extend the run from inventory, even if the
            -- chest is misbehaving. Otherwise the altar can re-fire.
            if boss and boss.run_type == "material" and not rotation.external then
                local actual = materials.scan()[boss.id] or 0
                if actual > 0 then
                    console.print(string.format(
                        "[Chest] Chest still present but %d %s material(s) in inventory — retrying open.",
                        actual, boss.label))
                    boss.runs_remaining = actual
                    set_phase("MAIN")
                    return
                end
            end

            console.print("[Chest] Chest didn't despawn after retries — out of summoning materials, skipping.")
            if boss then boss.runs_remaining = 0 end
            rotation.advance()
            tracker.reset_run()
            set_phase("IDLE")
        else
            -- Try interacting again
            if cooldown_ok() then
                interact_object(chest)
                last_interact_time = get_time_since_inject()
            end
            set_phase("WAIT_GONE")
        end
        return
    end

    -- ---- WAIT_COMPLETE: brief pause to loot, then start next run ----
    if phase == "WAIT_COMPLETE" then
        if phase_elapsed() < WAIT_COMPLETE_SECS then return end
        local boss = rotation.current()
        console.print(string.format("[Chest] Run complete — boss=%s  run_type=%s",
            tostring(boss and boss.id), tostring(boss and boss.run_type)))
        rotation.consume_run()
        tracker.reset_run()
        set_phase("IDLE")
        last_chest_pos = nil
        return
    end
end

return task
