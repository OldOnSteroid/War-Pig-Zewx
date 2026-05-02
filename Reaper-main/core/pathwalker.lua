-- ============================================================
--  Reaper - core/pathwalker.lua
--
--  Smooth lookahead path walker.
--  Supports two waypoint types:
--    Normal:   vec3  OR  { vec3 }            → pathfinder.request_move
--    Interact: { vec3, action="interact" }   → interact_object (ladder etc.)
-- ============================================================

local explorerlite = require "core.explorerlite"

local M = {}

M.is_walking          = false
M.current_path        = {}   -- normalised: { pos=vec3, action=nil|"interact" }
M.original_path       = {}
M.current_waypoint_index = 1
M.walking_to_start    = false

-- ---- Tuning ----
local REACH_DIST      = 2.5
local LOOKAHEAD_DIST  = 15.0  -- look further ahead for smoother movement
local STUCK_THRESHOLD = 3.0
local INTERACT_RANGE  = 3.5
local INTERACT_WAIT   = 2.5   -- seconds to wait after interact before advancing

-- ---- Internal state ----
local last_pos        = nil
local last_pos_time   = 0
local stuck_timer     = 0
local interacting     = false   -- true while waiting post-interact
local interact_start  = 0

local function now() return get_gametime() end

-- -------------------------------------------------------
-- Normalise mixed path formats into { pos=vec3, action=? }
-- -------------------------------------------------------
local function normalise(points)
    local out = {}
    for _, p in ipairs(points) do
        if type(p) == "userdata" then
            -- plain vec3
            out[#out + 1] = { pos = p, action = nil }
        elseif type(p) == "table" then
            local pos
            if type(p[1]) == "userdata" then
                pos = p[1]
            else
                -- { x=, y=, z= } table from PathRecorder
                pos = vec3:new(p.x or p[1] or 0, p.y or p[2] or 0, p.z or p[3] or 0)
            end
            out[#out + 1] = { pos = pos, action = p.action }
        end
    end
    return out
end

-- -------------------------------------------------------
-- Lookahead target selection (operates on normalised path)
-- -------------------------------------------------------
local function find_target_index(player_pos)
    local path = M.current_path
    local idx  = M.current_waypoint_index
    local n    = #path

    -- Advance past reached points (use ignore_z for horizontal reach check)
    while idx <= n do
        if player_pos:dist_to_ignore_z(path[idx].pos) > REACH_DIST then break end
        idx = idx + 1
    end
    if idx > n then return n end

    -- Stop at interact waypoints — don't look past them
    if path[idx].action == "interact" then return idx end

    -- Lookahead for normal waypoints
    local best = idx
    for i = idx + 1, n do
        if path[i].action == "interact" then break end  -- don't skip over interact
        if player_pos:dist_to_ignore_z(path[i].pos) <= LOOKAHEAD_DIST then
            best = i
        else
            break
        end
    end
    return best
end

-- -------------------------------------------------------
-- Interact helper
-- -------------------------------------------------------
local function try_interact(wp_pos)
    local player_pos = get_player_position()
    if not player_pos then return false end

    local actors = actors_manager:get_all_actors()
    local best, best_dist = nil, INTERACT_RANGE
    for _, actor in pairs(actors) do
        local ok, inter = pcall(function() return actor:is_interactable() end)
        if ok and inter then
            local d = player_pos:dist_to(actor:get_position())
            if d < best_dist then best = actor; best_dist = d end
        end
    end

    if best then
        console.print(string.format("[Pathwalker] Interact: %s (%.1fm)",
            best:get_skin_name(), best_dist))
        interact_object(best)
        return true
    end
    return false
end

-- -------------------------------------------------------
-- Per-run path jitter
-- Applies a small random XY offset to each non-interact waypoint so
-- the walked path varies slightly each run. The last waypoint is left
-- untouched so arrival at the altar/entrance is always precise.
-- If the jittered point is not walkable, the original position is kept.
-- -------------------------------------------------------
local JITTER_MAX = 1.8   -- maximum offset in meters on either axis

local function jitter_path(path)
    local n = #path
    for i = 1, n - 1 do        -- skip last waypoint
        local wp = path[i]
        if wp.action ~= "interact" then
            local ox = (math.random() * 2 - 1) * JITTER_MAX
            local oy = (math.random() * 2 - 1) * JITTER_MAX
            local candidate = vec3:new(
                wp.pos:x() + ox,
                wp.pos:y() + oy,
                wp.pos:z()
            )
            candidate = utility.set_height_of_valid_position(candidate)
            if utility.is_point_walkeable(candidate) then
                path[i] = { pos = candidate, action = wp.action }
            end
            -- If not walkable, keep the original point unchanged
        end
    end
    return path
end

-- -------------------------------------------------------
-- Public API
-- -------------------------------------------------------

function M.start_walking_path_with_points(points, path_name, _force)
    if not points or #points == 0 then
        console.print("[Pathwalker] No points provided.")
        return false
    end

    local normalised = normalise(points)
    jitter_path(normalised)

    M.current_path           = normalised
    M.original_path          = normalised
    M.current_waypoint_index = 1
    M.is_walking             = true
    M.walking_to_start       = false
    last_pos                 = nil
    last_pos_time            = now()
    stuck_timer              = 0
    interacting              = false
    interact_start           = 0

    console.print(string.format("[Pathwalker] Started: %s (%d pts, jitter=%.1fm)",
        path_name or "path", #M.current_path, JITTER_MAX))
    return true
end

function M.stop_walking()
    M.is_walking             = false
    M.current_path           = {}
    M.original_path          = {}
    M.current_waypoint_index = 1
    M.walking_to_start       = false
    interacting              = false
    last_pos                 = nil
end

function M.is_path_completed()
    return not M.is_walking and #M.original_path > 0
end

function M.is_at_final_waypoint()
    if not M.is_walking or #M.current_path == 0 then return false end
    local player_pos = get_player_position()
    if not player_pos then return false end
    return player_pos:dist_to_ignore_z(M.current_path[#M.current_path].pos) <= REACH_DIST
end

function M.get_progress() return M.current_waypoint_index, #M.current_path end
function M.get_status()
    if not M.is_walking then return "Not walking" end
    if interacting then return "Waiting for transition" end
    return string.format("Walking %d/%d", M.current_waypoint_index, #M.current_path)
end

-- -------------------------------------------------------
-- Main update
-- -------------------------------------------------------
function M.update_path_walking()
    if not M.is_walking or #M.current_path == 0 then return end

    local player_pos = get_player_position()
    if not player_pos then return end

    local n = #M.current_path
    local t = now()

    -- ---- Post-interact wait ----
    if interacting then
        if (t - interact_start) >= INTERACT_WAIT then
            interacting = false
            -- Advance past the interact waypoint
            M.current_waypoint_index = math.min(M.current_waypoint_index + 1, n)
            console.print("[Pathwalker] Transition done – resuming path.")
        else
            -- Still waiting — keep trying in case first interact didn't register
            if (t - interact_start) > 0.5 then
                try_interact(M.current_path[M.current_waypoint_index].pos)
            end
        end
        return
    end

    -- ---- End of path ----
    if M.current_waypoint_index >= n then
        if player_pos:dist_to_ignore_z(M.current_path[n].pos) <= REACH_DIST then
            console.print("[Pathwalker] Path complete.")
            M.stop_walking()
            return
        end
    end

    -- ---- Stuck detection ----
    if last_pos then
        if player_pos:dist_to_ignore_z(last_pos) < 0.3 then
            stuck_timer = stuck_timer + (t - last_pos_time)
            if stuck_timer >= STUCK_THRESHOLD then
                M.current_waypoint_index = math.min(M.current_waypoint_index + 3, n)
                stuck_timer = 0
                console.print(string.format("[Pathwalker] Stuck – skipped to #%d", M.current_waypoint_index))
            end
        else
            stuck_timer = 0
        end
    end
    last_pos      = player_pos
    last_pos_time = t

    -- ---- Find target ----
    local target_idx = find_target_index(player_pos)
    M.current_waypoint_index = target_idx

    local wp = M.current_path[target_idx]

    -- ---- Interact waypoint ----
    if wp.action == "interact" then
        local dist = player_pos:dist_to_ignore_z(wp.pos)
        if dist <= INTERACT_RANGE then
            if try_interact(wp.pos) then
                interacting    = true
                interact_start = t
                return
            end
        end
        -- Walk toward interact point
        explorerlite:set_custom_target(wp.pos)
        explorerlite:move_to_target()
        return
    end

    -- ---- Normal walk — continuous movement via explorerlite ----
    explorerlite:set_custom_target(wp.pos)
    explorerlite:move_to_target()
end

return M
