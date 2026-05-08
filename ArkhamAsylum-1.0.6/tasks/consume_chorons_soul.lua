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
local PRE_WALK_LOOT_DELAY = 10.0 -- hold at player position when soul first appears so Looteer can sweep boss-drop loot before we leave for the soul
local LOOT_DELAY      = 4.0    -- park at soul before first click so Looteer sweeps drops
local CHARGE_DELAY    = 4.5    -- per-click channel — 10 × 4.5 ≈ 45s as observed
local MAX_CLICKS      = 10     -- safety cap; soul typically goes non-interactable first
local WALK_TIMEOUT    = 30.0   -- give up reaching this soul after this long without arriving (measured from end of pre-walk delay)

-- Post-consume orb sweep: after the soul is exhausted, the experience orbs
-- it dropped sit on the ground around the soul actor.  XP orbs auto-pickup
-- when the player walks within range (~3-5u in D4); a small loop around the
-- actor sweeps any orbs that landed beyond the soul's own pickup radius.
local ORB_SWEEP_POINTS    = 6     -- hex pattern around the soul
local ORB_SWEEP_RADIUS    = 4.5   -- meters from soul center
local ORB_SWEEP_ARRIVAL   = 1.5   -- distance to current point that counts as "reached"
local ORB_SWEEP_PER_PT_TIMEOUT = 2.5  -- give up on a single point after this long
local ORB_SWEEP_TOTAL_TIMEOUT  = 12.0 -- hard cap on the whole sweep

local status_enum = {
    IDLE           = 'idle',
    PRE_LOOT_DELAY = "holding for boss-drop loot before walking to Choron's Soul",
    WALKING        = "walking to Choron's Soul",
    LOOT_DELAY     = "waiting at Choron's Soul (loot window)",
    CLICKING       = "clicking Choron's Soul",
    CHARGING       = "Choron's Soul charging",
    ORB_SWEEP      = "collecting XP orbs around Choron's Soul",
    DONE           = "Choron's Soul consumed",
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
local first_seen_time = nil    -- when we first started tracking this soul (drives pre-walk loot delay)
local walk_phase_started = nil -- when the pre-walk delay elapsed and walking actually began (drives WALK_TIMEOUT)
local skipped_souls   = {}     -- hard-skip on truly broken souls (walk timeout exhausted)
-- Orb-sweep state.  `orb_sweep_points` is the sequence of vec3 ring points
-- around the soul's last-known position; `orb_sweep_idx` advances when we
-- arrive at a point or its per-point timeout elapses.  When `orb_sweep_done`
-- flips true the task fully finishes and shouldExecute returns false.
local orb_sweep_points     = nil
local orb_sweep_idx        = 1
local orb_sweep_start_time = nil
local orb_sweep_pt_started = nil
local orb_sweep_done       = false
local soul_last_pos        = nil  -- snapshotted when we transition to ORB_SWEEP (actor may despawn)

local function soul_key(actor)
    local pos = actor:get_position()
    return math.floor(pos:x() + 0.5) .. ',' .. math.floor(pos:y() + 0.5)
end

local function reset_soul_state()
    active_soul_key      = nil
    arrived_time         = nil
    last_click_time      = nil
    click_count          = 0
    first_seen_time      = nil
    walk_phase_started   = nil
    orb_sweep_points     = nil
    orb_sweep_idx        = 1
    orb_sweep_start_time = nil
    orb_sweep_pt_started = nil
    orb_sweep_done       = false
    soul_last_pos        = nil
end

local function build_sweep_points(center)
    local pts = {}
    for i = 1, ORB_SWEEP_POINTS do
        local theta = (i - 1) * (2 * math.pi / ORB_SWEEP_POINTS)
        pts[i] = vec3:new(
            center:x() + ORB_SWEEP_RADIUS * math.cos(theta),
            center:y() + ORB_SWEEP_RADIUS * math.sin(theta),
            center:z()
        )
    end
    return pts
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

    -- Orb sweep armed — keep running even after the soul actor has vanished,
    -- since we drive the sweep off `soul_last_pos`, not the actor.  Triggered
    -- when the click loop transitions to the sweep (sets soul_last_pos).
    if soul_last_pos and not orb_sweep_done then return true end

    local soul, key = get_chorons_soul()
    if not soul then
        if active_soul_key then reset_soul_state() end
        return false
    end

    -- A fresh soul (different position) appeared after we finished a previous
    -- one — clear the per-session done flag and re-engage on this new soul.
    if orb_sweep_done and active_soul_key ~= key then
        reset_soul_state()
        return true
    end

    -- Same soul we already finished this session — don't re-engage even if
    -- the actor is still rendering.
    if orb_sweep_done then return false end

    return true
end

-- Walks one lap around `soul_last_pos` to sweep up XP orbs that landed beyond
-- the soul's own pickup radius.  Each ring point is targeted via Batmobile;
-- arrival within ORB_SWEEP_ARRIVAL OR per-point timeout advances the index.
-- Sets orb_sweep_done = true when all points are visited or the total timeout
-- elapses.  Caller wraps this in pause+update of Batmobile.
local function step_orb_sweep(local_player, now)
    if not orb_sweep_points then
        if not soul_last_pos then
            -- Defensive: nothing to sweep around — finish immediately.
            orb_sweep_done = true
            return
        end
        orb_sweep_points     = build_sweep_points(soul_last_pos)
        orb_sweep_idx        = 1
        orb_sweep_start_time = now
        orb_sweep_pt_started = now
        console.print(string.format(
            "[consume_chorons_soul] starting orb sweep — %d points, radius=%.1f",
            ORB_SWEEP_POINTS, ORB_SWEEP_RADIUS))
    end

    -- Total budget exceeded — bail out cleanly.
    if (now - orb_sweep_start_time) > ORB_SWEEP_TOTAL_TIMEOUT then
        console.print("[consume_chorons_soul] orb sweep total timeout — finishing")
        orb_sweep_done = true
        BatmobilePlugin.clear_target(plugin_label)
        return
    end

    -- All points visited — sweep is complete.
    if orb_sweep_idx > #orb_sweep_points then
        console.print("[consume_chorons_soul] orb sweep complete")
        orb_sweep_done = true
        BatmobilePlugin.clear_target(plugin_label)
        return
    end

    local target = orb_sweep_points[orb_sweep_idx]
    local dist   = utils.distance(local_player, target)
    if dist < ORB_SWEEP_ARRIVAL
        or (orb_sweep_pt_started and (now - orb_sweep_pt_started) > ORB_SWEEP_PER_PT_TIMEOUT)
    then
        orb_sweep_idx        = orb_sweep_idx + 1
        orb_sweep_pt_started = now
        return  -- next tick targets the next point
    end

    BatmobilePlugin.set_target(plugin_label, target, true)  -- short hops, suppress movement spell
    BatmobilePlugin.move(plugin_label)
    task.status = status_enum['ORB_SWEEP']
end

task.Execute = function()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)

    -- Orb sweep takes priority over everything else — once the clicks are
    -- done and we've snapshot soul_last_pos, the actor may despawn at any
    -- moment.  Drive the sweep off the snapshot, not the live actor.
    if soul_last_pos and not orb_sweep_done then
        step_orb_sweep(local_player, get_time_since_inject())
        return
    end

    local soul, key = get_chorons_soul()
    if soul == nil then
        reset_soul_state()
        return
    end

    -- New soul (different position) — start fresh state
    if active_soul_key ~= key then
        if active_soul_key == nil then
            console.print("[consume_chorons_soul] soul detected at " .. tostring(key) ..
                " — pre-walk loot delay=" .. PRE_WALK_LOOT_DELAY .. "s, then engage " ..
                "(soul loot delay=" .. LOOT_DELAY .. "s, " ..
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

    -- Pre-walk loot window: the boss died moments before the soul spawned, so
    -- loot is on the ground at the player's current position. Hold here for
    -- PRE_WALK_LOOT_DELAY so Looteer can sweep boss drops before we leave.
    -- pause + clear_target every frame guarantees nothing (this task on later
    -- ticks, lower-priority tasks if priority ever inverts, stale custom
    -- targets) can re-issue movement during the window.
    if first_seen_time and (now - first_seen_time) < PRE_WALK_LOOT_DELAY then
        BatmobilePlugin.clear_target(plugin_label)
        task.status = status_enum['PRE_LOOT_DELAY']
        return
    end

    -- Pre-walk delay elapsed — first frame stamps walk_phase_started so
    -- WALK_TIMEOUT is measured from when walking actually began.
    if walk_phase_started == nil then
        walk_phase_started = now
        console.print(string.format(
            "[consume_chorons_soul] pre-walk loot delay (%.1fs) elapsed — walking to soul (dist=%.1f)",
            PRE_WALK_LOOT_DELAY, dist))
    end

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
        if walk_phase_started and (now - walk_phase_started) > WALK_TIMEOUT then
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

    -- Stop conditions: soul self-deactivated (game cap reached) OR our safety
    -- cap.  Snapshot the soul position and transition to the orb sweep — the
    -- actor may despawn between this tick and the next, so we record its pos
    -- now and drive the sweep off the snapshot.  Only enter the sweep if we
    -- actually clicked at least once (no clicks = no orbs to collect).
    local function enter_orb_sweep(reason)
        if click_count == 0 then
            console.print("[consume_chorons_soul] " .. reason .. " — no clicks fired, skipping orb sweep")
            orb_sweep_done = true
            return
        end
        soul_last_pos = vec3:new(soul:get_position():x(), soul:get_position():y(), soul:get_position():z())
        console.print("[consume_chorons_soul] " .. reason ..
            " after " .. click_count .. " clicks — entering orb sweep")
    end
    if not soul:is_interactable() then
        enter_orb_sweep("soul went non-interactable")
        return
    end
    if click_count >= MAX_CLICKS then
        enter_orb_sweep("reached MAX_CLICKS (" .. MAX_CLICKS .. ")")
        return
    end

    -- Fire the click
    settings.orb_set_clear(false)
    interact_object(soul)
    click_count     = click_count + 1
    last_click_time = now
    task.status     = status_enum['CLICKING']
    console.print(string.format(
        "[consume_chorons_soul] click %d/%d (next click in %.1fs)",
        click_count, MAX_CLICKS, CHARGE_DELAY))
end

return task
