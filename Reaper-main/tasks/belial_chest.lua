-- ============================================================
--  Reaper - tasks/belial_chest.lua
--
--  Fires AFTER open_chest.lua has interacted with the physical
--  Belial chest (tracker.belial_chest_interacted = true).
--  Waits 1.5s for the "Choose Reward" dialog to fully render,
--  then clicks the appropriate buttons.
--
--  Pixel coords measured at 1920x1080, scaled to any res.
--
--  Sequence per target page:
--    Page 1 (no scroll):  wait → Modify → wait → Boss → wait → Open
--    Page 2 (must scroll): wait → Modify → wait → Scroll → wait → Boss → wait → Open
--
--  In-game chest menu layout (post game update):
--    Page 1:  Beast, Butcher, Grigoire, Urivar, Varshan, Lord Zir, Andariel
--    Page 2:  Varshan, Lord Zir, Andariel, Astaroth, Bartuc, Duriel, Harbinger
--  The 3 bosses that appear on BOTH pages are routed via page 1 to
--  skip the scroll click.  Astaroth, Bartuc, Duriel, and Harbinger are
--  the only entries that require the scroll path.
--
--  Party retry:
--    After clicking Open, if the chest is still interactable a
--    party member may have reset it.  In that case: step 8 units
--    away, walk back, re-interact, and repeat the full sequence
--    up to MAX_RETRIES times.
-- ============================================================

local settings     = require "core.settings"
local tracker      = require "core.tracker"
local utils        = require "core.utils"
local explorerlite = require "core.explorerlite"

-- -------------------------------------------------------
-- Screen-relative click helper
-- -------------------------------------------------------
local function click(rx, ry)
    local x = math.floor(get_screen_width()  * rx)
    local y = math.floor(get_screen_height() * ry)
    console.print(string.format("[BelialChest] click(%d, %d)", x, y))
    utility.send_mouse_click(x, y)
end

-- ── Click coordinates (pixel ratios @ 1920x1080, scaled to any res) ─────────
--
-- Slot Y-positions for the boss list.  The first six slots reuse the
-- coordinates that were measured for the OLD menu layout (those rows
-- still exist, the bosses occupying them just shifted around in the
-- new game version).  Slot 7 (~y=971) was extrapolated from the
-- ~96px row spacing of slots 1-6.
--
-- !!! TODO: verify slot 7 (y=971) and the page-2 assignments below
-- in-game.  If the visible row pixels shifted vs the old layout,
-- adjust the SLOT_Y values; the page mapping itself (which boss is on
-- which page) was provided by the operator and should be correct.
local SLOT_Y = {
    [1] =  397/1080,  -- (matches old: was 'duriel')
    [2] =  495/1080,  -- (matches old: was 'grigoire')
    [3] =  585/1080,  -- (matches old: was 'harbinger')
    [4] =  683/1080,  -- (matches old: was 'zir')
    [5] =  773/1080,  -- (matches old: was 'beast')
    [6] =  875/1080,  -- (matches old: was 'urivar')
    [7] =  971/1080,  -- TODO: verify (extrapolated)
}
local SLOT_X = 349/1920

-- Per-boss page + slot.  Page 1 = visible without scrolling; page 2 =
-- visible after one Scroll click.  Bosses present on BOTH pages are
-- routed through page 1 to skip the scroll.
local TARGETS = {
    -- Page 1
    beast     = { page = 1, slot = 1 },
    butcher   = { page = 1, slot = 2 },
    grigoire  = { page = 1, slot = 3 },
    urivar    = { page = 1, slot = 4 },
    varshan   = { page = 1, slot = 5 },
    zir       = { page = 1, slot = 6 },
    andariel  = { page = 1, slot = 7 },
    -- Page 2 (must scroll)
    astaroth  = { page = 2, slot = 4 },
    bartuc    = { page = 2, slot = 5 },
    duriel    = { page = 2, slot = 6 },
    harbinger = { page = 2, slot = 7 },
}

local function click_target(boss_id)
    local t = TARGETS[boss_id]
    if not t then
        console.print("[BelialChest] No click mapping for " .. tostring(boss_id))
        return
    end
    click(SLOT_X, SLOT_Y[t.slot])
end

-- Static dialog buttons (Open / Modify / Scroll).  Y-coords carried
-- over from the previous layout -- if these moved in the new game
-- version, update them here.
local C = {
    open   = function() click(349/1920, 956/1080) end,
    modify = function() click(349/1920, 816/1080) end,
    scroll = function() click(629/1920, 858/1080) end,
}

-- -------------------------------------------------------
-- Zone / chest helpers
-- -------------------------------------------------------
local function in_belial_zone()
    return get_current_world():get_current_zone_name():match("Boss_Kehj_Belial") ~= nil
end

local function find_belial_chest()
    local actors = actors_manager.get_all_actors()
    if type(actors) ~= "table" then return nil end
    for _, a in pairs(actors) do
        local n = a:get_skin_name()
        if type(n) == "string" and n:find("^Boss_WT_Belial_") then
            local ok, inter = pcall(function() return a:is_interactable() end)
            if ok and inter then return a end
        end
    end
    return nil
end

-- -------------------------------------------------------
-- Boss selection
-- -------------------------------------------------------
local rr_index = 0

local function pick_target()
    local cfg = settings.belial_chest
    if not cfg then return "duriel" end
    local mode = cfg.selection_mode or "manual"
    local pool = cfg.pool or {}
    if mode == "roundrobin" and #pool > 0 then
        rr_index = (rr_index % #pool) + 1
        return pool[rr_index]
    elseif mode == "random" and #pool > 0 then
        return pool[math.random(#pool)]
    else
        return cfg.target_boss or "duriel"
    end
end

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE      = "IDLE",
    WAIT      = "WAIT",       -- wait for dialog to render after interact
    MODIFY    = "MODIFY",
    SCROLL    = "SCROLL",
    SELECT    = "SELECT",
    OPEN      = "OPEN",
    CHECK     = "CHECK",      -- verify chest consumed; retry if still interactable
    STEP_AWAY = "STEP_AWAY",  -- walk away from chest before retry
    RETURN    = "RETURN",     -- walk back and re-interact
    DONE      = "DONE",
}

local MAX_RETRIES = 5

local s = {
    state     = STATE.IDLE,
    t         = 0,
    target    = nil,
    chest_pos = nil,   -- saved chest position used for step-away / return
    away_pos  = nil,   -- computed step-away target
    retries   = 0,
}

local function set_state(st)
    s.state = st
    s.t     = get_time_since_inject()
end

local function elapsed()
    return get_time_since_inject() - s.t
end

-- -------------------------------------------------------
local task = { name = "Belial Chest Looter" }

function task.shouldExecute()
    if not settings.belial_chest_enabled then return false end
    if not in_belial_zone() then
        if s.state ~= STATE.IDLE then set_state(STATE.IDLE) end
        return false
    end
    -- Mid-sequence: keep running until DONE
    if s.state ~= STATE.IDLE and s.state ~= STATE.DONE then return true end
    -- Trigger: open_chest interacted with the physical chest this run
    return tracker.belial_chest_interacted == true
end

function task.Execute()
    local cfg = settings.belial_chest or {}

    -- ---- IDLE: begin sequence ----
    if s.state == STATE.IDLE then
        s.target  = pick_target()
        s.retries = 0
        console.print("[BelialChest] Starting sequence. Target: " .. s.target)
        tracker.belial_chest_interacted = false
        set_state(STATE.WAIT)
        return
    end

    -- ---- WAIT: 1.5s for dialog to render ----
    -- Every target now goes through Modify → (Scroll if page 2) →
    -- Select → Open.  The previous "Andariel skips Modify" shortcut
    -- assumed Andariel was the dialog's default selection; that no
    -- longer holds with the new menu order.
    if s.state == STATE.WAIT then
        if elapsed() >= 1.5 then
            set_state(STATE.MODIFY)
        end
        return
    end

    -- ---- MODIFY ----
    if s.state == STATE.MODIFY then
        C.modify()
        local target_info = TARGETS[s.target]
        if target_info and target_info.page == 2 then
            set_state(STATE.SCROLL)
        else
            set_state(STATE.SELECT)
        end
        return
    end

    -- ---- SCROLL (page-2 targets only) ----
    if s.state == STATE.SCROLL then
        if elapsed() >= 0.3 then
            C.scroll()
            set_state(STATE.SELECT)
        end
        return
    end

    -- ---- SELECT ----
    if s.state == STATE.SELECT then
        if elapsed() >= 0.3 then
            click_target(s.target)
            set_state(STATE.OPEN)
        end
        return
    end

    -- ---- OPEN ----
    if s.state == STATE.OPEN then
        local delay = (cfg.party_delay or 0) / 1000.0
        if elapsed() >= (0.3 + delay) then
            C.open()
            tracker.chest_opened_time = os.time()
            set_state(STATE.CHECK)
        end
        return
    end

    -- ---- CHECK: did the chest actually get consumed? ----
    -- Wait 1.5s for the open animation, then check interactability.
    -- If still interactable a party member likely reset the dialog.
    if s.state == STATE.CHECK then
        if elapsed() < 1.5 then return end

        local chest = find_belial_chest()
        if chest == nil then
            -- Chest consumed — we're done
            set_state(STATE.DONE)
            return
        end

        -- Still interactable — step away and retry
        s.retries = s.retries + 1
        if s.retries > MAX_RETRIES then
            console.print("[BelialChest] Max retries reached — giving up.")
            set_state(STATE.DONE)
            return
        end

        console.print(string.format("[BelialChest] Chest still interactable — retry %d/%d.",
            s.retries, MAX_RETRIES))

        local cp = chest:get_position()
        s.chest_pos = cp

        -- Compute a point 8 units away from the chest in the direction of the player
        local pp = get_player_position()
        local dx = pp.x - cp.x
        local dy = pp.y - cp.y
        local len = math.sqrt(dx * dx + dy * dy)
        if len < 0.1 then dx, dy, len = 1.0, 0.0, 1.0 end
        s.away_pos = vec3:new(cp.x + (dx / len) * 8, cp.y + (dy / len) * 8, cp.z)

        set_state(STATE.STEP_AWAY)
        return
    end

    -- ---- STEP_AWAY: move away from chest ----
    if s.state == STATE.STEP_AWAY then
        local cp = s.chest_pos
        local pp = get_player_position()
        if cp then
            local dx   = pp.x - cp.x
            local dy   = pp.y - cp.y
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist >= 6.0 or elapsed() >= 3.0 then
                set_state(STATE.RETURN)
                return
            end
        end
        if s.away_pos then
            pathfinder.request_move(s.away_pos)
        end
        return
    end

    -- ---- RETURN: walk back to chest and re-interact ----
    if s.state == STATE.RETURN then
        if elapsed() >= 10.0 then
            console.print("[BelialChest] Timed out returning to chest — giving up.")
            set_state(STATE.DONE)
            return
        end

        local chest = find_belial_chest()
        if not chest then
            -- Chest gone while stepping away — success
            console.print("[BelialChest] Chest gone while returning — done.")
            set_state(STATE.DONE)
            return
        end

        local dist = utils.distance_to(chest:get_position())
        if dist <= 2.5 then
            loot_manager.interact_with_object(chest)
            console.print("[BelialChest] Re-interacted with chest.")
            set_state(STATE.WAIT)
            return
        end

        explorerlite:set_custom_target(chest:get_position())
        explorerlite:move_to_target()
        return
    end

    -- ---- DONE ----
    if s.state == STATE.DONE then
        s.retries = 0
        set_state(STATE.IDLE)
        return
    end
end

return task
