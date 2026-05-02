-- ============================================================
--  Reaper - tasks/revive.lua
--
--  Detects player death and handles recovery:
--    1. Call revive_at_checkpoint()
--    2. Wait for player to be alive and zone to load
--    3. If still in boss zone → path_exhausted reset so
--       navigate_to_boss will re-walk to the altar
--    4. If back in a town/non-boss zone → reset nav so it
--       will re-teleport to the boss
--
--  Priority: must be ABOVE navigate_to_boss so it fires first.
-- ============================================================

local utils    = require "core.utils"
local tracker  = require "core.tracker"
local rotation = require "core.boss_rotation"

local STATE = {
    IDLE     = "IDLE",
    DEAD     = "DEAD",     -- detected death, calling revive
    WAITING  = "WAITING",  -- waiting for respawn to complete
    RECOVER  = "RECOVER",  -- brief settle before handing back
}

local s = { state = STATE.IDLE, t = 0 }

local function now() return get_time_since_inject() end
local function set_state(st) s.state = st; s.t = now() end
local function elapsed() return now() - s.t end

local function player_is_dead()
    local lp = get_local_player()
    return lp ~= nil and lp:is_dead()
end

local task = { name = "Revive" }

function task.shouldExecute()
    if rotation.is_done() then return false end
    if s.state ~= STATE.IDLE then return true end
    return player_is_dead()
end

function task.Execute()
    -- ---- Detected death ----
    if s.state == STATE.IDLE then
        console.print("[Reaper] Player died – calling revive_at_checkpoint.")
        -- Reset run state so we re-summon and re-walk path after respawn
        tracker.altar_activated = false
        -- Signal navigate_to_boss to re-walk path on respawn
        -- (done via a shared flag read by navigate_to_boss)
        tracker.just_revived = true
        set_state(STATE.DEAD)
        return
    end

    -- ---- Call revive repeatedly until it takes ----
    if s.state == STATE.DEAD then
        if player_is_dead() then
            revive_at_checkpoint()
            -- Retry every 0.5s until alive
            if elapsed() >= 0.5 then
                set_state(STATE.DEAD)  -- resets timer
            end
        else
            console.print("[Reaper] Revived – waiting for zone to settle.")
            set_state(STATE.WAITING)
        end
        return
    end

    -- ---- Wait for loading screen / zone to stabilise ----
    if s.state == STATE.WAITING then
        if player_is_dead() then
            -- Somehow still dead – keep trying
            set_state(STATE.DEAD)
            return
        end
        if elapsed() >= 3.0 then
            set_state(STATE.RECOVER)
        end
        return
    end

    -- ---- Brief settle then hand back to other tasks ----
    if s.state == STATE.RECOVER then
        if elapsed() >= 1.0 then
            local boss = rotation.current()
            if boss then
                local zone = utils.get_zone()
                if zone:match(boss.zone_prefix) then
                    console.print("[Reaper] Respawned in boss zone – will re-walk to altar.")
                    -- nav_to_boss will handle path walk since path_exhausted=false after reset
                else
                    console.print("[Reaper] Respawned outside boss zone – will re-teleport.")
                end
            end
            set_state(STATE.IDLE)
        end
        return
    end
end

return task
