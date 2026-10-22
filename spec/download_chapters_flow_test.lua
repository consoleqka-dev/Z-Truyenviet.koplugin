local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Luồng tải chương nền của browser.lua với widget KOReader và DownloadJob
-- giả: ô tiến độ là toast, ẩn khi đang đọc, xử lý kết quả/hủy/bận.

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
local shown = {}
local UIManager = stub()
function UIManager:show(widget)
    table.insert(shown, widget)
end
function UIManager:close(widget)
    for index = #shown, 1, -1 do
        if shown[index] == widget then
            table.remove(shown, index)
        end
    end
    if widget.onCloseWidget then
        widget:onCloseWidget()
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
local function shownOfKind(kind)
    local found = {}
    for _, widget in ipairs(shown) do
        if widget.kind == kind then
            table.insert(found, widget)
        end
    end
    return found
end

local function widgetClass(kind)
    local Class = class()
    Class.kind = kind
    return Class
end

local TextWidget = class()
function TextWidget:setText(text)
    self.text = text
end
local FrameContainer = class()
function FrameContainer:getSize()
    return { w = 100, h = 20 }
end
local Geom = class()

local ReaderUI = { instance = nil }
local NetworkMgr = stub({
    runWhenOnline = function(_, callback) callback() end,
})
local trapper_wraps = 0
local Trapper = stub({
    wrap = function(_, callback)
        trapper_wraps = trapper_wraps + 1
        callback()
    end,
})

-- DownloadJob giả: giữ opts để test tự gọi on_poll/on_done.
local job_available = true
local job
local DownloadJob = {
    isAvailable = function() return job_available end,
    status = function() return job and not job.finished and job.status or nil end,
    cancel = function(reason) job.cancelled = reason end,
    start = function(opts)
        if job and not job.finished then
            return false, "busy"
        end
        job = { opts = opts, status = { title = opts.title, done = 0, total = opts.total } }
        return true
    end,
}

local cleaned = 0
local download_calls = {}
local ChapterDownloader = {
    cleanupPartials = function() cleaned = cleaned + 1 end,
    listPending = function(_, _, _, chapters) return chapters end,
    download = function(_, source, story, chapters, opts)
        table.insert(download_calls, { chapters = chapters, opts = opts })
        return { downloaded = #chapters, skipped = 0, errors = {} }
    end,
}

local Storage = stub({
    getDownloadProgressPath = function() return "/tmp/download.progress" end,
})

package.preload["ui/widget/menu"] = function() return class() end
package.preload["ui/widget/widget"] = function() return class() end
package.preload["ui/widget/textwidget"] = function() return TextWidget end
package.preload["ui/widget/container/framecontainer"] = function() return FrameContainer end
package.preload["ui/geometry"] = function() return Geom end
package.preload["ui/size"] = function() return { padding = { small = 2 } } end
package.preload["ui/font"] = function() return stub() end
package.preload["ffi/blitbuffer"] = function() return {} end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/network/manager"] = function() return NetworkMgr end
package.preload["ui/trapper"] = function() return Trapper end
package.preload["apps/reader/readerui"] = function() return ReaderUI end
package.preload["device"] = function()
    return { screen = stub({ getWidth = function() return 600 end,
        getHeight = function() return 800 end }) }
end
package.preload["logger"] = function() return stub() end
package.preload["socket.url"] = function()
    return { absolute = function(_, href) return href end }
end
package.preload["util"] = function()
    return { stringLower = string.lower, htmlEntitiesToUtf8 = function(value) return value end }
end
for name, kind in pairs({
    ["ui/widget/buttondialog"] = "ButtonDialog",
    ["ui/widget/confirmbox"] = "ConfirmBox",
    ["ui/widget/infomessage"] = "InfoMessage",
    ["ui/widget/inputdialog"] = "InputDialog",
    ["ui/widget/notification"] = "Notification",
    ["ui/widget/textviewer"] = "TextViewer",
}) do
    package.preload[name] = function() return widgetClass(kind) end
end
for name, value in pairs({
    ["truyenviet/download_job"] = DownloadJob,
    ["truyenviet/chapter_downloader"] = ChapterDownloader,
    ["truyenviet/storage"] = Storage,
    ["truyenviet/version"] = "test",
}) do
    package.preload[name] = function() return value end
end
for _, name in ipairs({
    "truyenviet/async_pool", "truyenviet/document_builder", "truyenviet/background_fetch",
    "truyenviet/chapter_cache", "truyenviet/chapter_order", "truyenviet/chapter_position",
    "truyenviet/cover_cache", "truyenviet/credential_manager", "truyenviet/local_library",
    "truyenviet/reader", "truyenviet/search_service", "truyenviet/source_registry",
    "truyenviet/widgets/story_results", "truyenviet/debugger", "truyenviet/windows",
}) do
    package.preload[name] = function() return stub() end
end

local Browser = require("truyenviet/browser")

local tests_run = 0
local function check(condition, message)
    tests_run = tests_run + 1
    if not condition then
        error(message, 2)
    end
end

local source = { id = "truyenqq", kind = "comic" }
local story = { title = "Truyện Dài", url = "/truyen/dai" }
local page_data = { story = story }
local chapters = { { title = "C1", url = "c1" }, { title = "C2", url = "c2" } }
local view_updates = 0
local view = { updateItems = function() view_updates = view_updates + 1 end }

-- Bắt đầu: không bọc Trapper, dọn .part trước, task chạy chế độ tiến trình con.
Browser:downloadChapters(view, page_data, source, chapters, 3)
check(job and job.opts.total == 2 and job.opts.title == "Truyện Dài", "khởi động việc tải nền")
check(trapper_wraps == 0, "không bọc Trapper (tiến trình con không thừa hưởng coroutine)")
check(cleaned == 1, "dọn .part trước khi tải")
check(job.opts.progress_path == "/tmp/download.progress", "đường dẫn tiến độ")
local indicators = shownOfKind(nil)
check(#indicators == 1 and indicators[1].toast == true, "ô tiến độ là toast, không chặn chạm")
local indicator = indicators[1]
check(indicator.text == "⤓ Truyện Dài 0/2", "ô tiến độ ghi tên truyện và số chương")

local report = function() end
local result = job.opts.task(report)
check(download_calls[1].opts.subprocess == true and download_calls[1].opts.on_progress == report,
    "task gọi ChapterDownloader ở chế độ tiến trình con")
check(result.downloaded == 2, "task trả kết quả tải")

-- Tiến độ: cập nhật chữ; đang mở sách thì ẩn ô, đóng sách thì hiện lại.
job.opts.on_poll({ title = "Truyện Dài", done = 1, total = 2 })
check(indicator.text == "⤓ Truyện Dài 1/2" and indicator.shown, "cập nhật tiến độ")
ReaderUI.instance = {}
job.opts.on_poll({ title = "Truyện Dài", done = 1, total = 2 })
check(not indicator.shown and #shownOfKind(nil) == 0, "đang đọc thì ẩn ô tiến độ")
ReaderUI.instance = nil
job.opts.on_poll({ title = "Truyện Dài", done = 2, total = 2 })
check(indicator.shown and #shownOfKind(nil) == 1, "thôi đọc thì hiện lại")

-- Bận: bấm tải truyện khác thì hỏi hủy, không tạo việc mới.
local first_job = job
Browser:downloadChapters(view, page_data, source, chapters, 0)
check(job == first_job, "không chạy việc thứ hai")
local dialogs = shownOfKind("ButtonDialog")
check(#dialogs == 1 and dialogs[1].title:find("Truyện Dài\": 0/2", 1, true), "hiện hộp hỏi hủy khi đang bận")
dialogs[1].buttons[1][1].callback()
check(job.cancelled == "cancelled", "nút Hủy tải nền hủy việc")

-- Xong khi không đọc: thêm vào lịch sử, cập nhật danh sách, hỏi gộp file.
local added
G_reader_settings = {
    addDocument = function(_, path) added = path end,
    flush = function() end,
}
job.finished = true
job.opts.on_done(true, { downloaded = 2, skipped = 0, errors = { "C3: lỗi" }, first_path = "/x/c1.cbz" })
check(not indicator.shown, "xong thì đóng ô tiến độ")
check(added == "/x/c1.cbz", "tiến trình chính ghi chương đầu vào lịch sử")
check(view_updates == 1, "cập nhật danh sách đang hiện")
local boxes = shownOfKind("ConfirmBox")
check(#boxes == 1 and boxes[1].text:find("tổng 5 chương") and boxes[1].text:find("C3: lỗi"), "hỏi gộp file kèm lỗi")

-- Xong khi đang đọc: chỉ báo nhỏ, không bật hộp thoại.
shown = {}
ReaderUI.instance = {}
Browser:downloadChapters(view, page_data, source, chapters, 0)
job.finished = true
job.opts.on_done(true, { downloaded = 2, skipped = 0, errors = {} })
check(#shownOfKind("ConfirmBox") == 0, "đang đọc thì không bật hộp gộp file")
local notes = shownOfKind("Notification")
check(#notes == 1 and notes[1].text:find("Đã tải xong 2 chương"), "đang đọc thì chỉ báo nhỏ")
ReaderUI.instance = nil

-- View đã ẩn (đang mở chương) thì không cập nhật.
shown = {}
view_updates = 0
view._truyenviet_hidden = true
Browser:downloadChapters(view, page_data, source, chapters, 0)
job.finished = true
job.opts.on_done(true, { downloaded = 1, skipped = 0, errors = {} })
check(view_updates == 0, "không cập nhật view đã ẩn")
view._truyenviet_hidden = nil

-- Hủy: báo đã hủy; Exit: im lặng; lỗi: dọn .part và báo lỗi.
shown = {}
Browser:downloadChapters(view, page_data, source, chapters, 0)
job.finished = true
job.opts.on_done(false, nil, "cancelled")
notes = shownOfKind("Notification")
check(#notes == 1 and notes[1].text:find("Đã hủy tải nền"), "báo đã hủy")

shown = {}
Browser:downloadChapters(view, page_data, source, chapters, 0)
job.finished = true
job.opts.on_done(false, nil, "exit")
check(#shown == 0, "Exit thì không hiện gì")

shown = {}
cleaned = 0
Browser:downloadChapters(view, page_data, source, chapters, 0)
job.finished = true
job.opts.on_done(false, nil, "Tải nền bị treo")
check(cleaned == 2, "lỗi thì dọn .part")
local errors = shownOfKind("InfoMessage")
check(#errors + #shownOfKind("TextViewer") + #shownOfKind("ButtonDialog") >= 1, "lỗi thì báo")

-- Exit khi ô tiến độ đang hiện: tự đóng để KOReader thoát được.
shown = {}
Browser:downloadChapters(view, page_data, source, chapters, 0)
indicator = shownOfKind(nil)[1]
indicator:onExit()
check(#shownOfKind(nil) == 0 and not indicator.shown, "Exit đóng ô tiến độ")
job.finished = true

-- Không fork được: chạy cách cũ trong coroutine (có Trapper).
shown = {}
job_available = false
download_calls = {}
Browser:downloadChapters(view, page_data, source, chapters, 0)
check(trapper_wraps == 1, "cách cũ chạy trong Trapper")
flush()
G_reader_settings = nil

print(string.format("download_chapters_flow_test: %d checks passed", tests_run))
