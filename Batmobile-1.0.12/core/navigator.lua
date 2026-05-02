local explorer = require 'core.explorer'
local path_finder = require 'core.pathfinder'
local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'

local navigator = {
    last_pos = nil,
    last_update = nil,
    target = nil,
    done = false,
    paused = false,
    path = {},
    last_trav = nil,
    trav_delay = nil,
    done_delay = nil,
    movement_step = 4,
    movement_dist = math.sqrt(4*4*2), -- diagonal dist
    spell_dist = 12,
    spell_time = -1,
    spell_timeout = 0.5,
    blacklisted_spell_node = {},
    unstuck_nodes = {},
    unstuck_count = 0,
    pathfind_fail_count = 0,
    pathfind_area_cooldown = -1,   -- wall-clock time after which pathfinding is allowed again
    pathfind_replan_cooldown = -1, -- wall-clock time after which a *successful* replan is allowed
    exploration_resets = 0,
    failed_target = nil,
    failed_target_time = -1,
    failed_target_cooldown = 15,
    failed_target_radius = 15,
    trav_final_target = nil,
    blacklisted_trav = {},
    move_time = -1,
    move_timeout = 0.05,
    update_time = -1,
    update_timeout = 0.05,
    disable_spell = nil,
    is_custom_target = false,
    -- Post-traversal escape: push player away from the crossing point before resuming
    trav_escape_pos = nil,      -- traversal position when crossed; non-nil = escape phase active
    post_trav_target = nil,     -- { pos, is_custom } real target stored during escape
    -- Partial-path no-progress tracker: when A* keeps returning partial paths but the
    -- player can't get any closer to the target, give up after a timeout instead of
    -- spinning forever (pathfind_fail_count gets reset on every partial path, and
    -- unstuck_count gets reset by tiny oscillating movement).
    partial_target_ref = nil,
    partial_target_best_dist = math.huge,
    partial_target_last_progress_time = -1,
    -- Throttle for the top-level partial-path stall escape check, so a failed
    -- traversal-route attempt doesn't re-fire every tick.
    last_trav_route_attempt_time = -1,

    -- ────────────────────────────────────────────────────────────────────────
    -- Trap detection / recovery
    -- See update_trap_state() / attempt_escape() at the bottom of this file.
    -- ────────────────────────────────────────────────────────────────────────
    trap_pos_history          = {},   -- ring buffer of {pos, t} samples for bbox check
    trap_pos_sample_time      = -1,
    trapped                   = false,
    trapped_since             = nil,
    trapped_escape_count      = 0,
    trapped_last_escape_time  = -1,
    trapped_clear_time        = -1,   -- time when trap state was cleared (for HR cooldown)
    giving_up                 = false, -- HR polls via BatmobilePlugin.is_giving_up()

    -- Per-traversal-cross direction history for escape-direction preference.
    -- Each entry: { t = timestamp, delta_z = z_after - z_before }.
    trav_history              = {},
    pre_trav_z                = nil,   -- player z when last_trav was first assigned

    -- Long-term traversal blacklist set by trap escape.  Keyed by name+pos so
    -- duplicate-named gizmos at different positions are distinct.  Values are
    -- absolute expiry timestamps (not relative ages) so each entry can have
    -- its own duration.  Used to keep the bot from immediately descending back
    -- into a trap zone after escaping it.  Checked alongside blacklisted_trav
    -- in every traversal-selection site.
    trap_blacklisted_trav     = {},   -- name+pos -> expiry timestamp

    -- After attempt_escape routes the bot to a traversal, keep trap state
    -- active for this many seconds even if the bbox grows (the climb
    -- naturally widens the bbox).  Lets the next attempt_escape fire on the
    -- NEW floor and find that floor's escape gizmo (e.g. F1 → F2 via climb,
    -- then F2 → F3 via second climb without dropping out of trap mode).
    trap_post_escape_grace_until = -1,
}

-- Tunables (kept as locals so they're visible in code but not part of the
-- navigator table that external callers can stomp on).
local TRAP_SAMPLE_INTERVAL  = 1.0   -- seconds between position samples
local TRAP_HISTORY_MAX      = 35    -- ~35 samples ≈ 35s of history
local TRAP_DETECT_WINDOW    = 30    -- seconds of bbox history to consider
local TRAP_BBOX_THRESHOLD   = 25    -- trapped if both bbox dimensions < this
local TRAP_MIN_SAMPLES      = 20    -- need this many samples before trap can fire
local TRAP_ESCAPE_COOLDOWN  = 5     -- seconds between escape attempts
local TRAP_GIVEUP_TIMEOUT   = 60    -- seconds in trapped state before giving_up=true
local TRAV_HISTORY_MAX      = 5     -- recent traversals to consider for direction
local TRAV_TRAP_BL_DURATION = 300   -- seconds to long-blacklist trap re-entry gizmos
local TRAP_POST_ESCAPE_GRACE = 15   -- seconds to keep trap active after escape routes

-- Combined check: returns true if a traversal is blacklisted by either the
-- short-term (15s) post-crossing list OR the long-term trap-escape list.
-- Always pass the full name+position string (`trav_str`).  Time arg is
-- supplied by the caller so we don't call get_time_since_inject() twice.
local function is_trav_blacklisted(trav_str, now)
    local bl_time = navigator.blacklisted_trav[trav_str]
    if bl_time ~= nil and type(bl_time) == "number" and (now - bl_time) < 15 then
        return true
    end
    local trap_until = navigator.trap_blacklisted_trav[trav_str]
    if trap_until ~= nil and type(trap_until) == "number" and now < trap_until then
        return true
    end
    return false
end

-- Compute a walkable escape waypoint away from trav_pos in the direction of player_pos.
-- Tries decreasing distances so that narrow platforms (top of a ladder, small ledge)
-- still get a valid escape point rather than a point off the edge that A* rejects.
local TRAV_ESCAPE_DIST = 5   -- maximum desired escape distance (reduced from 20 to prevent bounce-back)
local TRAV_ESCAPE_MIN  = 3   -- minimum fallback escape distance
local function compute_escape_target(trav_pos, player_pos)
    local dx = player_pos:x() - trav_pos:x()
    local dy = player_pos:y() - trav_pos:y()
    local len = math.sqrt(dx*dx + dy*dy)
    if len < 0.1 then dx, dy = 1, 0 else dx, dy = dx/len, dy/len end
    -- Walk from max to min distance, return first walkable point found
    local dist = TRAV_ESCAPE_DIST
    while dist >= TRAV_ESCAPE_MIN do
        local pt = vec3:new(
            player_pos:x() + dx * dist,
            player_pos:y() + dy * dist,
            player_pos:z()
        )
        pt = utility.set_height_of_valid_position(pt)
        if utility.is_point_walkeable(pt) then
            return pt
        end
        dist = dist - 5
    end
    -- Last resort: minimum nudge (may not be walkable but better than nothing)
    local pt = vec3:new(
        player_pos:x() + dx * TRAV_ESCAPE_MIN,
        player_pos:y() + dy * TRAV_ESCAPE_MIN,
        player_pos:z()
    )
    return utility.set_height_of_valid_position(pt)
end

-- Per-frame caching to avoid redundant expensive calls.
-- 50ms cache: traversal actors don't move, so a slightly stale list is safe
-- and the 13Hz update loop hits the cache ~3-4 times per refresh instead of
-- almost always missing the previous 10ms TTL.
local _cache_duration = 0.05
local _trav_cache = nil
local _trav_cache_time = -1
local _buff_cache = nil
local _buff_cache_time = -1
local get_nearby_travs = function (local_player)
    -- Cache: scanning all actors is expensive, avoid doing it 2-3x per frame
    local now = get_time_since_inject()
    if now - _trav_cache_time < _cache_duration then
        return _trav_cache
    end
    tracker.bench_start("get_nearby_travs")
    local traversals = {}
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        if name:match('[Tt]raversal_Gizmo') then
            traversals[#traversals+1] = actor
        end
    end
    _trav_cache = traversals
    _trav_cache_time = now
    tracker.bench_stop("get_nearby_travs")
    return traversals
end
local has_traversal_buff = function (local_player)
    -- Cache: buff scanning called 3-4x per frame, only need to scan once
    local now = get_time_since_inject()
    if _buff_cache ~= nil and now - _buff_cache_time < _cache_duration then
        return _buff_cache
    end
    local buffs = local_player:get_buffs()
    for _, buff in pairs(buffs) do
        if buff:name():match('Player_Traversal')  then
            _buff_cache = true
            _buff_cache_time = now
            return true
        end
    end
    _buff_cache = false
    _buff_cache_time = now
    return false
end
local get_closeby_node = function (trav_node, max_dist)
    tracker.bench_start("get_closeby_node")
    local local_player = get_local_player()
    if not local_player then
        tracker.bench_stop("get_closeby_node")
        return nil
    end
    local cur_node = utils.normalize_node(local_player:get_position())
    local norm_trav = utils.normalize_node(trav_node)
    local step = settings.step

    local nodes = {}
    for i = norm_trav:x()-max_dist, norm_trav:x()+max_dist, step do
        for j = norm_trav:y()-max_dist, norm_trav:y()+max_dist, step do
            local new_node =  vec3:new(i, j, cur_node:z())
            local valid = utility.set_height_of_valid_position(new_node)
            local walkable = utility.is_point_walkeable(valid)
            local diff_z = utils.distance_z(trav_node, valid)
            if walkable and diff_z < 1 then
                nodes[#nodes+1] = new_node
            end
        end
    end
    table.sort(nodes, function(a, b)
        return utils.distance(a, norm_trav) < utils.distance(b, norm_trav)
    end)
    -- Share evaluated (walkability) cache across find_path calls:
    -- nearby goals overlap heavily in A* exploration, so reusing the cache
    -- avoids thousands of redundant engine walkability checks
    local shared_eval = {}
    local max_attempts = 8  -- limit expensive pathfinding; if closest 8 nodes unreachable, portal is blocked
    local attempts = 0
    -- Tight per-attempt time cap: this is a feasibility check, not navigation.
    -- 8 attempts × 40ms = 320ms worst case (vs 1200ms with the default 150ms).
    -- A real path is much shorter than this; if 40ms isn't enough, the goal
    -- is realistically unreachable and we should move on.
    local CLOSEBY_TIME_CAP = 0.040
    for _, node in ipairs(nodes) do
        if attempts >= max_attempts then break end
        local result, is_partial = path_finder.find_path(
            cur_node, node, navigator.is_custom_target, shared_eval, CLOSEBY_TIME_CAP)
        attempts = attempts + 1
        if #result > 0 and not is_partial then
            tracker.bench_stop("get_closeby_node", string.format(
                "max_dist=%d candidates=%d attempts=%d ok",
                max_dist, #nodes, attempts))
            return node
        end
    end
    tracker.bench_stop("get_closeby_node", string.format(
        "max_dist=%d candidates=%d attempts=%d EXHAUSTED",
        max_dist, #nodes, attempts))
    return nil
end
-- Try routing through a nearby traversal to reach navigator.target. Returns
-- (true, trav) if traversal routing was engaged (caller should `return`),
-- (false, trav) if a traversal was found but its approach node wasn't usable
-- (caller can use trav for blacklist-radius decisions), or (false, nil) if
-- no usable traversal exists nearby.
local function try_traversal_route(local_player, player_pos)
    -- Don't engage during trap escape: attempt_escape is the sole authority
    -- for traversal selection while trapped (or in post-escape grace).  Without
    -- this guard, the "stuck → nearest traversal" heuristic here would happily
    -- pick the Down gizmo right back into the trap we just escaped from
    -- (logzewx showed bot crossing F1→F2 then immediately F2→F1 via this path).
    local now = get_time_since_inject()
    if navigator.trapped or now < navigator.trap_post_escape_grace_until then
        return false, nil
    end
    local nearby_travs = get_nearby_travs(local_player)
    local closest_trav = nil
    local closest_trav_dist = math.huge
    local now_for_bl = now
    for _, trav in ipairs(nearby_travs) do
        local d = utils.distance(player_pos, trav:get_position())
        local trav_str = trav:get_skin_name() .. utils.vec_to_string(trav:get_position())
        if d <= 30 and d < closest_trav_dist and not is_trav_blacklisted(trav_str, now_for_bl) then
            closest_trav = trav
            closest_trav_dist = d
        end
    end
    if closest_trav == nil then return false, nil end
    local trav_pos = closest_trav:get_position()
    local approach_node = get_closeby_node(trav_pos, 2)
    -- Wider fallback: gizmos near cliff edges often have all walkable cells
    -- within 2 units isolated from the player's position. 5 units gives A*
    -- more candidates on the player's side of the cliff before giving up.
    if approach_node == nil then
        approach_node = get_closeby_node(trav_pos, 5)
    end
    if approach_node == nil then return false, closest_trav end
    console.print('[nav] routing via traversal ' .. closest_trav:get_skin_name() ..
        ' to reach ' .. utils.vec_to_string(navigator.target) ..
        ' (paused=' .. tostring(navigator.paused) .. ')')
    tracker.bench_count("trav_route_attempt")
    -- Preserve the original destination so we can restore it after crossing.
    navigator.trav_final_target = navigator.target
    navigator.last_trav = closest_trav
    -- Snapshot player z so trap-escape can record the crossing's direction.
    navigator.pre_trav_z = local_player:get_position():z()
    navigator.target = approach_node
    navigator.is_custom_target = false
    navigator.path = {}
    navigator.pathfind_fail_count = 0
    return true, closest_trav
end
local get_movement_spell_id = function(local_player)
    if not settings.use_movement then return end
    if navigator.disable_spell == true then return end
    if navigator.spell_time + navigator.spell_timeout > get_time_since_inject() then return end
    navigator.spell_time = get_time_since_inject()
    local class = utils.get_character_class(local_player)
    if class == 'sorcerer' then
        if settings.use_teleport and utility.can_cast_spell(288106) then
            return 288106, false
        end
        if settings.use_teleport_enchanted and utility.can_cast_spell(959728) then
            return 959728, false
        end
    elseif class == 'spiritborn' then
        if settings.use_soar and utility.can_cast_spell(1871821) then
            return 1871821, false
        end
        if settings.use_rushing_claw and utility.can_cast_spell(1871761) then
            return 1871761, false
        end
        if settings.use_hunter and utility.can_cast_spell(1663206) then
            return 1663206, false
        end
    elseif class == 'rogue' then
        if settings.use_dash and utility.can_cast_spell(358761) then
            return 358761, false
        end
    elseif class == 'barbarian' then
        if settings.use_leap and utility.can_cast_spell(196545) then
            return 196545, false
        end
        if settings.use_charge and utility.can_cast_spell(204662) then
            return 204662, true
        end
    elseif class == 'paladin' then
        if settings.use_advance and utility.can_cast_spell(2329865) then
            return 2329865, true
        end
        if settings.use_falling_star and utility.can_cast_spell(2106904) then
            return 2106904, true
        end
        if settings.use_aoj and utility.can_cast_spell(2297125) then
            return 2297125, true
        end
    end
    -- class == 'default' or class == 'druid' or class == 'necromancer'
    -- everyone has evade (hopefully)
    if settings.use_evade and utility.can_cast_spell(337031) then
        return 337031, false
    end
    return nil, false
end
local select_target
select_target = function (prev_target)
    local local_player = get_local_player()
    if not local_player then return nil end
    local player_pos = local_player:get_position()
    local traversals = get_nearby_travs(local_player)
    -- Destination-aware traversal selection: only pick a traversal when the last
    -- pathfind was partial (couldn't reach goal) AND the traversal is roughly in
    -- the direction of the destination. This prevents unintentional climbing when
    -- just walking past a traversal on a successful path.
    -- Also: skip during trap escape — attempt_escape owns traversal selection
    -- while trapped or in post-escape grace.
    local now_for_trap = get_time_since_inject()
    local in_trap_or_grace = navigator.trapped
        or now_for_trap < navigator.trap_post_escape_grace_until
    local should_try_trav = (navigator.is_partial_path or navigator.pathfind_fail_count > 0)
        and not in_trap_or_grace
    if #traversals > 0 and should_try_trav then
        local closest_trav = nil
        local closest_dist = nil
        local closest_pos = nil
        local closest_str = nil
        local now_for_bl = get_time_since_inject()
        for _, trav in ipairs(traversals) do
            local trav_pos = trav:get_position()
            local trav_name = trav:get_skin_name()
            local trav_str = trav_name .. utils.vec_to_string(trav_pos)
            local cur_dist = utils.distance_z(player_pos, trav_pos)
            -- Combined blacklist: short-term post-crossing (15s) and long-term
            -- trap-escape (5min) — both keyed by name+position so duplicate
            -- gizmo names at different positions remain distinct.
            local is_blacklisted = is_trav_blacklisted(trav_str, now_for_bl)
            if not is_blacklisted and
                (closest_trav == nil or cur_dist < closest_dist) and
                utils.distance(player_pos, trav_pos) <= 15
            then
                closest_dist = cur_dist
                closest_trav = trav
                closest_pos = trav_pos
                closest_str = trav_str
            end
        end
        -- local diff_z = utils.distance_z(closest_pos, player_pos)
        if closest_trav ~= nil and
            closest_dist <= 15 and
            navigator.last_trav == nil and
            closest_pos ~= nil and
            math.abs(closest_pos:z() - player_pos:z()) <= 3 and
            (navigator.trav_delay == nil or get_time_since_inject() > navigator.trav_delay)
        then
            -- Direction check: only select if traversal is roughly toward the destination
            local dir_ok = true
            if prev_target ~= nil then
                local to_target_x = prev_target:x() - player_pos:x()
                local to_target_y = prev_target:y() - player_pos:y()
                local to_trav_x   = closest_pos:x() - player_pos:x()
                local to_trav_y   = closest_pos:y() - player_pos:y()
                local dot = to_target_x * to_trav_x + to_target_y * to_trav_y
                -- dot > 0 means traversal is in the same half-plane as the destination
                dir_ok = dot > 0
            end
            if dir_ok then
                local closest_node = get_closeby_node(closest_trav:get_position(), 2)
                if closest_node == nil then
                    navigator.blacklisted_trav[closest_str] = get_time_since_inject()
                    return select_target(prev_target)
                end
                navigator.last_trav = closest_trav
                -- Snapshot player z so trap-escape can record the crossing's direction.
                navigator.pre_trav_z = player_pos:z()
                utils.log(1, 'selecting traversal ' .. closest_trav:get_skin_name() .. ' (path was partial/failing, direction OK)')
                return closest_node
            end
        end
    elseif #traversals == 0 then
        navigator.last_trav = nil
        -- Expire old blacklist entries instead of clearing all at once
        local now = get_time_since_inject()
        for k, v in pairs(navigator.blacklisted_trav) do
            if type(v) == "number" and (now - v) > 15 then
                navigator.blacklisted_trav[k] = nil
            end
        end
        -- Same for the long-term trap blacklist (entries store absolute
        -- expiry timestamps, so the comparison is `now > expiry`).
        for k, expiry in pairs(navigator.trap_blacklisted_trav) do
            if type(expiry) == "number" and now > expiry then
                navigator.trap_blacklisted_trav[k] = nil
            end
        end
    end
    local target = explorer.select_node(local_player, prev_target)
    if target ~= nil then
        local dist = utils.distance(local_player:get_position(), target)
        console.print('[select_target] picked ' .. utils.vec_to_string(target) .. ' dist=' .. string.format('%.1f', dist) .. ' frontiers=' .. explorer.frontier_count .. ' bt=#' .. #explorer.backtrack .. ' bting=' .. tostring(explorer.backtracking))
    else
        console.print('[select_target] nil, frontiers=' .. explorer.frontier_count .. ' bt=#' .. #explorer.backtrack)
    end
    return target
end
local function shuffle_table(tbl)
    local len = #tbl
    for i = len, 2, -1 do
        -- Generate a random index 'j' between 1 and 'i' (inclusive)
        local j = math.random(i)
        -- Swap the elements at positions 'i' and 'j'
        tbl[i], tbl[j] = tbl[j], tbl[i]
    end
    return tbl
end
local get_unstuck_node = function ()
    -- get a node that is perpendicular to the first node in path from current node
    -- i.e. turn 90 degress left or right 
    local cur_node = navigator.last_pos
    local step = navigator.movement_step
    local test_node, test_node_str, valid, walkable

    if cur_node ~= nil then
        local x = cur_node:x()
        local y = cur_node:y()

        local directions = {
            {-step, 0},  -- up
            {0, step}, -- right
            {step, 0}, -- down
            {0, -step}, -- left
            {-step, step}, -- up-right
            {-step, -step}, -- up-left
            {step, step}, -- down-right
            {step, -step}, -- down-left
        }
        -- randomize direction order
        directions = shuffle_table(directions)
        for _, direction in ipairs(directions) do
            local dx = direction[1]
            local dy = direction[2]
            local new_x = x + dx
            local new_y = y + dy
            test_node = vec3:new(new_x, new_y, cur_node:z())
            test_node_str = utils.vec_to_string(test_node)
            valid = utility.set_height_of_valid_position(test_node)
            walkable = utility.is_point_walkeable(valid)
            if walkable and navigator.unstuck_nodes[test_node_str] ~= 'injected' then
                return valid, test_node_str
            end
        end
    end
    return nil, nil
end
local unstuck = function (local_player)
    navigator.unstuck_count = navigator.unstuck_count + 1

    -- After too many consecutive unstuck attempts, blacklist the area and force a new target
    if navigator.unstuck_count >= 5 then
        console.print('[unstuck] EXHAUSTED (' .. navigator.unstuck_count .. ' attempts), blacklisting 16x16 area around ' .. (navigator.last_pos and utils.vec_to_string(navigator.last_pos) or 'nil'))
        local pos = navigator.last_pos
        if pos then
            local step = settings.step or 2
            for i = -8, 8, step do
                for j = -8, 8, step do
                    local node_str = tostring(utils.normalize_value(pos:x() + i)) .. ',' .. tostring(utils.normalize_value(pos:y() + j))
                    explorer.visited[node_str] = node_str
                end
            end
        end
        navigator.target = select_target(navigator.target)
        navigator.is_custom_target = false
        navigator.unstuck_nodes = {}
        navigator.unstuck_count = 0
        return
    end

    local unstuck_node, unstuck_node_str = get_unstuck_node()
    if unstuck_node ~= nil and unstuck_node_str ~= nil then
        -- try evade if not add to path
        local movement_spell_id, need_raycast = get_movement_spell_id(local_player)
        local raycast_success = true
        if need_raycast then
            local dist = utils.distance(navigator.last_pos, unstuck_node)
            raycast_success = utility.is_ray_cast_walkeable(navigator.last_pos, unstuck_node, 0.5, dist)
        end
        if utility.can_cast_spell(337031) and
            navigator.unstuck_nodes[unstuck_node_str] == nil
        then
            utils.log(1, 'unstuck by evading')
            navigator.unstuck_nodes[unstuck_node_str] = 'evaded'
            cast_spell.position(337031, unstuck_node, 0)
            return
        elseif movement_spell_id ~= nil and raycast_success and
            (navigator.unstuck_nodes[unstuck_node_str] == nil or
            navigator.unstuck_nodes[unstuck_node_str] == 'evaded')
        then
            utils.log(1, 'unstuck by movement spell')
            navigator.unstuck_nodes[unstuck_node_str] = 'teleporting'
            cast_spell.position(movement_spell_id, unstuck_node, 0)
            return
        else
            utils.log(1, 'unstuck by injecting path')
            navigator.unstuck_nodes[unstuck_node_str] = 'injected'
            table.insert(navigator.path, 1, unstuck_node)
            return
        end
    end
    utils.log(1, 'unstuck by choosing new target')
    navigator.target = select_target(navigator.target)
    navigator.is_custom_target = false
    navigator.unstuck_nodes = {}
end
navigator.is_done = function ()
    return navigator.done
end
navigator.pause = function ()
    navigator.paused = true
    tracker.paused = true
end
navigator.unpause = function ()
    navigator.paused = false
    tracker.paused = false
end
navigator.update = function ()
    if navigator.update_time + navigator.update_timeout > get_time_since_inject() then
        tracker.bench_count("update_skipped_throttle")
        return
    end
    navigator.update_time = get_time_since_inject()
    tracker.bench_count("update_ran")
    local local_player = get_local_player()
    if not local_player then return end
    if has_traversal_buff(local_player) then
        tracker.bench_count("update_skipped_buff")
        return
    end
    -- Detect death/respawn: sudden large position jump (>50 units) that is not a traversal.
    -- After respawn the checkpoint position must NOT be appended to the backtrack path —
    -- doing so creates a spurious backtrack entry that doubles up the exploration route.
    -- Setting backtracking=true prevents set_current_pos from adding the checkpoint,
    -- so the next select_target call directly pops the real last-explored point.
    if explorer.cur_pos ~= nil and
        (navigator.trav_delay == nil or get_time_since_inject() > navigator.trav_delay)
    then
        local jump_dist = utils.distance(local_player:get_position(), explorer.cur_pos)
        if jump_dist > 50 then
            console.print('[nav] respawn detected (jumped ' .. string.format('%.1f', jump_dist) .. ' units), resuming from last backtrack point')
            explorer.backtracking = true
            navigator.target = nil
            navigator.is_custom_target = false
            navigator.path = {}
            navigator.trav_final_target = nil
            navigator.failed_target = nil
        end
    end
    tracker.bench_start("nav_explorer_update")
    explorer.update(local_player)
    tracker.bench_stop("nav_explorer_update")
end
-- reset_movement: clears only movement/pathfinding state; preserves explorer's
-- visited/backtrack/frontier so long-session exploration is not lost.
-- Use this for mid-session interruptions (death, stuck, traversal recovery).
-- Use reset() only for full session restarts.
navigator.reset_movement = function ()
    utils.log(1, 'reset_movement (exploration state preserved)')
    navigator.target = nil
    navigator.is_custom_target = false
    navigator.done = false
    navigator.done_delay = nil
    navigator.path = {}
    navigator.last_trav = nil
    navigator.trav_delay = nil
    navigator.last_pos = nil
    navigator.last_update = nil
    navigator.unstuck_nodes = {}
    navigator.unstuck_count = 0
    navigator.pathfind_fail_count = 0
    navigator.is_partial_path = false
    navigator.pathfind_area_cooldown = -1
    navigator.pathfind_replan_cooldown = -1
    navigator.failed_target = nil
    navigator.failed_target_time = -1
    navigator.failed_target_radius = 15
    navigator.trav_final_target = nil
    navigator.blacklisted_trav = {}
    navigator.blacklisted_spell_node = {}
    navigator.trav_escape_pos = nil
    navigator.post_trav_target = nil
    navigator.partial_target_ref = nil
    navigator.partial_target_best_dist = math.huge
    navigator.partial_target_last_progress_time = -1
    navigator.last_trav_route_attempt_time = -1
end
navigator.reset = function ()
    utils.log(1, 'reseting')
    explorer.reset()
    navigator.reset_movement()
    navigator.exploration_resets = 0
    -- Wall-ring penalty is cached against the static walkable grid; a full
    -- reset implies map/zone change, so the cache may be stale.
    if path_finder.clear_wall_penalty_cache then
        path_finder.clear_wall_penalty_cache()
    end
    -- Trap state is per-zone; never carry it across a full reset.  Use the
    -- exposed clearer rather than touching internals.
    if navigator.clear_trap_state then
        navigator.clear_trap_state()
    end
    navigator.trav_history = {}
    navigator.pre_trav_z   = nil
end
navigator.set_target = function (target, disable_spell)
    if target.get_position then
        target = target:get_position()
    end
    local new_target = utils.normalize_node(target)
    -- Reject targets near a recently-failed position
    if navigator.failed_target and
        utils.distance(new_target, navigator.failed_target) < navigator.failed_target_radius and
        get_time_since_inject() - navigator.failed_target_time < navigator.failed_target_cooldown
    then
        tracker.bench_count("set_target_rejected_failed")
        return false
    end
    -- Post-traversal escape in progress: store the caller's target for later restoration
    -- but don't let it override the escape waypoint.
    if navigator.trav_escape_pos ~= nil then
        navigator.post_trav_target = { pos = new_target, is_custom = true }
        return true
    end
    -- If we are mid-traversal to reach a custom target, don't disrupt the route
    -- (kill_monster keeps calling set_target every frame; return true so it doesn't
    -- mark the enemy unreachable, but keep routing to the traversal node)
    if navigator.trav_final_target ~= nil and navigator.last_trav ~= nil then
        if utils.distance(new_target, navigator.trav_final_target) < 50 then
            return true  -- silently accepted — traversal route in progress
        else
            -- Different enemy: abort traversal route, accept new target
            navigator.trav_final_target = nil
        end
    end
    local target_moved = navigator.target ~= nil and utils.distance(navigator.target, new_target) > 2
    tracker.bench_count("set_target_call")
    if navigator.target == nil or
        target_moved or
        navigator.disable_spell ~= disable_spell
    then
        navigator.failed_target = nil
        navigator.target = new_target
        navigator.is_custom_target = true
        -- Only clear the path when the target moved far enough to matter.
        -- For moving enemies (kill_monsters calls set_target every frame) a sub-2-unit
        -- drift is noise — keep the existing path to avoid triggering A* every 50ms.
        if navigator.path == nil or #navigator.path == 0 or target_moved then
            navigator.path = {}
            navigator.pathfind_fail_count = 0
            navigator.pathfind_replan_cooldown = -1  -- new target: allow immediate pathfind
            tracker.bench_count("set_target_replan")
        else
            tracker.bench_count("set_target_keep_path")
        end
    else
        tracker.bench_count("set_target_drift_noise")
    end
    explorer.backtracking = false
    return true
end
navigator.clear_target = function ()
    navigator.target = nil
    navigator.is_custom_target = false
    navigator.path = {}
    navigator.disable_spell = nil
    navigator.pathfind_replan_cooldown = -1
end
navigator.move = function ()
    if navigator.move_time + navigator.move_timeout > get_time_since_inject() then
        tracker.bench_count("move_skipped_throttle")
        return
    end
    navigator.move_time = get_time_since_inject()
    tracker.bench_count("move_ran")
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = local_player:get_position()
    local cur_node = utils.normalize_node(player_pos)
    -- Update nav state snapshot for perf report (cheap string, overwritten every allowed frame)
    if tracker.bench_enabled then
        tracker.bench_nav_state = string.format(
            "paused=%s  custom=%s  trav_routing=%s  last_trav=%s  pfail=%d  unstuck=%d  path_len=%d  trapped=%s",
            tostring(navigator.paused),
            tostring(navigator.is_custom_target),
            tostring(navigator.trav_final_target ~= nil),
            tostring(navigator.last_trav ~= nil),
            navigator.pathfind_fail_count,
            navigator.unstuck_count,
            #navigator.path,
            tostring(navigator.trapped))
    end
    -- Trap detection runs every move() tick; sampling and bbox check are
    -- internally rate-limited.  attempt_escape only fires while trapped.
    navigator.update_trap_state(local_player)
    if navigator.trapped then
        navigator.attempt_escape(local_player)
    end
    local traversals = get_nearby_travs(local_player)
    tracker.bench_start("nav_trav_block")
    if #traversals > 0 then
        local trav = navigator.last_trav
        if trav ~= nil and utils.distance(player_pos, trav:get_position()) <= 3 and
            (navigator.trav_delay == nil or get_time_since_inject() > navigator.trav_delay)
        then
            -- Snapshot pre-cross z RIGHT NOW (just before interact) — but
            -- ONLY if it's not already set this crossing.  pre_trav_z is
            -- cleared after buff detection, so nil = first interact for THIS
            -- crossing.  If the buff hasn't fired yet and we're firing a
            -- retry interact (after the 2s cooldown), we want to KEEP the
            -- original z so dz on eventual buff-detect reflects the FULL
            -- climb height — not just the tiny mid-climb position delta.
            if navigator.pre_trav_z == nil then
                navigator.pre_trav_z = player_pos:z()
            end
            interact_object(trav)
            local name = trav:get_skin_name()
            if not name:match('Jump') then
                -- Non-jump traversals (ladders, FreeClimb, etc.) have a traversal buff
                -- but it can be very short — short enough to be missed at the 50ms poll
                -- rate.  Set a 2s interact cooldown immediately so we don't spam
                -- interact_object every frame while the player is climbing.  Also clear
                -- the stale approach-node path and target so the player doesn't follow
                -- them back to the base of the ladder if the buff is never detected.
                navigator.trav_delay = get_time_since_inject() + 2
                navigator.path = {}
                navigator.target = nil
                navigator.is_custom_target = false
                local trav_pos_log = trav:get_position()
                console.print(string.format(
                    '[nav] non-jump traversal interacted: %s @(%.1f,%.1f,%.2f) | player @(%.1f,%.1f,%.2f) | waiting for buff (2s cooldown)',
                    name, trav_pos_log:x(), trav_pos_log:y(), trav_pos_log:z(),
                    player_pos:x(), player_pos:y(), player_pos:z()))
            end
            if name:match('Jump') then
                -- jump doesnt have traversal buff for some reason
                navigator.path = {}
                navigator.disable_spell = nil
                local trav_pos = trav:get_position()
                local crossed_str = trav:get_skin_name() .. utils.vec_to_string(trav_pos)
                -- Only blacklist the exact crossed gizmo with a timestamp (15s cooldown)
                navigator.blacklisted_trav[crossed_str] = get_time_since_inject()
                console.print('[nav] blacklisting jumped traversal ' .. trav:get_skin_name())
                navigator.last_trav = nil
                navigator.trav_delay = get_time_since_inject() + 4
                navigator.failed_target = nil
                navigator.failed_target_radius = 15
                -- Short escape to avoid re-triggering the landing-side gizmo,
                -- then re-plan toward the original destination from the new position.
                local escape_pt = compute_escape_target(trav_pos, player_pos)
                navigator.trav_escape_pos = trav_pos
                -- Preserve the original destination: store it for restoration after
                -- the brief escape, whether it was a custom target or explorer target.
                if navigator.trav_final_target ~= nil then
                    console.print('[nav] jump crossed, brief escape then restoring target ' .. utils.vec_to_string(navigator.trav_final_target))
                    navigator.post_trav_target = { pos = navigator.trav_final_target, is_custom = true }
                    navigator.trav_final_target = nil
                elseif navigator.paused and navigator.target ~= nil then
                    navigator.post_trav_target = { pos = navigator.target, is_custom = navigator.is_custom_target }
                else
                    navigator.post_trav_target = nil
                end
                navigator.target = escape_pt
                navigator.is_custom_target = false
                navigator.pathfind_fail_count = 0
                navigator.is_partial_path = false
                console.print('[nav] post-jump escape target: ' .. utils.vec_to_string(escape_pt))
            end
        end
        if has_traversal_buff(local_player) then
            tracker.bench_count("trav_crossed")
            navigator.trav_delay = get_time_since_inject() + 4
            navigator.path = {}
            navigator.disable_spell = nil
            local trav_pos_for_escape = navigator.last_trav and navigator.last_trav:get_position() or nil
            -- Record the crossing's direction (from gizmo NAME) so trap-escape
            -- can detect ping-pong and prefer the opposite direction.
            -- We can't trust measured dz at buff-detect time: the buff fires
            -- at the START of the climb animation, before the player's z
            -- reaches the destination floor.  Logzewx showed real F1->F2
            -- climbs reading dz=+0.06.  Names ('Up'/'Down' substrings) are
            -- unambiguous and known the moment the gizmo is selected.
            local crossing_dz = nil
            local crossing_dir = 0
            if navigator.last_trav ~= nil then
                local n = navigator.last_trav:get_skin_name()
                local has_up   = n:match('Up') ~= nil
                local has_down = n:match('Down') ~= nil
                if has_up and not has_down then crossing_dir =  1
                elseif has_down and not has_up then crossing_dir = -1
                end
            end
            if navigator.pre_trav_z ~= nil then
                crossing_dz = player_pos:z() - navigator.pre_trav_z
                navigator.pre_trav_z = nil
            end
            -- Always append, even if pre_trav_z was nil — direction-from-name
            -- is the load-bearing field for ping-pong detection.
            navigator.trav_history[#navigator.trav_history + 1] = {
                t        = get_time_since_inject(),
                delta_z  = crossing_dz,    -- informational only; may be ~0
                direction = crossing_dir,  -- +1 up, -1 down, 0 unknown/jump
            }
            if #navigator.trav_history > TRAV_HISTORY_MAX then
                table.remove(navigator.trav_history, 1)
            end
            if navigator.last_trav ~= nil then
                local crossed_str = navigator.last_trav:get_skin_name() .. utils.vec_to_string(navigator.last_trav:get_position())
                -- Only blacklist the exact crossed gizmo with a timestamp (15s cooldown)
                navigator.blacklisted_trav[crossed_str] = get_time_since_inject()
                local trav_pos_log = navigator.last_trav:get_position()
                console.print(string.format(
                    '[nav] blacklisting crossed traversal %s @(%.1f,%.1f,%.2f) | player @(%.1f,%.1f,%.2f) | dz=%s dir=%+d',
                    navigator.last_trav:get_skin_name(),
                    trav_pos_log:x(), trav_pos_log:y(), trav_pos_log:z(),
                    player_pos:x(), player_pos:y(), player_pos:z(),
                    crossing_dz and string.format('%+.2f', crossing_dz) or 'nil',
                    crossing_dir))
            end
            navigator.last_trav = nil
            navigator.failed_target = nil
            navigator.failed_target_radius = 15
            navigator.is_partial_path = false
            -- Reset stuck detection state: a successful cross teleports the
            -- player but doesn't always change x/y enough to trip the normal
            -- last_pos update.  Without this, STUCK fires immediately after
            -- the cross and unstuck() can pull the player back AWAY from the
            -- post-trav escape target — sometimes mid-walk to a follow-up
            -- traversal that trap-escape just routed to.
            navigator.last_update     = get_time_since_inject()
            navigator.last_pos        = cur_node
            navigator.unstuck_nodes   = {}
            navigator.unstuck_count   = 0

            -- ──────────────────────────────────────────────────────────────
            -- CHAIN ESCAPE
            -- After a same-direction cross, scan for ANOTHER gizmo of the
            -- same direction on the new floor.  If found nearby, route
            -- directly to it — skip the explorer's frontier-pick/walk cycle
            -- that often partial-paths back into the trap before the next
            -- attempt_escape can fire.
            --
            -- Only engages if we're trapped or in post-escape grace, OR the
            -- previous pathfind was partial (recent stuck signal).  Without
            -- a stuck signal, normal exploration shouldn't auto-chain.
            -- ──────────────────────────────────────────────────────────────
            -- try_traversal_route only fires when stuck-detection triggered,
            -- and attempt_escape only fires when trapped.  A successful cross
            -- via either path means we WERE stuck — treat any directional
            -- cross as a chain candidate.  (Walks crossed by exploration
            -- proper would still chain, but exploration rarely chains
            -- traversals back-to-back; chain_taken keeps the bot productive.)
            local chain_taken = false
            if crossing_dir ~= 0 then
                local chain_dir = crossing_dir
                local nearby = get_nearby_travs(local_player)
                local best = nil
                local best_dist = math.huge
                local now_for_bl = get_time_since_inject()
                local CHAIN_MAX_DIST = 30
                local CHAIN_Z_TOLERANCE = 3
                for _, c in ipairs(nearby) do
                    local cpos = c:get_position()
                    if math.abs(cpos:z() - player_pos:z()) <= CHAIN_Z_TOLERANCE then
                        local cname = c:get_skin_name()
                        local c_up   = cname:match('Up') ~= nil
                        local c_down = cname:match('Down') ~= nil
                        local c_dir = (c_up and not c_down) and 1
                            or ((c_down and not c_up) and -1 or 0)
                        if c_dir == chain_dir then
                            local cstr = cname .. utils.vec_to_string(cpos)
                            if not is_trav_blacklisted(cstr, now_for_bl) then
                                local d = utils.distance(player_pos, cpos)
                                if d <= CHAIN_MAX_DIST and d < best_dist then
                                    best_dist = d
                                    best = c
                                end
                            end
                        end
                    end
                end
                if best ~= nil then
                    local bp = best:get_position()
                    console.print(string.format(
                        '[nav] CHAIN ESCAPE: another %s on this floor @(%.1f,%.1f,%.2f) dist=%.1f — routing directly (skipping post-trav escape + explorer)',
                        best:get_skin_name(), bp:x(), bp:y(), bp:z(), best_dist))
                    navigator.last_trav            = best
                    navigator.target               = bp
                    navigator.is_custom_target     = false
                    navigator.path                 = {}
                    navigator.trav_delay           = nil
                    navigator.pre_trav_z           = nil  -- re-snapped at next interact
                    -- Extend grace so further chain attempts can keep firing
                    navigator.trap_post_escape_grace_until = now + TRAP_POST_ESCAPE_GRACE
                    navigator.trap_escape_pos      = nil  -- skip post-trav escape walk
                    navigator.post_trav_target     = nil
                    navigator.trav_final_target    = nil
                    chain_taken = true
                end
            end

            -- Brief escape to avoid re-triggering the landing-side gizmo,
            -- then re-plan toward the original destination from the new position.
            if (not chain_taken) and trav_pos_for_escape then
                local escape_pt = compute_escape_target(trav_pos_for_escape, player_pos)
                navigator.trav_escape_pos = trav_pos_for_escape
                -- Preserve the original destination for restoration after brief escape
                if navigator.trav_final_target ~= nil then
                    console.print('[nav] traversal crossed, brief escape then restoring target ' .. utils.vec_to_string(navigator.trav_final_target))
                    navigator.post_trav_target = { pos = navigator.trav_final_target, is_custom = true }
                    navigator.trav_final_target = nil
                elseif navigator.paused and navigator.target ~= nil then
                    navigator.post_trav_target = { pos = navigator.target, is_custom = navigator.is_custom_target }
                else
                    navigator.post_trav_target = nil
                end
                navigator.target = escape_pt
                navigator.is_custom_target = false
                navigator.pathfind_fail_count = 0
                console.print('[nav] post-traversal escape target: ' .. utils.vec_to_string(escape_pt))
            elseif not chain_taken then
                if navigator.trav_final_target ~= nil then
                    console.print('[nav] traversal crossed, restoring custom target ' .. utils.vec_to_string(navigator.trav_final_target))
                    navigator.target = navigator.trav_final_target
                    navigator.is_custom_target = true
                    navigator.pathfind_fail_count = 0
                    navigator.trav_final_target = nil
                else
                    if not navigator.paused then
                        navigator.target = nil
                        navigator.is_custom_target = false
                    end
                end
            end
        end
    end
    tracker.bench_stop("nav_trav_block")

    -- Buff-missed fallback: some traversals (ladders, FreeClimb, etc.) have a traversal
    -- buff that is too short to be reliably caught at the 50ms poll rate.  If last_trav
    -- is still set after the 2s interact cooldown has expired AND the player has physically
    -- moved > 8 units from the gizmo, the crossing happened but the buff was never seen.
    -- Treat it the same as a buff-detected crossing: blacklist + escape.
    if navigator.last_trav ~= nil and
        navigator.trav_delay ~= nil and
        get_time_since_inject() > navigator.trav_delay and
        utils.distance(player_pos, navigator.last_trav:get_position()) > 8
    then
        local missed_trav = navigator.last_trav
        local missed_pos  = missed_trav:get_position()
        local missed_dz = navigator.pre_trav_z and (player_pos:z() - navigator.pre_trav_z) or nil
        console.print(string.format(
            '[nav] buff-missed crossing: %s @(%.1f,%.1f,%.2f) | player @(%.1f,%.1f,%.2f) dist=%.1f dz=%s',
            missed_trav:get_skin_name(),
            missed_pos:x(), missed_pos:y(), missed_pos:z(),
            player_pos:x(), player_pos:y(), player_pos:z(),
            utils.distance(player_pos, missed_pos),
            missed_dz and string.format('%+.2f', missed_dz) or 'nil'))
        local crossed_str = missed_trav:get_skin_name() .. utils.vec_to_string(missed_pos)
        -- Only blacklist the exact crossed gizmo with a timestamp (15s cooldown)
        navigator.blacklisted_trav[crossed_str] = get_time_since_inject()
        navigator.last_trav      = nil
        navigator.trav_delay     = get_time_since_inject() + 4
        navigator.failed_target  = nil
        navigator.failed_target_radius = 15
        navigator.is_partial_path = false
        -- Reset stuck-detection so STUCK doesn't fire immediately after the
        -- missed-buff cross (player teleported but x/y may not have moved
        -- enough to trip the normal last_pos update).
        navigator.last_update    = get_time_since_inject()
        navigator.last_pos       = cur_node
        navigator.unstuck_nodes  = {}
        navigator.unstuck_count  = 0
        local escape_pt = compute_escape_target(missed_pos, player_pos)
        navigator.trav_escape_pos = missed_pos
        -- Preserve the original destination for restoration after brief escape
        if navigator.trav_final_target ~= nil then
            navigator.post_trav_target = { pos = navigator.trav_final_target, is_custom = true }
            navigator.trav_final_target = nil
        elseif navigator.paused and navigator.target ~= nil then
            navigator.post_trav_target = { pos = navigator.target, is_custom = navigator.is_custom_target }
        else
            navigator.post_trav_target = nil
        end
        navigator.target             = escape_pt
        navigator.is_custom_target   = false
        navigator.pathfind_fail_count = 0
        console.print('[nav] buff-missed escape target: ' .. utils.vec_to_string(escape_pt))
    end

    -- Post-traversal escape: complete when the player has either moved TRAV_ESCAPE_DIST
    -- units from the crossing point (normal path) OR actually reached the escape target
    -- (small platform where the closest walkable point is <20 units from the traversal).
    if navigator.trav_escape_pos ~= nil then
        local dist_from_trav = utils.distance(player_pos, navigator.trav_escape_pos)
        local reached_escape = navigator.target ~= nil
            and utils.distance(player_pos, navigator.target) <= 2
        if dist_from_trav >= TRAV_ESCAPE_DIST or reached_escape then
            local ptt = navigator.post_trav_target
            if ptt ~= nil then
                console.print('[nav] post-trav escape complete (dist=' .. string.format('%.1f', dist_from_trav) .. '), restoring target ' .. utils.vec_to_string(ptt.pos))
                console.print(string.format('[nav] restored target feasibility: dist=%.1f custom=%s walkable=%s',
                    utils.distance(player_pos, ptt.pos), tostring(ptt.is_custom),
                    tostring(utility.is_point_walkeable(ptt.pos))))
                navigator.target = ptt.pos
                navigator.is_custom_target = ptt.is_custom
                navigator.pathfind_fail_count = 0
            else
                console.print('[nav] post-trav escape complete (dist=' .. string.format('%.1f', dist_from_trav) .. '), no stored target — selecting new')
                if not navigator.paused then
                    navigator.target = nil
                    navigator.is_custom_target = false
                end
            end
            navigator.path = {}
            navigator.post_trav_target = nil
            navigator.trav_escape_pos = nil
        end
    end

    -- movement spells
    tracker.bench_start("nav_move_spell")
    if not utils.player_in_town() and #navigator.path > 0 then
        local movement_spell_id, need_raycast = get_movement_spell_id(local_player)
        if movement_spell_id ~= nil then
            local spell_node = nil
            local node_dist = -1
            local new_path = {}
            local selected = false
            for _, node in ipairs(navigator.path) do
                local dist = utils.distance(node, cur_node)
                local node_str = utils.vec_to_string(node)
                if selected or dist > navigator.spell_dist or node_dist > dist then
                    new_path[#new_path+1] = node
                    selected = true
                elseif navigator.blacklisted_spell_node[node_str] == nil and
                    -- move to nodes that is >= movement step 
                    utils.distance(node, cur_node) >= navigator.movement_step
                then
                    spell_node = node
                    node_dist = dist
                end
            end
            if spell_node ~= nil then
                local raycast_success = true
                if need_raycast then
                    local dist = utils.distance(cur_node, spell_node)
                    raycast_success = utility.is_ray_cast_walkeable(cur_node, spell_node, 0.5, dist)
                end
                if raycast_success then
                    local success = cast_spell.position(movement_spell_id, spell_node, 0)
                    if success then
                        utils.log(2, 'movement spell to ' .. utils.vec_to_string(spell_node))
                        tracker.bench_count("move_spell_cast")
                        if not navigator.paused then navigator.update() end
                        player_pos = local_player:get_position()
                        cur_node = utils.normalize_node(player_pos)
                        navigator.path = new_path
                        local node_str = utils.vec_to_string(spell_node)
                        navigator.blacklisted_spell_node[node_str] = spell_node
                    end
                end
            end
        end
    end
    tracker.bench_stop("nav_move_spell")

    local update_timeout = 1
    if utils.player_in_town() then update_timeout = 10 end
    if not has_traversal_buff(local_player) and
        navigator.last_trav == nil and
        (navigator.target == nil or utils.distance(cur_node, navigator.target) <= 1)
    then
        console.print('[nav] no target or reached, selecting new (prev=' .. (navigator.target and utils.vec_to_string(navigator.target) or 'nil') .. ')')
        navigator.blacklisted_spell_node = {}
        if navigator.paused then return end
        tracker.bench_start("select_target")
        navigator.target = select_target(nil)
        tracker.bench_stop("select_target")
        navigator.is_custom_target = false
        navigator.path = {}
        navigator.disable_spell = nil
        console.print('[nav] new target=' .. (navigator.target and utils.vec_to_string(navigator.target) or 'nil'))
    elseif navigator.target ~= nil and
        navigator.last_update ~= nil and
        navigator.last_update + update_timeout < get_time_since_inject() and
        not utils.is_cced(local_player)
    then
        local dist_to_target = utils.distance(cur_node, navigator.target)
        -- If we're close to a target traversal, suppress unstuck — we're
        -- positioning to interact, not stuck on terrain.  unstuck() can
        -- cast an evade or inject a perpendicular path node, both of which
        -- can pull the player away from the gizmo just as the proximity
        -- interact (within 3u) is about to fire on the next tick.
        if navigator.last_trav ~= nil
            and utils.distance(player_pos, navigator.last_trav:get_position()) <= 5
        then
            console.print(string.format(
                '[nav] STUCK suppressed: positioning for traversal %s (dist=%.1f) — giving interact a chance',
                navigator.last_trav:get_skin_name(),
                utils.distance(player_pos, navigator.last_trav:get_position())))
            -- Push last_update forward so we don't re-trip every tick
            navigator.last_update = get_time_since_inject() + 0.5
        else
            console.print('[nav] STUCK target=' .. utils.vec_to_string(navigator.target) .. ' dist=' .. string.format('%.1f', dist_to_target) .. ' path=#' .. #navigator.path .. ' unstuck_count=' .. navigator.unstuck_count)
            tracker.bench_start("unstuck")
            unstuck(local_player)
            tracker.bench_stop("unstuck")
            navigator.last_update = navigator.last_update + 0.25
        end
    end
    if navigator.last_pos == nil or
        utils.distance(cur_node, navigator.last_pos) >= 0.5 or
        has_traversal_buff(local_player) or
        utils.is_cced(local_player)
    then
        navigator.last_pos = cur_node
        navigator.unstuck_nodes = {}
        navigator.unstuck_count = 0
        if navigator.last_update == nil or navigator.last_update < get_time_since_inject() then
            navigator.last_update = get_time_since_inject()
        end
    end

    if navigator.target == nil and
        navigator.last_trav == nil and
        not has_traversal_buff(local_player)
    then
        if navigator.done_delay ~= nil and navigator.done_delay < get_time_since_inject() then
            if explorer.frontier_count > 0 and #explorer.backtrack == 0 then
                console.print('[nav] not done but no more backtrack, reseting')
                navigator.reset()
                return
            elseif explorer.frontier_count == 0 and #explorer.backtrack > 0 then
                -- Still have backtracks — moving there may reveal new frontiers
                console.print('[nav] no frontiers but ' .. #explorer.backtrack .. ' backtracks, retrying')
                navigator.done_delay = nil
            elseif navigator.exploration_resets < 2 then
                -- Both frontiers and backtracks exhausted but dungeon may not be done
                -- Reset explorer visited set so re-scanning can find missed branches
                navigator.exploration_resets = navigator.exploration_resets + 1
                console.print('[nav] exploration stalled, resetting explorer (attempt ' .. navigator.exploration_resets .. '/2)')
                explorer.reset()
                navigator.target = nil
                navigator.is_custom_target = false
                navigator.path = {}
                navigator.done_delay = nil
            else
                navigator.done = true
                navigator.exploration_resets = 0
                console.print('[nav] finish exploration (frontiers=' .. explorer.frontier_count .. ' bt=#' .. #explorer.backtrack .. ')')
            end
        elseif navigator.done_delay == nil then
            navigator.done_delay = get_time_since_inject() + 1
        end
        return
    else
        navigator.done_delay = nil
    end

    -- Deadlock guard: last_trav is set (blocking target selection) but target is nil
    -- and the player is not within interaction range.  This can happen when the traversal
    -- approach node pathfind fails and select_target returns nil (all nearby frontiers
    -- were blacklisted).  Clear last_trav so the "no target or reached" block can fire
    -- next tick and pick a fresh explorer target.
    if navigator.last_trav ~= nil and navigator.target == nil and
        utils.distance(player_pos, navigator.last_trav:get_position()) > 5
    then
        console.print('[nav] deadlock: last_trav set but target nil and player far from traversal — clearing last_trav')
        navigator.last_trav = nil
    end

    -- Partial-path stall escape: if A* keeps returning partial paths (target
    -- across a cliff/climb/etc.) and the player can't make progress on the
    -- current floor for 3s+, attempt traversal routing now. Without this,
    -- pathfind_fail_count stays at 0 (partial paths reset it) so the
    -- failure-handler trav fallback never triggers, and the bot stares at
    -- the cliff until the 6s no-progress abandonment timer fires.
    if navigator.target ~= nil
        and navigator.is_partial_path
        and navigator.last_trav == nil
        and navigator.trav_escape_pos == nil
        and navigator.partial_target_ref == navigator.target
        and (get_time_since_inject() - navigator.partial_target_last_progress_time) > 3
        and (get_time_since_inject() - navigator.last_trav_route_attempt_time) > 2
    then
        navigator.last_trav_route_attempt_time = get_time_since_inject()
        local routed, _trav = try_traversal_route(local_player, player_pos)
        if routed then
            return  -- target reassigned to traversal approach node
        end
    end

    if navigator.target ~= nil and (#navigator.path == 0 or
        utils.distance(navigator.path[1], navigator.last_pos) > navigator.movement_dist)
    then
        -- Cooldown after pathfind failure: avoid hammering A* at 20Hz on blocked terrain.
        if navigator.pathfind_area_cooldown > get_time_since_inject() then
            if #navigator.path > 0 then
                pathfinder.request_move(navigator.path[1])
            end
            return
        end
        -- Cooldown after successful replan: when the player swerves (looting, dodge) the path
        -- becomes stale but a fresh A* is expensive.  Keep moving on the old path for 0.5s
        -- before committing to a replan so brief deviations don't cause a pathfind storm.
        if navigator.pathfind_replan_cooldown > get_time_since_inject() then
            if #navigator.path > 0 then
                pathfinder.request_move(navigator.path[1])
            end
            return
        end
        local dist_to_target = utils.distance(navigator.last_pos, navigator.target)
        console.print('[nav] pathfinding to=' .. utils.vec_to_string(navigator.target) .. ' dist=' .. string.format('%.1f', dist_to_target) .. ' custom=' .. tostring(navigator.is_custom_target))
        local result, is_partial = path_finder.find_path(navigator.last_pos, navigator.target, navigator.is_custom_target)

        -- Partial path: A* couldn't reach the goal but got closer.
        -- Walk the partial path to approach the destination (e.g. cliff edge near a
        -- traversal). Don't increment fail count — the path IS making progress.
        -- When the partial path is consumed, re-pathfind from the new (closer) position.
        if is_partial and #result > 0 then
            local now = get_time_since_inject()
            -- No-progress detector: if best distance to target hasn't improved for
            -- ~6s of partial paths, the closest reachable region is genuinely
            -- N units short of the target — give up before spinning forever.
            if navigator.partial_target_ref ~= navigator.target then
                navigator.partial_target_ref = navigator.target
                navigator.partial_target_best_dist = dist_to_target
                navigator.partial_target_last_progress_time = now
            elseif dist_to_target < navigator.partial_target_best_dist - 1 then
                navigator.partial_target_best_dist = dist_to_target
                navigator.partial_target_last_progress_time = now
            elseif now - navigator.partial_target_last_progress_time > 4
                and navigator.last_trav == nil
            then
                console.print('[nav] partial-path no progress for 4s (best=' ..
                    string.format('%.1f', navigator.partial_target_best_dist) ..
                    ' cur=' .. string.format('%.1f', dist_to_target) ..
                    ') — abandoning unreachable target ' .. utils.vec_to_string(navigator.target))
                if navigator.paused then
                    -- Custom target (kill_monster etc.): mark unreachable via failed_target
                    navigator.failed_target = navigator.target
                    navigator.failed_target_time = now
                    navigator.failed_target_radius = 15
                else
                    -- Explorer target: marking just the exact node leaves adjacent
                    -- frontiers in the same unreachable cluster, so select_target
                    -- immediately picks the cell next door (e.g. -2.5,-19 abandoned
                    -- → next pick -2,-19, same dead zone). Mark a 5-unit radius
                    -- so the cluster is skipped wholesale. Smaller than the 16-unit
                    -- unstuck-EXHAUSTED blacklist (which wiped 1500+ legit frontiers).
                    local failed_pos = navigator.target
                    if failed_pos then
                        local step = settings.step or 0.5
                        local fx = failed_pos:x()
                        local fy = failed_pos:y()
                        for dx = -5, 5, step do
                            for dy = -5, 5, step do
                                local node_str =
                                    tostring(utils.normalize_value(fx + dx)) .. ',' ..
                                    tostring(utils.normalize_value(fy + dy))
                                explorer.visited[node_str] = node_str
                            end
                        end
                    end
                end
                navigator.target = nil
                navigator.is_custom_target = false
                navigator.path = {}
                navigator.is_partial_path = false
                navigator.disable_spell = nil
                navigator.partial_target_ref = nil
                navigator.partial_target_best_dist = math.huge
                navigator.pathfind_fail_count = 0
                return
            end
            console.print('[nav] PARTIAL PATH #' .. #result .. ' toward ' .. utils.vec_to_string(navigator.target) .. ' (dist=' .. string.format('%.1f', dist_to_target) .. ')')
            navigator.pathfind_fail_count = 0
            navigator.path = result
            navigator.is_partial_path = true
            -- Backoff replan cooldown when no progress: once it's clear A* can't
            -- do better than the current best distance, stop hammering it. Cuts
            -- find_path frequency 4x during stalls; 6s no-progress timer above
            -- still triggers abandonment on schedule.
            local stall = now - navigator.partial_target_last_progress_time
            local cooldown
            if stall > 2 then
                cooldown = navigator.is_custom_target and 1.0 or 2.0
            else
                cooldown = navigator.is_custom_target and 0.3 or 0.5
            end
            navigator.pathfind_replan_cooldown = now + cooldown
            -- Don't fall through to the failure handler
        elseif #result == 0 then
            navigator.is_partial_path = false
            tracker.debug_node = navigator.target
            navigator.pathfind_fail_count = navigator.pathfind_fail_count + 1
            tracker.bench_count("pathfind_fail")
            navigator.pathfind_area_cooldown = get_time_since_inject() + 0.4
            console.print('[nav] PATHFIND FAILED #' .. navigator.pathfind_fail_count .. ' target=' .. utils.vec_to_string(navigator.target) .. ' dist=' .. string.format('%.1f', dist_to_target) .. ' paused=' .. tostring(navigator.paused) .. ' frontiers=' .. explorer.frontier_count)
            -- Post-traversal escape: A* may fail when the escape point is on the edge of
            -- a small platform (top of ladder, narrow ledge).  Use direct movement to
            -- physically push the player away from the traversal instead of calling
            -- select_target (which would pick the landing-side gizmo and bounce back).
            if navigator.trav_escape_pos ~= nil then
                console.print('[nav] escape pathfind failed — nudging away from traversal directly')
                pathfinder.request_move(navigator.target)
                return
            end
            -- Intermediate nudge: on early failures for explorer targets, push the player
            -- a few units toward the target. From a closer position the limited A* often
            -- succeeds. Without this, the bot wastes 3 fail attempts on the same far
            -- target then blacklists a wide area, wiping huge swaths of frontiers
            -- (confirmed in log: 1650 -> 93 after one blacklist).
            if not navigator.paused
                and navigator.target ~= nil
                and navigator.pathfind_fail_count <= 2
                and navigator.last_trav == nil
            then
                local dx = navigator.target:x() - player_pos:x()
                local dy = navigator.target:y() - player_pos:y()
                local len = math.sqrt(dx*dx + dy*dy)
                if len > 6 then
                    local step_dist = 4
                    local nudge = vec3:new(
                        player_pos:x() + (dx/len) * step_dist,
                        player_pos:y() + (dy/len) * step_dist,
                        navigator.target:z()
                    )
                    local valid = utility.set_height_of_valid_position(nudge)
                    if utility.is_point_walkeable(valid) then
                        console.print(string.format(
                            '[nav] limited A* failed (dist=%.1f); nudging %d units toward (%.1f,%.1f)',
                            len, step_dist, valid:x(), valid:y()
                        ))
                        pathfinder.request_move(valid)
                        return  -- next pathfind from new position may succeed
                    end
                end
            end
            -- After N consecutive pathfind failures, handle unreachable target
            -- Custom targets (kill_monster): 3 failures (quick give-up, mark unreachable)
            -- Explorer targets: 3 failures — was 6, but with the heap-based A* each failed
            -- call still burns 200-600ms, so 6 failures = up to 3.6s of freeze. 3 is enough
            -- since adjacent frontier nodes in the same blocked area all fail the same way.
            local fail_threshold = navigator.is_custom_target and 3 or 3
            -- After a traversal crossing, walkability data for the new area may not be
            -- loaded yet — be more patient before giving up on the custom target
            if navigator.trav_delay ~= nil and get_time_since_inject() < navigator.trav_delay then
                fail_threshold = 15
            end
            if navigator.pathfind_fail_count >= fail_threshold then
                navigator.pathfind_fail_count = 0
                -- Check if a traversal is nearby — target is likely behind it.
                -- Pit floors connect via FreeClimb gizmos that A* cannot route
                -- through, so we route to the traversal approach node instead.
                local routed, closest_trav = try_traversal_route(local_player, player_pos)
                if routed then
                    return  -- don't set failed_target — retry after crossing
                end
                -- If paused (external caller like kill_monster set target), just mark
                -- as unreachable and clear — do NOT blacklist explorer.visited since
                -- the explorer didn't pick this target and blacklisting corrupts its state
                if navigator.paused then
                    local block_radius = closest_trav ~= nil and 50 or 15
                    console.print('[nav] clearing unreachable custom target ' .. utils.vec_to_string(navigator.target) .. ', cooldown=' .. navigator.failed_target_cooldown .. 's radius=' .. block_radius .. (closest_trav ~= nil and ' (no traversal route)' or ''))
                    navigator.failed_target = navigator.target
                    navigator.failed_target_time = get_time_since_inject()
                    navigator.failed_target_radius = block_radius
                    navigator.target = nil
                    navigator.is_custom_target = false
                    navigator.path = {}
                    navigator.disable_spell = nil
                    return
                end
                -- Only blacklist explorer area for explorer-picked targets.
                -- Special case: if last_trav is set, the failing target IS the traversal
                -- approach node.  Blacklisting its 48x48 area would wipe out the traversal
                -- zone entirely.  Instead, blacklist the traversal gizmo itself and clear
                -- last_trav so the explorer can resume without a deadlock.
                if navigator.last_trav ~= nil then
                    local trav_str = navigator.last_trav:get_skin_name() .. utils.vec_to_string(navigator.last_trav:get_position())
                    navigator.blacklisted_trav[trav_str] = get_time_since_inject()
                    console.print('[nav] traversal approach failed — blacklisting traversal ' .. navigator.last_trav:get_skin_name() .. ' and clearing last_trav')
                    navigator.last_trav = nil
                    navigator.target    = nil
                    navigator.path      = {}
                    return  -- let explorer pick fresh target next tick
                end
                -- Mark only the exact failed target as visited (not a wide area).
                -- With partial paths now working, most "unreachable" targets are just
                -- across a traversal — wiping a 16x16 area destroyed 100s of frontiers
                -- and triggered full explorer resets. Marking only the single node lets
                -- the explorer try nearby alternatives that may be reachable after a
                -- traversal crossing from a slightly different angle.
                console.print('[nav] marking failed target as visited: ' .. utils.vec_to_string(navigator.target))
                local failed_pos = navigator.target
                if failed_pos then
                    local node_str = tostring(utils.normalize_value(failed_pos:x())) .. ',' .. tostring(utils.normalize_value(failed_pos:y()))
                    explorer.visited[node_str] = node_str
                end
            end
            if navigator.paused then return end
            tracker.bench_start("select_target")
            navigator.target = select_target(navigator.target)
            tracker.bench_stop("select_target")
            console.print('[nav] new target after fail=' .. (navigator.target and utils.vec_to_string(navigator.target) or 'nil') .. (navigator.target and (' dist=' .. string.format('%.1f', utils.distance(cur_node, navigator.target))) or ''))
            navigator.is_custom_target = false
            navigator.path = {}
            navigator.disable_spell = nil
            return
        else
            console.print('[nav] pathfind OK, path=#' .. #result)
            navigator.is_partial_path = false
            tracker.debug_node = nil
            navigator.pathfind_fail_count = 0
            navigator.path = result
            -- Gate the next replan: brief player deviations (looting, dodge) won't re-trigger A*.
            -- Custom targets (kill_monsters) get a shorter window since enemy movement matters more.
            -- Far targets (>30u) get a longer window — at player speed ~7m/s the path stays
            -- valid for >1s and find_path is expensive at long distances (~50ms+ per call).
            local replan_cooldown
            if dist_to_target > 30 then
                replan_cooldown = navigator.is_custom_target and 0.8 or 1.0
            else
                replan_cooldown = navigator.is_custom_target and 0.3 or 0.5
            end
            navigator.pathfind_replan_cooldown = get_time_since_inject() + replan_cooldown
        end
    end

    -- Find the last node the player has already reached (within 1 unit).
    -- Using "last consumed" rather than "first not consumed" handles winding paths
    -- where a later node curves back near the player without meaning prior nodes
    -- are all passed.  The old `new_path = {}` reset dropped valid forward nodes
    -- whenever any mid-path node was near the player, leaving path[1] potentially
    -- > movement_dist away and triggering a spurious re-pathfind.
    tracker.bench_start("nav_consume_path")
    local last_consumed = 0
    for i, node in ipairs(navigator.path) do
        if utils.distance(node, cur_node) < 1 then
            last_consumed = i
        end
    end

    local moved = false
    local new_path = {}
    for i = last_consumed + 1, #navigator.path do
        local node = navigator.path[i]
        if not moved and
            -- move to nodes that is >= movement step
            (utils.distance(node, cur_node) >= navigator.movement_step or
            -- or if it is close to target
            (navigator.target ~= nil and utils.distance(node, navigator.target) == 0))
        then
            pathfinder.request_move(node)
            moved = true
        end
        new_path[#new_path+1] = node
    end
    -- Fallback: short partial paths (all remaining nodes < movement_step away)
    -- otherwise produce zero movement and the bot sits there spamming
    -- "has path but no move" until the replan cooldown expires.  Walk to the
    -- last node so the player makes >=1u of progress per tick — next replan
    -- from the new position can find a longer path.
    if not moved and #new_path > 0 then
        local last_node = new_path[#new_path]
        if utils.distance(last_node, cur_node) > 1 then
            pathfinder.request_move(last_node)
            moved = true
        end
    end
    if not moved and #navigator.path > 0 then
        console.print('[nav] has path (#' .. #navigator.path .. ') but no move, remaining=#' .. #new_path .. ' target=' .. (navigator.target and utils.vec_to_string(navigator.target) or 'nil'))
    end
    navigator.path = new_path
    tracker.bench_stop("nav_consume_path")
end

-- Expose get_closeby_node for plugins that need to path to actors sitting on
-- non-walkable tiles (e.g. portals, glyph gizmos). Read-only utility — finds
-- a walkable, reachable approach node within max_dist of the target.
navigator.get_closeby_node = get_closeby_node
-- Expose for the cross_traversal task: lets a higher-priority task engage
-- traversal routing when the portal task can't pathfind around a cliff.
navigator.try_traversal_route = try_traversal_route

-- ────────────────────────────────────────────────────────────────────────────
-- Trap detection / recovery
--
-- Problem: when the player descends through traversals into a small enclosed
-- area, the explorer keeps picking unreachable frontiers across walls and the
-- bot loops indefinitely on partial-path failures.
--
-- Detection: sample player position once per second; if the bbox of the last
-- 30s of samples is < TRAP_BBOX_THRESHOLD on both axes, we're trapped.
--
-- Escape: every TRAP_ESCAPE_COOLDOWN seconds while trapped:
--   1. Compute the trapped-zone bbox (sample bbox + 5u margin)
--   2. Mark every frontier in that bbox as visited (kills the infinite loop)
--   3. Find traversal gizmos in/near the bbox; pick one whose direction
--      opposes the recent traversal-history average (came down → go up)
--   4. Force the navigator to route to that traversal's approach node
--
-- Giveup: if still trapped after TRAP_GIVEUP_TIMEOUT seconds, set
-- navigator.giving_up = true so the calling plugin (HelltideRevamped) can
-- teleport away and pick a new zone.
-- ────────────────────────────────────────────────────────────────────────────

navigator.update_trap_state = function(local_player)
    local now = get_time_since_inject()
    local pos = local_player:get_position()

    -- Sample position once per TRAP_SAMPLE_INTERVAL seconds
    if now - navigator.trap_pos_sample_time >= TRAP_SAMPLE_INTERVAL then
        navigator.trap_pos_sample_time = now
        navigator.trap_pos_history[#navigator.trap_pos_history + 1] = { pos = pos, t = now }
        if #navigator.trap_pos_history > TRAP_HISTORY_MAX then
            table.remove(navigator.trap_pos_history, 1)
        end
    end

    -- Compute bbox if we have enough samples (gates bbox_trapped only).
    -- Ping-pong detection runs regardless: it depends on trav_history, not
    -- position samples, and we want it to fire as soon as a 2nd opposite
    -- crossing happens — even at session start before 20s of position data
    -- has accumulated.
    local bbox_trapped = false
    local bbox_w, bbox_h = 0, 0
    local min_x, max_x = math.huge, -math.huge
    local min_y, max_y = math.huge, -math.huge
    if #navigator.trap_pos_history >= TRAP_MIN_SAMPLES then
        local cutoff = now - TRAP_DETECT_WINDOW
        local n_in_window = 0
        for _, sample in ipairs(navigator.trap_pos_history) do
            if sample.t >= cutoff then
                local sx, sy = sample.pos:x(), sample.pos:y()
                if sx < min_x then min_x = sx end
                if sx > max_x then max_x = sx end
                if sy < min_y then min_y = sy end
                if sy > max_y then max_y = sy end
                n_in_window = n_in_window + 1
            end
        end
        if n_in_window >= TRAP_MIN_SAMPLES then
            bbox_w = max_x - min_x
            bbox_h = max_y - min_y
            bbox_trapped = bbox_w < TRAP_BBOX_THRESHOLD and bbox_h < TRAP_BBOX_THRESHOLD
        end
    end

    -- Secondary signal: traversal ping-pong.  Bbox alone misses scenarios where
    -- the player goes down a traversal, walks to a dead-end frontier 30u away,
    -- comes back up the same traversal pair, repeats.  X-span looks healthy
    -- (~50u) but no real exploration progress.
    --
    -- Detection: count direction reversals in trav_history within trav_window
    -- seconds.  Uses the DIRECTION INFERRED FROM GIZMO NAME, not the measured
    -- dz — the engine fires the traversal buff at the START of the climb
    -- animation, before player z reaches the destination, so dz reads ~0
    -- even on real ~5u climbs (logzewx showed dz=+0.06 for a confirmed F1->F2
    -- climb).  Names ('Up'/'Down') are known unambiguously the moment the
    -- gizmo is selected and don't suffer from animation timing.
    --
    -- Threshold: 1 reversal — a single down-then-up (or up-then-down) within
    -- 60s is almost always a wasted trip.
    local reversals = 0
    local trav_window = TRAP_DETECT_WINDOW * 2
    for i = 2, #navigator.trav_history do
        local prev = navigator.trav_history[i - 1]
        local cur  = navigator.trav_history[i]
        if (now - cur.t) <= trav_window then
            local prev_dir = prev.direction or 0
            local cur_dir  = cur.direction  or 0
            if (prev_dir > 0 and cur_dir < 0)
                or (prev_dir < 0 and cur_dir > 0)
            then
                reversals = reversals + 1
            end
        end
    end
    local pingpong_trapped = reversals >= 1

    local is_trapped = bbox_trapped or pingpong_trapped

    -- Post-escape grace: keep trap active even if bbox grew, so the next
    -- attempt_escape on the NEW floor (after a successful climb) can find
    -- the next escape gizmo.  Without this, the bot escapes F1 → F2,
    -- bbox immediately grows past threshold, trap clears, and the bot
    -- starts normal exploration on F2 — never tries the F2 → F3 climb.
    local in_grace = navigator.trapped and now < navigator.trap_post_escape_grace_until

    if is_trapped or in_grace then
        if not navigator.trapped then
            navigator.trapped = true
            navigator.trapped_since = now
            navigator.trapped_escape_count = 0
            navigator.trapped_last_escape_time = -1
            local reason = bbox_trapped
                and string.format('bbox %.1fx%.1f over %ds', bbox_w, bbox_h, TRAP_DETECT_WINDOW)
                or string.format('traversal ping-pong: %d reversals in %ds', reversals, trav_window)
            -- bbox center may be undefined if bbox check didn't run; use
            -- player position as fallback so the log line stays readable.
            local cx = (min_x ~= math.huge) and (min_x + max_x) / 2 or pos:x()
            local cy = (min_y ~= math.huge) and (min_y + max_y) / 2 or pos:y()
            console.print(string.format(
                '[TRAP] detected: %s | bbox center (%.1f,%.1f) | player @ (%.1f,%.1f,%.2f) — escape engaged',
                reason, cx, cy, pos:x(), pos:y(), pos:z()))
        end
    else
        if navigator.trapped then
            console.print(string.format(
                '[TRAP] cleared: bbox now %.1fx%.1f after %ds trapped, %d escape attempts',
                bbox_w, bbox_h, math.floor(now - navigator.trapped_since),
                navigator.trapped_escape_count))
            navigator.trapped_clear_time = now
        end
        navigator.trapped = false
        navigator.trapped_since = nil
        navigator.giving_up = false
        navigator.trapped_escape_count = 0
    end
end

navigator.attempt_escape = function(local_player)
    if not navigator.trapped then return end
    local now = get_time_since_inject()

    -- Giveup check (always run, even before first cooldown elapses, so HR
    -- doesn't have to wait an extra TRAP_ESCAPE_COOLDOWN before noticing).
    if now - navigator.trapped_since > TRAP_GIVEUP_TIMEOUT then
        if not navigator.giving_up then
            navigator.giving_up = true
            console.print(string.format(
                '[TRAP] GIVING UP after %ds trapped + %d escape attempts',
                math.floor(now - navigator.trapped_since),
                navigator.trapped_escape_count))
        end
        return
    end

    if now - navigator.trapped_last_escape_time < TRAP_ESCAPE_COOLDOWN then return end
    navigator.trapped_last_escape_time = now
    navigator.trapped_escape_count = navigator.trapped_escape_count + 1

    -- Recompute trapped-zone bbox with a small margin (used for traversal search)
    local cutoff = now - TRAP_DETECT_WINDOW
    local min_x, max_x = math.huge, -math.huge
    local min_y, max_y = math.huge, -math.huge
    for _, sample in ipairs(navigator.trap_pos_history) do
        if sample.t >= cutoff then
            local sx, sy = sample.pos:x(), sample.pos:y()
            if sx < min_x then min_x = sx end
            if sx > max_x then max_x = sx end
            if sy < min_y then min_y = sy end
            if sy > max_y then max_y = sy end
        end
    end
    min_x, max_x = min_x - 5, max_x + 5
    min_y, max_y = min_y - 5, max_y + 5

    -- Step 1: clear frontiers in a wide zone around the player.  The trapped
    -- bbox is often only ~25u, but the unreachable frontier across the wall
    -- is typically 15-30u away (just outside the bbox).  Use a generous radius
    -- so the explorer can't keep re-picking those across-the-wall frontiers.
    local player_pos = local_player:get_position()
    local CLEAR_RADIUS = 35
    local cleared = explorer.clear_frontiers_in_box(
        player_pos:x() - CLEAR_RADIUS, player_pos:x() + CLEAR_RADIUS,
        player_pos:y() - CLEAR_RADIUS, player_pos:y() + CLEAR_RADIUS)

    -- Reset failure trackers so the next pathfind isn't gated by stale state
    navigator.failed_target               = nil
    navigator.pathfind_fail_count         = 0
    navigator.partial_target_ref          = nil
    navigator.partial_target_best_dist    = math.huge
    navigator.partial_target_last_progress_time = -1
    navigator.is_partial_path             = false

    -- Step 2: determine preferred direction from recent traversal history.
    -- Most traps are pits — the bot fell or descended into them and needs
    -- to climb out.  Default to prefer_up.  Suppress only when we've been
    -- climbing repeatedly without escape (rare: the escape might actually
    -- need to be downward).
    --
    -- Rule:
    -- - If we've EVER descended in recent history → prefer_up (came down,
    --   need to climb back out).  This handles both:
    --     * fresh trap: 1 Down crossing entered, prefer Up to escape
    --     * mid-escape: 1 Down + 1 Up so far, continue Up to next floor
    -- - Only Up crossings in history → prefer_down (we've climbed multiple
    --   times without escape, try going down — uncommon scenario)
    -- - No crossings at all → prefer_up by default (most common case)
    local up_count = 0
    local down_count = 0
    for _, h in ipairs(navigator.trav_history) do
        if now - h.t < 120 then
            local d = h.direction or 0
            if d > 0 then up_count = up_count + 1
            elseif d < 0 then down_count = down_count + 1
            end
        end
    end
    local prefer_up   = (down_count > 0) or (up_count == 0)
    local prefer_down = not prefer_up and up_count > 0

    -- Step 3: find traversal gizmos near the trapped zone.
    -- Progressive blacklist relaxation — the more attempts that fail, the more
    -- we tolerate recently-crossed traversals.  The 30s cooldown that exists
    -- to prevent immediate re-crossing makes sense in normal exploration but
    -- defeats trap escape, since the most likely exit IS the gizmo we came
    -- through (and just blacklisted on the way in).
    --   Attempt 1   : require >=15s blacklist age
    --   Attempt 2   : require >=5s
    --   Attempt 3+  : ignore blacklist entirely
    local bl_age_required
    if navigator.trapped_escape_count == 1 then
        bl_age_required = 15
    elseif navigator.trapped_escape_count == 2 then
        bl_age_required = 5
    else
        bl_age_required = 0  -- desperate: any traversal will do
    end

    -- Z-plane filter: only consider traversals whose entry point is on the
    -- same elevation as the player.  A gizmo whose interaction node is on the
    -- floor below us is a "Down from above" — useless for escape because we
    -- can't reach its interactable point without falling.  Likewise, a gizmo
    -- whose entry is on the floor above us is something we'd need to climb
    -- TO, not climb FROM.  ~3u tolerance accommodates platform thickness and
    -- the tiny vertical offsets engine-side.
    local TRAV_Z_TOLERANCE = 3
    local player_z = player_pos:z()

    local traversals = get_nearby_travs(local_player)
    local best_trav = nil
    local best_score = -math.huge
    local best_is_dir_match = false
    local n_in_zone = 0
    local n_skipped_bl = 0
    local n_skipped_z = 0
    -- Per-candidate diagnostic: build a short summary of every in-zone gizmo
    -- and why it was kept/rejected.  Printed below so we can see at a glance
    -- which gizmo got chosen vs which got filtered.
    local cand_summaries = {}
    for _, trav in ipairs(traversals) do
        local tpos = trav:get_position()
        -- Allow traversals slightly outside the bbox (within 10u) — gizmos at
        -- the zone's edge might be just past the player's wandering bounds.
        if tpos:x() >= min_x - 10 and tpos:x() <= max_x + 10
            and tpos:y() >= min_y - 10 and tpos:y() <= max_y + 10
        then
            n_in_zone = n_in_zone + 1
            local trav_name = trav:get_skin_name()
            local dz = tpos:z() - player_z
            local dist = utils.distance(player_pos, tpos)
            -- Z-plane check: skip gizmos that aren't on the player's current
            -- floor.  Without this, "escape via FreeClimb_Up" might pick the
            -- Up-gizmo on the floor BELOW us (the entrance to the platform
            -- we're standing on), which we can't actually interact with.
            if math.abs(dz) > TRAV_Z_TOLERANCE then
                n_skipped_z = n_skipped_z + 1
                cand_summaries[#cand_summaries + 1] = string.format(
                    '%s @(%.1f,%.1f,%.2f dz=%+.2f dist=%.1f) Z-SKIP',
                    trav_name, tpos:x(), tpos:y(), tpos:z(), dz, dist)
                goto continue
            end
            -- Direction inference from skin name (Climb_Up / FreeClimb_Up_Down etc.).
            -- Approximate; we don't know exact destination z without crossing.
            local name_up   = trav_name:match('Up') ~= nil
            local name_down = trav_name:match('Down') ~= nil
            local dir_match = (prefer_up and name_up and not name_down)
                or (prefer_down and name_down and not name_up)
            -- Score: closer = better; direction match = +1000 (dominates distance)
            local score = -dist
            if dir_match then score = score + 1000 end
            local trav_str = trav_name .. utils.vec_to_string(tpos)
            -- Long-term trap blacklist always wins regardless of attempt count
            -- (it was set INTENTIONALLY by an earlier escape to prevent re-entry).
            local trap_until = navigator.trap_blacklisted_trav[trav_str]
            local trap_blocked = trap_until ~= nil and now < trap_until
            local bl_time = navigator.blacklisted_trav[trav_str]
            local bl_age = bl_time and (now - bl_time) or math.huge
            if not trap_blocked and bl_age >= bl_age_required then
                if score > best_score then
                    best_score = score
                    best_trav = trav
                    best_is_dir_match = dir_match
                end
                cand_summaries[#cand_summaries + 1] = string.format(
                    '%s @(%.1f,%.1f,%.2f dz=%+.2f dist=%.1f dir=%s bl=%s) OK',
                    trav_name, tpos:x(), tpos:y(), tpos:z(), dz, dist,
                    tostring(dir_match),
                    bl_age == math.huge and 'never' or string.format('%.1fs', bl_age))
            else
                n_skipped_bl = n_skipped_bl + 1
                local reason = trap_blocked and 'TRAP_BL' or 'BL'
                cand_summaries[#cand_summaries + 1] = string.format(
                    '%s @(%.1f,%.1f,%.2f dz=%+.2f dist=%.1f bl_age=%.1fs trap_bl=%s) %s-SKIP',
                    trav_name, tpos:x(), tpos:y(), tpos:z(), dz, dist,
                    bl_age == math.huge and -1 or bl_age,
                    tostring(trap_blocked), reason)
            end
            ::continue::
        end
    end
    -- Emit per-candidate diagnostic so we can see why each in-zone gizmo
    -- was kept or rejected.
    if #cand_summaries > 0 then
        for i, s in ipairs(cand_summaries) do
            console.print(string.format('[TRAP] cand[%d/%d] %s', i, #cand_summaries, s))
        end
    end

    if best_trav ~= nil then
        local best_tpos = best_trav:get_position()
        local approach = get_closeby_node(best_tpos, 3)
        local approach_source = 'closeby_3'
        if approach == nil then
            -- Try a wider radius before falling back to the gizmo position
            approach = get_closeby_node(best_tpos, 6)
            approach_source = 'closeby_6'
        end
        -- Fallback: even if get_closeby_node can't find a walkable approach
        -- node within 6u (which can happen on tight ledges where A* runs out
        -- of time on the 8-attempt feasibility check), use the gizmo's own
        -- position.  navigator.move's interact-on-proximity fires when the
        -- player is within 3u of last_trav, so as long as the player walks
        -- close enough the gizmo will trigger.  Better than giving up the
        -- whole escape when we KNOW which gizmo to use.
        if approach == nil then
            approach = best_tpos
            approach_source = 'gizmo_pos_fallback'
            console.print(string.format(
                '[TRAP] approach lookup exhausted for %s @(%.1f,%.1f,%.2f) — using gizmo position directly',
                best_trav:get_skin_name(), best_tpos:x(), best_tpos:y(), best_tpos:z()))
        end
        if approach ~= nil then
            -- Long-term blacklist all opposite-direction traversals in the
            -- trap zone — but ONLY when our chosen gizmo matches our directional
            -- preference.  If we picked something arbitrarily (no preference)
            -- or AGAINST preference (e.g. closer Down beat the preferred Up),
            -- long-blocking the opposite would cement the wrong choice and
            -- lock out the right gizmo for 5 minutes.  See logzewx where
            -- escape #3 picked a closer Down and long-blocked the F2→F3 Up
            -- (cand[4] showed `trap_bl=true` on subsequent escapes).
            local best_dir_up = best_trav:get_skin_name():match('Up') ~= nil
            local choice_matches_pref = (prefer_up and best_dir_up)
                or (prefer_down and not best_dir_up)
            local opposite_blocked = 0
            if choice_matches_pref then
                for _, trav2 in ipairs(traversals) do
                    if trav2 ~= best_trav then
                        local tpos2 = trav2:get_position()
                        if tpos2:x() >= min_x - 10 and tpos2:x() <= max_x + 10
                            and tpos2:y() >= min_y - 10 and tpos2:y() <= max_y + 10
                        then
                            local n2 = trav2:get_skin_name()
                            local n2_up = n2:match('Up') ~= nil
                            local n2_down = n2:match('Down') ~= nil
                            local is_opposite =
                                (best_dir_up and n2_down and not n2_up)
                                or (not best_dir_up and n2_up and not n2_down)
                            if is_opposite then
                                local key2 = n2 .. utils.vec_to_string(tpos2)
                                navigator.trap_blacklisted_trav[key2] = now + TRAV_TRAP_BL_DURATION
                                opposite_blocked = opposite_blocked + 1
                            end
                        end
                    end
                end
            end

            console.print(string.format(
                '[TRAP] escape #%d: routing to %s @(%.1f,%.1f,%.2f) [approach=%s] | player @(%.1f,%.1f,%.2f) dist=%.1f dir_match=%s prefer_up=%s bl_thresh=%ds | cleared %d frontiers | %d in zone, %d z-skipped, %d bl-skipped | %d opposite-traversals long-blocked %ds',
                navigator.trapped_escape_count, best_trav:get_skin_name(),
                best_tpos:x(), best_tpos:y(), best_tpos:z(), approach_source,
                player_pos:x(), player_pos:y(), player_pos:z(),
                utils.distance(player_pos, best_tpos),
                tostring(best_is_dir_match), tostring(prefer_up), bl_age_required,
                cleared, n_in_zone, n_skipped_z, n_skipped_bl,
                opposite_blocked, TRAV_TRAP_BL_DURATION))
            -- Wipe the recent blacklist for this traversal so we can re-cross
            local trav_str = best_trav:get_skin_name() .. utils.vec_to_string(best_trav:get_position())
            navigator.blacklisted_trav[trav_str] = nil
            navigator.target = approach
            navigator.is_custom_target = false
            navigator.path = {}
            navigator.last_trav = best_trav
            -- Snapshot player z so the next crossing records its delta_z.
            -- (Re-snapshotted at interact time below for accurate dz reading.)
            navigator.pre_trav_z = player_pos:z()
            navigator.trav_delay = nil  -- allow immediate interact when in range
            -- Reset stuck detection so the new escape target gets a fresh
            -- 1-second window to be reached before STUCK fires.  Without this,
            -- a stale last_update from F1 wandering can trigger STUCK
            -- immediately after we route, and unstuck() can pull the player
            -- away from the gizmo it's about to interact with.
            navigator.last_update    = now
            navigator.unstuck_nodes  = {}
            navigator.unstuck_count  = 0
            -- Post-escape grace: keep trap state alive for a few seconds even
            -- after the bbox grows (climbing naturally widens it).  Lets the
            -- next attempt_escape fire on the new floor and find that floor's
            -- escape gizmo (multi-floor traps need successive escapes).
            navigator.trap_post_escape_grace_until = now + TRAP_POST_ESCAPE_GRACE
            return
        end
    end

    -- No usable traversal found — at least we cleared the frontiers.
    -- Next escape attempt will retry with a fresh frontier scan.
    console.print(string.format(
        '[TRAP] escape #%d: no usable traversal in zone | player @(%.1f,%.1f,%.2f) | cleared %d frontiers | %d in zone, %d z-skipped, %d bl-skipped at thresh=%ds | will retry in %ds',
        navigator.trapped_escape_count, player_pos:x(), player_pos:y(), player_pos:z(),
        cleared, n_in_zone, n_skipped_z, n_skipped_bl, bl_age_required, TRAP_ESCAPE_COOLDOWN))
end

-- Called by external API when HR has handled giving_up (teleported away etc.).
navigator.clear_trap_state = function()
    navigator.trapped              = false
    navigator.trapped_since        = nil
    navigator.trapped_escape_count = 0
    navigator.giving_up            = false
    navigator.trap_pos_history     = {}  -- fresh start so we don't re-fire instantly
    navigator.trap_pos_sample_time = -1
    navigator.trap_post_escape_grace_until = -1
    -- Long-term trap-traversal blacklist is per-zone; teleporting away
    -- invalidates it (those gizmos may not even exist in the new zone).
    navigator.trap_blacklisted_trav = {}
end

return navigator