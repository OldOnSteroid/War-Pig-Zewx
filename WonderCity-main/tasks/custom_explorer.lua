--[[
  WonderCity Custom Explorer
  ==========================
  Replaces Batmobile's full-coverage mode with an objective-first targeted
  sweep. Instead of visiting every corridor, the bot:

    1. Records the floor entry point (spawn_pos) on each new run
    2. Runs a wide-scan every tick for enticements, the grand beacon,
       and the exit warp pad — at a configurable radius larger than
       check_distance, so we see objectives sooner and steer toward them
       before Batmobile's explorer would organically find them
    3. Maintains a frontier of unvisited waypoints generated as a radial
       BFS expansion from spawn — cells of CELL_SIZE units in 8 directions
    4. Selects the next movement target from a strict priority order:
         a. Nearest uninteracted enticement in wide-scan range
         b. Grand beacon (once max_enticement reached or all done)
         c. Exit warp pad (once beacon interacted)
         d. Next unvisited frontier waypoint (exploration fallback)
    5. Detects stuck (no progress toward target in STUCK_TIMEOUT seconds)
       and marks the waypoint unreachable, then picks the next one
    6. Stops generating frontier when boss room is detected
       (Healing_Well_Basic in actor list) — yields to kill_monster / exit tasks

  Integration with existing tasks
  ---------------------------------
  - interact_enticement, portal, kill_monster all have HIGHER priority in
    task_manager.lua and preempt this task automatically — no coordination needed
  - Replace 'explore_undercity' with 'custom_explorer' in task_manager.lua
    task_files list (same slot, end of list before 'idle')
  - interact_enticement continues to handle the actual enticement interaction;
    this task's job is purely navigation to bring objectives into its range

  Movement model
  ---------------
  Uses BatmobilePlugin.set_target + move (same pattern as portal/enticement
  tasks), so Batmobile still handles A* pathfinding around walls. We supply
  better waypoint choices — it handles the actual path to each waypoint.
  When a waypoint is unreachable (partial path / stuck), we discard it and
  move to the next candidate. This is much faster than Batmobile's coverage
  which backtracks to fill every corner.

  Data collected (logged, not yet used for decisions — build the dataset first):
  - Distance at which each objective type first appears in ally actor list
  - Entry position of each floor
  - Positions of all enticements, beacon, warp pad
  - Whether the beacon was deeper in the map than the enticements (expected)
--]]

local plugin_label = 'wonder_city'

local utils   = require 'core.utils'
local settings = require 'core.settings'
local tracker  = require 'core.tracker'

-- ── Tunable constants ─────────────────────────────────────────────────────────
local WIDE_SCAN_RADIUS  = 50    -- radius to detect objectives before check_distance triggers
local CELL_SIZE         = 6     -- BFS grid cell size in world units; smaller = better corridor coverage
local STUCK_TIMEOUT     = 1.8   -- seconds without progress; matches Batmobile's ~2.5s abandonment minus buffer
local STUCK_MIN_DELTA   = 0.5   -- must close distance by this much within timeout to not be stuck
local MAX_FRONTIER      = 80    -- larger frontier pool = more candidates after failures
local MAX_TARGET_DIST   = 25    -- never submit a frontier target farther than this from player

-- ── Floor state (reset on each undercity run) ─────────────────────────────────
local floor = {
    spawn_pos        = nil,   -- vec3: where we entered this floor
    run_time         = nil,   -- tracker.undercity_start_time at floor entry
    found_objectives = {},    -- { key→{type,pos,name,interacted} }
    visited_cells    = {},    -- key→true for cells we've passed through
    frontier         = {},    -- ordered list of vec3 waypoints to visit
    unreachable      = {},    -- key→true for positions we gave up on
    current_target   = nil,   -- vec3 we're currently moving toward
    target_dist_last = nil,   -- distance to target last time we checked
    target_dist_time = nil,   -- time of last progress check
    in_boss_room     = false,
}

-- ── Objective skin name definitions ──────────────────────────────────────────
local OBJ_DEFS = {
    { pattern = 'X1_Undercity_Enticements_SpiritBeaconSwitch', type = 'beacon'      },
    { pattern = 'SpiritHearth_Switch',                          type = 'enticement'  },
    { pattern = 'X1_Undercity_WarpPad',                         type = 'warp_pad'    },
}

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function cell_key(pos)
    local cx = math.floor(pos:x() / CELL_SIZE + 0.5)
    local cy = math.floor(pos:y() / CELL_SIZE + 0.5)
    return cx .. ',' .. cy
end

local function vec3_approx_eq(a, b, tol)
    tol = tol or 0.5
    return math.abs(a:x() - b:x()) < tol
       and math.abs(a:y() - b:y()) < tol
end

local function reset_floor()
    local player = get_local_player()
    local spawn  = player and player:get_position() or vec3:new(0, 0, 0)
    floor.spawn_pos        = spawn
    floor.run_time         = tracker.undercity_start_time
    floor.found_objectives = {}
    floor.visited_cells    = {}
    floor.frontier         = {}
    floor.unreachable      = {}
    floor.current_target   = nil
    floor.target_dist_last = nil
    floor.target_dist_time = nil
    floor.in_boss_room     = false
    -- Seed frontier with a ring of candidates around spawn
    floor.visited_cells[cell_key(spawn)] = true
    console.print(string.format('[WonderCity:explorer] floor reset | spawn=(%.1f, %.1f)',
        spawn:x(), spawn:y()))
end

-- ── Wide-scan: find new objectives across the whole actor list ────────────────
-- Key format MUST match interact_enticement.lua: name..tostring(x)..tostring(y)
-- so that tracker.enticement lookups hit the right entry.
local function obj_key(name, pos)
    return name .. tostring(pos:x()) .. tostring(pos:y())
end

local function wide_scan_objectives()
    local player = get_local_player()
    if not player then return end
    local actors = actors_manager:get_ally_actors()
    for _, actor in pairs(actors) do
        local name = actor:get_skin_name()
        for _, def in ipairs(OBJ_DEFS) do
            if name:match(def.pattern) then
                local pos = actor:get_position()
                local key = obj_key(name, pos)
                if not floor.found_objectives[key] then
                    local dist = utils.distance(player, actor)
                    floor.found_objectives[key] = {
                        type      = def.type,
                        pos       = pos,
                        name      = name,
                        dist_seen = dist,
                    }
                    console.print(string.format(
                        '[WonderCity:explorer] OBJECTIVE %-11s | dist=%5.1f | %s | pos=(%.1f,%.1f)',
                        def.type, dist, name, pos:x(), pos:y()))
                end
                -- no cached interacted field — always read tracker live in pick_target
                break
            end
        end
    end
end

-- ── Boss room detection ───────────────────────────────────────────────────────
local function check_boss_room()
    if floor.in_boss_room then return true end
    local actors = actors_manager:get_all_actors()
    for _, actor in pairs(actors) do
        if actor:get_skin_name() == 'Healing_Well_Basic' then
            floor.in_boss_room = true
            local pos = get_player_position()
            console.print(string.format(
                '[WonderCity:explorer] BOSS_ROOM detected | pos=(%.1f,%.1f)',
                pos:x(), pos:y()))
            return true
        end
    end
    return false
end

-- ── Beacon interacted check (live tracker read) ───────────────────────────────
local function beacon_interacted()
    for key, obj in pairs(floor.found_objectives) do
        if obj.type == 'beacon' and tracker.enticement[key] ~= nil then
            return true
        end
    end
    return false
end

-- ── Frontier: generate new BFS candidates from a position ────────────────────
local DIRS = {
    { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 },
    { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 },
}

local function expand_frontier_from(pos)
    for _, d in ipairs(DIRS) do
        local candidate = vec3:new(
            pos:x() + d[1] * CELL_SIZE,
            pos:y() + d[2] * CELL_SIZE,
            pos:z())
        local key = cell_key(candidate)
        if not floor.visited_cells[key] and not floor.unreachable[key] then
            local already = false
            for _, wp in ipairs(floor.frontier) do
                if vec3_approx_eq(wp, candidate, 1.0) then
                    already = true
                    break
                end
            end
            if not already and #floor.frontier < MAX_FRONTIER then
                table.insert(floor.frontier, candidate)
            end
        end
    end

    -- Sort nearest to player first: prevents the "furthest from spawn" jump that
    -- sent us 200 units across the map after two adjacent wall-cells failed.
    -- Nearest reachable candidate = fastest progress, lowest chance of limit_partial.
    local player_pos = get_player_position()
    table.sort(floor.frontier, function(a, b)
        return player_pos:squared_dist_to_ignore_z(a) < player_pos:squared_dist_to_ignore_z(b)
    end)
end

-- ── Target selection: strict priority order ───────────────────────────────────
-- All interacted checks read tracker.enticement live (keyed by obj_key) so that
-- changes made by interact_enticement are immediately visible here without
-- relying on any cached field that could be stale.
local function pick_target()
    local player = get_local_player()
    if not player then return nil, nil end

    -- How many SpiritHearth enticements have been handled this run (live count)
    local ent_done = utils.get_enticement_count()
    local ent_cap_reached = ent_done >= settings.max_enticement

    -- 1. Nearest uninteracted enticement within WIDE_SCAN_RADIUS — but only
    --    when we haven't hit the cap yet.  interact_enticement takes over once
    --    within check_distance; we just steer toward it.
    if not ent_cap_reached then
        local best_pos, best_dist = nil, math.huge
        for key, obj in pairs(floor.found_objectives) do
            if obj.type == 'enticement' and tracker.enticement[key] == nil then
                local d = utils.distance(player, obj.pos)
                if d <= WIDE_SCAN_RADIUS and d < best_dist then
                    best_pos = obj.pos
                    best_dist = d
                end
            end
        end
        if best_pos then
            return best_pos, string.format('steer→enticement (%d/%d done)', ent_done, settings.max_enticement)
        end
    end

    -- 2. Beacon — once cap reached OR no uninteracted enticements remain in scan
    --    range.  Don't head to it while interact_enticement is still handling one
    --    (its higher task priority already preempts us in that case, so this is
    --    just a belt-and-suspenders guard).
    if not beacon_interacted() then
        for key, obj in pairs(floor.found_objectives) do
            if obj.type == 'beacon' and tracker.enticement[key] == nil then
                return obj.pos, 'steer→beacon'
            end
        end
    end

    -- 3. Warp pad — only after beacon timer has fired and beacon is marked done
    if beacon_interacted() then
        for _, obj in pairs(floor.found_objectives) do
            if obj.type == 'warp_pad' then
                return obj.pos, 'steer→warp_pad'
            end
        end
    end

    -- 4. Frontier exploration fallback — nearest candidate within cap, or globally nearest
    if #floor.frontier > 0 then
        local player_pos = get_player_position()
        -- frontier is sorted nearest-first; find first within distance cap
        local chosen, chosen_dist
        for _, wp in ipairs(floor.frontier) do
            local d = math.sqrt(player_pos:squared_dist_to_ignore_z(wp))
            if chosen == nil then chosen = wp; chosen_dist = d end  -- fallback = nearest overall
            if d <= MAX_TARGET_DIST then
                chosen = wp; chosen_dist = d
                break
            end
        end
        return chosen, string.format('explore→frontier dist=%.0f total=%d', chosen_dist, #floor.frontier)
    end

    return nil, 'no target'
end

-- ── Stuck detection ───────────────────────────────────────────────────────────
local function check_stuck_and_advance(player, target)
    local dist = utils.distance(player, target)
    local now  = get_time_since_inject()

    if floor.target_dist_last == nil or not vec3_approx_eq(target, floor.current_target or target, 1.0) then
        floor.target_dist_last = dist
        floor.target_dist_time = now
        return false
    end

    if dist < floor.target_dist_last - STUCK_MIN_DELTA then
        floor.target_dist_last = dist
        floor.target_dist_time = now
        return false
    end

    if now - floor.target_dist_time > STUCK_TIMEOUT then
        -- Mark the failed cell AND its immediate neighbors unreachable — they're
        -- likely part of the same wall cluster that caused the limit_partial chain.
        -- Without this, the next frontier pop is an adjacent cell that also fails
        -- and we waste another full STUCK_TIMEOUT before recovering.
        floor.unreachable[cell_key(target)] = true
        for _, d in ipairs(DIRS) do
            local npos = vec3:new(target:x() + d[1]*CELL_SIZE, target:y() + d[2]*CELL_SIZE, target:z())
            floor.unreachable[cell_key(npos)] = true
        end

        -- Remove from frontier if still there
        for i, wp in ipairs(floor.frontier) do
            if vec3_approx_eq(wp, target, CELL_SIZE * 0.8) then
                table.remove(floor.frontier, i)
                break
            end
        end

        -- Re-expand from player's current position so the next candidates
        -- are reachable from HERE, not from the failed wall position.
        local player_pos = player:get_position()
        expand_frontier_from(player_pos)

        console.print(string.format(
            '[WonderCity:explorer] STUCK → unreachable (%.1f,%.1f) | frontier=%d',
            target:x(), target:y(), #floor.frontier))

        floor.current_target   = nil
        floor.target_dist_last = nil
        floor.target_dist_time = nil
        return true
    end

    return false
end

-- ── Task wiring ───────────────────────────────────────────────────────────────
local task = {
    name   = 'custom_explorer',
    status = 'idle',
}

task.shouldExecute = function ()
    if not settings.use_custom_explorer then return false end
    if not utils.player_in_undercity() then return false end
    if tracker.boss_trigger_time ~= nil then return false end
    if check_boss_room() then return false end
    return true
end

task.Execute = function ()
    local player = get_local_player()
    if not player then return end

    -- Detect new floor / reset state
    if floor.run_time ~= tracker.undercity_start_time then
        reset_floor()
        -- reset_floor pre-marks spawn as visited so the normal expansion block
        -- below won't fire on this tick — seed the frontier explicitly here now
        -- that expand_frontier_from is in scope (Execute is called at runtime).
        expand_frontier_from(floor.spawn_pos)
    end

    -- Wide scan for new objectives
    wide_scan_objectives()

    -- Mark current cell as visited and expand frontier
    local player_pos = player:get_position()
    local cur_key    = cell_key(player_pos)
    if not floor.visited_cells[cur_key] then
        floor.visited_cells[cur_key] = true
        -- Remove from frontier if we've arrived at it
        if #floor.frontier > 0 and vec3_approx_eq(floor.frontier[1], player_pos, CELL_SIZE * 0.6) then
            table.remove(floor.frontier, 1)
        end
        expand_frontier_from(player_pos)
    end

    -- Orbwalker
    if settings.skip_monsters then
        local near = target_selector.get_near_target_list(player_pos, settings.check_distance)
        local has_notable = false
        for _, e in pairs(near) do
            if (e:is_elite() or e:is_champion()) and e:get_current_health() > 1 then
                has_notable = true
                break
            end
        end
        settings.orb_set_clear(has_notable)
    else
        settings.orb_set_clear(true)
    end

    -- Pick movement target
    local target, reason = pick_target()
    if target == nil then
        -- Frontier exhausted — let Batmobile's own explorer fill in rather than going idle
        BatmobilePlugin.set_priority(plugin_label, settings.batmobile_priority)
        BatmobilePlugin.resume(plugin_label)
        BatmobilePlugin.update(plugin_label)
        BatmobilePlugin.move(plugin_label)
        task.status = 'batmobile fallback (frontier empty)'
        return
    end

    -- Stuck detection — only applies to frontier waypoints, not objectives
    if floor.current_target and vec3_approx_eq(floor.current_target, target, 1.0) then
        if check_stuck_and_advance(player, target) then
            return  -- stuck handler already cleared current_target and popped frontier
        end
    else
        floor.current_target   = target
        floor.target_dist_last = utils.distance(player, target)
        floor.target_dist_time = get_time_since_inject()
    end

    -- Move via Batmobile (A* still handles wall avoidance)
    BatmobilePlugin.pause(plugin_label)
    BatmobilePlugin.update(plugin_label)
    BatmobilePlugin.set_target(plugin_label, target)
    BatmobilePlugin.move(plugin_label)

    task.status = string.format('%s | frontier=%d | visited=%d',
        reason, #floor.frontier,
        (function() local n = 0; for _ in pairs(floor.visited_cells) do n = n + 1 end; return n end)())
end

-- Expose floor state for potential GUI overlay
task.get_floor_state = function () return floor end

return task
