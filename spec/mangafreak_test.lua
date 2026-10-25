local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local responses = {}
local requested_urls = {}
local Http = {}

function Http:get(url)
    requested_urls[#requested_urls + 1] = url
    local body = responses[url]
    if not body then
        return nil, "missing fixture"
    end
    return body
end

package.preload["truyenviet/http_client"] = function()
    return Http
end

package.preload["socket.url"] = function()
    return {
        absolute = function(base, href)
            if href:match("^https?://") then
                return href
            end
            return base:gsub("/+$", "") .. "/" .. href:gsub("^/+", "")
        end,
    }
end

package.preload["util"] = function()
    return {
        htmlEntitiesToUtf8 = function(value)
            return (value:gsub("&amp;", "&"))
        end,
        urlEncode = function(value)
            return (value:gsub(" ", "%%20"))
        end,
        stringLower = function(value)
            return value:lower()
        end,
    }
end

local Source = require("truyenviet/sources/mangafreak")
local tests_run = 0

local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local base = "https://ww3.mangafreak.me"

-- Danh sách: thẻ truyện, thể loại và số trang chỉ lấy từ nút phân trang.
local listing = [[
<a href="/Genre/All">All</a><a href="/Genre/Sports">Sports</a>
<div class="ranking_item">
  <a href="/Manga/Giant_Killing"><img src="https://images.mangafreak.me/manga_images/giant_killing.jpg"></a>
  <h3>Giant Killing</h3> (Ongoing) 612 Chapters
</div>
<div class="ranking_item">
  <a href="/Manga/One_Piece_Databook"><img src="/manga_images/one_piece_databook.jpg"></a>
  <strong>One Piece Databook</strong> (Completed)
</div>
<a class="letter" href="/Genre/All/99">Z</a>
<a class="n_p" href="/Genre/All/2">2</a><a class="last_p" href="/Genre/All/37">Last</a>
]]
responses[base .. "/Genre/All/1"] = listing
local hot = Source:getHot(1)
assertEqual(2, #hot.stories, "Reads both story cards")
assertEqual("Giant Killing", hot.stories[1].title, "Title from h3")
assertEqual(base .. "/Manga/Giant_Killing", hot.stories[1].url, "Absolute story URL")
assertEqual(612, hot.stories[1].chapter_count, "Chapter count")
assertEqual(false, hot.stories[1].completed, "Ongoing status")
assertEqual("One Piece Databook", hot.stories[2].title, "Title from strong")
assertEqual(true, hot.stories[2].completed, "Completed status")
assertEqual(base .. "/manga_images/one_piece_databook.jpg", hot.stories[2].cover_url, "Relative cover made absolute")
assertEqual(37, hot.total_pages, "Pages come from pagination anchors only")
assertEqual(1, #hot.genres, "Genre list skips All")
assertEqual("Sports", hot.genres[1].name, "Genre name")

-- Trang truyện: chương theo thứ tự cũ trước, bỏ link lặp ở thanh bên.
local story_page = [[
<div class="manga_series_description"><p>Football &amp; giant killers.</p></div></div>
Written By: Tsujitomo<br>This is ONGOING series
<a class="chapter-link" href="/Read1_Giant_Killing_1">Chapter 1</a>
<a class="chapter-link" href="/Read1_Giant_Killing_2">Chapter 2</a>
<a class="chapter-link" href="/Read1_Giant_Killing_2">Chapter 2</a>
<a class="other" href="/Read1_Giant_Killing_3">Chapter 3</a>
]]
local story = { url = base .. "/Manga/Giant_Killing", title = "Giant Killing" }
responses[story.url] = story_page
local page = Source:getStoryPage(story)
assertEqual(2, #page.chapters, "Unique chapter-link anchors only")
assertEqual("Chapter 1", page.chapters[1].title, "Oldest chapter first")
assertEqual(base .. "/Read1_Giant_Killing_2", page.chapters[2].url, "Absolute chapter URL")
assertEqual("ONGOING", page.story.details.status, "Series status")
assertEqual("Football & giant killers.", page.story.details.description, "Description")
local meta = Source:fetchSearchMeta(story)
assertEqual(2, meta.latest_chapter, "Latest chapter number")
assertEqual(false, meta.completed, "Ongoing series is not completed")

responses[base .. "/Manga/Empty"] = "<html></html>"
local missing, missing_err = Source:getStoryPage({ url = base .. "/Manga/Empty" })
assertEqual(nil, missing, "Story without chapters fails")
assertEqual("Không tìm thấy mục lục MangaFreak", missing_err, "Missing chapter list message")

-- Chương: ảnh đúng thư mục chương, đủ số trang, đúng thứ tự.
local chapter = { title = "Chapter 2", url = base .. "/Read1_Giant_Killing_2" }
local image_dir = "https://images.mangafreak.me/mangas/giant_killing/giant_killing_2/"
responses[chapter.url] = table.concat({
    "This chapter has 2 pages",
    '<img src="https://images.mangafreak.me/logo.png" alt="Logo">',
    '<img data-src="' .. image_dir .. 'giant_killing_2_1.jpg" alt="Giant Killing 2 Page 1">',
    '<img src="' .. image_dir .. 'giant_killing_2_2.jpg" alt="Giant Killing 2 Page 2">',
})
local payload = Source:getChapter(chapter)
assertEqual(2, #payload.images, "Keeps only this chapter's pages")
assertEqual(image_dir .. "giant_killing_2_1.jpg", payload.images[1].urls[1], "data-src wins")
assertEqual(base .. "/", payload.referer, "Image referer")

responses[chapter.url] = "This chapter has 3 pages"
    .. '<img src="' .. image_dir .. 'giant_killing_2_1.jpg" alt="Giant Killing 2 Page 1">'
local short, short_err = Source:getChapter(chapter)
assertEqual(nil, short, "Missing pages fail the chapter")
assertEqual("Không tìm đủ ảnh của chương MangaFreak", short_err, "Missing pages message")

responses[chapter.url] = '<img src="' .. image_dir .. 'giant_killing_2_2.jpg" alt="Giant Killing 2 Page 2">'
local _, order_err = Source:getChapter(chapter)
assertEqual("Ảnh chương MangaFreak thiếu hoặc sai thứ tự", order_err, "Out-of-order pages fail")

-- Tìm kiếm: chữ thường, khoảng trắng mã hóa.
responses[base .. "/Find/giant%20killing"] = listing
local found = Source:search("  Giant Killing ")
assertEqual(2, #found, "Search returns listing stories")

print(string.format("MangaFreak tests passed: %d assertions", tests_run))
