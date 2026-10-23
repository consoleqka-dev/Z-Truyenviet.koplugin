local Progress = {}
local bundle_key = "truyenviet_chapter_progress"

local function number(value)
    value = tonumber(value)
    if value and value == value and value ~= math.huge and value ~= -math.huge then
        return value
    end
end

local function percentage(value)
    value = number(value)
    return value and math.floor(math.max(0, math.min(1, value)) * 100 + 0.5) or 0
end

local function chapters(toc)
    if type(toc) ~= "table" then return {} end
    local Storage = require("truyenviet/storage")
    local result, seen = {}, {}
    for _, entry in ipairs(toc) do
        if type(entry) == "table" then
            local page = number(entry.page)
            local chapter = Storage.chapterNumber(tostring(entry.title or ""))
            if page and page >= 1 and chapter and not seen[chapter] then
                seen[chapter] = true
                table.insert(result, { number = chapter, page = page })
            end
        end
    end
    table.sort(result, function(a, b) return a.page < b.page end)
    return result
end

local function atPage(entries, page, total)
    if #entries < 2 or not page then return end
    for i = #entries, 1, -1 do
        local entry = entries[i]
        if page >= entry.page then
            local last = entries[i + 1] and entries[i + 1].page - 1 or total
            if last and last >= entry.page and page <= last then
                return tostring(entry.number), (page - entry.page + 1) / (last - entry.page + 1)
            end
            return
        end
    end
end

local function metadata(path)
    local ok, settings = pcall(function()
        local DocSettings = require("docsettings")
        if not DocSettings:findSidecarFile(path) then return end
        return DocSettings:open(path)
    end)
    if not ok or not settings then return end
    local read, data = pcall(function()
        return {
            percent = settings:readSetting("percent_finished"),
            chapter_progress = settings:readSetting(bundle_key),
            toc = settings:readSetting("handmade_toc"),
            page = settings:readSetting("last_page"),
            total = settings:readSetting("doc_pages"),
        }
    end)
    if read then return data end
end

-- Cache chỉ sống cùng một danh sách: file gộp đọc metadata một lần, mở lại
-- mục lục sẽ lấy tiến độ mới mà KOReader vừa lưu khi đóng reader.
function Progress.percent(path, chapter, cache)
    if type(path) ~= "string" or path == "" then return 0 end
    local data = cache and cache[path]
    if data == nil then
        data = metadata(path) or false
        if cache then cache[path] = data end
    end
    if not data then return 0 end
    if not chapter then return percentage(data.percent) end
    local saved = type(data.chapter_progress) == "table" and data.chapter_progress
    local value = saved and (saved[tostring(chapter)] or saved[chapter])
    if number(value) then return percentage(value) end
    -- Metadata cũ chỉ xác định được chương chứa trang đọc cuối. Không suy ra
    -- các chương trước đã đọc xong chỉ vì người dùng nhảy đến chương sau.
    data.entries = data.entries or chapters(data.toc)
    local current, percent = atPage(data.entries, number(data.page), number(data.total))
    return current == tostring(chapter) and percentage(percent) or 0
end

-- Ghi trong doc_settings đang mở, để KOReader tự flush cùng tiến độ chuẩn.
-- Không ghi file/flush theo từng trang và không mở lại tài liệu để đo tiến độ.
function Progress.observe(ui)
    local noop = function() end
    local settings = ui.doc_settings
    if not settings or type(settings.readSetting) ~= "function"
            or type(settings.saveSetting) ~= "function" then return noop end
    local entries = chapters(settings:readSetting("handmade_toc"))
    if #entries < 2 then return noop end
    local ready = false
    local function record()
        local document = ui.document
        if not ready or not document or type(ui.getCurrentPage) ~= "function" then return end
        local total = document.info and number(document.info.number_of_pages)
        if not total and type(document.getPageCount) == "function" then
            total = number(document:getPageCount())
        end
        total = total or number(settings:readSetting("doc_pages"))
        local chapter, percent = atPage(entries, number(ui:getCurrentPage()), total)
        if not chapter then return end
        local saved = settings:readSetting(bundle_key)
        if type(saved) ~= "table" then saved = {} end
        if saved[chapter] ~= percent then
            saved[chapter] = percent
            settings:saveSetting(bundle_key, saved)
        end
    end
    if type(ui.registerPostReaderReadyCallback) == "function" then
        ui:registerPostReaderReadyCallback(function()
            ready = true
            record()
        end)
    else
        ready = true
    end
    return record
end

return Progress
