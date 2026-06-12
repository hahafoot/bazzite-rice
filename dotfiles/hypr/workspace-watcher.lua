#!/usr/bin/env luajit
-- workspace-watcher.lua — listens to Hyprland's event socket and silently
-- moves matching windows to their genre workspace as they open.
--
-- Hyprland 0.54's windowrule block syntax silently accepts but never applies
-- any `workspace=`/`assign=`/`move=` field, so windowrule-based assignment
-- does not work in this build. This script is the substitute.
--
-- Edit RULES to add patterns, then reload with SUPER+SHIFT+R (the table is
-- read once at startup). Each entry is a Lua pattern matched against the new
-- window's class. Character classes like [Cc] and the ^/$ anchors work as in
-- regex; see https://www.lua.org/manual/5.1/manual.html#5.4.1 for the rest.
-- First matching rule wins (top to bottom).

local RULES = {
    -- ---- Desktop 1: terminal, file explorer, programming ----
    -- { "^kitty$", 1 },
    -- { "[Nn]autilus", 1 },
    { "^[Cc]ode$", 1 },
    { "[Kk]ate", 1 },
    { "[Tt]ext[Ee]ditor", 1 },
    { "[Ff]ile[Zz]illa", 1 },
    { "[Ff]ilelight", 1 },

    -- ---- Desktop 2: web browsers ----
    { "[Ff]irefox", 2 },
    { "[Vv]ivaldi", 2 },
    { "[Cc]hromium", 2 },
    { "[Cc]hrome", 2 },
    { "[Bb]rave", 2 },

    -- ---- Desktop 3: chat ----
    { "[Dd]iscord", 3 },
    { "[Vv]esktop", 3 },
    { "[Ss]lack", 3 },

    -- ---- Desktop 4: spotify + music ----
    { "[Ss]potify", 4 },

    -- ---- Desktop 5: steam / games ----
    { "[Ss]team", 5 },
    { "[Hh]eroic", 5 },
    { "[Ll]utris", 5 },
    { "[Pp]rism", 5 },
    { "[Pp]oly[Mm][Cc]", 5 },
    { "[Mm]inecraft", 5 },
    { "[Mm]odrinth", 5 },
    { "[Ll]unar[Cc]lient", 5 },
    { "^osu", 5 },
    { "[Ss]ober", 5 },
    { "[Dd]olphin%-[Ee]mu", 5 },
    { "[Pp]roton[Pp]lus", 5 },
    { "r2modman", 5 },
    { "[Bb]alatro", 5 },
    { "protontricks", 5 },
}

-- Skip our own cheatsheet window
local SKIP_PATTERN = "^keybinds%-cheatsheet$"

local function script_dir()
    local f = io.popen("readlink -f -- '" .. arg[0]:gsub("'", "'\\''") .. "' 2>/dev/null")
    local real = f and f:read("*l")
    if f then f:close() end
    return (real or arg[0]):match("(.*)/") or "."
end
local here = script_dir()
package.path = here .. "/lib/?.lua;" .. here .. "/../../hypr/lib/?.lua;" .. package.path

local posix = require("posix")
local hypr = require("hypr")

local sock_path = hypr.event_socket_path()
if not sock_path or not posix.exists(sock_path) then
    io.stderr:write("workspace-watcher: socket not found at " .. tostring(sock_path) .. "\n")
    os.exit(1)
end

local fd, err = posix.connect_unix(sock_path)
if not fd then
    io.stderr:write("workspace-watcher: connect failed: " .. tostring(err) .. "\n")
    os.exit(1)
end
local events = posix.stream(fd)

-- Hyprland event format:  openwindow>>ADDRESS,WORKSPACE,CLASS,TITLE
-- (TITLE may contain commas, so never split past the third field.)
local function handle(line)
    local addr, ws, class = line:match("^openwindow>>([^,]*),([^,]*),([^,]*)")
    if not addr then return end

    if class:find(SKIP_PATTERN) then return end

    for _, rule in ipairs(RULES) do
        if class:find(rule[1]) then
            local target = tostring(rule[2])
            -- Don't bother if it's already on the right workspace
            if ws ~= target then
                hypr.dispatch("movetoworkspacesilent", target .. ",address:0x" .. addr)
            end
            return
        end
    end
end

-- Event loop: must survive any weird event line, so each one is handled
-- under pcall. Exits when Hyprland closes the socket (session end/restart;
-- exec-once starts a fresh watcher with the new session).
while true do
    local line, lerr = events:readline(-1)
    if not line then
        if lerr ~= "timeout" then break end
    else
        pcall(handle, line)
    end
end
