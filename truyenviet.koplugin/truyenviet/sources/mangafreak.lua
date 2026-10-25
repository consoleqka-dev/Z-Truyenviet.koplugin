local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")

local Source = {
    id = "mangafreak", name = "MangaFreak", kind = "comic",
    base_url = "https://ww3.mangafreak.me", reversed_chapters = false,
    meta_concurrency = 1,
}

function Source:getCoverHeaders()
    return { ["Referer"] = self.base_url .. "/", ["Accept-Language"] = "en-US,en;q=0.9" }
end

Source.getImageHeaders = Source.getCoverHeaders

local function hasClass(tag, name)
    local classes = " " .. (Util.getAttribute(tag, "class") or "") .. " "
    return classes:find(" " .. name .. " ", 1, true) ~= nil
end

local function chaptersOf(html, story, source)
    local chapters = {}
    for attrs, body in html:gmatch("<a([^>]*)>([%s%S]-)</a>") do
        local href = Util.getAttribute(attrs, "href")
        if href and href:match("^/Read%d+_") and hasClass(attrs, "chapter-link") then
            table.insert(chapters, {
                title = Util.stripTags(body), url = Util.absoluteUrl(source.base_url, href),
                source_id = source.id, story_url = story.url, kind = source.kind,
            })
        end
    end
    -- The site's main table is already oldest first; sidebar links repeat the latest chapters.
    return Util.uniqueBy(chapters, "url")
end

function Source:parseGenres(html)
    local genres = {}
    for attrs, body in html:gmatch("<a([^>]*)>([%s%S]-)</a>") do
        local href = Util.getAttribute(attrs, "href")
        if href and href:match("^/Genre/[^/]+$") and href ~= "/Genre/All" then
            table.insert(genres, { name = Util.stripTags(body), url = self.base_url .. href })
        end
    end
    return Util.uniqueBy(genres, "url")
end

function Source:parseListing(html, page)
    local starts = {}
    local card_classes = { ranking_item = true, manga_search_item = true, list_item = true, latest_releases_item = true }
    for position, tag in html:gmatch('()(<div[^>]*>)') do
        if card_classes[Util.getAttribute(tag, "class")] then starts[#starts + 1] = position end
    end
    local stories = {}
    for index, start in ipairs(starts) do
        local card = html:sub(start, starts[index + 1] and starts[index + 1] - 1 or #html)
        local href = card:match('href=["\'](/Manga/[^"\']+)["\']')
        local title = card:match('<h3[^>]*>([%s%S]-)</h3>')
            or card:match('<strong[^>]*>([%s%S]-)</strong>')
        if href and title then
            local img = card:match('(<img[^>]*>)')
            local status = card:match('%((Completed)%)') or card:match('%((Ongoing)%)')
                or card:match('Status:</h6>%s*(%w+)')
            local count = card:match('(%d+)%s+Chapters?') or card:match('(%d+)%s+Published')
            local completed
            if status then completed = status == "Completed" end
            stories[#stories + 1] = {
                source_id = self.id, title = Util.stripTags(title), url = self.base_url .. href,
                cover_url = Util.absoluteUrl(self.base_url, Util.getAttribute(img, "src")),
                kind = self.kind, chapter_count = tonumber(count), completed = completed,
            }
        end
    end
    local total_pages = page or 1
    -- Only pagination anchors count: genre/letter navigation contains unrelated numbers.
    for attrs in html:gmatch('<a([^>]*)>') do
        if hasClass(attrs, "n_p") or hasClass(attrs, "last_p") or hasClass(attrs, "next_p") then
            local href = Util.getAttribute(attrs, "href") or ""
            local number = tonumber(href:match('[?&]page=(%d+)') or href:match('/(%d+)$'))
            if number then total_pages = math.max(total_pages, number) end
        end
    end
    return { stories = Util.uniqueBy(stories, "url"), genres = self:parseGenres(html),
        page = page or 1, total_pages = total_pages }
end

function Source:fetchListing(path, page, title)
    local html, err = Http:get(self.base_url .. path, self:getCoverHeaders())
    if not html then return nil, err end
    local result = self:parseListing(html, page)
    result.title = title
    return result
end

function Source:search(query)
    local result, err = self:fetchListing("/Find/" .. Util.urlEncode(Util.trim(query):lower()), 1, "Tìm kiếm")
    return result and result.stories or nil, err
end

function Source:getHot(page)
    page = page or 1
    return self:fetchListing("/Genre/All/" .. page, page, "Truyện phổ biến")
end

function Source:getCompleted(page)
    page = page or 1
    if page ~= 1 then return nil, "MangaFreak hiện chỉ trả trang đầu của bộ lọc hoàn thành; hãy dùng tìm kiếm hoặc thể loại" end
    if not self.empty_genres then
        local html, err = Http:get(self.base_url .. "/Find", self:getCoverHeaders())
        if not html then return nil, err end
        html = html:gsub('<!%-%-[%s%S]-%-%->', '')
        local count = 0
        for tag in html:gmatch('<div[^>]*>') do
            if hasClass(tag, "genreoption") then count = count + 1 end
        end
        if count == 0 then return nil, "Không đọc được bộ lọc MangaFreak" end
        self.empty_genres = string.rep("0", count)
    end
    -- The site drops status filters without /Find/<query>; an encoded blank searches all titles.
    local result, err = self:fetchListing("/Find/%20/Genre/" .. self.empty_genres .. "/Status/1/Type/0?page=1",
        1, "Truyện đã hoàn thành (trang đầu nguồn)")
    -- Empty-query status searches currently return page 1 even for ?page=2 on the live site.
    if result then result.total_pages = 1 end
    return result, err
end

function Source:getUpdating(page)
    page = page or 1
    return self:fetchListing("/Latest_Releases/" .. page, page, "Truyện mới cập nhật")
end

function Source:getGenre(genre, page)
    page = page or 1
    local path = (genre.url or ""):match('(/Genre/[^/?]+)')
    if not path then return nil, "Đường dẫn thể loại MangaFreak không hợp lệ" end
    local result, err = self:fetchListing(path .. "/" .. page, page, genre.name)
    if result then result.genre = genre end
    return result, err
end

function Source:getGenresList()
    local html, err = Http:get(self.base_url .. "/Genre", self:getCoverHeaders())
    if not html then return nil, err end
    return self:parseGenres(html)
end

function Source:parseStoryDetails(html)
    local description = html:match('class=["\']manga_series_description["\'][^>]*>([%s%S]-)</div>%s*</div>')
    local status = html:match('This is ([^<]-) series')
    local genres = {}
    for _, genre in ipairs(self:parseGenres(html)) do genres[#genres + 1] = genre.name end
    return {
        description = Util.stripTags(description and description:match('<p[^>]*>([%s%S]-)</p>') or ""),
        author = Util.stripTags(html:match('Written By:%s*([^<]*)') or ""),
        status = status, genres = genres,
    }
end

function Source:getStoryDetails(story)
    local html, err = Http:get(story.url, self:getCoverHeaders())
    if not html then return nil, err end
    return self:parseStoryDetails(html)
end

function Source:parseStoryPage(html, story)
    local chapters = chaptersOf(html, story, self)
    if #chapters == 0 then return nil, "Không tìm thấy mục lục MangaFreak" end
    story.details = self:parseStoryDetails(html)
    return { story = story, chapters = chapters, page = 1, total_pages = 1 }
end

function Source:getStoryPage(story)
    local html, err = Http:get(story.url, self:getCoverHeaders())
    if not html then return nil, err end
    return self:parseStoryPage(html, story)
end

function Source:getAllChapters(story)
    local result, err = self:getStoryPage(story)
    return result and result.chapters or nil, err
end

function Source:fetchSearchMeta(story)
    local result, err = self:getStoryPage(story)
    if not result then return nil, err end
    local latest = 0
    for _, chapter in ipairs(result.chapters) do
        latest = math.max(latest, tonumber(chapter.title:match('Chapter%s+(%d+%.?%d*)')) or 0)
    end
    return { chapter_count = #result.chapters, latest_chapter = latest,
        completed = result.story.details.status == "COMPLETED" }
end

function Source:parseChapter(html, chapter)
    local images, seen = {}, {}
    local slug, number = chapter.url:match('/Read%d+_(.+)_([^_/?#]+)')
    if not slug then return nil, "Đường dẫn chương MangaFreak không hợp lệ" end
    local image_path = "/mangas/" .. slug:lower() .. "/" .. slug:lower() .. "_" .. number:lower() .. "/"
    for tag in html:gmatch('(<img[^>]*>)') do
        local url = Util.absoluteUrl(self.base_url, Util.getAttribute(tag, "data-src") or Util.getAttribute(tag, "src"))
        local page = tonumber((Util.getAttribute(tag, "alt") or ""):match(' Page (%d+)$'))
        if url and page and url:lower():find(image_path, 1, true) and not seen[url] then
            if page ~= #images + 1 then return nil, "Ảnh chương MangaFreak thiếu hoặc sai thứ tự" end
            seen[url] = true
            images[#images + 1] = { urls = { url } }
        end
    end
    local expected = tonumber(html:match('This chapter has (%d+) pages'))
    if #images == 0 or (expected and #images ~= expected) then
        return nil, "Không tìm đủ ảnh của chương MangaFreak"
    end
    return { title = chapter.title, images = images, url = chapter.url,
        referer = self.base_url .. "/", kind = self.kind }
end

function Source:getChapter(chapter)
    local html, err = Http:get(chapter.url, self:getCoverHeaders())
    if not html then return nil, err end
    return self:parseChapter(html, chapter)
end

return Source
