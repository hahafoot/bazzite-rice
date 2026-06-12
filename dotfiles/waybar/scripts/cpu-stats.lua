#!/usr/bin/env luajit
-- Emits JSON for waybar with CPU usage %, temp, and a sparkline of recent
-- samples. Run by waybar every interval; state files in /tmp persist history.

local function script_dir()
    local f = io.popen("readlink -f -- '" .. arg[0]:gsub("'", "'\\''") .. "' 2>/dev/null")
    local real = f and f:read("*l")
    if f then f:close() end
    return (real or arg[0]):match("(.*)/") or "."
end
local here = script_dir()
package.path = here .. "/lib/?.lua;" .. here .. "/../../hypr/lib/?.lua;" .. package.path

local posix = require("posix")
local json = require("json")

local HIST = "/tmp/waybar-cpu-hist"
local LAST = "/tmp/waybar-cpu-last"
local N = 12 -- sparkline length (samples)

-- --- CPU usage from /proc/stat delta ---
local stat = posix.read_file("/proc/stat") or ""
local user, nice, sys, idle, iowait, irq, softirq =
    stat:match("^cpu%s+(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
user, nice, sys, idle, iowait, irq, softirq =
    tonumber(user) or 0, tonumber(nice) or 0, tonumber(sys) or 0,
    tonumber(idle) or 0, tonumber(iowait) or 0, tonumber(irq) or 0,
    tonumber(softirq) or 0

local cur_active = user + nice + sys + irq + softirq
local cur_total = cur_active + idle + iowait

local prev_active, prev_total = 0, 0
local last = posix.read_file(LAST)
if last then
    local a, t = last:match("(%d+) (%d+)")
    prev_active, prev_total = tonumber(a) or 0, tonumber(t) or 0
end
local lf = io.open(LAST, "w")
if lf then lf:write(cur_active, " ", cur_total, "\n"); lf:close() end

local usage = 0
if cur_total > prev_total then
    usage = math.floor(100 * (cur_active - prev_active) / (cur_total - prev_total))
end

-- --- CPU temp from k10temp hwmon (AMD) or coretemp (Intel) ---
local CPU_HWMON = { k10temp = true, coretemp = true, zenpower = true }
local temp = 0
local hwmons = {}
for _, ent in ipairs(posix.list_dir("/sys/class/hwmon") or {}) do
    hwmons[#hwmons + 1] = ent.name
end
table.sort(hwmons) -- match bash glob order
for _, hw in ipairs(hwmons) do
    local name = (posix.read_file("/sys/class/hwmon/" .. hw .. "/name") or ""):match("%S+")
    if name and CPU_HWMON[name] then
        local t = tonumber((posix.read_file("/sys/class/hwmon/" .. hw .. "/temp1_input") or ""):match("%d+"))
        if t then
            temp = math.floor(t / 1000)
            break
        end
    end
end

-- --- Sparkline history ---
local SPARK = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local tokens = {}
for tok in ((posix.read_file(HIST) or "") .. " " .. usage):gmatch("%S+") do
    tokens[#tokens + 1] = tok
end
while #tokens > N do table.remove(tokens, 1) end
local hf = io.open(HIST, "w")
if hf then hf:write(table.concat(tokens, " "), " \n"); hf:close() end

local graph = {}
for _, tok in ipairs(tokens) do
    local v = tonumber(tok) or 0
    local idx = math.floor(v * 8 / 100)
    if idx > 7 then idx = 7 end
    if idx < 0 then idx = 0 end
    graph[#graph + 1] = SPARK[idx + 1]
end
graph = table.concat(graph)

-- --- Class for CSS coloring ---
local class = "cpu"
if usage >= 80 or temp >= 80 then class = "cpu warning" end
if usage >= 95 or temp >= 90 then class = "cpu critical" end

print(json.encode({
    text = string.format(" %s  %d%% %d°C", graph, usage, temp),
    tooltip = string.format("CPU: %d%% usage\nTemp: %d°C\nLast %d samples", usage, temp, N),
    class = class,
}))
