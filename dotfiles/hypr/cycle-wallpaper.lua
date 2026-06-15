#!/usr/bin/env luajit
-- Cycle through wallpapers in <repo>/wallpapers and apply them per monitor.
--   - Images (.png .jpg .jpeg .webp .jxl .gif)  -> swww
--   - Videos (.mp4 .webm .mkv .mov)             -> mpvpaper (live wallpaper)
-- Each monitor has its own index, so DP-1 and DP-2 cycle independently.
--
-- Note: animated gifs are treated as images and animate fine in swww. Only
-- real video containers go through mpvpaper -- except when spanning, where
-- gifs route through mpvpaper too (see is_video below).
--
-- Usage:
--   cycle-wallpaper.lua                    # advance every monitor
--   cycle-wallpaper.lua next [MONITOR]
--   cycle-wallpaper.lua prev [MONITOR]
--   cycle-wallpaper.lua init               # re-apply each monitor's saved wallpaper
--   cycle-wallpaper.lua pick PATH [MON]    # set a specific wallpaper
--   cycle-wallpaper.lua span PATH          # stretch one image across all monitors

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
local fs = require("fs")
local hypr = require("hypr")

-- here = <repo>/dotfiles/hypr -> repo root is two levels up. Resolved from
-- our own real path so clones anywhere work (never hardcode the repo path).
local REPO_ROOT = here:match("(.*)/[^/]+/[^/]+$") or "/"
local WALL_DIR = os.getenv("WALLPAPER_DIR") or (REPO_ROOT .. "/wallpapers")
local STATE_DIR = hypr.state_dir()

-- Records the path of the currently-spanned wallpaper (if any) so `init` after
-- a Hyprland restart restores the span instead of degrading it to independent
-- per-monitor crops. Cleared whenever a per-monitor wallpaper is applied.
local SPAN_STATE = STATE_DIR .. "/wallpaper-span"
local function clear_span() posix.unlink(SPAN_STATE) end

local IMAGE_EXTS = { png = true, jpg = true, jpeg = true, webp = true, jxl = true }
local VIDEO_EXTS = { mp4 = true, webm = true, mkv = true, mov = true }
local ALL_EXTS = {}
for e in pairs(IMAGE_EXTS) do ALL_EXTS[e] = true end
for e in pairs(VIDEO_EXTS) do ALL_EXTS[e] = true end
ALL_EXTS.gif = true

-- Real videos always go to mpvpaper. GIFs go to swww (it animates them fine
-- on a single output) EXCEPT when spanning: swww's per-monitor animation
-- workers run on independent clocks and drift out of sync, while parallel mpv
-- processes started together stay frame-aligned -- so a spanned GIF routes
-- through mpvpaper instead. Callers pass spanning=true only on the span path.
local function is_video(path, spanning)
    local e = fs.ext(path)
    return VIDEO_EXTS[e] or (spanning and e == "gif") or false
end

local walls = fs.walk_files(WALL_DIR, ALL_EXTS, { __MACOSX = true }, "._")
if #walls == 0 then
    hypr.notify("Wallpaper", "No images/videos in " .. WALL_DIR, { urgency = "critical" })
    io.stderr:write("no wallpapers found in " .. WALL_DIR .. "\n")
    os.exit(1)
end

-- Reverse map for "which index is this wallpaper". State files keep the
-- 0-based indices the bash version wrote, so existing state carries over.
local wall_index0 = {}
for i, w in ipairs(walls) do wall_index0[w] = i - 1 end

-- Integer division truncating toward zero, like bash $(( / )).
local function idiv(a, b)
    local q = a / b
    return q >= 0 and math.floor(q) or math.ceil(q)
end

local function round(x)
    return math.floor(x + 0.5)
end

local function file_nonempty(path) -- bash [[ -s ]]
    local f = io.open(path, "r")
    if not f then return false end
    local byte = f:read(1)
    f:close()
    return byte ~= nil
end

local function mtime_of(path)
    local out, code = proc.run({ "stat", "-c", "%Y", "--", path })
    if code ~= 0 then return "0" end
    return out:match("%d+") or "0"
end

-- sha1 of parts joined by NUL, byte-identical to the bash printf '%s\0%s'
-- pipelines so existing frame/span caches stay valid across the Lua port.
local function sha1_key(fmt, ...)
    local cmd = { "sh", "-c", 'printf \'' .. fmt .. '\' "$@" | sha1sum', "sh" }
    for _, a in ipairs({ ... }) do cmd[#cmd + 1] = tostring(a) end
    local out = proc.run(cmd)
    return out:match("^(%x+)") or "0"
end

local function save_index(mon, wall)
    local idx0 = wall_index0[wall]
    if idx0 then
        posix.write_file(STATE_DIR .. "/wallpaper-index-" .. mon, idx0 .. "\n")
    end
end

local function ensure_swww_running()
    if proc.call({ "pgrep", "-x", "swww-daemon" }) == 0 then return end
    proc.spawn_detached({ "swww-daemon" })
    -- Wait until the daemon's socket is ready (swww commands hang otherwise).
    for _ = 1, 20 do
        if proc.call({ "swww", "query" }) == 0 then return end
        posix.sleep(0.1)
    end
end

local function stop_mpvpaper_for(mon)
    local pidfile = STATE_DIR .. "/mpvpaper-" .. mon .. ".pid"
    local pid = tonumber((posix.read_file(pidfile) or ""):match("%d+"))
    if pid then
        -- Only kill if the PID is still mpvpaper: PIDs get recycled, and the
        -- pidfile can outlive the process across reboots/crashes.
        local comm = (posix.read_file("/proc/" .. pid .. "/comm") or ""):gsub("%s+$", "")
        if comm == "mpvpaper" then proc.kill(pid) end
    end
    posix.unlink(pidfile)
    proc.pkill_f("mpvpaper.* " .. mon .. " ")
end

local SWWW_FADE = { "--transition-type", "any", "--transition-fps", "60", "--transition-duration", "1" }

local function swww_img(mon, wall, extra)
    local argv = { "swww", "img", "--outputs", mon }
    for _, a in ipairs(extra or {}) do argv[#argv + 1] = a end
    for _, a in ipairs(SWWW_FADE) do argv[#argv + 1] = a end
    argv[#argv + 1] = wall
    proc.call(argv)
end

local function apply_image(mon, wall)
    clear_span()
    stop_mpvpaper_for(mon)
    ensure_swww_running()
    -- Subtle fade between wallpapers. Tweak to taste.
    swww_img(mon, wall)
end

-- Wait (up to ~2.5s) for an mpv IPC socket to accept a connection. mpv only
-- creates the socket once it's loaded the file and decoded the first frame,
-- so this is our signal that mpvpaper is parked on frame 0 and the surface
-- holds it. Returns a connected fd (caller closes), or nil.
local function wait_mpv_socket(sock)
    for _ = 1, 50 do
        local fd = posix.connect_unix(sock)
        if fd then return fd end
        posix.sleep(0.05)
    end
    return nil
end

-- Send `set_property pause false` over mpv's JSON IPC. Best-effort.
local function mpv_unpause(fd)
    if fd then
        posix.write_fd(fd, '{"command":["set_property","pause",false]}\n')
        posix.close(fd)
    end
end

-- Best-effort prune of a regenerable cache dir: drop files not accessed in
-- 30+ days so the spanned-crop and first-frame caches don't grow without
-- bound (they had reached hundreds of MB). Anything pruned is rebuilt on
-- demand. atime (under the default relatime) keeps daily-used crops alive.
local function prune_cache(dir)
    proc.call({ "find", dir, "-type", "f", "-atime", "+30", "-delete" })
end

-- Extract (and cache) the first frame of a video file. Returns the cache
-- path on success, nil on failure. Used to play a swww transition before
-- mpvpaper claims the surface so videos don't pop in cold.
local function extract_video_frame(wall)
    if not proc.have("ffmpeg") then return nil end
    local fdir = STATE_DIR .. "/video-frames"
    posix.mkdir_p(fdir)
    local key = sha1_key("%s\\0%s", wall, mtime_of(wall))
    local frame_file = fdir .. "/" .. key .. ".png"
    if not file_nonempty(frame_file) then
        proc.call({ "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-i", wall, "-frames:v", "1", frame_file })
        prune_cache(fdir)
    end
    if file_nonempty(frame_file) then return frame_file end
    return nil
end

local function spawn_mpvpaper(mon, wall, sock, extra_opts)
    posix.unlink(sock)
    local opts = "no-audio loop-file=inf hwdec=auto pause input-ipc-server=" .. sock
    if extra_opts then opts = opts .. " " .. extra_opts end
    local pid = proc.spawn_detached({ "mpvpaper", "-o", opts, mon, wall })
    if pid then
        posix.write_file(STATE_DIR .. "/mpvpaper-" .. mon .. ".pid", pid .. "\n")
    end
end

local function mpv_ipc_sock(mon)
    local ipc_dir = STATE_DIR .. "/mpvpaper-ipc"
    posix.mkdir_p(ipc_dir)
    return ipc_dir .. "/" .. mon .. ".sock"
end

local function apply_video(mon, wall)
    if not proc.have("mpvpaper") then
        hypr.notify("Wallpaper", "mpvpaper not installed -- can't play " .. fs.basename(wall),
                    { urgency = "normal" })
        return
    end
    clear_span()
    ensure_swww_running()

    -- 1. Start the swww fade to the still first frame. Fit-with-black-fill so
    --    the still frame is letterboxed exactly like mpv will render the live
    --    video -- otherwise swww's default crop-to-fill leaves a zoom-cropped
    --    frame visible through the video's letterbox bars during playback.
    local frame = extract_video_frame(wall)
    stop_mpvpaper_for(mon)
    if frame then
        swww_img(mon, frame, { "--resize", "fit", "--fill-color", "000000" })
    end

    -- 2. Spawn mpvpaper paused IN PARALLEL with the fade so mpv decodes the
    --    first frame while swww is still animating. No swww clear here -- it
    --    would wipe the still frame mid-transition and cause a black flash.
    local sock = mpv_ipc_sock(mon)
    spawn_mpvpaper(mon, wall, sock)

    -- 3. Wait for the transition to finish AND mpv to be parked on frame 0,
    --    then unpause. mpv's first frame matches the still swww just landed
    --    on, so the surface handoff is invisible.
    if frame then posix.sleep(1) end
    mpv_unpause(wait_mpv_socket(sock))
end

local function apply_wallpaper(mon, wall)
    if is_video(wall) then
        apply_video(mon, wall)
    else
        apply_image(mon, wall)
    end
end

-- Compute the spanned-wallpaper layout given a source's pixel dimensions.
-- Returns (rows, img):
--   rows[i] = { name, nw, nh   (native post-transform pixels),
--               lw, lh         (logical compositor-coord size),
--               cx, cy         (monitor's offset into the scaled image) }
--   img     = { w, h, left, top, hash }
-- The layout hash fingerprints monitor positions/sizes/transforms for cache
-- keying (sha1 of the same TSV the bash/jq version hashed, so span caches
-- survive the port).
--
-- Strategy: anchor the image on the LARGEST monitor's center and scale
-- (preserving source aspect) until it reaches the farthest monitor edge in
-- both axes. Result: no black fill, no duplicate-looking content near the
-- seam, main subject lands on the primary monitor.
local function span_layout(src_w, src_h)
    local mons = hypr.monitors()
    if #mons == 0 then return nil end

    local rows, tsv = {}, {}
    local largest, largest_area = 1, 0
    for i, m in ipairs(mons) do
        local nw = (m.transform % 2 == 1) and m.height or m.width
        local nh = (m.transform % 2 == 1) and m.width or m.height
        local lw = round(nw / m.scale)
        local lh = round(nh / m.scale)
        rows[i] = { name = m.name, nw = nw, nh = nh, sx = m.x, sy = m.y, lw = lw, lh = lh }
        tsv[i] = table.concat({ m.name, nw, nh, m.x, m.y, lw, lh }, "\t")
        if lw * lh > largest_area then
            largest_area = lw * lh
            largest = i
        end
    end

    local L = rows[largest]
    local lcx = L.sx + idiv(L.lw, 2)
    local lcy = L.sy + idiv(L.lh, 2)

    local max_hx, max_vy = 0, 0
    for _, r in ipairs(rows) do
        for _, d in ipairs({ r.sx - lcx, r.sx + r.lw - lcx }) do
            if d < 0 then d = -d end
            if d > max_hx then max_hx = d end
        end
        for _, d in ipairs({ r.sy - lcy, r.sy + r.lh - lcy }) do
            if d < 0 then d = -d end
            if d > max_vy then max_vy = d end
        end
    end
    local need_w, need_h = max_hx * 2, max_vy * 2

    local img_w, img_h
    if need_w * src_h >= need_h * src_w then
        img_w = need_w
        img_h = idiv(src_h * need_w, src_w)
    else
        img_h = need_h
        img_w = idiv(src_w * need_h, src_h)
    end
    local img_left = lcx - idiv(img_w, 2)
    local img_top = lcy - idiv(img_h, 2)

    for _, r in ipairs(rows) do
        r.cx = r.sx - img_left
        r.cy = r.sy - img_top
    end
    return rows, {
        w = img_w, h = img_h, left = img_left, top = img_top,
        hash = proc.sha1(table.concat(tsv, "\n")),
    }
end

-- Translate a per-monitor slice from scaled-image pixels into source pixels
-- (aspect preserved, so the width ratio suffices), clamped to the source.
local function source_crop(r, img_w, src_w, src_h)
    local x = idiv(r.cx * src_w, img_w)
    local y = idiv(r.cy * src_w, img_w)
    local w = idiv(r.lw * src_w, img_w)
    local h = idiv(r.lh * src_w, img_w)
    if x < 0 then x = 0 end
    if y < 0 then y = 0 end
    if x + w > src_w then w = src_w - x end
    if y + h > src_h then h = src_h - y end
    return x, y, w, h
end

local function image_dimensions(wall)
    local id = proc.have("identify") and { "identify" } or { "magick", "identify" }
    id[#id + 1] = "-format"
    id[#id + 1] = "%w %h\n"
    id[#id + 1] = wall
    local out = proc.run(id)
    local w, h = out:match("^(%d+) (%d+)")
    return tonumber(w), tonumber(h)
end

-- Apply a still or animated image spanned across all monitors. Per-monitor
-- slices are cropped from the SOURCE coordinates (not from a pre-upscaled
-- canvas), so a small gif doesn't get scaled up 10x just to be cut. Animated
-- GIFs are coalesced and re-emitted as multi-frame GIFs so swww plays them.
-- Returns true on success.
local function apply_spanned_image(wall)
    local im_cmd
    if proc.have("magick") then
        im_cmd = "magick"
    elseif proc.have("convert") then
        im_cmd = "convert"
    else
        hypr.notify("Wallpaper", "ImageMagick required for spanned wallpapers",
                    { urgency = "critical" })
        io.stderr:write("ImageMagick (magick/convert) not found\n")
        return false
    end

    local src_w, src_h = image_dimensions(wall)
    if not src_w or not src_h then
        io.stderr:write("couldn't read dimensions of " .. wall .. "\n")
        return false
    end

    local is_animated = fs.ext(wall) == "gif"
    local out_ext = is_animated and "gif" or "png"

    local rows, img = span_layout(src_w, src_h)
    if not rows then return false end

    local cache_dir = STATE_DIR .. "/spanned-cache"
    posix.mkdir_p(cache_dir)
    local key = sha1_key("%s\\0%s\\0%s\\0%dx%d@%d,%d",
                         wall, mtime_of(wall), img.hash, img.w, img.h, img.left, img.top)

    ensure_swww_running()

    for _, r in ipairs(rows) do
        local crop_file = cache_dir .. "/" .. key .. "-" .. r.name .. "." .. out_ext
        if not file_nonempty(crop_file) then
            local x, y, w, h = source_crop(r, img.w, src_w, src_h)
            local crop_spec = w .. "x" .. h .. "+" .. x .. "+" .. y
            if is_animated then
                -- Don't upscale each frame to native pixels -- that bloats the
                -- cached GIF wildly (a 498px source x 44 frames upscaled to
                -- 2560x1440 = ~40 MB). Ship the source-sized slice; swww
                -- scales to the monitor on playback.
                proc.call({ im_cmd, wall, "-coalesce",
                            "-crop", crop_spec, "+repage", crop_file })
            else
                proc.call({ im_cmd, wall,
                            "-crop", crop_spec, "+repage",
                            "-resize", r.nw .. "x" .. r.nh .. "!", crop_file })
            end
        end

        stop_mpvpaper_for(r.name)
        swww_img(r.name, crop_file)
        save_index(r.name, wall)
    end
    prune_cache(cache_dir)
    return true
end

local function video_dimensions(wall)
    local out, code = proc.run({ "ffprobe", "-v", "error", "-select_streams", "v:0",
                                 "-show_entries", "stream=width,height",
                                 "-of", "csv=p=0", wall })
    if code ~= 0 then return nil end
    local w, h = out:match("(%d+),(%d+)")
    return tonumber(w), tonumber(h)
end

-- Apply a video (or animated GIF) spanned across all monitors via mpvpaper.
-- mpv crops on the GPU during playback (no pre-encoding); a synchronized
-- launch pattern keeps animations frame-aligned across monitors:
--
--   1. Spawn every mpvpaper instance with `pause` + `input-ipc-server=...`
--      so each mpv decodes and seeks to frame 0 but holds, hiding the
--      per-process startup variance.
--   2. Wait for every IPC socket to accept (mpv has finished its prep).
--   3. Fire `pause false` at all sockets back-to-back so they begin playing
--      within one kernel-scheduling slice of each other.
--
-- Per-monitor crop is computed in the spanning layout's scaled-image coords
-- then mapped back into source-video pixel coords for mpv's `crop` filter.
local function apply_spanned_video(wall)
    if not proc.have("mpvpaper") then
        hypr.notify("Wallpaper", "mpvpaper not installed -- can't play " .. fs.basename(wall),
                    { urgency = "normal" })
        return false
    end
    if not proc.have("ffprobe") then
        hypr.notify("Wallpaper", "ffprobe required to span videos", { urgency = "normal" })
        return false
    end

    local src_w, src_h = video_dimensions(wall)
    if not src_w or not src_h then
        io.stderr:write("couldn't read dimensions of " .. wall .. "\n")
        return false
    end

    local rows, img = span_layout(src_w, src_h)
    if not rows then return false end

    ensure_swww_running()

    -- 1. Play the swww fade into a still first frame across every monitor.
    --    apply_spanned_image already stops any running mpvpaper per output
    --    and writes the per-monitor crops with the same layout math, so the
    --    still frame and the live video align exactly.
    local frame = extract_video_frame(wall)
    if frame then
        apply_spanned_image(frame)
    end

    -- 2. Spawn every mpvpaper paused IN PARALLEL with the swww fade so mpv
    --    has a full second to load + decode the first frame. No per-monitor
    --    swww clear here -- that would wipe the still mid-transition.
    local socks = {}
    for _, r in ipairs(rows) do
        local x, y, w, h = source_crop(r, img.w, src_w, src_h)
        local sock = mpv_ipc_sock(r.name)
        -- Stop any prior mpvpaper before spawning the new one. apply_spanned_image
        -- already does this, but it is skipped when frame extraction fails above,
        -- so do it unconditionally here (idempotent) to avoid stacking instances.
        stop_mpvpaper_for(r.name)
        spawn_mpvpaper(r.name, wall, sock,
                       "vf=crop=" .. w .. ":" .. h .. ":" .. x .. ":" .. y)
        socks[#socks + 1] = sock
        save_index(r.name, wall)
    end

    -- 3. Wait out the rest of the swww fade, then confirm every mpv is
    --    parked on its first frame. By now mpv has been preparing for ~1s,
    --    so the socket-wait is usually a no-op.
    if frame then posix.sleep(1) end
    local fds = {}
    for _, sock in ipairs(socks) do
        fds[#fds + 1] = wait_mpv_socket(sock)
    end

    -- 4. Unpause every instance back-to-back -- start-of-playback offset
    --    between monitors is a few syscalls, not one mpv start.
    for _, fd in ipairs(fds) do
        mpv_unpause(fd)
    end
    return true
end

---------------------------------------------------------------- actions --

local action = arg[1] or "next"

if action == "span" then
    local span_path = arg[2]
    if not span_path or span_path == "" then
        io.stderr:write("span requires a path\n")
        os.exit(2)
    end
    local ok
    if is_video(span_path, true) then
        ok = apply_spanned_video(span_path)
    else
        ok = apply_spanned_image(span_path)
    end
    if not ok then os.exit(1) end
    -- Remember the span so `init` after a Hyprland restart can restore it.
    posix.write_file(SPAN_STATE, span_path .. "\n")
    hypr.notify("Wallpaper", fs.basename(span_path) .. " spanned across monitors",
                { timeout_ms = 2000 })
    os.exit(0)
end

if action == "pick" then
    local pick_path, pick_mon = arg[2], arg[3]
    if not pick_path or pick_path == "" then
        io.stderr:write("pick requires a path\n")
        os.exit(2)
    end
    local monitors = (pick_mon and pick_mon ~= "") and { pick_mon } or hypr.monitor_names()
    for _, mon in ipairs(monitors) do
        save_index(mon, pick_path)
        apply_wallpaper(mon, pick_path)
    end
    hypr.notify("Wallpaper", fs.basename(pick_path) .. " on " .. table.concat(monitors, " "),
                { timeout_ms = 2000 })
    os.exit(0)
end

if action ~= "next" and action ~= "prev" and action ~= "init" and action ~= "current" then
    io.stderr:write("unknown action: " .. action .. "\n")
    os.exit(2)
end

-- init after a Hyprland restart: if the last wallpaper was spanned, restore the
-- span instead of degrading to independent per-monitor crops. A failed restore
-- (e.g. the file was deleted) falls through to the normal per-monitor path.
if action == "init" then
    local sp = (posix.read_file(SPAN_STATE) or ""):match("[^\n]+")
    if sp and posix.exists(sp) then
        local ok
        if is_video(sp, true) then
            ok = apply_spanned_video(sp)
        else
            ok = apply_spanned_image(sp)
        end
        if ok then
            hypr.notify("Wallpaper", fs.basename(sp) .. " spanned across monitors",
                        { timeout_ms = 2000 })
            os.exit(0)
        end
    end
end

local mon_arg = arg[2]
local monitors = (mon_arg and mon_arg ~= "") and { mon_arg } or hypr.monitor_names()

local function apply_to_monitor(mon)
    local state_file = STATE_DIR .. "/wallpaper-index-" .. mon

    local idx = tonumber(((posix.read_file(state_file) or ""):match("-?%d+"))) or 0
    if idx < 0 or idx >= #walls then idx = 0 end

    if action == "next" then
        idx = (idx + 1) % #walls
    elseif action == "prev" then
        idx = (idx - 1 + #walls) % #walls
    end -- init|current: keep idx

    local wall = walls[idx + 1]
    posix.write_file(state_file, idx .. "\n")
    apply_wallpaper(mon, wall)
    return mon .. " -> " .. fs.basename(wall) .. " (" .. (idx + 1) .. "/" .. #walls .. ")"
end

local results = {}
for _, mon in ipairs(monitors) do
    results[#results + 1] = apply_to_monitor(mon)
end

hypr.notify("Wallpaper", table.concat(results, "\n"), { timeout_ms = 2000 })
