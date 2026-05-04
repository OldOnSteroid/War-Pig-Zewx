local utils = require "core.utils"
local tracker = require "core.tracker"
local helltide_task = require "tasks.helltide"
local enums = require "data.enums"
local settings = require "core.settings"
local plugin_label = "helltide_revamped"

local current_city_index = 0
-- Remembers which helltide_tps entry is active this hour so we can return directly
-- instead of cycling through all waypoints after being displaced from the zone.
-- Cleared only when helltide_active() returns false (minute >= 55, new hour).
local confirmed_helltide_tp = nil

-- Debounce for the idle-town teleport. The "wait until helltide starts"
-- branch fires teleport_to_waypoint(town) every pulse for as long as the
-- player isn't in the town zone — but the teleport is a multi-second channel
-- that gets cancelled if re-fired before completion, so the player ends up
-- spinning in place instead of arriving. 6s covers the channel + arrival.
local IDLE_TELEPORT_DEBOUNCE_S = 6.0
local idle_teleport_fired_time = nil

local function detect_helltide_zone()
    for _, tp in ipairs(enums.helltide_tps) do
        if utils.player_in_region(tp.region) then
            return tp
        end
    end
    return nil
end

local function index_of_tp(tp)
    for i, entry in ipairs(enums.helltide_tps) do
        if entry.id == tp.id then return i end
    end
    return 1
end

local search_helltide_state = {
    SEARCHING_HELLTIDE = "SEARCHING_HELLTIDE",
    TELEPORTING = "TELEPORTING",
    WAITING_FOR_TELEPORT = "WAITING_FOR_TELEPORT",
    FOUND_HELLTIDE = "FOUND_HELLTIDE",
}

local search_helltide_task = {
    name = "Search helltide",
    current_state = search_helltide_state.SEARCHING_HELLTIDE,

    shouldExecute = function()
        return not utils.is_in_helltide()
    end,

    Execute = function(self)
        -- console.print("Current state: " .. self.current_state)

        local lp = get_local_player()
        if lp and lp:is_dead() then
            revive_at_checkpoint()
            return
        end

        if tracker.helltide_end then
            self:reset()
        elseif self.current_state == search_helltide_state.SEARCHING_HELLTIDE then
            self:searching_helltide()
        elseif self.current_state == search_helltide_state.TELEPORTING then
            self:teleporting_to_helltide()
        elseif self.current_state == search_helltide_state.WAITING_FOR_TELEPORT then
            self:waiting_for_teleport()
        elseif self.current_state == search_helltide_state.FOUND_HELLTIDE then
            self:found_helltide()
        end
    end,

    searching_helltide = function(self)
        console.print("Initializing search helltide")
        self:reset()
        if not utils.helltide_active() then
            -- New hour window: forget the cached zone so next hour we search fresh
            if confirmed_helltide_tp then
                console.print("[HelltideRevamped] Helltide hour ended, clearing confirmed zone: " .. confirmed_helltide_tp.file)
                confirmed_helltide_tp = nil
            end
            console.print("Helltide is not active, wait until helltide starts")
            if not utils.player_in_zone(settings.town_zone) then
                if settings.salvage then
                    if AlfredTheButlerPlugin then
                        AlfredTheButlerPlugin.resume()
                        AlfredTheButlerPlugin.trigger_tasks(plugin_label, function ()
                            AlfredTheButlerPlugin.pause(plugin_label)
                        end)
                    end
                else
                    if PLUGIN_alfred_the_butler then
                        PLUGIN_alfred_the_butler.resume()
                        PLUGIN_alfred_the_butler.trigger_tasks(plugin_label, function ()
                            PLUGIN_alfred_the_butler.pause(plugin_label)
                        end)
                    end
                end
                local now = get_time_since_inject()
                if not idle_teleport_fired_time
                    or now - idle_teleport_fired_time >= IDLE_TELEPORT_DEBOUNCE_S
                then
                    teleport_to_waypoint(settings.town_waypoint) -- Idle in selected home town until helltide starts
                    idle_teleport_fired_time = now
                end
            else
                -- We're in the home town zone — channel completed, drop the
                -- debounce stamp so the next "go idle" cycle fires immediately.
                idle_teleport_fired_time = nil
            end
            return
        elseif utils.is_in_helltide() then
            -- Confirm and cache the zone (replacing any stale cached zone if
            -- the trap-recovery flag was set, since we're now in a *different*
            -- zone than the one we abandoned).
            local detected = detect_helltide_zone()
            if detected and (not confirmed_helltide_tp
                or tracker.skip_cached_zone
                or confirmed_helltide_tp.id ~= detected.id)
            then
                confirmed_helltide_tp = detected
                console.print("[HelltideRevamped] Confirmed helltide zone: " .. confirmed_helltide_tp.file)
            end
            -- Player landed in a working helltide; clear the skip flag so
            -- future returns to this same zone are fast.
            tracker.skip_cached_zone = false
            console.print("Found helltide")
            self.current_state = search_helltide_state.FOUND_HELLTIDE
        elseif confirmed_helltide_tp and not tracker.skip_cached_zone then
            -- We know where this hour's helltide is — go back directly
            console.print("[HelltideRevamped] Returning to known helltide zone: " .. confirmed_helltide_tp.file)
            current_city_index = index_of_tp(confirmed_helltide_tp)
            tracker.wait_in_town = nil  -- reset arrival timer so we don't use a stale one
            self.current_state = search_helltide_state.WAITING_FOR_TELEPORT
        else
            -- Either no cached zone yet, OR trap-recovery told us to skip the
            -- cached one and try a different helltide region.  Cycle through.
            if tracker.skip_cached_zone then
                console.print("[HelltideRevamped] skip_cached_zone set — cycling through TPs to find a different helltide")
            else
                console.print("Not in helltide, teleport to next town to check")
            end
            self.current_state = search_helltide_state.TELEPORTING
        end
    end,

    teleporting_to_helltide = function(self)
        if not ( get_current_world():get_name() == "Limbo") and not tracker.teleporting then
            if current_city_index > #enums.helltide_tps then
                current_city_index = 1
            else
                current_city_index = (current_city_index % #enums.helltide_tps) + 1
            end
            -- Skip the cached zone when trap-recovery told us to find a
            -- different helltide.  Advance one more step if the cycle landed
            -- on the abandoned zone.  (One iteration is enough: zones are
            -- distinct entries in helltide_tps.)
            if tracker.skip_cached_zone and confirmed_helltide_tp
                and enums.helltide_tps[current_city_index].id == confirmed_helltide_tp.id
            then
                console.print("[HelltideRevamped] skipping abandoned zone " .. confirmed_helltide_tp.file)
                current_city_index = (current_city_index % #enums.helltide_tps) + 1
            end
            console.print("Teleporting to: " .. tostring(enums.helltide_tps[current_city_index].file))
            tracker.wait_in_town = nil
            self.current_state = search_helltide_state.WAITING_FOR_TELEPORT
        else
            console.print("Currently in loading screen. Waiting before attempting teleport.")
            return
        end
    end,

    waiting_for_teleport = function(self)
        if utils.player_in_zone(enums.helltide_tps[current_city_index].name) then
            if not tracker.check_time("wait_in_town", 4) then
                return
            end
            tracker.teleporting = false
            self.current_state = search_helltide_state.SEARCHING_HELLTIDE
        else
            if utils.is_teleporting() then
                tracker.teleporting = true
                return
            else
                teleport_to_waypoint(enums.helltide_tps[current_city_index].id)
                return
            end
            -- fail teleport, retry
            tracker.clear_key('wait_in_town')
            self.current_state = search_helltide_state.TELEPORTING
            return
        end
    end,

    found_helltide = function(self)
        console.print("Found helltide")
    end,

    reset = function(self)
        tracker.helltide_end = false
        helltide_task:reset()
        self.current_state = search_helltide_state.SEARCHING_HELLTIDE
    end
}

return search_helltide_task