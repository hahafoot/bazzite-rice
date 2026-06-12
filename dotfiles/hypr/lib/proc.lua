-- proc.lua — process spawning without a shell. argv arrays go straight to
-- execvp, so filenames with spaces, quotes, pipes, or CJK unicode (all of
-- which exist in this repo's wallpapers/) can never be mangled by quoting.

local ffi = require("ffi")
local posix = require("posix")
local C = posix.C

local proc = {}

-- Build the C argv array. The caller must keep BOTH the returned cdata and
-- the Lua argv table alive until after execvp (passing the cdata as a call
-- argument is enough — don't ffi.cast it into a fresh unanchored pointer).
local function to_cargv(argv)
    local c = ffi.new("const char *[?]", #argv + 1)
    for i = 1, #argv do
        c[i - 1] = argv[i]
    end
    c[#argv] = nil
    return c
end

local function redirect_to_devnull(fds)
    local devnull = C.open("/dev/null", posix.O_RDWR)
    for _, fd in ipairs(fds) do
        C.dup2(devnull, fd)
    end
    if devnull > 2 then C.close(devnull) end
end

--- Run argv, capture stdout, wait. Returns stdout, exitcode.
--- stderr is inherited; stdin is /dev/null. exitcode is -1 if the child
--- died on a signal or exec failed.
function proc.run(argv)
    local fds = ffi.new("int[2]")
    if C.pipe2(fds, posix.O_CLOEXEC) ~= 0 then return "", -1 end
    local pid = C.fork()
    if pid < 0 then
        C.close(fds[0]); C.close(fds[1])
        return "", -1
    end
    if pid == 0 then
        C.dup2(fds[1], 1)
        local devnull = C.open("/dev/null", posix.O_RDONLY)
        C.dup2(devnull, 0)
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    C.close(fds[1])
    local chunks = {}
    local buf = ffi.new("char[?]", 8192)
    while true do
        local n = tonumber(C.read(fds[0], buf, 8192))
        if n <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, n)
    end
    C.close(fds[0])
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, 0)
    local st = status[0]
    local code = -1
    if st % 256 == 0 then code = math.floor(st / 256) % 256 end -- WIFEXITED
    return table.concat(chunks), code
end

--- Run argv, discard stdout, wait. Returns exitcode.
function proc.call(argv)
    local pid = C.fork()
    if pid < 0 then return -1 end
    if pid == 0 then
        redirect_to_devnull({ 0, 1 })
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, 0)
    local st = status[0]
    if st % 256 == 0 then return math.floor(st / 256) % 256 end
    return -1
end

--- Spawn argv detached in its own session (the setsid-&-disown pattern):
--- stdin/stdout/stderr on /dev/null, survives this process. Returns pid.
--- The caller is expected to exit soon after, so the child reparents to
--- init and never zombifies.
function proc.spawn_detached(argv)
    local pid = C.fork()
    if pid < 0 then return nil end
    if pid == 0 then
        C.setsid()
        redirect_to_devnull({ 0, 1, 2 })
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    return tonumber(pid)
end

--- Spawn argv with stdout piped back to us. Returns pid, stream
--- (a posix.stream line reader). stdin is /dev/null, stderr inherited.
function proc.spawn_pipe(argv)
    local fds = ffi.new("int[2]")
    if C.pipe2(fds, posix.O_CLOEXEC) ~= 0 then return nil end
    local pid = C.fork()
    if pid < 0 then
        C.close(fds[0]); C.close(fds[1])
        return nil
    end
    if pid == 0 then
        C.dup2(fds[1], 1)
        local devnull = C.open("/dev/null", posix.O_RDONLY)
        C.dup2(devnull, 0)
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    C.close(fds[1])
    return tonumber(pid), posix.stream(fds[0])
end

--- Spawn argv with all stdio on /dev/null, NOT detached. Returns pid for a
--- later proc.wait — the building block for parallel-then-wait fan-outs.
function proc.spawn_quiet(argv)
    local pid = C.fork()
    if pid < 0 then return nil end
    if pid == 0 then
        redirect_to_devnull({ 0, 1, 2 })
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    return tonumber(pid)
end

--- Block until pid exits.
function proc.wait(pid)
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, 0)
end

--- Run argv with `input` on its stdin, capture stdout, wait.
--- Returns stdout, exitcode. Suited to rofi -dmenu / fzf style tools (they
--- render on /dev/tty); input must comfortably fit a pipe buffer write
--- before the child finishes reading — fine for menu payloads.
function proc.run_with_input(argv, input)
    local inp = ffi.new("int[2]")
    local outp = ffi.new("int[2]")
    if C.pipe2(inp, 0) ~= 0 then return "", -1 end
    if C.pipe2(outp, 0) ~= 0 then
        C.close(inp[0]); C.close(inp[1])
        return "", -1
    end
    local pid = C.fork()
    if pid < 0 then
        C.close(inp[0]); C.close(inp[1]); C.close(outp[0]); C.close(outp[1])
        return "", -1
    end
    if pid == 0 then
        C.dup2(inp[0], 0)
        C.dup2(outp[1], 1)
        C.close(inp[0]); C.close(inp[1]); C.close(outp[0]); C.close(outp[1])
        C.execvp(argv[1], to_cargv(argv))
        C._exit(127)
    end
    C.close(inp[0])
    C.close(outp[1])
    posix.write_fd(inp[1], input or "")
    C.close(inp[1])
    local chunks = {}
    local buf = ffi.new("char[?]", 8192)
    while true do
        local n = tonumber(C.read(outp[0], buf, 8192))
        if n <= 0 then break end
        chunks[#chunks + 1] = ffi.string(buf, n)
    end
    C.close(outp[0])
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, 0)
    local st = status[0]
    local code = -1
    if st % 256 == 0 then code = math.floor(st / 256) % 256 end
    return table.concat(chunks), code
end

--- Replace this process with argv (bash `exec`). Only returns on failure.
function proc.exec(argv)
    local cargv = to_cargv(argv)
    C.execvp(argv[1], cargv)
    io.stderr:write("exec failed: " .. argv[1] .. "\n")
    os.exit(127)
end

function proc.kill(pid, sig)
    return C.kill(pid, sig or posix.SIGTERM) == 0
end

--- Reap a child without blocking (call after kill on a child we spawned).
function proc.reap(pid)
    local status = ffi.new("int[1]")
    C.waitpid(pid, status, posix.WNOHANG)
end

--- pgrep -if PATTERN: does any process's full argv match (case-insensitive
--- ERE)? Shells out to pgrep so the pattern semantics stay identical to the
--- contract documented in startup-apps.conf.
function proc.pgrep_if(pattern)
    return proc.call({ "pgrep", "-if", "--", pattern }) == 0
end

--- pkill -if PATTERN (best-effort).
function proc.pkill_if(pattern)
    proc.call({ "pkill", "-if", "--", pattern })
end

--- pkill -f PATTERN (case-sensitive, best-effort).
function proc.pkill_f(pattern)
    proc.call({ "pkill", "-f", "--", pattern })
end

--- Run a shell command line detached (for startup-apps.conf entries, which
--- are user-written shell commands by contract).
function proc.spawn_shell_detached(cmdline)
    return proc.spawn_detached({ "sh", "-c", cmdline })
end

--- Is `cmd` on PATH? (POSIX `command -v` via sh, like the bash originals.)
local have_cache = {}
function proc.have(cmd)
    if have_cache[cmd] == nil then
        have_cache[cmd] = proc.call({ "sh", "-c", 'command -v "$1" >/dev/null 2>&1', "sh", cmd }) == 0
    end
    return have_cache[cmd]
end

--- sha1 hex digest of a string (shells out to sha1sum; cache-key use only).
function proc.sha1(s)
    local out = proc.run({ "sh", "-c", 'printf %s "$1" | sha1sum', "sh", s })
    return out:match("^(%x+)") or "0"
end

return proc
