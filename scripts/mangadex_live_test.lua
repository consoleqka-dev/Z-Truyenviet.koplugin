-- Desktop live smoke test for the MangaDex sources. Requires: luajit, curl.
-- Run from the repository root: luajit scripts/mangadex_live_test.lua

local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    root .. "/spec/support/?.lua",
    package.path,
}, ";")

local request_count = 0

local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local Http = {}

function Http:get(url, headers)
    request_count = request_count + 1
    local parts = { "curl --fail --silent --show-error --location --max-time 60" }
    for key, value in pairs(headers or {}) do
        parts[#parts + 1] = "-H " .. shellQuote(key .. ": " .. value)
    end
    parts[#parts + 1] = shellQuote(url)
    local handle = assert(io.popen(table.concat(parts, " ")))
    local content = handle:read("*a")
    local ok = handle:close()
    if not ok or content == "" then return nil, "curl không tải được " .. url end
    -- Giữ dưới giới hạn ~5 request/giây của API.
    os.execute("sleep 0.25")
    return content, nil, {}, 200
end

package.preload["truyenviet/http_client"] = function() return Http end
package.preload["json"] = function() return require("mini_json") end
package.preload["socket.url"] = function() return { absolute = function(_, href) return href end } end
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(value) return value end, stringLower = string.lower }
end

local function check(condition, message)
    if not condition then error(message, 2) end
    print("ok - " .. message)
end

local function headImage(url, headers)
    local parts = { "curl --silent --output /dev/null --max-time 60 --write-out '%{http_code} %{size_download}'" }
    for key, value in pairs(headers or {}) do
        parts[#parts + 1] = "-H " .. shellQuote(key .. ": " .. value)
    end
    parts[#parts + 1] = shellQuote(url)
    local handle = assert(io.popen(table.concat(parts, " ")))
    local output = handle:read("*a")
    handle:close()
    local code, size = output:match("(%d+) (%d+)")
    return tonumber(code), tonumber(size)
end

local Vi = require("truyenviet/sources/mangadex")
local En = require("truyenviet/sources/mangadex_en")

local hot = assert(Vi:getHot(1))
check(#hot.stories == 30 and hot.total_pages > 10, "Hot (vi) trả 30 truyện và nhiều trang")
check(hot.stories[1].cover_url and hot.stories[1].cover_url:match("^https://uploads%.mangadex%.org/covers/"),
    "Hot có ảnh bìa")
local cover_code = headImage(hot.stories[1].cover_url, Vi:getCoverHeaders())
check(cover_code == 200, "Tải được ảnh bìa")

local updating = assert(Vi:getUpdating(2))
check(#updating.stories > 0 and updating.page == 2, "Mới cập nhật trang 2")
local completed = assert(Vi:getCompleted(1))
for _, story in ipairs(completed.stories) do
    assert(story.completed == true, "Truyện trong mục hoàn thành phải completed=true: " .. story.title)
end
check(#completed.stories > 0, "Hoàn thành chỉ có truyện completed")

local genres = assert(Vi:getGenresList())
local action
for _, genre in ipairs(genres) do
    if genre.name == "Action" then action = genre end
end
check(#genres > 50 and action, "Danh sách thể loại có Action")
local by_genre = assert(Vi:getGenre(action, 1))
check(#by_genre.stories > 0, "Duyệt theo thể loại Action")

local results = assert(Vi:search("hunter x hunter"))
local hxh
for _, story in ipairs(results) do
    if story.url == "https://mangadex.org/title/db692d58-4b13-4174-ae8c-30c515c0689c" then hxh = story end
end
check(hxh ~= nil, "Tìm thấy Hunter x Hunter")

local meta = assert(Vi:fetchSearchMeta(hxh))
check(meta.chapter_count and meta.chapter_count > 300 and meta.latest_chapter >= 400,
    "Meta từ aggregate: " .. tostring(meta.chapter_count) .. " chương, mới nhất " .. tostring(meta.latest_chapter))

local page = assert(Vi:getStoryPage(hxh))
check(page.story.details and page.story.details.author:match("Togashi"), "Chi tiết có tác giả Togashi")
check(#page.chapters >= meta.chapter_count - 5, "Mục lục có " .. #page.chapters .. " chương sau khi bỏ trùng")
local seen = {}
for index, chapter in ipairs(page.chapters) do
    assert(not seen[chapter.url], "URL chương bị trùng: " .. chapter.url)
    seen[chapter.url] = true
    if index > 1 and chapter.number and page.chapters[index - 1].number then
        assert(chapter.number > page.chapters[index - 1].number, "Chương không tăng dần ở " .. chapter.title)
    end
end
check(true, "Chương tăng dần, không trùng")

local first = assert(Vi:getChapter(page.chapters[2]))
check(#first.images > 5, "Chương 1 có " .. #first.images .. " ảnh")
local code, size = headImage(first.images[1].urls[1], Vi:getImageHeaders())
check(code == 200 and size > 10000, "Tải được ảnh trang 1 từ MangaDex@Home (" .. tostring(size) .. " byte)")

local external_only = { url = "https://mangadex.org/title/a1c7c817-4e59-43b7-9365-09675a149a6f" }
local none, err = Vi:getAllChapters(external_only)
check(none == nil and err:match("liên kết ngoài"), "One Piece (vi chỉ có MangaPlus) báo lỗi rõ ràng")

-- Nhiều truyện có bản quyền (VD Giant Killing) đã bị gỡ chương English; dùng
-- truyện vừa có chương mới để chắc chắn còn chương đọc được.
local en_updating = assert(En:getUpdating(1))
check(#en_updating.stories > 0 and En.id == "mangadex_en", "Nguồn English có truyện mới cập nhật")
local en_page = assert(En:getStoryPage(en_updating.stories[1]))
check(#en_page.chapters > 0 and en_page.chapters[1].title:match("^Chapter"), "Mục lục English: " .. #en_page.chapters .. " chương")

print(string.format("MangaDex live smoke test passed (%d API requests)", request_count))
