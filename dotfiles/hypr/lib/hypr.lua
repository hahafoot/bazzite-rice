-- hypr.lua — Hyprland + rice-environment helpers shared by the Lua scripts:
-- hyprctl wrappers, the event socket path, XDG dirs, repo-root resolution,
-- and best-effort desktop notifications.

local posix = require("posix")
local proc = require("proc")
local json = require("json")

local hypr = {}

local HOME = os.getenv("HOME") or "/root"

function hypr.config_dir()
    return (os.getenv("XDG_CONFIG_HOME") or HOME .. "/.config")
end

--- Per-runtime state dir (created on first use), per repo conventions.
function hypr.state_dir()
    local d = (os.getenv("XDG_STATE_HOME") or HOME .. "/.local/state") .. "/hypr"
    posix.mkdir_p(d)
    return d
end

function hypr.cache_dir()
    return (os.getenv("XDG_CACHE_HOME") or HOME .. "/.cache")
end

--- Resolve symlinks: realpath of a file (falls back to the input).
function hypr.realpath(path)
    local out, code = proc.run({ "readlink", "-f", "--", path })
    out = out:gsub("\n$", "")
    if code == 0 and out ~= "" then return out end
    return path
end

--- Repo root, resolved from a script's own (symlinked) location.
--- Scripts live at <repo>/dotfiles/hypr/ or <repo>/dotfiles/waybar/scripts/,
--- both exactly two/three levels below the root — pass levels accordingly.
--- Don't hardcode ~/Documents/bazzite-rice: users may clone elsewhere.
function hypr.repo_root(script_path, levels)
    local real = hypr.realpath(script_path)
    local dir = real:match("(.*)/") or "."
    for _ = 1, (levels or 2) do
        dir = dir:match("(.*)/") or "/"
    end
    return dir
end

--- hyprctl with argv semantics. Returns stdout, exitcode.
function hypr.ctl(...)
    return proc.run({ "hyprctl", ... })
end

--- hyprctl -j … decoded from JSON; nil on failure.
function hypr.ctl_json(...)
    local out, code = proc.run({ "hyprctl", "-j", ... })
    if code ~= 0 or out == "" then return nil end
    local ok, v = pcall(json.decode, out)
    if not ok then return nil end
    return v
end

--- List of monitor objects (hyprctl monitors -j); {} on failure.
function hypr.monitors()
    return hypr.ctl_json("monitors") or {}
end

function hypr.monitor_names()
    local names = {}
    for _, m in ipairs(hypr.monitors()) do
        names[#names + 1] = m.name
    end
    return names
end

function hypr.dispatch(...)
    return proc.call({ "hyprctl", "dispatch", ... })
end

--- Path of Hyprland's event socket (.socket2.sock); nil outside a session.
function hypr.event_socket_path()
    local runtime = os.getenv("XDG_RUNTIME_DIR")
    local sig = os.getenv("HYPRLAND_INSTANCE_SIGNATURE")
    if not runtime or not sig then return nil end
    return runtime .. "/hypr/" .. sig .. "/.socket2.sock"
end

--- Best-effort notify-send; never throws, never blocks the caller's logic.
--- opts: { urgency = "critical", timeout_ms = 2000, app = "brightness",
---         hints = { "string:x-...:y", "int:value:42" } }
function hypr.notify(title, body, opts)
    opts = opts or {}
    local argv = { "notify-send" }
    if opts.urgency then
        argv[#argv + 1] = "-u"; argv[#argv + 1] = opts.urgency
    end
    if opts.timeout_ms then
        argv[#argv + 1] = "-t"; argv[#argv + 1] = tostring(opts.timeout_ms)
    end
    if opts.app then
        argv[#argv + 1] = "-a"; argv[#argv + 1] = opts.app
    end
    for _, h in ipairs(opts.hints or {}) do
        argv[#argv + 1] = "-h"; argv[#argv + 1] = h
    end
    argv[#argv + 1] = title
    if body then argv[#argv + 1] = body end
    proc.call(argv)
end

return hypr
