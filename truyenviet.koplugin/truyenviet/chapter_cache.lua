local Debug = require("truyenviet/debugger")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local has_buffer, buffer = pcall(require, "string.buffer")

-- Mục lục chương đã lưu: kết quả thô của source:getStoryPage (trước
-- ChapterOrder.apply) theo từng trang, để mở truyện mà không chờ mạng.
local ChapterCache = {
    version = 1,
    -- Mục lục mới hơn chừng này giây thì không lấy lại khi mở truyện.
    ttl = 10 * 60,
    max_files = 120,
    keep_files = 100,
    -- Giới hạn số trang dò khi tìm mục lục của một truyện.
    max_scan_pages = 50,
}

function ChapterCache.isAvailable()
    return has_buffer == true
end

local function cacheKey(source_id, url, page)
    return string.format("%s|%s|%d", tostring(source_id), tostring(url), tonumber(page) or 1)
end

local function cachePath(key)
    return ffiutil.joinPath(Storage:getChapterCacheDir(), Util.stableHash(key) .. ".bin")
end

local function readFile(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    return content
end

-- Trả về data ({ story, page, total_pages, chapters }), saved_at; nil nếu
-- chưa lưu. File hỏng hoặc khác phiên bản bị xóa.
function ChapterCache.get(source_id, url, page)
    if not has_buffer or not source_id or not url then
        return nil
    end
    local key = cacheKey(source_id, url, page)
    local path = cachePath(key)
    local content = readFile(path)
    if not content then
        return nil
    end
    local ok, entry = pcall(buffer.decode, content)
    if not ok or type(entry) ~= "table" or entry.v ~= ChapterCache.version
            or entry.key ~= key or type(entry.data) ~= "table"
            or type(entry.data.chapters) ~= "table" then
        -- Trùng hash với truyện khác thì giữ file của truyện đó.
        if not (ok and type(entry) == "table" and entry.v == ChapterCache.version
                and type(entry.key) == "string" and entry.key ~= key) then
            os.remove(path)
        end
        return nil
    end
    return entry.data, tonumber(entry.saved_at)
end

local function prune(dir)
    local files = {}
    pcall(function()
        for name in lfs.dir(dir) do
            if name:match("%.bin$") then
                local path = ffiutil.joinPath(dir, name)
                table.insert(files, { path = path, time = lfs.attributes(path, "modification") or 0 })
            end
        end
    end)
    if #files <= ChapterCache.max_files then
        return
    end
    table.sort(files, function(left, right)
        if left.time ~= right.time then
            return left.time < right.time
        end
        return left.path < right.path
    end)
    for index = 1, #files - ChapterCache.keep_files do
        os.remove(files[index].path)
    end
end

-- Lưu một trang mục lục; page_data là kết quả thô của nguồn.
function ChapterCache.put(source_id, url, page, page_data)
    if not has_buffer or not source_id or not url or type(page_data) ~= "table"
            or type(page_data.chapters) ~= "table" then
        return false
    end
    local key = cacheKey(source_id, url, page)
    local entry = {
        v = ChapterCache.version,
        key = key,
        saved_at = os.time(),
        data = Util.plainData({
            story = page_data.story,
            page = page_data.page or page,
            total_pages = page_data.total_pages,
            chapters = page_data.chapters,
        }),
    }
    local ok, content = pcall(buffer.encode, entry)
    if not ok then
        Debug.write("[Mục lục] Không mã hóa được: " .. tostring(content))
        return false
    end
    local path = cachePath(key)
    local tmp = path .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then
        Debug.write("[Mục lục] Không ghi được " .. tmp)
        return false
    end
    local written = file:write(content)
    file:close()
    if not written or not os.rename(tmp, path) then
        os.remove(tmp)
        Debug.write("[Mục lục] Không lưu được " .. path)
        return false
    end
    prune(Storage:getChapterCacheDir())
    return true
end

function ChapterCache.clear()
    local dir = Storage:getChapterCacheDir()
    pcall(function()
        for name in lfs.dir(dir) do
            if name:match("%.bin$") or name:match("%.tmp$") then
                os.remove(ffiutil.joinPath(dir, name))
            end
        end
    end)
end

-- Số chương trong new_chapters chưa có (theo url) trong old_chapters.
function ChapterCache.newChapterCount(old_chapters, new_chapters)
    local known = {}
    for _, chapter in ipairs(old_chapters or {}) do
        if chapter.url then
            known[chapter.url] = true
        end
    end
    local count = 0
    for _, chapter in ipairs(new_chapters or {}) do
        if chapter.url and not known[chapter.url] then
            count = count + 1
        end
    end
    return count
end

-- Mọi chương đã lưu của một truyện (gộp các trang); nil nếu chưa lưu trang nào.
function ChapterCache.chaptersFor(source_id, url)
    local first, total_pages
    for page = 1, ChapterCache.max_scan_pages do
        local data = ChapterCache.get(source_id, url, page)
        if data then
            first = page
            total_pages = math.max(1, tonumber(data.total_pages) or 1)
            break
        end
    end
    if not first then
        return nil
    end
    local chapters = {}
    for page = 1, math.min(total_pages, ChapterCache.max_scan_pages) do
        local data = ChapterCache.get(source_id, url, page)
        for _, chapter in ipairs(data and data.chapters or {}) do
            table.insert(chapters, chapter)
        end
    end
    return chapters
end

return ChapterCache
