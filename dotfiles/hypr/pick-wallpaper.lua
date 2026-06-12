#!/usr/bin/env luajit
-- Terminal wallpaper picker. Opens fzf with previews and applies the selection
-- via cycle-wallpaper.lua. Designed to be launched from Hyprland (e.g. SUPER+W)
-- so it spawns its own kitty window. Videos get an on-demand cached thumbnail
-- (first hover extracts a frame with ffmpeg; subsequent hovers reuse it).
-- TAB inside the picker cycles the filter mode: all -> images -> videos -> all.
--
-- Usage:
--   pick-wallpaper.lua                  # spawn a kitty window running the picker
--   pick-wallpaper.lua --inner [MON]    # the actual fzf loop (run inside kitty)
--   pick-wallpaper.lua --preview REL    # render a single preview row (for fzf)
--   pick-wallpaper.lua --list STATE     # emit filter-mode-filtered relpaths
--   pick-wallpaper.lua --rotate STATE   # advance the filter mode in STATE file
--   pick-wallpaper.lua --prompt STATE   # emit prompt string for current mode

local function script_dir_and_real()
    local f = io.popen("readlink -f -- '" .. arg[0]:gsub("'", "'\\''") .. "' 2>/dev/null")
    local real = f and f:read("*l")
    if f then f:close() end
    real = real or arg[0]
    return real:match("(.*)/") or ".", real
end
local here, SCRIPT_REAL = script_dir_and_real()
package.path = here .. "/lib/?.lua;" .. here .. "/../../hypr/lib/?.lua;" .. package.path

local posix = require("posix")
local proc = require("proc")
local fs = require("fs")

local REPO_ROOT = here:match("(.*)/[^/]+/[^/]+$") or "/"
local WALL_DIR = os.getenv("WALLPAPER_DIR") or (REPO_ROOT .. "/wallpapers")
local CYCLE = here .. "/cycle-wallpaper.lua"
local THUMB_DIR = (os.getenv("XDG_CACHE_HOME") or ((os.getenv("HOME") or "") .. "/.cache"))
    .. "/wallpaper-picker/thumbs"

-- Section dividers used in the "all" view. They start with a marker that no
-- real filename can begin with, so the selection handler can skip them.
local IMG_HEADER = "── images ──"
local VID_HEADER = "── videos ──"

local IMG_EXTS = { png = true, jpg = true, jpeg = true, webp = true, jxl = true }
-- Gifs live in the "videos" bucket since they're animated.
local VID_EXTS = { mp4 = true, webm = true, mkv = true, mov = true, gif = true }
local PRUNE = { __MACOSX = true }

-- Emit absolute wallpaper paths (with optional dividers) filtered by mode.
local function find_walls(mode)
    if mode == "images" then
        return fs.walk_files(WALL_DIR, IMG_EXTS, PRUNE, "._")
    elseif mode == "videos" then
        return fs.walk_files(WALL_DIR, VID_EXTS, PRUNE, "._")
    end
    local out = {}
    local imgs = fs.walk_files(WALL_DIR, IMG_EXTS, PRUNE, "._")
    local vids = fs.walk_files(WALL_DIR, VID_EXTS, PRUNE, "._")
    if #imgs > 0 then
        out[#out + 1] = IMG_HEADER
        for _, p in ipairs(imgs) do out[#out + 1] = p end
    end
    if #vids > 0 then
        out[#out + 1] = VID_HEADER
        for _, p in ipairs(vids) do out[#out + 1] = p end
    end
    return out
end

-- Mode-state helpers driven by a small state file. fzf's TAB bind rotates the
-- mode and reloads the list / prompt.
local function read_mode(path)
    local v = (posix.read_file(path or "") or ""):gsub("%s+$", "")
    if v == "images" or v == "videos" or v == "all" then return v end
    return "all"
end

local function mode_prompt(mode)
    if mode == "images" then return "images> " end
    if mode == "videos" then return "videos> " end
    return "all> "
end

local function is_video_file(path)
    local e = fs.ext(path)
    return e == "mp4" or e == "webm" or e == "mkv" or e == "mov"
end

local function mtime_of(path)
    local out, code = proc.run({ "stat", "-c", "%Y", "--", path })
    if code ~= 0 then return "0" end
    return out:match("%d+") or "0"
end

local function sha1_path_mtime(path)
    local out = proc.run({ "sh", "-c", 'printf "%s\\0%s" "$1" "$2" | sha1sum', "sh",
                           path, mtime_of(path) })
    return out:match("^(%x+)") or "0"
end

local function file_nonempty(path)
    local f = io.open(path, "r")
    if not f then return false end
    local byte = f:read(1)
    f:close()
    return byte ~= nil
end

-- POSIX single-quote escaping for the shell command strings fzf executes.
local function sq(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

---------------------------------------------------------------- subcmds --

local cmd = arg[1]

if cmd == "--list" then
    local mode = read_mode(arg[2])
    local prefix = WALL_DIR .. "/"
    for _, p in ipairs(find_walls(mode)) do
        if p:sub(1, #prefix) == prefix then
            print(p:sub(#prefix + 1))
        else
            -- Divider line; pass through unmodified.
            print(p)
        end
    end
    os.exit(0)
end

if cmd == "--rotate" then
    local state = arg[2]
    local cur = read_mode(state)
    local next_mode = (cur == "all" and "images") or (cur == "images" and "videos") or "all"
    if state then
        local f = io.open(state, "w")
        if f then f:write(next_mode, "\n"); f:close() end
    end
    os.exit(0)
end

if cmd == "--prompt" then
    io.write(mode_prompt(read_mode(arg[2])))
    os.exit(0)
end

-- fzf invokes this once per highlighted row to render the right-side preview.
-- For videos we extract a frame to a cache (keyed by absolute path + mtime) so
-- the second hover is instant.
if cmd == "--preview" then
    local rel = arg[2] or ""
    local src = WALL_DIR .. "/" .. rel
    -- Section dividers and missing files: print a hint and exit cleanly.
    local probe = io.open(src, "r")
    if not probe then
        print("\n  (section divider -- press TAB to filter, or pick a file)")
        os.exit(0)
    end
    probe:close()
    if is_video_file(src) then
        posix.mkdir_p(THUMB_DIR)
        local thumb = THUMB_DIR .. "/" .. sha1_path_mtime(src) .. ".jpg"
        if not file_nonempty(thumb) then
            -- Grab a frame ~10% into the clip, scaled to 1280px wide.
            local out = proc.run({ "ffprobe", "-v", "error", "-show_entries",
                                   "format=duration", "-of", "csv=p=0", src })
            local dur = tonumber(out:match("[%d.]+")) or 10
            local ts = string.format("%.2f", dur > 0 and dur * 0.1 or 1)
            proc.call({ "ffmpeg", "-hide_banner", "-loglevel", "error",
                        "-ss", ts, "-i", src,
                        "-frames:v", "1", "-vf", "scale=1280:-1", "-q:v", "4", thumb })
        end
        if file_nonempty(thumb) then src = thumb end
    end
    proc.exec({ "kitten", "icat", "--clear", "--transfer-mode=memory",
                "--unicode-placeholder", "--stdin=no",
                "--place=" .. (os.getenv("FZF_PREVIEW_COLUMNS") or "80") .. "x"
                    .. (os.getenv("FZF_PREVIEW_LINES") or "24") .. "@0x0",
                "--", src })
end

-- Re-launch ourselves inside a kitty window for the actual UI.
if cmd ~= "--inner" then
    proc.exec({ "kitty",
                "--class=wallpaper-picker",
                "--title=Wallpaper Picker",
                "-o", "initial_window_width=120c",
                "-o", "initial_window_height=32c",
                "--", SCRIPT_REAL, "--inner", arg[1] or "" })
end

------------------------------------------------------------------ inner --

local target_mon = arg[2] or ""

-- Per-run state file holds the current filter mode (all/images/videos). fzf's
-- TAB bind mutates it then triggers reload+prompt refresh.
local state_file = proc.run({ "mktemp", "-t", "wallpaper-picker-mode.XXXXXX" }):gsub("%s+$", "")
if state_file == "" then os.exit(1) end
do
    local f = io.open(state_file, "w")
    if f then f:write("all\n"); f:close() end
end
local function cleanup()
    posix.unlink(state_file)
end

local all_walls = find_walls("all")
-- Bail early if there's nothing to show at all.
if #all_walls == 0 then
    io.stderr:write("no wallpapers in " .. WALL_DIR .. "\n")
    posix.sleep(2)
    cleanup()
    os.exit(1)
end

local header = "TAB: filter (all/images/videos)   ENTER: span across monitors   ALT-1: DP-1   ALT-2: DP-2   ESC: cancel"
if target_mon ~= "" then
    header = "TAB: filter (all/images/videos)   ENTER: apply to " .. target_mon .. "   ESC: cancel"
end

local script_q = sq(SCRIPT_REAL)
local state_q = sq(state_file)
local list_cmd = script_q .. " --list " .. state_q
local rotate_cmd = script_q .. " --rotate " .. state_q
local prompt_cmd = script_q .. " --prompt " .. state_q
-- Each preview row delegates to `SCRIPT_REAL --preview <rel>`, which handles
-- both images (passed straight to kitten icat) and videos (lazy ffmpeg thumb).
local preview_cmd = script_q .. " --preview {}"

local list_lines = {}
do
    local prefix = WALL_DIR .. "/"
    for _, p in ipairs(all_walls) do
        list_lines[#list_lines + 1] = (p:sub(1, #prefix) == prefix) and p:sub(#prefix + 1) or p
    end
end

local selection, code = proc.run_with_input({
    "fzf",
    "--prompt", mode_prompt("all"),
    "--header", header,
    "--preview", preview_cmd,
    "--preview-window", "right,60%,border-left",
    "--expect", "alt-1,alt-2",
    "--bind", "tab:execute-silent(" .. rotate_cmd .. ")+reload(" .. list_cmd
        .. ")+transform-prompt(" .. prompt_cmd .. ")",
    "--reverse",
    "--no-mouse",
}, table.concat(list_lines, "\n") .. "\n")
cleanup()
if code ~= 0 then os.exit(0) end

local key, pick = selection:match("^([^\n]*)\n([^\n]*)")
if not pick or pick == "" then os.exit(0) end
-- Picking a section divider is a no-op.
if pick == IMG_HEADER or pick == VID_HEADER then os.exit(0) end

local abs = WALL_DIR .. "/" .. pick

-- Videos (and animated GIFs) take a moment to start: ffprobe, mpvpaper spawn,
-- IPC sync wait. Detach so the picker window closes immediately on pick.
local is_vid = VID_EXTS[fs.ext(abs)] or false

local function run_cycle(...)
    if is_vid then
        proc.spawn_detached({ CYCLE, ... })
    else
        proc.call({ CYCLE, ... })
    end
end

if key == "alt-1" then
    run_cycle("pick", abs, "DP-1")
elseif key == "alt-2" then
    run_cycle("pick", abs, "DP-2")
elseif target_mon ~= "" then
    run_cycle("pick", abs, target_mon)
else
    run_cycle("span", abs)
end
