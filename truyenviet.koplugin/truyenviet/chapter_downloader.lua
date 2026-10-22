local Builder = require("truyenviet/document_builder")
local Storage = require("truyenviet/storage")

local ChapterDownloader = {}

function ChapterDownloader:listPending(source, story, chapters)
    local pending = {}
    for _, chapter in ipairs(chapters or {}) do
        if not Storage:isDownloaded(source, story, chapter) then
            table.insert(pending, chapter)
        end
    end
    return pending
end

function ChapterDownloader:cleanupPartials(source, story, chapters)
    for _, chapter in ipairs(chapters or {}) do
        os.remove(Storage:getChapterPath(source, story, chapter) .. ".part")
    end
end

-- Lấy nội dung rồi dựng file cho một chương; trả về đường dẫn hoặc nil, lỗi.
local function fetchAndBuild(fetch, source, story, chapter)
    local ok, payload, fetch_err = pcall(fetch, source, chapter)
    if not ok then
        fetch_err = payload
        payload = nil
    end

    local path
    local build_err
    if payload then
        ok, path, build_err = pcall(Builder.build, Builder, source, story, chapter, payload)
        if not ok then
            build_err = path
            path = nil
        end
    end
    if path then
        return path
    end
    os.remove(Storage:getChapterPath(source, story, chapter) .. ".part")
    return nil, string.format(
        "%s: %s",
        chapter.title,
        tostring(fetch_err or build_err or "lỗi không xác định")
    )
end

-- opts.subprocess: chạy trong tiến trình con (DownloadJob) nên không yield,
-- không ghi settings; tiến trình chính tự addDocument(result.first_path).
-- opts.on_progress({ done, total, downloaded, failed }) gọi sau mỗi chương.
function ChapterDownloader:download(source, story, chapters, opts)
    opts = opts or {}
    chapters = chapters or {}
    local subprocess = opts.subprocess == true
    local result = {
        downloaded = 0,
        skipped = 0,
        errors = {},
    }

    local function yield(text)
        if not subprocess and coroutine.running() then
            coroutine.yield(text)
        end
    end

    local function finishChapter(path, err)
        if path then
            result.downloaded = result.downloaded + 1
            if not result.first_path then
                result.first_path = path
                if not subprocess and G_reader_settings and G_reader_settings.addDocument then
                    G_reader_settings:addDocument(path)
                    G_reader_settings:flush()
                end
            end
        elseif err then
            table.insert(result.errors, err)
        end
        if opts.on_progress then
            opts.on_progress({
                done = result.downloaded + result.skipped + #result.errors,
                total = #chapters,
                downloaded = result.downloaded,
                failed = #result.errors,
            })
        end
    end

    if source.kind == "comic" or type(source.getChapterAsync) ~= "function" then
        local total_chaps = #chapters
        for i, chapter in ipairs(chapters) do
            yield(string.format("Đang tải %d/%d chương...", i, total_chaps))
            if Storage:isDownloaded(source, story, chapter) then
                result.skipped = result.skipped + 1
                finishChapter()
            else
                finishChapter(fetchAndBuild(source.getChapter, source, story, chapter))
            end
            collectgarbage()
        end
    else
        local copas = require("copas")
        local active_downloads = 0
        local max_concurrent = source.max_concurrent or 10

        for _, chapter in ipairs(chapters) do
            if Storage:isDownloaded(source, story, chapter) then
                result.skipped = result.skipped + 1
                finishChapter()
            else
                while active_downloads >= max_concurrent do
                    copas.step()
                end
                active_downloads = active_downloads + 1

                copas.addthread(function()
                    finishChapter(fetchAndBuild(source.getChapterAsync, source, story, chapter))
                    active_downloads = active_downloads - 1
                end)
            end

            if active_downloads > 0 then
                copas.step(0)
            end
            yield(string.format("Đang lấy chương... còn %d chương", active_downloads))
            collectgarbage()
        end

        while active_downloads > 0 do
            -- Tiến trình con chờ chặn được; tiến trình chính phải nhường UI.
            if subprocess then
                copas.step()
            else
                copas.step(0)
                yield(string.format("Đang tải %d chương...", active_downloads))
            end
        end
    end

    return result
end

return ChapterDownloader
