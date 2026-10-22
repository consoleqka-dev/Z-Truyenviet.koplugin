local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")
local ko_util = require("util")
local ok_json, json = pcall(require, "json")
if not ok_json or not json then
    ok_json, json = pcall(require, "dkjson")
end

local Source = {
    id = "giatocvuongtai",
    name = "Gia Tộc Vượng Tài",
    kind = "text",
    base_url = "https://giatocvuongtai.com",
    api_url = "https://giatocvuongtai.com/api/public"
}

function Source:getCoverHeaders()
    return {
        ["Referer"] = self.base_url .. "/",
    }
end

local CATEGORIES = {
    { url = "dam_my", name = "Đam Mỹ" },
    { url = "ngon_tinh", name = "Ngôn Tình" },
    { url = "bach_hop", name = "Bách Hợp" },
    { url = "nam_chu", name = "Nam Chủ" },
    { url = "nu_chu", name = "Nữ Chủ" }
}

local function formatStory(self, item)
    local cover = item.cover_url
    if cover and cover ~= "" then
        cover = "https://wsrv.nl/?w=300&output=jpeg&q=70&url=" .. cover:gsub("^https?://", "")
    end
    -- API trả sẵn số chương và trạng thái; completed = nil nếu thiếu trường
    local completed = nil
    if type(item.completion_status) == "string" then
        completed = item.completion_status == "completed"
    end
    return {
        source_id = self.id,
        title = item.title,
        url = self.base_url .. "/story/" .. item.slug,
        cover_url = cover,
        kind = self.kind,
        chapter_count = tonumber(item.chapter_count),
        completed = completed,
        _slug = item.slug,
        _id = item.id
    }
end

function Source:search(query)
    local encoded = ko_util.urlEncode(query)
    local url = self.api_url .. "/stories.json?limit=50&q=" .. encoded
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local stories = {}
    for _, item in ipairs(data.data) do
        table.insert(stories, formatStory(self, item))
    end
    return stories
end

-- Chương mới nhất của một truyện từ JSON chi tiết: các chương đã xuất bản được đánh số
-- bằng order_number (0 = mục "Giới thiệu", không tính). Lấy số lớn nhất, không phụ thuộc
-- thứ tự mảng.
function Source:parseLatestChapter(item)
    if type(item) ~= "table" or type(item.chapters) ~= "table" then
        return nil
    end
    local latest
    for _, chap in ipairs(item.chapters) do
        local order = tonumber(chap.order_number)
        if chap.is_published and order and order > 0 and (not latest or order > latest) then
            latest = order
        end
    end
    return latest
end

-- 1 request tới JSON chi tiết (danh sách chương nằm trong đó). Endpoint này đứng sau
-- Cloudflare và chỉ cho qua request giống fetch cùng nguồn của trình duyệt
-- (Sec-Fetch-*); thiếu các header này sẽ nhận 403 trang thử thách.
function Source:fetchSearchMeta(story)
    local slug = tostring(story.url or ""):match("/story/([^/]+)")
    if not slug then return nil, "Invalid URL" end
    if not json then return nil, "Thiếu thư viện JSON" end
    local json_str, err = Http:get(self.api_url .. "/story/" .. slug .. ".json", {
        ["Accept"] = "application/json",
        ["Referer"] = self.base_url .. "/story/" .. slug,
        ["Sec-Fetch-Mode"] = "cors",
        ["Sec-Fetch-Site"] = "same-origin",
    })
    if not json_str then return nil, err end

    local ok, data = pcall(json.decode, json_str)
    if not ok or type(data) ~= "table" or type(data.data) ~= "table" then
        return nil, "Invalid JSON"
    end
    local item = data.data
    local meta = { latest_chapter = self:parseLatestChapter(item) }
    if type(item.completion_status) == "string" then
        meta.completed = item.completion_status == "completed"
    end
    if meta.latest_chapter == nil and meta.completed == nil then
        return nil, "Không đọc được chương mới nhất"
    end
    return meta
end

function Source:getCompleted(page)
    page = page or 1
    local limit = 20
    local offset = (page - 1) * limit
    local url = self.api_url .. "/stories.json?status=published&completionStatus=completed&limit=" .. limit .. "&offset=" .. offset
    
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local stories = {}
    for _, item in ipairs(data.data) do
        table.insert(stories, formatStory(self, item))
    end
    
    local total_pages = page
    if #stories == limit then
        total_pages = page + 1
    end
    
    return {
        stories = stories,
        genres = CATEGORIES,
        page = page,
        total_pages = total_pages,
        title = "Truyện đã hoàn thành"
    }
end

function Source:getGenre(genre, page)
    page = page or 1
    local limit = 20
    local offset = (page - 1) * limit
    local url = self.api_url .. "/stories.json?status=published&limit=" .. limit .. "&offset=" .. offset
    
    if genre and genre.url then
        url = url .. "&storyRole=" .. genre.url
    end
    
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local stories = {}
    for _, item in ipairs(data.data) do
        table.insert(stories, formatStory(self, item))
    end
    
    local total_pages = page
    if #stories == limit then
        total_pages = page + 1
    end
    
    return {
        stories = stories,
        genres = CATEGORIES,
        page = page,
        total_pages = total_pages,
        title = genre and genre.name or "Thể loại"
    }
end

function Source:getStoryDetails(story)
    local slug = story.url:match("/story/([^/]+)")
    if not slug then return nil, "Invalid URL" end
    local url = self.api_url .. "/story/" .. slug .. ".json"
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local item = data.data
    local status = "Đang ra"
    if item.completion_status == "completed" then status = "Hoàn thành" end
    
    local author = item.author_name
    if not author and item.author then author = item.author.name end
    
    local description = item.summary
    if description then
        -- Strip HTML tags and clean up description for plain text display
        description = description:gsub("<br%s*/>", "\n"):gsub("<br>", "\n")
        description = description:gsub("<[^>]+>", "")
        description = description:gsub("[\xF0-\xF7][\x80-\xBF][\x80-\xBF][\x80-\xBF]", "")
        description = description:gsub("\n%s*\n%s*\n+", "\n\n")
        description = Util.decodeHtml(Util.trim(description))
    end

    return {
        description = description,
        author = author,
        status = status,
        genres = item.tags or {},
    }
end

function Source:getStoryPage(story, page)
    page = page or 1
    if page > 1 then
        return {
            story = story,
            chapters = {},
            page = page,
            total_pages = 1
        }
    end
    
    local slug = story.url:match("/story/([^/]+)")
    if not slug then return nil, "Invalid URL" end
    local url = self.api_url .. "/story/" .. slug .. ".json"
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local item = data.data
    local chapters = {}
    
    if item.chapters then
        for _, chap in ipairs(item.chapters) do
            if chap.is_published then
                table.insert(chapters, {
                    title = chap.title,
                    url = self.base_url .. "/chapter/" .. chap.id,
                    source_id = self.id,
                    story_url = story.url,
                    kind = self.kind,
                    _id = chap.id
                })
            end
        end
    end
    
    local status = "Đang ra"
    if item.completion_status == "completed" then status = "Hoàn thành" end
    local author = item.author_name
    if not author and item.author then author = item.author.name end
    local description = item.summary
    if description then
        description = description:gsub("<br%s*/>", "\n"):gsub("<br>", "\n")
        description = description:gsub("<[^>]+>", "")
        description = description:gsub("[\xF0-\xF7][\x80-\xBF][\x80-\xBF][\x80-\xBF]", "")
        description = description:gsub("\n%s*\n%s*\n+", "\n\n")
        description = Util.decodeHtml(Util.trim(description))
    end
    
    story.details = {
        description = description,
        author = author,
        status = status,
        genres = item.tags or {},
    }
    
    return {
        story = story,
        chapters = chapters,
        page = 1,
        total_pages = 1,
    }
end

local function parseChapterData(self, json_str, chapter)
    local data = json.decode(json_str)
    if not data or not data.data then return nil, "Invalid JSON" end
    
    local chapData = data.data
    local content_html = ""
    
    if chapData.content and chapData.content.blocks then
        for _, block in ipairs(chapData.content.blocks) do
            if block.type == "paragraph" then
                local p_text = ""
                if block.inline then
                    for _, inline in ipairs(block.inline) do
                        local text = Util.escapeHtml(inline.text or "")
                        if inline.marks then
                            for _, mark in ipairs(inline.marks) do
                                if mark == "italic" then text = "<i>" .. text .. "</i>" end
                                if mark == "bold" then text = "<b>" .. text .. "</b>" end
                                if mark == "underline" then text = "<u>" .. text .. "</u>" end
                                if mark == "strike" then text = "<s>" .. text .. "</s>" end
                            end
                        end
                        p_text = p_text .. text
                    end
                end
                content_html = content_html .. "<p>" .. p_text .. "</p>"
            elseif block.type == "image" then
                if block.attrs and block.attrs.src then
                    content_html = content_html .. '<img src="' .. Util.escapeHtml(block.attrs.src) .. '"/>'
                end
            end
        end
    end
    
    return {
        title = chapData.title or chapter.title,
        content = content_html,
        url = chapter.url,
        kind = self.kind,
    }
end

function Source:getChapter(chapter)
    local chapter_id = chapter.url:match("/chapter/([^/]+)")
    if not chapter_id then return nil, "Invalid URL" end
    local url = self.api_url .. "/chapter/" .. chapter_id .. ".json"
    local json_str, err = Http:get(url)
    if not json_str then return nil, err end
    
    return parseChapterData(self, json_str, chapter)
end

function Source:getChapterAsync(chapter)
    local chapter_id = chapter.url:match("/chapter/([^/]+)")
    if not chapter_id then return nil, "Invalid URL" end
    local url = self.api_url .. "/chapter/" .. chapter_id .. ".json"
    local json_str, err = Http:requestAsync("GET", url)
    if not json_str then return nil, err end
    
    return parseChapterData(self, json_str, chapter)
end

return Source
