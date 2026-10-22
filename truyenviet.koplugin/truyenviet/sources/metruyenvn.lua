local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")
local ko_util = require("util")

-- MeTruyenVN — Đọc Truyện Đam Mỹ Hoàn (WordPress)
local Source = {
    id = "metruyenvn",
    name = "Mê Truyện VN",
    kind = "text",
    base_url = "https://metruyenvn.org",
}

local function stdHeaders(base_url)
    return {
        ["Referer"] = base_url .. "/",
    }
end

local function parseCards(html, source_id)
    local stories = {}
    local seen = {}
    local pos = 1
    while true do
        local block_s, block_e = html:find('<div class="comic-item-box">', pos, true)
        if not block_s then break end
        local block_end = html:find('<div class="comic-item-box">', block_e + 1, true) or #html
        local block = html:sub(block_s, block_end - 1)
        
        local href = block:match('href="(https?://metruyenvn%.org/truyen/[^"]+)"')
        local title = block:match('title="([^"]+)"')
        local cover = block:match('<img[^>]+src="([^"]+)"')
        
        if href and title and not seen[href] then
            seen[href] = true
            local story = {
                source_id = source_id,
                title = Util.decodeHtml(title),
                url = href,
                cover_url = cover,
                kind = "text",
            }
            -- Thẻ liệt kê có chương mới nhất ("Chương 27") và nhãn "HẾT" khi đã hoàn thành.
            -- Truyện đang ra không có nhãn -> để nil (chưa rõ), core sẽ gọi fetchSearchMeta.
            local meta_block = block:sub(1, 3000)
            local latest = tonumber(meta_block:match('class="comic%-chapter"[^>]*>%s*Chương%s+(%d+)'))
            if latest and latest > 0 then story.latest_chapter = latest end
            if meta_block:find('label%-success[^>]*>%s*HẾT') then story.completed = true end
            table.insert(stories, story)
        end
        pos = block_e + 1
    end
    return stories
end

local function parseListing(html, page, source_id, base_url)
    local stories = parseCards(html, source_id)
    local max_page = page or 1
    for n in html:gmatch('/page/(%d+)/') do
        local p = tonumber(n)
        if p and p > max_page then max_page = p end
    end
    local genres = {}
    for href, prefix, name in html:gmatch('<a[^>]+href="(https?://metruyenvn%.org/([^/]+)/[^"]+)"[^>]*>([^<]+)</a>') do
        if prefix == "the-loai" or prefix == "nhom" or prefix == "loai-truyen" or prefix == "tu-khoa" or prefix == "tags" or prefix == "tag" then
            table.insert(genres, { name = Util.trim(name), url = href })
        end
    end
    return {
        stories = stories,
        genres = genres,
        page = page or 1,
        total_pages = max_page,
        title = "Truyện mới nhất",
    }
end

-- Ô tìm kiếm `?s=` của site đã bị đóng ("Chức năng này đã bị đóng!"); site tự gọi
-- admin-ajax `searchtax` (trả JSON tối đa 10 mục, lẫn cả thể loại/nhóm dịch -> chỉ giữ /truyen/).
-- cstatus: "Trọn bộ" = đã hoàn thành, "Đang tiến hành" = còn ra.
function Source:search(query)
    local headers = stdHeaders(self.base_url)
    headers["X-Requested-With"] = "XMLHttpRequest"
    headers["Accept"] = "application/json, text/javascript, */*; q=0.01"
    local body, err = Http:postForm(
        self.base_url .. "/wp-admin/admin-ajax.php",
        { action = "searchtax", keyword = query },
        headers
    )
    if not body then return nil, err end

    local data = Util.parseJson(body)
    if type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "Mê Truyện VN trả về dữ liệu tìm kiếm không hợp lệ"
    end

    local stories = {}
    local seen = {}
    for _, item in ipairs(data.data) do
        local link = type(item) == "table" and item.link or nil
        local title = type(item) == "table" and item.title or nil
        if type(link) == "string" and type(title) == "string"
            and link:find("^https?://metruyenvn%.org/truyen/") and not seen[link] then
            seen[link] = true
            local story = {
                source_id = self.id,
                title = Util.decodeHtml(title),
                url = link,
                cover_url = type(item.img) == "string" and item.img or nil,
                kind = "text",
            }
            if item.cstatus == "Trọn bộ" then
                story.completed = true
            elseif item.cstatus == "Đang tiến hành" then
                story.completed = false
            end
            table.insert(stories, story)
        end
    end
    return stories
end

-- Meta nhẹ cho kết quả tìm kiếm/duyệt: đúng 1 request vào trang truyện.
-- Danh sách chương trên trang thưa và gom nhóm nên không đếm link; lấy số chương lớn nhất
-- trong bảng chương (dạng /chuong-27-67/ hoặc /<slug>-chuong-7/) làm số chương.
function Source:fetchSearchMeta(story)
    local html, err = Http:get(story.url, stdHeaders(self.base_url))
    if not html then return nil, err end

    local latest
    for anchor in html:gmatch('<a class="text%-capitalize" href="([^"]+)"') do
        local n = tonumber(anchor:match('.*chuong%-(%d+)'))
        if n and (not latest or n > latest) then latest = n end
    end
    if not latest then
        latest = tonumber(html:match('href="https?://metruyenvn%.org/chuong%-(%d+)%-%d+/"'))
    end

    local meta = {}
    if latest and latest > 0 then meta.latest_chapter = latest end

    local status_html = html:match('<strong>Tình trạng:</strong>%s*<span[^>]*>(.-)</span>')
    if status_html then
        meta.completed = status_html:find("Trọn bộ", 1, true) ~= nil
    end

    if meta.latest_chapter == nil and meta.completed == nil then
        return nil, "Không đọc được số chương/trạng thái"
    end
    return meta
end

function Source:getCompleted(page)
    page = page or 1
    local url = self.base_url .. "/"
    if page > 1 then url = url .. "page/" .. page .. "/" end
    local html, err = Http:get(url, stdHeaders(self.base_url))
    if not html then return nil, err end
    local result = parseListing(html, page, self.id, self.base_url)
    result.title = "Truyện đam mỹ mới nhất"
    return result
end

function Source:getGenre(genre, page)
    page = page or 1
    local url = Util.withTrailingSlash(genre.url)
    if page > 1 then url = url .. "page/" .. page .. "/" end
    local html, err = Http:get(url, stdHeaders(self.base_url))
    if not html then return nil, err end
    local result = parseListing(html, page, self.id, self.base_url)
    result.title = genre.name
    return result
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local title = html:match('<meta property="og:title" content="([^"]+)%s*-%s*Mê Truyện')
        or html:match('<h2[^>]*class="[^"]*info%-title[^"]*"[^>]*>([^<]+)</h2>')
        or html:match('<meta itemprop="name" content="([^"]+)">')
    
    local author = html:match('<strong>Tác giả:</strong>%s*<span>%s*(.-)%s*</span>')
        or html:match('Tác giả[%s%S]-<a[^>]*>([^<]+)</a>')
    
    local desc_html = html:match('<div[^>]+class="[^"]*desc%-text[^"]*"[^>]*>(.-)</div>')
        or html:match('<div[^>]+itemprop="description"[^>]*>(.-)</div>')
    
    local description
    if desc_html then
        description = Util.stripTags(desc_html)
        description = description:gsub("^%s+", ""):gsub("%s+$", "")
    end
    
    local genres = {}
    local tags_html = html:match('<div class="tags[^"]*">(.-)</div>')
    if tags_html then
        for name in tags_html:gmatch('<a[^>]*>([^<]+)</a>') do
            table.insert(genres, Util.trim(name))
        end
    end

    local status_html = html:match('<strong>Tình trạng:</strong>%s*<span[^>]*>(.-)</span>')
    local is_completed = false
    if status_html and status_html:find("Trọn bộ") then
        is_completed = true
    end
    
    return {
        title = title and Util.decodeHtml(Util.trim(title)) or story.title,
        author = author and Util.trim(author) or nil,
        description = description,
        genres = genres,
        is_completed = is_completed,
    }
end

function Source:getStoryPage(story, page)
    page = page or 1
    local html, err = Http:get(story.url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local chapters = {}
    local seen = {}
    
    -- Chapter format: <a href="https://metruyenvn.org/chuong-123/">...</a>
    for href, inner_html in html:gmatch('<a[^>]+href="(https?://metruyenvn%.org/chuong%-[^"]+)"[^>]*>([%s%S]-)</a>') do
        if not seen[href] then
            seen[href] = true
            local title = inner_html:match('<span class="hidden%-sm hidden%-xs">(.-)</span>')
            if not title then title = inner_html end
            title = Util.trim(Util.stripTags(title))
            table.insert(chapters, 1, {
                title = title,
                url = href,
                source_id = self.id,
                story_url = story.url,
                kind = self.kind,
            })
        end
    end
    
    if #chapters == 0 then
        for href, inner_html in html:gmatch('<a[^>]+class="[^"]*comic%-chapter[^"]*"[^>]+href="([^"]+)"[^>]*>([%s%S]-)</a>') do
            if href:find("^https?://") and not seen[href] then
                seen[href] = true
                local title = inner_html:match('<span class="hidden%-sm hidden%-xs">(.-)</span>')
                if not title then title = inner_html end
                title = Util.trim(Util.stripTags(title))
                table.insert(chapters, 1, {
                    title = title,
                    url = href,
                    source_id = self.id,
                    story_url = story.url,
                    kind = self.kind,
                })
            end
        end
    end
    
    story.details = self:getStoryDetails(story)
    
    return {
        story = story,
        chapters = chapters,
        page = page,
        total_pages = 1,
    }
end

function Source:getChapter(chapter)
    local html, err = Http:get(chapter.url, stdHeaders(self.base_url))
    if not html then return nil, err end
    
    local start_pos = html:find('<div[^>]*class="[^"]*view%-chapter[^"]*"[^>]*>')
        or html:find('<div[^>]*id="chapter%-content"[^>]*>')
        
    if not start_pos then
        return nil, "Không tìm thấy nội dung chương"
    end
    
    local content_start = html:find('>', start_pos)
    if not content_start then return nil, "Lỗi cú pháp HTML" end
    
    local end_pos = html:find('</div>%s*</div>%s*<section', content_start)
        or html:find('</div>%s*<div[^>]*class="margin%-bottom%-15px"', content_start)
        or html:find('</div>%s*<div', content_start)
        
    local content = end_pos and html:sub(content_start + 1, end_pos - 1) or html:sub(content_start + 1)
    
    return Util.sanitizeContentHtml(content)
end

function Source:getChapterAsync(chapter)
    local html, err = Http:requestAsync("GET", chapter.url, nil, stdHeaders(self.base_url))
    if not html then return nil, err end
    local start_pos = html:find('<div[^>]*class="[^"]*view%-chapter[^"]*"[^>]*>')
        or html:find('<div[^>]*id="chapter%-content"[^>]*>')
        
    if not start_pos then
        return nil, "Không tìm thấy nội dung chương"
    end
    
    local content_start = html:find('>', start_pos)
    if not content_start then return nil, "Lỗi cú pháp HTML" end
    
    local end_pos = html:find('</div>%s*</div>%s*<section', content_start)
        or html:find('</div>%s*<div[^>]*class="margin%-bottom%-15px"', content_start)
        or html:find('</div>%s*<div', content_start)
        
    local content = end_pos and html:sub(content_start + 1, end_pos - 1) or html:sub(content_start + 1)
    
    return Util.sanitizeContentHtml(content)
end

return Source

