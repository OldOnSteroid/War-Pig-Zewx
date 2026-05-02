local plugin_label = 'arkham_asylum'

local utils = require 'core.utils'
local portal_task = require 'tasks.portal'

-- Higher-priority task than portal: when portal task can't pathfind around
-- a cliff/climb gizmo, this takes over and force-walks directly to the
-- traversal, then triggers interact_object once in range. Bypasses
-- get_closeby_node entirely (which fails when the gizmo's approach cells
-- are isolated from the player's position by cliff geometry).
--
-- Priority is held via a position-change cross-detector: once we engage a
-- traversal, cross_traversal keeps firing until the player teleports
-- (the cross completes) or the engagement times out. Without this hold,
-- portal task would re-engage 50ms after interact_object and pull the
-- player away from the climb mid-animation.
local task = {
    name = 'cross_traversal',
    status = 'idle',
}

local TRAV_SEARCH_RADIUS = 30      -- match navigator.try_traversal_route's cap
local INTERACT_DIST = 3            -- range at which interact_object fires
local INTERACT_COOLDOWN = 1.5      -- between interact retries while still engaged
local FAILURE_WINDOW = 5           -- seconds to honor portal_task's failure signal
local ENGAGEMENT_TIMEOUT = 12      -- max time on a single engagement before bailing
local CROSS_DETECT_DIST = 10       -- player position change indicating teleport/cross
local POST_CROSS_COOLDOWN = 5      -- after detected cross, suppress re-engagement so
                                   -- portal task gets a clean shot at the new floor's
                                   -- portal before cross_traversal can re-fire on the
                                   -- inverse climb gizmo right next to the landing.

local _last_interact_time = -math.huge
local _last_cross_time = -math.huge
local _engagement_start = -math.huge
local _engagement_pos = nil
local _interact_count = 0          -- interacts within current engagement
local _pos_at_last_interact = nil  -- player pos snapshotted at last interact
local INEFFECTIVE_THRESHOLD = 3    -- interacts without player moving = trav unusable
local INTERACT_RESPONSE_WINDOW = 2 -- if trav vanishes within Ns of our interact,
                                   -- treat as climb-starting (cross success)

local _trav_cache = nil
local _trav_cache_dist = nil
local _trav_cache_time = -1
local TRAV_CACHE_TTL = 0.1

-- Pick the best interactable Traversal_Gizmo within TRAV_SEARCH_RADIUS.
-- Direction-aware:
--   * If a portal is visible, prefer traversals going toward the portal's Z
--     level (Up if portal above, Down if portal below).
--   * If no portal info, prefer FreeClimb_Up — most pits ascend, and the
--     log showed the bot picking a closer Down gizmo when the Up was the
--     correct choice.
--   * Wrong-direction gizmos are excluded entirely (avoid bouncing between
--     a Down and Up sitting at the same cliff edge).
local function find_best_trav(local_player)
    local now = get_time_since_inject()
    if now - _trav_cache_time < TRAV_CACHE_TTL then
        return _trav_cache, _trav_cache_dist
    end
    local best_trav = nil
    local best_dist = math.huge
    local best_score = -math.huge
    if local_player ~= nil then
        local actors = actors_manager:get_all_actors()
        local player_pos = local_player:get_position()
        local player_z = player_pos:z()

        -- Determine which Z direction the portal is in (if any visible).
        local want_dir = 1   -- default: prefer Up (pit-typical)
        for _, actor in ipairs(actors) do
            local name = actor:get_skin_name()
            if name and name:match('Portal_Dungeon')
                and not name:match('Light_NoShadows')
                and actor:is_interactable()
            then
                local dz = actor:get_position():z() - player_z
                if dz > 1 then want_dir = 1
                elseif dz < -1 then want_dir = -1 end
                break
            end
        end

        for _, actor in ipairs(actors) do
            local name = actor:get_skin_name()
            if name and name:find('Traversal_Gizmo') and actor:is_interactable() then
                local d = utils.distance(player_pos, actor:get_position())
                if d <= TRAV_SEARCH_RADIUS then
                    local trav_dir = 0
                    if name:find('Up') then trav_dir = 1
                    elseif name:find('Down') then trav_dir = -1 end
                    -- Skip wrong-direction climbs entirely (Jump_*/Slide_* etc.
                    -- with trav_dir=0 are direction-neutral and stay eligible).
                    if trav_dir == 0 or trav_dir == want_dir then
                        local score = (trav_dir == want_dir and 100 or 0) - d
                        if score > best_score then
                            best_score = score
                            best_trav = actor
                            best_dist = d
                        end
                    end
                end
            end
        end
    end
    _trav_cache = best_trav
    _trav_cache_dist = best_trav and best_dist or nil
    _trav_cache_time = now
    return best_trav, best_dist
end

local function reset_engagement()
    _engagement_start = -math.huge
    _engagement_pos = nil
    _interact_count = 0
    _pos_at_last_interact = nil
end

task.shouldExecute = function ()
    if not utils.player_in_pit() then
        reset_engagement()
        return false
    end
    -- Active routing through navigator (via try_traversal_route success)
    if BatmobilePlugin.is_traversal_routing() then return true end

    local now = get_time_since_inject()
    local local_player = get_local_player()
    if not local_player then return false end

    -- Post-cross cooldown: after the player just teleported via a climb,
    -- the inverse gizmo on the new floor sits right next to them and the
    -- portal task often signals a transient failure mid-stabilization. Hold
    -- silent until the new floor settles so portal task can navigate freshly.
    if now - _last_cross_time < POST_CROSS_COOLDOWN then return false end

    -- Already engaged: hold priority until we detect the cross or hit the
    -- engagement timeout. Without this hold the next tick after interact_object
    -- yields to portal_task, which pulls the player away from the gizmo
    -- before the climb animation finishes.
    if _engagement_start > 0 then
        if now - _engagement_start > ENGAGEMENT_TIMEOUT then
            console.print('[cross_traversal] engagement timeout (' ..
                ENGAGEMENT_TIMEOUT .. 's) — yielding')
            reset_engagement()
            return false
        end
        if _engagement_pos ~= nil then
            local moved = utils.distance(local_player:get_position(), _engagement_pos)
            if moved > CROSS_DETECT_DIST then
                console.print(string.format(
                    '[cross_traversal] cross detected (moved %.1f units); yielding',
                    moved))
                -- Start the post-cross cooldown so the new floor's portal task
                -- gets a clean shot before cross_traversal can re-fire on the
                -- inverse climb gizmo right next to the landing point.
                _last_cross_time = now
                portal_task.long_path_failed_time = -math.huge
                reset_engagement()
                return false
            end
        end
        return true
    end

    -- New engagement: portal task signaled recent failure AND a usable
    -- traversal is interactable within range.
    if portal_task.long_path_failed_time + FAILURE_WINDOW < now then return false end
    return find_best_trav(local_player) ~= nil
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end

    -- If navigator's own trav routing engaged, drive it.
    if BatmobilePlugin.is_traversal_routing() then
        orbwalker.set_clear_toggle(true)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.move(plugin_label)
        task.status = 'nav_crossing'
        return
    end

    local trav, trav_dist = find_best_trav(local_player)
    if trav == nil then
        if _engagement_start > 0 then
            local now = get_time_since_inject()
            -- If the trav vanished shortly after we interacted, the gizmo
            -- toggled non-interactable because the climb is starting — treat
            -- it as a successful cross and trigger the post-cross cooldown
            -- so we don't immediately re-engage the inverse gizmo right at
            -- the landing point.
            if now - _last_interact_time < INTERACT_RESPONSE_WINDOW then
                console.print('[cross_traversal] trav gone post-interact — climb in progress')
                _last_cross_time = now
            else
                console.print('[cross_traversal] trav no longer interactable — yielding')
            end
            reset_engagement()
        end
        task.status = 'no_traversal_available'
        return
    end

    -- First tick of a new engagement: snapshot start state for cross detection.
    if _engagement_start <= 0 then
        _engagement_start = get_time_since_inject()
        _engagement_pos = local_player:get_position()
        console.print(string.format(
            '[cross_traversal] engaged %s at dist=%.1f',
            trav:get_skin_name(), trav_dist))
    end

    -- Take movement control: pause batmobile (stops explore_pit/select_target
    -- from setting competing targets) and block orbwalker movement (so it
    -- doesn't chase enemies away from the gizmo). Spell-casting stays on.
    orbwalker.set_clear_toggle(true)
    orbwalker.set_block_movement(true)
    BatmobilePlugin.pause(plugin_label)

    local trav_pos = trav:get_position()
    local now = get_time_since_inject()

    if trav_dist <= INTERACT_DIST then
        -- Throttle interact retries — calling every tick spams the engine.
        if now - _last_interact_time > INTERACT_COOLDOWN then
            -- Effectiveness check: if the previous interact didn't move the
            -- player, the gizmo isn't accepting our input (game cooldown,
            -- wrong-side approach, or already-used). Bail out fast instead
            -- of spamming until the engagement timeout fires.
            if _pos_at_last_interact ~= nil then
                local moved = utils.distance(
                    local_player:get_position(), _pos_at_last_interact)
                if _interact_count >= INEFFECTIVE_THRESHOLD and moved < 1 then
                    console.print(string.format(
                        '[cross_traversal] %d interacts ineffective (moved %.1f); yielding',
                        _interact_count, moved))
                    -- Trigger post-cross cooldown so we don't immediately
                    -- re-engage the same unusable gizmo.
                    _last_cross_time = now
                    reset_engagement()
                    return
                end
            end
            console.print(string.format('[cross_traversal] interacting %s (dist=%.1f)',
                trav:get_skin_name(), trav_dist))
            interact_object(trav)
            _last_interact_time = now
            _pos_at_last_interact = local_player:get_position()
            _interact_count = _interact_count + 1
        end
        task.status = 'interacting'
        return
    end

    -- Force-walk straight at the gizmo. Bypasses A* (which fails on isolated
    -- approach cells) and lets the engine's movement system handle short-range
    -- routing toward the position.
    pathfinder.force_move_raw(trav_pos)
    task.status = string.format('approaching (%.1f)', trav_dist)
end

return task
