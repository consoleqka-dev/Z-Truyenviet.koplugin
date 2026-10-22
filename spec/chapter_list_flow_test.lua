local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Luồng mở mục lục của browser.lua với widget KOReader giả: mở ngay từ mục
-- lục lưu, làm mới nền, dòng trạng thái và tìm chương kề lúc cần.

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

-- UIManager: hàng đợi nextTick chạy bằng tay.
local queue = {}
local shown = {}
local UIManager = stub()
function UIManager:show(widget)
    table.insert(shown, widget)
end
function UIManager:close(widget)
    widget._closed_by_uimanager = true
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

local Menu = class()
function Menu:init() end
function Menu:switchItemTable(_, items, itemnumber)
    self.item_table = items
    self.switch_count = (self.switch_count or 0) + 1
    self.switch_itemnumber = itemnumber
end

local InfoMessage = class()

local online = true
local NetworkMgr = stub({
    isWifiOn = function() return online end,
    runWhenOnline = function(_, callback) callback() end,
})

-- Mục lục lưu trong bộ nhớ.
local cache = {}
local ChapterCache = {
    ttl = 600,
    get = function(source_id, url, page)
        local entry = cache[source_id .. "|" .. url .. "|" .. page]
        if entry then
            return entry.data, entry.saved_at
        end
    end,
    put = function(source_id, url, page, page_data)
        local chapters = {}
        for index, chapter in ipairs(page_data.chapters) do
            chapters[index] = chapter
        end
        cache[source_id .. "|" .. url .. "|" .. page] = {
            data = {
                story = page_data.story,
                page = page_data.page,
                total_pages = page_data.total_pages,
                chapters = chapters,
            },
            saved_at = os.time(),
        }
        return true
    end,
}
function ChapterCache.newChapterCount(old_chapters, new_chapters)
    local known = {}
    for _, chapter in ipairs(old_chapters or {}) do
        known[chapter.url] = true
    end
    local count = 0
    for _, chapter in ipairs(new_chapters or {}) do
        if not known[chapter.url] then
            count = count + 1
        end
    end
    return count
end

-- Việc nền: giữ lại để test tự gọi task/on_done.
local jobs = {}
local fork_ok = true
local BackgroundFetch = {
    run = function(key, task, on_done)
        if not fork_ok then
            return false
        end
        table.insert(jobs, { key = key, task = task, on_done = on_done })
        return true
    end,
}

local favorite_updates = 0
local Storage = stub({
    isFavorite = function() return true end,
    isDownloaded = function() return false end,
    updateFavorite = function() favorite_updates = favorite_updates + 1 end,
})

local reader_calls = {}
local Reader = stub({
    show = function(_, path, on_return, on_next, from_reader, on_prev)
        table.insert(reader_calls, {
            path = path, on_return = on_return, on_next = on_next, on_prev = on_prev,
        })
    end,
})

local Builder = stub({
    getExistingPath = function(_, _, _, chapter)
        return "/books/" .. chapter.url .. ".html"
    end,
})

package.preload["ui/widget/menu"] = function() return Menu end
package.preload["ui/widget/widget"] = function() return class() end
package.preload["ui/widget/infomessage"] = function() return InfoMessage end
package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ui/network/manager"] = function() return NetworkMgr end
package.preload["ui/trapper"] = function()
    return stub({ wrap = function(_, callback) callback() end })
end
package.preload["device"] = function()
    return { screen = stub({ getWidth = function() return 600 end,
        getHeight = function() return 800 end }) }
end
package.preload["logger"] = function() return stub() end
for _, name in ipairs({
    "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/inputdialog",
    "ui/widget/notification", "ui/widget/textviewer",
}) do
    package.preload[name] = function() return class() end
end
for name, value in pairs({
    ["truyenviet/chapter_cache"] = ChapterCache,
    ["truyenviet/background_fetch"] = BackgroundFetch,
    ["truyenviet/storage"] = Storage,
    ["truyenviet/reader"] = Reader,
    ["truyenviet/document_builder"] = Builder,
    ["truyenviet/version"] = "test",
}) do
    package.preload[name] = function() return value end
end
for _, name in ipairs({
    "truyenviet/async_pool", "truyenviet/chapter_downloader", "truyenviet/cover_cache",
    "truyenviet/credential_manager", "truyenviet/local_library", "truyenviet/search_service",
    "truyenviet/source_registry", "truyenviet/widgets/story_results", "truyenviet/debugger",
    "truyenviet/helpers",
}) do
    package.preload[name] = function() return stub() end
end

local Browser = require("truyenviet/browser")
Browser.triggerPrefetchAndPurge = function() end

local tests_run = 0
local function check(condition, message)
    tests_run = tests_run + 1
    if not condition then
        error(message, 2)
    end
end

local function chapterList(count)
    local chapters = {}
    for index = 1, count do
        chapters[index] = { title = "Chương " .. index, url = "c" .. index }
    end
    return chapters
end

local fetches = 0
local remote_chapters = chapterList(3)
local source = {
    id = "src",
    name = "Nguồn",
    kind = "text",
    getStoryPage = function(_, story, page)
        fetches = fetches + 1
        story.author = "Tác giả"
        return { story = story, page = page, total_pages = 1, chapters = remote_chapters }
    end,
}

local function lastView()
    return shown[#shown]
end

local function statusText(view)
    return view.item_table[1].text
end

local function chapterItem(view, title)
    for _, item in ipairs(view.item_table) do
        if item.text == title then
            return item
        end
    end
end

-- Lần đầu: tải chặn, lưu mục lục, không có dòng trạng thái.
local story = { title = "Truyện A", url = "https://a.test/a", source_id = "src" }
Browser:loadStoryPage(story, source, 1, function() end)
check(fetches == 1, "lần đầu phải tải từ nguồn")
check(cache["src|https://a.test/a|1"] ~= nil, "lưu mục lục sau khi tải")
local view = lastView()
check(statusText(view) == "Xóa khỏi tủ truyện", "lần đầu không có dòng trạng thái")
check(favorite_updates == 1, "cập nhật Tủ truyện sau khi tải")

-- Mục lục còn mới: mở ngay, không tải, không chạy nền.
local reopened = { title = "Truyện A", url = "https://a.test/a", source_id = "src" }
Browser:loadStoryPage(reopened, source, 1, function() end)
view = lastView()
check(fetches == 1 and #jobs == 0, "mục lục còn mới thì không tải lại")
check(statusText(view):find("^Cập nhật lúc %d%d:%d%d · chạm để làm mới$"), "dòng trạng thái fresh: " .. statusText(view))
check(reopened.author == "Tác giả", "bổ sung trường truyện từ bản lưu")
check(chapterItem(view, "Chương 3"), "hiện chương từ bản lưu")

-- Mục lục đã cũ: mở ngay và làm mới nền.
cache["src|https://a.test/a|1"].saved_at = os.time() - 3600
remote_chapters = chapterList(5)
local stale_story = { title = "Truyện A", url = "https://a.test/a", source_id = "src" }
Browser:loadStoryPage(stale_story, source, 1, function() end)
view = lastView()
check(fetches == 1 and #jobs == 1, "mục lục cũ: mở ngay rồi chạy nền")
check(jobs[1].key == "src|https://a.test/a|1", "khóa việc nền theo nguồn/truyện/trang")
check(statusText(view) == "⟳ Đang lấy chương mới…", "dòng trạng thái running")
check(view.item_table[1].dim == true, "đang lấy thì dòng trạng thái mờ")
check(not chapterItem(view, "Chương 5"), "chưa có chương mới khi chưa làm mới xong")

-- Đang đọc chương cuối của danh sách lưu: chương kế tìm lúc bấm.
chapterItem(view, "Chương 3").callback()
check(#reader_calls == 1, "mở chương đã tải bằng Reader")
check(view._truyenviet_hidden, "mở chương thì view cũ được đánh dấu đã đóng")
local reading = reader_calls[1]
reading.on_next(false)
flush()
local message = shown[#shown]
check(message.text == "Đang lấy chương mới, thử lại sau giây lát.", "hết chương khi đang làm mới: " .. tostring(message.text))

-- Kết quả nền về (tiến trình con trả story bản sao).
local result = jobs[1].task()
local child_story = {}
for key, value in pairs(result.story) do child_story[key] = value end
child_story.author = "Tác giả mới"
result.story = child_story
jobs[1].on_done(true, result)
check(stale_story.author == "Tác giả mới", "chép thông tin truyện từ tiến trình con")
check(cache["src|https://a.test/a|1"].data.chapters[5] ~= nil, "lưu mục lục mới")
check(favorite_updates == 2, "cập nhật Tủ truyện sau khi làm mới nền")
check(view.switch_count == nil, "view đã đóng thì không dựng lại")

-- Bấm chương sau lần nữa: thấy chương 4 vừa có.
reading.on_next(false)
flush()
check(#reader_calls == 2 and reader_calls[2].path == "/books/c4.html", "chương kế lấy từ mục lục đã làm mới")

-- Quay về mục lục: dòng trạng thái báo số chương mới.
reader_calls[2].on_return()
view = lastView()
check(statusText(view):find("^Có 2 chương mới · %d%d:%d%d$"), "báo chương mới: " .. statusText(view))

-- Kết quả nền về khi view còn mở thì dựng lại tại chỗ, giữ trang.
cache["src|https://a.test/a|1"].saved_at = os.time() - 3600
remote_chapters = chapterList(5)
local visible_story = { title = "Truyện A", url = "https://a.test/a", source_id = "src" }
Browser:loadStoryPage(visible_story, source, 1, function() end)
view = lastView()
local job = jobs[#jobs]
job.on_done(true, job.task())
check(view.switch_count == 1 and view.switch_itemnumber == -1, "dựng lại view đang mở, giữ trang")
check(statusText(view):find("^Đã là mới nhất · "), "không có chương mới: " .. statusText(view))

-- Làm mới thất bại.
cache["src|https://a.test/a|1"].saved_at = os.time() - 3600
Browser:loadStoryPage({ title = "Truyện A", url = "https://a.test/a", source_id = "src" }, source, 1, function() end)
view = lastView()
jobs[#jobs].on_done(false, nil, "mạng hỏng")
check(statusText(view) == "Không cập nhật được · chạm để thử lại", "dòng trạng thái failed")
local fetches_before = fetches
view.item_table[1].callback()
flush()
check(fetches == fetches_before + 1, "chạm dòng trạng thái thì tải lại (chặn)")
view = lastView()
check(statusText(view):find("^Đã là mới nhất · "), "tải lại xong báo trạng thái")

-- Bị hủy (mở truyện khác) thì quay về trạng thái fresh.
cache["src|https://a.test/a|1"].saved_at = os.time() - 3600
Browser:loadStoryPage({ title = "Truyện A", url = "https://a.test/a", source_id = "src" }, source, 1, function() end)
view = lastView()
jobs[#jobs].on_done(false, nil, "cancelled")
check(statusText(view):find("^Cập nhật lúc "), "bị hủy thì không báo lỗi")

-- Không fork được: báo lỗi để người dùng tự làm mới.
cache["src|https://a.test/a|1"].saved_at = os.time() - 3600
fork_ok = false
Browser:loadStoryPage({ title = "Truyện A", url = "https://a.test/a", source_id = "src" }, source, 1, function() end)
check(statusText(lastView()) == "Không cập nhật được · chạm để thử lại", "fork lỗi thì báo không cập nhật được")
fork_ok = true

-- Ngoại tuyến có mục lục lưu: mở từ bản lưu, không tải.
online = false
fetches_before = fetches
local jobs_before = #jobs
Browser:loadStoryPage({ title = "Truyện A", url = "https://a.test/a", source_id = "src" }, source, 1, function() end)
view = lastView()
check(fetches == fetches_before and #jobs == jobs_before, "ngoại tuyến không tải")
check(statusText(view):find("^Ngoại tuyến · danh sách lưu lúc "), "dòng trạng thái offline")
chapterItem(view, "Chương 5").callback()
reader_calls[#reader_calls].on_next(false)
flush()
check(shown[#shown].text == "Đã tới chương cuối trong danh sách đã lưu (chưa cập nhật được).",
    "hết chương khi ngoại tuyến")
online = true

-- Danh sách truyện (vd. Lịch sử đọc): mục "Trên máy" không có trong
-- SourceRegistry nhưng vẫn lấy bìa trích từ file trong CoverCache.
do
    local LocalLibrary = require("truyenviet/local_library")
    local CoverCache = require("truyenviet/cover_cache")
    local SourceRegistry = require("truyenviet/source_registry")
    local StoryResults = require("truyenviet/widgets/story_results")
    LocalLibrary.source_name = "Trên máy"
    LocalLibrary.isLocal = function(story) return story.source_id == "local" end
    SourceRegistry.get = function(_, id)
        if id == "web" then return { name = "Web" } end
    end
    CoverCache.get = function(_, story)
        return story.cover_url and ("/covers/" .. story.url) or nil
    end
    local created
    StoryResults.new = function(_, args) created = args; return args end
    local pdf = { source_id = "local", url = "/sdcard/Books/a.pdf", cover_url = "file:///sdcard/Books/a.pdf" }
    local web = { source_id = "web", url = "/s/1", cover_url = "https://img/1.jpg" }
    local gone = { source_id = "removed", url = "/x", cover_url = "https://img/x.jpg" }
    Browser:showStories("Lịch sử đọc", { pdf, web, gone }, function() end, {})
    check(created and #created.stories == 3, "mở danh sách truyện")
    check(pdf.cover_path == "/covers/" .. pdf.url, "file trên máy có bìa")
    check(pdf.source_name == "Trên máy", "file trên máy có tên nguồn")
    check(web.cover_path == "/covers/" .. web.url and web.source_name == "Web", "truyện online có bìa")
    check(gone.cover_path == nil, "nguồn đã gỡ thì không đọc bìa")
end

print(string.format("chapter_list_flow_test: %d checks passed", tests_run))
