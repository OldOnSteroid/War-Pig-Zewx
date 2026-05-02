local utils    = require "core.utils"
local enums    = require "data.enums"
local tracker  = require "core.tracker"

-- ============================================================
-- Constants
-- ============================================================
local GRID_SPACING    = 40     -- meters between grid node centers
local GRID_EXPAND     = 200    -- meters to expand beyond waypoint bounding box on each side
local ARRIVAL_RADIUS  = 20     -- meters: player within this = node scouted
local STUCK_TIMEOUT   = 20     -- seconds with no progress toward target before skipping
local PROGRESS_THRESH = 3      -- meters closer to target required to reset stuck timer
local FAIL_LIMIT      = 3      -- consecutive reach-failures before marking node unreachable
local DIST_BIAS       = 50     -- distance bias in score denominator (prevents obsessing over small diffs)
local MAX_DIRECT_DIST = 40     -- meters: beyond this, return intermediate step instead of raw node pos
local NODE_SKIP_COOLDOWN = 60  -- seconds before a stuck-skipped node can be selected again

-- ============================================================
-- Module state
-- ============================================================
local nodes              = nil  -- array of { pos, visited_at, visit_count, fail_count, unreachable, skip_until }
local nodes_wp_count     = 0    -- fingerprint: #tracker.waypoints when nodes were built
local active_idx         = nil  -- index of current navigation target
local stuck_time         = nil  -- wall-clock when stuck timer started
local stuck_dist         = nil  -- distance to target when stuck timer started
local cached_intermediate = nil -- stable intermediate step position (reused until player reaches it)
local was_in_helltide    = false

local helltide_explorer = {}

-- ============================================================
-- Grid construction
-- ============================================================

local function build_grid()
    local wps = tracker.waypoints
    if not wps or #wps == 0 then return end

    local min_x, max_x =  math.huge, -math.huge
    local min_y, max_y =  math.huge, -math.huge
    local ref_z = 0

    for _, wp in ipairs(wps) do
        local x, y = wp:x(), wp:y()
        if x < min_x then min_x = x end
        if x > max_x then max_x = x end
        if y < min_y then min_y = y end
        if y > max_y then max_y = y end
        ref_z = wp:z()
    end

    min_x = min_x - GRID_EXPAND
    max_x = max_x + GRID_EXPAND
    min_y = min_y - GRID_EXPAND
    max_y = max_y + GRID_EXPAND

    nodes = {}
    local skipped = 0

    for gx = min_x, max_x, GRID_SPACING do
        for gy = min_y, max_y, GRID_SPACING do
            local node = vec3:new(gx, gy, ref_z)
            node = utility.set_height_of_valid_position(node)
            if utility.is_point_walkeable(node) then
                nodes[#nodes + 1] = {
                    pos          = node,
                    visited_at   = 0,
                    visit_count  = 0,
                    fail_count   = 0,
                    unreachable  = false,
                }
            else
                skipped = skipped + 1
            end
        end
    end

    nodes_wp_count = #wps
    active_idx     = nil
    stuck_time     = nil
    stuck_dist     = nil

    console.print(string.format(
        "[EXPLORER] Grid built: %d walkable nodes (%d skipped) | bounds (%.0f,%.0f)-(%.0f,%.0f) | spacing=%dm expand=%dm",
        #nodes, skipped, min_x, min_y, max_x, max_y, GRID_SPACING, GRID_EXPAND))
end

-- ============================================================
-- Node scoring and selection
-- ============================================================

local function score_node(node, player_pos, now)
    if node.unreachable then return -1 end
    if node.skip_until and now < node.skip_until then return -1 end
    local dist = player_pos:dist_to(node.pos)
    if node.visited_at == 0 then
        -- Never visited: highest priority; nearest unvisited wins ties
        return 1e9 - dist
    end
    local age = now - node.visited_at
    return age / (dist + DIST_BIAS)
end

local function select_next_node(player_pos)
    if not nodes then return nil end
    local now = get_time_since_inject()
    local best_idx, best_score = nil, -math.huge

    for i, node in ipairs(nodes) do
        if i ~= active_idx then
            local s = score_node(node, player_pos, now)
            if s > best_score then
                best_score = s
                best_idx   = i
            end
        end
    end

    if best_idx then
        local n = nodes[best_idx]
        -- Count unvisited for logging
        local unvisited = 0
        for _, nd in ipairs(nodes) do
            if nd.visited_at == 0 and not nd.unreachable then
                unvisited = unvisited + 1
            end
        end
        local age_str = n.visited_at == 0 and "never" or string.format("%.0fs ago", now - n.visited_at)
        console.print(string.format(
            "[EXPLORER] -> Node %d at (%.0f,%.0f) dist=%.0fm last=%s visits=%d | unvisited=%d/%d",
            best_idx, n.pos:x(), n.pos:y(),
            player_pos:dist_to(n.pos),
            age_str, n.visit_count,
            unvisited, #nodes))

        -- Top-3 runner-up comparison for debugging node selection quality
        local candidates = {}
        for i, node in ipairs(nodes) do
            if i ~= active_idx then
                local s = score_node(node, player_pos, now)
                if s > 0 then
                    candidates[#candidates + 1] = {idx = i, score = s, dist = player_pos:dist_to(node.pos)}
                end
            end
        end
        table.sort(candidates, function(a, b) return a.score > b.score end)
        if #candidates >= 2 then
            local c3 = candidates[3]
            console.print(string.format("[EXPLORER] Top picks: #%d(s=%.0f d=%.0f) #%d(s=%.0f d=%.0f) #%d(s=%.0f d=%.0f)",
                candidates[1].idx, candidates[1].score, candidates[1].dist,
                candidates[2].idx, candidates[2].score, candidates[2].dist,
                c3 and c3.idx or 0, c3 and c3.score or 0, c3 and c3.dist or 0))
        end
    end

    return best_idx
end

-- ============================================================
-- Public API
-- ============================================================

-- Lazy init / rebuild when waypoints change.
function helltide_explorer.init()
    local wps = tracker.waypoints
    if not wps or #wps == 0 then return end
    if nodes and nodes_wp_count == #wps then return end
    build_grid()
end

-- Called every frame from explore_helltide when experimental_explorer is enabled.
-- Returns vec3 target to navigate toward, or nil when just arrived (next node being chosen).
function helltide_explorer.get_target(player_pos)
    if not nodes or #nodes == 0 then return nil end

    local now = get_time_since_inject()

    -- Periodic grid coverage stats (every 30s)
    if not helltide_explorer._last_stats or now - helltide_explorer._last_stats > 30 then
        helltide_explorer._last_stats = now
        local visited, unvisited_s, unreachable_s, cooling_s = 0, 0, 0, 0
        for _, n in ipairs(nodes) do
            if n.unreachable then unreachable_s = unreachable_s + 1
            elseif n.skip_until and now < n.skip_until then cooling_s = cooling_s + 1
            elseif n.visited_at == 0 then unvisited_s = unvisited_s + 1
            else visited = visited + 1 end
        end
        console.print(string.format("[EXPLORER STATS] visited=%d unvisited=%d unreachable=%d cooling=%d total=%d",
            visited, unvisited_s, unreachable_s, cooling_s, #nodes))
    end

    -- Pick a starting node if we don't have one
    if not active_idx then
        active_idx = select_next_node(player_pos)
        stuck_time = now
        stuck_dist = active_idx and player_pos:dist_to(nodes[active_idx].pos) or nil
        cached_intermediate = nil  -- new node, clear stale intermediate
        if not active_idx then return nil end
    end

    local node = nodes[active_idx]
    local dist = player_pos:dist_to(node.pos)

    -- Arrived
    if dist <= ARRIVAL_RADIUS then
        node.visited_at  = now
        node.visit_count = node.visit_count + 1
        node.fail_count  = 0
        -- Count remaining unvisited
        local unvisited = 0
        for _, nd in ipairs(nodes) do
            if nd.visited_at == 0 and not nd.unreachable then unvisited = unvisited + 1 end
        end
        console.print(string.format(
            "[EXPLORER] Arrived node %d (dist=%.1f) visit#%d | unvisited remaining: %d",
            active_idx, dist, node.visit_count, unvisited))
        active_idx         = nil
        stuck_time         = nil
        stuck_dist         = nil
        cached_intermediate = nil
        return nil
    end

    -- Stuck detection: reset timer if player made progress toward target
    if stuck_dist ~= nil and (stuck_dist - dist) >= PROGRESS_THRESH then
        stuck_time = now
        stuck_dist = dist
    end

    if stuck_time and (now - stuck_time) > STUCK_TIMEOUT then
        node.fail_count = node.fail_count + 1
        if node.fail_count >= FAIL_LIMIT then
            node.unreachable = true
            console.print(string.format(
                "[EXPLORER] Node %d permanently unreachable after %d failures — skipping",
                active_idx, FAIL_LIMIT))
        else
            node.skip_until = now + NODE_SKIP_COOLDOWN
            console.print(string.format(
                "[EXPLORER] Node %d stuck (attempt %d/%d, dist=%.0fm) — cooling down %.0fs",
                active_idx, node.fail_count, FAIL_LIMIT, dist, NODE_SKIP_COOLDOWN))
        end
        active_idx         = nil
        stuck_time         = nil
        stuck_dist         = nil
        cached_intermediate = nil
        return nil
    end

    -- Update stuck baseline distance each frame (only if getting closer)
    if stuck_dist == nil then
        stuck_dist = dist
    end

    -- If node is far away, return a stable intermediate step to keep A* paths short.
    -- Recompute only when we arrive within 10m of the cached point (real progress made),
    -- not every frame — the intermediate shifts slightly as the player moves, which
    -- looks like a new target to navigate_to and triggers a fresh A* attempt each frame.
    if dist > MAX_DIRECT_DIST then
        -- Recompute when player arrives within 5m of the cached point (real progress),
        -- or the cached point is absurdly far (teleport/death).  Using 5m instead of 10m
        -- prevents frame-by-frame recomputation when only a short (try_dist=10) intermediate
        -- is walkable — at 10m threshold the player is always "close enough" to trigger.
        local need_new = cached_intermediate == nil
            or player_pos:dist_to(cached_intermediate) < 5
            or player_pos:dist_to(cached_intermediate) > MAX_DIRECT_DIST + 20
        if need_new then
            local dx = node.pos:x() - player_pos:x()
            local dy = node.pos:y() - player_pos:y()
            local len = math.sqrt(dx * dx + dy * dy)
            -- Try decreasing distances until we find a walkable intermediate.
            -- A straight-line point MAX_DIRECT_DIST ahead can land in a wall or off
            -- a cliff edge after a traversal, causing A* to fail on every attempt.
            local found = false
            local try_dist = MAX_DIRECT_DIST
            while try_dist >= 10 do
                local ix = player_pos:x() + dx / len * try_dist
                local iy = player_pos:y() + dy / len * try_dist
                local candidate = vec3:new(ix, iy, node.pos:z())
                candidate = utility.set_height_of_valid_position(candidate)
                if utility.is_point_walkeable(candidate) then
                    cached_intermediate = candidate
                    found = true
                    break
                end
                try_dist = try_dist - 10
            end
            if not found then
                -- No walkable intermediate in straight line — use node pos directly
                -- and let A* attempt the full path (may still fail but won't loop on a wall).
                cached_intermediate = utility.set_height_of_valid_position(node.pos)
                console.print(string.format("[EXPLORER] Intermediate: NO walkable step -> node %d (%.0f,%.0f) using node directly",
                    active_idx, node.pos:x(), node.pos:y()))
            else
                console.print(string.format("[EXPLORER] Intermediate: (%.0f,%.0f) -> node %d (%.0f,%.0f) try_dist=%d walk=true",
                    cached_intermediate:x(), cached_intermediate:y(),
                    active_idx, node.pos:x(), node.pos:y(), try_dist))
            end
        end
        return cached_intermediate
    end

    -- Close enough to target directly — clear the intermediate cache
    cached_intermediate = nil
    return node.pos
end

-- Returns a snapshot of session stats for optional HUD/logging use.
function helltide_explorer.get_stats()
    if not nodes then return { total=0, unvisited=0, visited=0, unreachable=0 } end
    local total, unvisited, visited, unreachable_count = #nodes, 0, 0, 0
    for _, nd in ipairs(nodes) do
        if nd.unreachable then
            unreachable_count = unreachable_count + 1
        elseif nd.visited_at == 0 then
            unvisited = unvisited + 1
        else
            visited = visited + 1
        end
    end
    return { total=total, unvisited=unvisited, visited=visited, unreachable=unreachable_count }
end

-- Called from navigate_to() when the active node's intermediate has been re-asserted
-- multiple times without the player getting closer.  Advances fail_count exactly like
-- the normal stuck timeout, but fires quickly (every ~10s of re-assertion) instead of
-- waiting for the full 20s STUCK_TIMEOUT which resets whenever the player makes even
-- 3m of incidental progress toward the far node.
function helltide_explorer.report_intermediate_fail()
    if not active_idx or not nodes or not nodes[active_idx] then return end
    local n   = nodes[active_idx]
    local now = get_time_since_inject()
    n.fail_count = n.fail_count + 1
    if n.fail_count >= FAIL_LIMIT then
        n.unreachable = true
        console.print(string.format(
            "[EXPLORER] Node %d permanently unreachable — intermediate failed %d times",
            active_idx, FAIL_LIMIT))
    else
        n.skip_until = now + NODE_SKIP_COOLDOWN
        console.print(string.format(
            "[EXPLORER] Node %d intermediate unreachable (attempt %d/%d) — cooling down %.0fs",
            active_idx, n.fail_count, FAIL_LIMIT, NODE_SKIP_COOLDOWN))
    end
    active_idx          = nil
    stuck_time          = nil
    stuck_dist          = nil
    cached_intermediate = nil
end

-- Returns the active node's raw position (vec3) without recomputing intermediates.
-- Used by long-path nav to feed the actual node target to Batmobile's uncapped
-- A* instead of the distance-capped intermediate that get_target() returns.
function helltide_explorer.get_active_node_pos()
    if active_idx and nodes and nodes[active_idx] then
        return nodes[active_idx].pos
    end
    return nil
end

-- Mark the currently active node as permanently unreachable for this session.
-- Called when the player walks out of the helltide zone boundary — the node
-- that was being navigated toward led outside, so it should never be picked again.
function helltide_explorer.mark_active_unreachable()
    if active_idx and nodes and nodes[active_idx] then
        local n = nodes[active_idx]
        n.unreachable = true
        cached_intermediate = nil
        console.print(string.format(
            "[EXPLORER] Node %d at (%.0f,%.0f) blacklisted — led outside helltide zone",
            active_idx, n.pos:x(), n.pos:y()))
    end
    -- Also clear active so the next get_target() call picks a fresh node inward
    active_idx  = nil
    stuck_time  = nil
    stuck_dist  = nil
end

-- Full wipe — call from helltide_task:reset() on session end.
function helltide_explorer.reset()
    nodes               = nil
    nodes_wp_count      = 0
    active_idx          = nil
    stuck_time          = nil
    stuck_dist          = nil
    cached_intermediate = nil
    console.print("[EXPLORER] Reset — grid and session state cleared")
end

-- ============================================================
-- Helltide-end auto-reset
-- ============================================================
on_update(function()
    local lp = get_local_player()
    if not lp then return end
    local in_helltide = utils.is_in_helltide()
    if was_in_helltide and not in_helltide then
        helltide_explorer.reset()
    end
    was_in_helltide = in_helltide
end)

return helltide_explorer
