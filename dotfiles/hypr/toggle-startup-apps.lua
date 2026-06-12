#!/usr/bin/env luajit
-- Rofi menu to manage entries in startup-apps.conf.
-- - The menu lists currently-enabled startup apps.
-- - Selecting one removes it from the conf AND kills the running process.
-- - Selecting "+ add new app..." opens a drun-style picker of installed apps
--   and appends the chosen one as a new `on` entry.

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

local CONF = hypr.config_dir() .. "/hypr/startup-apps.conf"
local ADD_ENTRY = "+ add new app..."

do
    local f = io.open(CONF, "r")
    if not f then
        hypr.notify("startup-apps", "config not found: " .. CONF)
        os.exit(1)
    end
    f:close()
end

local function rofi_menu(title, input)
    return proc.run_with_input({
        "rofi", "-dmenu", "-i", "-p", title, "-no-custom", "-show-icons",
        "-theme-str", "window { width: 480px; } listview { lines: 10; }",
    }, input)
end

--- Parse one .desktop file the way the old awk did: [Desktop Entry] section
--- only; Name/Exec/Icon keep the first occurrence; NoDisplay/Hidden hide it;
--- field codes (%U %f …) are stripped from Exec.
local function parse_desktop(path, id)
    local f = io.open(path, "r")
    if not f then return nil end
    local in_entry = false
    local typ, name, exec, icon, hide
    for line in f:lines() do
        if line:match("^%[Desktop Entry%]%s*$") then
            in_entry = true
        elseif line:match("^%[") then
            in_entry = false
        elseif in_entry then
            if line:match("^Type=") then typ = line:sub(6) end
            if not name and line:match("^Name=") then name = line:sub(6) end
            if not exec and line:match("^Exec=") then exec = line:sub(6) end
            if not icon and line:match("^Icon=") then icon = line:sub(6) end
            if line:match("^NoDisplay=true") or line:match("^Hidden=true") then hide = true end
        end
    end
    f:close()
    if typ == "Application" and not hide and exec and exec ~= "" and name and name ~= "" then
        exec = exec:gsub(" ?%%[UuFfick]", ""):gsub("[ \t]+$", "")
        return { id = id, name = name, exec = exec, icon = icon or "" }
    end
    return nil
end

--- All installed apps, deduped by desktop id (first dir wins), sorted
--- case-insensitively by name.
local function build_app_list()
    local home = os.getenv("HOME") or ""
    local dirs = {
        home .. "/.local/share/applications",
        home .. "/.local/share/flatpak/exports/share/applications",
        "/var/lib/flatpak/exports/share/applications",
        "/usr/local/share/applications",
        "/usr/share/applications",
    }
    local seen, apps = {}, {}
    for _, dir in ipairs(dirs) do
        local names = {}
        for _, ent in ipairs(posix.list_dir(dir) or {}) do
            if ent.name:match("%.desktop$") then names[#names + 1] = ent.name end
        end
        table.sort(names)
        for _, fname in ipairs(names) do
            local id = fname:gsub("%.desktop$", "")
            if not seen[id] then
                seen[id] = true
                local app = parse_desktop(dir .. "/" .. fname, id)
                if app then apps[#apps + 1] = app end
            end
        end
    end
    table.sort(apps, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    return apps
end

-- Map of lowercase desktop-file id -> icon name, used by resolve_icon.
local apps = build_app_list()
local ICON_BY_ID = {}
for _, app in ipairs(apps) do
    if app.icon ~= "" then ICON_BY_ID[app.id:lower()] = app.icon end
end

--- First non-flag token after "flatpak run", i.e. the flatpak app id.
local function flatpak_appid(cmd)
    local rest = cmd:match("flatpak%s+run%s+(.+)")
    if not rest then return nil end
    for tok in rest:gmatch("%S+") do
        if not tok:match("^%-%-") then return tok end
    end
    return nil
end

-- Best-effort icon name for a conf entry. Falls back through:
--   1) flatpak appid pulled out of the cmd
--   2) the conf name treated as a desktop id
--   3) the basename of the first cmd token
--   4) the conf name itself (rofi will still try the icon theme)
local function resolve_icon(name, cmd)
    local appid = flatpak_appid(cmd)
    if appid and ICON_BY_ID[appid:lower()] then return ICON_BY_ID[appid:lower()] end
    if ICON_BY_ID[name:lower()] then return ICON_BY_ID[name:lower()] end
    local first = cmd:match("^(%S+)") or ""
    first = (first:match("([^/]+)$") or first):lower()
    if ICON_BY_ID[first] then return ICON_BY_ID[first] end
    return name
end

local function conf_lines()
    local out = {}
    for line in io.lines(CONF) do out[#out + 1] = line end
    return out
end

local function parse_entry(line)
    if line == "" or line:sub(1, 1) == "#" then return nil end
    local state, name, cmd = line:match("^([^|]*)|([^|]*)|(.*)$")
    if not state then return nil end
    return state, name, cmd
end

local function build_menu()
    local rows = {}
    for _, line in ipairs(conf_lines()) do
        local state, name, cmd = parse_entry(line)
        if state == "on" and name ~= "" and cmd ~= "" then
            local status = proc.pgrep_if(name) and "running" or "stopped"
            rows[#rows + 1] = name .. "  (" .. status .. ")\0icon\31" .. resolve_icon(name, cmd)
        end
    end
    rows[#rows + 1] = ADD_ENTRY .. "\0icon\31list-add"
    return table.concat(rows, "\n") .. "\n"
end

local function add_new_app()
    if #apps == 0 then
        hypr.notify("startup-apps", "no applications found")
        return
    end

    -- rofi's icon protocol is "<display>\0icon\x1f<icon>\n"; -format 'i'
    -- returns the 0-based row index so apps that share a display name
    -- (e.g. duplicate Flatpak runtimes) stay unambiguous.
    local rows = {}
    for _, app in ipairs(apps) do
        rows[#rows + 1] = app.name .. "\0icon\31" .. app.icon
    end
    local out, code = proc.run_with_input(
        { "rofi", "-dmenu", "-i", "-p", "Apps", "-show-icons", "-format", "i" },
        table.concat(rows, "\n") .. "\n")
    if code ~= 0 then return end
    local idx = tonumber(out:match("%-?%d+"))
    if not idx then return end
    local app = apps[idx + 1]
    if not app then return end

    -- Derive a short identifier that doubles as the pgrep pattern.
    -- For "flatpak run <appid>" lines, prefer the appid (covers e.g.
    -- com.spotify.Client -> matches the running process via pgrep -if).
    local short = flatpak_appid(app.exec)
    short = (short or app.id):lower()

    if not short:match("^[A-Za-z0-9_.%-]+$") then
        hypr.notify("startup-apps", "invalid derived name: '" .. short .. "'")
        return
    end
    if app.exec:find("|", 1, true) then
        hypr.notify("startup-apps", "command contains '|', cannot store")
        return
    end
    for _, line in ipairs(conf_lines()) do
        local _, name = parse_entry(line)
        if name == short then
            hypr.notify("startup-apps", "'" .. short .. "' already in startup list")
            return
        end
    end

    -- Append through the symlink (the conf lives in the dotfiles repo).
    local f = io.open(CONF, "a")
    if not f then
        hypr.notify("startup-apps", "cannot write " .. CONF)
        return
    end
    f:write("on|", short, "|", app.exec, "\n")
    f:close()
    if not proc.pgrep_if(short) then
        proc.spawn_shell_detached(app.exec)
    end
    hypr.notify("startup-apps", "added & launched " .. short)
end

local selection, mcode = rofi_menu("startup apps", build_menu())
if mcode ~= 0 then os.exit(0) end
selection = selection:gsub("\n$", "")
if selection == "" then os.exit(0) end

if selection == ADD_ENTRY then
    add_new_app()
    os.exit(0)
end

local target = selection:match("^(%S+)")
if not target then os.exit(1) end

local kept, removed = {}, false
for _, line in ipairs(conf_lines()) do
    local _, name = parse_entry(line)
    if name == target then
        removed = true
    else
        kept[#kept + 1] = line
    end
end

if not removed then
    hypr.notify("startup-apps", "no entry named '" .. target .. "'")
    os.exit(1)
end

-- Rewrite in place THROUGH the symlink (truncate+write, never rename --
-- a rename would replace the symlink and orphan the repo file).
local f = io.open(CONF, "w")
if not f then
    hypr.notify("startup-apps", "cannot write " .. CONF)
    os.exit(1)
end
f:write(table.concat(kept, "\n"))
if #kept > 0 then f:write("\n") end
f:close()

proc.pkill_if(target)
hypr.notify("startup-apps", "removed " .. target)
