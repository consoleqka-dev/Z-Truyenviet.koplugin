-- Vị trí chương đang đọc trên tổng số, hiện ở thanh trạng thái của KOReader.
local ChapterPosition = {}

-- Cùng quy tắc so khớp với chuyển chương trước/sau trong Browser:openChapter.
function ChapterPosition.isSameChapter(item, chapter)
    if item.url == chapter.url then
        return true
    end
    if item.is_local and chapter.is_local then
        return item.title == chapter.title
    end
    if item.is_local and not chapter.is_local then
        return item.title == chapter.title or item.url == ("local/" .. tostring(chapter.title))
    end
    return false
end

function ChapterPosition.indexOf(chapters, chapter)
    for i, item in ipairs(chapters or {}) do
        if ChapterPosition.isSameChapter(item, chapter) then
            return i
        end
    end
end

-- Thứ tự đọc: chương cũ nhất là 1, kể cả khi mục lục xếp "Mới nhất trước".
-- Mục lục chia nhiều trang thì chỉ biết vị trí trong trang đang mở.
function ChapterPosition.fromChapterList(page_data, chapter, sort_mode)
    local chapters = page_data and page_data.chapters
    local index = chapter and ChapterPosition.indexOf(chapters, chapter)
    if not index then
        return nil
    end
    local total = #chapters
    if (sort_mode or page_data.chapter_sort) == "desc" then
        index = total - index + 1
    end
    local total_pages = tonumber(page_data.total_pages) or 1
    return {
        label = "Chương",
        index = index,
        total = total,
        page = total_pages > 1 and (tonumber(page_data.page) or 1) or nil,
        total_pages = total_pages > 1 and total_pages or nil,
    }
end

function ChapterPosition.fromFolder(paths, path, label)
    for i, item in ipairs(paths or {}) do
        if ChapterPosition.samePath(item, path) then
            return { label = label or "Tập", index = i, total = #paths }
        end
    end
end

function ChapterPosition.format(position)
    if not position then
        return nil
    end
    local text = string.format("%s %d/%d", position.label, position.index, position.total)
    if position.total_pages then
        text = text .. string.format(" · trang %d/%d", position.page, position.total_pages)
    end
    return text
end

-- KOReader có thể nhận cùng file qua /sdcard hoặc /storage/emulated/0:
-- so tên file và thư mục cha.
local function tail(path)
    return tostring(path or ""):match("([^/]+/[^/]+)$") or tostring(path or "")
end

function ChapterPosition.samePath(a, b)
    if not a or not b then
        return false
    end
    return a == b or tail(a) == tail(b)
end

local storage_aliases = { "/storage/emulated/0/", "/storage/self/primary/", "/sdcard/" }

local function canonical(path)
    path = tostring(path or ""):gsub("/+$", "")
    for _, alias in ipairs(storage_aliases) do
        if path:sub(1, #alias) == alias then
            return "/sdcard/" .. path:sub(#alias + 1)
        end
    end
    return path
end

-- Thư mục truyện chứa file nếu file nằm đúng <root>/<nguồn>/<truyện>/<file>
-- (nơi plugin tải chương về). Trả về thư mục theo dạng đường dẫn của file.
function ChapterPosition.downloadFolder(root, file)
    if type(root) ~= "string" or type(file) ~= "string" then
        return nil
    end
    local prefix = canonical(root) .. "/"
    local path = canonical(file)
    if path:sub(1, #prefix) ~= prefix then
        return nil
    end
    local source = path:sub(#prefix + 1):match("^([^/]+)/[^/]+/[^/]+$")
    if not source or source == "cache" then
        return nil
    end
    return file:match("^(.*)/[^/]+$")
end

return ChapterPosition
