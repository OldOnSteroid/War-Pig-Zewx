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
--
-- Reference coordinates are pixels at 1920x1080. The dialog scales with
-- vertical resolution and stays centered horizontally, so the conversion
-- to actual screen pixels is:
--
--   screen_x = screen_width/2 + (ref_x - 960)  * (screen_height / 1080)
--   screen_y = ref_y * (screen_height / 1080)
--
-- This keeps clicks on-target for ultrawide (21:9 / 32:9) where naive
-- ratio scaling would put them well to the left of the actual button.
-- -------------------------------------------------------
local REF_W, REF_H = 1920, 1080

-- Resolve a 1920x1080 pixel coordinate to current-screen pixels.
local function resolve(ref_x, ref_y)
    local sw = get_screen_width()
    local sh = get_screen_height()
    local scale = sh / REF_H
    local x = math.floor(sw / 2 + (ref_x - REF_W / 2) * scale)
    local y = math.floor(ref_y * scale)
    return x, y
end

-- Public so the renderer can draw crosshairs at the same positions.
local function ref_points(cfg)
    cfg = cfg or settings.belial_chest or {}
    local sx = cfg.slot_x or 349
    local sy = cfg.slot_y or { 397, 495, 585, 683, 773, 875, 971 }
    local mod = cfg.modify or { x = 349, y = 816 }
    local scr = cfg.scroll or { x = 629, y = 858 }
    local opn = cfg.open   or { x = 349, y = 956 }
    return {
        { label = "Modify", color = "yellow", x = mod.x, y = mod.y },
        { label = "Scroll", color = "cyan",   x = scr.x, y = scr.y },
        { label = "Open",   color = "green",  x = opn.x, y = opn.y },
        { label = "Slot 1", color = "white",  x = sx, y = sy[1] or 0 },
        { label = "Slot 2", color = "white",  x = sx, y = sy[2] or 0 },
        { label = "Slot 3", color = "white",  x = sx, y = sy[3] or 0 },
        { label = "Slot 4", color = "white",  x = sx, y = sy[4] or 0 },
        { label = "Slot 5", color = "white",  x = sx, y = sy[5] or 0 },
        { label = "Slot 6", color = "white",  x = sx, y = sy[6] or 0 },
        { label = "Slot 7", color = "white",  x = sx, y = sy[7] or 0 },
    }
end

local function click_at(ref_x, ref_y, label)
    local x, y = resolve(ref_x, ref_y)
    console.print(string.format("[BelialChest] click %s -> (%d, %d)",
        label or "?", x, y))
    utility.send_mouse_click(x, y)
end

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
    local cfg = settings.belial_chest or {}
    local sx = cfg.slot_x or 349
    local sy_table = cfg.slot_y or { 397, 495, 585, 683, 773, 875, 971 }
    click_at(sx, sy_table[t.slot] or 0, "Slot " .. t.slot)
end

-- Static dialog buttons (Open / Modify / Scroll). Sourced from
-- settings.belial_chest so users can tune them in the GUI.
local C = {
    open   = function()
        local p = (settings.belial_chest or {}).open or { x = 349, y = 956 }
        click_at(p.x, p.y, "Open")
    end,
    modify = function()
        local p = (settings.belial_chest or {}).modify or { x = 349, y = 816 }
        click_at(p.x, p.y, "Modify")
    end,
    scroll = function()
        local p = (settings.belial_chest or {}).scroll or { x = 629, y = 858 }
        click_at(p.x, p.y, "Scroll")
    end,
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

-- Public helpers used by main.lua's calibration overlay.
task.resolve_ref_to_screen = resolve
task.get_ref_points        = ref_points

return task
