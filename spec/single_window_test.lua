local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Mở trang chủ Truyện Việt: chỉ còn một cửa sổ, và chương đang đọc của plugin
-- được đóng trước.

local function stub(fields)
    return setmetatable(fields or {}, {
        __index = function()
            return function() end
        end,
    })
end

local function class()
    local Class = {}
    function Class:extend(definition)
        definition = definition or {}
        definition.__index = definition
        return setmetatable(definition, { __index = self })
    end
    function Class:new(object)
        object = object or {}
        self.__index = self
        setmetatable(object, self)
        if object.init then
            object:init()
        end
        return object
    end
    return Class
end

local queue = {}
local stack = {}
local UIManager = stub()
function UIManager:show(widget)
    table.insert(stack, widget)
end
function UIManager:close(widget)
    for index, item in ipairs(stack) do
        if item == widget then
            table.remove(stack, index)
            if widget.onCloseWidget then
                widget:onCloseWidget()
            end
            return
        end
    end
end
function UIManager:nextTick(callback)
    table.insert(queue, callback)
end
local function flush()
    while #queue > 0 do
        table.remove(queue, 1)()
    end
end

local returns = {}
local Reader = stub({ active = false })
function Reader:returnToPlugin(callback)
    table.insert(returns, callback)
end

local ReaderUI = { instance = nil }

local Menu = class()
function Menu:init() end
package.preload["ui/widget/menu"] = function() return Menu end
package.preload["ui/widget/widget"] = function() return class() end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload["device"] = function()
    return { screen = stub({ getWidth = function() return 600 end,
        getHeight = function() return 800 end }) }
end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/notification", "ui/widget/textviewer", "ui/widget/infomessage",
}) do
    package.preload[name] = function() return class() end
end
for name, value in pairs({
    ["truyenviet/storage"] = stub({
        getHistory = function() return {} end,
        settings = stub({ readSetting = function(_, _, default) return default end }),
    }),
    ["truyenviet/reader"] = Reader,
    ["truyenviet/version"] = "test",
}) do
    package.preload[name] = function() return value end
end
for _, name in ipairs({
    "logger", "ui/network/manager", "ui/trapper",
    "truyenviet/async_pool", "truyenviet/chapter_downloader", "truyenviet/cover_cache",
    "truyenviet/credential_manager", "truyenviet/local_library", "truyenviet/search_service",
    "truyenviet/source_registry", "truyenviet/widgets/story_results", "truyenviet/debugger",
    "truyenviet/helpers", "truyenviet/chapter_cache", "truyenviet/background_fetch",
    "truyenviet/document_builder", "truyenviet/font_helper",
}) do
    package.preload[name] = function() return stub() end
end

local Browser = require("truyenviet/browser")
local Windows = require("truyenviet/windows")

local passed = 0
local function check(condition, message)
    if not condition then
        error(message, 2)
    end
    passed = passed + 1
end

-- Mở trang chủ hai lần (menu, cử chỉ, nút trên thanh tiêu đề...): một cửa sổ.
Browser:showRoot()
local first = stack[#stack]
check(first and Windows.count() == 1, "opens the home window")
Browser:showRoot()
check(#stack == 1 and stack[1] ~= first, "replaces the old home window")
check(Windows.count() == 1, "tracks only the open window")

-- Cửa sổ cũ đóng không mở lại màn trước của nó.
local reopened = 0
stack[1].on_return_callback = function() reopened = reopened + 1 end
Browser:showRoot()
flush()
check(#stack == 1 and reopened == 0, "closing old windows skips their return callbacks")

-- Cửa sổ đã đóng bình thường không còn bị theo dõi.
UIManager:close(stack[1])
check(Windows.count() == 0, "closed windows are forgotten")

-- Đang đọc chương của plugin: đóng chương trước rồi mới mở trang chủ.
Browser:showRoot()
Reader.active = true
ReaderUI.instance = {}
Browser:showRoot()
check(#returns == 1, "closes the open chapter first")
check(#stack == 1, "waits for the chapter to close before opening home")
Reader.active = false
ReaderUI.instance = nil
returns[1]()
check(#stack == 1 and Windows.count() == 1, "opens a single home window after the chapter closed")

-- Sách mở ngoài plugin (Lịch sử KOReader...) không bị đóng.
ReaderUI.instance = {}
Browser:showRoot()
check(#returns == 1 and #stack == 1, "leaves books opened outside the plugin alone")

print(string.format("single_window_test: %d checks passed", passed))
