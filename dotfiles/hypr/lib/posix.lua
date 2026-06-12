-- posix.lua — thin LuaJIT FFI layer over the libc bits the rice scripts need:
-- monotonic clock, sub-second sleep, unix-domain socket clients, poll-based
-- line readers, and the fork/exec primitives proc.lua builds on.
-- Linux x86_64 / glibc only (this repo targets Bazzite).

local ffi = require("ffi")

ffi.cdef[[
typedef int pid_t;
typedef long ssize_t;
typedef unsigned long size_t;

pid_t fork(void);
int   execvp(const char *file, const char **argv);
int   pipe2(int fds[2], int flags);
int   dup2(int oldfd, int newfd);
int   open(const char *path, int flags, ...);
int   close(int fd);
ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
pid_t waitpid(pid_t pid, int *status, int options);
pid_t setsid(void);
void  _exit(int status);
int   kill(pid_t pid, int sig);
pid_t getpid(void);

int access(const char *path, int mode);
int mkdir(const char *path, unsigned int mode);
int unlink(const char *path);
int rename(const char *oldpath, const char *newpath);
ssize_t readlink(const char *path, char *buf, size_t bufsiz);

struct timespec { long tv_sec; long tv_nsec; };
int nanosleep(const struct timespec *req, struct timespec *rem);
int clock_gettime(int clk_id, struct timespec *tp);

struct pollfd { int fd; short events; short revents; };
int poll(struct pollfd *fds, unsigned long nfds, int timeout);

int socket(int domain, int type, int protocol);
struct sockaddr_un { unsigned short sun_family; char sun_path[108]; };
int connect(int fd, const struct sockaddr_un *addr, unsigned int len);

int flock(int fd, int operation);

struct dirent64 {
    unsigned long  d_ino;
    long           d_off;
    unsigned short d_reclen;
    unsigned char  d_type;
    char           d_name[256];
};
typedef struct __dirstream DIR;
DIR *opendir(const char *name);
struct dirent64 *readdir64(DIR *dirp);
int closedir(DIR *dirp);

char *strerror(int errnum);
]]

local C = ffi.C

local posix = { C = C }

posix.O_RDONLY  = 0
posix.O_WRONLY  = 1
posix.O_RDWR    = 2
posix.O_CREAT   = 0x40
posix.O_CLOEXEC = 0x80000
posix.POLLIN    = 0x001
posix.WNOHANG   = 1
posix.SIGTERM   = 15
posix.SIGKILL   = 9

posix.DT_DIR = 4
posix.DT_REG = 8

local CLOCK_MONOTONIC = 1
local AF_UNIX, SOCK_STREAM, SOCK_CLOEXEC = 1, 1, 0x80000

function posix.errstr()
    return ffi.string(C.strerror(ffi.errno()))
end

--- Monotonic time in (fractional) seconds.
function posix.monotonic()
    local ts = ffi.new("struct timespec")
    C.clock_gettime(CLOCK_MONOTONIC, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
end

--- Sleep for a (possibly fractional) number of seconds.
function posix.sleep(sec)
    if sec <= 0 then return end
    local ts = ffi.new("struct timespec")
    ts.tv_sec = math.floor(sec)
    ts.tv_nsec = math.floor((sec % 1) * 1e9)
    C.nanosleep(ts, nil)
end

--- Does the path exist (any file type)?
function posix.exists(path)
    return C.access(path, 0) == 0
end

--- mkdir -p. Errors are ignored (EEXIST is the common case).
function posix.mkdir_p(path)
    local prefix = path:sub(1, 1) == "/" and "/" or ""
    local acc = prefix
    for part in path:gmatch("[^/]+") do
        acc = acc .. part
        C.mkdir(acc, 0x1FF) -- 0777; the umask trims it
        acc = acc .. "/"
    end
end

function posix.unlink(path)
    C.unlink(path)
end

--- Single-level readlink (no resolution of the target); nil if not a link.
function posix.readlink(path)
    local buf = ffi.new("char[4096]")
    local n = tonumber(C.readlink(path, buf, 4096))
    if n <= 0 then return nil end
    return ffi.string(buf, n)
end

--- Write a file atomically (tmp file + rename).
function posix.write_file(path, content)
    local tmp = path .. ".tmp." .. tonumber(C.getpid())
    local f, err = io.open(tmp, "w")
    if not f then return nil, err end
    f:write(content)
    f:close()
    if C.rename(tmp, path) ~= 0 then
        C.unlink(tmp)
        return nil, posix.errstr()
    end
    return true
end

--- Read a whole file; nil if unreadable.
function posix.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

--- Connect to a unix-domain stream socket. Returns fd, or nil + error.
function posix.connect_unix(path)
    if #path >= 108 then return nil, "socket path too long" end
    local fd = C.socket(AF_UNIX, SOCK_STREAM + SOCK_CLOEXEC, 0)
    if fd < 0 then return nil, posix.errstr() end
    local addr = ffi.new("struct sockaddr_un")
    addr.sun_family = AF_UNIX
    ffi.copy(addr.sun_path, path)
    -- sizeof(sa_family_t) + path + NUL
    if C.connect(fd, addr, 2 + #path + 1) ~= 0 then
        local err = posix.errstr()
        C.close(fd)
        return nil, err
    end
    return fd
end

--- Block until fd is readable or timeout_ms elapses (-1 = forever).
--- Returns true if readable, false on timeout, nil + err on poll error.
function posix.poll_read(fd, timeout_ms)
    local pfd = ffi.new("struct pollfd[1]")
    pfd[0].fd = fd
    pfd[0].events = posix.POLLIN
    local r = C.poll(pfd, 1, timeout_ms)
    if r < 0 then return nil, posix.errstr() end
    return r > 0
end

function posix.write_fd(fd, s)
    local off, len = 0, #s
    while off < len do
        local n = tonumber(C.write(fd, ffi.cast("const char *", s) + off, len - off))
        if n <= 0 then return nil, posix.errstr() end
        off = off + n
    end
    return true
end

function posix.close(fd)
    C.close(fd)
end

--- Try to take an exclusive non-blocking flock on path (creating it).
--- Returns the held fd (close to release; exiting also releases), or nil
--- if another process holds it.
function posix.flock_try(path)
    local ffi_ = require("ffi")
    local fd = C.open(path, posix.O_WRONLY + posix.O_CREAT + posix.O_CLOEXEC,
                      ffi_.cast("unsigned int", 0x1A4)) -- 0644
    if fd < 0 then return nil end
    local LOCK_EX, LOCK_NB = 2, 4
    if C.flock(fd, LOCK_EX + LOCK_NB) ~= 0 then
        C.close(fd)
        return nil
    end
    return fd
end

--- List a directory's entries (skips . and ..). Returns an array of
--- { name = ..., is_dir = bool, is_reg = bool }, or nil if unreadable.
--- Symlinks report neither flag, matching `find -P -type f/d` semantics.
--- DT_UNKNOWN entries are classified with an opendir probe.
function posix.list_dir(path)
    local d = C.opendir(path)
    if d == nil then return nil end
    local out = {}
    while true do
        local ent = C.readdir64(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            local t = ent.d_type
            local is_dir, is_reg = t == posix.DT_DIR, t == posix.DT_REG
            if t == 0 then -- DT_UNKNOWN: rare fs without d_type support
                local probe = C.opendir(path .. "/" .. name)
                if probe ~= nil then
                    C.closedir(probe)
                    is_dir = true
                else
                    is_reg = posix.exists(path .. "/" .. name)
                end
            end
            out[#out + 1] = { name = name, is_dir = is_dir, is_reg = is_reg }
        end
    end
    C.closedir(d)
    return out
end

--- Buffered line reader over a raw fd.
--- :readline(timeout_ms) -> line (without \n)
---                        | nil, "timeout"
---                        | nil, "eof" (buffer exhausted and fd closed)
local Stream = {}
Stream.__index = Stream

function posix.stream(fd)
    return setmetatable({ fd = fd, buf = "", eof = false }, Stream)
end

local READ_CHUNK = 4096

function Stream:readline(timeout_ms)
    while true do
        local nl = self.buf:find("\n", 1, true)
        if nl then
            local line = self.buf:sub(1, nl - 1)
            self.buf = self.buf:sub(nl + 1)
            return line
        end
        if self.eof then
            if #self.buf > 0 then
                local line = self.buf
                self.buf = ""
                return line
            end
            return nil, "eof"
        end
        local readable, perr = posix.poll_read(self.fd, timeout_ms or -1)
        if readable == nil then return nil, perr end
        if not readable then return nil, "timeout" end
        local cbuf = ffi.new("char[?]", READ_CHUNK)
        local n = tonumber(C.read(self.fd, cbuf, READ_CHUNK))
        if n > 0 then
            self.buf = self.buf .. ffi.string(cbuf, n)
        elseif n == 0 then
            self.eof = true
        else
            return nil, posix.errstr()
        end
    end
end

function Stream:close()
    C.close(self.fd)
end

return posix
