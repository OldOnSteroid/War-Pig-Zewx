local gui = require 'gui'

local settings = {
    plugin_label    = gui.plugin_label,
    plugin_version  = gui.plugin_version,
    enabled         = false,
    use_keybind     = false,
    use_teleport_transition = false,
    run_pit_after_turnin = false,
    teleport_click_x = 0,
    teleport_click_y = 0,
    show_click_points = false,
    verbose_logs    = false,
    log_all_quests  = false,
}

-- Module-level capture cache. The slider_int widget on this host doesn't
-- expose a :set() method — `:set(...)` errors with "attempt to call method
-- 'set' (a nil value)" — so we can't update the slider's displayed value
-- programmatically. Instead we cache the captured pixel here and prefer it
-- over the slider value when populating settings. Manual slider edits still
-- work (cleared by setting the slider to anything via the GUI is not
-- detectable, so once you capture, the slider value is overridden until the
-- script reloads — acceptable since capture is opt-in via keybind).
local captured_click_x = nil
local captured_click_y = nil

settings.update_settings = function()
    settings.enabled        = gui.elements.main_toggle:get()
    settings.use_keybind    = gui.elements.use_keybind:get()
    settings.use_teleport_transition = gui.elements.use_teleport_transition:get()
    settings.run_pit_after_turnin = gui.elements.run_pit_after_turnin:get()

    -- Keybind capture: when the user presses the bound key (default F5)
    -- while hovering an in-game target, capture the cursor's screen pixel
    -- position. Rising-edge consumed via :get_state().
    if gui.elements.teleport_capture_keybind:get_state() == 1 then
        if utility and type(utility.get_cursor_screen_position) == 'function' then
            local cx, cy = utility.get_cursor_screen_position()
            if cx and cy then
                captured_click_x = math.floor(cx)
                captured_click_y = math.floor(cy)
                console.print(string.format(
                    '[WarPigs] captured teleport click target = (%d, %d) [in-memory; slider widget read-only on this host]',
                    captured_click_x, captured_click_y))
            end
        end
    end

    -- Prefer the captured value over the slider when present. Falls back to
    -- the slider so a fresh script load (no capture yet) still honors the
    -- saved slider position.
    settings.teleport_click_x = captured_click_x or gui.elements.teleport_click_x:get()
    settings.teleport_click_y = captured_click_y or gui.elements.teleport_click_y:get()
    settings.show_click_points = gui.elements.show_click_points:get()
    settings.verbose_logs   = gui.elements.verbose_logs:get()
    settings.log_all_quests = gui.elements.log_all_quests:get()
end

-- Mirrors HordeDev's get_keybind_state(): when the keybind feature is off,
-- always returns true. When on, returns true only while the bound key is in
-- the active state (toggled on). 0x0A is the harness "no key bound" sentinel.
settings.get_keybind_state = function()
    if not settings.use_keybind then return true end
    local kb = gui.elements.keybind_toggle
    return kb:get_key() ~= 0x0A and kb:get_state() == 1
end

return settings
