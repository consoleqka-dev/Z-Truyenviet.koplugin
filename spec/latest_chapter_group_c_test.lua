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
    local response = responses[url]
    if not response then
        return nil, "missing fixture", {}, nil
    end
    return response.body, nil, response.headers or {}, response.code or 200
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
            return value:gsub("&amp;", "&")
        end,
        urlEncode = function(value)
            return value:gsub(" ", "+")
        end,
        stringLower = function(value)
            return value:lower()
        end,
    }
end

package.preload["json"] = function()
    return {
        decode = function(raw)
            local posts = {}
            for link, title in raw:gmatch(
                '{"link":"([^"]+)","title":{"rendered":"([^"]*)"}}'
            ) do
                posts[#posts + 1] = { link = link, title = { rendered = title } }
            end
            return posts
        end,
    }
end

local assertions = 0
local function assertEqual(expected, actual, message)
    assertions = assertions + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

-- conduongbachu: chương mới nhất = số lớn nhất trong 10 bài mới nhất.
local Cdbc = require("truyenviet/sources/conduongbachu")
local cdbc_url = "https://conduongbachu.com/wp-json/wp/v2/posts?categories=12&per_page=10&_fields=link,title&order=desc&orderby=date"
responses[cdbc_url] = {
    -- Bài "Bầu chọn" không phải chương; số chương lớn nhất nằm ở bài đầu hoặc giữa đều phải đúng.
    body = '[{"link":"https://conduongbachu.com/bau-chon-ngoai-truyen/","title":{"rendered":"Bầu chọn ngoại truyện"}},'
        .. '{"link":"https://conduongbachu.com/chuong-15-toc/","title":{"rendered":"CHƯƠNG 15: TỘC"}},'
        .. '{"link":"https://conduongbachu.com/chuong-14-tham/","title":{"rendered":"CHƯƠNG 14: THẢM"}}]',
    headers = { ["x-wp-total"] = "16" },
}
local cdbc_story = Cdbc:search("ngoại truyện")[2]
assertEqual("https://conduongbachu.com/ngoai-truyen/", cdbc_story.url, "conduongbachu picks the Bất Hủ Thần Chiến story")
local cdbc_meta = assert(Cdbc:fetchSearchMeta(cdbc_story))
assertEqual(15, cdbc_meta.latest_chapter, "conduongbachu latest chapter ignores non-chapter posts")
assertEqual(16, cdbc_meta.chapter_count, "conduongbachu keeps total post count")
assertEqual(true, cdbc_meta.completed, "conduongbachu keeps completed flag")
assertEqual(1, #requested_urls, "conduongbachu meta uses exactly one request")
assert(Cdbc:fetchSearchMeta(cdbc_story))
assertEqual(1, #requested_urls, "conduongbachu meta is cached per story")

-- dualeotruyenfull: JSON-LD hasPart có issueNumber, lấy số lớn nhất.
local Dualeo = require("truyenviet/sources/dualeotruyenfull")
local dualeo_story = {
    url = "https://dualeotruyenfull.net/doc-truyen/demo/",
}
responses[dualeo_story.url] = {
    body = '<title>Đọc Truyện Demo [Chương 67] – Dưa Leo</title>'
        .. '{"@type":"PropertyValue","name":"chapterCount","value":"67"},'
        .. '{"@type":"PropertyValue","name":"status","value":"ongoing"}],'
        .. '"hasPart":[{"@type":["Chapter"],"name":"Chương 66: B","issueNumber":66,"url":"x"},'
        .. '{"@type":["Chapter"],"name":"Chương 67: A","issueNumber":67,"url":"y"},'
        .. '{"@type":["Chapter"],"name":"Chương 12.5: C","issueNumber":12.5,"url":"z"}]',
}
local dualeo_meta = assert(Dualeo:fetchSearchMeta(dualeo_story))
assertEqual(67, dualeo_meta.latest_chapter, "dualeotruyenfull latest chapter is the max issueNumber")
assertEqual(67, dualeo_meta.chapter_count, "dualeotruyenfull keeps chapterCount")
assertEqual(false, dualeo_meta.completed, "dualeotruyenfull keeps ongoing status")

local fallback_story = { url = "https://dualeotruyenfull.net/doc-truyen/fallback/" }
responses[fallback_story.url] = {
    body = '<title>Đọc Truyện Demo [Chương 43] – Dưa Leo</title>',
}
local fallback_meta = assert(Dualeo:fetchSearchMeta(fallback_story))
assertEqual(43, fallback_meta.latest_chapter, "dualeotruyenfull falls back to the [Chương N] page title")

local empty_story = { url = "https://dualeotruyenfull.net/doc-truyen/empty/" }
responses[empty_story.url] = { body = "<html></html>" }
local empty_meta, empty_err = Dualeo:fetchSearchMeta(empty_story)
assertEqual(nil, empty_meta, "dualeotruyenfull reports no meta for an unrecognised page")
assertEqual(true, empty_err ~= nil, "dualeotruyenfull returns an error for an unrecognised page")

-- generic_source: search.latest_chapter_pattern.
local GenericSource = require("truyenviet/generic_source")
local function makeSource(pattern)
    return GenericSource.create({
        id = "demo",
        base_url = "https://demo.example",
        search = {
            item_marker = '<a class="card" ',
            url_pattern = 'href="([^"]+)"',
            title_pattern = "<h3>([^<]*)</h3>",
            latest_chapter_pattern = pattern,
        },
    })
end
local function card(chapter_html)
    return '<a class="card" href="/truyen/a"><h3>A</h3>' .. chapter_html .. "</a>"
end

local source = makeSource("Chương%s+([%d%.,]+)")
assertEqual(170, source:parseSearch(card("<i>Chương 170</i>"))[1].latest_chapter, "generic integer chapter")
assertEqual(12.5, source:parseSearch(card("<i>Chương 12.5</i>"))[1].latest_chapter, "generic decimal chapter is kept")
assertEqual(1234, source:parseSearch(card("<i>Chương 1.234</i>"))[1].latest_chapter, "generic dot thousand separator is stripped")
assertEqual(1234, source:parseSearch(card("<i>Chương 1,234</i>"))[1].latest_chapter, "generic comma thousand separator is stripped")
assertEqual(nil, source:parseSearch(card("<i>Hoàn thành</i>"))[1].latest_chapter, "generic no match gives nil")
assertEqual(nil, source:parseSearch(card("<i>Chương 0</i>"))[1].latest_chapter, "generic zero chapter gives nil")
assertEqual(nil, makeSource("[unclosed"):parseSearch(card("<i>Chương 9</i>"))[1].latest_chapter, "generic bad pattern gives nil")
assertEqual(nil, makeSource(nil):parseSearch(card("<i>Chương 9</i>"))[1].latest_chapter, "generic without pattern gives nil")

print("Latest chapter group C tests passed: " .. assertions .. " assertions")
