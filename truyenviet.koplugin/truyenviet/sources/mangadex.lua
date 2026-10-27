local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")

-- MangaDex có API JSON chính thức (https://api.mangadex.org/docs/). Quy định
-- của API: User-Agent phải là của ứng dụng (không giả trình duyệt), khoảng 5
-- request/giây/IP, /at-home/server tối đa 40 lần/phút, offset + limit <= 10000.
local API = "https://api.mangadex.org"
local UPLOADS = "https://uploads.mangadex.org"
local SITE = "https://mangadex.org"
local USER_AGENT = "TruyenViet-KOReader/" .. tostring(require("truyenviet/version")):match("^[%d%.]+")
local PAGE_SIZE = 30
local FEED_SIZE = 500
local MAX_RESULTS = 10000
local CONTENT_RATINGS = { "safe", "suggestive" }

local LABELS = {
    vi = { chapter = "Chương", oneshot = "Oneshot", lang_name = "Tiếng Việt" },
    en = { chapter = "Chapter", oneshot = "Oneshot", lang_name = "English" },
}

local STATUS_NAMES = {
    ongoing = "Đang ra", completed = "Hoàn thành", hiatus = "Tạm ngưng", cancelled = "Đã hủy",
}

-- json.decode của KOReader trả null thành giá trị đặc biệt chứ không phải nil.
local function str(value)
    return type(value) == "string" and value or nil
end

local function query(params)
    local parts = {}
    for _, pair in ipairs(params) do
        parts[#parts + 1] = Util.urlEncode(pair[1]) .. "=" .. Util.urlEncode(pair[2])
    end
    return table.concat(parts, "&")
end

local function apiHeaders()
    return { ["User-Agent"] = USER_AGENT, ["Accept"] = "application/json" }
end

-- Node MangaDex@Home trả 404 nếu thiếu Referer của mangadex.org.
local function imageHeaders()
    return { ["User-Agent"] = USER_AGENT, ["Referer"] = SITE .. "/" }
end

local function getJson(path, params)
    local url = API .. path .. (params and ("?" .. query(params)) or "")
    local body, err = Http:get(url, apiHeaders())
    if not body then return nil, err end
    local data = Util.parseJson(body)
    if type(data) ~= "table" then return nil, "MangaDex trả về dữ liệu không hợp lệ" end
    if data.result ~= "ok" then
        local first = type(data.errors) == "table" and data.errors[1] or nil
        return nil, "MangaDex: " .. tostring(first and (str(first.detail) or str(first.title)) or "lỗi không rõ")
    end
    return data
end

local function mangaIdOf(url)
    return tostring(url or ""):match("/title/([%w%-]+)")
end

local function chapterIdOf(url)
    return tostring(url or ""):match("/chapter/([%w%-]+)")
end

local function firstValue(map)
    if type(map) ~= "table" then return nil end
    for _, value in pairs(map) do
        if str(value) then return value end
    end
end

-- Tên truyện gốc thường là romaji (ja-ro); ưu tiên tên theo ngôn ngữ nguồn rồi
-- tới tiếng Anh nếu có trong altTitles.
local function pickTitle(attributes, lang)
    local titles = type(attributes.title) == "table" and attributes.title or {}
    local alts = type(attributes.altTitles) == "table" and attributes.altTitles or {}
    for _, code in ipairs({ lang, "en" }) do
        if str(titles[code]) then return titles[code] end
        for _, alt in ipairs(alts) do
            if type(alt) == "table" and str(alt[code]) then return alt[code] end
        end
    end
    return firstValue(titles) or "Không rõ tên"
end

local function pickText(map, lang)
    if type(map) ~= "table" then return nil end
    return str(map[lang]) or str(map.en) or firstValue(map)
end

-- Mô tả dùng Markdown: giữ chữ của liên kết, bỏ ký hiệu định dạng.
local function plainDescription(text)
    text = tostring(text or "")
    text = text:gsub("%[([^%]]-)%]%b()", "%1")
    text = text:gsub("%*%*", ""):gsub("__", ""):gsub("\n%-%-%-+", "\n"):gsub("\r", "")
    return Util.trim(text)
end

local function relationships(item, rel_type)
    local found = {}
    for _, rel in ipairs(type(item.relationships) == "table" and item.relationships or {}) do
        if rel.type == rel_type then found[#found + 1] = rel end
    end
    return found
end

local function coverUrl(manga, size)
    local cover = relationships(manga, "cover_art")[1]
    local file = cover and type(cover.attributes) == "table" and str(cover.attributes.fileName)
    if not file then return nil end
    return string.format("%s/covers/%s/%s.%d.jpg", UPLOADS, manga.id, file, size or 256)
end

local function formatNumber(value)
    local number = tonumber(value)
    if not number then return tostring(value or "") end
    if number == math.floor(number) then return string.format("%d", number) end
    return tostring(number)
end

local Source = {}

-- Mỗi ngôn ngữ là một nguồn riêng; chép hàm vào từng bảng nguồn (không dùng
-- metatable) để giống các nguồn tích hợp khác.
function Source.create(lang)
    local labels = LABELS[lang] or LABELS.en
    local instance = {
        id = lang == "vi" and "mangadex" or ("mangadex_" .. lang),
        name = "MangaDex (" .. labels.lang_name .. ")",
        kind = "comic",
        base_url = SITE,
        reversed_chapters = false,
        -- Mỗi lần lấy số chương gọi một request /aggregate; chạy ít worker để
        -- không vượt giới hạn ~5 request/giây.
        meta_concurrency = 2,
        lang = lang,
        labels = labels,
    }
    for key, value in pairs(Source) do
        instance[key] = value
    end
    return instance
end

local function isCompleted(status)
    if status then return status == "completed" end
end

function Source:getCoverHeaders()
    return imageHeaders()
end

function Source:getImageHeaders()
    return imageHeaders()
end

function Source:mangaParams(extra)
    local params = {
        { "availableTranslatedLanguage[]", self.lang },
        { "hasAvailableChapters", "true" },
        { "includes[]", "cover_art" },
    }
    for _, rating in ipairs(CONTENT_RATINGS) do
        params[#params + 1] = { "contentRating[]", rating }
    end
    for _, pair in ipairs(extra or {}) do
        params[#params + 1] = pair
    end
    return params
end

function Source:storyFromManga(manga)
    local attributes = type(manga.attributes) == "table" and manga.attributes or {}
    local status = str(attributes.status)
    return {
        source_id = self.id,
        title = pickTitle(attributes, self.lang),
        url = SITE .. "/title/" .. manga.id,
        cover_url = coverUrl(manga, 256),
        kind = self.kind,
        completed = isCompleted(status),
    }
end

function Source:parseMangaList(data, page, title)
    local stories = {}
    for _, manga in ipairs(type(data.data) == "table" and data.data or {}) do
        if str(manga.id) then stories[#stories + 1] = self:storyFromManga(manga) end
    end
    local total = math.min(tonumber(data.total) or #stories, MAX_RESULTS)
    return {
        stories = stories,
        page = page,
        total_pages = math.max(1, math.ceil(total / PAGE_SIZE)),
        title = title,
    }
end

function Source:fetchMangaList(page, extra, title)
    page = math.max(1, tonumber(page) or 1)
    local offset = (page - 1) * PAGE_SIZE
    if offset + PAGE_SIZE > MAX_RESULTS then
        return nil, "MangaDex chỉ cho xem tối đa 10.000 kết quả đầu"
    end
    local params = self:mangaParams(extra)
    params[#params + 1] = { "limit", tostring(PAGE_SIZE) }
    params[#params + 1] = { "offset", tostring(offset) }
    local data, err = getJson("/manga", params)
    if not data then return nil, err end
    return self:parseMangaList(data, page, title)
end

function Source:search(keyword)
    local result, err = self:fetchMangaList(1, {
        { "title", Util.trim(keyword) },
        { "order[relevance]", "desc" },
    }, "Tìm kiếm")
    return result and result.stories or nil, err
end

function Source:getHot(page)
    return self:fetchMangaList(page, { { "order[followedCount]", "desc" } }, "Truyện phổ biến")
end

function Source:getUpdating(page)
    return self:fetchMangaList(page, { { "order[latestUploadedChapter]", "desc" } }, "Truyện mới cập nhật")
end

function Source:getCompleted(page)
    return self:fetchMangaList(page, {
        { "status[]", "completed" },
        { "order[followedCount]", "desc" },
    }, "Truyện đã hoàn thành")
end

function Source:parseTags(data)
    local genres = {}
    for _, tag in ipairs(type(data.data) == "table" and data.data or {}) do
        local attributes = type(tag.attributes) == "table" and tag.attributes or {}
        -- Nhóm "content" (bạo lực, tình dục) không phải thể loại để duyệt.
        if str(tag.id) and attributes.group ~= "content" then
            local name = pickText(attributes.name, self.lang)
            if name then genres[#genres + 1] = { name = name, url = SITE .. "/tag/" .. tag.id } end
        end
    end
    table.sort(genres, function(a, b) return a.name < b.name end)
    return genres
end

function Source:getGenresList()
    local data, err = getJson("/manga/tag")
    if not data then return nil, err end
    return self:parseTags(data)
end

function Source:getGenre(genre, page)
    local tag_id = tostring(genre and genre.url or ""):match("/tag/([%w%-]+)")
    if not tag_id then return nil, "Thể loại MangaDex không hợp lệ" end
    local result, err = self:fetchMangaList(page, {
        { "includedTags[]", tag_id },
        { "order[followedCount]", "desc" },
    }, genre.name)
    if result then result.genre = genre end
    return result, err
end

function Source:parseStoryDetails(manga)
    local attributes = type(manga.attributes) == "table" and manga.attributes or {}
    local function names(rel_type)
        local list = {}
        for _, rel in ipairs(relationships(manga, rel_type)) do
            local name = type(rel.attributes) == "table" and str(rel.attributes.name)
            if name then list[#list + 1] = name end
        end
        return list
    end
    local authors, seen = {}, {}
    for _, name in ipairs(names("author")) do authors[#authors + 1] = name; seen[name] = true end
    for _, name in ipairs(names("artist")) do
        if not seen[name] then authors[#authors + 1] = name; seen[name] = true end
    end

    local genres = {}
    for _, tag in ipairs(type(attributes.tags) == "table" and attributes.tags or {}) do
        local name = type(tag.attributes) == "table" and pickText(tag.attributes.name, self.lang)
        if name then genres[#genres + 1] = name end
    end
    local status = str(attributes.status)
    return {
        description = plainDescription(pickText(attributes.description, self.lang)),
        author = #authors > 0 and table.concat(authors, ", ") or nil,
        status = status and (STATUS_NAMES[status] or status) or nil,
        completed = isCompleted(status),
        genres = genres,
        cover_url = coverUrl(manga, 512),
    }
end

function Source:getStoryDetails(story)
    local manga_id = mangaIdOf(story.url)
    if not manga_id then return nil, "Không nhận ra mã truyện MangaDex trong đường dẫn" end
    local data, err = getJson("/manga/" .. manga_id, {
        { "includes[]", "author" }, { "includes[]", "artist" }, { "includes[]", "cover_art" },
    })
    if not data then return nil, err end
    return self:parseStoryDetails(data.data or {})
end

local function chapterSlug(number, chapter_id)
    if number then return "chapter-" .. formatNumber(number):gsub("%.", "-") end
    return "oneshot-" .. chapter_id:sub(1, 8)
end

-- Nhiều nhóm dịch có thể đăng cùng một số chương. Giữ một bản cho mỗi số
-- chương, ưu tiên nhóm dịch nhiều chương nhất để cả bộ đồng nhất.
function Source:parseChapterFeed(items, story)
    local group_counts = {}
    local function groupOf(item)
        local group = relationships(item, "scanlation_group")[1]
        return group and str(group.id) or "none"
    end
    for _, item in ipairs(items) do
        local group = groupOf(item)
        group_counts[group] = (group_counts[group] or 0) + 1
    end

    local by_number, numbered, oneshots = {}, {}, {}
    for index, item in ipairs(items) do
        local attributes = type(item.attributes) == "table" and item.attributes or {}
        if str(item.id) and not str(attributes.externalUrl) and (tonumber(attributes.pages) or 0) > 0 then
            local number = tonumber(str(attributes.chapter))
            local entry = { item = item, attributes = attributes, number = number,
                rank = group_counts[groupOf(item)], index = index }
            if not number then
                oneshots[#oneshots + 1] = entry
            else
                local key = formatNumber(number)
                local current = by_number[key]
                if not current then
                    by_number[key] = entry
                    numbered[#numbered + 1] = key
                elseif entry.rank > current.rank then
                    by_number[key] = entry
                end
            end
        end
    end

    local entries = {}
    for _, key in ipairs(numbered) do entries[#entries + 1] = by_number[key] end
    table.sort(entries, function(a, b)
        if a.number ~= b.number then return a.number < b.number end
        return a.index < b.index
    end)
    for _, entry in ipairs(oneshots) do entries[#entries + 1] = entry end

    local chapters = {}
    for _, entry in ipairs(entries) do
        local name = str(entry.attributes.title)
        local label = entry.number and (self.labels.chapter .. " " .. formatNumber(entry.number))
            or self.labels.oneshot
        if name and Util.trim(name) ~= "" then label = label .. ": " .. Util.trim(name) end
        chapters[#chapters + 1] = {
            title = label,
            number = entry.number,
            url = string.format("%s/chapter/%s/%s", SITE, entry.item.id, chapterSlug(entry.number, entry.item.id)),
            source_id = self.id,
            story_url = story.url,
            kind = self.kind,
        }
    end
    return chapters
end

function Source:fetchChapterFeed(manga_id)
    local items, offset = {}, 0
    repeat
        local params = {
            { "translatedLanguage[]", self.lang },
            { "order[chapter]", "asc" },
            { "limit", tostring(FEED_SIZE) },
            { "offset", tostring(offset) },
            { "includeExternalUrl", "0" },
            { "includeEmptyPages", "0" },
            { "includeFuturePublishAt", "0" },
            { "includes[]", "scanlation_group" },
        }
        -- Lọc theo truyện ở trang danh sách; ở đây lấy mọi chương của truyện đã chọn.
        for _, rating in ipairs({ "safe", "suggestive", "erotica", "pornographic" }) do
            params[#params + 1] = { "contentRating[]", rating }
        end
        local data, err = getJson("/manga/" .. manga_id .. "/feed", params)
        if not data then return nil, err end
        local page = type(data.data) == "table" and data.data or {}
        for _, item in ipairs(page) do items[#items + 1] = item end
        offset = offset + FEED_SIZE
        local total = tonumber(data.total) or 0
    until #page == 0 or offset >= math.min(total, MAX_RESULTS)
    return items
end

function Source:getAllChapters(story)
    local manga_id = mangaIdOf(story.url)
    if not manga_id then return nil, "Không nhận ra mã truyện MangaDex trong đường dẫn" end
    local items, err = self:fetchChapterFeed(manga_id)
    if not items then return nil, err end
    local chapters = self:parseChapterFeed(items, story)
    if #chapters == 0 then
        return nil, "Truyện chưa có chương " .. self.labels.lang_name
            .. " đọc được trên MangaDex (có thể chỉ có liên kết ngoài hoặc đã bị gỡ)"
    end
    return chapters
end

function Source:getStoryPage(story)
    local chapters, err = self:getAllChapters(story)
    if not chapters then return nil, err end
    local ok, details = pcall(self.getStoryDetails, self, story)
    if ok and type(details) == "table" then story.details = details end
    return { story = story, chapters = chapters, page = 1, total_pages = 1 }
end

-- /aggregate trả gọn danh sách số chương theo tập, nhẹ hơn nhiều so với /feed.
function Source:parseAggregate(data)
    local count, latest = 0, 0
    local volumes = type(data.volumes) == "table" and data.volumes or {}
    for _, volume in pairs(volumes) do
        local chapters = type(volume) == "table" and type(volume.chapters) == "table" and volume.chapters or {}
        for _, chapter in pairs(chapters) do
            count = count + 1
            latest = math.max(latest, tonumber(type(chapter) == "table" and str(chapter.chapter)) or 0)
        end
    end
    return { chapter_count = count > 0 and count or nil, latest_chapter = latest > 0 and latest or nil }
end

function Source:fetchSearchMeta(story)
    local manga_id = mangaIdOf(story.url)
    if not manga_id then return nil, "Không nhận ra mã truyện MangaDex trong đường dẫn" end
    local data, err = getJson("/manga/" .. manga_id .. "/aggregate", { { "translatedLanguage[]", self.lang } })
    if not data then return nil, err end
    local meta = self:parseAggregate(data)
    meta.completed = story.completed
    return meta
end

-- Ảnh gốc từ node MangaDex@Home; dự phòng bằng máy chủ gốc rồi bản nén.
function Source:parseAtHome(data, chapter)
    local info = type(data.chapter) == "table" and data.chapter or {}
    local base, hash = str(data.baseUrl), str(info.hash)
    local files = type(info.data) == "table" and info.data or {}
    local saver = type(info.dataSaver) == "table" and info.dataSaver or {}
    if not base or not hash or #files == 0 then
        return nil, "Không tìm thấy ảnh của chương MangaDex"
    end
    local images = {}
    for index, file in ipairs(files) do
        local urls = {
            string.format("%s/data/%s/%s", base, hash, file),
            string.format("%s/data/%s/%s", UPLOADS, hash, file),
        }
        if #saver == #files and str(saver[index]) then
            urls[#urls + 1] = string.format("%s/data-saver/%s/%s", base, hash, saver[index])
        end
        images[#images + 1] = { urls = urls }
    end
    return { title = chapter.title, images = images, url = chapter.url,
        referer = SITE .. "/", kind = self.kind }
end

function Source:getChapter(chapter)
    local chapter_id = chapterIdOf(chapter.url)
    if not chapter_id then return nil, "Không nhận ra mã chương MangaDex" end
    local data, err = getJson("/at-home/server/" .. chapter_id)
    if not data then return nil, err end
    return self:parseAtHome(data, chapter)
end

return Source.create("vi")
