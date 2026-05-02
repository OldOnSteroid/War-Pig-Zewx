-- WarPigs internal task: when WarPlans_QST_TurnIn_Rewards is active,
-- teleport to Temis, walk to NPC_QST_Tyrael_NonCombat, and interact.
-- Resets to idle once the quest disappears (other tick logic detects the
-- transition and calls tick(false)).

local M = {}

local TEMIS_WP   = 0x1CE51E       -- Skov_Temis waypoint sno (from existing plugins)
local TEMIS_ZONE = 'Skov_Temis'
local NPC_NAME   = 'NPC_QST_X2_Tyrael_NonCombat'

local INTERACT_DIST     = 3.0
local INTERACT_COOLDOWN = 1.5
local TELEPORT_TIMEOUT  = 30.0

local STATE = {
    IDLE         = 'IDLE',
    TELEPORTING  = 'TELEPORTING',
    APPROACH_NPC = 'APPROACH_NPC',
}

local state         = STATE.IDLE
local state_entered = 0
local last_interact = -999
local last_diag     = -999

local DIAG_INTERVAL = 4.0  -- seconds between "NPC not found" diagnostic dumps

local function log(msg) console.print('[WarPigs:turn_in] ' .. msg) end
local function now() return get_time_since_inject() end

local function set_state(s)
    if s ~= state then
        log('state ' .. state .. ' -> ' .. s)
        state         = s
        state_entered = now()
    end
end

local function get_zone()
    local world = get_current_world()
    if not world then return '' end
    local ok, z = pcall(function() return world:get_current_zone_name() end)
    return (ok and type(z) == 'string') and z or ''
end

local function find_npc()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= 'table' then return nil end
    for _, actor in pairs(actors) do
        local ok, name = pcall(function() return actor:get_skin_name() end)
        if ok and name == NPC_NAME then return actor end
    end
    return nil
end

-- When the exact NPC name isn't found, dump nearby candidates so the user
-- can correct NPC_NAME if the in-game skin differs from what we expect.
local function diagnose_missing_npc()
    if (now() - last_diag) < DIAG_INTERVAL then return end
    last_diag = now()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= 'table' then
        log('NPC not found — actors_manager returned non-table.')
        return
    end
    local pp = get_player_position()
    local matches = {}
    for _, actor in pairs(actors) do
        local ok_n, name = pcall(function() return actor:get_skin_name() end)
        if ok_n and type(name) == 'string'
                and (name:find('Tyrael') or name:find('NPC_QST')) then
            local ok_p, pos = pcall(function() return actor:get_position() end)
            local d = (ok_p and pp) and pp:dist_to(pos) or -1
            matches[#matches+1] = string.format('  %s  dist=%.1f', name, d)
        end
    end
    if #matches == 0 then
        log('NPC not found. No nearby actors match Tyrael/NPC_QST. Looking for: ' .. NPC_NAME)
    else
        log('NPC "' .. NPC_NAME .. '" not found. Nearby candidates:')
        for _, line in ipairs(matches) do log(line) end
    end
end

function M.tick(active)
    if not active then
        if state ~= STATE.IDLE then
            log('Quest gone — resetting.')
            set_state(STATE.IDLE)
        end
        return
    end

    if state == STATE.IDLE then
        if get_zone() == TEMIS_ZONE then
            log('Already in Temis — approaching Tyrael.')
            set_state(STATE.APPROACH_NPC)
        else
            log('Teleporting to Temis.')
            teleport_to_waypoint(TEMIS_WP)
            set_state(STATE.TELEPORTING)
        end
        return
    end

    if state == STATE.TELEPORTING then
        if get_zone() == TEMIS_ZONE then
            set_state(STATE.APPROACH_NPC)
            return
        end
        if (now() - state_entered) > TELEPORT_TIMEOUT then
            log('Teleport timeout — retrying.')
            teleport_to_waypoint(TEMIS_WP)
            state_entered = now()
        end
        return
    end

    if state == STATE.APPROACH_NPC then
        if get_zone() ~= TEMIS_ZONE then
            log('Left Temis unexpectedly — teleporting back.')
            teleport_to_waypoint(TEMIS_WP)
            set_state(STATE.TELEPORTING)
            return
        end
        local npc = find_npc()
        if not npc then
            diagnose_missing_npc()
            return
        end

        local pos = npc:get_position()
        local pp  = get_player_position()
        if not pp then return end
        local dist = pp:dist_to(pos)

        if dist <= INTERACT_DIST then
            if (now() - last_interact) >= INTERACT_COOLDOWN then
                log('Interacting with Tyrael.')
                loot_manager.interact_with_object(npc)
                last_interact = now()
            end
        else
            pathfinder.request_move(pos)
        end
        return
    end
end

function M.get_state() return state end

return M
