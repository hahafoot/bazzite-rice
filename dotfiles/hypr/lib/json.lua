-- json.lua — strict JSON encode/decode for LuaJIT, no dependencies.
-- UTF-8 in strings passes through untouched; \uXXXX escapes (including
-- surrogate pairs) are decoded to UTF-8 on parse.

local json = {}

---------------------------------------------------------------- decode --

local function decode_error(str, pos, msg)
    local line, col = 1, 1
    for i = 1, math.min(pos, #str) - 1 do
        if str:byte(i) == 10 then line, col = line + 1, 1 else col = col + 1 end
    end
    error(("json: %s at line %d col %d"):format(msg, line, col), 0)
end

local function skip_ws(str, pos)
    local _, e = str:find("^[ \t\r\n]*", pos)
    return e + 1
end

local ESCAPES = {
    ['"'] = '"', ['\\'] = '\\', ['/'] = '/',
    b = '\b', f = '\f', n = '\n', r = '\r', t = '\t',
}

local function utf8_encode(cp)
    if cp < 0x80 then
        return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000),
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000),
                           0x80 + math.floor(cp / 0x1000) % 0x40,
                           0x80 + math.floor(cp / 0x40) % 0x40,
                           0x80 + cp % 0x40)
    end
end

local function parse_string(str, pos)
    local out, i = {}, pos + 1
    while true do
        local c = str:sub(i, i)
        if c == "" then
            decode_error(str, i, "unterminated string")
        elseif c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local e = str:sub(i + 1, i + 1)
            if e == "u" then
                local hex = str:sub(i + 2, i + 5)
                if not hex:find("^%x%x%x%x$") then
                    decode_error(str, i, "invalid \\u escape")
                end
                local cp = tonumber(hex, 16)
                i = i + 6
                if cp >= 0xD800 and cp <= 0xDBFF then -- high surrogate
                    local hex2 = str:match("^\\u(%x%x%x%x)", i)
                    local lo = hex2 and tonumber(hex2, 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        i = i + 6
                    end
                end
                out[#out + 1] = utf8_encode(cp)
            elseif ESCAPES[e] then
                out[#out + 1] = ESCAPES[e]
                i = i + 2
            else
                decode_error(str, i, "invalid escape '\\" .. e .. "'")
            end
        else
            -- consume a run of plain characters at once
            local j = str:find('["\\]', i) or (#str + 1)
            out[#out + 1] = str:sub(i, j - 1)
            i = j
        end
    end
end

local function parse_number(str, pos)
    local num = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    local n = tonumber(num)
    if not n then decode_error(str, pos, "invalid number") end
    return n, pos + #num
end

local parse_value

local function parse_array(str, pos)
    local arr, n, i = {}, 0, skip_ws(str, pos + 1)
    if str:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = parse_value(str, i)
        -- Use an explicit counter so a JSON null (decoded to nil) keeps the
        -- positions of later elements instead of collapsing the array via #arr.
        n = n + 1
        arr[n] = v
        i = skip_ws(str, i)
        local c = str:sub(i, i)
        if c == "]" then return arr, i + 1 end
        if c ~= "," then decode_error(str, i, "expected ',' or ']'") end
        i = skip_ws(str, i + 1)
    end
end

local function parse_object(str, pos)
    local obj, i = {}, skip_ws(str, pos + 1)
    if str:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if str:sub(i, i) ~= '"' then decode_error(str, i, "expected string key") end
        local k, v
        k, i = parse_string(str, i)
        i = skip_ws(str, i)
        if str:sub(i, i) ~= ":" then decode_error(str, i, "expected ':'") end
        i = skip_ws(str, i + 1)
        v, i = parse_value(str, i)
        obj[k] = v
        i = skip_ws(str, i)
        local c = str:sub(i, i)
        if c == "}" then return obj, i + 1 end
        if c ~= "," then decode_error(str, i, "expected ',' or '}'") end
        i = skip_ws(str, i + 1)
    end
end

parse_value = function(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then return parse_string(str, pos) end
    if c == "{" then return parse_object(str, pos) end
    if c == "[" then return parse_array(str, pos) end
    if c == "t" and str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    if c == "f" and str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    if c == "n" and str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
    if c == "-" or c:find("^%d") then return parse_number(str, pos) end
    decode_error(str, pos, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Errors (with position) on malformed input.
--- JSON null decodes to Lua nil (so null object values vanish — fine for
--- our uses: hyprctl/waybar payloads never carry meaningful nulls).
function json.decode(str)
    local v, pos = parse_value(str, skip_ws(str, 1))
    pos = skip_ws(str, pos)
    if pos <= #str then decode_error(str, pos, "trailing garbage") end
    return v
end

---------------------------------------------------------------- encode --

local STR_ESCAPES = {
    ['"'] = '\\"', ["\\"] = "\\\\",
    ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function encode_string(s)
    return '"' .. s:gsub('[%z\1-\31"\\]', function(c)
        return STR_ESCAPES[c] or ("\\u%04x"):format(c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
        n = n + 1
    end
    return n == #t
end

local encode_value

local function encode_table(t, seen)
    if seen[t] then error("json: circular reference", 0) end
    seen[t] = true
    local out
    if is_array(t) and next(t) ~= nil then
        out = {}
        for i = 1, #t do out[i] = encode_value(t[i], seen) end
        out = "[" .. table.concat(out, ",") .. "]"
    else
        out = {}
        local keys = {}
        for k in pairs(t) do
            if type(k) ~= "string" then error("json: object keys must be strings", 0) end
            keys[#keys + 1] = k
        end
        table.sort(keys)
        for i, k in ipairs(keys) do
            out[i] = encode_string(k) .. ":" .. encode_value(t[k], seen)
        end
        out = "{" .. table.concat(out, ",") .. "}"
    end
    seen[t] = nil
    return out
end

encode_value = function(v, seen)
    local tv = type(v)
    if v == nil then return "null" end
    if tv == "boolean" then return tostring(v) end
    if tv == "string" then return encode_string(v) end
    if tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            error("json: cannot encode NaN/inf", 0)
        end
        if v % 1 == 0 and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
        return ("%.14g"):format(v)
    end
    if tv == "table" then return encode_table(v, seen) end
    error("json: cannot encode " .. tv, 0)
end

--- Encode a Lua value as compact JSON. Empty tables encode as {}.
function json.encode(v)
    return encode_value(v, {})
end

return json
