local settings = require 'core.settings'

local orchestrator = {}

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
orchestrator.quest_plugin_map = {
    WarPlans_QST_ThePit = {
        plugin = 'ArkhamAsylumPlugin',
        -- Quest can vanish while still inside the pit (post-quest reward
        -- phase). Arkham needs to wrap up the glyphstone interaction and
        -- teleport back to town first. Defer disable until we're no longer
        -- in the PIT_Subzone.
        disable_when = function()
            local world = get_current_world()
            if not world then return false end
            local ok, zone = pcall(function() return world:get_current_zone_name() end)
            if not ok or type(zone) ~= 'string' then return false end
            return zone ~= 'PIT_Subzone'
        end,
    },

    WarPlans_QST_Helltide_TorturedGifts = 'HelltideRevampedPlugin',

    WarPlans_QST_Undercity              = 'WonderCityPlugin',

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
    },
    WarPlans_QST_BossLair_Harby = {     -- CONFIRMED (harbinger)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('harbinger') end,
    },
    WarPlans_QST_BossLair_Duriel = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('duriel') end,
    },
    WarPlans_QST_BossLair_Varshan = {   -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('varshan') end,
    },
    WarPlans_QST_BossLair_PenitentKnight = {  -- CONFIRMED (grigoire)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('grigoire') end,
    },
    WarPlans_QST_BossLair_S2VampireLord = {  -- guess (zir, asset name)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('zir') end,
    },
    WarPlans_QST_BossLair_MegaDemon = {      -- guess (beast in ice, asset name)
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('beast') end,
    },
    WarPlans_QST_BossLair_Urivar = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('urivar') end,
    },
    WarPlans_QST_BossLair_Butcher = {   -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('butcher') end,
    },
    WarPlans_QST_BossLair_Belial = {    -- guess
        plugin = 'ReaperPlugin',
        enable = function(p) p.run_boss('belial') end,
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
local was_off        = {}  -- plugin_name -> true (we believe it is currently off; suppresses repeated logs)

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

local function plugin_enable(entry, reason)
    local p = _G[entry.plugin]
    if not p then
        log('cannot enable ' .. entry.plugin .. ' — plugin not loaded')
        return
    end
    if entry.enable then
        entry.enable(p)
    elseif type(p.enable) == 'function' then
        p.enable()
    else
        log('cannot enable ' .. entry.plugin .. ' — no enable function')
        return
    end
    owned[entry.plugin] = true
    log('enabled ' .. entry.plugin .. ' (' .. (reason or '?') .. ')')
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

-- Best-effort check: is the plugin currently reporting itself enabled?
-- Returns true if a status surface says enabled=true. Returns false if no
-- status is exposed — in which case we fall back to our own owned[] table.
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

function orchestrator.tick()
    if settings.log_all_quests then dump_all_quests() end

    local active_names = get_active_quest_names()

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
            local ok, err = pcall(entry.task.tick, matched)
            if not ok then log('task error (' .. pattern .. '): ' .. tostring(err)) end
        elseif matched and entry.plugin and not wants[entry.plugin] then
            wants[entry.plugin]          = entry
            matched_reason[entry.plugin] = pattern
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

    -- Edge: enable plugins newly wanted (per-plugin, so multiple matching
    -- patterns don't double-enable).
    for plugin_name, entry in pairs(wants) do
        if not last_wanted[plugin_name] then
            plugin_enable(entry, matched_reason[plugin_name])
        end
    end

    -- State-based disable: every managed plugin without a matching trigger
    -- must be off. This catches plugins that were enabled outside WarPigs
    -- (manual toggle, persisted across script reload, prior session). Honors
    -- disable_when so post-quest wrap-up windows still apply.
    local managed = get_managed_plugins()
    for plugin_name, entry in pairs(managed) do
        if not wants[plugin_name] then
            if entry.disable_when and not entry.disable_when() then
                if not pending_disable[plugin_name] then
                    log('deferring disable of ' .. plugin_name ..
                        ' — disable_when() not yet satisfied')
                    pending_disable[plugin_name] = true
                end
                wants[plugin_name] = entry  -- keep wanted; prevents edge re-trigger
            else
                pending_disable[plugin_name] = nil
                if is_plugin_on(plugin_name) then
                    plugin_disable(entry)
                    was_off[plugin_name] = true
                else
                    -- Already off. Clear stale ownership without logging.
                    owned[plugin_name] = nil
                    if not was_off[plugin_name] then was_off[plugin_name] = true end
                end
            end
        else
            was_off[plugin_name] = nil  -- wanted again; reset suppress flag
        end
    end

    last_wanted  = {}
    for k in pairs(wants) do last_wanted[k] = true end
    last_matches = matches
end

-- Release every plugin we currently own. Called when WarPigs itself is
-- disabled so it doesn't leave a managed plugin running.
function orchestrator.release_all()
    for plugin_name in pairs(owned) do
        plugin_disable(find_entry_for_plugin(plugin_name))
    end
    last_wanted     = {}
    last_matches    = {}
    pending_disable = {}
end

function orchestrator.get_status_line()
    local names = {}
    for n in pairs(owned) do names[#names+1] = n end
    if #names == 0 then return 'WarPigs: watching quests' end
    return 'WarPigs: managing ' .. table.concat(names, ', ')
end

return orchestrator
