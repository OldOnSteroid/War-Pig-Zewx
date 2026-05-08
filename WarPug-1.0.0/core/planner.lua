local settings = require 'core.settings'

local planner = {}

-- ── Constants ────────────────────────────────────────────────────────────────

-- Activity names from warplan.node_name() that must NEVER appear in a
-- confirmed path. Based on SAMPLEDUMP data.
local BLOCKED = {
    ['Warplans_NightmareDungeons'] = true,
}

local TEMIS_ZONE = 'Skov_Temis'

local INTERACT_DIST          = 3.0
local INTERACT_COOLDOWN      = 1.5
local WAIT_READY_TIMEOUT     = 12.0  -- seconds before giving up after table interact
local REROLL_CLICK1_DELAY    = 1.5   -- wait after reroll click before firing confirm
local REROLL_SETTLE_DELAY    = 4.0   -- wait after confirm before retrying plan search
local DONE_WAIT_TIMEOUT      = 30.0  -- max wait after confirm() before giving up
local MAX_REROLLS            = 10    -- safety cap: give up if every new tree also has no valid path
local DIAG_INTERVAL          = 5.0   -- minimum seconds between repeated warning prints

local CLICK_FADE = 6.0  -- seconds before click fade markers disappear

-- ── States ───────────────────────────────────────────────────────────────────

local S = {
    IDLE           = 'IDLE',
    APPROACH_TABLE = 'APPROACH_TABLE',
    INTERACT_TABLE = 'INTERACT_TABLE',
    WAIT_READY     = 'WAIT_READY',
    FIND_PATH      = 'FIND_PATH',
    CONFIRMING     = 'CONFIRMING',
    DONE_WAIT      = 'DONE_WAIT',
    REROLL_CLICK1  = 'REROLL_CLICK1',
    REROLL_WAIT1   = 'REROLL_WAIT1',
    REROLL_CLICK2  = 'REROLL_CLICK2',
    REROLL_WAIT2   = 'REROLL_WAIT2',
}

local state         = S.IDLE
local state_entered = -math.huge
local last_interact = -math.huge
local last_diag     = -math.huge
local reroll_count   = 0
local reroll_pending = false  -- true when we need to open the panel then fire reroll clicks
local recent_clicks  = {}

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function now()  return get_time_since_inject() end
local function log(m) console.print('[WarPug] ' .. m) end

local function vlog(m)
    if settings.verbose_logs then console.print('[WarPug:v] ' .. m) end
end

local function set_state(s)
    if s ~= state then
        log('state ' .. state .. ' -> ' .. s)
        state         = s
        state_entered = now()
    end
end

local function record_click(label, x, y)
    recent_clicks[#recent_clicks + 1] = { label = label, x = x, y = y, t = now() }
    while #recent_clicks > 8 do table.remove(recent_clicks, 1) end
end

function planner.get_recent_clicks()
    local t = now()
    while recent_clicks[1] and (t - recent_clicks[1].t) > CLICK_FADE do
        table.remove(recent_clicks, 1)
    end
    return recent_clicks, CLICK_FADE
end

function planner.get_current_state() return state end

local function in_temis()
    local world = get_current_world()
    if not world then return false end
    local ok, z = pcall(function() return world:get_current_zone_name() end)
    return ok and type(z) == 'string' and z == TEMIS_ZONE
end

local function has_warplan_quests()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return false end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if ok_n and type(name) == 'string' and name:find('WarPlans_QST', 1, true) then
            return true
        end
    end
    return false
end

local function warplan_api_ready()
    if not _G.warplan or type(warplan.is_ready) ~= 'function' then return false end
    local ok, v = pcall(function() return warplan.is_ready() end)
    return ok and v == true
end

local function clear_warplan_path()
    if not _G.warplan then return end
    pcall(function()
        while warplan.selected_count() > 0 do
            if not warplan.deselect_last() then break end
        end
    end)
end

local function find_table_actor()
    local name = settings.table_actor_name
    if not name or name == '' then return nil end
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= 'table' then return nil end
    for _, actor in pairs(actors) do
        local ok, skin = pcall(function() return actor:get_skin_name() end)
        if ok and skin == name then return actor end
    end
    return nil
end

-- DFS with backtracking through the live warplan API.
-- Finds a path of exactly `required` picks containing no BLOCKED activities.
-- Leaves the warplan in fully-selected state on success.
-- Returns true if a valid path was found, false otherwise.
local function dfs(required)
    local depth = warplan.selected_count()
    if depth == required then
        return warplan.is_complete()
    end
    local legal = warplan.get_selectable_now()
    vlog(string.format('dfs depth=%d/%d, choices=%d', depth, required, #legal))
    local count_before = depth
    for _, id in ipairs(legal) do
        local ok_n, name = pcall(function() return warplan.node_name(id) end)
        local activity   = (ok_n and type(name) == 'string') and name or ''
        if BLOCKED[activity] then
            vlog(string.format('  skip blocked: %d:%s', id, activity))
        else
            vlog(string.format('  try: %d:%s', id, activity))
            local ok_s, accepted = pcall(function() return warplan.select_node(id) end)
            if ok_s and accepted then
                if dfs(required) then return true end
                -- Backtrack: undo this pick and try the next sibling
                warplan.deselect_last()
                if warplan.selected_count() ~= count_before then
                    -- deselect_last refused or returned inconsistent state
                    log('dfs: deselect_last inconsistency — aborting search')
                    return false
                end
                vlog(string.format('  backtrack: %d:%s', id, activity))
            else
                vlog(string.format('  select_node rejected: %d:%s', id, activity))
            end
        end
    end
    return false
end

local function do_click(x, y, label)
    if x > 0 and y > 0 then
        local have_util = utility and type(utility.send_mouse_click) == 'function'
        if have_util then
            if type(utility.send_mouse_move) == 'function' then
                utility.send_mouse_move(x, y)
            end
            utility.send_mouse_click(x, y)
            record_click(label, x, y)
            log(string.format('%s: CLICKED (%d, %d)', label, x, y))
        else
            log(label .. ': utility.send_mouse_click unavailable')
        end
    else
        log(string.format('%s: SKIP click — coords (%d, %d) are zero. ' ..
            'Open the WarPug menu, hover the button in-game, and press the ' ..
            'configured "Set %s Pos" keybind to capture it.', label, x, y, label))
    end
end

-- ── Main tick ────────────────────────────────────────────────────────────────

function planner.tick()
    if not settings.enabled then
        if state ~= S.IDLE then
            clear_warplan_path()
            reroll_count = 0
            set_state(S.IDLE)
        end
        return
    end

    if not get_local_player() then return end

    -- Preconditions: must be in Temis, no active WarPlans quests.
    -- Check these every tick so we immediately reset if quests appear mid-run
    -- (e.g. the user manually confirmed, or the script lag-confirmed a path).
    if state ~= S.IDLE then
        local temis  = in_temis()
        local quests = has_warplan_quests()
        if not temis or quests then
            log(string.format(
                'preconditions lost (in_temis=%s no_quests=%s) — resetting to IDLE',
                tostring(temis), tostring(not quests)))
            -- Don't deselect nodes for CONFIRMING/DONE_WAIT: the plan is already
            -- submitted to the server; calling deselect_last() at this point
            -- could interfere with the confirmed plan state.
            if state ~= S.CONFIRMING and state ~= S.DONE_WAIT then
                clear_warplan_path()
            end
            reroll_count   = 0
            reroll_pending = false
            set_state(S.IDLE)
            return
        end
    end

    -- ── IDLE ─────────────────────────────────────────────────────────────────
    if state == S.IDLE then
        if not in_temis() or has_warplan_quests() then return end

        if warplan_api_ready() then
            log('warplan panel already open — skipping vendor approach, going to FIND_PATH')
            set_state(S.FIND_PATH)
        elseif settings.table_actor_name ~= '' then
            log('warplan panel not open — approaching vendor "' .. settings.table_actor_name .. '"')
            set_state(S.APPROACH_TABLE)
        else
            -- No actor name configured and panel not ready: can't do anything
            if (now() - last_diag) >= DIAG_INTERVAL then
                log('waiting: warplan panel not ready and table_actor_name not set in core/settings.lua')
                last_diag = now()
            end
        end
        return
    end

    -- ── APPROACH_TABLE ────────────────────────────────────────────────────────
    if state == S.APPROACH_TABLE then
        local actor = find_table_actor()
        if not actor then
            if (now() - last_diag) >= DIAG_INTERVAL then
                log('war plan table actor "' .. settings.table_actor_name .. '" not found nearby')
                last_diag = now()
            end
            return
        end
        local pos = actor:get_position()
        local pp  = get_player_position()
        if not pp then return end
        if pp:dist_to(pos) <= INTERACT_DIST then
            set_state(S.INTERACT_TABLE)
        else
            pathfinder.request_move(pos)
        end
        return
    end

    -- ── INTERACT_TABLE ────────────────────────────────────────────────────────
    if state == S.INTERACT_TABLE then
        local actor = find_table_actor()
        if not actor then
            log('table actor lost during interact — returning to IDLE')
            set_state(S.IDLE)
            return
        end
        local pp  = get_player_position()
        local pos = actor:get_position()
        if pp and pp:dist_to(pos) > INTERACT_DIST then
            set_state(S.APPROACH_TABLE)
            return
        end
        if (now() - last_interact) >= INTERACT_COOLDOWN then
            interact_vendor(actor)
            last_interact = now()
            log('interact_vendor: war plan table — waiting for panel')
            set_state(S.WAIT_READY)
        end
        return
    end

    -- ── WAIT_READY ────────────────────────────────────────────────────────────
    if state == S.WAIT_READY then
        if warplan_api_ready() then
            if reroll_pending then
                log('panel open — firing reroll clicks')
                set_state(S.REROLL_CLICK1)
            else
                set_state(S.FIND_PATH)
            end
            return
        end
        if (now() - state_entered) >= WAIT_READY_TIMEOUT then
            log('timeout waiting for war plan panel to open — retrying table approach')
            set_state(S.APPROACH_TABLE)
        end
        return
    end

    -- ── FIND_PATH ─────────────────────────────────────────────────────────────
    if state == S.FIND_PATH then
        if not warplan_api_ready() then
            log('warplan panel closed in FIND_PATH — re-approaching table')
            set_state(S.APPROACH_TABLE)
            return
        end

        -- Clear any stale selection before searching
        clear_warplan_path()

        local ok_r, required = pcall(function() return warplan.required_picks() end)
        if not ok_r then
            log('warplan.required_picks() error: ' .. tostring(required))
            set_state(S.IDLE)
            return
        end

        log(string.format('searching: required=%d', required))

        -- Dump every top-level node name so we can see what the tree contains.
        local ok_sel, top_nodes = pcall(function() return warplan.get_selectable_now() end)
        if ok_sel and type(top_nodes) == 'table' then
            local parts = {}
            for _, id in ipairs(top_nodes) do
                local ok_n, nm = pcall(function() return warplan.node_name(id) end)
                local activity = (ok_n and type(nm) == 'string' and nm ~= '') and nm or '?'
                local tag = BLOCKED[activity] and ' [BLOCKED]' or ''
                parts[#parts + 1] = string.format('%d:%s%s', id, activity, tag)
            end
            log('top-level nodes (' .. #parts .. '): ' .. (#parts > 0 and table.concat(parts, ', ') or 'none'))
        else
            log('get_selectable_now() failed: ' .. tostring(top_nodes))
        end

        if required == 0 then
            -- Nothing to pick; confirm immediately
            log('required_picks=0 — confirming immediately')
            pcall(function() warplan.confirm() end)
            reroll_count = 0
            set_state(S.DONE_WAIT)
            return
        end

        local ok_dfs, found = pcall(dfs, required)
        if not ok_dfs then
            log('DFS error: ' .. tostring(found))
            set_state(S.IDLE)
            return
        end

        if found then
            reroll_pending = false
            -- Path is now fully selected in the warplan API; log it and confirm
            local ok_p, path = pcall(function() return warplan.selected_path() end)
            if ok_p and type(path) == 'table' then
                local parts = {}
                for _, id in ipairs(path) do
                    local ok_n, nm = pcall(function() return warplan.node_name(id) end)
                    parts[#parts + 1] = string.format('%d(%s)',
                        id, (ok_n and nm ~= '') and nm or '?')
                end
                log('valid path found: ' .. table.concat(parts, ' -> '))
            end
            set_state(S.CONFIRMING)
        else
            log(string.format('no nightmare-free path found (reroll attempt %d/%d)',
                reroll_count + 1, MAX_REROLLS))
            if reroll_count >= MAX_REROLLS then
                log('max rerolls reached — stopping. Verify reroll click coordinates.')
                reroll_count   = 0
                reroll_pending = false
                set_state(S.IDLE)
            else
                reroll_pending = true
                log('approaching vendor to open panel for reroll')
                set_state(S.APPROACH_TABLE)
            end
        end
        return
    end

    -- ── CONFIRMING ────────────────────────────────────────────────────────────
    if state == S.CONFIRMING then
        if not warplan_api_ready() then
            log('warplan panel closed in CONFIRMING — re-approaching')
            set_state(S.APPROACH_TABLE)
            return
        end
        local ok_c, complete = pcall(function() return warplan.is_complete() end)
        if not ok_c or not complete then
            local sel = warplan.selected_count()
            local req = warplan.required_picks()
            log(string.format('path incomplete (%d/%d) — re-running search', sel, req))
            set_state(S.FIND_PATH)
            return
        end
        local ok_conf, err = pcall(function() warplan.confirm() end)
        if not ok_conf then
            log('warplan.confirm() error: ' .. tostring(err))
            set_state(S.IDLE)
            return
        end
        log('war plan confirmed')
        reroll_count   = 0
        reroll_pending = false
        set_state(S.DONE_WAIT)
        return
    end

    -- ── DONE_WAIT ─────────────────────────────────────────────────────────────
    -- Hold here until war plan quests actually appear. This prevents re-entering
    -- FIND_PATH and double-confirming if the server is slow to apply the plan.
    -- The precondition check above handles the normal path (quests appear →
    -- that block fires no_quests=false → IDLE). This block is only reached
    -- when quests haven't appeared yet within the tick; we just keep waiting.
    -- Fall back to IDLE after DONE_WAIT_TIMEOUT in case the server rejected
    -- the confirmation silently (e.g. panel wasn't actually interactive).
    if state == S.DONE_WAIT then
        if (now() - state_entered) >= DONE_WAIT_TIMEOUT then
            log('timeout waiting for war plan quests to appear after confirm — ' ..
                'server may have rejected the plan. Returning to IDLE.')
            set_state(S.IDLE)
        end
        return
    end

    -- ── REROLL_CLICK1 ─────────────────────────────────────────────────────────
    if state == S.REROLL_CLICK1 then
        reroll_count = reroll_count + 1
        do_click(settings.reroll_click_x, settings.reroll_click_y, 'Reroll')
        set_state(S.REROLL_WAIT1)
        return
    end

    -- ── REROLL_WAIT1 ──────────────────────────────────────────────────────────
    if state == S.REROLL_WAIT1 then
        if (now() - state_entered) >= REROLL_CLICK1_DELAY then
            set_state(S.REROLL_CLICK2)
        end
        return
    end

    -- ── REROLL_CLICK2 ─────────────────────────────────────────────────────────
    if state == S.REROLL_CLICK2 then
        do_click(settings.reroll_confirm_x, settings.reroll_confirm_y, 'RerollConfirm')
        set_state(S.REROLL_WAIT2)
        return
    end

    -- ── REROLL_WAIT2 ──────────────────────────────────────────────────────────
    if state == S.REROLL_WAIT2 then
        if (now() - state_entered) >= REROLL_SETTLE_DELAY then
            reroll_pending = false
            if warplan_api_ready() then
                set_state(S.FIND_PATH)
            else
                -- Panel closed after confirm; re-open via vendor interact
                log('panel closed after reroll confirm — re-approaching vendor')
                set_state(S.APPROACH_TABLE)
            end
        end
        return
    end
end

function planner.get_status_line()
    if not settings.enabled then return nil end
    if reroll_count > 0 then
        return string.format('WarPug: %s (reroll %d/%d)', state, reroll_count, MAX_REROLLS)
    end
    return 'WarPug: ' .. state
end

-- Public wrapper around the internal do_click. Used by main.lua's test
-- sequencer so a test fire goes through the exact same path (mouse_move +
-- mouse_click + record_click) the live REROLL_CLICK1/2 states use, including
-- the yellow fading-circle overlay.
function planner.fire_click(x, y, label)
    do_click(x, y, label)
end

return planner
