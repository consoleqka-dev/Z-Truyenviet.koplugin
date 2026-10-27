local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["dispatcher"] = function()
    return {
        registerAction = function() end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    function WidgetContainer:extend(definition)
        return definition
    end
    return WidgetContainer
end

local browser_show_root_called = false
package.preload["truyenviet/browser"] = function()
    return {
        showRoot = function()
            browser_show_root_called = true
        end,
    }
end

package.preload["truyenviet/reader"] = function()
    return {}
end

package.preload["truyenviet/version"] = function()
    return "3.12.0"
end

package.preload["truyenviet/font_helper"] = function()
    return {
        setupFont = function() end,
    }
end

package.preload["truyenviet/updater"] = function()
    return {
        scheduleBackgroundCheck = function() end,
    }
end

local Plugin = require("main")
local menu_items = {}

Plugin.addToMainMenu({
    ui = {
        name = "ReaderUI",
    },
}, menu_items)

local reader_item = assert(
    menu_items.truyenviet_reader_tools,
    "ReaderUI menu item was not registered"
)

assert(
    reader_item.sorting_hint == "tools",
    string.format(
        "ReaderUI sorting_hint must target KOReader's 'tools' menu, got %s",
        tostring(reader_item.sorting_hint)
    )
)

-- Title must be clean "Truyện Việt" without emoji so it sorts under T
assert(reader_item.text == "Truyện Việt", "Menu text must be clean 'Truyện Việt'")
assert(type(reader_item.callback) == "function", "Menu item must provide callback for 1-tap launch")

local found_gdrive = false
for _, item in ipairs(reader_item.sub_item_table or {}) do
    if item.text and item.text:find("Google Drive") then
        found_gdrive = true
        break
    end
end
assert(found_gdrive, "Google Drive menu item not found in sub_item_table")
assert(type(Plugin.onTruyenVietGDriveDownload) == "function", "onTruyenVietGDriveDownload handler missing")

local found_ota = false
for _, item in ipairs(reader_item.sub_item_table or {}) do
    if item.text and item.text:find("OTA") then
        found_ota = true
        break
    end
end
assert(found_ota, "OTA Update menu item not found in sub_item_table")
assert(type(Plugin.onTruyenVietCheckUpdate) == "function", "onTruyenVietCheckUpdate handler missing")

-- ==================== ZenOS Compatibility Verification ====================
-- ZenOS checks LAUNCH_METHODS = { "onShow", "show", "open", "launch", "onOpen" }
-- and camel = "on" .. key:sub(1,1):upper() .. key:sub(2) -> "onTruyenviet".
-- onShow/onOpen must NOT exist: KOReader broadcasts Show/Open events to plugin
-- modules, which would reopen the browser over a freshly opened chapter.
local LAUNCH_METHODS = { "onShow", "show", "open", "launch", "onOpen" }
assert(Plugin.onShow == nil, "Plugin must not define onShow (Show event is broadcast)")
assert(Plugin.onOpen == nil, "Plugin must not define onOpen (Open event is broadcast)")
for _, method in ipairs({ "show", "open", "launch", "onTruyenviet" }) do
    assert(type(Plugin[method]) == "function", "Plugin must define launch method: " .. method)
end

-- Test that the ZenOS launch method triggers browser:showRoot()
browser_show_root_called = false
Plugin:show()
assert(browser_show_root_called == true, "Plugin:show() must invoke Browser:showRoot()")

-- Test ZenOS scan method resolution
local function is_callable(v) return type(v) == "function" end
local function find_method(mod, key)
    for _i, method in ipairs(LAUNCH_METHODS) do
        if is_callable(mod[method]) then return method end
    end
    local camel = "on" .. key:sub(1, 1):upper() .. key:sub(2)
    if is_callable(mod[camel]) then return camel end
end

local zenos_detected_method = find_method(Plugin, "truyenviet")
assert(zenos_detected_method == "show", "ZenOS must discover the show launch method")

-- Test alphabetical sorting under ZenOS "Choose plugin menu"
local plugin_titles = {
    "Auto frontlight", "Calibre", "Exporter", "Invert colors", "Kosync",
    "NewsDownloader", "Periodic timer", "ReadTimer", "SSH server",
    "Statistics", "System statistics", "Terminal", "Tweak document settings",
    "Wallabag",
}
table.insert(plugin_titles, reader_item.text) -- "Truyện Việt"
table.sort(plugin_titles, function(a, b) return a < b end)

-- Find position of "Truyện Việt"
local pos = 0
for i, title in ipairs(plugin_titles) do
    if title == "Truyện Việt" then
        pos = i
        break
    end
end

assert(plugin_titles[pos - 1] == "Terminal", "Truyện Việt must sort after Terminal")
assert(plugin_titles[pos + 1] == "Tweak document settings", "Truyện Việt must sort before Tweak document settings")

-- "Danh sách chương" khi đang mở sách ngoài plugin: đóng sách trước rồi mới mở.
local ReaderUI = { instance = { file = "/sdcard/Books/Manga/GK/chapter-125.cbz" } }
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload["truyenviet/storage"] = function()
    return { getHistory = function() return {} end }
end
package.preload["truyenviet/local_library"] = function() return {} end
local Reader = require("truyenviet/reader")
local close_callbacks = {}
Reader.active = false
function Reader:returnToPlugin(callback)
    table.insert(close_callbacks, callback or false)
end
browser_show_root_called = false
Plugin:onTruyenVietBackToChapters()
assert(#close_callbacks == 1 and close_callbacks[1], "Chapter list must close an outside book first")
assert(browser_show_root_called == false, "Chapter list must wait for the book to close")
ReaderUI.instance = nil
close_callbacks[1]()
assert(browser_show_root_called == true, "Chapter list opens after the book closed")

-- Không có sách nào mở: mở ngay, không đóng gì.
browser_show_root_called = false
Plugin:onTruyenVietBackToChapters()
assert(#close_callbacks == 1, "Nothing open: nothing to close")
assert(browser_show_root_called == true, "Nothing open: chapter list opens at once")

-- Chương của plugin: về đúng màn trước của chương.
Reader.active = true
ReaderUI.instance = {}
Plugin:onTruyenVietBackToChapters()
assert(#close_callbacks == 2 and close_callbacks[2] == false, "Plugin chapter returns to its own screen")

print("Main menu & ZenOS launcher compatibility tests passed!")
