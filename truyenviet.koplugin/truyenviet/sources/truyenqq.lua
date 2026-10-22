local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")

local Source = {
    id = "truyenqq",
    name = "TruyenQQ",
    kind = "comic",
    base_url = "https://truyenqq.com.vn",
    reversed_chapters = true,
}

-- LƯU Ý (12/07/2026): log thực tế cho thấy lỗi "redirect not supported" xảy ra
-- khi tải trang danh sách bình thường (/truyen-hoan-thanh...) — không phải API.
-- Trước đây header X-Requested-With: XMLHttpRequest (dấu hiệu gọi AJAX) bị gửi
-- trên MỌI request, kể cả tải trang HTML thường. Việc "giả AJAX" cho request
-- tải trang có thể khiến server xử lý khác đi (ví dụ redirect sang trang khác)
-- so với truy cập trang bình thường. Tách riêng: pageHeaders() cho tải trang
-- HTML thường (không có X-Requested-With), ajaxHeaders() chỉ dùng cho đúng 1
-- endpoint AJAX thật là /frontend/search/search.
-- Truyện lưu từ tên miền cũ (vd. truyenqqko.com) vẫn phải tải từ đúng tên miền đó:
-- link chương trên trang là đường dẫn tương đối, và CDN ảnh từ chối Referer khác tên miền.
local function siteOf(url)
    return tostring(url or ""):match("^(https?://[^/]+)") or Source.base_url
end

local function pageHeaders(site)
    return {
        ["Referer"] = (site or Source.base_url) .. "/",
        ["Accept-Language"] = "vi-VN,vi;q=0.9,en;q=0.7",
    }
end

local function ajaxHeaders()
    local h = pageHeaders()
    h["X-Requested-With"] = "XMLHttpRequest"
    return h
end

-- Giữ tên cũ `requestHeaders` trỏ về `pageHeaders` để không phải sửa lại từng
-- chỗ gọi bên dưới — chỉ có `search()` (endpoint AJAX thật) mới cần đổi sang
-- `ajaxHeaders()`.
local requestHeaders = pageHeaders

function Source:getCoverHeaders()
    return requestHeaders()
end

function Source:parseSearch(html)
    local stories = {}

    for item_html in html:gmatch("<li[^>]*>([%s%S]-)</li>") do
        local anchor = item_html:match("(<a[^>]*>)")
        local href = Util.getAttribute(anchor, "href")
        local title = item_html:match('<p[^>]-class="name"[^>]*>([%s%S]-)</p>')
        local image_tag = item_html:match("(<img[^>]*>)")
        if href and title then
            table.insert(stories, {
                source_id = self.id,
                title = Util.stripTags(title),
                url = Util.absoluteUrl(self.base_url, href),
                cover_url = Util.absoluteUrl(
                    self.base_url,
                    Util.getAttribute(image_tag, "src")
                        or Util.getAttribute(image_tag, "data-fb")
                ),
                kind = self.kind,
            })
        end
    end

    return Util.uniqueBy(stories, "url")
end

-- Giao diện truyenqq.com.vn: kết quả tìm kiếm là trang HTML /tim-kiem?s=...
-- với mỗi truyện là <div class="item"> chứa <h3><a href title> và dòng
-- "Số chương: N" nằm sau </h3>, nên cắt từng mục theo mốc <div class="item"> kế tiếp.
function Source:parseSearchPage(html)
    local stories = {}
    local listing_start = html:find('class="listing"', 1, true)
    if not listing_start then
        return stories
    end
    local listing = html:sub(listing_start)
    local marker = '<div class="item">'
    local position = listing:find(marker, 1, true)
    while position do
        local next_position = listing:find(marker, position + #marker, true)
        local item_html = listing:sub(
            position + #marker,
            (next_position or (#listing + 1)) - 1
        )
        local heading = item_html:match("<h3[^>]*>([%s%S]-)</h3>")
        local anchor_attrs, title_html = (heading or ""):match("<a([^>]*)>([%s%S]-)</a>")
        local href = Util.getAttribute(anchor_attrs, "href")
        local title = Util.stripTags(title_html)
        local chapter_count = item_html:match("Số chương</span>%s*:%s*([%d%.,]+)")
        if href and title ~= "" then
            table.insert(stories, {
                source_id = self.id,
                title = title,
                url = Util.absoluteUrl(self.base_url, href),
                cover_url = Util.absoluteUrl(
                    self.base_url,
                    Util.getAttribute(item_html:match("(<img[^>]*>)"), "src")
                ),
                chapter_count = chapter_count
                    and tonumber((chapter_count:gsub("[%.,]", ""))),
                kind = self.kind,
            })
        end
        position = next_position
    end
    return Util.uniqueBy(stories, "url")
end

-- Trang tìm kiếm không ghi trạng thái; chỉ trang chi tiết truyện mới có nhãn
-- <span class="label-status label-full">Hoàn thành</span> (hoặc label-updating
-- khi đang ra). Core gọi fetchSearchMeta (chạy async trong pool, có cache theo URL).
function Source:parseCompleted(html)
    if html:find("label%-status label%-full") then
        return true
    end
    if html:find("label%-status label%-updating") then
        return false
    end
    return nil
end

-- Số chương từ nhãn "Chapter 16", "Chapter 12.5", "Chương 3"; nil nếu nhãn không có số
-- (vd. "Extra") hoặc số <= 0.
local function chapterNumberFromLabel(label)
    local text = Util.stripTags(label)
    for _, prefix in ipairs({ "Chapter", "Chương", "Chap" }) do
        local number = text:match("^%s*" .. prefix .. "%s*(%d+%.%d+)")
            or text:match("^%s*" .. prefix .. "%s*(%d+)")
        number = tonumber(number)
        if number and number > 0 then
            return number
        end
    end
    return nil
end

-- Chương mới nhất của trang chi tiết: trang 1 của #chapter-list liệt kê 100 chương
-- mới nhất (mới -> cũ) dạng <a class="chapter-name ...">Chapter N</a>. Lấy số lớn nhất
-- thay vì mục đầu để không phụ thuộc thứ tự; dự phòng bằng mô tả meta
-- "...trải nghiệm đọc chương N tại TruyenQQ".
function Source:parseLatestChapter(html)
    local list_start = html:find('id="chapter-list"', 1, true)
    local latest
    if list_start then
        for attrs, inner in html:sub(list_start):gmatch("<a([^>]*)>([%s%S]-)</a>") do
            local class_name = Util.getAttribute(attrs, "class") or ""
            if class_name:find("chapter-name", 1, true) then
                local number = chapterNumberFromLabel(inner)
                if number and (not latest or number > latest) then
                    latest = number
                end
            end
        end
    end
    if latest then
        return latest
    end
    local description = Util.getMetaContent(html, "name", "description") or ""
    local number = tonumber(description:match("đọc chương%s+(%d+)"))
    if number and number > 0 then
        return number
    end
    return nil
end

function Source:fetchSearchMeta(story)
    local html, err = Http:get(
        story.url,
        requestHeaders(siteOf(story.url)),
        { force_luasec = true }
    )
    if not html then
        return nil, err
    end
    local completed = self:parseCompleted(html)
    local latest_chapter = self:parseLatestChapter(html)
    if completed == nil and latest_chapter == nil then
        return nil, "Không đọc được trạng thái"
    end
    return { completed = completed, latest_chapter = latest_chapter }
end

function Source:search(query)
    local stories
    local html, err = Http:postForm(
        self.base_url .. "/frontend/search/search",
        { search = query, type = 0 },
        ajaxHeaders(),
        { force_luasec = true }
    )
    if html then
        stories = self:parseSearch(html)
    end

    if not stories or #stories == 0 then
        local page_html, page_err = Http:get(
            self.base_url .. "/tim-kiem?s=" .. Util.urlEncode(query),
            requestHeaders(),
            { force_luasec = true }
        )
        if not page_html then
            return nil, page_err or err
        end
        stories = self:parseSearchPage(page_html)
    end

    return stories
end

function Source:parseListing(html, page)
    local stories = {}
    local list_start = html:find('<ul class="list_grid grid"', 1, true)
    local list_end = list_start and html:find("</ul>", list_start, true)
    local list_html = list_start
        and html:sub(list_start, (list_end or (#html + 1)) - 1)
        or ""

    for item_html in list_html:gmatch("<li[^>]*>([%s%S]-)</li>") do
        if item_html:find('class="book_avatar"', 1, true) then
            local name_html = item_html:match(
                '<div[^>]-class="book_name[^"]*"[^>]*>([%s%S]-)</div>'
            )
            local anchor = name_html and name_html:match("(<a[^>]*>)")
            local image_tag = item_html:match("(<img[^>]*>)")
            local href = Util.getAttribute(anchor, "href")
            local title = Util.getAttribute(anchor, "title")
                or Util.stripTags(name_html)
            if href and title and title ~= "" then
                table.insert(stories, {
                    source_id = self.id,
                    title = Util.decodeHtml(title),
                    url = Util.absoluteUrl(self.base_url, href),
                    cover_url = Util.absoluteUrl(
                        self.base_url,
                        Util.getAttribute(image_tag, "data-original")
                            or Util.getAttribute(image_tag, "src")
                            or Util.getAttribute(image_tag, "data-fb")
                    ),
                    kind = self.kind,
                })
            end
        end
    end

    return {
        stories = Util.uniqueBy(stories, "url"),
        genres = Util.parseGenres(html, self.base_url),
        page = page or 1,
        total_pages = Util.maxPage(html, page),
    }
end

function Source:getCompleted(page)
    page = page or 1
    local url = self.base_url .. "/truyen-hoan-thanh"
    if page > 1 then
        url = url .. "/trang-" .. page .. "?status=2"
    end
    local html, err = Http:get(url, requestHeaders(), { force_luasec = true })
    if not html then
        return nil, err
    end
    local result = self:parseListing(html, page)
    result.title = "Truyện đã hoàn thành"
    return result
end

function Source:getGenre(genre, page)
    page = page or 1
    local url = genre.url:gsub("/+$", "")
    if page > 1 then
        url = url .. "/trang-" .. page
    end
    local html, err = Http:get(url, requestHeaders(), { force_luasec = true })
    if not html then
        return nil, err
    end
    local result = self:parseListing(html, page)
    result.title = genre.name
    result.genre = genre
    return result
end

function Source:parseStoryDetails(html)
    local description_html = html:match(
        '<div[^>]-class="[^"]*story%-detail%-info[^"]*detail%-content[^"]*"[^>]*>([%s%S]-)</div>'
    )
    local author_html = html:match(
        '<li[^>]-class="[^"]*author[^"]*"[^>]*>([%s%S]-)</li>'
    )
    local status_html = html:match(
        '<li[^>]-class="[^"]*status[^"]*"[^>]*>([%s%S]-)</li>'
    )
    local genre_html = html:match(
        '<ul[^>]-class="[^"]*list01[^"]*"[^>]*>([%s%S]-)</ul>'
    )

    local author
    for paragraph in tostring(author_html or ""):gmatch("<p[^>]*>([%s%S]-)</p>") do
        author = Util.stripTags(paragraph)
    end
    local status
    for paragraph in tostring(status_html or ""):gmatch("<p[^>]*>([%s%S]-)</p>") do
        status = Util.stripTags(paragraph)
    end

    return {
        description = Util.stripTags(description_html)
            ~= "" and Util.stripTags(description_html)
            or Util.getMetaContent(html, "name", "description"),
        author = author,
        status = status,
        genres = Util.parseGenreNames(genre_html),
    }
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, requestHeaders(siteOf(story.url)), { force_luasec = true })
    if not html then
        return nil, err
    end
    return self:parseStoryDetails(html)
end

function Source:parseStoryPage(html, story)
    local chapters = {}
    local slug = story.url:match("([^/]+)$") or ""
    local base_slug = slug:match("^(.-)%-%d+%.html$") or slug:match("^(.-)%.html$") or slug
    local site = siteOf(story.url)

    -- Parse chapter links from works-chapter-item divs (preferred structure)
    for item_html in html:gmatch('<div[^>]-class="[^"]*works%-chapter%-item[^"]*"[^>]*>([%s%S]-)</div>%s*</div>') do
        for anchor_attrs, anchor_html in item_html:gmatch("<a([^>]*)>([%s%S]-)</a>") do
            local href = Util.getAttribute(anchor_attrs, "href")
            local chapter_url = Util.absoluteUrl(site, href)
            if chapter_url and chapter_url:find(base_slug, 1, true) then
                local lurl = (chapter_url or ""):lower()
                if lurl:find("%-chap%-") or lurl:find("chapter") or lurl:find("chuong") then
                    table.insert(chapters, {
                        title = Util.stripTags(anchor_html),
                        url = chapter_url,
                        source_id = self.id,
                        story_url = story.url,
                        kind = self.kind,
                    })
                end
            end
        end
    end

    -- Fallback: search for chapter links inside list_chapter container
    if #chapters == 0 then
        local list_html = html:match('<div[^>]-class="[^"]*list_chapter[^"]*"[^>]*>([%s%S]-)</div>%s*</div>%s*<div[^>]-id="ad_info"')
            or html
        for anchor_attrs, anchor_html in list_html:gmatch("<a([^>]*)>([%s%S]-)</a>") do
            local href = Util.getAttribute(anchor_attrs, "href")
            local chapter_url = Util.absoluteUrl(site, href)
            if chapter_url and chapter_url:find(base_slug, 1, true) then
                local lurl = (chapter_url or ""):lower()
                if lurl:find("%-chap%-") or lurl:find("chapter") or lurl:find("chuong") then
                    table.insert(chapters, {
                        title = Util.stripTags(anchor_html),
                        url = chapter_url,
                        source_id = self.id,
                        story_url = story.url,
                        kind = self.kind,
                    })
                end
            end
        end
    end

    story.details = self:parseStoryDetails(html)
    return {
        story = story,
        chapters = Util.uniqueBy(chapters, "url"),
        page = 1,
        total_pages = 1,
    }
end

function Source:getStoryPage(story)
    local html, err = Http:get(story.url, requestHeaders(siteOf(story.url)), { force_luasec = true })
    if not html then
        return nil, err
    end
    return self:parseStoryPage(html, story)
end

function Source:parseChapter(html, chapter)
    local site = siteOf(chapter.url)
    local images = {}
    local position = 1

    while true do
        local open_start, open_end, div_attrs = html:find("<div([^>]*)>", position)
        if not open_start then
            break
        end
        position = open_end + 1

        local page_id = Util.getAttribute(div_attrs, "id") or ""
        local class_name = Util.getAttribute(div_attrs, "class") or ""
        if page_id:match("^page_%d+$")
                and class_name:find("page-chapter", 1, true) then
            local close_start, close_end = html:find("</div>", position, true)
            if not close_start then
                break
            end

            local div_html = html:sub(position, close_start - 1)
            position = close_end + 1
            for image_tag in div_html:gmatch("(<img[^>]*>)") do
                local primary = Util.getAttribute(image_tag, "data-original")
                    or Util.getAttribute(image_tag, "src")
                if primary then
                    local clean_urls = {}
                    local seen = {}
                    local candidates = {
                        primary,
                        Util.getAttribute(image_tag, "data-cdn"),
                        Util.getAttribute(image_tag, "data-fb"),
                    }
                    for index = 1, 3 do
                        local url = Util.absoluteUrl(site, candidates[index])
                        if url and not seen[url] then
                            seen[url] = true
                            table.insert(clean_urls, url)
                        end
                    end
                    table.insert(images, { urls = clean_urls })
                end
            end
        end
    end

    -- Giao diện truyenqq.com.vn: ảnh nằm trong <div class="reading-content">,
    -- tải lười qua thuộc tính data-src (src chỉ là ảnh giữ chỗ), không có
    -- khối page-chapter. CDN ảnh yêu cầu Referer nên giữ nguyên referer bên dưới.
    if #images == 0 then
        local content_start = html:find('class="reading-content"', 1, true)
        local content_html = content_start and html:sub(content_start) or ""
        for image_tag in content_html:gmatch("(<img[^>]*>)") do
            local url = Util.absoluteUrl(site, Util.getAttribute(image_tag, "data-src"))
            if url then
                table.insert(images, { urls = { url } })
            end
        end
    end

    if #images == 0 then
        return nil, "Không tìm thấy ảnh của chương (kiểm tra lại tên miền TruyenQQ trong Cài đặt, có thể bạn đã nhập tên miền truyện chữ vào nguồn truyện tranh)"
    end

    local title
    for heading_attrs, heading_html in html:gmatch("<h1([^>]*)>([%s%S]-)</h1>") do
        local class_name = Util.getAttribute(heading_attrs, "class") or ""
        if class_name:find("detail-title", 1, true) then
            title = Util.stripTags(heading_html)
            break
        end
    end

    return {
        title = title or chapter.title,
        images = images,
        url = chapter.url,
        referer = site .. "/",
        kind = self.kind,
    }
end

function Source:getChapter(chapter)
    local html, err = Http:get(chapter.url, requestHeaders(siteOf(chapter.url)), { force_luasec = true })
    if not html then
        return nil, err
    end
    return self:parseChapter(html, chapter)
end

return Source