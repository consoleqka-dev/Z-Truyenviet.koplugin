local Http = require("truyenviet/http_client")
local Util = require("truyenviet/helpers")
local Debug = require("truyenviet/debugger")

local Source = {
    id = "cbunu",
    name = "Cbunu",
    kind = "comic",
    -- Site đã chuyển cbunu.com -> cucbongunu.com (301)
    base_url = "https://cucbongunu.com",
    reversed_chapters = true,
}

-- URL truyện/chương đã lưu có thể còn domain cũ: đổi về domain hiện tại để khỏi tốn 1 lần redirect
local function normalizeUrl(url)
    if type(url) ~= "string" then
        return url
    end
    return (url:gsub("^https?://[Ww][Ww][Ww]%.cbunu%.com", Source.base_url)
        :gsub("^https?://cbunu%.com", Source.base_url))
end

-- Cookie phiên lấy động từ trang chủ, không hardcode giá trị tĩnh
local session_cookie = nil
local session_cookie_time = 0
local COOKIE_TTL = 30 * 60 -- 30 phút thì refresh lại

local function extractSetCookie(headers)
    if not headers then
        return nil
    end
    local raw = headers["set-cookie"] or headers["Set-Cookie"]
    if not raw then
        return nil
    end

    local found = {}
    if type(raw) == "table" then
        for _, entry in ipairs(raw) do
            local pair = entry:match("^([^;]+)")
            if pair then
                table.insert(found, pair)
            end
        end
    else
        for entry in tostring(raw):gmatch("([^,]+)") do
            local pair = entry:match("^%s*([^;]+)")
            if pair and pair:find("=") then
                table.insert(found, pair)
            end
        end
    end

    if #found == 0 then
        return nil
    end
    return table.concat(found, "; ")
end

local site_blocked = false
local BLOCKED_MESSAGE = "Cbunu yêu cầu đăng nhập hoặc đang bảo trì, nguồn tạm thời không khả dụng."

local function refreshSessionCookie()
    local html, err, headers, status_code = Http:get(Source.base_url .. "/", {
        ["Referer"] = Source.base_url .. "/",
    })
    if not html then
        if status_code == 403 then
            Debug.write("cbunu: 403 Forbidden, attempting to login...")
            local passwords = { "2026", "12345" }
            for _, pass in ipairs(passwords) do
                local _, _, auth_headers, auth_status = Http:postForm(
                    Source.base_url .. "/",
                    { access_pass = pass },
                    { ["Referer"] = Source.base_url .. "/" },
                    { redirect = false }
                )
                if auth_status == 302 or auth_status == 200 then
                    headers = auth_headers
                    status_code = auth_status
                    break
                end
            end

            if status_code == 403 then
                site_blocked = true
                Debug.write("cbunu: login failed with all passwords, nguồn không khả dụng")
                return nil
            end
        else
            Debug.write("cbunu: không lấy được trang chủ để refresh cookie: " .. tostring(err))
            return nil
        end
    end
    site_blocked = false
    local cookie = extractSetCookie(headers)
    if cookie then
        session_cookie = cookie
        session_cookie_time = os.time()
        Debug.write("cbunu: đã lấy cookie session mới")
    else
        Debug.write("cbunu: không thấy Set-Cookie trong phản hồi trang chủ")
    end
    return session_cookie
end

local function ensureSessionCookie()
    if not session_cookie or (os.time() - session_cookie_time) > COOKIE_TTL then
        refreshSessionCookie()
    end
    return session_cookie
end

local function requestHeaders()
    local headers = {
        ["Referer"] = Source.base_url .. "/",
        ["X-Requested-With"] = "XMLHttpRequest",
    }
    local cookie = ensureSessionCookie()
    if cookie then
        headers["Cookie"] = cookie
    end
    return headers
end

function Source:getCoverHeaders()
    return requestHeaders()
end

local function isStoryUrl(href)
    return href
        and href:find("/truyen-tranh/", 1, true)
        and not href:find("%-chap%-")
        and not href:find("%.html")
end

local function parseStoryCards(html)
    local stories = {}
    for anchor_attrs, anchor_html in tostring(html or ""):gmatch(
        "<a([^>]*)>([%s%S]-)</a>"
    ) do
        local href = Util.getAttribute(anchor_attrs, "href")
        if isStoryUrl(href) then
            local title = Util.getAttribute(anchor_attrs, "title")
                or Util.getAttribute(anchor_html:match("(<img[^>]*>)"), "alt")
                or Util.stripTags(anchor_html)
            title = Util.stripTags(title):gsub("%.%.%.$", "")
            local image_tag = anchor_html:match("(<img[^>]*>)")
            local original_cover_url = Util.absoluteUrl(
                Source.base_url,
                Util.getAttribute(image_tag, "data-original")
                    or Util.getAttribute(image_tag, "data-src")
                    or Util.getAttribute(image_tag, "src")
                    or Util.getAttribute(image_tag, "data-fb")
            )
            local cover_url = original_cover_url
            if cover_url then
                cover_url = cover_url:gsub("^https?://", "https://i0.wp.com/") .. "?resize=200,266"
            end
            
            table.insert(stories, {
                source_id = Source.id,
                title = title,
                url = Util.absoluteUrl(Source.base_url, href),
                cover_url = cover_url,
                kind = Source.kind,
            })
        end
    end
    return Util.uniqueBy(stories, "url")
end

-- Thẻ truyện kiểu mới: badge "Đã hoàn" + 2 chương mới nhất (pill).
-- Số chương chỉ xấp xỉ (= số chương mới nhất, bỏ phần lẻ); chỉ biết chắc "hoàn thành"
-- khi có badge, các badge khác không nói lên truyện đang ra hay không -> completed = nil.
local function parseCardMeta(card_html)
    local meta = {}
    local badge = card_html:match('cb%-story%-badge">([^<]+)<')
    if badge and badge:find("Đã hoàn", 1, true) then
        meta.completed = true
    end
    local pills = card_html:match('<div class="cb%-chapter%-pills">([%s%S]-)</div>')
    local latest = 0
    for number in tostring(pills or ""):gmatch("Chương%s+(%d+%.?%d*)") do
        local value = tonumber(number)
        if value and value > latest then
            latest = value
        end
    end
    if latest >= 1 then
        meta.latest_chapter = latest
    end
    return meta
end

local function parseCards(html)
    local stories = {}
    for card_html in tostring(html or ""):gmatch('<article class="cb%-story%-card">([%s%S]-)</article>') do
        local story = parseStoryCards(card_html)[1]
        if story then
            local meta = parseCardMeta(card_html)
            story.latest_chapter = meta.latest_chapter
            story.completed = meta.completed
            table.insert(stories, story)
        end
    end
    stories = Util.uniqueBy(stories, "url")
    if #stories > 0 then
        return stories
    end
    return parseStoryCards(html)
end

function Source:parseSearch(html)
    local stories = parseCards(html)
    if #stories > 0 then
        return stories
    end

    for item_html in tostring(html or ""):gmatch("<li[^>]*>([%s%S]-)</li>") do
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

local function urlEncode(str)
    if str then
        str = str:gsub("\n", "\r\n")
        str = str:gsub("([^%w %-%_%.%~])", function(c)
            return string.format("%%%02X", string.byte(c))
        end)
        str = str:gsub(" ", "+")
    end
    return str
end

function Source:search(query)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    local encoded_query = urlEncode(query)
    local html, err = Http:get(
        self.base_url .. "/tim-kiem.html?q=" .. encoded_query,
        requestHeaders()
    )
    if not html then
        return nil, err
    end
    return self:parseSearch(html)
end

function Source:parseListing(html, page)
    return {
        stories = parseCards(html),
        genres = Util.parseGenres(html, self.base_url),
        page = page or 1,
        total_pages = Util.maxPage(html, page),
    }
end

function Source:getCompleted(page)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    page = page or 1
    local url = self.base_url .. "/da-hoan"
    if page > 1 then
        url = url .. "?completed_page=" .. page
    end
    local html, err = Http:get(url, requestHeaders())
    if not html then
        return nil, err
    end
    local result = self:parseListing(html, page)
    result.title = "Truyện đã hoàn thành"
    return result
end

function Source:getGenre(genre, page)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    page = page or 1
    local url = genre.url:gsub("/+$", "")
    if page > 1 then
        url = url:gsub("%.html$", "") .. "/trang-" .. page .. ".html"
    end
    local html, err = Http:get(url, requestHeaders())
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
    -- Giao diện mới: <p>Tình trạng: Đang tiến hành</p> (không còn <li class="status">)
    local new_status = html:match("Tình trạng:%s*([^<]+)</p>")
    if new_status then
        status = Util.trim(new_status)
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
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    local html, err = Http:get(normalizeUrl(story.url), requestHeaders())
    if not html then
        return nil, err
    end
    return self:parseStoryDetails(html)
end

-- Số chương chính xác + trạng thái từ trang truyện (1 request, danh sách chương nằm trọn trong trang).
-- Không gọi requestHeaders() để khỏi tốn request lấy cookie; chỉ dùng cookie đã có.
function Source:fetchSearchMeta(story)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    local headers = { ["Referer"] = self.base_url .. "/" }
    if session_cookie then
        headers["Cookie"] = session_cookie
    end
    local html, err = Http:get(normalizeUrl(story.url), headers)
    if not html then
        return nil, err
    end

    local meta = {}
    local count = 0
    for _ in html:gmatch('data%-chapter%-order="') do
        count = count + 1
    end
    if count > 0 then
        meta.chapter_count = count
    end
    local status = html:match("Tình trạng:%s*([^<]+)</p>")
    if status then
        meta.completed = status:find("Đã hoàn", 1, true) ~= nil
    end
    if meta.chapter_count == nil and meta.completed == nil then
        return nil, "Không đọc được số chương"
    end
    return meta
end

function Source:parseStoryPage(html, story)
    local chapters = {}
    local slug = story.url:match("([^/]+)$") or ""
    local base_slug = slug:match("^(.-)%-%d+$")
        or slug:match("^(.-)%-%d+%.html$")
        or slug:match("^(.-)%.html$")
        or slug

    for anchor_attrs, anchor_html in tostring(html or ""):gmatch("<a([^>]*)>([%s%S]-)</a>") do
        local href = Util.getAttribute(anchor_attrs, "href")
        local chapter_url = Util.absoluteUrl(self.base_url, href)
        if chapter_url and chapter_url:find(base_slug, 1, true) then
            local lurl = (chapter_url or ""):lower()
            local is_chapter = false
            if lurl:find("%-chap%-")
                    or lurl:find("chapter", 1, true)
                    or lurl:find("chuong", 1, true) then
                is_chapter = true
            end
            local anchor_text = Util.stripTags(anchor_html) or ""
            local at_lower = anchor_text:lower()
            if not is_chapter then
                if at_lower:find("chương%s*%d")
                        or at_lower:find("chapter%s*%d")
                        or at_lower:find("^%d+%s*$") then
                    is_chapter = true
                end
            end
            if is_chapter then
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

    story.details = self:parseStoryDetails(html)

    return {
        story = story,
        chapters = Util.uniqueBy(chapters, "url"),
        page = 1,
        total_pages = 1,
    }
end

function Source:getStoryPage(story)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    local html, err = Http:get(normalizeUrl(story.url), requestHeaders())
    if not html then
        return nil, err
    end
    return self:parseStoryPage(html, story)
end

function Source:parseChapter(html, chapter)
    local images = {}
    
    local content_html = html:match('<div[^>]-class="[^"]*story%-see%-content[^"]*"[^>]*>([%s%S]-)</div>')
    if not content_html then
        content_html = html
    end

    for image_tag in content_html:gmatch("(<img[^>]*>)") do
        local primary = Util.getAttribute(image_tag, "data-original")
            or Util.getAttribute(image_tag, "src")
        local class_name = Util.getAttribute(image_tag, "class") or ""
        
        if primary and (class_name:find("lazy") or primary:find("/chap/")) then
            local clean_urls = {}
            local seen = {}
            local candidates = {
                primary,
                Util.getAttribute(image_tag, "data-cdn"),
                Util.getAttribute(image_tag, "data-fb"),
            }
            for index = 1, 3 do
                local url = Util.absoluteUrl(self.base_url, candidates[index])
                if url and not seen[url] then
                    seen[url] = true
                    table.insert(clean_urls, url)
                end
            end
            if #clean_urls > 0 then
                table.insert(images, { urls = clean_urls })
            end
        end
    end

    if #images == 0 then
        return nil, "Không tìm thấy ảnh của chương"
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
        referer = self.base_url .. "/",
        kind = self.kind,
    }
end

local function parseCookies(raw, cookies_table)
    cookies_table = cookies_table or {}
    if not raw then return cookies_table end
    local list = {}
    if type(raw) == "table" then
        for _, v in ipairs(raw) do
            table.insert(list, v)
        end
    else
        for entry in tostring(raw):gmatch("([^,]+)") do
            table.insert(list, entry)
        end
    end

    for _, entry in ipairs(list) do
        local name, value = entry:match("^%s*([^;=]+)=([^;]*)")
        if name then
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            value = value:gsub("^%s+", ""):gsub("%s+$", "")
            local name_lower = name:lower()
            if name_lower ~= "expires" and name_lower ~= "max-age" and name_lower ~= "path" 
               and name_lower ~= "domain" and name_lower ~= "secure" and name_lower ~= "httponly" 
               and name_lower ~= "samesite" then
                cookies_table[name] = value
            end
        end
    end
    return cookies_table
end

local function buildCookieHeader(cookies_table)
    local found = {}
    for k, v in pairs(cookies_table or {}) do
        table.insert(found, k .. "=" .. v)
    end
    return table.concat(found, "; ")
end

local function unlockChapter(url, fallback_headers, init_cookies)
    local passwords = { "12345", "2026" }
    Debug.write("[cbunu] unlockChapter started for URL: " .. url)
    for _, password in ipairs(passwords) do
        local body = "access_pass=" .. password
        local post_headers = {
            ["Content-Type"] = "application/x-www-form-urlencoded",
            ["Referer"] = Source.base_url .. "/",
            ["Origin"] = Source.base_url,
        }
        for k, v in pairs(fallback_headers) do
            post_headers[k] = v
        end
        local cookie_str = buildCookieHeader(init_cookies)
        if cookie_str ~= "" then 
            post_headers["Cookie"] = cookie_str 
        end

        Debug.write("[cbunu] unlockChapter trying password: " .. password)
        local html, err, headers, code, resp_body = Http:request("POST", url, body, post_headers, { redirect = false })
        Debug.write(string.format("[cbunu] unlockChapter POST finished. code=%s, err=%s", tostring(code), tostring(err)))
        
        if (code == 302 or code == 200) and headers then
            local set_cookie = headers["set-cookie"] or headers["Set-Cookie"]
            if set_cookie then
                parseCookies(set_cookie, init_cookies)
                Debug.write("[cbunu] unlockChapter parsed new cookies from POST response")
            end
            
            local get_headers = {
                ["Referer"] = Source.base_url .. "/",
            }
            for k, v in pairs(fallback_headers) do 
                get_headers[k] = v 
            end
            cookie_str = buildCookieHeader(init_cookies)
            if cookie_str ~= "" then 
                get_headers["Cookie"] = cookie_str 
            end
            
            Debug.write("[cbunu] unlockChapter making GET request to retrieve unlocked content")
            local get_html, get_err, get_hdrs, get_code = Http:get(url, get_headers)
            Debug.write(string.format("[cbunu] unlockChapter GET finished. code=%s, body_len=%d", tostring(get_code), get_html and #get_html or 0))
            
            if get_code == 200 and get_html then
                if not get_html:find("<title>Đăng nhập</title>", 1, true) then
                    Debug.write("[cbunu] unlockChapter SUCCESS: Unlocked content obtained successfully")
                    return get_html
                else
                    Debug.write("[cbunu] unlockChapter FAILED: Page still displays login title")
                end
            end
        end
    end
    return nil, "Không thể mở khóa chương với mật khẩu mặc định"
end

function Source:getChapter(chapter)
    if site_blocked then
        return nil, BLOCKED_MESSAGE
    end
    local chapter_url = normalizeUrl(chapter.url)
    Debug.write("[cbunu] getChapter started for: " .. chapter_url)
    local html, err, headers, code, body = Http:get(chapter_url, requestHeaders())
    Debug.write(string.format("[cbunu] getChapter initial request returned code=%s, err=%s", tostring(code), tostring(err)))
    
    if code == 403 or (body and body:find("<title>Đăng nhập</title>", 1, true)) then
        Debug.write("[cbunu] getChapter detected 403 or login title. Attempting to unlock...")
        local cookies = {}
        local cookie_header = requestHeaders()["Cookie"]
        if cookie_header then
            parseCookies(cookie_header, cookies)
        end
        if headers and (headers["set-cookie"] or headers["Set-Cookie"]) then
            parseCookies(headers["set-cookie"] or headers["Set-Cookie"], cookies)
        end
        html, err = unlockChapter(chapter_url, requestHeaders(), cookies)
    end
    
    if not html then
        Debug.write("[cbunu] getChapter failed: " .. tostring(err))
        return nil, err or "Không thể tải nội dung chương"
    end
    return self:parseChapter(html, chapter)
end

return Source
