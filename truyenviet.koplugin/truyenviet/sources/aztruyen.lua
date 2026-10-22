local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")
local ko_util = require("util")

local Source = {
    id = "aztruyen",
    name = "AzTruyen",
    kind = "text",
    base_url = "https://aztruyen.top",
}

local function stdHeaders(base_url)
    return {
        ["Referer"] = base_url .. "/",
    }
end

local CARD_MARKER = '<div class="col-sm-12 col-md-6 story">'

-- Bóc số chương + trạng thái hoàn thành từ từng thẻ truyện (tách theo CARD_MARKER),
-- trả về bảng meta_by_url[url] = { chapter_count = n|nil, completed = bool }:
--   <span class="full-label"></span> chỉ xuất hiện khi truyện đã hoàn thành
--   <span class="part-count"><svg>...</svg> 198</span> là số chương (có thể kèm dấu . hoặc ,)
-- Mỗi thẻ được cắt tới đoạn mô tả (<p class="crop-text-2 desc">) để không dính sidebar ở thẻ cuối.
local function parseCardMeta(html)
    local meta_by_url = {}
    local pos = 1
    while true do
        local s, e = html:find(CARD_MARKER, pos, true)
        if not s then break end
        local next_s = html:find(CARD_MARKER, e + 1, true)
        local block = html:sub(e + 1, (next_s or (#html + 1)) - 1)
        local desc_s = block:find('<p class="crop%-text%-2 desc"')
        if desc_s then
            block = block:sub(1, desc_s - 1)
        elseif #block > 8000 then
            block = block:sub(1, 8000)
        end

        local url = block:match('href="(https?://aztruyen%.top/[%w%-]+%-%d+/)"')
        if url and not meta_by_url[url] then
            local raw_count = block:match('class="part%-count">.-</svg>%s*([%d%.,]+)%s*</span>')
            local count = raw_count and tonumber((raw_count:gsub("[%.,]", "")))
            meta_by_url[url] = {
                chapter_count = (count and count > 0) and count or nil,
                completed = block:find('<span class="full-label">', 1, true) ~= nil,
            }
        end
        pos = e + 1
    end
    return meta_by_url
end

local function applyCardMeta(stories, html)
    local meta_by_url = parseCardMeta(html)
    for _, story in ipairs(stories) do
        local meta = meta_by_url[story.url]
        if meta then
            story.chapter_count = meta.chapter_count
            story.completed = meta.completed
        end
    end
end

-- Tên chương trên AzTruyen không thống nhất: "Chương 75", "Chương 12 - Tiêu đề", "Tiên Nghịch 1801-1850",
-- "851-881 (end)", "cực phẩm nữ tiên 176", "170 (Ngoại Truyện)". Quy tắc lấy số (theo thứ tự ưu tiên):
--   1. số ngay sau từ khoá "chương"/"chapter"/"chap" (giữ phần thập phân);
--   2. khoảng "a-b" thì lấy b; "a-end" thì lấy a (chặn dưới đã biết);
--   3. số cuối cùng trong tên. Tên không có số (vd "Lời giới thiệu") trả nil.
local CHAPTER_KEYWORDS = { "chương", "chƯƠng", "chapter", "chap" }

local function extractChapterNumber(title)
    if not title then return nil end
    local lower = title:lower()
    for _, keyword in ipairs(CHAPTER_KEYWORDS) do
        local n = tonumber(lower:match(keyword .. "%s*[:%-]?%s*(%d+%.?%d*)"))
        if n and n > 0 then return n end
    end
    local range_end = tonumber(lower:match("%d+%s*%-%s*(%d+)"))
    if range_end and range_end > 0 then return range_end end
    local open_end = tonumber(lower:match("(%d+)%s*%-%s*end"))
    if open_end and open_end > 0 then return open_end end
    local last
    for num in lower:gmatch("%d+%.?%d*") do last = num end
    local n = tonumber(last)
    if n and n > 0 then return n end
    return nil
end

-- Chương mới nhất nằm trong khối "Chương mới nhất" (5 chương cuối, cũ -> mới) của trang truyện.
-- Lấy số lớn nhất trong khối; nếu site bỏ khối này thì lấy số lớn nhất của cả danh sách chương.
local function parseLatestChapter(html)
    local function maxNumber(fragment)
        local best
        for label in fragment:gmatch('<li class="listc">%s*<a[^>]*>([^<]*)</a>') do
            local n = extractChapterNumber(Util.decodeHtml(label))
            if n and (not best or n > best) then best = n end
        end
        return best
    end

    local block = html:match('Chương mới nhất</div>%s*<ul class="chapters">(.-)</ul>')
    return (block and maxNumber(block)) or maxNumber(html)
end

-- Cấu trúc thẻ truyện thật đã xác nhận bằng fetch trực tiếp aztruyen.top ngày 11/07/2026:
--   URL truyện dạng: https://aztruyen.top/{slug}-{id}/   (id số ở cuối, có dấu / kết thúc)
--   Ảnh bìa dạng:    https://aztruyen.top/images/{slug}-{id}.webp   (cùng domain, đuôi .webp)
--   Tiêu đề nằm trong <h2><a href="...url..." title="Tên">Tên</a></h2>
-- Quy trình: bóc toàn bộ cặp (url, cover) từ các thẻ <a><img></a>, rồi bóc (url, title) từ
-- các thẻ <h2><a>, sau đó ghép lại theo url — không phụ thuộc tên class cụ thể (dễ đổi),
-- chỉ phụ thuộc cấu trúc URL đã xác nhận.
local function parseStories(html, source_id)
    local stories = {}
    local seen = {}

    local cover_by_url = {}
    for url, cover in html:gmatch(
        '<a[^>]+href="(https?://aztruyen%.top/[%w%-]+%-%d+/)"[^>]*>%s*<img[^>]+src="(https?://aztruyen%.top/images/[^"]+)"'
    ) do
        cover_by_url[url] = cover
    end

    for url, title in html:gmatch(
        '<h2[^>]*>%s*<a[^>]+href="(https?://aztruyen%.top/[%w%-]+%-%d+/)"[^>]*title="([^"]+)"'
    ) do
        if not seen[url] then
            seen[url] = true
            table.insert(stories, {
                source_id = source_id,
                title = Util.decodeHtml(title),
                url = url,
                cover_url = cover_by_url[url],
                kind = "text",
            })
        end
    end

    -- Dự phòng: nếu site đổi cấu trúc <h2>, thử pattern rộng hơn theo href chung
    if #stories == 0 then
        for href, title in html:gmatch('<a[^>]+href="(https?://aztruyen%.top/[%w%-]+%-%d+/)"[^>]*title="([^"]+)"') do
            if not seen[href] then
                seen[href] = true
                table.insert(stories, {
                    source_id = source_id,
                    title = Util.decodeHtml(title),
                    url = href,
                    cover_url = cover_by_url[href],
                    kind = "text",
                })
            end
        end
    end

    -- Dự phòng cũ (giữ lại phòng khi 2 pattern trên đều không khớp)
    if #stories == 0 then
        for block in html:gmatch('<div class="[^"]*story[^"]*">(.-)<p class="[^"]*desc"') do
            local href = block:match('href="(https?://aztruyen%.top/[^"]+)"')
            local title = block:match('title="([^"]+)"')
            local cover = block:match('data%-src="([^"]+)"') or block:match('<img[^>]+src="([^"]+)"')
            if href and title and not seen[href] then
                seen[href] = true
                table.insert(stories, {
                    source_id = source_id,
                    title = Util.decodeHtml(title),
                    url = href,
                    cover_url = cover,
                    kind = "text",
                })
            end
        end
    end

    applyCardMeta(stories, html)
    return stories
end

local function parseGenres(html)
    local genres = {}
    local seen = {}
    for href, name in html:gmatch('<a href="(https?://aztruyen%.top/the%-loai/[^"]+)"[^>]*>([^<]+)</a>') do
        if not seen[href] then
            seen[href] = true
            table.insert(genres, {
                name = Util.decodeHtml(name),
                url = href,
            })
        end
    end
    return genres
end

function Source:search(query)
    local encoded = ko_util.urlEncode(query)
    local url = self.base_url .. "/tim-kiem/" .. encoded
    local html, err = Http:get(url, stdHeaders(self.base_url))
    if not html then return nil, err end
    local stories = parseStories(html, self.id)
    return stories
end

-- Chương mới nhất cho kết quả tìm kiếm: thẻ trong trang tìm kiếm không có tên chương nên đọc
-- khối "Chương mới nhất" của trang truyện (đúng 1 request). Số chương/hoàn thành đã lấy từ thẻ.
function Source:fetchSearchMeta(story)
    local html, err = Http:get(story.url, stdHeaders(self.base_url))
    if not html then return nil, err end
    local latest = parseLatestChapter(html)
    if not latest then return nil, "Không đọc được chương mới nhất" end
    return { latest_chapter = latest }
end

function Source:getCompleted(page)
    page = page or 1
    -- LƯU Ý: chưa xác minh được AzTruyen.top có trang riêng liệt kê "truyện hoàn
    -- thành" hay không (không thấy trong menu điều hướng khi kiểm tra trực tiếp
    -- ngày 11/07/2026, chỉ có menu Thể loại + Yêu thích). Thử URL cũ trước,
    -- nếu không ra truyện nào thì dùng trang chủ (luôn có danh sách + sidebar thể loại).
    local url = self.base_url .. "/danh-sach/hoan-thanh/"
    if page > 1 then url = url .. "trang-" .. page .. "/" end
    local html = Http:get(url, stdHeaders(self.base_url))

    local stories = html and parseStories(html, self.id) or {}
    if #stories == 0 then
        url = self.base_url .. "/"
        if page > 1 then url = url .. "trang-" .. page .. "/" end
        local err
        html, err = Http:get(url, stdHeaders(self.base_url))
        if not html then return nil, err end
        stories = parseStories(html, self.id)
    end

    local total_pages = tonumber(html:match('href="[^"]+trang%-(%d+)/"[^>]*>Cuối')) or page
    return {
        stories = stories,
        genres = parseGenres(html),
        page = page,
        total_pages = total_pages,
        title = "AzTruyen"
    }
end

function Source:getGenre(genre, page)
    page = page or 1
    local url = Util.withTrailingSlash(genre.url)
    if page > 1 then url = url .. "trang-" .. page .. "/" end
    local html, err = Http:get(url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local total_pages = tonumber(html:match('href="[^"]+trang%-(%d+)/"[^>]*>Cuối')) or page
    return {
        stories = parseStories(html, self.id),
        genres = parseGenres(html),
        page = page,
        total_pages = total_pages,
        title = genre.name
    }
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local title = html:match('<h1[^>]*>([^<]+)</h1>')
    local author = html:match('Tác giả:%s*</span>%s*<a[^>]*>([^<]+)</a>')
        or html:match('<span itemprop="name">%s*<a[^>]+rel="author"[^>]*>([^<]+)</a>')
    
    local desc_block = html:match('<div class="content%-story"[^>]*>(.-)</div>%s*<div class="list%-chapter"')
        or html:match('<div class="desc%-text"[^>]*>(.-)</div>')
        or html:match('<div class="content%-story"[^>]*>(.-)</div>')
    
    local description = desc_block and Util.stripTags(desc_block) or nil
    if description then
        description = description:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    return {
        title = title and Util.decodeHtml(Util.trim(title)) or story.title,
        author = author and Util.trim(author) or nil,
        description = description,
    }
end

function Source:getStoryPage(story, page)
    page = page or 1
    local url = Util.withTrailingSlash(story.url)
    if page > 1 then url = url .. "trang-" .. page .. "/" end
    local html, err = Http:get(url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local chapters = {}
    local seen = {}
    
    local story_path = story.url:gsub("^https?://[^/]+", "")
    story_path = story_path:gsub("/$", "")
    
    local all_matches = {}
    for anchor in html:gmatch('<a%s+[^>]*>') do
        local href = anchor:match('href="(https?://aztruyen%.top' .. story_path:gsub("%-", "%%-") .. '/chuong[^"]+)"')
        local title = anchor:match('title="([^"]+)"')
        if href and title then
            table.insert(all_matches, {href = href, title = title})
        end
    end

    local reversed_chapters = {}
    for i = #all_matches, 1, -1 do
        local href = all_matches[i].href
        if not seen[href] then
            seen[href] = true
            table.insert(reversed_chapters, {
                title = Util.trim(all_matches[i].title),
                url = href,
                source_id = self.id,
                story_url = story.url,
                kind = self.kind,
            })
        end
    end

    for i = #reversed_chapters, 1, -1 do
        table.insert(chapters, reversed_chapters[i])
    end

    local total_pages = tonumber(html:match('href="[^"]+trang%-(%d+)/"[^>]*>Cuối')) or page
    story.details = self:getStoryDetails(story)
    
    return {
        story = story,
        chapters = chapters,
        page = page,
        total_pages = total_pages,
    }
end

-- LƯU Ý: log thực tế cho thấy request tải chương trả về 200 (HTML thật, không
-- lỗi mạng) nhưng nội dung hiện ra "nil" -> nghĩa là 2 pattern cũ dưới đây
-- (class="chapter-content" / id="chapter-content") không khớp cấu trúc HTML
-- thật của aztruyen.top (chưa từng được xác minh trực tiếp). Thêm nhiều pattern
-- dự phòng thường gặp ở các site WordPress/Ghost tương tự, để tăng khả năng
-- khớp cho tới khi xác minh được chính xác class thật.
local CONTENT_PATTERNS = {
    '<div class="chapter%-content"[^>]*>(.-)</div>%s*</div>',
    '<div id="chapter%-content"[^>]*>(.-)</div>%s*</div>',
    '<div class="chapter%-content"[^>]*>(.-)</div>',
    '<div id="chapter%-content"[^>]*>(.-)</div>',
    '<div class="content%-chapter"[^>]*>(.-)</div>',
    '<div class="entry%-content"[^>]*>(.-)</div>',
    '<div class="reading%-content"[^>]*>(.-)</div>',
    '<div id="content"[^>]*>(.-)</div>',
}

local function extractChapterContent(html)
    -- Tìm nội dung giữa <div class="chapter-content"> và watermark hoặc div tiếp theo
    local start_idx, content_start = html:find('<div class="chapter%-content"[^>]*>')
    if not start_idx then
        start_idx, content_start = html:find('<div id="chapter%-content"[^>]*>')
    end
    if not start_idx then
        start_idx, content_start = html:find('<div class="content%-chapter"[^>]*>')
    end
    if not start_idx then
        start_idx, content_start = html:find('<div class="entry%-content"[^>]*>')
    end
    if not start_idx then
        start_idx, content_start = html:find('<div class="reading%-content"[^>]*>')
    end

    if content_start then
        local end_idx = html:find('<p class="chapter%-end">', content_start)
        if not end_idx then
            end_idx = html:find('Bạn đang đọc truyện trên', content_start)
        end
        if not end_idx then
            end_idx = html:find('<div class="display%-chapter">', content_start)
        end
        
        if end_idx then
            local content = html:sub(content_start + 1, end_idx - 1)
            -- Bỏ </div> cuối cùng nếu có
            content = content:gsub('</div[^>]*>%s*$', '')
            if Util.trim(Util.stripTags(content)) ~= "" then
                return content
            end
        end
    end

    -- Nếu tìm bằng string.find thất bại, thử dùng pattern cũ
    for _, pattern in ipairs(CONTENT_PATTERNS) do
        local content = html:match(pattern)
        if content and Util.trim(Util.stripTags(content)) ~= "" then
            return content
        end
    end

    return nil
end

function Source:getChapter(chapter)
    local html, err = Http:get(chapter.url, stdHeaders(self.base_url))
    if not html then return nil, err end

    local content = extractChapterContent(html)
    if not content then return nil, "Không tìm thấy nội dung chương (cấu trúc trang có thể đã đổi)" end

    return Util.sanitizeContentHtml(content)
end

function Source:getChapterAsync(chapter)
    local html, err = Http:requestAsync("GET", chapter.url, stdHeaders(self.base_url))
    if not html then return nil, err end

    local content = extractChapterContent(html)
    if not content then return nil, "Không tìm thấy nội dung chương (cấu trúc trang có thể đã đổi)" end

    return Util.sanitizeContentHtml(content)
end

return Source