local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")
local Debug = require("truyenviet/debugger")

local Source = {
    id = "zettruyen",
    name = "ZetTruyen",
    kind = "comic",
    base_url = "https://www.zettruyen4.com",
    reversed_chapters = false,
}

-- ZetTruyen đổi tên miền theo số (zettruyen4, zettruyen5...). Truyện đã lưu
-- phải tải từ đúng tên miền trong URL của nó; truyện mới dùng base_url (có thể
-- đổi trong Cài đặt nguồn).
local function siteOf(url)
    return tostring(url or ""):match("^(https?://[^/]+)") or Source.base_url
end

-- CDN ảnh (cdnX.zetimage.com, sau Cloudflare) trả 403 nếu thiếu Referer của
-- trang truyện; cả ảnh bìa lẫn ảnh chương đều cần.
local function pageHeaders(site)
    return {
        ["Referer"] = (site or Source.base_url) .. "/",
        ["Accept-Language"] = "vi-VN,vi;q=0.9,en;q=0.7",
    }
end

local function jsonHeaders(site)
    local headers = pageHeaders(site)
    headers["Accept"] = "application/json"
    headers["X-Requested-With"] = "XMLHttpRequest"
    return headers
end

local function slugOf(url)
    return tostring(url or ""):match("/truyen%-tranh/([^/?#]+)")
end

-- chapter_num có thể là số lẻ (39.1): URL dùng đúng "chuong-39.1", còn số
-- nguyên phải bỏ ".0".
local function formatChapterNum(value)
    local number = tonumber(value)
    if not number then
        return tostring(value or "")
    end
    if number == math.floor(number) then
        return string.format("%d", number)
    end
    return tostring(number)
end

local function getJson(url, site)
    local body, err = Http:get(url, jsonHeaders(site))
    if not body then
        return nil, err
    end
    local data = Util.parseJson(body)
    if type(data) ~= "table" or data.success == false then
        return nil, "ZetTruyen trả về dữ liệu không hợp lệ"
    end
    return data.data
end

function Source:getCoverHeaders(story)
    return pageHeaders(siteOf(story and story.url or self.base_url))
end

function Source:getImageHeaders()
    return pageHeaders(self.base_url)
end

local function chaptersApi(site, slug, page, per_page)
    return string.format(
        "%s/api/comics/%s/chapters?page=%d&per_page=%d&order=asc",
        site, slug, page, per_page
    )
end

-- Nhãn trạng thái trên huy hiệu của thẻ truyện ở trang tìm kiếm nâng cao.
-- Không có huy hiệu hoặc nhãn lạ -> nil (không rõ).
local STATUS_BADGES = {
    ["Hoàn Thành"] = true,
    ["Hoàn thành"] = true,
    ["Full"] = true,
    ["Đang tiến hành"] = false,
    ["Đang Tiến Hành"] = false,
    ["Đang Cập Nhật"] = false,
    ["Đang cập nhật"] = false,
}

-- Trang tìm kiếm nâng cao (1 request) liệt kê thẻ truyện kèm huy hiệu trạng
-- thái; quick-search không có trạng thái. Trả về bảng slug -> completed.
function Source:parseStatusMap(html, site)
    local map = {}
    local marker = '<a href="' .. site .. '/truyen-tranh/'
    local position = 1
    while true do
        local start = html:find(marker, position, true)
        if not start then
            break
        end
        local next_start = html:find(marker, start + #marker, true)
        local card = html:sub(start, (next_start or #html + 1) - 1)
        -- Chỉ xét phần trong thẻ <a> của chính truyện này, tránh nhặt huy hiệu
        -- của khối khác phía sau thẻ cuối cùng.
        card = card:match("^(.-)</a>") or card
        local slug = card:match('truyen%-tranh/([^/"]+)"')
        local badge = card:match('data%-state="([^"]*)"%s+class="absolute')
        if slug and badge then
            local completed = STATUS_BADGES[Util.trim(badge)]
            if completed ~= nil then
                map[slug] = completed
            end
        end
        position = start + #marker
    end
    return map
end

function Source:fetchStatusMap(query)
    local html, err = Http:get(
        self.base_url .. "/tim-kiem-nang-cao?name=" .. Util.urlEncode(query),
        pageHeaders(self.base_url)
    )
    if not html then
        return nil, err
    end
    return self:parseStatusMap(html, self.base_url)
end

-- Tổng số chương chính xác: API danh sách chương với per_page=1 chỉ trả
-- "total" (~200 byte), chỉ dùng khi quick-search không có chương mới nhất.
-- Trạng thái không có trong API này nên để nil.
function Source:fetchSearchMeta(story)
    if tonumber(story.latest_chapter) then
        return {}
    end
    local slug = slugOf(story.url)
    if not slug then
        return nil, "Không nhận ra mã truyện ZetTruyen trong đường dẫn"
    end
    local site = siteOf(story.url)
    local data, err = getJson(chaptersApi(site, slug, 1, 1), site)
    if not data then
        return nil, err
    end
    local total = type(data) == "table" and tonumber(data.total)
    if not total or total <= 0 then
        return nil, "ZetTruyen không trả về tổng số chương"
    end
    return { chapter_count = math.floor(total), completed = nil }
end

function Source:search(query)
    local data, err = getJson(
        self.base_url .. "/api/quick-search?q=" .. Util.urlEncode(query),
        self.base_url
    )
    if not data then
        return nil, err
    end

    local stories = {}
    for _, item in ipairs(type(data) == "table" and data or {}) do
        local slug = item.slug
        local url = item.url
            or (slug and (self.base_url .. "/truyen-tranh/" .. slug))
        if url and item.name then
            -- Quick-search có sẵn chương mới nhất (vd 700.9), miễn phí.
            local last = type(item.last_chapter) == "table" and tonumber(item.last_chapter.chapter_num) or nil
            table.insert(stories, {
                source_id = self.id,
                title = Util.decodeHtml(item.name),
                url = url,
                cover_url = item.thumbnail,
                kind = self.kind,
                latest_chapter = last and last > 0 and last or nil,
            })
        end
    end
    stories = Util.uniqueBy(stories, "url")

    if #stories > 0 then
        local ok, status_map, status_err = pcall(self.fetchStatusMap, self, query)
        if ok and status_map then
            for _, story in ipairs(stories) do
                local completed = status_map[slugOf(story.url)]
                if completed ~= nil then
                    story.completed = completed
                end
            end
        else
            Debug.write("[ZetTruyen] Không lấy được trạng thái: " .. tostring(ok and status_err or status_map))
        end
    end
    return stories
end

local function infoValue(html, label)
    local value = html:match(
        ">%s*" .. label .. "%s*</div>%s*<div[^>]*>([%s%S]-)</div>"
    )
    value = value and Util.stripTags(value) or ""
    return value ~= "" and value or nil
end

function Source:parseStoryDetails(html)
    local description = html:match('"articleBody"%s*:%s*"([^"]*)"')
    if description then
        description = Util.decodeHtml(description)
    else
        description = Util.getMetaContent(html, "name", "description")
    end

    local genre_html
    local genre_start = html:find(">%s*Thể loại%s*</div>")
    if genre_start then
        genre_html = html:sub(genre_start, genre_start + 6000):match(
            "<div[^>]-flex%-wrap[^>]*>([%s%S]-)</div>"
        )
    end

    return {
        description = description,
        author = infoValue(html, "Tác giả"),
        status = infoValue(html, "Trạng thái"),
        genres = Util.parseGenreNames(genre_html),
    }
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, pageHeaders(siteOf(story.url)))
    if not html then
        return nil, err
    end
    return self:parseStoryDetails(html)
end

function Source:fetchChapters(story)
    local site = siteOf(story.url)
    local slug = slugOf(story.url)
    if not slug then
        return nil, "Không nhận ra mã truyện ZetTruyen trong đường dẫn"
    end

    local chapters = {}
    local page, last_page = 1, 1
    repeat
        local data, err = getJson(chaptersApi(site, slug, page, 100), site)
        if not data then
            if #chapters > 0 then
                Debug.write(string.format(
                    "[ZetTruyen] Dừng ở trang chương %d: %s", page, tostring(err)))
                break
            end
            return nil, err
        end
        last_page = tonumber(data.last_page) or page
        for _, item in ipairs(type(data.chapters) == "table" and data.chapters or {}) do
            local num = formatChapterNum(item.chapter_num)
            if num ~= "" then
                table.insert(chapters, {
                    title = Util.decodeHtml(item.chapter_name or ("Chapter " .. num)),
                    url = string.format("%s/truyen-tranh/%s/chuong-%s", site, slug, num),
                    source_id = self.id,
                    story_url = story.url,
                    kind = self.kind,
                })
            end
        end
        page = page + 1
    until page > last_page or page > 100

    return Util.uniqueBy(chapters, "url")
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
        local class_name = Util.getAttribute(image_tag, "class") or ""
        local url = Util.absoluteUrl(site, Util.getAttribute(image_tag, "src"))
        -- Ảnh trang truyện dùng class "object-cover mx-auto" trên CDN zetimage;
        -- loại banner của site và ảnh bìa truyện gợi ý (/thumb/).
        if url
                and class_name:find("object-cover", 1, true)
                and url:find("zetimage.com", 1, true)
                and not url:find("/thumb/", 1, true)
                and not seen[url] then
            seen[url] = true
            table.insert(images, { urls = { url } })
        end
    end

    if #images == 0 then
        return nil, "Không tìm thấy ảnh của chương ZetTruyen"
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
    local html, err = Http:get(chapter.url, pageHeaders(siteOf(chapter.url)))
    if not html then
        return nil, err
    end
    return self:parseChapter(html, chapter)
end

return Source
