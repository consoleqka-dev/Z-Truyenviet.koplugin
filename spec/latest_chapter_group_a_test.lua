-- Kiểm tra lấy "chương mới nhất" (story.latest_chapter) cho truyenqq, docln,
-- blhvip, giatocvuongtai. Các đoạn HTML/JSON mẫu rút gọn từ phản hồi thật của site.
local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local response_by_url = {}
local requested = {}
local Http = {}

function Http:get(url, headers, options)
    requested[#requested + 1] = { url = url, headers = headers or {}, options = options }
    return response_by_url[url], response_by_url[url] and nil or "missing fixture"
end

package.preload["truyenviet/http_client"] = function()
    return Http
end

package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
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

-- JSON giả: chuỗi "JSON:<khóa>" tra bảng json_fixtures.
local json_fixtures = {}
local function decodeFixture(raw)
    if type(raw) ~= "string" or raw:sub(1, 5) ~= "JSON:" then
        error("invalid JSON fixture")
    end
    return json_fixtures[raw:sub(6)]
end

package.preload["util"] = function()
    return {
        htmlEntitiesToUtf8 = function(value)
            return value
                :gsub("&amp;", "&")
                :gsub("&quot;", '"')
                :gsub("&#039;", "'")
                :gsub("&#39;", "'")
                :gsub("&#234;", "ê")
        end,
        urlEncode = function(value)
            return value:gsub(" ", "%%20")
        end,
        jsonDecode = decodeFixture,
    }
end

package.preload["json"] = function()
    return { decode = decodeFixture }
end

local TruyenQQ = require("truyenviet/sources/truyenqq")
local DocLN = require("truyenviet/sources/docln")
local Blhvip = require("truyenviet/sources/blhvip")
local Giatoc = require("truyenviet/sources/giatocvuongtai")

local assertions = 0

local function assertEqual(expected, actual, message)
    assertions = assertions + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function reset()
    response_by_url = {}
    requested = {}
    json_fixtures = {}
end

-- ===== truyenqq =====

local qq_detail = [[
<head>
  <meta name="description" content="Truyenqq.com.vn vừa cập nhật bộ truyện tranh mới Hell Login của t&#225;c giả Mộng Ti&#234;n Giới, h&#227;y c&#249;ng trải nghiệm đọc chương 16 tại TruyenQQ" />
</head>
<span class="label-status label-updating">Đang ra</span>
<div id="chapter-list" class="chapter-list">
  <div class="inner"><div class="reading-list">
    <div class="item"><div class="item-name">
      <a href="/dang-nhap-dia-nguc/chapter-16" class="chapter-name d-block">Chapter 16</a>
    </div><div class="item-time">1 giờ trước</div></div>
    <div class="item"><div class="item-name">
      <a href="/dang-nhap-dia-nguc/chapter-15" class="chapter-name d-block">Chapter 15</a>
    </div><div class="item-time">1 tuần trước</div></div>
    <div class="item"><div class="item-name">
      <a href="/dang-nhap-dia-nguc/chapter-1" class="chapter-name d-block">Chapter 1</a>
    </div><div class="item-time">2 tháng trước</div></div>
  </div></div>
</div>
]]

assertEqual(16, TruyenQQ:parseLatestChapter(qq_detail), "truyenqq lấy chương lớn nhất (danh sách mới -> cũ)")

local qq_oldest_first = [[
<div id="chapter-list" class="chapter-list">
  <a href="/x/chapter-1" class="chapter-name d-block">Chapter 1</a>
  <a href="/x/chapter-extra" class="chapter-name d-block">Chapter Extra</a>
  <a href="/x/chapter-12-5" class="chapter-name d-block">Chapter 12.5</a>
  <a href="/x/chapter-12" class="chapter-name d-block">Chapter 12</a>
</div>
]]
assertEqual(12.5, TruyenQQ:parseLatestChapter(qq_oldest_first), "truyenqq giữ phần thập phân, bỏ chương không số")

local qq_meta_only = [[
<meta name="description" content="Truyenqq.com.vn cập nhật, hãy cùng trải nghiệm đọc chương 110 tại TruyenQQ" />
]]
assertEqual(110, TruyenQQ:parseLatestChapter(qq_meta_only), "truyenqq dự phòng bằng mô tả meta")
assertEqual(nil, TruyenQQ:parseLatestChapter("<html></html>"), "truyenqq không có dữ liệu trả nil")

reset()
response_by_url["https://truyenqq.com.vn/dang-nhap-dia-nguc"] = qq_detail
local meta = TruyenQQ:fetchSearchMeta({ url = "https://truyenqq.com.vn/dang-nhap-dia-nguc" })
assertEqual(16, meta.latest_chapter, "truyenqq fetchSearchMeta latest_chapter")
assertEqual(false, meta.completed, "truyenqq fetchSearchMeta vẫn trả completed")
assertEqual(1, #requested, "truyenqq chỉ 1 request")

-- ===== docln =====

local docln_cards = [[
<div class="thumb-item-flow col-4 col-md-3 col-lg-2">
    <div class="thumb-wrapper ln-tooltip" data-tooltip-content="#series_27906">
        <a href="/truyen/27906-tien-tu-xin-nghe-ta-giai-thich/c1-chuong-95-nhi-pham-yeu-quy" title="Chương 95: Nhị phẩm yêu quỷ">
            <div class="a6-ratio"><div class="content img-in-ratio lazyload" data-bg="https://i2.hako.vip/a.webp"></div></div>
        </a>
        <div class="thumb-detail">
            <div class="thumb_attr chapter-title" title="Chương 95: Nhị phẩm yêu quỷ"><a href="/truyen/27906-tien-tu-xin-nghe-ta-giai-thich/c1-chuong-95-nhi-pham-yeu-quy" title="Chương 95: Nhị phẩm yêu quỷ">Chương 95: Nhị phẩm yêu quỷ</a></div>
            <div class="thumb_attr volume-title">[1-100]</div>
        </div>
    </div>
    <div class="thumb_attr series-title"><a href="/truyen/27906-tien-tu-xin-nghe-ta-giai-thich" title="Tiên Tử, Xin Nghe Ta Giải Thích">Tiên Tử, Xin Nghe Ta Giải Thích</a></div>
</div>
<div class="thumb-item-flow col-4 col-md-3 col-lg-2">
    <div class="thumb-wrapper ln-tooltip" data-tooltip-content="#series_24430">
        <a href="/truyen/24430-tieng-vong-thien-duong/c2-chuong-22" title="Chương 2.2: Nhà Sản Xuất Phía Sau Trường Học">
            <div class="a6-ratio"><div class="content img-in-ratio lazyload" data-bg="https://i2.hako.vip/b.webp"></div></div>
        </a>
        <div class="thumb-detail">
            <div class="thumb_attr chapter-title" title="Chương 2.2: Nhà Sản Xuất Phía Sau Trường Học"><a href="/truyen/24430-tieng-vong-thien-duong/c2-chuong-22" title="x">Chương 2.2: Nhà Sản Xuất Phía Sau Trường Học</a></div>
            <div class="thumb_attr volume-title">Tập 06</div>
        </div>
    </div>
    <div class="thumb_attr series-title"><a href="/truyen/24430-tieng-vong-thien-duong" title="Tiếng Vọng Thiên Đường">Tiếng Vọng Thiên Đường</a></div>
</div>
<div class="thumb-item-flow col-4 col-md-3 col-lg-2 type-convert ">
    <div class="thumb-wrapper ln-tooltip" data-tooltip-content="#series_27958">
        <div class="thumb-detail">
            <div class="thumb_attr chapter-title" title="x"><a href="/truyen/27958-a/c3" title="x">CHƯƠNG 9: Ô trưởng lão chết rồi</a></div>
        </div>
    </div>
    <div class="thumb_attr series-title"><a href="/truyen/27958-a" title="Tiên Tử Bất Nhân">Tiên Tử Bất Nhân</a></div>
</div>
<div class="thumb-item-flow col-4 col-md-3 col-lg-2">
    <div class="thumb-wrapper ln-tooltip" data-tooltip-content="#series_22921">
        <div class="thumb-detail">
            <div class="thumb_attr chapter-title" title="Lời bạt"><a href="/truyen/22921-b/c4" title="Lời bạt">Lời bạt</a></div>
        </div>
    </div>
    <div class="thumb_attr series-title"><a href="/truyen/22921-b" title="Tiếng Ồn Nơi Thiên Đường">Tiếng Ồn Nơi Thiên Đường</a></div>
</div>
<div class="thumb-item-flow col-4 col-md-3 col-lg-2">
    <div class="thumb-wrapper ln-tooltip" data-tooltip-content="#series_1">
        <div class="thumb-detail">
            <div class="thumb_attr chapter-title" title="x"><a href="/truyen/1-c/c5" title="x">Chap 1: Phép thuật màu xương</a></div>
        </div>
    </div>
    <div class="thumb_attr series-title"><a href="/truyen/1-c" title="Tiếng Vọng">Tiếng Vọng</a></div>
</div>
]]

local docln_stories = DocLN:parseSearch(docln_cards)
assertEqual(5, #docln_stories, "docln số thẻ truyện")
assertEqual(95, docln_stories[1].latest_chapter, "docln thẻ: Chương 95")
assertEqual(2.2, docln_stories[2].latest_chapter, "docln thẻ: Chương 2.2 giữ thập phân")
assertEqual(9, docln_stories[3].latest_chapter, "docln thẻ: CHƯƠNG 9 viết hoa")
assertEqual(nil, docln_stories[4].latest_chapter, "docln thẻ: Lời bạt không có số")
assertEqual(1, docln_stories[5].latest_chapter, "docln thẻ: Chap 1")

local docln_detail = [[
<div>Tình trạng: <a href="/x">Đang tiến hành</a></div>
<ul class="list-chapters at-series">
 <li><div class="chapter-name"><a href="/truyen/24430-t/c10-minh-hoa">Minh hoạ</a></div></li>
 <li><div class="chapter-name"><a href="/truyen/24430-t/c11-chuong-11-a">Chương 1.1: A</a></div></li>
 <li><div class="chapter-name"><a href="/truyen/24430-t/c12-chuong-10-b">Chương 10: B</a></div></li>
 <li><div class="chapter-name"><a href="/truyen/24430-t/c13-loi-bat">Lời Bạt</a></div></li>
 <li><div class="chapter-name"><a href="/truyen/24430-t/c14-chuong-21-c">Chương 2.1: C</a></div></li>
 <li><div class="chapter-name"><a href="/truyen/24430-t/c15-minh-hoa">Minh họa</a></div></li>
</ul>
]]

reset()
response_by_url["https://docln.sbs/truyen/24430-t"] = docln_detail
local docln_meta = DocLN:fetchSearchMeta({ url = "https://docln.sbs/truyen/24430-t" })
assertEqual(2.1, docln_meta.latest_chapter, "docln trang chi tiết: chương có số cuối cùng, bỏ Minh họa/Lời bạt")
assertEqual(6, docln_meta.chapter_count, "docln vẫn trả chapter_count (đếm mọi mục trong danh sách)")
assertEqual(false, docln_meta.completed, "docln vẫn trả completed")
assertEqual(1, #requested, "docln chỉ 1 request")

reset()
response_by_url["https://docln.sbs/truyen/24430-t"] = docln_detail
local from_card = DocLN:fetchSearchMeta({ url = "https://docln.sbs/truyen/24430-t", latest_chapter = 2.2 })
assertEqual(2.2, from_card.latest_chapter, "docln giữ chương mới nhất đã đọc từ thẻ tìm kiếm")

-- ===== blhvip =====

reset()
json_fixtures.blhvip_new = {
    success = true,
    total_page = 18,
    data = {
        { ord = "885", name = "Chương 885: Thuần Dương Chân Tiên", is_vip = true, url = "/truyen/chan-tien/chuong-885" },
        { ord = "884", name = "Chương 884: Thuần Dương Chân Tiên", is_vip = true, url = "/truyen/chan-tien/chuong-884" },
        { ord = "883", name = "Chương 883: Bên ngoài vũ trụ", is_vip = true, url = "/truyen/chan-tien/chuong-883" },
    },
}
assertEqual(885, Blhvip:parseLatestChapter(json_fixtures.blhvip_new), "blhvip lấy chương lớn nhất")
assertEqual(1300, Blhvip:parseLatestChapter({ data = {
    { ord = "1299", name = "Chương 1299. Sát Linh hiển uy" },
    { ord = "1300", name = "Chương 1300. Sát Linh hiển uy" },
} }), "blhvip tên dạng 'Chương N.' và thứ tự bất kỳ")
assertEqual(12.5, Blhvip:parseLatestChapter({ data = {
    { ord = "13", name = "Chương 12.5: Ngoại" },
    { ord = "12", name = "Chương 12: Chính" },
    { ord = "14", name = "Phiên ngoại" },
} }), "blhvip giữ thập phân, bỏ phiên ngoại không số")
assertEqual(14, Blhvip:parseLatestChapter({ data = {
    { ord = "13", name = "Mở đầu" },
    { ord = "14", name = "Phiên ngoại" },
} }), "blhvip dự phòng bằng ord khi không tên nào có số")
assertEqual(nil, Blhvip:parseLatestChapter({ data = {} }), "blhvip danh sách rỗng trả nil")
assertEqual(nil, Blhvip:parseLatestChapter(nil), "blhvip không có JSON trả nil")

response_by_url["https://api.blhvip.vn/v1/story/chan-tien/chapter_list?page=1&new=1"] = "JSON:blhvip_new"
local bl_meta = Blhvip:fetchSearchMeta({ url = "https://blhvip.vn/truyen/chan-tien" })
assertEqual(885, bl_meta and bl_meta.latest_chapter, "blhvip fetchSearchMeta latest_chapter")
assertEqual(1, #requested, "blhvip chỉ 1 request")
local bl_err = select(2, Blhvip:fetchSearchMeta({ url = "https://blhvip.vn/truyen/khong-co" }))
assertEqual("missing fixture", bl_err, "blhvip lỗi mạng được trả về")

-- ===== giatocvuongtai =====

local gt_item = {
    completion_status = "ongoing",
    chapter_count = 85,
    chapters = {
        { id = "a", title = "Giới thiệu", order_number = 0, is_published = true },
        { id = "b", title = "Cực phẩm lô đỉnh vạn năm khó gặp", order_number = 1, is_published = true },
        { id = "d", title = "Vảy ngược của rồng, chạm vào là chết", order_number = 83, is_published = true },
        { id = "e", title = "Đồ đệ có mè nheo thì mới được sư phụ hôn", order_number = 84, is_published = true },
        { id = "f", title = "Chưa xuất bản", order_number = 90, is_published = false },
    },
}
assertEqual(84, Giatoc:parseLatestChapter(gt_item), "gtvt lấy order_number lớn nhất đã xuất bản, bỏ Giới thiệu")
assertEqual(3, Giatoc:parseLatestChapter({ chapters = {
    { order_number = 3, is_published = true },
    { order_number = 2, is_published = true },
    { order_number = 1, is_published = true },
} }), "gtvt thứ tự mới -> cũ")
assertEqual(nil, Giatoc:parseLatestChapter({ chapters = {
    { order_number = 0, is_published = true },
} }), "gtvt chỉ có Giới thiệu trả nil")
assertEqual(nil, Giatoc:parseLatestChapter({}), "gtvt không có chapters trả nil")

reset()
json_fixtures.gt_story = { data = gt_item }
local gt_slug = "dam-my-dit-y-ha-n-o-n-i-e-nh-a-ong-ga-o-hie-n"
response_by_url["https://giatocvuongtai.com/api/public/story/" .. gt_slug .. ".json"] = "JSON:gt_story"
local gt_meta = Giatoc:fetchSearchMeta({ url = "https://giatocvuongtai.com/story/" .. gt_slug })
assertEqual(84, gt_meta and gt_meta.latest_chapter, "gtvt fetchSearchMeta latest_chapter")
assertEqual(false, gt_meta and gt_meta.completed, "gtvt fetchSearchMeta completed")
assertEqual(1, #requested, "gtvt chỉ 1 request")
assertEqual("cors", requested[1].headers["Sec-Fetch-Mode"], "gtvt gửi header Sec-Fetch để qua Cloudflare")
local gt_err = select(2, Giatoc:fetchSearchMeta({ url = "https://giatocvuongtai.com/story/khong-co" }))
assertEqual("missing fixture", gt_err, "gtvt lỗi mạng được trả về")

print(string.format("latest chapter group A: %d assertions passed", assertions))
