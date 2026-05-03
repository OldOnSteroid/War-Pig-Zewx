local plugin_label = 'alfred_the_butler'

local utils = require 'core.utils'
local settings = require 'core.settings'
local tracker = require 'core.tracker'
local explorerlite = require 'core.explorerlite'
local base_task = require 'tasks.base'

local task = base_task.new_task()
local status_enum = {
    IDLE = 'Idle',
    EXECUTE = 'Keeping item in stash',
    MOVING = 'Moving to stash',
    INTERACTING = 'Interacting with stash',
    RESETTING = 'Re-trying stash',
    FAILED = 'Failed to stash'
}

local debounce_time = nil
local debounce_timeout = 1
local stash_item_count = -1
local failed_interaction_count = -1
local last_interaction_item_count = -1

-- ===== right-click stash fallback (mirrors WonderCity tribute click pattern) =====
-- D4's right-click "use item" action checks the in-game cursor position, not
-- the click event coordinates. We MUST move the cursor onto the slot first,
-- then send the right-click. With the stash UI open, right-click on an
-- inventory item sends it to the stash.
local INVENTORY_COLS         = 11
local INV_CATEGORY_INVENTORY = 0  -- regular gear inventory grid
local FALLBACK_TRIGGER_NO_PROGRESS_CALLS = 3   -- arm fallback after this many execute() calls with no inventory change
local FALLBACK_HOVER_SETTLE  = 0.20
local FALLBACK_CLICK_DELAY   = 0.50

local fallback = {
    active           = false,
    step             = 'pick',     -- 'pick' | 'hover' | 'wait'
    step_time        = 0,
    target_pos       = nil,
    target_sno       = nil,
    last_inv_count   = nil,
    no_progress_calls = 0,
}

local function reset_fallback(reason)
    if fallback.active or fallback.no_progress_calls > 0 then
        if reason then console.print('[alfred:stash] fallback reset (' .. reason .. ')') end
    end
    fallback.active           = false
    fallback.step             = 'pick'
    fallback.step_time        = 0
    fallback.target_pos       = nil
    fallback.target_sno       = nil
    fallback.last_inv_count   = nil
    fallback.no_progress_calls = 0
end

local function slot_screen_pos(slot_index)
    local col = slot_index % INVENTORY_COLS
    local row = math.floor(slot_index / INVENTORY_COLS)
    return settings.inventory_slot_0_x + col * settings.inventory_cell_size_x,
           settings.inventory_slot_0_y + row * settings.inventory_cell_size_y
end

local function should_stash_item(item)
    if not item then return false end
    local is_sell    = utils.is_salvage_or_sell(item, utils.item_enum['SELL'])
    local is_salvage = utils.is_salvage_or_sell(item, utils.item_enum['SALVAGE'])
    local is_cache   = utils.get_item_type(item) == 'cache'
    local skip_cache_now = settings.skip_cache and is_cache
    return not is_sell and not is_salvage and not skip_cache_now
end

-- ===== debug logging =====
local DEBUG = true
local function dbg(msg)
    if DEBUG then console.print('[alfred:stash] ' .. tostring(msg)) end
end
local last_should_block_reason = nil
local last_is_done_signature = nil
local last_vendor_screen_state = nil
local last_logged_inv_count = -1
-- ==========================

local function update_last_interaction_time()
    local local_player = get_local_player()
    local item_count = #local_player:get_inventory_items() +
        #local_player:get_consumable_items() +
        #local_player:get_dungeon_key_items() +
        #local_player:get_socketable_items()

    if item_count == last_interaction_item_count then
        failed_interaction_count = failed_interaction_count + 1
    else
        failed_interaction_count = -1
    end
    if failed_interaction_count < 10 then
        task.last_interaction = get_time_since_inject()
    end
    last_interaction_item_count = item_count
end

local extension = {}
function extension.get_npc()
    return utils.get_npc(utils.npc_enum['STASH'])
end
function extension.move()
    local npc_location = utils.compute_move_target(utils.get_npc_location('STASH'))
    dbg(string.format('move() -> target=(%.1f,%.1f,%.1f) batmobile=%s',
        npc_location:x(), npc_location:y(), npc_location:z(),
        tostring(BatmobilePlugin ~= nil)))
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, npc_location)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(npc_location)
        explorerlite:move_to_target()
    end
end
function extension.interact()
    local npc = extension.get_npc()
    if npc then
        dbg(string.format('interact() npc=%s dist=%.2f', tostring(npc:get_skin_name()), utils.distance_to(npc)))
        interact_vendor(npc)
    else
        dbg('interact() no NPC found in actors_manager')
    end
end
-- ── right-click stash fallback step machine ─────────────────────────────────
-- Runs one logical step per execute() call (matching the existing 1s debounce).
-- Picks the next stashable item, hovers its slot, waits, sends right-click,
-- then loops.
local function run_fallback_step(local_player, items)
    local now = get_time_since_inject()

    if fallback.step == 'pick' then
        local next_item
        for _, item in pairs(items) do
            if should_stash_item(item) then next_item = item; break end
        end
        if not next_item then
            dbg('fallback: no remaining stashable items in inventory')
            return
        end
        local ok, slot = pcall(function()
            return local_player:get_item_slot_index(next_item, INV_CATEGORY_INVENTORY)
        end)
        if not ok or slot == nil or slot < 0 then
            dbg(string.format('fallback: skipping item sno=%s — get_item_slot_index returned %s',
                tostring(next_item:get_sno_id()), tostring(slot)))
            -- Move on next pulse to avoid spinning on the same bad item
            fallback.step      = 'wait'
            fallback.step_time = now
            return
        end
        local sx, sy = slot_screen_pos(slot)
        dbg(string.format('fallback hover sno=%s slot=%d screen=(%d,%d)',
            tostring(next_item:get_sno_id()), slot, sx, sy))
        utility.send_mouse_move(sx, sy)
        fallback.target_pos = { x = sx, y = sy }
        fallback.target_sno = next_item:get_sno_id()
        fallback.step       = 'hover'
        fallback.step_time  = now
        update_last_interaction_time()
        return
    end

    if fallback.step == 'hover' then
        if now - fallback.step_time < FALLBACK_HOVER_SETTLE then return end
        local p = fallback.target_pos
        if p then
            dbg(string.format('fallback right-click sno=%s screen=(%d,%d)',
                tostring(fallback.target_sno), p.x, p.y))
            utility.send_mouse_right_click(p.x, p.y)
        end
        fallback.step      = 'wait'
        fallback.step_time = now
        update_last_interaction_time()
        return
    end

    if fallback.step == 'wait' then
        if now - fallback.step_time < FALLBACK_CLICK_DELAY then return end
        fallback.step = 'pick'
        return
    end
end

function extension.execute()
    local local_player = get_local_player()
    if not local_player then dbg('execute() no local_player'); return end
    if debounce_time ~= nil and debounce_time + debounce_timeout > get_time_since_inject() then return end
    debounce_time = get_time_since_inject()
    tracker.last_task = task.name

    local moved = 0
    local skipped_sell = 0
    local skipped_salvage = 0
    local skipped_cache = 0
    local items = local_player:get_inventory_items()
    local total_inv = #items
    if total_inv ~= last_logged_inv_count then
        dbg(string.format('execute() entered — inv=%d stash_count=%d flags{boss=%s keys=%s sigils=%s socket=%s} skip_cache=%s',
            total_inv, tracker.stash_count,
            tostring(tracker.stash_boss_materials), tostring(tracker.stash_keys),
            tostring(tracker.stash_sigils), tostring(tracker.stash_socketables),
            tostring(settings.skip_cache)))
        last_logged_inv_count = total_inv
    end

    -- Track inventory progress to decide whether the primary stash path is
    -- making forward progress.  When it stalls for FALLBACK_TRIGGER_NO_PROGRESS_CALLS
    -- consecutive execute() pulses and the toggle is on, switch to the
    -- right-click fallback flow.
    if settings.stash_right_click_fallback then
        if fallback.last_inv_count ~= nil and total_inv == fallback.last_inv_count then
            fallback.no_progress_calls = fallback.no_progress_calls + 1
            if not fallback.active and
                fallback.no_progress_calls >= FALLBACK_TRIGGER_NO_PROGRESS_CALLS
            then
                fallback.active = true
                fallback.step   = 'pick'
                dbg(string.format('move_item_to_stash made no progress for %d calls — switching to right-click fallback',
                    fallback.no_progress_calls))
            end
        else
            -- inventory shrank; primary path is working again
            if fallback.active then
                dbg('inventory progressed — leaving fallback mode')
            end
            fallback.active           = false
            fallback.no_progress_calls = 0
            fallback.step             = 'pick'
        end
        fallback.last_inv_count = total_inv

        if fallback.active then
            run_fallback_step(local_player, items)
            return
        end
    end

    for _,item in pairs(items) do
        if item then
            local is_sell = utils.is_salvage_or_sell(item,utils.item_enum['SELL'])
            local is_salvage = utils.is_salvage_or_sell(item,utils.item_enum['SALVAGE'])
            local is_cache = utils.get_item_type(item) == 'cache'
            local skip_cache_now = settings.skip_cache and is_cache
            if not is_sell and not is_salvage and not skip_cache_now then
                local name = (item.get_display_name and item:get_display_name()) or '?'
                local locked = (item.is_locked and item:is_locked()) or false
                local real_vendor_open = false
                if loot_manager and loot_manager.is_in_vendor_screen then
                    local ok, val = pcall(function() return loot_manager:is_in_vendor_screen() end)
                    real_vendor_open = ok and val or false
                end
                local move_ret = loot_manager.move_item_to_stash(item)
                dbg(string.format('move_item_to_stash: sno=%s name=%s locked=%s real_vendor_open=%s ret=%s',
                    tostring(item:get_sno_id()), tostring(name), tostring(locked),
                    tostring(real_vendor_open), tostring(move_ret)))
                update_last_interaction_time()
                moved = moved + 1
            else
                if is_sell then skipped_sell = skipped_sell + 1
                elseif is_salvage then skipped_salvage = skipped_salvage + 1
                elseif skip_cache_now then skipped_cache = skipped_cache + 1 end
            end
        end
        debounce_time = get_time_since_inject()
    end
    if total_inv > 0 then
        dbg(string.format('inventory pass: moved=%d skip_sell=%d skip_salvage=%d skip_cache=%d', moved, skipped_sell, skipped_salvage, skipped_cache))
    end

    local restock_items = utils.get_restock_items_from_tracker()
    if tracker.stash_boss_materials then
        local consumeable_items = local_player:get_consumable_items()
        local boss_moved, boss_seen = 0, 0
        for _,item in pairs(consumeable_items) do
            if restock_items[item:get_sno_id()] ~= nil then
                boss_seen = boss_seen + 1
                local current = restock_items[item:get_sno_id()]
                if current.count - item:get_stack_count() >= current.max or current.max < current.min then
                    dbg(string.format('moving boss-mat: sno=%s count=%d stack=%d max=%d min=%d',
                        tostring(item:get_sno_id()), current.count, item:get_stack_count(), current.max, current.min))
                    loot_manager.move_item_to_stash(item)
                    update_last_interaction_time()
                    boss_moved = boss_moved + 1
                end
            end
            debounce_time = get_time_since_inject()
        end
        if boss_seen > 0 then dbg(string.format('boss-mats pass: moved=%d/%d tracked', boss_moved, boss_seen)) end
    end
    if tracker.stash_keys then
        local key_items = local_player:get_dungeon_key_items()
        local key_moved, key_seen = 0, 0
        for _,item in pairs(key_items) do
            if restock_items[item:get_sno_id()] ~= nil then
                key_seen = key_seen + 1
                local current = restock_items[item:get_sno_id()]
                if current.count - item:get_stack_count() >= current.max or current.max < current.min then
                    dbg(string.format('moving key: sno=%s count=%d stack=%d max=%d min=%d',
                        tostring(item:get_sno_id()), current.count, item:get_stack_count(), current.max, current.min))
                    loot_manager.move_item_to_stash(item)
                    update_last_interaction_time()
                    key_moved = key_moved + 1
                end
            end
            debounce_time = get_time_since_inject()
        end
        if key_seen > 0 then dbg(string.format('keys pass: moved=%d/%d tracked', key_moved, key_seen)) end
        if tracker.stash_sigils then
            local items = local_player:get_dungeon_key_items()
            local sig_moved = 0
            for _, item in pairs(items) do
                local name = item:get_display_name()
                if item:is_locked() and string.lower(name):match('sigil') then
                    dbg(string.format('moving sigil: name=%s', tostring(name)))
                    loot_manager.move_item_to_stash(item)
                    update_last_interaction_time()
                    sig_moved = sig_moved + 1
                end
            end
            if sig_moved > 0 then dbg(string.format('sigils pass: moved=%d', sig_moved)) end
        end
    end
    if tracker.stash_socketables then
        local socket_items = local_player:get_socketable_items()
        local sock_moved = 0
        for _,item in pairs(socket_items) do
            loot_manager.move_item_to_stash(item)
            update_last_interaction_time()
            sock_moved = sock_moved + 1
        end
        if sock_moved > 0 then dbg(string.format('socketables pass: moved=%d', sock_moved)) end
        debounce_time = get_time_since_inject()
    end

end
function extension.reset()
    local local_player = get_local_player()
    if not local_player then return end
    -- Walking away from the stash invalidates any pending fallback hover/click
    -- since the inventory grid coordinates only make sense while the stash UI
    -- is visible. Clear state so the next stash attempt re-evaluates progress.
    reset_fallback('reset')
    local new_position = vec3:new(2574.0361328125, -486.248046875, 31.5029296875)
    if task.reset_state == status_enum['MOVING'] then
        new_position = vec3:new(2578.1103515625, -482.2646484375, 31.5029296875)
    end
    if BatmobilePlugin then
        BatmobilePlugin.set_target(plugin_label, new_position)
        BatmobilePlugin.move(plugin_label)
    else
        explorerlite:set_custom_target(new_position)
        explorerlite:move_to_target()
    end
end
function extension.is_done()
    if task.check_status(status_enum['EXECUTE']) and
        #get_local_player():get_stash_items() == 300
    then
        dbg('is_done() -> true (stash full at 300 while EXECUTE)')
        return true
    end
    local material_stashed = true
    for _,item_data in pairs(tracker.restock_items) do
        if (item_data.item_type == 'consumables' and
            (item_data.count - 99 >= item_data.max or
            item_data.max < item_data.min and item_data.count > 0) and
            tracker.stash_boss_materials) or
            (item_data.item_type == 'key' and
            (item_data.count - 99 >= item_data.max or
            item_data.max < item_data.min and item_data.count > 0) and
            tracker.stash_keys)
        then
            material_stashed = false
        end
    end
    if material_stashed and #get_local_player():get_stash_items() > 0 then
        local restock_items = utils.get_restock_items_from_tracker()
        local stash_items = get_local_player():get_stash_items()
        for key,_ in pairs(restock_items) do
            restock_items[key].stash = 0
        end
        for _,item in pairs(stash_items) do
            if restock_items[item:get_sno_id()] ~= nil then
                local item_count = item:get_stack_count()
                if item_count == 0 then
                    item_count = 1
                end
                restock_items[item:get_sno_id()].stash = restock_items[item:get_sno_id()].stash + item_count
            end
        end
    end
    local socketable_stashed = true
    if tracker.stash_socketables then
        socketable_stashed = #get_local_player():get_socketable_items() == 0
    end
    local sigils_stashed = true
    if tracker.stash_sigils then
        local items = get_local_player():get_dungeon_key_items()
        for _, item in pairs(items) do
            local name = item:get_display_name()
            if item:is_locked() and string.lower(name):match('sigil') then
                sigils_stashed = false
            end
        end
    end
    local result = (tracker.stash_count == 0) and
        (not tracker.stash_socketables or socketable_stashed) and
        (not tracker.stash_boss_materials or material_stashed) and
        (not tracker.stash_keys or material_stashed) and
        (not tracker.stash_sigils or sigils_stashed)
    local sig = string.format('done=%s sc=%d sock=%s mat=%s sig=%s flags{sock=%s boss=%s keys=%s sig=%s}',
        tostring(result), tracker.stash_count,
        tostring(socketable_stashed), tostring(material_stashed), tostring(sigils_stashed),
        tostring(tracker.stash_socketables), tostring(tracker.stash_boss_materials),
        tostring(tracker.stash_keys), tostring(tracker.stash_sigils))
    if sig ~= last_is_done_signature then
        dbg('is_done() ' .. sig)
        last_is_done_signature = sig
    end
    return result
end
function extension.done()
    dbg('done() called — marking stash_done=true')
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.stash_done = true
    tracker.gamble_paused = false
    stash_item_count = -1
    failed_interaction_count = -1
    last_interaction_item_count = -1
    reset_fallback('done')
end
function extension.failed()
    dbg(string.format('failed() called — retry=%d max=%d failed_interactions=%d',
        task.retry or -1, task.max_retries or -1, failed_interaction_count))
    if BatmobilePlugin then
        BatmobilePlugin.clear_target(plugin_label)
    end
    tracker.stash_failed = true
    tracker.gamble_paused = false
    stash_item_count = -1
    failed_interaction_count = -1
    last_interaction_item_count = -1
    reset_fallback('failed')
end
function extension.is_in_vendor_screen()
    -- Prefer the SDK signal (matches sell/salvage/repair tasks). The legacy
    -- count-based heuristic could never return true on an empty stash, which
    -- is exactly the failure mode the right-click fallback is meant to catch.
    local sdk_open = false
    if loot_manager and loot_manager.is_in_vendor_screen then
        local ok, val = pcall(function() return loot_manager:is_in_vendor_screen() end)
        sdk_open = ok and val == true
    end
    local stash_count = #get_local_player():get_stash_items()
    local count_open  = stash_count > 0 and stash_item_count == stash_count
    local is_open     = sdk_open or count_open
    if is_open ~= last_vendor_screen_state then
        dbg(string.format('is_in_vendor_screen() -> %s (sdk=%s count=%s stash_items=%d prev_seen=%d)',
            tostring(is_open), tostring(sdk_open), tostring(count_open), stash_count, stash_item_count))
        last_vendor_screen_state = is_open
    end
    stash_item_count = stash_count
    return is_open
end

task.name = 'stash'
task.extension = extension
task.status_enum = status_enum

task.shouldExecute = function ()
    if tracker.trigger_tasks == false then
        task.retry = 0
    end
    if utils.is_in_town() and
        tracker.trigger_tasks and
        not tracker.stash_failed and
        not tracker.stash_done and
        (tracker.sell_done or tracker.sell_failed) and
        (tracker.gamble_done or tracker.gamble_failed or tracker.gamble_paused) and
        (tracker.salvage_done or tracker.salvage_failed)
    then
        if last_should_block_reason ~= 'OK' then
            dbg('shouldExecute() -> true (gates passed, running stash task)')
            last_should_block_reason = 'OK'
        end
        if task.check_status(task.status_enum['FAILED']) then
            task.set_status(task.status_enum['IDLE'])
        end
        return true
    end
    -- Determine which gate blocked, log only on change so we don't spam
    local reason
    if not utils.is_in_town() then reason = 'not_in_town'
    elseif not tracker.trigger_tasks then reason = 'trigger_tasks=false'
    elseif tracker.stash_failed then reason = 'stash_failed=true'
    elseif tracker.stash_done then reason = 'stash_done=true'
    elseif not (tracker.sell_done or tracker.sell_failed) then reason = 'sell not done/failed'
    elseif not (tracker.gamble_done or tracker.gamble_failed or tracker.gamble_paused) then reason = 'gamble not done/failed/paused'
    elseif not (tracker.salvage_done or tracker.salvage_failed) then reason = 'salvage not done/failed'
    else reason = 'unknown' end
    if reason ~= last_should_block_reason then
        dbg('shouldExecute() -> false, blocked by: ' .. reason)
        last_should_block_reason = reason
    end
    return false
end

return task