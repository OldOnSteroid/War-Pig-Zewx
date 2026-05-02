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
--  Andariel:   wait → Open
--  Varshan:    wait → Modify → wait → Scroll → wait → Varshan → wait → Open
--  Others:     wait → Modify → wait → Boss   → wait → Open
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

-- Coords as ratios (measured px / reference res)
local C = {
    open     = function() click(349/1920, 956/1080) end,
    modify   = function() click(349/1920, 816/1080) end,
    scroll   = function() click(629/1920, 858/1080) end,
    duriel   = function() click(349/1920, 397/1080) end,
    grigoire = function() click(349/1920, 495/1080) end,
    harbinger= function() click(349/1920, 585/1080) end,
    zir      = function() click(349/1920, 683/1080) end,
    beast    = function() click(349/1920, 773/1080) end,
    urivar   = function() click(349/1920, 875/1080) end,
    varshan  = function() click(349/1920, 845/1080) end,
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
    if s.state == STATE.WAIT then
        if elapsed() >= 1.5 then
            if s.target == "andariel" then
                set_state(STATE.OPEN)
            else
                set_state(STATE.MODIFY)
            end
        end
        return
    end

    -- ---- MODIFY ----
    if s.state == STATE.MODIFY then
        C.modify()
        if s.target == "varshan" then
            set_state(STATE.SCROLL)
        else
            set_state(STATE.SELECT)
        end
        return
    end

    -- ---- SCROLL (Varshan only) ----
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
            local fn = C[s.target]
            if fn then
                fn()
            else
                console.print("[BelialChest] No button for " .. s.target)
            end
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
