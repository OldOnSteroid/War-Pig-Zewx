-- ============================================================
--  Reaper - core/input.lua
--
--  Thin wrappers around the utility keyboard/mouse API.
--  All coordinates are screen-relative (0.0–1.0) so they
--  work at any resolution. Pass raw pixel coords only where
--  noted.
-- ============================================================

local input = {}

-- -------------------------------------------------------
-- Internal: convert relative (0–1) coords to pixel coords
-- Clamps Y to minimum 1 to avoid sending events at the
-- OS title bar / top edge of the window (y=0 is dead zone).
-- -------------------------------------------------------
local function rel(rx, ry)
    local w = get_screen_width()
    local h = get_screen_height()
    local px = math.floor(w * rx)
    local py = math.max(1, math.floor(h * ry))
    return px, py
end

-- -------------------------------------------------------
-- Keyboard
-- -------------------------------------------------------

-- VK codes used in this script
input.VK = {
    M      = string.byte('M'),
    ESC    = 0x1B,
    ENTER  = 0x0D,
    SPACE  = 0x20,
}

function input.key_press(vk_code)
    utility.send_key_press(vk_code)
end

-- -------------------------------------------------------
-- Mouse – relative coords (0.0–1.0)
-- -------------------------------------------------------

function input.click_rel(rx, ry)
    local x, y = rel(rx, ry)
    utility.send_mouse_click(x, y)
end

function input.right_click_rel(rx, ry)
    local x, y = rel(rx, ry)
    utility.send_mouse_right_click(x, y)
end

function input.move_rel(rx, ry)
    local x, y = rel(rx, ry)
    utility.send_mouse_move(x, y)
end

--- Scroll at a relative position.
--- delta: positive = up/zoom out, negative = down/zoom in
function input.scroll_rel(rx, ry, delta)
    local x, y = rel(rx, ry)
    utility.send_mouse_wheel(x, y, delta)
end

-- -------------------------------------------------------
-- Mouse – raw pixel coords (use sparingly)
-- -------------------------------------------------------

function input.click_px(x, y)
    utility.send_mouse_click(x, y)
end

function input.scroll_px(x, y, delta)
    utility.send_mouse_wheel(x, y, delta)
end

-- -------------------------------------------------------
-- Map helpers
-- -------------------------------------------------------

--- Open the in-game map (M key)
function input.open_map()
    input.key_press(input.VK.M)
end

--- Close the map (ESC)
function input.close_map()
    input.key_press(input.VK.ESC)
end

return input
