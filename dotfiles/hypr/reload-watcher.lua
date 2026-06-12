#!/usr/bin/env luajit
-- Restart workspace-watcher.lua so it picks up edits to its RULES table.
-- (The watcher reads RULES once at startup; the running one is stale until
-- restarted.)
--
-- Lives in its own script so the killer's own argv doesn't contain the
-- string "workspace-watcher" -- if it did, pkill -f would suicide.
-- The pattern is extensionless so it also reaps a stale bash-era
-- workspace-watcher.sh left over from before the Lua port.

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

-- Anchor on the interpreter so an editor with workspace-watcher.lua in its
-- argv (vim/nano during the documented edit-then-reload flow) never matches.
proc.pkill_f("luajit .*workspace-watcher")
proc.pkill_f("bash .*workspace-watcher.sh")
posix.sleep(0.3)
hypr.dispatch("exec", "~/.config/hypr/workspace-watcher.lua")
hypr.notify("Workspace watcher", "Reloaded", { timeout_ms = 1500 })
