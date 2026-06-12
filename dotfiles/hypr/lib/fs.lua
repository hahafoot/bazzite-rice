-- fs.lua — filesystem walks for the wallpaper system. Replaces the old
-- `find … -prune … -iname … | sort` pipelines with a native walk, so paths
-- with spaces, colons, or CJK unicode are never re-parsed through a shell.

local posix = require("posix")

local fs = {}

--- Lowercased extension of a path ("png", "mp4", …), or "" if none.
function fs.ext(path)
    local e = path:match("%.([^./]+)$")
    return e and e:lower() or ""
end

function fs.basename(path)
    return path:match("([^/]+)/*$") or path
end

--- Recursively collect regular files under root. Like `find -P -type f`:
--- symlinks are not followed and symlinked files are not listed.
---   exts        set of lowercase extensions to keep, e.g. {png=true,…};
---               nil keeps everything
---   prune_dirs  set of directory names to skip entirely (e.g. __MACOSX)
---   skip_prefix file-name prefix to drop (e.g. "._" AppleDouble junk)
--- Returns a byte-order-sorted (LC_ALL=C) array of absolute paths.
function fs.walk_files(root, exts, prune_dirs, skip_prefix)
    prune_dirs = prune_dirs or {}
    local out = {}
    local function walk(dir)
        for _, ent in ipairs(posix.list_dir(dir) or {}) do
            if ent.is_dir then
                if not prune_dirs[ent.name] then
                    walk(dir .. "/" .. ent.name)
                end
            elseif ent.is_reg then
                local skip = skip_prefix
                    and ent.name:sub(1, #skip_prefix) == skip_prefix
                if not skip and (not exts or exts[fs.ext(ent.name)]) then
                    out[#out + 1] = dir .. "/" .. ent.name
                end
            end
        end
    end
    walk((root:gsub("/+$", "")))
    table.sort(out)
    return out
end

return fs
