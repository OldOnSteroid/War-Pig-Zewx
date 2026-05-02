-- ============================================================
--  Reaper - core/materials.lua
--
--  Scans inventory for boss summoning materials (consumables)
--  and Lair Boss Sigils (dungeon keys).
--
--  Material costs per run:
--    Varshan            12x Malignant Heart    (1489420)
--    Grigoire           12x Living Steel       (1502128)
--    Beast in the Ice   12x Distilled Fear     (1518053)
--    Lord Zir           12x Exquisite Blood    (1522891)
--    Urivar             12x Judicator's Mask   (2193876)
--    Duriel              3x Shard of Agony     (1524924)
--    Andariel            3x Pincushioned Doll  (1812685)
--    Harbinger           3x Abhorrent Heart    (2194097)
--    Belial              2x Betrayer's Husk    (2194099)
--
--  Sigil SNO IDs:
--    Bloodied/Bloodsoaked Lair Boss Sigil  sno_id = 2565553 (0x2725B1)
-- ============================================================

local materials = {}

-- -------------------------------------------------------
-- Consumable materials
-- -------------------------------------------------------
local BOSS_MATS = {
    varshan   = { sno_id = 1489420, cost = 12 },  -- Malignant Heart
    grigoire  = { sno_id = 1502128, cost = 12 },  -- Living Steel
    beast     = { sno_id = 1518053, cost = 12 },  -- Distilled Fear
    zir       = { sno_id = 1522891, cost = 12 },  -- Exquisite Blood
    urivar    = { sno_id = 2193876, cost = 12 },  -- Judicator's Mask
    duriel    = { sno_id = 1524924, cost =  3 },  -- Shard of Agony
    andariel  = { sno_id = 1812685, cost =  3 },  -- Pincushioned Doll
    harbinger = { sno_id = 2194097, cost =  3 },  -- Abhorrent Heart
    belial    = { sno_id = 2194099, cost =  2 },  -- Betrayer's Husk
    butcher   = { sno_id = 2553531, cost =  3 },  -- BossSummoning_Butcher
}

-- -------------------------------------------------------
-- Sigil definitions
-- -------------------------------------------------------
local SIGIL_SNO = 2565553  -- Bloodied + Bloodsoaked share the same SNO ID

-- Maps display name substrings → boss_id
local SIGIL_DISPLAY_MAP = {
    ["Hall of the Penitent"]  = "grigoire",
    ["Glacial Fissure"]       = "beast",
    ["Ancient's Seat"]        = "zir",
    ["Palace of the Deceiver"]= "belial",
    ["Hanged Man's Hall"]     = "andariel",
    ["Malignant Burrow"]      = "varshan",
    ["The Broiler"]           = "butcher",
    ["Gaping Crevasse"]       = "duriel",
    ["Fields of Judgement"]   = "urivar",
    ["Harbinger's Den"]       = "harbinger",
}

-- -------------------------------------------------------
-- Helpers
-- -------------------------------------------------------
local function count_consumable(items, sno_id)
    local total = 0
    for _, item in pairs(items) do
        if item:get_sno_id() == sno_id then
            local n = item:get_stack_count()
            total = total + (n > 0 and n or 1)
        end
    end
    return total
end

local function boss_from_display(display)
    if not display then return nil end
    for substr, boss_id in pairs(SIGIL_DISPLAY_MAP) do
        if display:find(substr, 1, true) then return boss_id end
    end
    return nil
end

-- Public alias so other modules can use it
materials.boss_from_display = boss_from_display

-- -------------------------------------------------------
-- Public: scan consumable materials from inventory
-- Returns { boss_id = run_count }
-- -------------------------------------------------------
function materials.scan()
    local lp = get_local_player()
    if not lp then return {} end

    local consumables = lp:get_consumable_items() or {}
    local result = {}
    for boss_id, mat in pairs(BOSS_MATS) do
        local count = count_consumable(consumables, mat.sno_id)
        result[boss_id] = math.floor(count / mat.cost)
    end
    return result
end

-- -------------------------------------------------------
-- Public: check if inventory has any runs available
-- -------------------------------------------------------
function materials.has_inventory_stock(settings)
    if settings.run_materials then
        local mats = materials.scan()
        for _, v in pairs(mats) do
            if v > 0 then return true end
        end
    end
    if settings.run_sigils then
        local sigs = materials.scan_sigils()
        for k, v in pairs(sigs) do
            if k ~= "unknown" and v > 0 then return true end
        end
    end
    return false
end

-- -------------------------------------------------------
-- Public: scan Lair Boss Sigils from dungeon key inventory
-- Returns { boss_id = count }
-- -------------------------------------------------------
function materials.scan_sigils()
    local lp = get_local_player()
    if not lp then return {} end

    local ok, keys = pcall(function() return lp:get_dungeon_key_items() end)
    if not ok or type(keys) ~= "table" then return {} end

    local result = {}
    for _, item in ipairs(keys) do
        local ok_sno, sno = pcall(function() return item:get_sno_id() end)
        if ok_sno and sno == SIGIL_SNO then
            local ok_d, display = pcall(function() return item:get_display_name() end)
            local boss_id = ok_d and boss_from_display(display) or nil
            if boss_id then
                result[boss_id] = (result[boss_id] or 0) + 1
                console.print(string.format("[Reaper] Sigil found: '%s' → %s", tostring(display), boss_id))
            else
                result["unknown"] = (result["unknown"] or 0) + 1
                console.print(string.format("[Reaper] Sigil UNMAPPED: '%s' (sno=0x%X) — add to SIGIL_DISPLAY_MAP",
                    tostring(display), sno))
            end
        end
    end
    return result
end

function materials.print_summary()
    local counts = materials.scan()
    console.print("[Reaper] Material scan:")
    for boss_id, runs in pairs(counts) do
        console.print(string.format("  %-12s %d runs", boss_id, runs))
    end
end

function materials.print_all_consumables()
    local lp = get_local_player()
    if not lp then console.print("[Reaper] print_all_consumables: no local player"); return end
    local ok, items = pcall(function() return lp:get_consumable_items() end)
    if not ok or type(items) ~= "table" then
        console.print("[Reaper] print_all_consumables: could not read consumable items")
        return
    end
    console.print(string.format("[Reaper] Consumable inventory (%d item slots):", #items))
    for _, item in ipairs(items) do
        local ok_sno,  sno   = pcall(function() return item:get_sno_id() end)
        local ok_name, name  = pcall(function() return item:get_name() end)
        local ok_disp, disp  = pcall(function() return item:get_display_name() end)
        local ok_cnt,  cnt   = pcall(function() return item:get_stack_count() end)
        local sno_str  = ok_sno  and string.format("sno=%d (0x%X)", sno, sno) or "sno=?"
        local name_str = ok_name and name  or (ok_disp and disp or "unknown")
        local cnt_str  = ok_cnt  and tostring(cnt > 0 and cnt or 1)            or "?"
        console.print(string.format("  [%s]  x%-4s  %s", sno_str, cnt_str, name_str))
    end
end

return materials
