local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local mock_data_dir = "/tmp/truyenviet_font_test"
local font_dir = mock_data_dir .. "/plugins/truyenviet.koplugin/fonts"
local font_path = font_dir .. "/BeVietnamPro-Regular.ttf"
local patch_path = mock_data_dir .. "/patches/2--ui-font.lua"
os.execute("rm -rf " .. mock_data_dir)
os.execute("mkdir -p " .. font_dir)

package.preload["datastorage"] = function()
    return {
        getDataDir = function() return mock_data_dir end,
    }
end

-- FontList:getFontList() trả về danh sách font KOReader đã quét.
local scanned_fonts = { "/fonts/noto/NotoSans-Regular.ttf" }
package.preload["fontlist"] = function()
    return {
        getFontList = function() return scanned_fonts end,
    }
end

local broken_fonts = {}
local face_calls = {}
package.preload["ui/font"] = function()
    return {
        fontmap = {},
        sizemap = { infofont = 22, smallinfofont = 18 },
        getFace = function(_, name, size)
            table.insert(face_calls, name)
            if broken_fonts[name] then
                error("cannot load " .. name)
            end
            return { name = name, size = size }
        end,
    }
end

package.preload["ffi/util"] = function()
    return {
        joinPath = function(...)
            return (table.concat({ ... }, "/"):gsub("/+", "/"))
        end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local f = io.open(path, "r")
            if not f then
                return nil
            end
            f:close()
            local entry = { mode = "file" }
            return field and entry[field] or entry
        end,
    }
end

package.preload["util"] = function()
    return {
        makePath = function(path)
            os.execute("mkdir -p '" .. path .. "'")
            return true
        end,
        arrayContains = function(list, value)
            for _, item in ipairs(list) do
                if item == value then return true end
            end
            return false
        end,
    }
end

local function readFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function writeFile(path, content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
end

local FontHelper = require("truyenviet/font_helper")
local function reset()
    FontHelper._font_path = nil
    FontHelper._setup_done = nil
end

local function run()
    assert(FontHelper.FONT_NAME == "BeVietnamPro-Regular.ttf", "Font name must be BeVietnamPro-Regular.ttf")
    assert(FontHelper.FONT_FAMILY == "Be Vietnam Pro", "Font family must be Be Vietnam Pro")

    -- 1. Thiếu file font: không đăng ký, không ghi patch, getFace dùng font mặc định.
    reset()
    assert(FontHelper:getFontPath() == nil, "Missing font file must not resolve")
    FontHelper:setupFont()
    assert(#scanned_fonts == 1, "Missing font must not be registered")
    assert(FontHelper:installUserPatch() == false, "Patch must not be written without the font file")
    assert(FontHelper:isUserPatchInstalled() == false, "No patch file without the font")
    assert(FontHelper:getFace("smallinfofont", 18).name == "smallinfofont", "Fallback to the alias face")

    -- 2. Có file font trong thư mục plugin: đăng ký đường dẫn tuyệt đối một lần.
    writeFile(font_path, "fake font")
    reset()
    assert(FontHelper:getFontPath() == font_path, "Plugin font path must be found")
    FontHelper:setupFont()
    FontHelper:registerFontPath(font_path)
    local registered = 0
    for _, path in ipairs(scanned_fonts) do
        if path == font_path then registered = registered + 1 end
    end
    assert(registered == 1, "Font path must be registered exactly once")

    -- 3. installUserPatch ghi patch v2 dùng đường dẫn tuyệt đối.
    assert(FontHelper:installUserPatch() == true, "installUserPatch should succeed")
    assert(FontHelper:isUserPatchInstalled() == true, "Patch should be reported as installed")
    local content = assert(readFile(patch_path), "Patch file must exist")
    assert(content:find(FontHelper.PATCH_MARKER, 1, true), "Patch must carry the v2 marker")
    assert(content:find("/plugins/truyenviet.koplugin/fonts/BeVietnamPro-Regular.ttf", 1, true),
        "Patch must use the plugin font path")
    assert(content:find("Font:getFace(font_path, 16)", 1, true), "Patch must test-load the font first")
    assert(loadstring(content), "Patch must be valid Lua")

    -- 4. Patch cũ (không có marker) được tự nâng cấp; patch v2 giữ nguyên.
    writeFile(patch_path, "-- Old patch\nFont.fontmap.infofont = 'ComicHelvetic-Light.ttf'")
    FontHelper:autoUpgradeOldPatch()
    assert(readFile(patch_path):find(FontHelper.PATCH_MARKER, 1, true), "Legacy patch must be upgraded")
    local custom = "-- " .. FontHelper.PATCH_MARKER .. " (user edited)"
    writeFile(patch_path, custom)
    FontHelper:autoUpgradeOldPatch()
    assert(readFile(patch_path) == custom, "Current patch must not be rewritten")

    -- 5. removeUserPatch
    FontHelper:removeUserPatch()
    assert(FontHelper:isUserPatchInstalled() == false, "Patch should be removed")

    -- 6. getFace dùng font plugin; font hỏng thì quay về font mặc định và nhớ lại.
    local face = FontHelper:getFace("smallinfofont", 18)
    assert(face.name == font_path and face.size == 18, "getFace must use the plugin font")
    assert(FontHelper:getFace("infofont").size == 22, "Size comes from Font.sizemap")
    broken_fonts[font_path] = true
    face = FontHelper:getFace("smallinfofont", 18)
    assert(face.name == "smallinfofont", "Broken font falls back to the alias")
    face_calls = {}
    FontHelper:getFace("smallinfofont", 18)
    assert(#face_calls == 1 and face_calls[1] == "smallinfofont", "Broken font is not retried")
end

local ok, err = pcall(run)
os.execute("rm -rf " .. mock_data_dir)
if not ok then
    error(err, 0)
end
print("FontHelper tests passed successfully!")
