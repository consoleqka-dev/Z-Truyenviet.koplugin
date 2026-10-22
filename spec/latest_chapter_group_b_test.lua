local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Stub Http: trả fixture theo URL, ghi lại số request để kiểm tra "đúng 1 request".
local requested_urls = {}
local response_by_url = {}
local Http = {}

function Http:get(url)
    requested_urls[#requested_urls + 1] = url
    return response_by_url[url], response_by_url[url] and nil or "missing fixture", nil,
        response_by_url[url] and 200 or nil
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
            return value
                :gsub("&amp;", "&")
                :gsub("&quot;", '"')
                :gsub("&#39;", "'")
                :gsub("&#8211;", "-")
        end,
        urlEncode = function(value)
            return value:gsub(" ", "%%20")
        end,
    }
end

package.preload["json"] = function()
    return { decode = function() error("không dùng JSON trong spec này") end }
end

local AzTruyen = require("truyenviet/sources/aztruyen")
local MeTruyenChu = require("truyenviet/sources/metruyenchuvn")
local Haccbl = require("truyenviet/sources/haccbl")
local Mizzya = require("truyenviet/sources/mizzya")

local assertions = 0

local function assertEqual(expected, actual, message)
    assertions = assertions + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function fetchMeta(source, url, body)
    for index = #requested_urls, 1, -1 do
        table.remove(requested_urls, index)
    end
    response_by_url[url] = body
    local meta, err = source:fetchSearchMeta({ url = url, title = "Demo" })
    assertEqual(1, #requested_urls, source.id .. " fetchSearchMeta dùng đúng 1 request")
    return meta, err
end

-- ===== AzTruyen =====
local function azPage(latest_titles, list_titles)
    local function items(titles)
        local out = {}
        for i, title in ipairs(titles) do
            out[#out + 1] = string.format(
                '<li class="listc"> <a href="https://aztruyen.top/demo-1/c-%d/" title="%s">%s</a></li>',
                i, title, title)
        end
        return table.concat(out)
    end
    local latest = latest_titles and (
        '<div class="box_stories" id="chapters"><div class="title"><svg width="1"></svg> Chương mới nhất</div>'
        .. '        <ul class="chapters">            ' .. items(latest_titles) .. '        </ul>    </div>'
    ) or ""
    return latest .. '<div class="box_stories" id="chapters"><div class="title"><svg></svg> Danh sách chương</div>'
        .. '        <ul class="chapters">            ' .. items(list_titles or {}) .. '        </ul></div>'
end

local az_url = "https://aztruyen.top/demo-1/"
local meta = fetchMeta(AzTruyen, az_url, azPage(
    { "Chương 75", "Chương 76: Ngoại truyện 1 (sinh nhật trong kỳ nghỉ hè)", "Chương 79: Ngoại truyện 4 (An Nguyệt)" },
    { "Chương 1", "Chương 2" }))
assertEqual(79, meta.latest_chapter, "aztruyen lấy số sau 'Chương'")

meta = fetchMeta(AzTruyen, az_url, azPage(
    { "Làm nhân vật phản diện cũng phải nổi tiếng khắp tu chân giới - Chương 108",
      "(PN) Làm nhân vật phản diện cũng phải nổi tiếng khắp tu chân giới - Chương 109",
      "Làm nhân vật phản diện cũng phải nổi tiếng khắp tu chân giới - Chương 112" }))
assertEqual(112, meta.latest_chapter, "aztruyen lấy 'Chương N' ở cuối tên dài")

meta = fetchMeta(AzTruyen, az_url, azPage({ "cực phẩm nữ tiên 172", "cực phẩm nữ tiên 176", "cực phẩm nữ tiên 175" }))
assertEqual(176, meta.latest_chapter, "aztruyen chọn số lớn nhất, không phải phần tử đầu/cuối")

meta = fetchMeta(AzTruyen, az_url, azPage({ "170 (Ngoại Truyện) ", "171 (Ngoại Truyện) ", "174 (Ngoại Truyện)" }))
assertEqual(174, meta.latest_chapter, "aztruyen tên chỉ có số")

meta = fetchMeta(AzTruyen, az_url, azPage({ "651-700", "751-801", "851-881 (end)" }))
assertEqual(881, meta.latest_chapter, "aztruyen khoảng a-b lấy b")

meta = fetchMeta(AzTruyen, az_url, azPage({ "Tiên Nghịch 1951-2000", "Tiên Nghịch 2001-end" }))
assertEqual(2001, meta.latest_chapter, "aztruyen khoảng a-end lấy a (chặn dưới đã biết)")

meta = fetchMeta(AzTruyen, az_url, azPage({ "Chương 12.5", "Chương 12" }))
assertEqual(12.5, meta.latest_chapter, "aztruyen giữ phần thập phân")

meta = fetchMeta(AzTruyen, az_url, azPage(nil, { "Lời giới thiệu", "Chương 1", "Chương 2", "Chương 3" }))
assertEqual(3, meta.latest_chapter, "aztruyen không có khối mới nhất thì lấy max cả danh sách")

local az_err
meta, az_err = fetchMeta(AzTruyen, az_url, azPage({ "Lời giới thiệu" }))
assertEqual(nil, meta, "aztruyen không có số chương trả nil")
assertEqual(true, az_err ~= nil, "aztruyen trả lỗi khi không có số chương")

-- ===== MeTruyenChu VN =====
local function mtPage(links)
    local out = {}
    for _, l in ipairs(links) do
        out[#out + 1] = string.format("<a href='%s'>%s</a>", l[1], l[2])
    end
    return '<div class="new-chap">\n  <h2>Chương mới nhất được cập nhật</h2>\n  ' .. table.concat(out)
        .. '\n</div><div class="other">Chương 9999</div>'
end

local mt_url = "https://metruyenchu.com.vn/demo"
meta = fetchMeta(MeTruyenChu, mt_url, mtPage({
    { "/demo/chuong-235-aaa", "Chương 235" },
    { "/demo/chuong-234-bbb", "Chương 234" },
}))
assertEqual(235, meta.latest_chapter, "metruyenchuvn lấy chương đầu khối new-chap")

meta = fetchMeta(MeTruyenChu, mt_url, mtPage({
    { "/demo/chuong-1563-a", "Chương 1563" },
    { "/demo/chuong-1562-b", "Chương 1562" },
    { "/demo/chuong-1569-c", "Chương 1569" },
}))
assertEqual(1569, meta.latest_chapter, "metruyenchuvn chọn số lớn nhất khi khối không sắp xếp")

meta = fetchMeta(MeTruyenChu, mt_url, mtPage({
    { "/demo/chuong-tiep-a", "\239\187\191Chương 297" },
    { "/demo/chuong-tiep-b", "\239\187\191Chương 296" },
}))
assertEqual(297, meta.latest_chapter, "metruyenchuvn chịu được BOM trước 'Chương'")

meta = fetchMeta(MeTruyenChu, mt_url, mtPage({
    { "/demo/chuong-tiep-a", "Chương tiếp" },
    { "/demo/chuong-12-b", "Chương 12.5" },
}))
assertEqual(12.5, meta.latest_chapter, "metruyenchuvn bỏ chương không số, giữ số thập phân")

local mt_err
meta, mt_err = fetchMeta(MeTruyenChu, mt_url, "<html><body>không có khối</body></html>")
assertEqual(nil, meta, "metruyenchuvn thiếu khối new-chap trả nil")
assertEqual(true, mt_err ~= nil, "metruyenchuvn trả lỗi khi thiếu khối new-chap")

-- ===== Haccbl =====
local hac_url = "https://haccbl.xyz/manga/demo/"
local hac_json_ld = '"additionalProperty":[{"@type":"PropertyValue","name":"chapterCount","value":"88"},'
    .. '{"@type":"PropertyValue","name":"status","value":"completed"}],"hasPart":['
    .. '{"@type":["Chapter","ComicIssue"],"name":"Chương 83.3: Extra 3","issueNumber":83.3,"url":"x"},'
    .. '{"@type":["Chapter","ComicIssue"],"name":"Chương 83.2: Extra 2","issueNumber":83.2,"url":"y"},'
    .. '{"@type":["Chapter","ComicIssue"],"name":"Chương 83.1: Extra 1","issueNumber":83.1,"url":"z"}]'
meta = fetchMeta(Haccbl, hac_url, hac_json_ld)
assertEqual(83.3, meta.latest_chapter, "haccbl lấy issueNumber lớn nhất (thập phân)")
assertEqual(88, meta.chapter_count, "haccbl giữ chapter_count")
assertEqual(true, meta.completed, "haccbl giữ completed")

meta = fetchMeta(Haccbl, hac_url,
    '"name":"status","value":"ongoing"}],"hasPart":[{"name":"Chương 75","issueNumber":75},{"name":"Chương 77","issueNumber":77},'
    .. '{"name":"Chương 76","issueNumber":76}]')
assertEqual(77, meta.latest_chapter, "haccbl chọn số lớn nhất, không phải phần tử cuối")
assertEqual(false, meta.completed, "haccbl ongoing -> completed=false")
assertEqual(nil, meta.chapter_count, "haccbl thiếu chapterCount thì không bịa")

meta = fetchMeta(Haccbl, hac_url, [[
<div class="chapter-item">
    <a class="uk-link-toggle"
       href="https://haccbl.xyz/manga/demo/chapter-83-3/">x</a>
</div>
<div class="chapter-item">
    <a class="uk-link-toggle"
       href="https://haccbl.xyz/manga/demo/chapter-83/">x</a>
</div>
<div class="other"><a href="https://haccbl.xyz/manga/other/chapter-500/">khác</a></div>
]])
assertEqual(83.3, meta.latest_chapter, "haccbl dự phòng từ href chapter-item")

local hac_err
meta, hac_err = fetchMeta(Haccbl, hac_url, "<html></html>")
assertEqual(nil, meta, "haccbl không có dữ liệu trả nil")
assertEqual(true, hac_err ~= nil, "haccbl trả lỗi khi không có dữ liệu")

-- ===== Mizzya =====
local function mizzyaPage(titles)
    local out = {}
    for i, title in ipairs(titles) do
        out[#out + 1] = string.format('<p><a href="https://mizzya.wordpress.com/2011/10/05/c%d/">%s</a></p>', i, title)
    end
    return '<h1 class="entry-title">Demo - Tác giả</h1><div class="entry-content">' .. table.concat(out)
        .. '</div><div id="jp-post-flair"></div>'
end

local miz_url = "https://mizzya.wordpress.com/2011/10/05/demo/"
meta = fetchMeta(Mizzya, miz_url, mizzyaPage({
    "Lời giới thiệu", "Chương 1: Các cô chú tí hon", "Chương 28: Vũ hội", "Chương 29: Trở về", "Đoạn kết",
}))
assertEqual(29, meta.latest_chapter, "mizzya lấy 'Chương' lớn nhất, bỏ mục không số")
assertEqual(5, meta.chapter_count, "mizzya giữ chapter_count là số link chương")

meta = fetchMeta(Mizzya, miz_url, mizzyaPage({ "Chương 30", "Chương 2", "Chương 12.5" }))
assertEqual(30, meta.latest_chapter, "mizzya chọn số lớn nhất khi danh sách không tăng dần")

meta = fetchMeta(Mizzya, miz_url, mizzyaPage({ "Phần thứ nhất", "Hồi thứ hai", "Phần 3: Tiêu đề" }))
assertEqual(nil, meta.latest_chapter, "mizzya không đoán chương từ 'Phần'/'Hồi'")
assertEqual(3, meta.chapter_count, "mizzya vẫn đếm số chương")

print(string.format("Group B latest chapter tests passed: %d assertions", assertions))
