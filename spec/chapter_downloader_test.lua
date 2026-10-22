local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local downloaded = {
    existing = true,
}

package.preload["truyenviet/storage"] = function()
    return {
        isDownloaded = function(_, _, _, chapter)
            return downloaded[chapter.url] == true
        end,
        getChapterPath = function(_, _, _, chapter)
            return "unused-" .. chapter.url
        end,
    }
end

package.preload["truyenviet/document_builder"] = function()
    return {
        build = function(_, _, _, chapter)
            if chapter.url == "build-fail" then
                return nil, "build failed"
            end
            downloaded[chapter.url] = true
            return "downloaded-" .. chapter.url
        end,
    }
end

local ChapterDownloader = require("truyenviet/chapter_downloader")
local tests_run = 0

local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format(
            "%s: expected %s, got %s",
            message,
            tostring(expected),
            tostring(actual)
        ))
    end
end

local source = {
    getChapter = function(_, chapter)
        if chapter.url == "fetch-fail" then
            return nil, "fetch failed"
        end
        return { content = chapter.title }
    end,
}
local story = { title = "Demo", url = "story" }
local chapters = {
    { title = "Đã có", url = "existing" },
    { title = "Tải được", url = "success" },
    { title = "Lỗi tải", url = "fetch-fail" },
    { title = "Lỗi dựng", url = "build-fail" },
}

local pending = ChapterDownloader:listPending(source, story, chapters)
assertEqual(3, #pending, "Pending chapter count")

local result = ChapterDownloader:download(source, story, chapters)
assertEqual(1, result.downloaded, "Downloaded chapter count")
assertEqual(1, result.skipped, "Skipped chapter count")
assertEqual(2, #result.errors, "Failed chapter count")
assertEqual(true, downloaded.success, "Successful chapter is persisted")

-- Chế độ tiến trình con: không yield (kể cả khi đang trong coroutine),
-- không ghi settings, báo tiến độ từng chương, trả first_path.
local settings_touched = false
G_reader_settings = setmetatable({}, {
    __index = function()
        settings_touched = true
        return function() end
    end,
})
downloaded = { existing = true }
local progress = {}
local co = coroutine.create(function()
    return ChapterDownloader:download(source, story, chapters, {
        subprocess = true,
        on_progress = function(status) table.insert(progress, status) end,
    })
end)
local ok, sub_result = coroutine.resume(co)
assertEqual(true, ok, "Subprocess download runs")
assertEqual("dead", coroutine.status(co), "Subprocess download never yields")
assertEqual(1, sub_result.downloaded, "Subprocess downloaded count")
assertEqual("downloaded-success", sub_result.first_path, "First downloaded path is returned")
assertEqual(4, #progress, "Progress reported for every chapter")
assertEqual(4, progress[4].done, "Progress done count")
assertEqual(4, progress[4].total, "Progress total")
assertEqual(2, progress[4].failed, "Progress failed count")
assertEqual(false, settings_touched, "Subprocess mode leaves settings alone")

-- Nguồn async (Copas giả chạy luồng ngay): cũng không yield trong tiến trình con.
local copas_steps = 0
package.preload["copas"] = function()
    return {
        addthread = function(fn) fn() end,
        step = function() copas_steps = copas_steps + 1 end,
    }
end
local async_source = {
    getChapterAsync = source.getChapter,
}
downloaded = { existing = true }
progress = {}
co = coroutine.create(function()
    return ChapterDownloader:download(async_source, story, chapters, {
        subprocess = true,
        on_progress = function(status) table.insert(progress, status) end,
    })
end)
ok, sub_result = coroutine.resume(co)
assertEqual(true, ok, "Async subprocess download runs")
assertEqual("dead", coroutine.status(co), "Async subprocess download never yields")
assertEqual(1, sub_result.downloaded, "Async downloaded count")
assertEqual(4, #progress, "Async progress for every chapter")
assertEqual(false, settings_touched, "Async subprocess mode leaves settings alone")

-- Tiến trình chính (cách cũ): chương đầu tải được thì ghi vào lịch sử KOReader.
local added
G_reader_settings = {
    addDocument = function(_, path) added = path end,
    flush = function() end,
}
downloaded = { existing = true }
co = coroutine.create(function()
    return ChapterDownloader:download(async_source, story, chapters)
end)
local yields = 0
repeat
    ok, sub_result = coroutine.resume(co)
    assertEqual(true, ok, "Main-process async download runs")
    if coroutine.status(co) ~= "dead" then
        yields = yields + 1
    end
until coroutine.status(co) == "dead"
assertEqual(true, yields > 0, "Main-process download yields to the UI")
assertEqual("downloaded-success", added, "Main-process download adds first chapter to history")
G_reader_settings = nil

print(string.format(
    "Chapter downloader tests passed: %d assertions",
    tests_run
))
