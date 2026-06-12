#!/usr/bin/env luajit
-- Adjust external-monitor brightness over DDC/CI (this is a desktop -- no
-- internal backlight, so brightnessctl is useless; ddcutil drives the panels).
-- Usage: brightness.lua up|down [step]   (step is a percentage, default 10)

local function script_dir()
    local f = io.popen("readlink -f -- '" .. arg[0]:gsub("'", "'\\''") .. "' 2>/dev/null")
    local real = f and f:read("*l")
    if f then f:close() end
    return (real or arg[0]):match("(.*)/") or "."
end
local here = script_dir()
package.path = here .. "/lib/?.lua;" .. here .. "/../../hypr/lib/?.lua;" .. package.path

local posix = require("posix")
local proc = require("proc")
local hypr = require("hypr")

local dir = arg[1]
local step = tonumber(arg[2]) or 10

local sign
if dir == "up" then
    sign = 1
elseif dir == "down" then
    sign = -1
else
    io.stderr:write("usage: " .. arg[0] .. " up|down [step]\n")
    os.exit(1)
end
local delta = sign * step

local state_dir = hypr.state_dir()
local cache = state_dir .. "/ddc-displays"
local sigfile = state_dir .. "/ddc-displays.sig"

-- Serialize. ddcutil talks raw I2C, which is NOT concurrency-safe: overlapping
-- calls (e.g. from key autorepeat while held) wedge the bus and freeze the
-- session. A non-blocking flock drops this press if an adjustment is already
-- in flight, which also rate-limits a held key to one step at a time.
-- (The fd stays open for the process lifetime; exit releases the lock.)
local lock_fd = posix.flock_try(state_dir .. "/brightness.lock")
if not lock_fd then os.exit(0) end

-- Cache the display list. `ddcutil detect` scans every I2C bus and is far too
-- slow (1-2s) to run on every keypress -- detect once, then reuse. But key the
-- cache to the set of currently-connected outputs (read instantly from DRM
-- sysfs, no I2C): if a monitor was asleep/off when detect last ran it would be
-- missing from the cache and never get adjusted, so re-detect whenever the
-- connected set changes (monitor wakes, is replugged, etc.).
local connected = {}
for _, ent in ipairs(posix.list_dir("/sys/class/drm") or {}) do
    local status_path = "/sys/class/drm/" .. ent.name .. "/status"
    local status = posix.read_file(status_path)
    if status and status:match("^connected\n?$") then
        connected[#connected + 1] = status_path
    end
end
table.sort(connected)
local sig = #connected > 0 and (table.concat(connected, " ") .. " ") or ""

local function read_cache_displays()
    local out = {}
    for line in (posix.read_file(cache) or ""):gmatch("[^\n]+") do
        out[#out + 1] = line
    end
    return out
end

if not posix.read_file(cache) or posix.read_file(cache) == ""
    or sig ~= (posix.read_file(sigfile) or "") then
    local detect = proc.run({ "ddcutil", "detect", "--terse" })
    local nums = {}
    for line in detect:gmatch("[^\n]+") do
        local n = line:match("^Display (%d+)")
        if n then nums[#nums + 1] = n end
    end
    local f = io.open(cache, "w")
    if f then
        for _, n in ipairs(nums) do f:write(n, "\n") end
        f:close()
    end
    local sf = io.open(sigfile, "w")
    if sf then sf:write(sig); sf:close() end
    -- Display numbers may have shifted -- drop tracked levels so they re-init
    -- from the panels' actual brightness on this run.
    for _, ent in ipairs(posix.list_dir(state_dir) or {}) do
        if ent.name:match("^level%-") then
            posix.unlink(state_dir .. "/" .. ent.name)
        end
    end
end

local displays = read_cache_displays()
if #displays == 0 then
    posix.unlink(cache)
    posix.unlink(sigfile)
    hypr.notify("No DDC displays found", nil, { app = "brightness" })
    os.exit(1)
end

-- ddcutil's default inter-op I2C delays make each call ~1s. .2 cuts a write to
-- ~0.65s -- the practical floor here (.15 is no faster) -- and still lands every
-- write on both panels. Lower with care: too small and setvcp silently fails.
local DC = { "--sleep-multiplier", ".2" }

local function getvcp_level(d)
    local argv = { "ddcutil", "--display", d }
    for _, a in ipairs(DC) do argv[#argv + 1] = a end
    argv[#argv + 1] = "getvcp"; argv[#argv + 1] = "10"; argv[#argv + 1] = "--terse"
    local out = proc.run(argv)
    -- Terse format: "VCP 10 C <current> <max>" -> 4th field.
    local cur = out:match("^%S+%s+%S+%s+%S+%s+(%S+)")
    return tonumber(cur) or 50
end

-- Responsiveness: instead of a relative setvcp + a read-back for the OSD (three
-- serial DDC round-trips per press), track each monitor's level in a state file
-- and set absolute values. The new % is then known with zero extra DDC traffic,
-- and the per-monitor writes run in PARALLEL -- safe because each display is on
-- its own I2C bus (the earlier freeze was many procs contending one bus; the
-- flock above still prevents overlapping *invocations*). Levels re-init from the
-- panel via one getvcp only when a level file is missing (first run / re-detect).
local pids = {}
local osd
for _, d in ipairs(displays) do
    local lf = state_dir .. "/level-" .. d
    local content = posix.read_file(lf)
    local cur
    if content and content ~= "" then
        cur = tonumber(content:match("-?%d+")) or 0
    else
        cur = getvcp_level(d)
    end
    local new = cur + delta
    if new < 0 then new = 0 end
    if new > 100 then new = 100 end
    local f = io.open(lf, "w")
    if f then f:write(tostring(new)); f:close() end
    osd = osd or new
    local argv = { "ddcutil", "--display", d }
    for _, a in ipairs(DC) do argv[#argv + 1] = a end
    argv[#argv + 1] = "--noverify"
    argv[#argv + 1] = "setvcp"; argv[#argv + 1] = "10"; argv[#argv + 1] = tostring(new)
    local pid = proc.spawn_quiet(argv)
    if pid then pids[#pids + 1] = pid end
end
for _, pid in ipairs(pids) do
    proc.wait(pid)
end

hypr.notify("Brightness " .. (osd or 0) .. "%", nil, {
    app = "brightness",
    hints = { "string:x-canonical-private-synchronous:brightness",
              "int:value:" .. (osd or 0) },
})
