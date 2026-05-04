local plugin_label = 'arkham_asylum'

local utils    = require 'core.utils'
local settings = require 'core.settings'

-- Choron's Soul appears as an Interactable actor near the Awakened Glyphstone
-- after the pit guardian dies.  Each click consumes one glyph upgrade chance
-- and channels for ~4.5s, dropping experience orbs at the end.  Up to 10
-- clicks per soul (≈45s total).
--
-- Flow per soul instance:
--   walk to soul → 3s loot-pickup window → click → 4.5s charge → click → … up
--   to MAX_CLICKS, or until the actor goes non-interactable (game-side cap).
local SOUL_ACTOR_NAME = 'Warplans_Pit_ChoronsSoul'
local INTERACT_RANGE  = 3      -- distance considered "at the soul" (matches shrine)
local LOOT_DELAY      = 4.0    -- park at soul before first click so Looteer sweeps drops
local CHARGE_DELAY    = 4.5    -- per-click channel — 10 × 4.5 ≈ 45s as observed
local MAX_CLICKS      = 10     -- safety cap; soul typically goes non-interactable first
local WALK_TIMEOUT    = 30.0   -- give up reaching this soul after this long without arriving

local status_enum = {
    IDLE       = 'idle',
    WALKING    = "walking to Choron's Soul",
    LOOT_DELAY = "waiting at Choron's Soul (loot window)",
    CLICKING   = "clicking Choron's Soul",
    CHARGING   = "Choron's Soul charging",
    DONE       = "Choron's Soul consumed",
}

local task = {
    name   = 'consume_chorons_soul',
    status = status_enum['IDLE'],
}

-- Per-soul session state.  Reset whenever a new soul (different position) is
-- picked up or the current soul disappears.  Keyed on rounded position so a
-- second soul on a re-run of the same floor doesn't inherit the first's state.
local active_soul_key = nil
local arrived_time    = nil
local last_click_time = nil    -- nil before first click; set after each interact_object
local click_count     = 0
local first_seen_time = nil    -- when we first started tracking this soul (walk timeout)
local skipped_souls   = {}     -- hard-skip on truly broken souls (walk timeout exhausted)

local function soul_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local function reset_soul_state()
    active_soul_key = nil
    arrived_time    = nil
    last_click_time = nil
    click_count     = 0
    first_seen_time = nil
end

-- Returns the first non-blacklisted Choron's Soul actor.  Uses get_all_actors
-- (not get_ally_actors) because the WarPlans gizmo family — including the
-- parallel BSK_TalismanChest in HordeDev — is reached via the all-actors
-- list.  Filtering by `is_interactable()` is intentionally NOT done here so
-- the caller can distinguish "soul exists but channeling" from "soul gone".
local function get_chorons_soul()
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name == SOUL_ACTOR_NAME then
            local k = soul_key(actor)
            if not skipped_souls[k] then
                return actor, k
            end
        end
    end
    return nil, nil
end

task.shouldExecute = function()
    if settings.speed_mode then return false end
    if not settings.use_chorons_soul then return false end
    if not utils.player_in_pit() then return false end

    local soul, key = get_chorons_soul()
    if not soul then
        if active_soul_key then reset_soul_state() end
        return false
    end

    -- Already finished this soul — don't re-engage if it's still rendering.
    if active_soul_key == key then
        if click_count >= MAX_CLICKS then return false end
        if not soul:is_interactable() and click_count > 0 then return false end
    end

    return true
end

task.Execute = function()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    local soul, key = get_chorons_soul()
    if soul == nil then
        reset_soul_state()
        return
    end

    -- New soul (different position) — start fresh state
    if active_soul_key ~= key then
        if active_soul_key == nil then
            console.print("[consume_chorons_soul] soul detected at " .. tostring(key) ..
                " — engaging (loot delay=" .. LOOT_DELAY .. "s, " ..
                MAX_CLICKS .. " clicks × " .. CHARGE_DELAY .. "s charge)")
        else
            console.print("[consume_chorons_soul] new soul detected (" .. tostring(key) ..
                "), resetting click counter")
        end
        reset_soul_state()
        active_soul_key = key
        first_seen_time = get_time_since_inject()
    end

    local now  = get_time_since_inject()
    local dist = utils.distance(local_player, soul)

    -- Walk phase
    if dist > INTERACT_RANGE then
        local disable_spell = (dist <= 4)
        BatmobilePlugin.set_target(plugin_label, soul, disable_spell)
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
        -- Reset arrival timer so the loot delay only counts from when we
        -- actually arrived (not from a previous brief touch we walked away from).
        arrived_time = nil
        -- Walk timeout: if we can never reach this soul, blacklist and move on
        if first_seen_time and (now - first_seen_time) > WALK_TIMEOUT then
            console.print("[consume_chorons_soul] walk timeout (" .. WALK_TIMEOUT ..
                "s) for soul " .. tostring(key) .. " — blacklisting")
            skipped_souls[key] = true
            reset_soul_state()
        end
        return
    end

    -- We're at the soul — hold position so the channel doesn't get interrupted
    BatmobilePlugin.clear_target(plugin_label)

    -- Mark arrival on the first frame we're in range.  Done here (not in walk
    -- phase) so transient close-proximity ticks before settling don't start
    -- the loot timer prematurely.
    if arrived_time == nil then
        arrived_time = now
        task.status = status_enum['LOOT_DELAY']
        return
    end

    -- Loot pickup window before the very first click
    if click_count == 0 and (now - arrived_time) < LOOT_DELAY then
        task.status = status_enum['LOOT_DELAY']
        return
    end

    -- Charge cooldown between clicks: don't re-fire interact_object until the
    -- previous channel finished, otherwise the second click cancels the first.
    if last_click_time and (now - last_click_time) < CHARGE_DELAY then
        task.status = status_enum['CHARGING']
        return
    end

    -- Stop conditions: soul self-deactivated (game cap reached) OR our safety cap
    if not soul:is_interactable() then
        task.status = status_enum['DONE']
        return
    end
    if click_count >= MAX_CLICKS then
        console.print("[consume_chorons_soul] reached MAX_CLICKS (" .. MAX_CLICKS .. ")")
        task.status = status_enum['DONE']
        return
    end

    -- Fire the click
    orbwalker.set_clear_toggle(false)
    interact_object(soul)
    click_count     = click_count + 1
    last_click_time = now
    task.status     = status_enum['CLICKING']
    console.print(string.format(
        "[consume_chorons_soul] click %d/%d (next click in %.1fs)",
        click_count, MAX_CLICKS, CHARGE_DELAY))
end

return task
