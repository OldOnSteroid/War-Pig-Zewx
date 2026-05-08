local plugin_label = 'arkham_asylum' -- change to your plugin name

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local status_enum = {
    IDLE = 'idle',
    EXPLORING = 'exploring',
    RESETING = 'reseting explorer',
    INTERACTING = 'interacting with portal',
    WALKING = 'walking to portal'
}
local task = {
    name = 'portal', -- change to your choice of task name
    status = status_enum['IDLE'],
    portal_found = false,
    portal_exit = -1,
    -- Last time long_path or get_closeby_node failed to reach the portal.
    -- The cross_traversal task reads this to decide when to engage a
    -- traversal gizmo (portal across a cliff/climb).
    long_path_failed_time = -math.huge,
}
-- Cache portal scan to avoid double actor iteration per frame (shouldExecute + Execute)
local _portal_cache = nil
local _portal_cache_time = -1
local _portal_cache_duration = 0.01 -- 10ms, well within a single frame

-- Back-portal blacklist: Prefab_Portal_Dungeon_Generic is the actor name for both the
-- next-floor portal and the previous-floor portal. After teleporting, the player spawns
-- on top of the back-portal. We snapshot the spawn position on world change and exclude
-- any portal within BACK_PORTAL_RADIUS of it for the duration of the new world.
local current_world_name = nil
local back_portal_pos = nil
local portal_just_used = false
local portal_used_time = -math.huge
local PORTAL_TRANSITION_WINDOW = 5  -- seconds to accept world-change as portal-induced
-- The game offsets the spawn 4-7 units from the back-portal so the player doesn't
-- immediately re-trigger it. Confirmed via log: spawns at distances 4.9 and 6.1 from
-- the back-portal. Use 10 to safely catch them without snagging a descend portal,
-- which is typically 30+ units away on multi-portal floors.
local BACK_PORTAL_RADIUS = 10
-- Portal task engages at a larger radius than settings.check_distance (12). The explorer
-- doesn't seek portal actors directly — it picks walkable-tile frontiers — so the bot can
-- circle a portal at distance 13–28 forever without crossing the 12-unit threshold.
-- Once a non-back portal is visible within this radius, take it.
local PORTAL_DETECTION_RADIUS = 25
-- A descent portal is "blocked" when an alive boss or the glyphstone sits within this
-- radius. Boss case: never skip past an unkilled boss. Glyphstone case: never leave
-- the floor where the upgrade gizmo spawned (upgrade_glyph + exit_pit own that floor).
-- Blocked portals are filtered out of get_portal() so the task yields to kill_monster /
-- upgrade_glyph / exit_pit.
local PORTAL_BLOCK_RADIUS = 20

-- ── Death-recovery: route back to last-seen portal after respawn ───────────
-- Problem: PORTAL_DETECTION_RADIUS (25u) keeps the portal task from engaging
-- prematurely during exploration. But when the player dies near a portal and
-- respawns at the floor checkpoint (often hundreds of units away), the portal
-- isn't detected and there are no frontiers in the area (already explored)
-- so explore_pit does nothing — bot stalls.
-- Fix: snapshot the most recently seen interactable portal's position.
-- Detect respawn via a sudden position jump > 50u within the same world
-- (world-change crossings are handled separately via portal_just_used).
-- On respawn, long-path back toward the remembered portal until get_portal()
-- starts seeing it again (then the regular flow takes over).
local _last_portal_pos       = nil       -- vec3 of last interactable (descend) portal we saw on this floor
local _last_portal_seen_t    = -math.huge
local PORTAL_REMEMBER_TTL    = 60        -- seconds: a portal we saw recently is probably still there
local _last_choron_pos       = nil       -- vec3 of last Choron's Soul actor seen on this floor
local _last_choron_seen_t    = -math.huge
local _last_player_pos       = nil       -- per-frame tracking for jump detection
local _respawn_recovery_pos  = nil       -- vec3 we're routing back to after detected respawn
local _respawn_recovery_t    = -math.huge
local _respawn_recovery_kind = nil       -- 'portal'|'boss'|'glyph'|'choron'|'last_alive' (for log + arrival check)
local _respawn_long_path_t   = -math.huge -- last time we issued a recovery long_path
local RESPAWN_JUMP_THRESHOLD = 50         -- match Batmobile's nav.lua respawn threshold
local RESPAWN_RECOVERY_TIMEOUT = 45       -- seconds: give up if portal not re-detected by then
local RESPAWN_PATH_RETRY     = 3          -- seconds between recovery long_path retries
local RESPAWN_ARRIVAL_RADIUS = 10         -- non-portal recovery clears once we're this close
local CHORON_SOUL_ACTOR      = 'Warplans_Pit_ChoronsSoul'

-- Pick a recovery target by priority: descend portal > boss > glyph > Choron's
-- Soul > last-alive position. State for portal/choron is cleared on world
-- change (see update_back_portal_tracking), so the chain only ever sees
-- targets known on the current floor — entry/back portals are never picked.
local function pick_recovery_target(now, death_pos)
    if _last_portal_pos ~= nil
        and (now - _last_portal_seen_t) <= PORTAL_REMEMBER_TTL
    then
        return _last_portal_pos, 'portal'
    end
    if tracker.boss_position ~= nil then
        return tracker.boss_position, 'boss'
    end
    local glyph = utils.get_glyph_upgrade_gizmo()
    if glyph then
        return glyph:get_position(), 'glyph'
    end
    if tracker.glyph_anchor_pos ~= nil then
        return tracker.glyph_anchor_pos, 'glyph'
    end
    if _last_choron_pos ~= nil then
        return _last_choron_pos, 'choron'
    end
    if death_pos ~= nil then
        return death_pos, 'last_alive'
    end
    return nil, nil
end

local function update_death_recovery()
    -- Beta gate: feature disabled by default while it's being validated.
    -- Any in-flight recovery state is wiped so flipping the toggle off mid-run
    -- doesn't leave the task pinned to a stale recovery target.
    if not settings.death_recovery then
        if _respawn_recovery_pos ~= nil or _last_player_pos ~= nil then
            _respawn_recovery_pos  = nil
            _respawn_recovery_kind = nil
            _last_player_pos       = nil
        end
        return
    end
    if not utils.player_in_pit() then
        _last_player_pos       = nil
        _respawn_recovery_pos  = nil
        _respawn_recovery_kind = nil
        return
    end
    local pos = get_player_position()
    if not pos then return end
    local now = get_time_since_inject()
    if _last_player_pos ~= nil and not portal_just_used then
        local jump = utils.distance(pos, _last_player_pos)
        if jump > RESPAWN_JUMP_THRESHOLD then
            -- Position jumped without a portal use: classify as death + respawn.
            -- _last_player_pos is the death point (last frame before respawn);
            -- pass it as the bottom-of-chain fallback so we can resume the
            -- exact frontier we were exploring when we died.
            local target, kind = pick_recovery_target(now, _last_player_pos)
            if target ~= nil then
                _respawn_recovery_pos  = vec3:new(target:x(), target:y(), target:z())
                _respawn_recovery_t    = now
                _respawn_recovery_kind = kind
                _respawn_long_path_t   = -math.huge
                console.print(string.format(
                    "[portal] respawn detected (jumped %.1f units) — recovering to %s at (%.1f,%.1f) dist=%.1f",
                    jump, kind,
                    _respawn_recovery_pos:x(), _respawn_recovery_pos:y(),
                    utils.distance(pos, _respawn_recovery_pos)))
            else
                console.print(string.format(
                    "[portal] respawn detected (jumped %.1f units) — no recovery target available",
                    jump))
            end
        end
    end
    _last_player_pos = vec3:new(pos:x(), pos:y(), pos:z())

    -- Recovery clears on (a) arrival, or (b) timeout. Portal kind also clears
    -- in get_portal() once the actor is back in detection range, but if the
    -- portal is gone (e.g. it was the actual death point) the arrival check
    -- still terminates recovery so explore_pit can take over the same area.
    if _respawn_recovery_pos ~= nil then
        local d = utils.distance(pos, _respawn_recovery_pos)
        if d < RESPAWN_ARRIVAL_RADIUS then
            console.print(string.format(
                "[portal] respawn recovery: arrived at %s target (dist=%.1f) — clearing",
                _respawn_recovery_kind or 'unknown', d))
            _respawn_recovery_pos  = nil
            _respawn_recovery_kind = nil
        elseif (now - _respawn_recovery_t) > RESPAWN_RECOVERY_TIMEOUT then
            console.print("[portal] respawn recovery timed out — clearing")
            _respawn_recovery_pos  = nil
            _respawn_recovery_kind = nil
        end
    end
end

local function portal_blocked(portal_actor)
    local ppos = portal_actor:get_position()
    local enemies = target_selector and target_selector.get_near_target_list
        and target_selector.get_near_target_list(ppos, PORTAL_BLOCK_RADIUS)
        or nil
    if enemies then
        for _, enemy in pairs(enemies) do
            if enemy:is_boss() and enemy:get_current_health() > 1 then
                return true, 'boss', enemy
            end
        end
    end
    local glyph = utils.get_glyph_upgrade_gizmo()
    if glyph then
        if utils.distance(glyph:get_position(), ppos) <= PORTAL_BLOCK_RADIUS then
            return true, 'glyphstone', glyph
        end
    end
    return false
end

local function update_back_portal_tracking()
    if not utils.player_in_pit() then
        if current_world_name ~= nil then
            console.print("[portal] left pit, clearing back-portal state")
        end
        current_world_name = nil
        back_portal_pos = nil
        portal_just_used = false
        -- Pit-exit: also wipe death-recovery state so it can't bleed into the
        -- next pit run.  shouldExecute already does this on its early-return
        -- path, but keep the wipe here too in case this runs first.
        _respawn_recovery_pos  = nil
        _respawn_recovery_kind = nil
        _last_player_pos       = nil
        _last_portal_pos       = nil
        _last_portal_seen_t    = -math.huge
        _last_choron_pos       = nil
        _last_choron_seen_t    = -math.huge
        return
    end
    local world = get_current_world()
    if not world then return end
    local wname = world:get_name()
    if wname == current_world_name then
        -- Drop stale portal_just_used flag if no transition occurred (interaction failed?)
        if portal_just_used and (get_time_since_inject() - portal_used_time) > PORTAL_TRANSITION_WINDOW then
            console.print("[portal] portal_just_used timed out without world change, clearing")
            portal_just_used = false
        end
        return
    end
    -- World changed
    if portal_just_used and (get_time_since_inject() - portal_used_time) < PORTAL_TRANSITION_WINDOW then
        local pos = get_player_position()
        if pos then
            back_portal_pos = vec3:new(pos:x(), pos:y(), pos:z())
            console.print(string.format("[portal] arrived in '%s' via portal — back-portal blacklisted near (%.1f,%.1f) radius=%.0f",
                wname, pos:x(), pos:y(), BACK_PORTAL_RADIUS))
        end
    else
        back_portal_pos = nil
        console.print(string.format("[portal] entered '%s' (not via portal) — no back-portal blacklist", wname))
    end
    current_world_name = wname
    portal_just_used = false
    -- Invalidate cache: actor pointers from previous world are no longer relevant
    _portal_cache = nil
    _portal_cache_time = -1
    -- Wipe per-floor recovery state. _last_portal_pos from the previous floor
    -- maps to coords that don't correspond to anything in this world; keeping
    -- it would route post-death recovery back to a phantom location. Choron's
    -- Soul only spawns on the boss floor — its position is also per-floor.
    -- (boss/glyph tracker state is cleared at portal interaction further down.)
    _last_portal_pos       = nil
    _last_portal_seen_t    = -math.huge
    _last_choron_pos       = nil
    _last_choron_seen_t    = -math.huge
    -- Active recovery target also doesn't survive a world change — its coords
    -- belong to whichever floor we just left.
    _respawn_recovery_pos  = nil
    _respawn_recovery_kind = nil
    _last_player_pos       = nil
end

local function is_back_portal(actor)
    if not back_portal_pos then return false end
    local pos = actor:get_position()
    return utils.distance(pos, back_portal_pos) < BACK_PORTAL_RADIUS
end

-- Periodic debug dump of all Portal-named actors so we can see exactly what the scan
-- finds and why each is filtered. Throttled to once every 2 seconds.
local _last_portal_dump = -math.huge
local PORTAL_DUMP_INTERVAL = 2

local get_portal = function ()
    update_back_portal_tracking()
    local now = get_time_since_inject()
    if now - _portal_cache_time < _portal_cache_duration then
        return _portal_cache
    end
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    -- get_all_actors covers non-ally actors too — Batmobile's traversal scan uses this
    local actors = actors_manager:get_all_actors()
    local found_portal = nil
    local dump_now = (now - _last_portal_dump) >= PORTAL_DUMP_INTERVAL
    for _, actor in pairs(actors) do
        local actor_name = actor:get_skin_name()
        -- Stamp Choron's Soul position whenever we see it. Cheap to piggyback
        -- on the existing actor iteration; used by the death-recovery fallback
        -- chain when no portal/boss/glyph anchor is available.
        if actor_name == CHORON_SOUL_ACTOR then
            local cp = actor:get_position()
            _last_choron_pos    = vec3:new(cp:x(), cp:y(), cp:z())
            _last_choron_seen_t = now
        end
        if actor_name and actor_name:match('Portal')
            -- Light_NoShadows_Portal_Dungeon_Generic is a decorative lighting actor
            -- that mirrors the portal's position; never use it for pathing.
            and not actor_name:match('Light_NoShadows')
        then
            local interactable = actor:is_interactable()
            local apos = actor:get_position()
            local dist = utils.distance(player_pos, actor)
            local is_back = is_back_portal(actor)
            if dump_now then
                console.print(string.format(
                    "[portal] candidate name=%s interactable=%s dist=%.1f pos=(%.1f,%.1f) back=%s",
                    actor_name, tostring(interactable), dist, apos:x(), apos:y(), tostring(is_back)
                ))
            end
            -- Match any Portal_Dungeon_* variant (Generic, Sightless_Skov, etc.).
            -- Safe to be permissive now that get_closeby_node handles non-walkable
            -- portal meshes — if the variant ever turns out to be undesirable, the
            -- back-portal blacklist still excludes ones we just came through.
            if interactable and actor_name:match('Portal_Dungeon') and not is_back
                and dist <= PORTAL_DETECTION_RADIUS and found_portal == nil
            then
                local blocked, reason = portal_blocked(actor)
                if blocked then
                    if dump_now then
                        console.print(string.format(
                            '[portal] %s at (%.1f,%.1f) blocked by %s within %d — skipping',
                            actor_name, apos:x(), apos:y(), reason, PORTAL_BLOCK_RADIUS
                        ))
                    end
                else
                    found_portal = actor
                end
            end
        end
    end
    if dump_now then _last_portal_dump = now end
    if found_portal ~= nil then
        _portal_cache = found_portal
        _portal_cache_time = now
        -- Remember position so we can route back here after a death + respawn
        -- (PORTAL_DETECTION_RADIUS won't see the portal from the checkpoint).
        local fp_pos = found_portal:get_position()
        _last_portal_pos    = vec3:new(fp_pos:x(), fp_pos:y(), fp_pos:z())
        _last_portal_seen_t = now
        -- Successful (re-)detection cancels any in-flight respawn recovery —
        -- the regular flow takes over from here.
        if _respawn_recovery_pos ~= nil then
            console.print("[portal] portal back in detection range — clearing respawn recovery")
            _respawn_recovery_pos  = nil
            _respawn_recovery_kind = nil
        end
        return found_portal
    end
    _portal_cache = nil
    _portal_cache_time = now
    return nil
end
task.shouldExecute = function ()
    if not utils.player_in_pit() then
        -- Pit-exit cleanup: wipe death-recovery state here.  Without this, a
        -- recovery target armed in the previous pit run survives across
        -- exit→teleport→re-enter (update_back_portal_tracking + the cleanup
        -- inside update_death_recovery only run when this task gets past the
        -- not-in-pit gate, which it doesn't on travel frames). Result: stale
        -- "respawn recovery: long_path back to <kind> target" log on the
        -- first frame of the new pit until the timeout fires.
        if _respawn_recovery_pos ~= nil
            or _last_player_pos ~= nil
            or _last_portal_pos ~= nil
            or _last_choron_pos ~= nil
        then
            _respawn_recovery_pos  = nil
            _respawn_recovery_kind = nil
            _last_player_pos       = nil
            _last_portal_pos       = nil
            _last_portal_seen_t    = -math.huge
            _last_choron_pos       = nil
            _last_choron_seen_t    = -math.huge
        end
        return false
    end
    -- Drive death-recovery jump detection on every shouldExecute call (cheap;
    -- gates inside on player_in_pit and same-world). When recovery is armed
    -- we want this task to win the priority slot until the portal becomes
    -- detectable again — explore_pit has nothing to do anyway since the
    -- frontiers near the portal are already exhausted.
    update_death_recovery()
    return get_portal() ~= nil
        or task.portal_found
        or task.portal_exit + 1 >= get_time_since_inject()
        or _respawn_recovery_pos ~= nil
end
-- Track which portal position we last issued a long-path to, so we don't recompute
-- the uncapped A* every frame. Also track time of last issue so we can re-issue if
-- the long-path navigation ended without reaching the portal.
local _long_path_target = nil
local _last_path_issue = -math.huge
local _approach_fail_time = -math.huge -- cooldown after get_closeby_node failure
local PATH_RETRY_INTERVAL = 2  -- seconds; if long-path stops navigating, retry no more often than this

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    settings.orb_set_clear(true)
    local portal = get_portal()
    if portal == nil then
        -- Death-recovery branch: portal isn't visible (we're back at the
        -- checkpoint after dying). Target was picked by pick_recovery_target()
        -- using the priority chain (descend portal > boss > glyph > Choron's
        -- Soul > last-alive position). Long-path back until either the portal
        -- comes back into detection range, we get within RESPAWN_ARRIVAL_RADIUS
        -- of the target, or we time out.
        if _respawn_recovery_pos ~= nil then
            local now = get_time_since_inject()
            local dist = utils.distance(local_player, _respawn_recovery_pos)
            local kind = _respawn_recovery_kind or 'unknown'
            BatmobilePlugin.pause(plugin_label)
            BatmobilePlugin.update(plugin_label)
            local need_repath = false
            if not BatmobilePlugin.is_long_path_navigating()
                and (now - _respawn_long_path_t) > RESPAWN_PATH_RETRY
            then
                need_repath = true
            elseif _respawn_long_path_t == -math.huge then
                need_repath = true
            end
            if need_repath then
                console.print(string.format(
                    "[portal] respawn recovery: long_path back to %s target (dist=%.1f)",
                    kind, dist))
                local started = BatmobilePlugin.navigate_long_path(plugin_label, _respawn_recovery_pos)
                if not started then
                    console.print("[portal] respawn recovery long_path FAILED — retrying")
                end
                _respawn_long_path_t = now
            end
            BatmobilePlugin.move(plugin_label)
            task.status = string.format('respawn recovery → %s (%.0fu)', kind, dist)
            return
        end
        if task.portal_found then
            task.portal_found = false
            task.status = status_enum['RESETING']
            task.portal_exit = get_time_since_inject()
            _long_path_target = nil
            BatmobilePlugin.stop_long_path(plugin_label)
            BatmobilePlugin.reset(plugin_label)
            return
        end
    elseif utils.distance(local_player, portal) > 3 then
        BatmobilePlugin.pause(plugin_label)
        BatmobilePlugin.update(plugin_label)
        local portal_pos = portal:get_position()
        local portal_dist = utils.distance(local_player, portal)
        local now = get_time_since_inject()
        -- Close range: when within 7m of the portal, use force_move_raw directly
        -- instead of long_path. A tiny 2-3 node path gets consumed in a single
        -- navigator.move() tick, letting select_target pick a frontier and walk
        -- the bot away before the portal script can interact.
        if portal_dist < 7 then
            if BatmobilePlugin.is_long_path_navigating() then
                BatmobilePlugin.stop_long_path(plugin_label)
                _long_path_target = nil
            end
            pathfinder.force_move_raw(portal_pos)
            task.status = status_enum['WALKING']
            return
        end
        -- Re-issue long-path when:
        --   1. No path target set yet
        --   2. Portal position changed (shouldn't happen, but defensive)
        --   3. Long-path navigation has stopped (path completed or got cleared) and we
        --      still aren't within interact range. Without this check we end up paused
        --      forever staring at a portal we already half-walked toward.
        -- Throttle (3) to PATH_RETRY_INTERVAL so we don't burn get_closeby_node CPU.
        local need_repath = false
        if _long_path_target == nil then
            -- Throttle: don't retry until cooldown from last approach failure expires
            if (now - _approach_fail_time) > PATH_RETRY_INTERVAL then
                need_repath = true
            end
        elseif utils.distance(portal_pos, _long_path_target) > 3 then
            need_repath = true
        elseif not BatmobilePlugin.is_long_path_navigating()
            and (now - _last_path_issue) > PATH_RETRY_INTERVAL
        then
            console.print('[portal] long-path navigation ended but still ' ..
                string.format('%.1f', utils.distance(local_player, portal)) ..
                ' from portal — retrying')
            -- Long path ended without reaching the portal: signal cross_traversal
            -- so it can engage a nearby trav even if the next attempt also returns
            -- a partial path. Without this, the failure flag is only set on
            -- outright no_path returns — which happen later, after the bot has
            -- already drifted far from any nearby gizmo.
            task.long_path_failed_time = now
            need_repath = true
        end
        if need_repath then
            local approach = BatmobilePlugin.get_closeby_node(plugin_label, portal_pos, 5)
            if approach == nil then
                -- get_closeby_node failed (expensive standard A* timed out).
                -- Fall back to navigate_long_path directly to portal position;
                -- it uses uncapped iterations and can find paths around corners.
                console.print('[portal] no walkable approach within 5 — trying long_path directly to portal')
                local started = BatmobilePlugin.navigate_long_path(plugin_label, portal_pos)
                if started then
                    _long_path_target = portal_pos
                    _last_path_issue = now
                    _approach_fail_time = -math.huge
                else
                    console.print('[portal] long_path to portal also FAILED — cooldown retry')
                    BatmobilePlugin.stop_long_path(plugin_label)
                    _long_path_target = nil
                    _approach_fail_time = now
                    task.long_path_failed_time = now
                    task.status = status_enum['IDLE']
                    return
                end
            else
                console.print(string.format(
                    "[portal] long_path to approach (%.1f,%.1f) for portal at (%.1f,%.1f) dist=%.1f",
                    approach:x(), approach:y(), portal_pos:x(), portal_pos:y(),
                    portal_dist
                ))
                local started = BatmobilePlugin.navigate_long_path(plugin_label, approach)
                if started == false then
                    console.print('[portal] long_path FAILED — approach unreachable, cooldown retry')
                    BatmobilePlugin.stop_long_path(plugin_label)
                    _long_path_target = nil
                    _approach_fail_time = now
                    task.long_path_failed_time = now
                    task.status = status_enum['IDLE']
                    return
                end
                _long_path_target = portal_pos
                _last_path_issue = now
            end
        end
        BatmobilePlugin.move(plugin_label)
        task.status = status_enum['WALKING']
    else
        task.portal_found = true
        portal_just_used = true
        portal_used_time = get_time_since_inject()
        _long_path_target = nil
        BatmobilePlugin.stop_long_path(plugin_label)
        -- Reset per-floor boss state so detection / anchor / freeze don't
        -- carry into the next floor. Boss only spawns on the final floor; if
        -- we're crossing a portal we haven't fought it yet on this side.
        local tracker = require 'core.tracker'
        tracker.boss_kill_time = nil
        tracker.boss_seen = false
        tracker.boss_position = nil
        tracker.boss_dead = false
        tracker.glyph_anchor_pos = nil
        interact_object(portal)
        task.status = status_enum['INTERACTING']
    end
end

return task
