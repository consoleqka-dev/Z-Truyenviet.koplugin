-- Bộ giải mã JSON tối giản cho test trên máy tính (KOReader có sẵn json).
-- null được giải thành một giá trị đặc biệt (không phải nil), giống json của
-- KOReader, để test bắt được code coi null là chuỗi/bảng.
local MiniJson = { null = setmetatable({}, { __tostring = function() return "null" end }) }

local function utf8Char(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
        return string.char(0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
end

local ESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

function MiniJson.decode(text)
    local pos = 1
    local value

    local function fail(message)
        error(string.format("JSON lỗi tại %d: %s", pos, message))
    end

    local function skip()
        pos = text:find("[^ \t\r\n]", pos) or (#text + 1)
    end

    local function parseString()
        pos = pos + 1
        local parts = {}
        while true do
            local stop = text:find('["\\]', pos)
            if not stop then fail("chuỗi chưa đóng") end
            parts[#parts + 1] = text:sub(pos, stop - 1)
            if text:sub(stop, stop) == '"' then
                pos = stop + 1
                return table.concat(parts)
            end
            local kind = text:sub(stop + 1, stop + 1)
            if kind == "u" then
                local code = tonumber(text:sub(stop + 2, stop + 5), 16)
                pos = stop + 6
                if code >= 0xD800 and code <= 0xDBFF and text:sub(pos, pos + 1) == "\\u" then
                    local low = tonumber(text:sub(pos + 2, pos + 5), 16)
                    code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
                    pos = pos + 6
                end
                parts[#parts + 1] = utf8Char(code)
            else
                parts[#parts + 1] = ESCAPES[kind] or fail("escape lạ")
                pos = stop + 2
            end
        end
    end

    function value()
        skip()
        local char = text:sub(pos, pos)
        if char == "{" then
            local object = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == "}" then pos = pos + 1; return object end
            while true do
                skip()
                local key = parseString()
                skip()
                if text:sub(pos, pos) ~= ":" then fail("thiếu dấu :") end
                pos = pos + 1
                object[key] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then return object end
                if sep ~= "," then fail("thiếu dấu , trong object") end
            end
        elseif char == "[" then
            local array = {}
            pos = pos + 1
            skip()
            if text:sub(pos, pos) == "]" then pos = pos + 1; return array end
            while true do
                array[#array + 1] = value()
                skip()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then return array end
                if sep ~= "," then fail("thiếu dấu , trong array") end
            end
        elseif char == '"' then
            return parseString()
        elseif text:sub(pos, pos + 3) == "true" then
            pos = pos + 4; return true
        elseif text:sub(pos, pos + 4) == "false" then
            pos = pos + 5; return false
        elseif text:sub(pos, pos + 3) == "null" then
            pos = pos + 4; return MiniJson.null
        end
        local number = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not number or number == "" then fail("giá trị lạ") end
        pos = pos + #number
        return tonumber(number)
    end

    local result = value()
    skip()
    if pos <= #text then fail("dữ liệu thừa") end
    return result
end

return MiniJson
