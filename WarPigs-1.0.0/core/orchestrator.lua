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
-- next quest), and then wait for the channel + arrival before releasing
-- the enable gate. Timings are deliberate: the Tab open animation is fast
-- but the click must land after the UI has settled, and the quest teleport
-- channel runs ~3-5s (matches teleport_to_waypoint).
local TELEPORT_TAB_DELAY    = 0.5
-- 1.5s after Tab before clicking. The Quests / Map panel fade-in can run
-- past 1s on slower frames and clicking before the target is rendered
-- silently no-ops (the click lands on whatever's underneath the cursor in
-- the world). Bumped from 1.0s to 1.5s based on user report of "Tab opens
-- but nothing clicks".
local TELEPORT_CLICK_DELAY  = 1.5
local TELEPORT_SETTLE_DELAY = 5.0
local TELEPORT_VK_TAB       = 0x09

-- Predicates that gate the START of the teleport sequence. teleport_pending
-- can be armed long before any of these pass; we hold the sequence until
-- they're all true so we don't Tab/click while the player is still mid-
-- loot-or-salvage cleanup.
--   * in_town_attribute(): out of dungeon, no monsters.
--   * Alfred idle: AlfredTheButlerPlugin (if loaded) reports all_task_done
--     so an in-progress salvage/sell/restock isn't interrupted.
local function in_town_attribute_for_teleport()
    local lp = get_local_player()
    if not lp then return false end
    if not _G.attributes or _G.attributes.PLAYER_IN_TOWN_LEVEL_AREA == nil then
        return true  -- attribute missing — fail-open so we don't deadlock
    end
    local ok, val = pcall(function()
        return lp:get_attribute(attributes.PLAYER_IN_TOWN_LEVEL_AREA) == 1
    end)
    return ok and val == true
end

local function alfred_idle()
    local alfred = _G.AlfredTheButlerPlugin
    if not alfred or type(alfred.get_status) ~= 'function' then return true end
    local ok, s = pcall(alfred.get_status)
    if not ok or type(s) ~= 'table' then return true end
    -- Not enabled = nothing to wait on. Enabled but all_task_done = idle.
    if not s.enabled then return true end
    return s.all_task_done == true
end

local function is_safe_to_teleport()
    return in_town_attribute_for_teleport() and alfred_idle()
end

local teleport_transition = {
    state      = 'IDLE',  -- IDLE | WAIT_TAB | WAIT_CLICK | WAIT_SETTLE
    started_at = -math.huge,
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
-- Suppresses repeat "teleport holding — in_town=… alfred_idle=…" logs while
-- the sequence is waiting for its safety predicates. Cleared the moment we
-- transition out of IDLE.
local teleport_holding_logged = false
-- Tracks whether ANY plugin/task has been active under this WarPigs session.
-- False until the first activity starts; switched true on first activation
-- so cold-start fires exactly once. Reset by release_all().
local had_active_session = false

-- Recent click marker log for the on-screen "where did the bot just click?"
-- overlay. Same shape WonderCity uses: each entry fades over CLICK_FADE
-- seconds. Cap to 8 entries to bound memory in long sessions.
local CLICK_FADE   = 6.0
local recent_clicks = {}

local function record_click(label, sx, sy, kind)
    recent_clicks[#recent_clicks + 1] = {
        label = label, x = sx, y = sy, kind = kind or 'left',
        t = get_time_since_inject(),
    }
    while #recent_clicks > 8 do table.remove(recent_clicks, 1) end
end

function orchestrator.get_recent_clicks()
    local now = get_time_since_inject()
    while recent_clicks[1] and (now - recent_clicks[1].t) > CLICK_FADE do
        table.remove(recent_clicks, 1)
    end
    return recent_clicks, CLICK_FADE
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
    },

    -- Helltide handoff: no disable_when. The quest disappearing means the
    -- helltide event ended (or the bot left it), and there's no in-zone
    -- wrap-up worth waiting for — HR can be cut immediately. The standard
    -- TRANSITION_GAP_SECONDS (5s) gap still applies via last_disable_time
    -- before the next plugin enables.
    WarPlans_QST_Helltide_TorturedGifts = 'HelltideRevampedPlugin',

    WarPlans_QST_Undercity = {
        plugin       = 'WonderCityPlugin',
        disable_when = in_town_disable_when,  -- wait for the Kurast/Temis return
    },

    -- Confirmed seen in logs as WarPlans_QST_InfernalHordes_BSK; substring
    -- match covers any tier/variant suffix.
    --
    -- Quest vanishes when the wave bosses die, but HordeDev still has to
    -- open chests and pick up loot. Defer disable until we either leave the
    -- BSK world (S05_BSK_Prototype02) or 60s elapse as a safety cap.
    WarPlans_QST_InfernalHordes = {
        plugin = 'InfernalHordesPlugin',
        disable_when = (function()
            local defer_start
            return function()
                local world = get_current_world()
                local name
                if world then
                    local ok, n = pcall(function() return world:get_name() end)
                    if ok then name = n end
                end
                local in_bsk = type(name) == 'string'
                    and name:find('BSK', 1, true) ~= nil
                if not in_bsk then
                    defer_start = nil
                    return true
                end
                defer_start = defer_start or get_time_since_inject()
                if get_time_since_inject() - defer_start >= 60 then
                    defer_start = nil
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
    WarPlans_QST_BossLair_Beast = {          -- display-name guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
        disable_when = reaper_kill_disable_when,
    },
    WarPlans_QST_BossLair_BeastInIce = {     -- display-name (full) guess
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
    last_enabled_reason[entry.plugin] = nil
    last_disable_time[entry.plugin] = get_time_since_inject()
    -- Arm the teleport sequence for the NEXT activity. plugin_disable only
    -- fires after disable_when has satisfied, so by here:
    --   * Reaper has waited kill+60s (chest open + loot pickup time)
    --   * Pit/WC have landed in town (Alfred salvage already complete)
    -- That means we're in a clean state and free to Tab → click → teleport
    -- without losing loot. Sequence actually starts inside orchestrator.tick
    -- once a new wanted plugin or matched task entry exists.
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

function orchestrator.tick()
    if settings.log_all_quests then dump_all_quests() end

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
            -- While our teleport sequence is mid-flight, hold the task in
            -- "inactive" so it doesn't fire its own teleport / actions and
            -- compete with the orchestrator-driven Tab+Click. Once the
            -- sequence settles back to IDLE, the next tick passes
            -- matched=true and the task picks up normally (e.g. turn-in
            -- task transitions IDLE → APPROACH_NPC since the orchestrator
            -- just landed us in town).
            local task_matched = matched
            if matched and teleport_transition.state ~= 'IDLE' then
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
                end
                pending_disable[plugin_name]       = nil
                pending_disable_since[plugin_name] = nil
                owned[plugin_name]                 = nil
                if not was_off[plugin_name] then was_off[plugin_name] = true end
            else
                local force = false
                if pending_disable[plugin_name] and pending_disable_since[plugin_name]
                    and now - pending_disable_since[plugin_name] >= MAX_DISABLE_DEFER_SECONDS
                then
                    log(string.format('forcing disable of %s — exceeded MAX_DISABLE_DEFER_SECONDS (%ds)',
                        plugin_name, MAX_DISABLE_DEFER_SECONDS))
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
        end
    end

    -- ── TELEPORT TRANSITION (optional) ──────────────────────────────────────
    -- A new activity (plugin or task) just transitioned from unmatched →
    -- matched (see "TELEPORT TRIGGER" block above). Run the Tab+Click
    -- sequence and gate the enable + task tick until it settles. Stages are
    -- time-driven so we don't need to poll game state for "map open" /
    -- "teleport landing".
    if settings.use_teleport_transition
        and teleport_pending
        and teleport_transition.state == 'IDLE'
    then
        if not is_safe_to_teleport() then
            -- Hold pending: previous activity hasn't fully wrapped up yet
            -- (still in dungeon collecting chest loot, or Alfred is mid-
            -- salvage). teleport_pending stays true, we'll re-check next
            -- tick. Log once when we first start holding so the user can
            -- see *why* nothing is happening.
            if not teleport_holding_logged then
                local in_town = in_town_attribute_for_teleport()
                local alfred_done = alfred_idle()
                log(string.format(
                    'teleport holding — in_town=%s alfred_idle=%s (waiting for cleanup)',
                    tostring(in_town), tostring(alfred_done)))
                teleport_holding_logged = true
            end
        else
            teleport_pending          = false
            teleport_holding_logged   = false
            teleport_transition.state      = 'WAIT_TAB'
            teleport_transition.started_at = now
            log(string.format(
                'teleport transition started — Tab in %.1fs, click target=(%d, %d), settle=%.1fs',
                TELEPORT_TAB_DELAY,
                settings.teleport_click_x or 0,
                settings.teleport_click_y or 0,
                TELEPORT_SETTLE_DELAY))
        end
    end
    if teleport_transition.state == 'WAIT_TAB' then
        if (now - teleport_transition.started_at) >= TELEPORT_TAB_DELAY then
            if utility and type(utility.send_key_press) == 'function' then
                utility.send_key_press(TELEPORT_VK_TAB)
                log('teleport transition: Tab pressed')
            else
                log('teleport transition: utility.send_key_press unavailable — skipping Tab')
            end
            teleport_transition.state      = 'WAIT_CLICK'
            teleport_transition.started_at = now
        end
    elseif teleport_transition.state == 'WAIT_CLICK' then
        if (now - teleport_transition.started_at) >= TELEPORT_CLICK_DELAY then
            local x = settings.teleport_click_x or 0
            local y = settings.teleport_click_y or 0
            local have_util = utility and type(utility.send_mouse_click) == 'function'
            if x > 0 and y > 0 and have_util then
                -- Move cursor onto the target before clicking. Some panels
                -- ignore a click whose preceding mouse-position event landed
                -- elsewhere; an explicit move forces the cursor to register
                -- at (x, y) before the button event.
                if type(utility.send_mouse_move) == 'function' then
                    utility.send_mouse_move(x, y)
                end
                utility.send_mouse_click(x, y)
                record_click('Teleport', x, y, 'left')
                log(string.format('teleport transition: CLICKED (%d, %d)', x, y))
            elseif not have_util then
                log('teleport transition: SKIP click — utility.send_mouse_click missing')
            else
                log(string.format(
                    'teleport transition: SKIP click — coords (%d,%d) are zero. ' ..
                    'Set them via the GUI sliders or hover the in-game target ' ..
                    'and press the Capture cursor key (default F5).',
                    x, y))
            end
            teleport_transition.state      = 'WAIT_SETTLE'
            teleport_transition.started_at = now
        end
    elseif teleport_transition.state == 'WAIT_SETTLE' then
        if (now - teleport_transition.started_at) >= TELEPORT_SETTLE_DELAY then
            log('teleport transition: settled — releasing enable gate')
            teleport_transition.state = 'IDLE'
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
    teleport_pending      = false
    teleport_holding_logged = false
    teleport_transition.state      = 'IDLE'
    teleport_transition.started_at = -math.huge
    had_active_session    = false
    recent_clicks         = {}
end

function orchestrator.get_status_line()
    local names = {}
    for n in pairs(owned) do names[#names+1] = n end
    if #names == 0 then return 'WarPigs: watching quests' end
    return 'WarPigs: managing ' .. table.concat(names, ', ')
end

return orchestrator
