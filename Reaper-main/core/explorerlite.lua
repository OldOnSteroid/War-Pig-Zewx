local MinHeap = {}
MinHeap.__index = MinHeap

function MinHeap.new(compare)
    return setmetatable({heap = {}, compare = compare or function(a, b) return a < b end}, MinHeap)
end

function MinHeap:push(value)
    table.insert(self.heap, value)
    self:siftUp(#self.heap)
end

function MinHeap:pop()
    local root = self.heap[1]
    self.heap[1] = self.heap[#self.heap]
    table.remove(self.heap)
    self:siftDown(1)
    return root
end

function MinHeap:peek()
    return self.heap[1]
end

function MinHeap:empty()
    return #self.heap == 0
end

function MinHeap:siftUp(index)
    local parent = math.floor(index / 2)
    while index > 1 and self.compare(self.heap[index], self.heap[parent]) do
        self.heap[index], self.heap[parent] = self.heap[parent], self.heap[index]
        index = parent
        parent = math.floor(index / 2)
    end
end

function MinHeap:siftDown(index)
    local size = #self.heap
    while true do
        local smallest = index
        local left  = 2 * index
        local right = 2 * index + 1
        if left  <= size and self.compare(self.heap[left],  self.heap[smallest]) then smallest = left  end
        if right <= size and self.compare(self.heap[right], self.heap[smallest]) then smallest = right end
        if smallest == index then break end
        self.heap[index], self.heap[smallest] = self.heap[smallest], self.heap[index]
        index = smallest
    end
end

function MinHeap:contains(value)
    for _, v in ipairs(self.heap) do
        if v == value then return true end
    end
    return false
end

local utils    = require "core.utils"
local enums    = require "data.enums"
local settings = require "core.settings"
local tracker  = require "core.tracker"

local explorerlite = {
    enabled         = false,
    is_task_running = false,  -- prevents path interference while a task is active
}

local explored_areas          = {}
local target_position         = nil
local grid_size               = 2    -- grid cell size in meters
local exploration_radius      = 10   -- radius considered explored
local explored_buffer         = 2    -- buffer around explored areas in meters
local max_target_distance     = 120  -- maximum distance for a new exploration target
local target_distance_states  = {120, 40, 20, 5}
local target_distance_index   = 1
local unstuck_target_distance = 15   -- maximum search radius for an unstuck target
local stuck_threshold         = 20   -- seconds before the player is considered stuck
local last_position           = nil
local last_move_time          = 0
local last_explored_targets   = {}
local max_last_targets        = 50
local stuck_check_interval    = 10   -- how often (seconds) to run the stuck check
local stuck_distance_threshold = 0.5 -- player is stuck if they moved less than this
local temp_target_distance    = 10   -- radius used when picking a temporary unstuck target
local last_stuck_check_time   = 0
local last_stuck_check_position = nil
local original_target         = nil

-- A* pathfinding state
local current_path          = {}
local path_index            = 1
local last_movement_direction = nil

-- Exploration mode: "unexplored" finds new areas; "explored" revisits known areas
local exploration_mode = "unexplored"

-- -------------------------------------------------------
-- Clears the current path and target position
-- -------------------------------------------------------
function explorerlite:clear_path_and_target()
    console.print("Clearing path and target.")
    target_position = nil
    current_path    = {}
    path_index      = 1
end

local function calculate_distance(point1, point2)
    if not point2.x and point2 then
        return point1:dist_to_ignore_z(point2:get_position())
    end
    return point1:dist_to_ignore_z(point2)
end

-- Sets a point's Z coordinate to the valid walkable height at that XY position
local function set_height_of_valid_position(point)
    return utility.set_height_of_valid_position(point)
end

local function get_grid_key(point)
    return math.floor(point:x() / grid_size) .. "," ..
        math.floor(point:y() / grid_size) .. "," ..
        math.floor(point:z() / grid_size)
end

local explored_area_bounds = {
    min_x = math.huge,
    max_x = -math.huge,
    min_y = math.huge,
    max_y = -math.huge,
    min_z = math.huge,
    max_z = math.huge
}

local function update_explored_area_bounds(point, radius)
    explored_area_bounds.min_x = math.min(explored_area_bounds.min_x, point:x() - radius)
    explored_area_bounds.max_x = math.max(explored_area_bounds.max_x, point:x() + radius)
    explored_area_bounds.min_y = math.min(explored_area_bounds.min_y, point:y() - radius)
    explored_area_bounds.max_y = math.max(explored_area_bounds.max_y, point:y() + radius)
    explored_area_bounds.min_z = math.min(explored_area_bounds.min_z or math.huge,  point:z() - radius)
    explored_area_bounds.max_z = math.max(explored_area_bounds.max_z or -math.huge, point:z() + radius)
end

local function is_point_in_explored_area(point)
    return point:x() >= explored_area_bounds.min_x and point:x() <= explored_area_bounds.max_x and
        point:y() >= explored_area_bounds.min_y and point:y() <= explored_area_bounds.max_y and
        point:z() >= explored_area_bounds.min_z and point:z() <= explored_area_bounds.max_z
end

-- -------------------------------------------------------
-- Finds a random nearby walkable position to escape a stuck state
-- -------------------------------------------------------
local function find_unstuck_target()
    console.print("Finding unstuck target.")
    local player_pos    = get_player_position()
    local valid_targets = {}

    for x = -unstuck_target_distance, unstuck_target_distance, grid_size do
        for y = -unstuck_target_distance, unstuck_target_distance, grid_size do
            local point = vec3:new(
                player_pos:x() + x,
                player_pos:y() + y,
                player_pos:z()
            )
            point = set_height_of_valid_position(point)
            local distance = calculate_distance(player_pos, point)
            if utility.is_point_walkeable(point) and distance >= 2 and distance <= unstuck_target_distance then
                table.insert(valid_targets, point)
            end
        end
    end

    if #valid_targets > 0 then
        return valid_targets[math.random(#valid_targets)]
    end
    return nil
end

explorerlite.find_unstuck_target = find_unstuck_target

local function handle_stuck_player()
    local current_time = os.time()
    local player_pos   = get_player_position()

    if not last_stuck_check_position then
        last_stuck_check_position = player_pos
        last_stuck_check_time     = current_time
        return false
    end

    if current_time - last_stuck_check_time >= stuck_check_interval then
        local distance_moved = calculate_distance(player_pos, last_stuck_check_position)

        if distance_moved < stuck_distance_threshold then
            console.print("Player appears to be stuck. Finding temporary target.")
            original_target = target_position
            local temp_target = find_unstuck_target()
            if temp_target then
                target_position = temp_target
            else
                console.print("Failed to find temporary target.")
            end
            return true
        elseif original_target and distance_moved >= stuck_distance_threshold * 2 then
            console.print("Player has moved. Returning to original target.")
            target_position = original_target
            original_target = nil
        end

        last_stuck_check_position = player_pos
        last_stuck_check_time     = current_time
    end

    return false
end

-- -------------------------------------------------------
-- Resets all exploration state so areas are treated as unexplored again
-- -------------------------------------------------------
function explorerlite:reset_exploration()
    explored_area_bounds = {
        min_x = math.huge,
        max_x = -math.huge,
        min_y = math.huge,
        max_y = -math.huge,
    }
    target_position       = nil
    last_position         = nil
    last_move_time        = 0
    current_path          = {}
    path_index            = 1
    exploration_mode      = "unexplored"
    last_movement_direction = nil

    console.print("Exploration reset. All areas marked as unexplored.")
end

-- Returns true if the given point is adjacent to an unwalkable cell (near a wall)
local function is_near_wall(point)
    local wall_check_distance = 2
    local directions = {
        { x = 1,  y = 0  }, { x = -1, y = 0  }, { x = 0,  y = 1  }, { x = 0,  y = -1 },
        { x = 1,  y = 1  }, { x = 1,  y = -1 }, { x = -1, y = 1  }, { x = -1, y = -1 }
    }
    for _, dir in ipairs(directions) do
        local check_point = vec3:new(
            point:x() + dir.x * wall_check_distance,
            point:y() + dir.y * wall_check_distance,
            point:z()
        )
        check_point = set_height_of_valid_position(check_point)
        if not utility.is_point_walkeable(check_point) then
            return true
        end
    end
    return false
end

local function find_random_explored_target()
    console.print("Finding random explored target.")
    local player_pos     = get_player_position()
    local check_radius   = max_target_distance
    local explored_points = {}

    for x = -check_radius, check_radius, grid_size do
        for y = -check_radius, check_radius, grid_size do
            local point = vec3:new(
                player_pos:x() + x,
                player_pos:y() + y,
                player_pos:z()
            )
            point = set_height_of_valid_position(point)
            local grid_key = get_grid_key(point)
            if utility.is_point_walkeable(point) and explored_areas[grid_key] and not is_near_wall(point) then
                table.insert(explored_points, point)
            end
        end
    end

    if #explored_points == 0 then return nil end
    return explored_points[math.random(#explored_points)]
end

function vec3.__add(v1, v2)
    return vec3:new(v1:x() + v2:x(), v1:y() + v2:y(), v1:z() + v2:z())
end

local function is_in_last_targets(point)
    for _, target in ipairs(last_explored_targets) do
        if calculate_distance(point, target) < grid_size * 2 then
            return true
        end
    end
    return false
end

local function add_to_last_targets(point)
    table.insert(last_explored_targets, 1, point)
    if #last_explored_targets > max_last_targets then
        table.remove(last_explored_targets)
    end
end

-- -------------------------------------------------------
-- A* pathfinding
-- -------------------------------------------------------

-- Heuristic: straight-line distance to goal
local function heuristic(a, b)
    return calculate_distance(a, b)
end

-- Returns all walkable grid neighbors of a point
local function get_neighbors(point)
    local neighbors = {}
    local directions = {
        { x = 1,  y = 0  }, { x = -1, y = 0  }, { x = 0,  y = 1  }, { x = 0,  y = -1 },
        { x = 1,  y = 1  }, { x = 1,  y = -1 }, { x = -1, y = 1  }, { x = -1, y = -1 }
    }
    for _, dir in ipairs(directions) do
        local neighbor = vec3:new(
            point:x() + dir.x * grid_size,
            point:y() + dir.y * grid_size,
            point:z()
        )
        neighbor = set_height_of_valid_position(neighbor)
        if utility.is_point_walkeable(neighbor) then
            -- Avoid immediately reversing direction unless no other option is available
            if not last_movement_direction or
                (dir.x ~= -last_movement_direction.x or dir.y ~= -last_movement_direction.y) then
                table.insert(neighbors, neighbor)
            end
        end
    end

    -- If all forward neighbors are blocked, allow backtracking
    if #neighbors == 0 and last_movement_direction then
        local back = vec3:new(
            point:x() - last_movement_direction.x * grid_size,
            point:y() - last_movement_direction.y * grid_size,
            point:z()
        )
        back = set_height_of_valid_position(back)
        if utility.is_point_walkeable(back) then
            table.insert(neighbors, back)
        end
    end

    return neighbors
end

local function reconstruct_path(came_from, current)
    local path = { current }
    while came_from[get_grid_key(current)] do
        current = came_from[get_grid_key(current)]
        table.insert(path, 1, current)
    end

    -- Remove collinear intermediate points to simplify the path
    local filtered_path = { path[1] }
    for i = 2, #path - 1 do
        local prev = path[i - 1]
        local curr = path[i]
        local next = path[i + 1]

        local dir1 = { x = curr:x() - prev:x(), y = curr:y() - prev:y() }
        local dir2 = { x = next:x() - curr:x(), y = next:y() - curr:y() }

        local dot_product = dir1.x * dir2.x + dir1.y * dir2.y
        local magnitude1  = math.sqrt(dir1.x^2 + dir1.y^2)
        local magnitude2  = math.sqrt(dir2.x^2 + dir2.y^2)
        local angle       = math.acos(dot_product / (magnitude1 * magnitude2))

        -- Keep this point only if the direction changes
        if angle > 0 then
            table.insert(filtered_path, curr)
        end
    end
    table.insert(filtered_path, path[#path])

    return filtered_path
end

local function a_star(start, goal)
    local closed_set = {}
    local came_from  = {}
    local g_score    = { [get_grid_key(start)] = 0 }
    local f_score    = { [get_grid_key(start)] = heuristic(start, goal) }
    local iterations = 0

    local open_set = MinHeap.new(function(a, b)
        return f_score[get_grid_key(a)] < f_score[get_grid_key(b)]
    end)
    open_set:push(start)

    while not open_set:empty() do
        iterations = iterations + 1
        if iterations > 6666 then
            console.print("Max iterations reached, aborting!")
            break
        end

        local current = open_set:pop()
        if calculate_distance(current, goal) < grid_size then
            max_target_distance   = target_distance_states[1]
            target_distance_index = 1
            return reconstruct_path(came_from, current)
        end

        closed_set[get_grid_key(current)] = true

        for _, neighbor in ipairs(get_neighbors(current)) do
            if not closed_set[get_grid_key(neighbor)] then
                local tentative_g = g_score[get_grid_key(current)] + calculate_distance(current, neighbor)

                if not g_score[get_grid_key(neighbor)] or tentative_g < g_score[get_grid_key(neighbor)] then
                    came_from[get_grid_key(neighbor)] = current
                    g_score[get_grid_key(neighbor)]   = tentative_g
                    f_score[get_grid_key(neighbor)]   = tentative_g + heuristic(neighbor, goal)

                    if not open_set:contains(neighbor) then
                        open_set:push(neighbor)
                    end
                end
            end
        end
    end

    if target_distance_index < #target_distance_states then
        target_distance_index = target_distance_index + 1
        max_target_distance   = target_distance_states[target_distance_index]
        console.print("No path found. Reducing max target distance to " .. max_target_distance)
    else
        console.print("No path found even after reducing max target distance.")
    end

    return nil
end

local last_a_star_call = 0.0

-- -------------------------------------------------------
-- Stuck detection (public, used by kill_monsters task)
-- -------------------------------------------------------
local function check_if_stuck()
    local current_pos  = get_player_position()
    local current_time = os.time()

    if last_position and calculate_distance(current_pos, last_position) < 0.1 then
        if current_time - last_move_time > stuck_threshold then
            return true
        end
    else
        last_move_time = current_time
    end

    last_position = current_pos
    return false
end

explorerlite.check_if_stuck = check_if_stuck

function explorerlite:set_custom_target(target)
    target_position = target
end

function explorerlite:movement_spell_to_target(target)
    local local_player = get_local_player()
    if not local_player then return end

    local movement_spell_id = {
        288106,  -- Sorcerer: Teleport
        358761,  -- Rogue: Dash
        355606,  -- Rogue: Shadow Step
        1663206, -- Spiritborn: Hunter
        1871821, -- Spiritborn: Soar
    }

    if settings.use_evade_as_movement_spell then
        table.insert(movement_spell_id, 337031) -- General Evade
    end

    for _, spell_id in ipairs(movement_spell_id) do
        if local_player:is_spell_ready(spell_id) then
            local success = cast_spell.position(spell_id, target, 3.0)
            if success then
                console.print("Successfully used movement spell to target.")
            else
                console.print("Failed to use movement spell.")
            end
        else
            console.print("Movement spell on cooldown.")
        end
    end
end

-- Requests a move along the A* path toward the current target position
local function move_to_target()
    if explorerlite.is_task_running then
        return  -- Do not pathfind while a task is active
    end

    if target_position then
        local player_pos = get_player_position()
        if calculate_distance(player_pos, target_position) > 500 then
            current_path = {}
            path_index   = 1
            return
        end

        local current_core_time    = get_time_since_inject()
        local time_since_last_call = current_core_time - last_a_star_call

        if not current_path or #current_path == 0 or path_index > #current_path or time_since_last_call >= 0.50 then
            path_index       = 1
            current_path     = nil
            current_path     = a_star(player_pos, target_position)
            last_a_star_call = current_core_time

            if not current_path then
                console.print("No path found to target. Finding new target.")
                return
            end
        end

        local next_point = current_path[path_index]
        if next_point and not next_point:is_zero() then
            pathfinder.request_move(next_point)
        end

        if next_point and next_point.x and not next_point:is_zero() and
            calculate_distance(player_pos, next_point) < grid_size then
            last_movement_direction = {
                x = next_point:x() - player_pos:x(),
                y = next_point:y() - player_pos:y()
            }
            path_index = path_index + 1
        end

        if calculate_distance(player_pos, target_position) < 2 then
            target_position = nil
            current_path    = {}
            path_index      = 1
        end
    else
        -- No target; nudge toward world origin as a fallback
        console.print("No target found. Moving to center.")
        pathfinder.force_move_raw(vec3:new(9.204102, 8.915039, 0.000000))
    end
end

-- Moves directly to the target without A* (used in aggressive movement mode)
local function move_to_target_aggressive()
    if target_position then
        pathfinder.force_move_raw(target_position)
    else
        console.print("No target found. Moving to center.")
        pathfinder.force_move_raw(vec3:new(9.204102, 8.915039, 0.000000))
    end
end

function explorerlite:move_to_target()

    if handle_stuck_player() then
        -- A temporary unstuck target was just set; move toward it immediately
        if settings.aggressive_movement then
            move_to_target_aggressive()
        else
            move_to_target()
        end
        return
    end

    if settings.aggressive_movement then
        move_to_target_aggressive()
    else
        move_to_target()
    end
end

on_render(function()
    if not settings.enabled then return end
    -- Path waypoints are available here for debug rendering if needed
end)

return explorerlite
