-- Performance monitoring module for HelltideRevamped
-- Tracks timing and event counts, prints a summary every `interval` seconds.
-- Usage:
--   perf.start("my_func") / perf.stop("my_func")  -- time a section
--   perf.inc("my_event")                           -- count an event (no timing)
--   perf.report()                                  -- call every frame; fires every interval seconds

local perf = {
    enabled  = true,
    data     = {},   -- timed entries:  { total, count, max, min }
    counters = {},   -- event counters: integer
    starts   = {},   -- open start times
    max_meta = {},   -- name -> meta string captured at the new-max moment
    last_report = -1,
    interval = 5,
    first    = true,
    -- Spike threshold: any stop() above this prints inline so cause is co-located in the log
    spike_ms = 30,
}

function perf.start(name)
    if not perf.enabled then return end
    perf.starts[name] = os.clock()
end

-- stop(name [, meta]) — meta is a short string recorded only when this call sets a new max,
-- so non-peak metas are discarded.  Spikes above spike_ms are also printed inline.
function perf.stop(name, meta)
    if not perf.enabled then return end
    local s = perf.starts[name]
    if not s then return end
    local elapsed = os.clock() - s
    perf.starts[name] = nil
    local d = perf.data[name]
    if not d then
        d = { total = 0, count = 0, max = 0, min = math.huge }
        perf.data[name] = d
    end
    d.total = d.total + elapsed
    d.count = d.count + 1
    if elapsed > d.max then
        d.max = elapsed
        if meta ~= nil then perf.max_meta[name] = meta end
    end
    if elapsed < d.min then d.min = elapsed end
    if elapsed * 1000 >= perf.spike_ms then
        console.print(string.format("[HR SPIKE] %s %.1fms%s",
            name, elapsed * 1000,
            meta ~= nil and (' ' .. meta) or ''))
    end
end

function perf.inc(name)
    if not perf.enabled then return end
    perf.counters[name] = (perf.counters[name] or 0) + 1
end

-- Set peak metadata directly (kept until the next report cycle resets it).
function perf.set_meta(name, meta)
    if not perf.enabled then return end
    perf.max_meta[name] = meta
end

function perf.report()
    if not perf.enabled then return end
    local now = os.clock()
    if now - perf.last_report < perf.interval then return end
    local win = (perf.last_report >= 0) and (now - perf.last_report) or perf.interval
    perf.last_report = now

    if perf.first then
        console.print("[HR PERF] Performance logging active — summary every " .. perf.interval .. "s")
        perf.first   = false
        perf.data     = {}
        perf.counters = {}
        return
    end

    console.print(string.format("[HR PERF] ============ %.1fs window ============", win))

    -- Timed sections — sorted by total cost descending
    local timed = {}
    for k, d in pairs(perf.data) do
        if d.count > 0 then timed[#timed + 1] = { k = k, d = d } end
    end
    table.sort(timed, function(a, b) return a.d.total > b.d.total end)

    if #timed > 0 then
        console.print("  [TIMING]  name                             calls    /s    avg(ms)  max(ms) total(ms)")
        for _, e in ipairs(timed) do
            local d = e.d
            local meta = perf.max_meta[e.k]
            console.print(string.format("  %-34s  %5d  %5.1f  %7.3f  %7.3f  %8.2f%s",
                e.k, d.count, d.count / win,
                d.total / d.count * 1000,
                d.max * 1000,
                d.total * 1000,
                meta ~= nil and ('  peak{' .. meta .. '}') or ''))
        end
    end

    -- Event counters — sorted alphabetically
    local cnts = {}
    for k, v in pairs(perf.counters) do cnts[#cnts + 1] = { k = k, v = v } end
    table.sort(cnts, function(a, b) return a.k < b.k end)
    if #cnts > 0 then
        local parts = {}
        for _, e in ipairs(cnts) do
            parts[#parts + 1] = string.format("%s=%d(%.1f/s)", e.k, e.v, e.v / win)
        end
        console.print("  [EVENTS]  " .. table.concat(parts, "   "))
    end

    if #timed == 0 and #cnts == 0 then
        console.print("  (no data this window)")
    end

    -- Reset for next window
    perf.data     = {}
    perf.counters = {}
    perf.max_meta = {}
end

return perf
