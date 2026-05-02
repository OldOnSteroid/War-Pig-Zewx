-- ============================================================
--  Reaper - tasks/dungeon_reset.lua
--
--  After every N completed runs (configurable), calls
--  reset_all_dungeons() then navigates back to the current
--  boss to start fresh.
--
--  Why: some dungeons accumulate temporary state or actors
--  over many runs. Periodic resets keep things clean.
-- ============================================================

local utils    = require "core.utils"
local settings = require "core.settings"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"

local STATE = {
    IDLE      = "IDLE",
    RESETTING = "RESETTING",
    WAITING   = "WAITING",
}

local state       = STATE.IDLE
local state_start = 0
local runs_at_last_reset = 0

local function now() return get_time_since_inject() end

local task = { name = "Dungeon Reset" }

function task.shouldExecute()
    -- Feature disabled
    if not settings.dungeon_reset_enabled then return false end
    if settings.dungeon_reset_interval <= 0 then return false end

    -- Only trigger between runs (not while inside a boss zone)
    local zone = utils.get_zone()
    local in_boss = zone:match("Boss_WT4_") or zone:match("Boss_WT3_")
                 or zone:match("Boss_WT5_") or zone:match("Boss_Kehj_Belial")
                 or zone:match("S12_Boss_Butcher")
    if in_boss then return false end

    -- Continue executing until IDLE again
    if state ~= STATE.IDLE then return true end

    -- Check if we've hit the interval
    local runs_since_reset = tracker.total_kills - runs_at_last_reset
    return runs_since_reset >= settings.dungeon_reset_interval
end

function task.Execute()
    local t = now()

    if state == STATE.IDLE then
        state       = STATE.RESETTING
        state_start = t
        console.print(string.format(
            "[Reaper] Dungeon reset triggered after %d runs.",
            tracker.total_kills - runs_at_last_reset
        ))
        reset_all_dungeons()
        runs_at_last_reset = tracker.total_kills
        return
    end

    if state == STATE.RESETTING then
        -- Give the API call a moment to process
        if (t - state_start) >= 2.0 then
            state       = STATE.WAITING
            state_start = t
            console.print("[Reaper] Dungeon reset complete. Resuming rotation.")
        end
        return
    end

    if state == STATE.WAITING then
        -- Brief pause before handing back to navigate_to_boss
        if (t - state_start) >= 1.0 then
            state = STATE.IDLE
        end
        return
    end
end

return task
