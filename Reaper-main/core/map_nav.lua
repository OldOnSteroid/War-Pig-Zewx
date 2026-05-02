-- ============================================================
--  Reaper - core/map_nav.lua
--
--  Uses teleport_to_boss_dungeon(sno_id) to travel directly
--  to the boss dungeon, then waits for zone confirmation.
-- ============================================================

local map_nav = {}

-- -------------------------------------------------------
-- Boss SNO IDs  (from world SNO list)
-- -------------------------------------------------------
local BOSS_SNO = {
    grigoire  = 1496130,  -- Boss_WT3_PenitentKnight
    beast     = 1496152,  -- Boss_WT4_MegaDemon
    varshan   = 1496113,  -- Boss_WT3_Varshan
    belial    = 2166288,  -- Boss_Kehj_Belial
    andariel  = 1807180,  -- Boss_WT4_Andariel
    duriel    = 1496160,  -- Boss_WT4_Duriel
    butcher   = 2553700,  -- S12_Boss_Butcher
    zir       = 1496144,  -- Boss_WT4_S2VampireLord
    urivar    = 2191378,  -- Boss_WT5_Urivar
    harbinger = 2191385,  -- Boss_WT5_Harbinger
}

-- -------------------------------------------------------
-- State machine
-- -------------------------------------------------------
local STATE = {
    IDLE      = "IDLE",
    WAIT_ZONE = "WAIT_ZONE",  -- waiting to land in boss zone after teleport
    DONE      = "DONE",
}

local s = {
    state       = STATE.IDLE,
    t           = -999,
    boss_id     = nil,
    zone_prefix = nil,
    is_sigil    = false,
    attempts    = 0,
}

local MAX_ATTEMPTS = 3
local T_ZONE       = 20.0  -- seconds to wait for boss zone to load

local function now() return get_time_since_inject() end

local function in_boss_zone()
    local zone = get_current_world():get_current_zone_name()
    if s.is_sigil then
        return zone:find("BloodyLair") ~= nil
            or zone:find("S12_Boss")   ~= nil
            or zone:find("Boss_WT")    ~= nil
            or zone:find("Boss_Kehj")  ~= nil
    end
    if not s.zone_prefix or s.zone_prefix == "" then return false end
    return zone:match(s.zone_prefix) ~= nil
end

local function set_state(st)
    s.state = st
    s.t     = now()
end

local function elapsed() return now() - s.t end

local function do_teleport()
    local sno = BOSS_SNO[s.boss_id]
    if not sno then
        console.print("[MapNav] No SNO ID for boss: " .. tostring(s.boss_id))
        map_nav.reset()
        return false
    end
    console.print(string.format("[MapNav] Teleporting to %s (SNO %d)", s.boss_id, sno))
    teleport_to_boss_dungeon(sno)
    return true
end

-- -------------------------------------------------------
-- Public API
-- -------------------------------------------------------
function map_nav.start(boss_id, zone_prefix, is_sigil)
    s.boss_id     = boss_id
    s.zone_prefix = zone_prefix or ""
    s.is_sigil    = is_sigil or false
    s.attempts    = 0

    if do_teleport() then
        set_state(STATE.WAIT_ZONE)
    end
end

function map_nav.is_done()   return s.state == STATE.DONE end
function map_nav.is_active() return s.state ~= STATE.IDLE and s.state ~= STATE.DONE end
function map_nav.reset()     s.state = STATE.IDLE; s.boss_id = nil end
function map_nav.get_state() return s.state end

function map_nav.update()
    if s.state == STATE.IDLE or s.state == STATE.DONE then return end

    if s.state == STATE.WAIT_ZONE then
        if in_boss_zone() then
            console.print("[MapNav] Arrived: " .. get_current_world():get_current_zone_name())
            set_state(STATE.DONE)
            return
        end
        if elapsed() >= T_ZONE then
            s.attempts = s.attempts + 1
            console.print(string.format("[MapNav] Timeout – retry %d/%d", s.attempts, MAX_ATTEMPTS))
            if s.attempts >= MAX_ATTEMPTS then
                console.print("[MapNav] Giving up.")
                map_nav.reset()
                return
            end
            if do_teleport() then
                set_state(STATE.WAIT_ZONE)
            end
        end
        return
    end
end

return map_nav
