local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    root .. "/spec/support/?.lua",
    package.path,
}, ";")

local responses, requests = {}, {}
local Http = {}

function Http:get(url, headers)
    requests[#requests + 1] = { url = url, headers = headers }
    for pattern, body in pairs(responses) do
        if url:find(pattern, 1, true) then return body end
    end
    return nil, "missing fixture " .. url
end

package.preload["truyenviet/http_client"] = function() return Http end
package.preload["json"] = function() return require("mini_json") end
package.preload["socket.url"] = function() return { absolute = function(_, href) return href end } end
package.preload["util"] = function()
    return { htmlEntitiesToUtf8 = function(value) return value end, stringLower = string.lower }
end

local Source = require("truyenviet/sources/mangadex")
local En = require("truyenviet/sources/mangadex_en")
local tests_run = 0

local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)), 2)
    end
end

assertEqual("mangadex", Source.id, "Vietnamese source id")
assertEqual("mangadex_en", En.id, "English source id")
assertEqual("vi", Source.lang, "Instances keep their own language")

-- Danh sách: tên ưu tiên tiếng Việt, rồi tiếng Anh; null không bị coi là chuỗi.
responses["/manga?"] = [[{"result":"ok","total":95,"data":[
 {"id":"aaaa-1","attributes":{"title":{"ja-ro":"Kimetsu no Yaiba"},
  "altTitles":[{"en":"Demon Slayer"},{"vi":"Thanh Gươm Diệt Quỷ"}],"status":"completed"},
  "relationships":[{"type":"cover_art","id":"c1","attributes":{"fileName":"cover.png"}}]},
 {"id":"bbbb-2","attributes":{"title":{"ja-ro":"Some Title"},"altTitles":[{"en":"English Name"}],"status":"ongoing"},
  "relationships":[{"type":"cover_art","id":"c2","attributes":{"fileName":null}}]},
 {"id":"cccc-3","attributes":{"title":{"ja-ro":"Romaji Only"},"altTitles":[],"status":null},"relationships":[]}
]}]]
local hot = Source:getHot(2)
assertEqual(3, #hot.stories, "Reads every manga")
assertEqual("Thanh Gươm Diệt Quỷ", hot.stories[1].title, "Prefers Vietnamese title")
assertEqual("English Name", hot.stories[2].title, "Falls back to English title")
assertEqual("Romaji Only", hot.stories[3].title, "Falls back to original title")
assertEqual("https://mangadex.org/title/aaaa-1", hot.stories[1].url, "Story URL")
assertEqual("https://uploads.mangadex.org/covers/aaaa-1/cover.png.256.jpg", hot.stories[1].cover_url, "Cover thumbnail")
assertEqual(nil, hot.stories[2].cover_url, "Null cover file name is ignored")
assertEqual(true, hot.stories[1].completed, "Completed status")
assertEqual(false, hot.stories[2].completed, "Ongoing is not completed")
assertEqual(nil, hot.stories[3].completed, "Unknown status stays nil")
assertEqual(4, hot.total_pages, "95 results / 30 per page")
assertEqual("Demon Slayer", En:parseMangaList(require("mini_json").decode(responses["/manga?"]), 1).stories[1].title,
    "English source prefers English title")

local last = requests[#requests]
assertEqual(true, last.url:find("offset=30", 1, true) ~= nil, "Page 2 offset")
assertEqual(true, last.url:find("availableTranslatedLanguage%5B%5D=vi", 1, true) ~= nil, "Brackets are URL-encoded")
assertEqual(true, last.headers["User-Agent"]:match("^TruyenViet%-KOReader/") ~= nil, "Non-browser User-Agent")
assertEqual(nil, Source:getHot(400), "Refuses offsets beyond the 10000 result window")

-- Mục lục: bỏ chương link ngoài/0 trang, mỗi số chương giữ một bản của nhóm
-- dịch nhiều chương nhất, sắp xếp theo số, oneshot xếp cuối.
responses["/feed?"] = [[{"result":"ok","total":7,"data":[
 {"id":"ch-2a","attributes":{"chapter":"2","title":"Hai","pages":20,"externalUrl":null},"relationships":[{"type":"scanlation_group","id":"g-small"}]},
 {"id":"ch-1","attributes":{"chapter":"1","title":"","pages":18,"externalUrl":null},"relationships":[{"type":"scanlation_group","id":"g-main"}]},
 {"id":"ch-2b","attributes":{"chapter":"2","title":"Hai (main)","pages":21,"externalUrl":null},"relationships":[{"type":"scanlation_group","id":"g-main"}]},
 {"id":"ch-10","attributes":{"chapter":"10","title":null,"pages":15,"externalUrl":null},"relationships":[{"type":"scanlation_group","id":"g-main"}]},
 {"id":"ch-2.5","attributes":{"chapter":"2.5","title":"Extra","pages":5,"externalUrl":null},"relationships":[]},
 {"id":"ch-ext","attributes":{"chapter":"3","title":"Ngoài","pages":0,"externalUrl":"https://mangaplus.shueisha.co.jp/x"},"relationships":[]},
 {"id":"oneshot-1234567","attributes":{"chapter":null,"title":"Ngoại truyện","pages":12,"externalUrl":null},"relationships":[]}
]}]]
local chapters = Source:getAllChapters({ url = "https://mangadex.org/title/aaaa-1" })
assertEqual(5, #chapters, "Drops duplicates and external chapters")
assertEqual("Chương 1", chapters[1].title, "Empty chapter title is omitted")
assertEqual("Chương 2: Hai (main)", chapters[2].title, "Duplicate keeps the most complete group")
assertEqual("https://mangadex.org/chapter/ch-2b/chapter-2", chapters[2].url, "Readable chapter URL")
assertEqual("Chương 2.5: Extra", chapters[3].title, "Decimal chapters sort numerically")
assertEqual("https://mangadex.org/chapter/ch-2.5/chapter-2-5", chapters[3].url, "Decimal slug")
assertEqual("Chương 10", chapters[4].title, "10 sorts after 2.5")
assertEqual("Oneshot: Ngoại truyện", chapters[5].title, "Chapters without a number go last")
assertEqual(10, chapters[4].number, "Numeric chapter number")
assertEqual("https://mangadex.org/title/aaaa-1", chapters[1].story_url, "Chapter story URL")

responses["/feed?"] = [[{"result":"ok","total":1,"data":[
 {"id":"ext","attributes":{"chapter":"1","title":null,"pages":1,"externalUrl":"https://mangaplus.shueisha.co.jp/"},"relationships":[]}]}]]
local none, err = Source:getAllChapters({ url = "https://mangadex.org/title/aaaa-1" })
assertEqual(nil, none, "External-only manga has no readable chapters")
assertEqual(true, err:find("liên kết ngoài", 1, true) ~= nil, "Explains external-only manga")

-- Ảnh chương: node MangaDex@Home, rồi máy chủ gốc, rồi bản nén.
responses["/at-home/server/ch-2b"] = [[{"result":"ok","baseUrl":"https://node.mangadex.network",
 "chapter":{"hash":"h1","data":["1-a.png","2-b.png"],"dataSaver":["1-a.jpg","2-b.jpg"]}}]]
local content = Source:getChapter(chapters[2])
assertEqual(2, #content.images, "Two pages")
assertEqual("https://node.mangadex.network/data/h1/1-a.png", content.images[1].urls[1], "Node original first")
assertEqual("https://uploads.mangadex.org/data/h1/1-a.png", content.images[1].urls[2], "Uploads fallback")
assertEqual("https://node.mangadex.network/data-saver/h1/1-a.jpg", content.images[1].urls[3], "Data saver fallback")
assertEqual("https://mangadex.org/", Source:getImageHeaders()["Referer"], "Node images need Referer")

responses["/at-home/server/bad"] = [[{"result":"error","errors":[{"title":"Not Found","detail":"Chapter not found"}]}]]
local missing, missing_err = Source:getChapter({ url = "https://mangadex.org/chapter/bad/chapter-1" })
assertEqual(nil, missing, "API errors return nil")
assertEqual("MangaDex: Chapter not found", missing_err, "API error detail is shown")

-- Meta tìm kiếm từ /aggregate.
responses["/aggregate?"] = [[{"result":"ok","volumes":{
 "none":{"volume":"none","chapters":{"12":{"chapter":"12"},"11.5":{"chapter":"11.5"}}},
 "1":{"volume":"1","chapters":{"1":{"chapter":"1"},"2":{"chapter":"2"}}}}}]]
local meta = Source:fetchSearchMeta({ url = "https://mangadex.org/title/aaaa-1", completed = false })
assertEqual(4, meta.chapter_count, "Counts aggregate chapters")
assertEqual(12, meta.latest_chapter, "Latest chapter number")
assertEqual(false, meta.completed, "Keeps listing status")
responses["/aggregate?"] = [[{"result":"ok","volumes":[]}]]
assertEqual(nil, Source:fetchSearchMeta({ url = "https://mangadex.org/title/aaaa-1" }).chapter_count,
    "Empty aggregate has no count")

-- Thể loại: bỏ nhóm content, sắp xếp theo tên; chi tiết truyện.
responses["/manga/tag"] = [[{"result":"ok","data":[
 {"id":"t-romance","attributes":{"name":{"en":"Romance"},"group":"genre"}},
 {"id":"t-gore","attributes":{"name":{"en":"Gore"},"group":"content"}},
 {"id":"t-action","attributes":{"name":{"en":"Action"},"group":"genre"}}]}]]
local genres = Source:getGenresList()
assertEqual(2, #genres, "Skips content tags")
assertEqual("Action", genres[1].name, "Sorted tags")
assertEqual("https://mangadex.org/tag/t-action", genres[1].url, "Tag URL")
Source:getGenre(genres[1], 1)
assertEqual(true, requests[#requests].url:find("includedTags%5B%5D=t-action", 1, true) ~= nil, "Filters by tag")

responses["/manga/aaaa-1?"] = [[{"result":"ok","data":{"id":"aaaa-1","attributes":{
 "description":{"en":"English text","vi":"**Mô tả** có [liên kết](https://example.com)."},
 "status":"hiatus","tags":[{"attributes":{"name":{"en":"Action"}}}]},
 "relationships":[{"type":"author","attributes":{"name":"Gotouge Koyoharu"}},
  {"type":"artist","attributes":{"name":"Gotouge Koyoharu"}},
  {"type":"cover_art","attributes":{"fileName":"cover.png"}}]}}]]
local details = Source:getStoryDetails({ url = "https://mangadex.org/title/aaaa-1" })
assertEqual("Mô tả có liên kết.", details.description, "Markdown is flattened")
assertEqual("Gotouge Koyoharu", details.author, "Author and artist are merged")
assertEqual("Tạm ngưng", details.status, "Vietnamese status name")
assertEqual("Action", details.genres[1], "Tag names")

print(string.format("mangadex_test.lua: %d assertions passed", tests_run))
