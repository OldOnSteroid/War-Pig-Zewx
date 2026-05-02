local plugin_label = 'arkham_asylum'

local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'

-- Constants
local PUSH_ENGAGE_RANGE = 15       -- "near player" radius for threshold check
local PUSH_CLUSTER_RADIUS = 15     -- enemies within this distance form a cluster
local PUSH_MIN_PULL_DIST = 8       -- ignore clusters already on top of us
local PUSH_ARRIVAL_DIST = 5        -- close enough to pull target
local PUSH_STUCK_TIMEOUT = 5       -- seconds without movement -> unstuck recovery
local PUSH_NAV_TIMEOUT = 12        -- seconds without nav progress -> abandon target

local status_enum = {
    IDLE = 'idle',
    SCANNING = 'scanning',
    PULLING = 'pulling',
    ARRIVING = 'arriving',
}
local task = {
    name = 'push_monsters',
    status = status_enum.IDLE,
}

-- State
local pull_target = nil             -- vec3: where we're pulling toward
local actively_pulling = false      -- prevents flickering between push/kill
local nav_tracking = { pos = nil, time = 0, dist = nil }
local stuck_pos = nil
local stuck_time = 0

local ignore_list = {
    ['S11_BabyBelial_Apparition'] = true
}

-- Get all valid enemies in range, filtered by Z level and alive status
local function get_enemies_in_range(player_pos, range)
    local enemies = target_selector.get_near_target_list(player_pos, range)
    local result = {}
    for _, enemy in pairs(enemies) do
        if not ignore_list[enemy:get_skin_name()] then
            local epos = enemy:get_position()
            if math.abs(player_pos:z() - epos:z()) <= 5
                and enemy:get_current_health() > 1
                and not enemy:is_untargetable()
            then
                result[#result + 1] = enemy
            end
        end
    end
    return result
end

-- Calculate weighted enemy count from a list of enemies
local function calc_weighted(enemies)
    local weighted = 0
    local has_boss = false
    for _, enemy in ipairs(enemies) do
        if enemy:is_boss() then
            weighted = weighted + settings.push_boss_weight
            has_boss = true
        elseif enemy:is_champion() then
            weighted = weighted + settings.push_champion_weight
        elseif enemy:is_elite() then
            weighted = weighted + settings.push_elite_weight
        else
            weighted = weighted + 1
        end
    end
    return weighted, has_boss
end

-- Get weighted count of enemies near the player
local function get_weighted_near_player(player_pos)
    local enemies = get_enemies_in_range(player_pos, PUSH_ENGAGE_RANGE)
    local weighted, has_boss = calc_weighted(enemies)
    return weighted, has_boss, enemies
end

-- Compute the weighted centroid of a list of enemies (heavier enemies pull the center more)
local function get_weighted_centroid(enemies)
    local cx, cy, cz = 0, 0, 0
    local total_w = 0
    for _, enemy in ipairs(enemies) do
        local w = 1
        if enemy:is_boss() then w = settings.push_boss_weight
        elseif enemy:is_champion() then w = settings.push_champion_weight
        elseif enemy:is_elite() then w = settings.push_elite_weight
        end
        local epos = enemy:get_position()
        cx = cx + epos:x() * w
        cy = cy + epos:y() * w
        cz = cz + epos:z() * w
        total_w = total_w + w
    end
    if total_w == 0 then return nil end
    return vec3:new(cx / total_w, cy / total_w, cz / total_w)
end

-- Cluster distant enemies and find the best pull target
-- Scoring: clusters that already meet the threshold get a large bonus so a big
-- pack at 35 units beats two tiny groups at 15 units. Within each tier, closer wins.
local function find_pull_target(player_pos)
    local max_pull = settings.push_max_pull_dist
    local all_enemies = get_enemies_in_range(player_pos, max_pull)

    -- Filter to enemies beyond engage range (we already have nearby ones aggroed)
    local distant = {}
    for _, enemy in ipairs(all_enemies) do
        if utils.distance(player_pos, enemy) > PUSH_ENGAGE_RANGE then
            distant[#distant + 1] = enemy
        end
    end

    if #distant == 0 then return nil end

    -- Simple clustering: assign each enemy to nearest cluster centroid,
    -- or start a new cluster if too far from all existing ones
    local clusters = {} -- each: { cx, cy, cz, count, weighted }
    for _, enemy in ipairs(distant) do
        local epos = enemy:get_position()
        local best_cluster = nil
        local best_dist = PUSH_CLUSTER_RADIUS

        for _, cluster in ipairs(clusters) do
            local cdist = utils.distance(vec3:new(cluster.cx, cluster.cy, cluster.cz), epos)
            if cdist < best_dist then
                best_dist = cdist
                best_cluster = cluster
            end
        end

        -- Weight for this enemy
        local w = 1
        if enemy:is_boss() then w = settings.push_boss_weight
        elseif enemy:is_champion() then w = settings.push_champion_weight
        elseif enemy:is_elite() then w = settings.push_elite_weight
        end

        if best_cluster then
            -- Update centroid incrementally
            local n = best_cluster.count
            best_cluster.cx = (best_cluster.cx * n + epos:x()) / (n + 1)
            best_cluster.cy = (best_cluster.cy * n + epos:y()) / (n + 1)
            best_cluster.cz = (best_cluster.cz * n + epos:z()) / (n + 1)
            best_cluster.count = n + 1
            best_cluster.weighted = best_cluster.weighted + w
        else
            clusters[#clusters + 1] = {
                cx = epos:x(), cy = epos:y(), cz = epos:z(),
                count = 1, weighted = w,
            }
        end
    end

    -- Score clusters with two tiers:
    -- Tier 1: clusters whose weighted size >= threshold (big packs worth traveling to)
    --         score = threshold_bonus + (weighted / max_pull) - (dist / max_pull)
    -- Tier 2: everything else
    --         score = weighted / dist
    -- Tier 1 always beats Tier 2 because threshold_bonus is large.
    -- Within Tier 1, prefer denser clusters at shorter distance.
    local threshold = settings.push_threshold
    local min_weight = settings.push_min_cluster_weight
    local TIER_BONUS = 1000
    local best_score = -1
    local best_centroid = nil
    local best_info = nil
    for _, cluster in ipairs(clusters) do
        -- Skip clusters too small to be worth pulling toward
        if cluster.weighted < min_weight then goto next_cluster end
        local centroid = vec3:new(cluster.cx, cluster.cy, cluster.cz)
        local dist = utils.distance(player_pos, centroid)
        if dist < PUSH_MIN_PULL_DIST then goto next_cluster end

        local score
        if cluster.weighted >= threshold then
            -- Big pack: always prefer these, closer is better
            score = TIER_BONUS + cluster.weighted - dist
        else
            -- Small pack: weighted / distance
            score = cluster.weighted / dist
        end
        if score > best_score then
            best_score = score
            best_centroid = centroid
            best_info = cluster
        end
        ::next_cluster::
    end

    return best_centroid, best_info
end

task.shouldExecute = function()
    if settings.speed_mode then return false end
    if not settings.push_mode then return false end
    if not utils.player_in_pit() then
        return false
    end
    -- Glyphstone present = post-boss-kill safe zone. No need to pull anything.
    if utils.get_glyph_upgrade_gizmo() then return false end
    -- Freeze movement after boss kill while glyphstone spawns
    if tracker.boss_kill_time and
        (get_time_since_inject() - tracker.boss_kill_time) < 10
    then
        return false
    end

    local player_pos = get_player_position()
    if not player_pos then return false end

    local weighted, has_boss, _ = get_weighted_near_player(player_pos)

    -- Always yield for bosses — kill_monster handles them
    if has_boss then
        actively_pulling = false
        pull_target = nil
        return false
    end

    -- Actively pulling: always continue
    if actively_pulling then return true end

    -- No enemies at all -> let explore find them
    if weighted == 0 then return false end

    -- Enemies exist (big group or small) -> push mode handles it
    -- Big group: we'll navigate to the dense center
    -- Small group: we'll pull toward the nearest cluster (or fight if none found)
    return true
end

task.Execute = function()
    local local_player = get_local_player()
    if not local_player then return end
    local player_pos = get_player_position()
    local now = get_time_since_inject()

    orbwalker.set_clear_toggle(true)
    orbwalker.set_block_movement(true)

    local weighted, has_boss, nearby = get_weighted_near_player(player_pos)

    -- Phase 1: Continue toward existing pull target
    if pull_target then
        local dist = utils.distance(player_pos, pull_target)

        -- Check arrival
        if dist < PUSH_ARRIVAL_DIST then
            console.print("[push] arrived at pull target")
            pull_target = nil
            actively_pulling = false
            nav_tracking.pos = nil
            -- Fall through to engage/rescan below
        else
            -- Check if threshold met mid-pull -> stop pulling, engage the pack
            if weighted >= settings.push_threshold then
                console.print(string.format("[push] threshold met mid-pull (%d >= %d), engaging pack",
                    weighted, settings.push_threshold))
                pull_target = nil
                actively_pulling = false
                nav_tracking.pos = nil
                BatmobilePlugin.clear_target(plugin_label)
                -- Fall through to engage centroid below
            else
                -- Nav progress tracking
                if nav_tracking.pos == nil or utils.distance(pull_target, nav_tracking.pos) > 5 then
                    nav_tracking.pos = pull_target
                    nav_tracking.time = now
                    nav_tracking.dist = dist
                elseif dist < nav_tracking.dist - 2 then
                    nav_tracking.dist = dist
                    nav_tracking.time = now
                elseif now - nav_tracking.time > PUSH_NAV_TIMEOUT then
                    console.print("[push] no nav progress for " .. PUSH_NAV_TIMEOUT .. "s, abandoning target")
                    pull_target = nil
                    actively_pulling = false
                    nav_tracking.pos = nil
                    BatmobilePlugin.clear_target(plugin_label)
                    -- Fall through to engage/rescan below
                end
            end
        end

        -- Still pulling (didn't fall through above)
        if pull_target then
            -- Stuck recovery
            if stuck_pos == nil or player_pos:dist_to(stuck_pos) > 3 then
                stuck_pos = player_pos
                stuck_time = now
            elseif now - stuck_time > PUSH_STUCK_TIMEOUT then
                console.print("[push] stuck for " .. PUSH_STUCK_TIMEOUT .. "s, clearing nav state")
                BatmobilePlugin.clear_traversal_blacklist(plugin_label)
                BatmobilePlugin.reset_movement(plugin_label)
                stuck_pos = nil
                stuck_time = now
            end

            BatmobilePlugin.pause(plugin_label)
            local accepted = BatmobilePlugin.set_target(plugin_label, pull_target, false)
            if accepted == false then
                console.print("[push] pull target rejected by navigator, abandoning")
                pull_target = nil
                actively_pulling = false
                nav_tracking.pos = nil
            else
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
                task.status = string.format('pulling (dist=%.0f)', utils.distance(player_pos, pull_target))
                return
            end
        end

        -- Refresh nearby count after state changes above
        weighted, has_boss, nearby = get_weighted_near_player(player_pos)
    end

    -- Phase 2: Threshold met -> engage the dense center of the pack
    if weighted >= settings.push_threshold then
        local centroid = get_weighted_centroid(nearby)
        if centroid then
            local dist = utils.distance(player_pos, centroid)
            if dist > 2 then
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.set_target(plugin_label, centroid, dist <= 4)
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
                task.status = string.format('engaging pack center (%d weighted, dist=%.0f)', weighted, dist)
                return
            end
        end
        -- Already on top of the pack center, let orbwalker/rotation handle combat
        task.status = string.format('in pack (%d weighted)', weighted)
        return
    end

    -- Phase 3: Below threshold -> find a cluster to pull toward
    local target_pos, cluster_info = find_pull_target(player_pos)
    if target_pos then
        pull_target = target_pos
        actively_pulling = true
        nav_tracking.pos = nil
        stuck_pos = nil
        stuck_time = now

        console.print(string.format("[push] pulling toward cluster (%d enemies, weighted=%d, dist=%.1f)",
            cluster_info.count, cluster_info.weighted,
            utils.distance(player_pos, target_pos)))

        BatmobilePlugin.pause(plugin_label)
        local accepted = BatmobilePlugin.set_target(plugin_label, pull_target, false)
        if accepted == false then
            console.print("[push] initial pull target rejected")
            pull_target = nil
            actively_pulling = false
        else
            BatmobilePlugin.update(plugin_label)
            BatmobilePlugin.move(plugin_label)
            task.status = string.format('pulling (%d enemies)', cluster_info.count)
            return
        end
    end

    -- Phase 4: No clusters to pull toward but enemies nearby -> engage centroid of what's here
    if #nearby > 0 then
        local centroid = get_weighted_centroid(nearby)
        if centroid then
            local dist = utils.distance(player_pos, centroid)
            if dist > 2 then
                BatmobilePlugin.pause(plugin_label)
                BatmobilePlugin.set_target(plugin_label, centroid, dist <= 4)
                BatmobilePlugin.update(plugin_label)
                BatmobilePlugin.move(plugin_label)
                task.status = string.format('engaging nearby (%d weighted, dist=%.0f)', weighted, dist)
                return
            end
        end
        task.status = string.format('in pack (%d weighted)', weighted)
        return
    end

    -- Phase 5: Truly nothing -> yield to explore
    pull_target = nil
    actively_pulling = false
    task.status = status_enum.IDLE
end

return task
