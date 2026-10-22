local DataStorage = require("datastorage")
local Font = require("ui/font")
local FontList = require("fontlist")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local FontHelper = {
    FONT_NAME = "BeVietnamPro-Regular.ttf",
    FONT_FAMILY = "Be Vietnam Pro",
    FONT_MEDIUM_NAME = "BeVietnamPro-Medium.ttf",
}

-- Tìm đường dẫn tuyệt đối tới font có thật đúng một lần, ưu tiên font nằm trong thư mục plugin.
-- Gọi Font:getFace với file không tồn tại khiến KOReader ghi log lỗi ở mỗi lần vẽ widget.
function FontHelper:getFontPath()
    if self._font_path ~= nil then
        return self._font_path or nil
    end
    local data_dir = DataStorage:getDataDir()
    local candidates = {
        ffiutil.joinPath(data_dir, "plugins/truyenviet.koplugin/fonts/" .. self.FONT_NAME),
    }
    local info = debug.getinfo(1, "S")
    local src = info and info.source and info.source:match("@?(.*)")
    local dir = src and src:match("^(/.*)/[^/]+$")
    if dir then
        candidates[#candidates + 1] = ffiutil.joinPath(dir, "../fonts/" .. self.FONT_NAME)
    end
    candidates[#candidates + 1] = ffiutil.joinPath(data_dir, "fonts/" .. self.FONT_NAME)
    self._font_path = false
    for _, path in ipairs(candidates) do
        if path:sub(1, 1) == "/" and lfs.attributes(path, "mode") == "file" then
            self._font_path = path
            break
        end
    end
    return self._font_path or nil
end

-- Font:getFace luôn ghép FontList.fontdir vào trước tên font, kể cả đường dẫn tuyệt đối,
-- nên chỉ nạp được font ngoài thư mục đó qua bước dò dự phòng trong FontList.fontlist.
-- Phải để KOReader quét xong trước: danh sách đã có phần tử thì getFontList bỏ qua bước quét.
function FontHelper:registerFontPath(path)
    local fonts = FontList:getFontList()
    if not util.arrayContains(fonts, path) then
        table.insert(fonts, path)
    end
end

function FontHelper:setupFont()
    if self._setup_done then return end
    self._setup_done = true

    pcall(function()
        local font_path = self:getFontPath()
        if font_path then
            self:registerFontPath(font_path)
        end
        -- Nâng cấp patch cũ (tên font trần, gây crash) sang bản dùng đường dẫn tuyệt đối
        self:autoUpgradeOldPatch()
    end)
end

-- Backward compatibility alias
function FontHelper:setupComicFont()
    self:setupFont()
end

FontHelper.PATCH_MARKER = "truyenviet-font-patch v2"

function FontHelper:autoUpgradeOldPatch()
    pcall(function()
        local data_dir = DataStorage:getDataDir()
        local patch_file = ffiutil.joinPath(data_dir, "patches/2--ui-font.lua")
        local f = io.open(patch_file, "r")
        if f then
            local content = f:read("*all")
            f:close()
            if content and not content:find(self.PATCH_MARKER, 1, true) then
                self:installUserPatch()
            end
        end
    end)
end

-- Chỉ ghi patch khi file font có thật; patch tự kiểm tra lại lúc khởi động.
function FontHelper:installUserPatch()
    self:setupFont()
    if not self:getFontPath() then
        return false
    end
    local data_dir = DataStorage:getDataDir()
    local patches_dir = ffiutil.joinPath(data_dir, "patches")
    util.makePath(patches_dir)

    local patch_file = ffiutil.joinPath(patches_dir, "2--ui-font.lua")
    local patch_content = [[
-- KOReader User Patch for Be Vietnam Pro UI Font (Created by Truyện Việt)
-- truyenviet-font-patch v2: dùng đường dẫn tuyệt đối tới font trong thư mục plugin,
-- chỉ áp dụng khi file font tồn tại và nạp được; nếu không, giữ nguyên font mặc định.
pcall(function()
    local DataStorage = require("datastorage")
    local Font = require("ui/font")
    local FontList = require("fontlist")
    local lfs = require("libs/libkoreader-lfs")

    local font_path = DataStorage:getDataDir() .. "/plugins/truyenviet.koplugin/fonts/BeVietnamPro-Regular.ttf"
    if font_path:sub(1, 1) ~= "/" or lfs.attributes(font_path, "mode") ~= "file" then
        return
    end

    -- Font:getFace ghép FontList.fontdir vào trước mọi tên font, nên đường dẫn tuyệt đối
    -- chỉ nạp được qua bước dò dự phòng trong FontList.fontlist (sau khi đã quét xong).
    local fonts = FontList:getFontList()
    local registered = false
    for _, path in ipairs(fonts) do
        if path == font_path then
            registered = true
            break
        end
    end
    if not registered then
        table.insert(fonts, font_path)
    end

    -- Nạp thử trước khi đổi font giao diện: Font:getFace trả về nil sẽ làm crash widget.
    if not Font:getFace(font_path, 16) then
        return
    end

    for _, alias in ipairs({
        "cfont", "infofont", "smallinfofont", "xx_smallinfofont",
        "tfont", "smalltfont", "x_smalltfont",
        "ffont", "smallffont", "largeffont",
        "rifont", "pgfont",
    }) do
        Font.fontmap[alias] = font_path
    end
end)
]]

    local f = io.open(patch_file, "w")
    if f then
        f:write(patch_content)
        f:close()
        return true
    end
    return false
end

function FontHelper:removeUserPatch()
    local data_dir = DataStorage:getDataDir()
    local patch_file = ffiutil.joinPath(data_dir, "patches/2--ui-font.lua")
    os.remove(patch_file)
    return true
end

function FontHelper:isUserPatchInstalled()
    local data_dir = DataStorage:getDataDir()
    local patch_file = ffiutil.joinPath(data_dir, "patches/2--ui-font.lua")
    local f = io.open(patch_file, "r")
    if f then
        f:close()
        return true
    end
    return false
end

function FontHelper:getFace(alias, size)
    pcall(function() self:setupFont() end)
    local font_path = self:getFontPath()
    size = size or (Font.sizemap and Font.sizemap[alias or "infofont"])
    if font_path and size then
        local ok, face = pcall(Font.getFace, Font, font_path, size)
        if ok and face then
            return face
        end
        -- Font hỏng: ghi nhớ để lần sau dùng thẳng font mặc định
        self._font_path = false
    end
    return Font:getFace(alias or "infofont", size)
end

return FontHelper
