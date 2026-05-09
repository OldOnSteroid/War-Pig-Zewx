local plugin_label = 'arkham_asylum'

local utils    = require 'core.utils'
local settings = require 'core.settings'

-- Heart of Stone (Choron's Burden) — a Warplans-family carryable that can spawn
-- anywhere on a pit floor.  Picking it up is a single interact_object click;
-- the actor goes non-interactable / despawns once carried.  We detect from
-- anywhere in the pit (no distance gate), let Batmobile route to it, dwell
-- briefly on arrival so the click registers cleanly, then click once.
local HEART_ACTOR_NAME = 'Warplans_Pit_ChoronsBurden_Carryable'
local INTERACT_RANGE   = 2     -- distance considered "at the heart"
local ARRIVAL_DELAY    = 1.5   -- dwell after arrival before firing the click
local INTERACT_TIMEOUT = 4.0   -- if click doesn't take after this many seconds, blacklist
local WALK_TIMEOUT     = 30.0  -- give up reaching this heart after this long without arriving

local status_enum = {
    IDLE        = 'idle',
    WALKING     = 'walking to Heart of Stone',
    DWELL       = 'dwelling at Heart of Stone',
    INTERACTING = 'picking up Heart of Stone',
}

local task = {
    name   = 'pickup_heart_of_stone',
    status = status_enum['IDLE'],
}

local active_key   = nil
local arrived_time = nil
local walk_started = nil
local clicked_time = nil
local skipped      = {}  -- key: "x,y" of heart position

local function heart_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local function reset_state()
    active_key   = nil
    arrived_time = nil
    walk_started = nil
    clicked_time = nil
end

-- Uses get_all_actors because the Warplans actor family isn't surfaced via
-- get_ally_actors (same reason consume_chorons_soul does).
local function get_heart()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == HEART_ACTOR_NAME then
            local k = heart_key(actor)
            if not skipped[k] then
                return actor, k
            end
        end
    end
    return nil, nil
end

task.shouldExecute = function ()
    -- No speed_mode gate: heart pickups are explicit detours requested by the
    -- user "throughout the entire pit" — speed_mode shouldn't suppress them.
    if not settings.pickup_heart_of_stone then return false end
    if not utils.player_in_pit() then return false end
    local heart = get_heart()
    if not heart then
        if active_key then reset_state() end
        return false
    end
    return true
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local heart, key = get_heart()
    if heart == nil then
        reset_state()
        return
    end

    -- New heart instance — reset per-instance state
    if active_key ~= key then
        if active_key == nil then
            console.print("[pickup_heart_of_stone] heart detected at " .. tostring(key) .. " — engaging")
        else
            console.print("[pickup_heart_of_stone] new heart detected (" .. tostring(key) .. "), resetting state")
        end
        reset_state()
        active_key   = key
        walk_started = get_time_since_inject()
    end

    local now  = get_time_since_inject()
    local dist = utils.distance(local_player, heart)

    -- Walk phase
    if dist > INTERACT_RANGE then
        local disable_spell = (dist <= 4)
        local accepted = BatmobilePlugin.set_target(plugin_label, heart, disable_spell)
        if accepted == false then
            console.print("[pickup_heart_of_stone] navigator rejected target for " .. tostring(key) .. " — blacklisting")
            skipped[key] = true
            reset_state()
            BatmobilePlugin.clear_target(plugin_label)
            return
        end
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
        arrived_time = nil
        if walk_started and (now - walk_started) > WALK_TIMEOUT then
            console.print("[pickup_heart_of_stone] walk timeout (" .. WALK_TIMEOUT ..
                "s) for heart " .. tostring(key) .. " — blacklisting")
            skipped[key] = true
            reset_state()
        end
        return
    end

    -- We're at the heart — hold position
    BatmobilePlugin.clear_target(plugin_label)

    if arrived_time == nil then
        arrived_time = now
        task.status = status_enum['DWELL']
        return
    end

    -- Brief dwell so the interact lands cleanly (Choron's Soul uses a similar
    -- pre-click window; keep this short — single pickup, not a channel)
    if (now - arrived_time) < ARRIVAL_DELAY then
        task.status = status_enum['DWELL']
        return
    end

    -- Heart already consumed by something (party member, etc.) — blacklist and move on
    if not heart:is_interactable() then
        console.print("[pickup_heart_of_stone] heart " .. tostring(key) .. " went non-interactable — blacklisting")
        skipped[key] = true
        reset_state()
        return
    end

    -- Fire the pickup click (idempotent if it doesn't take; INTERACT_TIMEOUT
    -- below blacklists if the actor refuses to go non-interactable)
    settings.orb_set_clear(false)
    interact_object(heart)
    if clicked_time == nil then
        clicked_time = now
        console.print("[pickup_heart_of_stone] picking up heart at " .. tostring(key))
    elseif (now - clicked_time) > INTERACT_TIMEOUT then
        console.print("[pickup_heart_of_stone] interact timeout for " .. tostring(key) .. " — blacklisting")
        skipped[key] = true
        reset_state()
        return
    end
    task.status = status_enum['INTERACTING']
end

return task
