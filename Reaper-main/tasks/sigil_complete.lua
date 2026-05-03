-- ============================================================
--  Reaper - tasks/sigil_complete.lua
--
--  Detects when a sigil run is complete (no enemies for 5s) then:
--    1. Calls rotation.consume_run() + tracker.reset_run()
--    2. Teleports back to Cerrigar
--    3. Waits to land (navigate_to_boss handles next sigil activation)
--
--  The Doom/seasonal "theme" chest was removed from D4 (2026-05-03 patch);
--  enemy-cleared is the sole completion signal now.
-- ============================================================

local utils    = require "core.utils"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"
local settings = require "core.settings"

-- Home town now resolved per pulse from settings.town_zone / settings.town_waypoint.
local NO_ENEMY_TIMEOUT = 5.0   -- seconds with no enemies before declaring run complete

local STATE = {
    IDLE         = "IDLE",
    WATCHING     = "WATCHING",   -- altar activated, watching for enemies to clear
    TELEPORTING  = "TELEPORTING",
    WAIT_TOWN    = "WAIT_TOWN",
    DONE         = "DONE",
}

local s = {
    state        = STATE.IDLE,
    t            = -999,
    last_enemy_t = -999,
    last_log_t   = -999,
}

local function now()         return get_time_since_inject() end
local function set_state(st) s.state = st; s.t = now() end

local function in_sigil_zone()
    local boss = rotation.current()
    if not boss or boss.run_type ~= "sigil" then return false end
    local zone = utils.get_zone()
    return zone:find("BloodyLair") ~= nil
        or zone:find("S12_Boss")   ~= nil
        or zone:find("Boss_WT")    ~= nil
        or zone:find("Boss_Kehj")  ~= nil
end

local task = { name = "Sigil Complete" }

function task.shouldExecute()
    local boss = rotation.current()
    if not boss or boss.run_type ~= "sigil" then return false end

    -- Keep running mid-sequence
    if s.state ~= STATE.IDLE then return true end

    -- Only start watching once altar is activated and we're in the zone,
    -- or if sigil_entry_t is set and 60s have passed (stale dungeon fallback).
    if tracker.altar_activated and in_sigil_zone() then return true end
    if tracker.sigil_entry_t > 0
            and (now() - tracker.sigil_entry_t) >= 60.0
            and in_sigil_zone() then
        return true
    end
    return false
end

function task.Execute()
    local t = now()

    -- ---- IDLE: start watching ----
    if s.state == STATE.IDLE then
        s.last_enemy_t = t
        set_state(STATE.WATCHING)
        console.print("[Reaper] Sigil run in progress — watching for clear.")
        return
    end

    -- ---- WATCHING: wait for no enemies ----
    if s.state == STATE.WATCHING then
        if not in_sigil_zone() then
            set_state(STATE.IDLE)
            return
        end

        local has_enemy = utils.get_closest_enemy() ~= nil
                       or utils.get_suppressor() ~= nil

        if has_enemy then
            s.last_enemy_t = t  -- reset timer whenever enemies are present
            s.last_log_t   = -999  -- allow immediate log next time enemies are gone
            return
        end

        local idle_time = t - s.last_enemy_t

        -- Log once every 5s so console isn't spammed
        if (t - s.last_log_t) >= 5.0 then
            console.print(string.format("[Reaper] No enemies for %.0fs / %ds",
                idle_time, NO_ENEMY_TIMEOUT))
            s.last_log_t = t
        end

        if idle_time >= NO_ENEMY_TIMEOUT then
            console.print("[Reaper] Sigil run complete — teleporting to " .. settings.town_zone .. ".")
            teleport_to_waypoint(settings.town_waypoint)
            set_state(STATE.TELEPORTING)
        end
        return
    end

    -- ---- TELEPORTING: brief wait for teleport animation ----
    if s.state == STATE.TELEPORTING then
        if (t - s.t) >= 1.5 then
            set_state(STATE.WAIT_TOWN)
        end
        return
    end

    -- ---- WAIT_TOWN: wait to land in the home town, then count the run ----
    if s.state == STATE.WAIT_TOWN then
        if utils.player_in_zone(settings.town_zone) then
            if (t - s.t) >= 2.0 then
                console.print("[Reaper] Back in " .. settings.town_zone .. " — counting run.")
                rotation.consume_run()
                tracker.reset_run()
                set_state(STATE.IDLE)
            end
            return
        end
        -- Timeout — retry teleport
        if (t - s.t) >= 20.0 then
            console.print("[Reaper] Town wait timeout — retrying teleport.")
            teleport_to_waypoint(settings.town_waypoint)
            set_state(STATE.TELEPORTING)
        end
        return
    end
end

return task
