local plugin_label = 'arkham_asylum'

local utils    = require 'core.utils'
local settings = require 'core.settings'

-- Choron's Burden Receptacle — a Warplans altar that spawns post-boss kill
-- and grants one extra glyph upgrade chance when interacted with. Single
-- click, instant, the actor disappears on success.
--
-- Priority: this task sits ABOVE consume_chorons_soul and upgrade_glyph in
-- task_manager so the bonus chance lands before the soul converts spare
-- chances to XP and before upgrade_glyph spends them. Detection by actor
-- presence — no explicit boss_dead gate needed since the altar only spawns
-- post-kill.
local ALTAR_ACTOR_NAME = 'Warplans_Pit_ChoronsBurden_Receptacle'
local INTERACT_RANGE   = 2
local INTERACT_TIMEOUT = 5.0   -- click didn't take after this long → blacklist
local WALK_TIMEOUT     = 30.0  -- couldn't reach in this long → blacklist

local status_enum = {
    IDLE        = 'idle',
    WALKING     = 'walking to Burden Altar',
    INTERACTING = 'using Burden Altar',
}

local task = {
    name   = 'use_burden_altar',
    status = status_enum['IDLE'],
}

local active_key   = nil
local walk_started = nil
local clicked_time = nil
local skipped      = {}

local function altar_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local function reset_state()
    active_key   = nil
    walk_started = nil
    clicked_time = nil
end

-- Uses get_all_actors because the Warplans actor family isn't surfaced via
-- get_ally_actors (same as consume_chorons_soul / pickup_heart_of_stone).
local function get_altar()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == ALTAR_ACTOR_NAME then
            local k = altar_key(actor)
            if not skipped[k] then
                return actor, k
            end
        end
    end
    return nil, nil
end

task.shouldExecute = function ()
    -- No speed_mode gate: this is a one-shot post-boss interaction, not trash
    -- engagement. Speed_mode is about charging through floors, not skipping
    -- the bonus-glyph altar.
    if not settings.use_burden_altar then return false end
    if not utils.player_in_pit() then return false end
    local altar = get_altar()
    if not altar then
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

    local altar, key = get_altar()
    if altar == nil then
        reset_state()
        return
    end

    if active_key ~= key then
        console.print("[use_burden_altar] altar detected at " .. tostring(key) .. " — engaging")
        reset_state()
        active_key   = key
        walk_started = get_time_since_inject()
    end

    local now  = get_time_since_inject()
    local dist = utils.distance(local_player, altar)

    -- Walk phase
    if dist > INTERACT_RANGE then
        local disable_spell = (dist <= 4)
        local accepted = BatmobilePlugin.set_target(plugin_label, altar, disable_spell)
        if accepted == false then
            console.print("[use_burden_altar] navigator rejected target for " .. tostring(key) .. " — blacklisting")
            skipped[key] = true
            reset_state()
            BatmobilePlugin.clear_target(plugin_label)
            return
        end
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
        if walk_started and (now - walk_started) > WALK_TIMEOUT then
            console.print("[use_burden_altar] walk timeout (" .. WALK_TIMEOUT ..
                "s) for altar " .. tostring(key) .. " — blacklisting")
            skipped[key] = true
            reset_state()
        end
        return
    end

    -- In range — hold and click. Interaction is instant; the actor disappears
    -- on success which lets shouldExecute return false next tick.
    BatmobilePlugin.clear_target(plugin_label)

    if not altar:is_interactable() then
        console.print("[use_burden_altar] altar " .. tostring(key) .. " went non-interactable — blacklisting")
        skipped[key] = true
        reset_state()
        return
    end

    settings.orb_set_clear(false)
    interact_object(altar)
    if clicked_time == nil then
        clicked_time = now
        console.print("[use_burden_altar] interacting with altar at " .. tostring(key))
    elseif (now - clicked_time) > INTERACT_TIMEOUT then
        console.print("[use_burden_altar] interact timeout for " .. tostring(key) .. " — blacklisting")
        skipped[key] = true
        reset_state()
        return
    end
    task.status = status_enum['INTERACTING']
end

return task
