#!/usr/bin/env luajit
-- media-now.lua — emit waybar JSON for the active playerctl media player.
--
-- Hides the module after the player has been not-Playing for HIDE_AFTER_PAUSE
-- seconds. Re-shows immediately when playback resumes.
--
-- Single-threaded: one poll loop multiplexes `playerctl -F` metadata lines
-- with the marquee tick (the Python original used a timer thread).

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
local json = require("json")

local HIDE_AFTER_PAUSE = 20.0 -- seconds since last Playing before we hide
local SCROLL_TICK      = 0.4  -- seconds between marquee frames
local MAX_BODY         = 40   -- title+artist chars before scrolling kicks in
local SCROLL_SEP       = "   •   "

local ICONS = {
    spotify  = "♪",
    mpv      = "",
    firefox  = "",
    chromium = "",
    chrome   = "",
    vlc      = "嗢",
    default  = "▶",
}

local FIELD_SEP = "\31" -- unit separator; vanishingly unlikely in metadata
local FMT = table.concat({
    "{{playerName}}", "{{status}}",
    "{{xesam:title}}", "{{xesam:artist}}", "{{xesam:album}}",
}, FIELD_SEP)

local state = {
    player = "", status = "Stopped",
    title = "", artist = "", album = "",
    last_play = 0.0, -- monotonic timestamp of most recent "Playing"
}

local scroll = { frame = 0, key = "" }
local last_emit = nil

-- Split a UTF-8 string into characters so the marquee never slices a
-- codepoint in half (CJK/accented titles must stay valid for pango).
local function utf8_chars(s)
    local out = {}
    for c in s:gmatch("[\1-\127\194-\244][\128-\191]*") do
        out[#out + 1] = c
    end
    return out
end

local function marquee(s, n, frame)
    local chars = utf8_chars(s)
    if #chars <= n then return s end
    local fchars = utf8_chars(s .. SCROLL_SEP)
    local len = #fchars
    local step = frame % len
    local out = {}
    for i = 1, n do
        out[i] = fchars[(step + i - 1) % len + 1]
    end
    return table.concat(out)
end

-- python html.escape(quote=True) equivalent (order matters: & first)
local function escape(s)
    return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
             :gsub('"', "&quot;"):gsub("'", "&#x27;"))
end

local function emit(payload)
    local txt = json.encode(payload)
    if txt == last_emit then return end
    io.stdout:write(txt, "\n")
    io.stdout:flush()
    last_emit = txt
end

local function hidden()
    return { text = "", tooltip = "", class = "stopped", alt = "stopped" }
end

local function render(player, status, title, artist, album)
    if (title == "" and artist == "") or status == "Stopped" then
        return hidden()
    end

    local body_plain = title
    if title ~= "" and artist ~= "" then
        body_plain = title .. "  —  " .. artist
    elseif artist ~= "" then
        body_plain = artist
    end

    local key = player .. "\31" .. title .. "\31" .. artist
    if key ~= scroll.key then
        scroll.key = key
        scroll.frame = 0
    end
    local body = escape(marquee(body_plain, MAX_BODY, scroll.frame))

    local text
    if player:lower() == "spotify" then
        text = status == "Paused" and ("♪  <i>" .. body .. "</i>  ♪")
                                   or ("♪  " .. body .. "  ♪")
    else
        local icon = ICONS[player:lower()] or ICONS.default
        text = status == "Paused" and ("⏸  <i>" .. body .. "</i>")
                                   or (icon .. "  " .. body)
    end

    local tooltip = player .. " · " .. status .. "\n" .. title
    if artist ~= "" then
        tooltip = tooltip .. "\n" .. artist
        if album ~= "" then
            tooltip = tooltip .. " — " .. album
        end
    end

    return {
        text    = text,
        tooltip = escape(tooltip),
        class   = status:lower(),
        alt     = status:lower(),
    }
end

local function snapshot_and_emit()
    local elapsed = posix.monotonic() - state.last_play
    if state.status == "Playing"
        or (elapsed < HIDE_AFTER_PAUSE and (state.title ~= "" or state.artist ~= "")) then
        emit(render(state.player, state.status, state.title, state.artist, state.album))
    else
        emit(hidden())
    end
end

local pid, stream = proc.spawn_pipe({ "playerctl", "-F", "metadata", "--format", FMT })
if not pid then
    emit(hidden())
    os.exit(1)
end

local next_tick = posix.monotonic() + SCROLL_TICK
while true do
    local timeout_ms = math.floor((next_tick - posix.monotonic()) * 1000)
    if timeout_ms < 0 then timeout_ms = 0 end
    local line, err = stream:readline(timeout_ms)
    if line then
        local parts = {}
        for p in (line .. FIELD_SEP):gmatch("([^\31]*)\31") do
            parts[#parts + 1] = p
        end
        state.player = parts[1] or ""
        state.status = parts[2] or ""
        state.title  = parts[3] or ""
        state.artist = parts[4] or ""
        state.album  = parts[5] or ""
        if state.status == "Playing" then
            state.last_play = posix.monotonic()
        end
        snapshot_and_emit()
    elseif err == "timeout" then
        scroll.frame = scroll.frame + 1
        next_tick = posix.monotonic() + SCROLL_TICK
        snapshot_and_emit()
    else
        break -- playerctl exited (eof) or read error
    end
end

proc.kill(pid)
proc.reap(pid)
