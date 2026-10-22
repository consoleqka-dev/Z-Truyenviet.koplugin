local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")

local Source = {
    id = "weebcentral",
    name = "WeebCentral",
    kind = "comic",
    base_url = "https://weebcentral.com",
    reversed_chapters = false,
}

local function siteOf(url)
    return tostring(url or ""):match("^(https?://[^/]+)") or Source.base_url
end

local function pageHeaders(site)
    return {
        ["Referer"] = (site or Source.base_url) .. "/",
        ["Accept-Language"] = "en-US,en;q=0.9",
    }
end

-- Trang dùng htmx: các mảnh danh sách chương / ảnh chương trả về khi có
-- HX-Request, giống trình duyệt.
local function fragmentHeaders(site)
    local headers = pageHeaders(site)
    headers["HX-Request"] = "true"
    return headers
end

local function seriesIdOf(url)
    return tostring(url or ""):match("/series/([%w]+)")
end

-- Mã chương là ULID ngẫu nhiên; thêm đoạn tên đọc được ("/chapter-12") vào
-- cuối URL để tệp tải về có tên dễ đọc (Storage lấy phần cuối URL làm tên
-- tệp). Khi gọi lên web thì chỉ dùng mã chương.
local function chapterIdOf(url)
    return tostring(url or ""):match("/chapters/([%w]+)")
end

local function chapterSlug(title)
    local slug = tostring(title or ""):lower():gsub("[^%w%.]+", "-")
    slug = slug:gsub("^%-+", ""):gsub("%-+$", "")
    return slug ~= "" and slug or "chapter"
end

function Source:getCoverHeaders(story)
    return pageHeaders(siteOf(story and story.url or self.base_url))
end

function Source:getImageHeaders()
    return pageHeaders(self.base_url)
end

function Source:parseSearch(html)
    local stories = {}
    local marker = '<article class="bg-base-300 flex gap-4 p-4">'
    local position = 1
    local starts = {}
    while true do
        local found = html:find(marker, position, true)
        if not found then
            break
        end
        table.insert(starts, found)
        position = found + #marker
    end

    for index, start in ipairs(starts) do
        local finish = starts[index + 1] and (starts[index + 1] - 1) or #html
        local card = html:sub(start, finish)
        local url = card:match('href="(https?://[^"]-/series/[^"]+)"')
        local title = card:match('alt="([^"]-) cover"')
        if url and title then
            local status = card:match("Status:%s*</strong>%s*<span>%s*([^<]-)%s*</span>")
            local completed
            if status and status ~= "" then
                completed = status == "Complete"
            end
            table.insert(stories, {
                source_id = self.id,
                title = Util.decodeHtml(title),
                url = url,
                cover_url = card:match('<img[^>]-src="([^"]+)"'),
                kind = self.kind,
                -- Có nhãn Status trên thẻ: Complete = hoàn thành, nhãn khác = chưa; không có nhãn = nil.
                completed = completed,
            })
        end
    end
    return Util.uniqueBy(stories, "url")
end

function Source:search(query)
    local url = self.base_url
        .. "/search/data?author=&text=" .. Util.urlEncode(query)
        .. "&sort=Best+Match&order=Descending&official=Any&anime=Any&adult=Any"
        .. "&display_mode=Full+Display"
    local html, err = Http:get(url, fragmentHeaders(self.base_url))
    if not html then
        return nil, err
    end
    return self:parseSearch(html)
end

-- Site hay trả 429 khi gọi dồn: chỉ cho chạy tuần tự khi lấy số chương.
Source.meta_concurrency = 1

-- RSS của truyện (~1 KB) có mục mới nhất dạng "<Tên> Chapter 1196"; dùng số
-- chương mới nhất làm số chương thay cho danh sách chương đầy đủ (hơn 1 MB).
function Source:parseLatestChapter(rss)
    local number = tonumber(tostring(rss or ""):match(
        "<item>%s*<title>[^<]-Chapter%s+([%d%.]+)%s*</title>"
    ))
    return number and number > 0 and number or nil
end

function Source:fetchSearchMeta(story)
    local series_id = seriesIdOf(story.url)
    if not series_id then
        return nil, "Không nhận ra mã truyện WeebCentral trong đường dẫn"
    end
    local site = siteOf(story.url)
    local rss, err = Http:get(
        string.format("%s/series/%s/rss", site, series_id),
        pageHeaders(site)
    )
    if not rss then
        return nil, err
    end
    local latest = self:parseLatestChapter(rss)
    if not latest then
        return nil, "Không đọc được chương mới nhất từ RSS WeebCentral"
    end
    return { latest_chapter = latest, completed = nil }
end

local function labelBlock(html, label)
    return html:match("<strong[^>]*>%s*" .. label .. "%s*</strong>([%s%S]-)</li>")
end

function Source:parseStoryDetails(html)
    local description = html:match(
        "Description%s*</strong>%s*<p[^>]*>([%s%S]-)</p>"
    )
    description = description and Util.stripTags(description) or ""
    if description == "" then
        description = Util.getMetaContent(html, "name", "description")
    end

    local authors = {}
    for name in tostring(labelBlock(html, "Author%(s%):") or ""):gmatch("<a[^>]*>([%s%S]-)</a>") do
        table.insert(authors, Util.stripTags(name))
    end
    local genres = {}
    for name in tostring(labelBlock(html, "Tags%(s%):") or ""):gmatch("<a[^>]*>([%s%S]-)</a>") do
        table.insert(genres, Util.stripTags(name))
    end
    local status = Util.stripTags(labelBlock(html, "Status:") or "")

    return {
        description = description,
        author = #authors > 0 and table.concat(authors, ", ") or nil,
        status = status ~= "" and status or nil,
        genres = genres,
    }
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, pageHeaders(siteOf(story.url)))
    if not html then
        return nil, err
    end
    return self:parseStoryDetails(html)
end

function Source:parseChapterList(html, story)
    local site = siteOf(story.url)
    local chapters = {}
    for href, body in html:gmatch('<a href="([^"]-/chapters/[%w]+)"[^>]*>([%s%S]-)</a>') do
        local chapter_id = chapterIdOf(href)
        local title = body:match('<span class="">%s*([^<]-)%s*</span>')
        if chapter_id and title and title ~= "" then
            title = Util.decodeHtml(title)
            table.insert(chapters, {
                title = title,
                url = string.format("%s/chapters/%s/%s", site, chapter_id, chapterSlug(title)),
                source_id = self.id,
                story_url = story.url,
                kind = self.kind,
            })
        end
    end

    -- Trang trả về chương mới nhất trước; đảo lại cho đúng thứ tự đọc.
    local ordered = {}
    for index = #chapters, 1, -1 do
        table.insert(ordered, chapters[index])
    end
    return Util.uniqueBy(ordered, "url")
end

function Source:fetchChapters(story)
    local site = siteOf(story.url)
    local series_id = seriesIdOf(story.url)
    if not series_id then
        return nil, "Không nhận ra mã truyện WeebCentral trong đường dẫn"
    end
    local html, err = Http:get(
        string.format("%s/series/%s/full-chapter-list", site, series_id),
        fragmentHeaders(site)
    )
    if not html then
        return nil, err
    end
    local chapters = self:parseChapterList(html, story)
    if #chapters == 0 then
        return nil, "Không tìm thấy chương nào trên WeebCentral"
    end
    return chapters
end

function Source:getAllChapters(story)
    return self:fetchChapters(story)
end

function Source:getStoryPage(story)
    local chapters, err = self:fetchChapters(story)
    if not chapters then
        return nil, err
    end

    local ok, details = pcall(self.getStoryDetails, self, story)
    if ok and type(details) == "table" then
        story.details = details
    end

    return {
        story = story,
        chapters = chapters,
        page = 1,
        total_pages = 1,
    }
end

function Source:parseChapter(html, chapter)
    local site = siteOf(chapter.url)
    local images = {}
    local seen = {}
    for image_tag in html:gmatch("(<img[^>]*>)") do
        local alt = Util.getAttribute(image_tag, "alt") or ""
        local url = Util.absoluteUrl(site, Util.getAttribute(image_tag, "src"))
        if url and alt:match("^Page %d+") and not seen[url] then
            seen[url] = true
            table.insert(images, { urls = { url } })
        end
    end

    if #images == 0 then
        return nil, "Không tìm thấy ảnh của chương WeebCentral"
    end

    return {
        title = chapter.title,
        images = images,
        url = chapter.url,
        referer = site .. "/",
        kind = self.kind,
    }
end

function Source:getChapter(chapter)
    local site = siteOf(chapter.url)
    local chapter_id = chapterIdOf(chapter.url)
    if not chapter_id then
        return nil, "Không nhận ra mã chương WeebCentral"
    end
    local html, err = Http:get(
        string.format(
            "%s/chapters/%s/images?is_prev=False&current_page=1&reading_style=long_strip",
            site, chapter_id
        ),
        fragmentHeaders(site)
    )
    if not html then
        return nil, err
    end
    return self:parseChapter(html, chapter)
end

return Source
