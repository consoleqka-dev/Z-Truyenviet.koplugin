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
local reader_returns = 0
local Reader = stub({
    show = function(_, path, on_return, on_next, from_reader, on_prev)
        table.insert(reader_calls, {
            path = path, on_return = on_return, on_next = on_next, on_prev = on_prev,
        })
    end,
    returnToPlugin = function()
        reader_returns = reader_returns + 1
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
local metadata_exists, native_progress = true, 0.42
package.preload["docsettings"] = function()
    return {
        findSidecarFile = function(_, path) return metadata_exists and path .. ".sdr/metadata.lua" end,
        open = function()
            return { readSetting = function(_, key)
                if key == "percent_finished" then return native_progress end
            end }
        end,
    }
end
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
Storage.isDownloaded = function() return true end
check(chapterItem(view, "Chương 3").mandatory_func() == "Đã tải · 42%", "hiện tiến độ đọc cạnh trạng thái tải")
do
    local function freshLabel()
        local items = Browser:buildChapterItems({ story = story, chapters = chapterList(3),
            page = 1, total_pages = 1 }, source, function() end)
        return chapterItem({ item_table = items }, "Chương 3").mandatory_func()
    end
    metadata_exists = false
    check(freshLabel() == "Đã tải · -", "chương chưa mở hiện dấu gạch ngang")
    metadata_exists, native_progress = true, nil
    check(freshLabel() == "Đã tải · -", "sidecar chưa có tiến độ không hiện phần trăm giả")
    native_progress = 0
    check(freshLabel() == "Đã tải · 0%", "tiến độ đọc hợp lệ bằng không vẫn hiện 0%")
    native_progress = 0.42
    check(freshLabel() == "Đã tải · 42%", "danh sách mới lấy tiến độ đọc sau khi mở chương")
end
Storage.isDownloaded = function() return false end
check(chapterItem(view, "Chương 3").mandatory_func() == "", "chương chưa tải không hiện tiến độ giả")
chapterItem(view, "Chương 3").callback()
check(#reader_calls == 1, "mở chương đã tải bằng Reader")
check(view._truyenviet_hidden, "mở chương thì view cũ được đánh dấu đã đóng")
local reading = reader_calls[1]
local shown_before_end = #shown
reading.on_next(false)
flush()
check(reader_returns == 1, "hết danh sách đang làm mới thì đóng reader để quay về mục lục")
check(#shown == shown_before_end, "không hiện hộp thông báo chặn trên chương cuối")

-- Kết quả nền về (tiến trình con trả story bản sao).
local result = jobs[1].task()
local child_story = {}
for key, value in pairs(result.story) do child_story[key] = value end
child_story.author = "Tác giả mới"
result.story = child_story
local raised
Storage.raiseLatestChapter = function(target, chapters) raised = { story = target, chapters = chapters } end
jobs[1].on_done(true, result)
check(stale_story.author == "Tác giả mới", "chép thông tin truyện từ tiến trình con")
check(raised and raised.story == stale_story and #raised.chapters == 5,
    "làm mới nền nâng chương mới nhất theo mục lục mới")
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
shown_before_end = #shown
reader_calls[#reader_calls].on_next(false)
flush()
check(reader_returns == 2, "hết danh sách ngoại tuyến thì quay về mục lục đã lưu")
check(#shown == shown_before_end, "ngoại tuyến không hiện hộp thông báo chặn")
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

-- Lịch sử đọc: dòng "Đang đọc" kèm tiến độ của chương đọc cuối, chỉ khi
-- chương đó có trên máy và đã có dữ liệu đọc.
do
    local LocalLibrary = require("truyenviet/local_library")
    local StoryResults = require("truyenviet/widgets/story_results")
    local created
    StoryResults.new = function(_, args) created = args; return args end
    LocalLibrary.copyFavoriteCovers = function() end
    Storage.getHistory = function()
        return {
            { story = { source_id = "local", url = "/sdcard/Books/a.pdf" },
                chapter = { title = "a.pdf", url = "/sdcard/Books/a.pdf" } },
            { story = { source_id = "web", url = "/s/1" }, chapter = { title = "Chapter 84", url = "c84" } },
            { story = { source_id = "web", url = "/s/2" }, chapter = { title = "Chapter 2", url = "c2" } },
        }
    end
    Storage.isDownloaded = function(_, _, story) return story.url == "/s/1" end
    metadata_exists, native_progress = true, 0.8
    Browser:showHistory(function() end)
    local stories = created.stories
    check(stories[1].reading_percent == 80, "file trên máy có tiến độ đọc")
    check(stories[2].reading_chapter == "Chapter 84" and stories[2].reading_percent == 80,
        "chương online đã tải có tiến độ đọc")
    check(stories[3].reading_percent == nil, "chương chưa tải không có tiến độ giả")
    check(raised and raised.chapters[1].title == "Chapter 2",
        "Lịch sử nâng chương mới nhất theo chương đang đọc")
    metadata_exists = false
    Browser:showHistory(function() end)
    check(created.stories[2].reading_percent == nil, "chưa mở chương thì không hiện phần trăm")
    metadata_exists = true
    Storage.isDownloaded = function() return false end

    -- Bấm truyện trong Lịch sử đọc: hỏi đọc tiếp, rồi mở đúng chương đọc cuối.
    local loads = {}
    local loadStoryPage = Browser.loadStoryPage
    Browser.loadStoryPage = function(_, story, src, page, back, chapter)
        table.insert(loads, { story = story, source = src, back = back, chapter = chapter })
    end
    local SourceRegistry = require("truyenviet/source_registry")
    local web_source = { name = "Web" }
    SourceRegistry.get = function(_, id)
        if id == "web" then return web_source end
    end
    local history_view = created
    created.story_callback(created.stories[2])
    local box = lastView()
    check(box.ok_text == "Đọc tiếp" and box.cancel_text == "Mục lục"
        and box.text == "Đọc tiếp: Chapter 84?", "Lịch sử đọc hỏi đọc tiếp")
    box.ok_callback()
    flush()
    check(history_view._closed_by_uimanager and #loads == 1 and loads[1].chapter.url == "c84"
        and loads[1].story == created.stories[2], "Đọc tiếp mở chương đọc cuối")

    -- Nút "Tiếp tục" ở trang chủ: cùng hộp hỏi, trang chủ chỉ đóng khi đã chọn.
    local item = Storage.getHistory()[2]
    local home = { name = "home" }
    local homes = 0
    Browser:confirmContinue(item, home, function() homes = homes + 1 end)
    box = lastView()
    check(box.ok_text == "Đọc tiếp" and not home._closed_by_uimanager, "Tiếp tục hỏi trước khi rời trang chủ")
    box.cancel_callback()
    flush()
    check(home._closed_by_uimanager and #loads == 2 and loads[2].chapter == nil
        and loads[2].story == item.story, "Mục lục mở danh sách chương")
    loads[2].back()
    check(homes == 1, "quay lại trang chủ")

    -- Lệnh Tiếp tục đọc (không có cửa sổ): nguồn đã gỡ thì báo lỗi rồi về trang chủ.
    local shown_count = #shown
    Browser:confirmContinue({ story = { source_id = "removed", url = "/x" },
        chapter = { title = "Chương 1", url = "x1" } }, nil, function() homes = homes + 1 end)
    check(#shown == shown_count + 1 and #loads == 2, "nguồn đã gỡ thì báo lỗi")
    Browser.loadStoryPage = loadStoryPage
end

-- Chọn nhiều trong Tủ truyện: tìm bìa lớn cho các truyện đã chọn.
do
    local LocalLibrary = require("truyenviet/local_library")
    Menu.updateItems = function() end
    local a = { source_id = "web", url = "/s/a", title = "A", cover_path = "/covers/a", cover_found = true }
    local b = { source_id = "web", url = "/s/b", title = "B" }
    local c = { source_id = "local", url = "/sdcard/c.pdf", title = "C", cover_path = "/covers/c" }
    Storage.listFavorites = function() return { a, b, c } end
    LocalLibrary.annotate = function(list) return list end
    local searched, merged
    LocalLibrary.findCovers = function(stories)
        searched = stories
        stories[1].cover_found = true
        return stories
    end
    Storage.mergeFavorites = function(_, records) merged = records end
    local removed = {}
    local os_remove = os.remove
    os.remove = function(path) table.insert(removed, path) end
    local favorites_shown = 0
    Browser.showFavorites = function() favorites_shown = favorites_shown + 1 end

    Browser:selectFavoritesToRemove(function() end)
    local view = lastView()
    check(view.title == "Chọn truyện", "màn chọn nhiều không chỉ để xóa")
    local cover_item = view.item_table[2]
    check(cover_item.text == "Tìm ảnh bìa lớn cho 0 truyện đã chọn", "có action tìm bìa")
    cover_item.callback()
    check(searched == nil, "chưa chọn truyện nào thì không tìm")

    view.item_table[4].callback() -- chọn A
    view.item_table[6].callback() -- chọn C
    check(cover_item.text == "Tìm ảnh bìa lớn cho 2 truyện đã chọn", "đếm truyện đã chọn")
    online = false
    cover_item.callback()
    check(searched == nil, "ngoại tuyến thì không tìm")
    online = true
    cover_item.callback()
    flush()
    check(#searched == 2 and searched[1] == a and searched[2] == c, "chỉ tìm truyện đã chọn")
    check(#removed == 1 and removed[1] == "/covers/a", "xóa bìa cũ của truyện online")
    check(a.cover_path == nil and c.cover_path == nil and b.cover_path == nil, "bỏ đường dẫn bìa cũ")
    check(merged == searched, "lưu kết quả vào Tủ truyện")
    check(lastView().text == "Đã tìm được ảnh bìa cho 1/2 truyện.", "báo số bìa tìm được")
    check(view._truyenviet_closed and favorites_shown == 1, "quay về Tủ truyện")
    os.remove = os_remove
end

-- Thư mục "Trên máy": mỗi file hiện tiến độ đọc, file đọc cuối thêm "Đang đọc".
do
    local LocalLibrary = require("truyenviet/local_library")
    local DocSettings = require("docsettings")
    local dir = "/sdcard/Books/GK"
    local read = { [dir .. "/chapter-001.cbz"] = 1, [dir .. "/chapter-002.cbz"] = 0.2 }
    local find_sidecar, open = DocSettings.findSidecarFile, DocSettings.open
    DocSettings.findSidecarFile = function(_, path) return read[path] and path .. ".sdr/metadata.lua" end
    DocSettings.open = function(_, path)
        return { readSetting = function(_, key)
            if key == "percent_finished" then return read[path] end
        end }
    end
    LocalLibrary.entryType = function() return "dir" end
    LocalLibrary.listBooks = function()
        return { dir .. "/chapter-001.cbz", dir .. "/chapter-002.cbz", dir .. "/chapter-003.cbz" }
    end
    Storage.getHistory = function()
        return { { story = { source_id = "local", url = dir },
            chapter = { title = "chapter-002", url = dir .. "/chapter-002.cbz" } } }
    end
    Browser:openLocalEntry({ source_id = "local", url = dir, title = "GK" }, nil, function() end)
    flush()
    local items = lastView().item_table
    check(items[1].text == "chapter-001.cbz" and items[1].mandatory_func() == "100%", "file đã đọc hiện 100%")
    check(items[2].mandatory_func() == "Đang đọc · 20%", "file đọc cuối hiện tiến độ")
    check(items[3].mandatory_func() == "", "file chưa mở để trống")
    DocSettings.findSidecarFile, DocSettings.open = find_sidecar, open
end

-- Tủ truyện: "Tìm lại ảnh bìa lớn" tìm được bìa thì mở lại danh sách (giữ vị
-- trí truyện) để vẽ bìa mới, không chỉ đổi dòng chữ của mục.
do
    local LocalLibrary = require("truyenviet/local_library")
    local SourceRegistry = require("truyenviet/source_registry")
    local StoryResults = require("truyenviet/widgets/story_results")
    package.preload["datastorage"] = package.preload["datastorage"] or function()
        return { getFullDataDir = function() return "/sdcard/koreader" end }
    end
    package.preload["truyenviet/library_import"] = function()
        return { libraryDirs = function() return {} end }
    end
    LocalLibrary.collectDownloadTargets = function(stories) return { targets = {}, stories = stories } end
    LocalLibrary.countFiles = function() return 0 end
    LocalLibrary.sizeOf = function() return 0 end
    LocalLibrary.formatSize = function() return "0 B" end
    LocalLibrary.findCovers = function(stories)
        for _, item in ipairs(stories) do
            item.cover_found = true
            item.cover_path = "/covers/new.jpg"
        end
        return stories
    end
    SourceRegistry.get = function(_, id)
        if id == "web" then return { id = "web", name = "Web" } end
    end
    local created
    StoryResults.new = function(_, args) created = args; return args end
    local reopened
    local show_favorites = Browser.showFavorites
    Browser.showFavorites = function(_, _, focus_story) reopened = focus_story end

    local versus = { source_id = "web", url = "/s/versus", title = "Versus" }
    Browser:showStories("Tủ truyện", { versus }, function() end, { favorites_only = true })
    local list = created
    list.story_hold_callback(versus)
    local find_button
    for _, row in ipairs(lastView().buttons or {}) do
        for _, button in ipairs(row) do
            if button.text == "Tìm lại ảnh bìa lớn" then
                find_button = button
            end
        end
    end
    check(find_button ~= nil, "Tủ truyện có nút tìm lại bìa lớn")
    find_button.callback()
    flush()
    check(versus.cover_found and versus.cover_path == "/covers/new.jpg", "tìm được bìa mới")
    check(list._closed_by_uimanager, "đóng danh sách đang hiện bìa cũ")
    check(reopened == versus, "mở lại Tủ truyện tại truyện vừa tìm bìa")
    Browser.showFavorites = show_favorites
end

print(string.format("chapter_list_flow_test: %d checks passed", tests_run))
