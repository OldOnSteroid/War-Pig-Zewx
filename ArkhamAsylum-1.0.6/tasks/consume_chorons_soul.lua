local plugin_label = 'arkham_asylum'

local utils    = require 'core.utils'
local settings = require 'core.settings'

-- Choron's Soul appears as an Interactable actor near the Awakened Glyphstone
-- after the pit guardian dies.  Interacting with it consumes glyph upgrade
-- chances and converts them into experience.  Same pattern as interact_shrine:
-- pause Batmobile, walk to it, fire interact_object, blacklist on stuck.
local SOUL_ACTOR_NAME   = 'Warplans_Pit_ChoronsSoul'
local INTERACT_TIMEOUT  = 5.0   -- seconds before a stuck soul is blacklisted

local status_enum = {
    IDLE        = 'idle',
    WALKING     = "walking to Choron's Soul",
    INTERACTING = "consuming Choron's Soul",
}
local task = {
    name   = 'consume_chorons_soul',
    status = status_enum['IDLE'],
}

local stuck_since    = nil
local skipped_souls  = {}   -- key: "x,y" rounded position string

local function soul_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local get_chorons_soul = function ()
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == SOUL_ACTOR_NAME and actor:is_interactable() then
            if not skipped_souls[soul_key(actor)] then
                return actor
            end
        end
    end
    return nil
end

task.shouldExecute = function ()
    if settings.speed_mode then return false end
    return settings.use_chorons_soul
        and utils.player_in_pit()
        and get_chorons_soul() ~= nil
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local soul = get_chorons_soul()
    if soul == nil then
        stuck_since = nil
        return
    end

    if utils.distance(local_player, soul) > 2 then
        stuck_since = nil
        local disable_spell = false
        if utils.distance(local_player, soul) <= 4 then
            disable_spell = true
        end
        BatmobilePlugin.set_target(plugin_label, soul, disable_spell)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    else
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['INTERACTING']
        orbwalker.set_clear_toggle(false)
        interact_object(soul)
        if stuck_since == nil then
            stuck_since = get_time_since_inject()
        elseif get_time_since_inject() - stuck_since > INTERACT_TIMEOUT then
            local key = soul_key(soul)
            console.print("[consume_chorons_soul] stuck for " .. INTERACT_TIMEOUT ..
                "s, blacklisting " .. key)
            skipped_souls[key] = true
            stuck_since = nil
        end
    end
end

return task
