local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["socket.url"] = function()
    return { absolute = function(base, href) return base:match("^(https?://[^/]+)") .. href end }
end
package.preload["util"] = function()
    return {
        stringLower = string.lower,
        htmlEntitiesToUtf8 = function(value) return value end,
    }
end
package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
end
package.preload["truyenviet/storage"] = function()
    return { getCoverCacheDir = function() return "/cache/covers" end }
end
package.preload["ffi/util"] = function()
    return { joinPath = function(left, right) return left .. "/" .. right end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function() return nil end }
end

local pages = {}
local http_calls = {}
package.preload["truyenviet/http_client"] = function()
    return {
        get = function(_, url, headers)
            table.insert(http_calls, { url = url, headers = headers })
            return pages[url]
        end,
    }
end

-- Ảnh hợp lệ: URL có trong valid_images; còn lại coi như lỗi 404/không phải ảnh.
local valid_images = {}
local downloads = {}
package.preload["truyenviet/cover_cache"] = function()
    return {
        get = function() return nil end,
        download = function(_, story, source)
            table.insert(downloads, { url = story.cover_url, source = source.id })
            if valid_images[story.cover_url] then
                return "/cache/covers/" .. #downloads .. ".jpg"
            end
            return nil, "not an image"
        end,
    }
end

local CoverFinder = require("truyenviet/cover_finder")
local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local search_calls = 0
local weebcentral = {
    id = "weebcentral",
    base_url = "https://weebcentral.com",
    search = function(_, query)
        search_calls = search_calls + 1
        if query == "Fool Night" then
            return {
                { title = "Fool Night Extra", url = "https://weebcentral.com/series/AAA/fool-night-extra" },
                { title = "Fool Night", url = "https://weebcentral.com/series/01J76XYFN/Fool-Night",
                    cover_url = "https://temp.compsci88.com/cover/normal/01J76XYFN.webp" },
            }
        end
        return {}
    end,
}
local truyenqq = {
    id = "truyenqq",
    base_url = "https://truyenqq.com.vn",
    getCoverHeaders = function() return { Referer = "https://truyenqq.com.vn/" } end,
}
local registry = {
    get = function(_, id)
        if id == "weebcentral" then return weebcentral end
        if id == "truyenqq" then return truyenqq end
    end,
}

-- Nhận diện tên tiếng Việt
assertEqual(true, CoverFinder.hasVietnamese("Ta Là Tà Đế"), "Vietnamese title")
assertEqual(false, CoverFinder.hasVietnamese("I Am A Hero"), "English title")
assertEqual("01J76XYFN", CoverFinder.seriesId("https://weebcentral.com/series/01J76XYFN/Fool-Night"), "Series ID")

-- 1. WeebCentral trùng tên chính xác -> bìa JPEG 400x600
local fool_night = {
    source_id = "truyenqq", kind = "comic", title = "Fool Night",
    url = "https://truyenqq.com.vn/truyen-tranh/fool-night-12615",
    cover_url = "https://hinhhinh.com/80x105/fool-night.jpg",
}
valid_images["https://temp.compsci88.com/cover/fallback/01J76XYFN.jpg"] = true
local found = CoverFinder:find(fool_night, registry)
assertEqual("https://temp.compsci88.com/cover/fallback/01J76XYFN.jpg", found and found.cover_url, "WeebCentral cover")
assertEqual("weebcentral", found.cover_source_id, "Cover source is WeebCentral")
assertEqual("weebcentral", downloads[1].source, "Downloaded with WeebCentral headers")
assertEqual(0, #http_calls, "No page fetch when WeebCentral matched")

-- 2. Không trùng tên -> og:image của trang truyện
downloads = {}
local giant = {
    source_id = "truyenqq", kind = "comic", title = "Giant Killing",
    url = "https://truyenqq.com.vn/truyen-tranh/giant-killing-1",
    cover_url = "https://hinhhinh.com/80x105/giant.jpg",
}
pages[giant.url] = '<html><meta property="og:image" content="/media/book/giant-killing.jpg"></html>'
valid_images["https://truyenqq.com.vn/media/book/giant-killing.jpg"] = true
found = CoverFinder:find(giant, registry)
assertEqual("https://truyenqq.com.vn/media/book/giant-killing.jpg", found and found.cover_url, "og:image cover")
assertEqual("truyenqq", found.cover_source_id, "og:image keeps story source")
assertEqual("https://truyenqq.com.vn/", http_calls[1].headers.Referer, "Page fetched with source headers")

-- 3. Truyện chữ tiếng Việt: không tìm WeebCentral, bìa cũ còn sống thì giữ
downloads = {}
local before = search_calls
local novel = {
    source_id = "truyenqq", kind = "novel", title = "Đấu Phá Thương Khung",
    url = "https://truyenqq.com.vn/truyen/dau-pha", cover_url = "https://img/old.jpg",
}
valid_images["https://img/old.jpg"] = true
found = CoverFinder:find(novel, registry)
assertEqual(before, search_calls, "Novel skips WeebCentral search")
assertEqual("https://img/old.jpg", found and found.cover_url, "Existing cover kept when alive")

-- 4. Không gì dùng được -> nil (bìa chết không được nhận)
local dead = {
    source_id = "truyenqq", kind = "comic", title = "Ta Là Tà Đế",
    url = "https://truyenqq.com.vn/truyen-tranh/ta-la-ta-de", cover_url = "https://hinhhinh.com/80x105/x.jpg",
}
assertEqual(nil, CoverFinder:find(dead, registry), "Dead cover is not accepted")

-- Truyện WeebCentral dùng chính ID của nó, không tìm kiếm
before = search_calls
valid_images["https://temp.compsci88.com/cover/fallback/XYZ.jpg"] = true
found = CoverFinder:find({ source_id = "weebcentral", kind = "comic", title = "X",
    url = "https://weebcentral.com/series/XYZ/x" }, registry)
assertEqual("https://temp.compsci88.com/cover/fallback/XYZ.jpg", found and found.cover_url, "Own series ID")
assertEqual(before, search_calls, "No search for WeebCentral stories")

-- Mục trên máy dùng tên hiển thị để tìm
found = CoverFinder:find({ source_id = "local", kind = "local", title = "Fool Night - Seinen",
    url = "/sdcard/Books/Fool Night" }, registry, { query = "Fool Night" })
assertEqual("https://temp.compsci88.com/cover/fallback/01J76XYFN.jpg", found and found.cover_url, "Local entry query")

print(string.format("Cover finder tests passed: %d assertions", tests_run))
