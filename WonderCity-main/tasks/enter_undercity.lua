local plugin_label = 'wonder_city'

local gui = require 'gui'
local utils = require "core.utils"
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local path = require 'data.path'

local status_enum = {
    IDLE     = 'idle',
    WALKING  = 'walking to ',
    OPENING  = 'opening undercity',
    ENTERING = 'entering undercity',
    WAITING  = 'waiting ',
}

local CLICK_DELAY = 2.0  -- seconds to wait after every click action

-- Brazier interact retry watchdog. The walk branch stops at distance <= 2,
-- but the game's actual interaction range can be tighter than that. If
-- interact_object() is spammed with no vendor screen response, lower the
-- close-enough threshold so the next tick walks closer instead of looping.
local INTERACT_RETRY_TIMEOUT       = 3.0
local INTERACT_THRESHOLD_DEFAULT   = 2.0
local INTERACT_THRESHOLD_STEP      = 0.4
local INTERACT_THRESHOLD_FLOOR     = 0.6

-- Steps shared by both flows. Bargain flow inserts extra steps between TRIBUTE_WAIT and OPEN_PORTAL.
local STEP = {
    TRIBUTE             = 1,
    TRIBUTE_HOVER       = 13,  -- cursor moved to slot, waiting brief settle before right-click
    TRIBUTE_WAIT        = 2,
    BARGAIN_OPEN        = 3,   -- bargain flow only: click bargain opener
    BARGAIN_OPEN_WAIT   = 4,
    BARGAIN_SCROLL      = 5,   -- bargain flow only: click scroll bar (if needed)
    BARGAIN_SCROLL_WAIT = 6,
    BARGAIN_SELECT      = 7,   -- bargain flow only: click bargain option
    BARGAIN_SELECT_WAIT = 8,
    OPEN_PORTAL         = 9,
    OPEN_PORTAL_WAIT    = 10,
    ACCEPT              = 11,
    ACCEPT_WAIT         = 12,  -- waiting for portal actor to appear; timeout retries next bargain
}

-- D4 dungeon-keys inventory is an 11×3 grid (used for the screen-position
-- math). The second arg to lp:get_item_slot_index is a separate value: the
-- inventory CATEGORY ID for Dungeon Keys (4). Don't conflate them — one is
-- a UI grid dimension, the other is an API category enum.
local INVENTORY_COLS         = 11
local INVENTORY_ROWS         = 3
local INV_CATEGORY_DUNGEON_KEYS = 4

local task = {
    name             = 'enter_undercity',
    status           = status_enum['IDLE'],
    interacted       = false,
    debounce_time    = -1,
    step             = 0,
    step_time        = -1,
    bargain_idx      = 0,    -- current index into sorted bargain list
    bargain_walk_away = false,
    interact_threshold  = INTERACT_THRESHOLD_DEFAULT,
    interact_started_at = -1,
    brazier_missing_logged = false,
}

local get_sorted_bargains = function ()
    local result = {}
    for i, bargain in ipairs(gui.bargains_data) do
        local p = settings.bargain_priorities[i]
        if p and p > 0 then
            result[#result + 1] = {priority = p, bargain = bargain}
        end
    end
    table.sort(result, function(a, b) return a.priority < b.priority end)
    return result
end

local reset_state = function ()
    task.step      = 0
    task.step_time = -1
    task.bargain_idx = 0
end

local slot_screen_pos = function (slot_index)
    local col = slot_index % INVENTORY_COLS
    local row = math.floor(slot_index / INVENTORY_COLS)
    return settings.inventory_slot_0_x + col * settings.inventory_cell_size_x,
           settings.inventory_slot_0_y + row * settings.inventory_cell_size_y
end

-- Exported on the task table so main.lua can render the full inventory
-- grid as crosshairs for calibration.
local function get_grid_dims() return INVENTORY_COLS, INVENTORY_ROWS end
local function get_slot_pos(i) return slot_screen_pos(i) end

-- Recent clicks log (for the on-screen "where did the bot just click?" overlay).
-- Keeps up to 8 entries, each fades out after CLICK_FADE seconds.
local CLICK_FADE = 6.0
local recent_clicks = {}

local function record_click(label, sx, sy, kind)
    recent_clicks[#recent_clicks + 1] = {
        label = label, x = sx, y = sy, kind = kind,
        t = get_time_since_inject(),
    }
    -- Trim oldest if list grows
    while #recent_clicks > 8 do table.remove(recent_clicks, 1) end
end

local function get_recent_clicks()
    -- Drop expired entries each query
    local now = get_time_since_inject()
    while recent_clicks[1] and (now - recent_clicks[1].t) > CLICK_FADE do
        table.remove(recent_clicks, 1)
    end
    return recent_clicks, CLICK_FADE
end

-- Throttled diagnostic for pick_tribute. Logs at most once every 5s while
-- nothing is selected, and a one-shot dump on the first call.
local _last_pick_log = -999
local _pick_log_interval = 5.0

local function pick_log(msg)
    console.print('[WonderCity:tribute] ' .. msg)
end

local pick_tribute = function ()
    local now = get_time_since_inject()
    local should_log = (now - _last_pick_log) >= _pick_log_interval

    local lp = get_local_player()
    if not lp then
        if should_log then pick_log('skip: get_local_player() returned nil'); _last_pick_log = now end
        return
    end

    local key_items = lp:get_dungeon_key_items()
    if not key_items or #key_items == 0 then
        if should_log then pick_log('skip: no dungeon_key_items in inventory'); _last_pick_log = now end
        return
    end

    -- Count configured priorities (so we know if the user actually set any)
    local prio_count = 0
    for _, _ in pairs(settings.tribute_priorities) do prio_count = prio_count + 1 end

    local best_item, best_priority = nil, math.huge
    local matches = 0
    for _, item in ipairs(key_items) do
        local sno = item:get_sno_id()
        local p   = settings.tribute_priorities[sno]
        if p and p > 0 then
            matches = matches + 1
            if p < best_priority then
                best_item = item
                best_priority = p
            end
        end
    end

    local picked = best_item or key_items[1]
    if should_log then
        pick_log(string.format(
            'inventory=%d  configured_priorities=%d  matched=%d  picked=%s (sno=%s priority=%s)',
            #key_items, prio_count, matches,
            best_item and 'priority match' or 'fallback first slot',
            tostring(picked and picked:get_sno_id()),
            best_priority == math.huge and 'n/a' or tostring(best_priority)))
        -- Dump the inventory contents the first time only (or whenever we
        -- log the diagnostic) so the user can correlate sno_ids.
        for i, item in ipairs(key_items) do
            local sno = item:get_sno_id()
            local p   = settings.tribute_priorities[sno] or 0
            pick_log(string.format('  slot=%d sno=%s priority=%s',
                i - 1, tostring(sno), p > 0 and tostring(p) or 'unset'))
        end
        _last_pick_log = now
    end

    return picked, lp
end

-- ── Step machine ─────────────────────────────────────────────────────────────
local run_steps = function ()
    local now = get_time_since_inject()

    -- Initialise on first call after interact
    if task.step == 0 then
        task.step = STEP.TRIBUTE
    end

    -- Helper: waiting for delay after a click
    local function waiting(label)
        if now < task.step_time + CLICK_DELAY then
            task.status = status_enum['WAITING'] .. label
            return true
        end
        return false
    end

    -- ── Shared: tribute ───────────────────────────────────────────────────
    -- D4's right-click "use item" action checks the in-game cursor position,
    -- not the click event coordinates. So we MUST move the cursor onto the
    -- slot first, then right-click. Sending right-click alone makes the game
    -- evaluate the action against whatever the cursor was over (often a
    -- world actor like an NPC), and the inventory item is never used.
    if task.step == STEP.TRIBUTE then
        local item, lp = pick_tribute()
        if item and lp then
            local slot = lp:get_item_slot_index(item, INV_CATEGORY_DUNGEON_KEYS)
            local sx, sy = slot_screen_pos(slot)
            pick_log(string.format(
                'hover sno=%s slot=%d screen=(%d,%d)',
                tostring(item:get_sno_id()), slot, sx, sy))
            utility.send_mouse_move(sx, sy)
            task.tribute_click_pos = { x = sx, y = sy }
            task.step = STEP.TRIBUTE_HOVER
            task.step_time = now
            task.status = status_enum['WAITING'] .. 'hover tribute'
        else
            task.status = status_enum['WAITING'] .. 'tribute (no item available)'
        end
        return
    end

    -- Wait for the cursor to settle on the slot, then send the right-click.
    if task.step == STEP.TRIBUTE_HOVER then
        if now < task.step_time + 0.2 then
            task.status = status_enum['WAITING'] .. 'hover settle'
            return
        end
        local p = task.tribute_click_pos
        if p then
            pick_log(string.format('right-click tribute screen=(%d,%d)', p.x, p.y))
            utility.send_mouse_right_click(p.x, p.y)
            record_click('TRIBUTE', p.x, p.y, 'right')
        end
        task.step = STEP.TRIBUTE_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'tribute'
        return
    end

    if task.step == STEP.TRIBUTE_WAIT then
        if waiting('tribute') then return end
        if settings.enable_bargains then
            task.step = STEP.BARGAIN_OPEN
        else
            task.step = STEP.OPEN_PORTAL
        end
        return
    end

    -- ── Bargain only ──────────────────────────────────────────────────────
    if task.step == STEP.BARGAIN_OPEN then
        local sorted = get_sorted_bargains()
        task.bargain_idx = task.bargain_idx + 1
        if task.bargain_idx > #sorted then
            task.step = STEP.OPEN_PORTAL
        else
            local cp = settings.bargain_cp['bargain_opener']
            utility.send_mouse_click(cp.x, cp.y)
            task.step = STEP.BARGAIN_OPEN_WAIT
            task.step_time = now
            task.status = status_enum['WAITING'] .. 'bargain menu'
        end
        return
    end

    if task.step == STEP.BARGAIN_OPEN_WAIT then
        if waiting('bargain menu') then return end
        local sorted = get_sorted_bargains()
        local current = sorted[task.bargain_idx]
        if current and current.bargain.needs_scroll then
            task.step = STEP.BARGAIN_SCROLL
        else
            task.step = STEP.BARGAIN_SELECT
        end
        return
    end

    if task.step == STEP.BARGAIN_SCROLL then
        local cp = settings.bargain_cp['scroll_bar']
        utility.send_mouse_click(cp.x, cp.y)
        task.step = STEP.BARGAIN_SCROLL_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'scroll'
        return
    end

    if task.step == STEP.BARGAIN_SCROLL_WAIT then
        if waiting('scroll') then return end
        task.step = STEP.BARGAIN_SELECT
        return
    end

    if task.step == STEP.BARGAIN_SELECT then
        local sorted = get_sorted_bargains()
        local current = sorted[task.bargain_idx]
        if current then
            local cp = settings.bargain_cp[current.bargain.cp_key]
            utility.send_mouse_click(cp.x, cp.y)
            task.status = 'selecting: ' .. current.bargain.name
        end
        task.step = STEP.BARGAIN_SELECT_WAIT
        task.step_time = now
        return
    end

    if task.step == STEP.BARGAIN_SELECT_WAIT then
        if waiting('bargain select') then return end
        task.step = STEP.OPEN_PORTAL
        return
    end

    -- ── Shared: open portal ───────────────────────────────────────────────
    if task.step == STEP.OPEN_PORTAL then
        pick_log(string.format('left-click OPEN_PORTAL screen=(%d,%d)',
            settings.portal_button_x, settings.portal_button_y))
        utility.send_mouse_click(settings.portal_button_x, settings.portal_button_y)
        record_click('OPEN_PORTAL', settings.portal_button_x, settings.portal_button_y, 'left')
        task.step = STEP.OPEN_PORTAL_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'open portal'
        return
    end

    if task.step == STEP.OPEN_PORTAL_WAIT then
        if waiting('open portal') then return end
        task.step = STEP.ACCEPT
        return
    end

    -- ── Shared: accept ────────────────────────────────────────────────────
    if task.step == STEP.ACCEPT then
        pick_log(string.format('left-click ACCEPT screen=(%d,%d)',
            settings.accept_button_x, settings.accept_button_y))
        utility.send_mouse_click(settings.accept_button_x, settings.accept_button_y)
        record_click('ACCEPT', settings.accept_button_x, settings.accept_button_y, 'left')
        task.step = STEP.ACCEPT_WAIT
        task.step_time = now
        task.status = status_enum['WAITING'] .. 'accept'
        return
    end

    if task.step == STEP.ACCEPT_WAIT then
        if waiting('accept') then return end
        if now > task.step_time + CLICK_DELAY + settings.bargain_timeout then
            if settings.enable_bargains then
                task.bargain_walk_away = true
                task.step = STEP.BARGAIN_OPEN
                task.step_time = -1
                task.status = 'bargain failed - walking away'
            else
                task.step = STEP.ACCEPT
            end
        else
            task.status = status_enum['WAITING'] .. 'for portal'
        end
        return
    end
end

-- ── Common obelisk wrapper ────────────────────────────────────────────────────
local open_portal = function (delay)
    task.status = status_enum['OPENING']
    local spirit_brazier = utils.get_spirit_brazier()
    if spirit_brazier == nil or spirit_brazier.get_position == nil then return end

    local now = get_time_since_inject()

    if not loot_manager:is_in_vendor_screen() and not task.interacted then
        if task.interact_started_at < 0 then
            task.interact_started_at = now
            console.print(string.format(
                '[WonderCity:enter] interact spirit_brazier (threshold=%.2f)',
                task.interact_threshold))
        end
        interact_object(spirit_brazier)
        if now - task.interact_started_at > INTERACT_RETRY_TIMEOUT then
            local new_thr = math.max(
                task.interact_threshold - INTERACT_THRESHOLD_STEP,
                INTERACT_THRESHOLD_FLOOR)
            if new_thr ~= task.interact_threshold then
                task.interact_threshold = new_thr
                console.print(string.format(
                    '[WonderCity:enter] vendor screen never opened — tightening close-enough threshold to %.2f',
                    new_thr))
            end
            task.interact_started_at = now
        end
    elseif not task.interacted then
        task.interacted = true
        task.interact_started_at = -1
        task.interact_threshold = INTERACT_THRESHOLD_DEFAULT
        reset_state()
    end

    if loot_manager:is_in_vendor_screen() then
        run_steps()
    elseif delay and task.debounce_time + settings.confirm_delay > get_time_since_inject() then
        task.status = status_enum['WAITING'] .. 'for confirmation'
        return
    else
        task.interacted = false
    end
    task.debounce_time = get_time_since_inject()
end

local enter_portal = function (portal)
    interact_object(portal)
    BatmobilePlugin.reset(plugin_label)
    tracker.undercity_start_time = get_time_since_inject()
    tracker.exit_trigger_time = nil
    tracker.exit_reset = false
    tracker.boss_trigger_time = nil
    tracker.boss_kill_time = nil
    tracker.enticement = {}
    tracker.done = false
    task.status = status_enum['ENTERING']
end

task.shouldExecute = function ()
    return utils.player_in_zone(settings.town_zone)
end

task.Execute = function ()
    local local_player = get_local_player()
    if not local_player then return end
    BatmobilePlugin.pause(plugin_label)

    local player_pos = local_player:get_position()
    local spirit_brazier = utils.get_spirit_brazier()
    local portal = utils.get_entrance_portal()

    -- Walk away from obelisk to reset after a failed bargain
    if task.bargain_walk_away then
        if spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > 10 then
            task.bargain_walk_away = false
            task.interacted = false
        else
            BatmobilePlugin.set_target(plugin_label, path[1])
            BatmobilePlugin.move(plugin_label)
            task.status = 'bargain failed - walking away'
        end
        return
    end

    if portal ~= nil then
        if utils.distance(player_pos, portal) > 2 then
            BatmobilePlugin.set_target(plugin_label, portal)
            BatmobilePlugin.move(plugin_label)
            task.status = status_enum['WALKING'] .. 'portal'
        else
            enter_portal(portal)
        end
    elseif spirit_brazier == nil or utils.distance(player_pos, spirit_brazier) > task.interact_threshold then
        if spirit_brazier ~= nil then
            -- Close-range: skip Batmobile A*. The brazier sits on non-walkable
            -- terrain — A* returns limit_partial, the partial-path watchdog
            -- clears the custom target, the explorer picks a frontier and
            -- drags us off. force_move_raw is a direct move command, no
            -- second-guessing, so we hold position long enough for the
            -- vendor screen to open. Mirrors enter_pit.lua + portal.lua.
            local brazier_pos = spirit_brazier:get_position()
            if utils.distance(player_pos, brazier_pos) <= 7 then
                BatmobilePlugin.clear_target(plugin_label)
                pathfinder.force_move_raw(brazier_pos)
            else
                BatmobilePlugin.set_target(plugin_label, spirit_brazier)
                BatmobilePlugin.move(plugin_label)
            end
            task.status = status_enum['WALKING'] .. 'spirit brazier'
        else
            task.status = status_enum['WAITING'] .. 'for spirit brazier (not found)'
            if not task.brazier_missing_logged then
                console.print('[WonderCity:enter] spirit brazier actor not found in get_all_actors() — check actor name (expected Aubrie_Test_Undercity_Crafter)')
                task.brazier_missing_logged = true
            end
        end
        task.interact_started_at = -1
    elseif not settings.party_enabled then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(false)
    elseif settings.party_mode == 0 then
        BatmobilePlugin.clear_target(plugin_label)
        open_portal(true)
    else
        BatmobilePlugin.clear_target(plugin_label)
        if task.status ~= status_enum['WAITING'] .. 'for portal' and
            settings.use_magoogle_tool and settings.party_enabled and
            settings.party_mode == 1
        then
            -- contact magoogle tool accepting portal
        end
        task.status = status_enum['WAITING'] .. 'for portal'
    end
end

task.get_grid_dims     = get_grid_dims
task.get_slot_pos      = get_slot_pos
task.get_recent_clicks = get_recent_clicks

return task
