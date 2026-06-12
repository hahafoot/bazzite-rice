#!/usr/bin/env luajit
-- Emits JSON for waybar with AMD GPU usage %, temp, and a sparkline.
-- Auto-picks the dGPU (largest VRAM) if more than one amdgpu card is present.

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

local HIST = "/tmp/waybar-gpu-hist"
local N = 12

local function read_num(path)
    return tonumber((posix.read_file(path) or ""):match("-?%d+"))
end

-- --- Find the discrete AMD GPU (largest VRAM) ---
local cards = {}
for _, ent in ipairs(posix.list_dir("/sys/class/drm") or {}) do
    if ent.name:match("^card%d+$") then cards[#cards + 1] = ent.name end
end
table.sort(cards)

local gpu_dir, gpu_card
local best_vram = 0
for _, card in ipairs(cards) do
    local d = "/sys/class/drm/" .. card .. "/device"
    local drv = posix.readlink(d .. "/driver")
    drv = drv and drv:match("([^/]+)$")
    if drv == "amdgpu" and posix.exists(d .. "/gpu_busy_percent") then
        local vram = read_num(d .. "/mem_info_vram_total") or 0
        if vram > best_vram then
            best_vram = vram
            gpu_dir, gpu_card = d, card
        end
    end
end

if not gpu_dir then
    print(json.encode({ text = "󰢮 n/a", tooltip = "no amdgpu device found", class = "gpu" }))
    os.exit(0)
end

local usage = read_num(gpu_dir .. "/gpu_busy_percent") or 0

-- Temp from hwmon under the device.
local temp = 0
local hwmons = {}
for _, ent in ipairs(posix.list_dir(gpu_dir .. "/hwmon") or {}) do
    hwmons[#hwmons + 1] = ent.name
end
table.sort(hwmons)
for _, hw in ipairs(hwmons) do
    local t = read_num(gpu_dir .. "/hwmon/" .. hw .. "/temp1_input")
    if t then
        temp = math.floor(t / 1000)
        break
    end
end

-- VRAM use for the tooltip.
local vram_used = read_num(gpu_dir .. "/mem_info_vram_used") or 0
local vram_pct = 0
if best_vram > 0 then vram_pct = math.floor(vram_used * 100 / best_vram) end
local vram_gb = string.format("%.1f", best_vram / 1073741824)

-- --- Sparkline ---
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

local class = "gpu"
if usage >= 80 or temp >= 80 then class = "gpu warning" end
if usage >= 95 or temp >= 90 then class = "gpu critical" end

print(json.encode({
    text = string.format("󰢮 %s  %d%% %d°C", graph, usage, temp),
    tooltip = string.format("GPU: %d%% busy\nTemp: %d°C\nVRAM: %d%% of %s GB\nDevice: %s",
                            usage, temp, vram_pct, vram_gb, gpu_card),
    class = class,
}))
