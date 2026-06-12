#!/usr/bin/env luajit
-- Launch the apps marked `on` in startup-apps.conf.
-- Invoked from hyprland.conf as `exec-once`.
--
-- Conf lines are `<state>|<name>|<command>`; `name` doubles as the
-- pgrep -if pattern (see comments in startup-apps.conf). The command is
-- everything after the second `|` and runs via `sh -c`, detached.

-- Locate the shared lib next to this script's real path (works from the
-- repo and through the ~/.config symlinks; covers hypr/ and waybar/scripts/).
local function script_dir()
    local f = io.popen("readlink -f -- '" .. arg[0]:gsub("'", "'\\''") .. "' 2>/dev/null")
    local real = f and f:read("*l")
    if f then f:close() end
    return (real or arg[0]):match("(.*)/") or "."
end
local here = script_dir()
package.path = here .. "/lib/?.lua;" .. here .. "/../../hypr/lib/?.lua;" .. package.path

local proc = require("proc")
local hypr = require("hypr")

local conf = hypr.config_dir() .. "/hypr/startup-apps.conf"
local f = io.open(conf, "r")
if not f then os.exit(0) end

for line in f:lines() do
    local state, name, cmd = line:match("^([^|]*)|([^|]*)|(.*)$")
    if state and state == "on" and name ~= "" and cmd ~= "" then
        -- Don't double-launch if something matching is already running.
        if not proc.pgrep_if(name) then
            proc.spawn_shell_detached(cmd)
        end
    end
end
f:close()
