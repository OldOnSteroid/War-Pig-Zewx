local settings = require 'core.settings'

local orchestrator = {}

-- ── transition sequencer ────────────────────────────────────────────────────
-- Goal: never have two activity plugins running at once and never start the
-- next plugin while the previous one is still wrapping up. Sequence per
-- handoff:
--   (1) Wait for outgoing plugin's disable_when() to return true
--       (e.g. Pit/WonderCity → back in town; Reaper → boss kill + 60s).
--   (2) Disable outgoing plugin.
--   (3) Wait TRANSITION_GAP_SECONDS for game state to settle.
--   (4) Enable incoming plugin.
-- MAX_DISABLE_DEFER_SECONDS is a safety cap so a stuck activity can't block
-- the orchestrator forever.
local TRANSITION_GAP_SECONDS    = 5
local MAX_DISABLE_DEFER_SECONDS = 120

-- Optional teleport sequence inserted between disable and enable when
-- settings.use_teleport_transition is on. After a plugin is disabled and a
-- new plugin is wanted, we send Tab once (open map / quest list), wait
-- briefly, click the user-defined pixel target (initiate teleport to the
-- next quest), and then confirm arrival before releasing the enable gate.
-- Confirmation: after TELEPORT_CHECK_INTERVAL seconds we snapshot world +
-- zone at fire time and re-check; if at least one changed the teleport
-- landed, otherwise we retry warplan.teleport_to_activity() and check again.
local TELEPORT_CHECK_INTERVAL = 3.0

-- Hold time AFTER the incoming activity first appears in the matched set.
-- Stops us from pressing Tab the same tick the previous WarPlan unmatched —
-- the next WarPlan (e.g. TurnIn) typically lands ~1 second later, and the
-- in-game quest panel needs a moment to redraw with its entry before our
-- pixel-targeted click can hit it. 2.5s comfortably covers the 1-1.5s
-- spawn delay seen in logs (Helltide → TurnIn ≈ 1.0s) plus UI render.
local TELEPORT_INCOMING_SETTLE = 2.5

local function alfred_idle()
    local alfred = _G.AlfredTheButlerPlugin
    if not alfred or type(alfred.get_status) ~= 'function' then return true end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return true end
    -- Not enabled = nothing to wait on.
    if not s.enabled then return true end
    -- Paused: only safe to skip if Alfred has nothing pending. If need_trigger
    -- or inventory_full is set Alfred wants to salvage/stash but can't self-start
    -- while paused — alfred_kick_if_needed() will resume it; we hold the gate
    -- here so the teleport doesn't fire before Alfred finishes.
    if s.paused then
        if s.need_trigger or s.inventory_full then return false end
        return true
    end
    -- trigger_tasks is the live "Alfred is processing its queue" flag —
    -- Alfred's status task sets it true when there's work pending and
    -- clears it when the queue completes. Don't use all_task_done here:
    -- that flag is initially false on cold start (only flips true AFTER
    -- Alfred runs at least one full cycle), so on a fresh launch with
    -- nothing for Alfred to do it gates us forever.
    if s.trigger_tasks then return false end
    return true
end

-- When Alfred is paused but has work to do (need_trigger / inventory_full) and
-- the player is in town, resume and trigger it so it can run before the next
-- teleport. Called each tick while teleport_pending is true so it fires as soon
-- as we land in town after a pit/undercity/horde exit. Only acts while paused —
-- once resumed, Alfred's own loop takes over and alfred_idle() gates on
-- trigger_tasks clearing, so we won't double-fire.
local function alfred_kick_if_needed()
    -- Inline in-town check (in_town_disable_when is defined later in this file).
    local _lp = get_local_player()
    if not _lp then return end
    if _G.attributes and _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA ~= nil then
        local _ok, _val = pcall(function()
            return _lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
        end)
        if not (_ok and _val == true) then return end
    end
    local alfred = _G.AlfredTheButlerPlugin
    if not alfred or type(alfred.get_status) ~= 'function' then return end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return end
    if not s.enabled then return end
    if not s.paused then return end
    if not (s.need_trigger or s.inventory_full) then return end
    if type(alfred.resume) == 'function' then pcall(alfred.resume) end
    if type(alfred.trigger_tasks) == 'function' then
        pcall(alfred.trigger_tasks, 'WarPigs')
    end
    log('Alfred was paused with work pending — resumed and triggered (in town, pre-transition)')
end

-- Via-Temis-Alfred preamble: before EVERY warplan teleport (cold start + each
-- handoff), drop the player at Temis and trigger Alfred so loot from the prior
-- activity is salvaged/stashed/repaired before the next quest starts. The user
-- explicitly asked for this — it costs an extra teleport for non-Pit activities
-- but guarantees a clean inventory each cycle.
local TEMIS_WP                = 0x1CE51E      -- Skov_Temis waypoint sno
local TEMIS_ZONE              = 'Skov_Temis'
local TEMIS_TELEPORT_TIMEOUT  = 30.0          -- retry the waypoint hop after this
local TEMIS_TELEPORT_DEBOUNCE = 6.0           -- min gap between waypoint calls (channel ≈ 5s)
-- Alfred dwell window. After firing trigger_tasks we need to give Alfred's main
-- loop a beat to pick up the trigger and flip its busy/trigger_tasks flag —
-- otherwise alfred_idle() returns true the instant we trigger and we leave the
-- state immediately. ALFRED_GRACE_SECONDS is the "if Alfred never went busy
-- there's nothing to do" timeout. ALFRED_MAX_SECONDS is the absolute safety cap.
local ALFRED_GRACE_SECONDS    = 4.0
local ALFRED_MAX_SECONDS      = 180.0

local function in_temis()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    return ok2 and zname == TEMIS_ZONE
end

-- Resume Alfred if paused, then fire trigger_tasks. Returns true if a trigger
-- was actually issued (Alfred loaded AND enabled). False means caller should
-- skip the TEMIS_ALFRED dwell and go straight to the warplan teleport.
local function alfred_trigger_now()
    local alfred = _G.AlfredTheButlerPlugin
    if not alfred or type(alfred.trigger_tasks) ~= 'function' then return false end
    if type(alfred.get_status) == 'function' then
        local ok, s = pcall(alfred.get_status)
        if not (ok and type(s) == 'table' and s.enabled) then return false end
        if s.paused and type(alfred.resume) == 'function' then pcall(alfred.resume) end
    end
    pcall(alfred.trigger_tasks, 'WarPigs')
    return true
end

local teleport_transition = {
    -- IDLE | TO_TEMIS | TEMIS_ALFRED | TELEPORTING
    -- TO_TEMIS:     teleport_to_waypoint(TEMIS_WP) sent, waiting for arrival.
    -- TEMIS_ALFRED: alfred_trigger_now() fired, waiting for Alfred to finish.
    -- TELEPORTING:  warplan.teleport_to_activity() sent, waiting for confirmation.
    state           = 'IDLE',
    started_at      = -math.huge,
    snap_world      = nil,  -- world name at the moment teleport was sent
    snap_zone       = nil,  -- zone name at the moment teleport was sent
    last_temis_tp   = -math.huge,  -- debounce for repeated TEMIS_WP calls
    alfred_fired_at = nil,  -- time alfred_trigger_now() was called
    alfred_was_busy = false, -- went busy at least once after trigger (saw work)
}
-- True when the teleport sequence still needs to start. Two trigger sources:
--   * plugin_disable() — fires AFTER the previous activity's disable_when
--     predicate satisfies (Reaper waits kill+60s for chest/loot, Pit/WC
--     wait for town arrival post-Alfred-salvage). This means "previous
--     activity finished cleanup, safe to teleport for the next one".
--   * cold-start — when no plugin/task has ever been active in this WarPigs
--     session and a quest first matches, fire teleport before the very
--     first activity begins.
-- A pattern-edge trigger ("next WarPlan's quest matches") was DELIBERATELY
-- rejected: WarPlan quests unmatch the moment the boss dies, while the bot
-- still has chests to open and loot to salvage. Triggering on the new
-- pattern's match would interrupt that cleanup and lose the loot.
local teleport_pending = false
-- Tracks when the *incoming* activity first matched after teleport_pending was
-- armed. We wait TELEPORT_INCOMING_SETTLE before calling teleport_to_activity()
-- so the warplan data reflects the new quest. Cleared when a sequence starts.
local teleport_incoming_first_seen = nil
-- Suppresses repeat "teleport holding — …" logs while waiting for predicates.
local teleport_holding_logged = false
-- Tracks whether ANY plugin/task has been active under this WarPigs session.
-- False until the first activity starts; switched true on first activation
-- so cold-start fires exactly once. Reset by release_all().
local had_active_session = false

-- Scans all actors for a given skin name. Used by arrived_when predicates so
-- the orchestrator can confirm "we are at the quest destination" without
-- importing plugin-specific utils modules.
local function actor_present(skin_name)
    local ok, actors = pcall(function() return actors_manager:get_all_actors() end)
    if not ok or type(actors) ~= 'table' then return false end
    for _, actor in ipairs(actors) do
        local ok2, name = pcall(function() return actor:get_skin_name() end)
        if ok2 and name == skin_name then return true end
    end
    return false
end

-- Predicate: is the player in a town level area? Reused by Pit / WonderCity /
-- Helltide entries since "back in town" is the natural settle point for all
-- three. Returns true on any failure to read the attribute (don't block on
-- API quirks — MAX_DISABLE_DEFER_SECONDS is the real safety net).
local function in_town_disable_when()
    local lp = get_local_player()
    if not lp then return false end
    if not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then
        return true
    end
    local ok, val = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
    end)
    return ok and val == true
end

-- Predicate: does the player currently have the Helltide buff (= we're inside
-- a helltide zone). Used as arrived_when for the Helltide WarPlans entry so
-- WarPigs skips warplan.teleport_to_activity() when we're already in the right
-- zone — without this, cold-start (or post-respawn re-arm) inside a helltide
-- fires the teleport which is a no-op (world/zone unchanged) and loops on
-- "teleport retry — world/zone unchanged" forever, fighting HR's chest /
-- patrol work the whole time.
local HELLTIDE_BUFF_HASH = 1066539
local function has_helltide_buff()
    local lp = get_local_player()
    if not lp then return false end
    local ok, buffs = pcall(function() return lp:get_buffs() end)
    if not ok or type(buffs) ~= 'table' then return false end
    for _, buff in ipairs(buffs) do
        local ok2, hash = pcall(function() return buff.name_hash end)
        if ok2 and hash == HELLTIDE_BUFF_HASH then return true end
    end
    return false
end

-- Predicate: is the player already inside an Undercity dungeon zone? Mirrors
-- WonderCity's `utils.player_in_undercity` (zone name match `X1_Undercity_`).
-- Used as part of arrived_when for WarPlans_QST_Undercity so the orchestrator
-- recognises an in-progress run and stops re-firing warplan.teleport_to_activity()
-- — without this, mid-run teleport snapshots inside e.g. X1_Undercity_SnakeTemple_*
-- never confirm (brazier-only arrived_when can't see it deep in the dungeon),
-- and WarPigs loops on "teleport retry — world/zone unchanged" while WonderCity
-- is trying to do its job.
local function in_undercity_zone()
    local ok, w = pcall(function() return get_current_world() end)
    if not ok or w == nil then return false end
    local ok2, zname = pcall(function() return w:get_current_zone_name() end)
    if not ok2 or type(zname) ~= 'string' then return false end
    return zname:match('X1_Undercity_') ~= nil
end

-- Predicate: are there live enemies close enough that the teleport channel
-- will be interrupted by incoming damage? Used to defer
-- warplan.teleport_to_activity() out of a helltide zone — once the rotation
-- plugin clears the area, this returns false and the teleport fires
-- immediately on the next tick.
local COMBAT_NEARBY_RANGE = 12
local function enemies_near_player()
    if not _G.target_selector or type(target_selector.get_near_target_list) ~= 'function' then
        return false
    end
    local lp = get_local_player()
    if not lp then return false end
    local ok_pos, pos = pcall(function() return lp:get_position() end)
    if not ok_pos or not pos then return false end
    local ok, list = pcall(target_selector.get_near_target_list, pos, COMBAT_NEARBY_RANGE)
    if not ok or type(list) ~= 'table' then return false end
    for _, e in pairs(list) do
        local ok2, hp = pcall(function() return e:get_current_health() end)
        if ok2 and hp and hp > 1 then
            local ok3, untarg = pcall(function() return e:is_untargetable() end)
            if not (ok3 and untarg) then return true end
        end
    end
    return false
end

-- Reaper kill tracker. Reaper only exposes a monotonically-increasing
-- total_runs counter, so we snapshot it at enable time and treat any increase
-- after that as "boss died this run". The 60s post-kill defer covers loot
-- pickup, crafting-mat opening, and travel back to town.
local reaper_kill = { baseline = nil, kill_time = nil }

local function reaper_kill_tick()
    local p = _G.ReaperPlugin
    if not p or type(p.status) ~= 'function' then return end
    local ok, s = pcall(p.status)
    if not ok or type(s) ~= 'table' then return end
    local total = s.total_runs or 0
    if reaper_kill.baseline == nil then
        reaper_kill.baseline = total
        return
    end
    if total > reaper_kill.baseline then
        reaper_kill.kill_time = get_time_since_inject()
        reaper_kill.baseline  = total
    end
end

local function reset_reaper_kill_baseline()
    local p = _G.ReaperPlugin
    if p and type(p.status) == 'function' then
        local ok, s = pcall(p.status)
        if ok and type(s) == 'table' then
            reaper_kill.baseline = s.total_runs or 0
        else
            reaper_kill.baseline = 0
        end
    else
        reaper_kill.baseline = 0
    end
    reaper_kill.kill_time = nil
end

local function reaper_kill_disable_when()
    if reaper_kill.kill_time == nil then return false end
    return get_time_since_inject() - reaper_kill.kill_time >= 60
end

-- Map keys are matched as PLAIN SUBSTRINGS against the names of active
-- quests. Only quests whose name contains "WarPlans_QST" are eligible —
-- everything else (Bounty_*, story quests, etc.) is ignored. Multiple keys
-- may target the same plugin; the plugin stays enabled while at least one
-- key still matches.
--
-- Each value is either:
--   * a STRING — the plugin global name (calls plugin.enable()/disable())
--   * a TABLE  — {
--         plugin       = 'GlobalName',
--         enable       = fn(p)         -- optional custom enable hook
--         disable      = fn(p)         -- optional custom disable hook
--         disable_when = fn() -> bool  -- optional. When the quest disappears,
--                                      -- disable is deferred until this
--                                      -- returns true. Re-checked every tick.
--                                      -- Use to let the plugin finish a
--                                      -- post-quest wrap-up before WarPigs
--                                      -- flips it off (e.g. Arkham collecting
--                                      -- the glyphstone reward and TPing out
--                                      -- of the pit).
--     }
--   * a TABLE with `task` — {
--         task = require 'core.tasks.<name>'  -- module exposing tick(active)
--     }
--     The task module's tick(true) is called each WarPigs tick while the
--     trigger pattern matches; tick(false) when it stops. Used for actions
--     WarPigs performs itself (teleport, NPC interaction) instead of just
--     toggling another plugin.
-- Activity-plugin preemption priority. When more than one plugin's quest is
-- matched simultaneously, only the highest-priority one stays "wanted" — the
-- rest are treated as if their quest had gone unmatched (disabled per the
-- normal disable/disable_when path).
--
-- Why: WarPlans for short-lived objectives (Pit, Boss runs, Hordes) frequently
-- overlap with ambient/long-running activities (Undercity, Helltide). Without
-- preemption, both plugins stay enabled and fight for BatmobilePlugin/orbwalker
-- — in practice the ambient one wins the per-pulse race because it's already
-- mid-run, and the short-lived objective never starts. Specifically, completing
-- a Kurast boss and returning to Temis with an active Pit WarPlan should hand
-- off to Arkham; before this preemption, WonderCity just looped into the next
-- Undercity run instead.
--
-- Higher number = higher priority. Plugins not listed default to 0 (no
-- preemption — they always run alongside others if their quest matches).
local PLUGIN_PRIORITY = {
    ArkhamAsylumPlugin     = 100,  -- Pit: short objective, preempt ambient activities
    InfernalHordesPlugin   = 90,   -- Horde wave: also short
    ReaperPlugin           = 80,   -- Boss runs: short
    WonderCityPlugin       = 50,   -- Undercity: ambient/repeatable
    HelltideRevampedPlugin = 40,   -- Helltide: ambient/timed
}

orchestrator.quest_plugin_map = {
    WarPlans_QST_ThePit = {
        plugin = 'ArkhamAsylumPlugin',
        -- Pit quest can vanish while still inside the pit (post-quest reward
        -- phase). Wait for the player to fully return to town before letting
        -- the next plugin take over.
        disable_when = in_town_disable_when,
        -- Pit tower lives in Temis. If we're already in Temis when the teleport
        -- sequence fires, world/zone won't change and the confirmation loop
        -- would retry forever. arrived_when lets the orchestrator skip or
        -- confirm the teleport when the pit tower actor is already visible.
        arrived_when = function()
            return actor_present('TWN_Kehj_IronWolves_PitKey_Crafter')
        end,
    },

    -- Helltide handoff: no disable_when. The quest disappearing means the
    -- helltide event ended (or the bot left it), and there's no in-zone
    -- wrap-up worth waiting for — HR can be cut immediately. The standard
    -- TRANSITION_GAP_SECONDS (5s) gap still applies via last_disable_time
    -- before the next plugin enables.
    --
    -- arrived_when = has_helltide_buff: when the player is already inside the
    -- helltide zone (cold-start with both plugins enabled, or post-respawn
    -- re-arm), warplan.teleport_to_activity() is a no-op and the orchestrator
    -- otherwise loops on "teleport retry — world/zone unchanged" while HR
    -- tries to do its job (logzewx 3337-3343 confirmed). The buff check is the
    -- ground truth — it fires when we're in the active helltide regardless of
    -- which specific Helltide_* zone we landed in.
    WarPlans_QST_Helltide_TorturedGifts = {
        plugin       = 'HelltideRevampedPlugin',
        arrived_when = has_helltide_buff,
    },

    WarPlans_QST_Undercity = {
        plugin       = 'WonderCityPlugin',
        disable_when = in_town_disable_when,  -- wait for the Kurast/Temis return
        -- Two-layer arrived check:
        --   1. Brazier visible (Aubrie_Test_Undercity_Crafter) — we're at the
        --      Undercity town crafter, ready to start a run. Same loop-prevention
        --      as the Pit entry above — if already in town the teleport is a no-op.
        --   2. Already inside an X1_Undercity_* zone — we're mid-run. WonderCity
        --      owns the bot; WarPigs must not re-fire teleport_to_activity()
        --      because the dungeon world/zone snapshot won't change between
        --      retries and arrived_when is the only confirmation path.
        arrived_when = function()
            return actor_present('Aubrie_Test_Undercity_Crafter')
                or in_undercity_zone()
        end,
    },

    -- Confirmed seen in logs as WarPlans_QST_InfernalHordes_BSK; substring
    -- match covers any tier/variant suffix.
    --
    -- Quest vanishes when the wave bosses die, but HordeDev still has to
    -- open chests and pick up loot. Defer disable until we either leave the
    -- BSK world (S05_BSK_Prototype02) or 60s elapse as a safety cap.
    WarPlans_QST_InfernalHordes = {
        plugin = 'InfernalHordesPlugin',
        -- Quest vanishes when the wave bosses die, but HordeDev still has to
        -- run its full post-boss cycle: open the talisman chest (if enabled),
        -- the greater-affix chest (if enabled), the materials/selected chest,
        -- then exit_horde teleports back to town. WarPigs must not preempt
        -- any of those steps.
        --
        -- Primary gate: chests_done() — HordeDev sets this true only after
        -- finish_chest_opening (or a hard exhaust). While it's false we hold
        -- unconditionally; the previous version's 60s in-BSK timer fired in
        -- the middle of "Waiting Talisman loot" and dropped GA + materials.
        --
        -- Once chests are done we wait for out-of-BSK as confirmation that
        -- exit_horde has actually fired (it teleports the player to Caldeum).
        -- Small safety cap covers a stuck exit_horde channel; while chests
        -- are still progressing the cap is not started.
        --
        -- max_disable_defer_seconds overrides the global MAX_DISABLE_DEFER
        -- so a slow chest sequence (talisman + GA + materials with loot
        -- waits) can't be force-disabled by the orchestrator's safety net.
        max_disable_defer_seconds = 300,
        disable_when = (function()
            local exit_defer_start
            return function()
                local p = _G.InfernalHordesPlugin
                local done = p and type(p.chests_done) == 'function' and p.chests_done()
                if not done then
                    exit_defer_start = nil
                    return false
                end
                local world = get_current_world()
                local name
                if world then
                    local ok, n = pcall(function() return world:get_name() end)
                    if ok then name = n end
                end
                local in_bsk = type(name) == 'string'
                    and name:find('BSK', 1, true) ~= nil
                if not in_bsk then
                    exit_defer_start = nil
                    return true
                end
                exit_defer_start = exit_defer_start or get_time_since_inject()
                if get_time_since_inject() - exit_defer_start >= 60 then
                    exit_defer_start = nil
                    return true
                end
                return false
            end
        end)(),
    },

    -- After a WarPlan finishes, this quest returns to drive the reward
    -- turn-in. WarPigs handles it directly: teleport to Temis, walk to
    -- Tyrael, interact.
    WarPlans_QST_TurnIn_Rewards = { task = require 'core.tasks.turn_in_rewards' },

    -- Boss runs via Reaper. boss_id must match an entry in
    -- Reaper-main/data/enums.lua boss_zones (duriel, andariel, varshan,
    -- grigoire, zir, beast, harbinger, urivar, butcher, belial).
    --
    -- Quest-name suffixes are confirmed where marked; the rest are best
    -- guesses based on the "Andariel" and "Harby" precedents. Wrong guesses
    -- are harmless (substring just won't match anything) — verify via the
    -- "Log ALL quests" mode and rename as needed.
    WarPlans_QST_BossLair_Andariel = {  -- CONFIRMED
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('andariel') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Harby = {     -- CONFIRMED (harbinger)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('harbinger') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Duriel = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('duriel') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Varshan = {   -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('varshan') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_PenitentKnight = {  -- CONFIRMED (grigoire)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('grigoire') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Zir = {  -- CONFIRMED (log 2026-05-03: id=2317384)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('zir') end,
        disable_when = reaper_kill_disable_when,
    },
    -- Beast in Ice: asset name is Boss_WT4_MegaDemon, but quests typically use
    -- the display name (per Harby/PenitentKnight precedent). Listing multiple
    -- aliases so we match whatever Blizzard chose. Multiple keys → same plugin
    -- is supported (kept enabled while ANY matches). Confirm the real name by
    -- enabling settings.log_all_quests and watching for "NEW QUEST: ..."
    -- containing WarPlans_QST_BossLair_*; trim the misses afterward.
    WarPlans_QST_BossLair_MegaDemon = {      -- asset-name guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Beast = {          -- display-name guess (also matches BeastInIce via substring)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_BeastInIce = {     -- display-name (full) guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_IceBeast = {       -- guess (alternate word order)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Wendigo = {        -- guess (lore name for Beast in Ice)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Urivar = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('urivar') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Butcher = {   -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('butcher') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_Belial = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('belial') end,
        disable_when = reaper_kill_disable_when,
    },
}

local function normalize(entry)
    if type(entry) == 'string' then return { plugin = entry } end
    return entry
end

-- WarPigs is the master orchestrator: any plugin in quest_plugin_map is
-- bound to its trigger pattern. When no pattern matches, the plugin is
-- forcibly disabled — even if it was enabled outside WarPigs (e.g. by a
-- manual toggle, a stale state surviving a script reload, or a previous
-- WarPigs session whose owned[] table was lost).
local owned          = {}  -- plugin_name -> true (currently enabled by us)
local last_wanted    = {}  -- plugin_name -> true (was-wanted on previous tick)
local last_matches   = {}  -- pattern -> true (for verbose log only)
local pending_disable = {} -- plugin_name -> true (disable deferred by predicate)
local pending_disable_since = {}  -- plugin_name -> time when deferral started (for MAX_DISABLE_DEFER_SECONDS)
local last_disable_time     = {}  -- plugin_name -> time the disable actually fired (for TRANSITION_GAP_SECONDS gate)
local enable_blocked        = {}  -- plugin_name -> last gate-reason logged (suppresses repeat logs)
local was_off        = {}  -- plugin_name -> true (we believe it is currently off; suppresses repeated logs)
-- Same-activity continuation: when the same plugin re-matches within this
-- window after being disabled (e.g. back-to-back helltide WarPlans), cancel
-- the pending teleport so we don't fire warplan.teleport_to_activity() while
-- the plugin is already positioned in the right zone.
local last_disabled_plugin = nil
local last_disabled_at     = -math.huge
local last_disabled_reason = nil   -- quest pattern that triggered the last disable
local SAME_ACTIVITY_SECS   = 30.0
-- Track which trigger pattern was last used to enable each plugin. When the
-- matched pattern changes mid-run (e.g. ReaperPlugin running Zir but a new
-- Varshan WarPlan appears before Zir's kill+60s defer satisfies), re-fire
-- enable() so the plugin's enable hook switches to the new boss. Without this
-- the orchestrator owns the plugin under the OLD entry, the enable phase's
-- edge-trigger short-circuits, and the plugin keeps running stale context.
local last_enabled_reason   = {}  -- plugin_name -> pattern

local function log(msg)
    console.print('[WarPigs] ' .. msg)
end

-- Hard filter: only quests containing this substring can drive WarPigs.
-- Prevents accidental matches against bounty/story quests when a map key is
-- an unintentionally broad substring.
local QUEST_FILTER = 'WarPlans_QST'

local function get_active_quest_names()
    local names = {}
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return names end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        if ok_n and type(name) == 'string' and name:find(QUEST_FILTER, 1, true) then
            names[#names+1] = name
        end
    end
    return names
end

-- Best-effort check: is the plugin currently reporting itself enabled?
-- Returns true if a status surface says enabled=true. Returns false if no
-- status is exposed — in which case we fall back to our own owned[] table.
-- (Defined ABOVE plugin_enable so the resilient-enable code can reference it
--  — Lua locals aren't hoisted, so a forward reference would resolve to a
--  global nil at call time.)
local function is_plugin_on(plugin_name)
    local p = _G[plugin_name]
    if not p then return false end
    local status_fn = (type(p.status) == 'function' and p.status)
                   or (type(p.get_status) == 'function' and p.get_status)
                   or nil
    if status_fn then
        local ok, s = pcall(status_fn)
        if ok and type(s) == 'table' then return s.enabled == true end
    end
    return owned[plugin_name] == true
end

local function plugin_enable(entry, reason)
    local p = _G[entry.plugin]
    if not p then
        log('cannot enable ' .. entry.plugin .. ' — plugin not loaded')
        return
    end
    -- Wrap enable() in pcall: a misbehaving plugin (e.g. HR.enable referencing
    -- a missing GUI element) used to crash the orchestrator and trigger an
    -- infinite enable loop because owned[] never got set, so the edge check
    -- fired again next tick.
    local ok, err
    if entry.enable then
        ok, err = pcall(entry.enable, p)
    elseif type(p.enable) == 'function' then
        ok, err = pcall(p.enable)
    else
        log('cannot enable ' .. entry.plugin .. ' — no enable function')
        return
    end
    if not ok then
        log('enable() of ' .. entry.plugin .. ' threw: ' .. tostring(err))
    end
    -- Trust the plugin's status() over enable()'s exit path — partial enables
    -- (HR sets main_toggle, then crashes on missing keybind_toggle, but the
    -- plugin IS active because main_toggle is what status() reports) should
    -- count as enabled. Otherwise we'd keep retrying and crashing forever.
    if is_plugin_on(entry.plugin) then
        owned[entry.plugin] = true
        enable_blocked[entry.plugin] = nil
        last_enabled_reason[entry.plugin] = reason
        if entry.plugin == 'ReaperPlugin' then reset_reaper_kill_baseline() end
        log('enabled ' .. entry.plugin .. ' (' .. (reason or '?') .. ')')
    else
        log('enable of ' .. entry.plugin .. ' did not result in enabled status — will retry next tick')
    end
end

local function plugin_disable(entry)
    local p = _G[entry.plugin]
    if p then
        if entry.disable then
            entry.disable(p)
            log('disabled ' .. entry.plugin)
        elseif type(p.disable) == 'function' then
            p.disable()
            log('disabled ' .. entry.plugin)
        end
    end
    owned[entry.plugin] = nil
    last_disabled_reason = last_enabled_reason[entry.plugin]
    last_enabled_reason[entry.plugin] = nil
    last_disable_time[entry.plugin] = get_time_since_inject()
    last_disabled_plugin = entry.plugin
    last_disabled_at     = get_time_since_inject()
    -- Arm the teleport sequence for the NEXT activity. plugin_disable only
    -- fires after disable_when has satisfied (Reaper: kill+60s, Pit/WC: in
    -- town after Alfred salvage), so we're in a clean state to teleport.
    if settings.use_teleport_transition then
        teleport_pending = true
    end
end

-- Quest-dump mode: record every quest name+id we have ever seen and print
-- on first sighting. Lets us discover quest names for new activities without
-- needing the in-game overlay.
local seen_all = {}

local function dump_all_quests()
    local ok, quests = pcall(get_quests)
    if not ok or type(quests) ~= 'table' then return end
    for _, quest in ipairs(quests) do
        local ok_n, name = pcall(function() return quest:get_name() end)
        local ok_i, qid  = pcall(function() return quest:get_id() end)
        if ok_n and type(name) == 'string' and not seen_all[name] then
            seen_all[name] = true
            log(string.format('NEW QUEST: id=%s name=%s',
                ok_i and tostring(qid) or '?', name))
        end
    end
end

-- Returns true if any active quest name contains pattern (plain substring).
local function pattern_has_match(pattern, active_names)
    for _, name in ipairs(active_names) do
        if name:find(pattern, 1, true) then return true end
    end
    return false
end

-- Picks any map entry that targets plugin_name (used when disabling, so the
-- entry's custom disable hook is preserved even if the matching pattern has
-- already gone away).
local function find_entry_for_plugin(plugin_name)
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin == plugin_name then return e end
    end
    return { plugin = plugin_name }
end

-- Build the set of all distinct plugin globals referenced by the map. Used
-- by the state-based disable phase to enforce "off" on plugins WarPigs may
-- not have enabled itself (manual toggle, stale state from before reload).
local function get_managed_plugins()
    local set = {}
    for _, raw in pairs(orchestrator.quest_plugin_map) do
        local e = normalize(raw)
        if e.plugin then set[e.plugin] = e end
    end
    return set
end

-- Death-handling state: log "died" once on transition so respawn loops don't
-- spam.  Cleared the moment is_dead() goes false.
local was_dead          = false

-- Filler-pit state for `settings.run_pit_after_turnin`.  We arm the filler
-- once at least one WarPlans_QST_TurnIn_Rewards cycle has completed in this
-- session (matched → unmatched edge); after arming, whenever no real WarPlans
-- quest is active and no internal task is running, we inject ArkhamAsylumPlugin
-- into `wants` so pit fills the gap.  Cleared by `release_all`.
local TURN_IN_PATTERN          = 'WarPlans_QST_TurnIn_Rewards'
local turn_in_was_matched      = false
local had_turn_in_complete     = false
local pit_filler_active_logged = false   -- dedup the "filler engaged"/"yielded" logs

function orchestrator.tick()
    if settings.log_all_quests then dump_all_quests() end

    -- Death recovery — handle this before any other state, in case the player
    -- got killed during the Tab→click→settle teleport sequence (mob aggro on
    -- the way out of town, late-arriving boss attack, etc).  When dead we
    --   (1) abort any in-flight transition + re-arm so it restarts after
    --       respawn — the click was either lost or fired into a death screen,
    --   (2) call revive_at_checkpoint() each tick until it takes,
    --   (3) early-return so the orchestrator doesn't try to drive plugins
    --       while the player is on the death screen.
    local lp = get_local_player()
    if lp and lp:is_dead() then
        if not was_dead then
            log('player died — aborting any in-flight transition and reviving')
            was_dead = true
        end
        if teleport_transition.state ~= 'IDLE' then
            log('died mid-transition (state=' .. teleport_transition.state ..
                ') — re-arming teleport sequence for after respawn')
            teleport_transition.state           = 'IDLE'
            teleport_transition.started_at      = -math.huge
            teleport_transition.alfred_fired_at = nil
            teleport_transition.alfred_was_busy = false
            teleport_pending                    = true
            teleport_incoming_first_seen        = nil
            teleport_holding_logged             = false
        elseif settings.use_teleport_transition and not teleport_pending then
            -- Death outside an active transition still likely cancelled any
            -- in-progress in-game teleport channel (common when a mob hits
            -- you during the 3-5s teleport cast).  Arm the sequence so we
            -- redo the Tab+click after respawn lands us at the checkpoint.
            teleport_pending = true
        end
        revive_at_checkpoint()
        return
    end
    if was_dead then
        log('player revived — resuming orchestrator')
        was_dead = false
    end

    -- Always sample Reaper kill state, even when no boss quest is currently
    -- matched, so reaper_kill_disable_when() has accurate data the moment a
    -- boss quest disappears.
    reaper_kill_tick()

    local active_names = get_active_quest_names()
    local now          = get_time_since_inject()

    -- Compute which plugins should be enabled this tick, and drive any
    -- task entries directly. Matching is plain substring (string.find
    -- with plain=true).
    local wants          = {}  -- plugin_name -> entry to use for enable hook
    local matches        = {}  -- pattern -> true (verbose tracking)
    local matched_reason = {}  -- plugin_name -> first matching pattern (log)
    for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
        local entry   = normalize(raw_entry)
        local matched = pattern_has_match(pattern, active_names)
        if matched then matches[pattern] = true end

        if entry.task then
            -- Task entries are stateful internally; just signal active/idle.
            -- They do NOT participate in plugin ownership tracking.
            -- While our teleport sequence is mid-flight OR pending (waiting
            -- for settle/alfred prerequisites), hold the task in "inactive"
            -- so it doesn't fire its own teleport / actions and compete
            -- with the orchestrator-driven Tab+Click. Once the sequence
            -- fully completes (state IDLE AND pending cleared), the next
            -- tick passes matched=true and the task picks up normally
            -- (e.g. turn-in task transitions IDLE → APPROACH_NPC since the
            -- orchestrator just landed us in town).
            local task_matched = matched
            if matched
                and (teleport_transition.state ~= 'IDLE' or teleport_pending)
            then
                task_matched = false
            end
            local ok, err = pcall(entry.task.tick, task_matched)
            if not ok then log('task error (' .. pattern .. '): ' .. tostring(err)) end
        elseif matched and entry.plugin and not wants[entry.plugin] then
            wants[entry.plugin]          = entry
            matched_reason[entry.plugin] = pattern
        end
    end

    -- ── PREEMPTION ──────────────────────────────────────────────────────────
    -- When multiple activity plugins match at the same time, only the highest
    -- priority one stays wanted. Demoted plugins fall through to the disable
    -- phase (disable_when still applies, so an in-flight activity gets to
    -- wrap up before being cut). Priorities are static — see PLUGIN_PRIORITY.
    do
        local max_priority = -1
        local max_owner    = nil
        for plugin_name in pairs(wants) do
            local p = PLUGIN_PRIORITY[plugin_name] or 0
            if p > max_priority then
                max_priority = p
                max_owner    = plugin_name
            end
        end
        if max_priority > 0 then
            for plugin_name in pairs(wants) do
                local p = PLUGIN_PRIORITY[plugin_name] or 0
                if p < max_priority then
                    log(string.format('preempting %s (priority %d) — %s (priority %d) also matched',
                        plugin_name, p, max_owner, max_priority))
                    wants[plugin_name]          = nil
                    matched_reason[plugin_name] = nil
                end
            end
        end
    end

    if settings.verbose_logs then
        for pattern in pairs(matches) do
            if not last_matches[pattern] then log('trigger matched: ' .. pattern) end
        end
        for pattern in pairs(last_matches) do
            if not matches[pattern] then log('trigger unmatched: ' .. pattern) end
        end
    end

    -- ── RUN PIT AFTER TURN-IN ───────────────────────────────────────────────
    -- Track the turn-in pattern's matched→unmatched edge.  First time we see
    -- it, arm the pit filler for the rest of the session.  This way cold-start
    -- with no WarPlans quests doesn't auto-launch pit — the user has to have
    -- completed at least one WarPlans cycle first.
    local turn_in_matched_now = matches[TURN_IN_PATTERN] == true
    if turn_in_was_matched and not turn_in_matched_now and not had_turn_in_complete then
        had_turn_in_complete = true
        log('turn-in cycle completed — pit filler armed (run_pit_after_turnin)')
    end
    turn_in_was_matched = turn_in_matched_now

    -- Inject ArkhamAsylumPlugin as filler when:
    --   • setting on
    --   • turn-in has happened at least once this session
    --   • no real WarPlans plugin matched this tick (next(wants) == nil)
    --   • no internal task is currently active (turn-in mid-flight, etc.)
    -- Done AFTER preemption so a real WarPlans match always wins; the filler
    -- only ever fills empty gaps.  When a new WarPlans quest arrives next
    -- tick, the filler skips this block and the normal disable phase pulls
    -- ArkhamAsylumPlugin out (deferred by its in_town_disable_when).
    if settings.run_pit_after_turnin
        and had_turn_in_complete
        and next(wants) == nil
    then
        local any_task_active = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then any_task_active = true; break end
            end
        end
        if not any_task_active then
            local arkham_entry
            for _, raw in pairs(orchestrator.quest_plugin_map) do
                local entry = normalize(raw)
                if entry.plugin == 'ArkhamAsylumPlugin' then
                    arkham_entry = entry
                    break
                end
            end
            if arkham_entry then
                wants['ArkhamAsylumPlugin']          = arkham_entry
                matched_reason['ArkhamAsylumPlugin'] = 'filler:run_pit_after_turnin'
                -- Suppress the Tab+click teleport sequence for the filler:
                -- the click target the user configured points at a WarPlans
                -- quest icon and we have no quest active, so the click would
                -- land on stale/empty UI.  Arkham handles its own teleport-
                -- to-town-then-walk-to-pit-tower internally.
                if teleport_pending then
                    teleport_pending             = false
                    teleport_incoming_first_seen = nil
                    teleport_holding_logged      = false
                end
                if not pit_filler_active_logged then
                    log('pit filler engaged — no WarPlans quest active, enabling ArkhamAsylumPlugin (teleport sequence skipped)')
                    pit_filler_active_logged = true
                end
            end
        elseif pit_filler_active_logged then
            -- A task is now active (typically turn-in just appeared) — yield
            -- the filler back so future cycles re-log on re-engage.
            pit_filler_active_logged = false
        end
    elseif pit_filler_active_logged then
        -- A real WarPlans plugin matched, or setting was turned off — log the yield.
        log('pit filler yielding — WarPlans activity resumed')
        pit_filler_active_logged = false
    end

    -- ── COLD-START TELEPORT ─────────────────────────────────────────────────
    -- For the very first activity in a WarPigs session there's no preceding
    -- plugin_disable to arm the teleport, so detect "we have something to do
    -- AND have never run before" and fire the sequence here. Plugin →
    -- plugin and plugin → task transitions are armed inside plugin_disable
    -- (which only fires after disable_when satisfies — i.e. AFTER chests
    -- are looted, Alfred has salvaged, and the player is back in town).
    if settings.use_teleport_transition and not had_active_session then
        local has_any_plugin_want = next(wants) ~= nil
        local has_any_task_match  = false
        for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
            if matches[pattern] then
                local entry = normalize(raw_entry)
                if entry.task then has_any_task_match = true; break end
            end
        end
        if has_any_plugin_want or has_any_task_match then
            log('teleport queued — cold start (first activity of session)')
            teleport_pending = true
            had_active_session = true
        end
    elseif not had_active_session
        and (next(wants) ~= nil or next(matches) ~= nil)
    then
        -- Even with the option off, mark that we've seen activity so a later
        -- toggle of "Use teleport" doesn't retro-trigger a cold-start fire.
        had_active_session = true
    end

    -- ── DISABLE PHASE (runs first) ──────────────────────────────────────────
    -- Every managed plugin without a matching trigger must be off. Honors
    -- disable_when so post-quest wrap-up windows apply. After the deferral
    -- exceeds MAX_DISABLE_DEFER_SECONDS the disable is forced to keep a stuck
    -- activity from blocking the orchestrator forever.
    local managed = get_managed_plugins()
    for plugin_name, entry in pairs(managed) do
        if not wants[plugin_name] then
            -- Short-circuit: if the plugin is already off (self-disabled, e.g.
            -- Reaper "Nothing to farm — Stopping", or never on), there's no
            -- handoff to sequence. Clear deferral state and skip the gap so
            -- the next plugin can enable immediately. Without this guard,
            -- self-disabled plugins with strict disable_when predicates
            -- (Reaper kill+60s) would block enables forever.
            if not is_plugin_on(plugin_name) then
                if pending_disable[plugin_name] then
                    log('clearing stale pending_disable on ' .. plugin_name ..
                        ' — plugin is no longer reporting enabled')
                end
                -- If we believed we owned this plugin (= it was running under
                -- our enable), treat the self-disable as a real handoff and
                -- apply the transition gap. Plugins that were never owned by
                -- us (stale state from a prior session, manual toggle) skip
                -- the gap so cold-start cleanup is fast.
                if owned[plugin_name] then
                    log('detected self-disable of ' .. plugin_name ..
                        ' — applying ' .. TRANSITION_GAP_SECONDS .. 's transition gap')
                    last_disable_time[plugin_name] = now
                    -- Arm the teleport sequence even on self-disable. plugin_disable()
                    -- is the normal arm site, but it's bypassed here. Without this,
                    -- Reaper finishing its rotation (self-disables via main.lua) hands
                    -- off to the next plugin (e.g. HelltideRevamped) without the
                    -- Tab+click teleport — and if Reaper's own teleport_to_waypoint
                    -- silently failed, the next plugin enables in the boss room.
                    if settings.use_teleport_transition then
                        teleport_pending = true
                        log('arming teleport_pending (self-disable handoff)')
                    end
                end
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
                owned[plugin_name]                 = nil
                if not was_off[plugin_name] then was_off[plugin_name] = true end
            else
                local force = false
                local cap = entry.max_disable_defer_seconds or MAX_DISABLE_DEFER_SECONDS
                if pending_disable[plugin_name] and pending_disable_since[plugin_name]
                    and now - pending_disable_since[plugin_name] >= cap
                then
                    log(string.format('forcing disable of %s — exceeded disable defer cap (%ds)',
                        plugin_name, cap))
                    force = true
                end
                if not force and entry.disable_when and not entry.disable_when() then
                    if not pending_disable[plugin_name] then
                        log('deferring disable of ' .. plugin_name ..
                            ' — disable_when() not yet satisfied')
                        pending_disable[plugin_name]       = true
                        pending_disable_since[plugin_name] = now
                    end
                    -- Keep this plugin "wanted" (still owned by us) so the enable
                    -- phase doesn't try to re-enable it during the deferral.
                    wants[plugin_name] = entry
                else
                    pending_disable[plugin_name]       = nil
                    pending_disable_since[plugin_name] = nil
                    plugin_disable(entry)
                    was_off[plugin_name] = true
                end
            end
        else
            was_off[plugin_name] = nil  -- wanted again; reset suppress flag
            -- pending_disable can get stuck when the same plugin's quest
            -- re-matches before disable_when() satisfied (e.g. a new Horde
            -- WarPlan appears while still in BSK so the old disable deferred).
            -- Once disable_when() finally clears here (player exited BSK,
            -- landed in Caldeum), force the handoff: plugin_disable arms
            -- teleport_pending so warplan.teleport_to_activity() fires before
            -- the plugin is re-enabled next cycle.
            if pending_disable[plugin_name] and entry.disable_when and entry.disable_when() then
                log(plugin_name .. ': pending disable resolved while re-wanted — forcing handoff, arming teleport')
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
                plugin_disable(entry)
            end
        end
    end

    -- ── SAME-ACTIVITY CONTINUATION ──────────────────────────────────────────
    -- If the plugin we just disabled is the incoming activity (same quest
    -- pattern re-matched, e.g. back-to-back helltide WarPlans), skip the
    -- warplan teleport entirely. The player is already in the right zone and
    -- firing warplan.teleport_to_activity() would either do nothing (world/zone
    -- unchanged → retry loop) or fight with the plugin's own navigation.
    -- The transition gap (last_disable_time) still applies, giving the game
    -- state a beat to settle before the plugin re-enables.
    if teleport_pending
        and last_disabled_plugin
        and wants[last_disabled_plugin]
        and (now - last_disabled_at) <= SAME_ACTIVITY_SECS
        and matched_reason[last_disabled_plugin] == last_disabled_reason
    then
        log(string.format(
            '%s: same-activity continuation pattern=%s (%.1fs since disable) — cancelling teleport, re-enable in place',
            last_disabled_plugin, tostring(last_disabled_reason), now - last_disabled_at))
        teleport_pending             = false
        teleport_incoming_first_seen = nil
        teleport_holding_logged      = false
        last_disabled_plugin         = nil
        last_disabled_reason         = nil
    end

    -- ── TELEPORT TRANSITION (optional) ──────────────────────────────────────
    -- After an activity ends, call warplan.teleport_to_activity() and wait
    -- for the channel to settle before enabling the next plugin. We hold the
    -- call until the incoming quest has been visible for TELEPORT_INCOMING_SETTLE
    -- so warplan data reflects the new activity, and until Alfred finishes any
    -- loot/salvage work.

    -- Shared "fire warplan teleport (or skip)" used both by the IDLE→ready
    -- branch (when via-Temis preamble is unavailable) and by TEMIS_ALFRED on
    -- exit. Decides between three outcomes:
    --   * Task-only incoming (e.g. TurnIn_Rewards) — task drives its own nav,
    --     so we just release the gate (state stays IDLE).
    --   * arrived_when() already true — we're at the destination already, skip.
    --   * Otherwise — fire warplan.teleport_to_activity() and enter TELEPORTING.
    local function start_warplan_teleport(wants_, now_)
        local task_only_incoming = next(wants_) == nil
        local already_arrived = false
        for _, entry in pairs(wants_) do
            if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                already_arrived = true
                break
            end
        end
        if task_only_incoming then
            log('teleport skipped — incoming is task-only (handles own navigation)')
            teleport_transition.state = 'IDLE'
        elseif already_arrived then
            log('teleport skipped — quest actor present, already at destination')
            teleport_transition.state = 'IDLE'
        else
            teleport_transition.state      = 'TELEPORTING'
            teleport_transition.started_at = now_
            if _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                local snap_w = get_current_world()
                teleport_transition.snap_world = snap_w and snap_w:get_name()
                teleport_transition.snap_zone  = snap_w and snap_w:get_current_zone_name()
                warplan.teleport_to_activity()
                log(string.format(
                    'warplan.teleport_to_activity() called — world=%s zone=%s check_in=%.1fs',
                    tostring(teleport_transition.snap_world),
                    tostring(teleport_transition.snap_zone),
                    TELEPORT_CHECK_INTERVAL))
            else
                log('warplan.teleport_to_activity not available — skipping teleport')
                teleport_transition.state = 'IDLE'
            end
        end
    end

    if settings.use_teleport_transition
        and teleport_pending
        and teleport_transition.state == 'IDLE'
    then
        local has_incoming = next(wants) ~= nil
        if not has_incoming then
            for pattern, raw_entry in pairs(orchestrator.quest_plugin_map) do
                if matches[pattern] then
                    local entry = normalize(raw_entry)
                    if entry.task then has_incoming = true; break end
                end
            end
        end
        if not has_incoming then
            teleport_incoming_first_seen = nil
        elseif teleport_incoming_first_seen == nil then
            teleport_incoming_first_seen = now
            log(string.format('teleport: incoming activity matched, settling for %.1fs',
                TELEPORT_INCOMING_SETTLE))
        end
        local incoming_settled = teleport_incoming_first_seen
            and (now - teleport_incoming_first_seen) >= TELEPORT_INCOMING_SETTLE
        alfred_kick_if_needed()
        local alfred_done = alfred_idle()

        -- Helltide combat hold: when teleporting out of a helltide zone, the
        -- channel is interrupted by any incoming damage. Wait for the rotation
        -- plugin to clear nearby enemies before firing teleport_to_activity().
        -- Gated on has_helltide_buff() so town-to-town handoffs (Pit/Undercity)
        -- aren't affected — the player is in town, no enemies, no-op.
        local in_helltide_combat = has_helltide_buff() and enemies_near_player()

        local has_pending = next(pending_disable) ~= nil
        local ready = has_incoming and incoming_settled and alfred_done
            and not has_pending and not in_helltide_combat
        if not ready then
            local reason
            if not has_incoming then
                reason = 'no incoming activity yet'
            elseif has_pending then
                local pname = next(pending_disable)
                reason = 'waiting for ' .. tostring(pname) .. ' to finish (deferred disable)'
            elseif not alfred_done then
                reason = 'Alfred busy (loot/salvage in progress)'
            elseif in_helltide_combat then
                reason = 'in helltide combat — waiting for area to clear before teleport'
            else
                local left = TELEPORT_INCOMING_SETTLE - (now - teleport_incoming_first_seen)
                reason = string.format('settling incoming (%.1fs left)', left)
            end
            if teleport_holding_logged ~= reason then
                log('teleport holding — ' .. reason)
                teleport_holding_logged = reason
            end
        else
            teleport_pending             = false
            teleport_incoming_first_seen = nil
            teleport_holding_logged      = false
            -- Decide whether to begin the via-Temis-Alfred preamble. We always
            -- want to detour through Temis + run Alfred between activities, EXCEPT
            -- when teleport_to_waypoint isn't available on this host (then we
            -- jump straight to the warplan-teleport / skip decision below).
            local can_temis_detour = type(teleport_to_waypoint) == 'function'
            if can_temis_detour and in_temis() then
                -- Already in Temis: skip the waypoint hop and trigger Alfred now.
                if alfred_trigger_now() then
                    teleport_transition.state           = 'TEMIS_ALFRED'
                    teleport_transition.started_at      = now
                    teleport_transition.alfred_fired_at = now
                    teleport_transition.alfred_was_busy = false
                    log('via-Temis preamble: already in Temis — Alfred triggered')
                else
                    -- Alfred not loaded/enabled — go straight to the warplan
                    -- teleport / skip decision (start_warplan_teleport below).
                    log('via-Temis preamble: Alfred not loaded/enabled — skipping Alfred step')
                    start_warplan_teleport(wants, now)
                end
            elseif can_temis_detour then
                if (now - teleport_transition.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                    teleport_to_waypoint(TEMIS_WP)
                    teleport_transition.last_temis_tp = now
                end
                teleport_transition.state      = 'TO_TEMIS'
                teleport_transition.started_at = now
                log('via-Temis preamble: teleport_to_waypoint(Temis) sent')
            else
                -- No teleport_to_waypoint on this host — fall back to the original
                -- behaviour (warplan teleport directly or skip).
                start_warplan_teleport(wants, now)
            end
        end
    end
    if teleport_transition.state == 'TO_TEMIS' then
        if in_temis() then
            if alfred_trigger_now() then
                teleport_transition.state           = 'TEMIS_ALFRED'
                teleport_transition.started_at      = now
                teleport_transition.alfred_fired_at = now
                teleport_transition.alfred_was_busy = false
                log('via-Temis preamble: arrived in Temis — Alfred triggered')
            else
                log('via-Temis preamble: arrived in Temis, Alfred not loaded/enabled — proceeding to warplan teleport')
                start_warplan_teleport(wants, now)
            end
        elseif (now - teleport_transition.started_at) >= TEMIS_TELEPORT_TIMEOUT then
            if (now - teleport_transition.last_temis_tp) >= TEMIS_TELEPORT_DEBOUNCE then
                log('via-Temis preamble: TO_TEMIS timeout — retrying waypoint')
                teleport_to_waypoint(TEMIS_WP)
                teleport_transition.last_temis_tp = now
                teleport_transition.started_at    = now
            end
        end
    end
    if teleport_transition.state == 'TEMIS_ALFRED' then
        local elapsed   = now - teleport_transition.alfred_fired_at
        local busy_now  = not alfred_idle()
        if busy_now then teleport_transition.alfred_was_busy = true end
        local done = false
        if teleport_transition.alfred_was_busy and not busy_now then
            done = true
            log('via-Temis preamble: Alfred finished its work')
        elseif not teleport_transition.alfred_was_busy and elapsed >= ALFRED_GRACE_SECONDS then
            done = true
            log(string.format(
                'via-Temis preamble: Alfred had nothing to do (%.1fs grace elapsed)', elapsed))
        elseif elapsed >= ALFRED_MAX_SECONDS then
            done = true
            log(string.format(
                'via-Temis preamble: Alfred max wait (%.0fs) exceeded — proceeding anyway', elapsed))
        end
        if done then
            teleport_transition.alfred_fired_at = nil
            teleport_transition.alfred_was_busy = false
            start_warplan_teleport(wants, now)
        end
    end
    if teleport_transition.state == 'TELEPORTING' then
        -- If a deferred-disable is still pending, abort the teleport — the
        -- outgoing plugin (e.g. InfernalHordes) hasn't finished yet.
        local blocking_pending
        for p in pairs(pending_disable) do blocking_pending = p; break end
        if blocking_pending then
            log('teleport aborted — deferred disable pending for ' .. tostring(blocking_pending))
            teleport_transition.state      = 'IDLE'
            teleport_transition.snap_world = nil
            teleport_transition.snap_zone  = nil
            teleport_pending               = false
            teleport_incoming_first_seen   = nil
            teleport_holding_logged        = false
        elseif (now - teleport_transition.started_at) >= TELEPORT_CHECK_INTERVAL then
            local w         = get_current_world()
            local cur_world = w and w:get_name()
            local cur_zone  = w and w:get_current_zone_name()
            local changed   = cur_world ~= teleport_transition.snap_world
                           or cur_zone  ~= teleport_transition.snap_zone
            -- Secondary confirmation: quest actor visible means we arrived even
            -- if world/zone didn't change (warplan teleported us to the same
            -- zone the actor lives in, e.g. Pit/Undercity → Temis while already
            -- in Temis on a retry path).
            local arrived_now = false
            if not changed then
                for _, entry in pairs(wants) do
                    if type(entry.arrived_when) == 'function' and entry.arrived_when() then
                        arrived_now = true
                        break
                    end
                end
            end
            if changed or arrived_now then
                teleport_transition.state    = 'IDLE'
                teleport_transition.snap_world = nil
                teleport_transition.snap_zone  = nil
                log(string.format('teleport confirmed (%s world=%s zone=%s) — releasing enable gate',
                    arrived_now and 'arrived_when' or 'world/zone',
                    tostring(cur_world), tostring(cur_zone)))
            else
                teleport_transition.started_at = now
                if _G.warplan and type(warplan.teleport_to_activity) == 'function' then
                    warplan.teleport_to_activity()
                    log(string.format(
                        'teleport retry — world/zone unchanged (world=%s zone=%s), retrying in %.1fs',
                        tostring(cur_world), tostring(cur_zone), TELEPORT_CHECK_INTERVAL))
                else
                    teleport_transition.state    = 'IDLE'
                    teleport_transition.snap_world = nil
                    teleport_transition.snap_zone  = nil
                    log('teleport: warplan not available on retry — releasing gate')
                end
            end
        end
    end

    -- ── ENABLE GATE ─────────────────────────────────────────────────────────
    -- Don't start the next plugin while:
    --   (a) any plugin's disable is still deferred (outgoing not finished), or
    --   (b) we just disabled something within TRANSITION_GAP_SECONDS, or
    --   (c) teleport transition state machine is mid-sequence.
    -- This is the actual handoff sequencer — pairs with disable_when to give
    -- the game state a clean break between activities.
    local gate_reason = nil
    for p in pairs(pending_disable) do
        gate_reason = 'pending disable: ' .. p
        break
    end
    if not gate_reason and teleport_transition.state ~= 'IDLE' then
        gate_reason = 'teleport transition: ' .. teleport_transition.state
    end
    -- Also gate while teleport_pending is true but the sequence hasn't
    -- started yet (state still IDLE because we're waiting for incoming /
    -- settle / alfred_idle). Without this, cold-start enables fire BEFORE
    -- the Tab+click runs because the state-machine hasn't transitioned out
    -- of IDLE yet.
    if not gate_reason and teleport_pending then
        gate_reason = 'teleport pending (waiting for prerequisites)'
    end
    if not gate_reason then
        for p, t in pairs(last_disable_time) do
            local age = now - t
            if age < TRANSITION_GAP_SECONDS then
                gate_reason = string.format('post-disable cooldown: %s (%.1fs left)',
                    p, TRANSITION_GAP_SECONDS - age)
                break
            end
        end
    end

    -- ── ENABLE PHASE ────────────────────────────────────────────────────────
    -- Edge-trigger: enable plugins newly wanted, unless gated.
    -- ALSO re-fire enable when the matched pattern changes for an
    -- already-owned plugin: Reaper's run_boss('zir') vs run_boss('varshan')
    -- both target ReaperPlugin, so without re-firing the plugin would keep
    -- running the old boss while WarPigs thinks the handoff is done.
    for plugin_name, entry in pairs(wants) do
        local newly_wanted = not last_wanted[plugin_name] and not owned[plugin_name]
        local reason       = matched_reason[plugin_name]
        local reason_changed = owned[plugin_name]
            and reason
            and last_enabled_reason[plugin_name]
            and last_enabled_reason[plugin_name] ~= reason
        if newly_wanted or reason_changed then
            if gate_reason then
                if enable_blocked[plugin_name] ~= gate_reason then
                    log('deferring enable of ' .. plugin_name .. ' — ' .. gate_reason)
                    enable_blocked[plugin_name] = gate_reason
                end
            else
                if reason_changed then
                    log(string.format('re-enabling %s — pattern changed: %s -> %s',
                        plugin_name, last_enabled_reason[plugin_name], reason))
                    -- Clear the stale defer for the OLD pattern: the old
                    -- entry's disable_when (e.g. Reaper kill+60s for the
                    -- previous boss that was never actually killed) is no
                    -- longer relevant once we hand off to a new entry.
                    pending_disable[plugin_name]       = nil
                    pending_disable_since[plugin_name] = nil
                end
                plugin_enable(entry, reason)
            end
        end
    end

    -- last_wanted tracks "this plugin was actually owned at end of last tick".
    -- Plugins that were gated out of enabling must NOT be marked wanted, so
    -- the next tick's edge check fires the enable once the gate clears.
    last_wanted = {}
    for plugin_name in pairs(wants) do
        if owned[plugin_name] then last_wanted[plugin_name] = true end
    end
    last_matches = matches
end

-- Release every plugin we currently own. Called when WarPigs itself is
-- disabled so it doesn't leave a managed plugin running.
function orchestrator.release_all()
    for plugin_name in pairs(owned) do
        plugin_disable(find_entry_for_plugin(plugin_name))
    end
    last_wanted           = {}
    last_matches          = {}
    pending_disable       = {}
    pending_disable_since = {}
    last_disable_time     = {}
    enable_blocked        = {}
    last_enabled_reason   = {}
    teleport_pending             = false
    teleport_incoming_first_seen = nil
    teleport_holding_logged      = false
    teleport_transition.state           = 'IDLE'
    teleport_transition.started_at      = -math.huge
    teleport_transition.snap_world      = nil
    teleport_transition.snap_zone       = nil
    teleport_transition.last_temis_tp   = -math.huge
    teleport_transition.alfred_fired_at = nil
    teleport_transition.alfred_was_busy = false
    had_active_session       = false
    -- Filler-pit state — re-arm only after the next session sees a turn-in.
    turn_in_was_matched      = false
    had_turn_in_complete     = false
    pit_filler_active_logged = false
    recent_clicks            = {}
    last_disabled_plugin     = nil
    last_disabled_at         = -math.huge
    last_disabled_reason     = nil
end

function orchestrator.get_status_line()
    local names = {}
    for n in pairs(owned) do names[#names+1] = n end
    if #names > 0 then return 'WarPigs: managing ' .. table.concat(names, ', ') end
    -- Show active task state so "watching quests" doesn't mask turn-in work.
    for pattern in pairs(last_matches) do
        local raw_entry = orchestrator.quest_plugin_map[pattern]
        if raw_entry then
            local entry = normalize(raw_entry)
            if entry.task then
                local task_label = pattern:gsub('WarPlans_QST_', '')
                local task_state = type(entry.task.get_state) == 'function'
                    and entry.task.get_state() or '?'
                return 'WarPigs: task ' .. task_label .. ' [' .. task_state .. ']'
            end
        end
    end
    return 'WarPigs: watching quests'
end

return orchestrator
