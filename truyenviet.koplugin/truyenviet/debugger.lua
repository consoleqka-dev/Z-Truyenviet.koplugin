local Storage = require("truyenviet/storage")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local Debug = {}

-- Giới hạn kích thước log: vượt ngưỡng thì đổi tên thành .1 (ghi đè bản .1 cũ)
local MAX_LOG_BYTES = 2 * 1024 * 1024
local ROTATE_CHECK_EVERY = 100
local writes_since_check = ROTATE_CHECK_EVERY

local function safe_write(path, text)
    local ok, f = pcall(function() return io.open(path, "a") end)
    if not ok or not f then return end
    f:write(text)
    f:close()
end

local function rotate_if_needed(path)
    writes_since_check = writes_since_check + 1
    if writes_since_check < ROTATE_CHECK_EVERY then return end
    writes_since_check = 0
    local size = lfs.attributes(path, "size")
    if size and size > MAX_LOG_BYTES then
        pcall(os.rename, path, path .. ".1")
    end
end

function Debug.write(msg)
    local ok, root = pcall(function() return Storage:getRootDir() end)
    if not ok or not root then return end
    local logpath = ffiutil.joinPath(root, "truyenviet-debug.txt")
    rotate_if_needed(logpath)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " " .. tostring(msg) .. "\n"
    safe_write(logpath, line)
end

-- Log chi tiết (header, body, từng request): chỉ ghi khi
-- ["debug_verbose"] = true trong settings/truyenviet.lua
function Debug.isVerbose()
    local settings = Storage.settings
    return settings ~= nil and settings:isTrue("debug_verbose")
end

function Debug.verbose(msg)
    if Debug.isVerbose() then
        Debug.write(msg)
    end
end

return Debug
