local CoverCache = require("truyenviet/cover_cache")
local Debug = require("truyenviet/debugger")
local Http = require("truyenviet/http_client")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

-- Tìm bìa lớn nhất cho mục Tủ truyện:
-- 1. WeebCentral 400x600 (truyện tranh, tên trùng hoàn toàn sau chuẩn hóa)
-- 2. og:image của trang truyện
-- 3. cover_url đang lưu
-- 4. trang bìa trong file (truyện trên máy)
-- Mỗi ứng viên được tải và kiểm tra là ảnh thật trước khi nhận.
local CoverFinder = {
    weebcentral_id = "weebcentral",
    -- Bản JPEG luôn có; bản thường là webp, KOReader đọc JPEG ổn định hơn.
    weebcentral_cover = "https://temp.compsci88.com/cover/fallback/%s.jpg",
    max_local_width = 600,
}

-- Tên có chữ tiếng Việt có dấu thì không có trên WeebCentral.
function CoverFinder.hasVietnamese(title)
    local text = tostring(title or "")
    return Util.normalizeSearch(text) ~= Util.normalizeSearch(text:gsub("[\128-\255]+", " "))
end

function CoverFinder.seriesId(url)
    return tostring(url or ""):match("/series/(%w+)")
end

-- Ảnh bìa WeebCentral cho truyện; nil nếu không có kết quả trùng tên.
function CoverFinder:weebcentralCover(story, registry, query)
    if story.source_id == self.weebcentral_id then
        local id = self.seriesId(story.url)
        return id and string.format(self.weebcentral_cover, id) or nil
    end
    if story.kind ~= "comic" and story.kind ~= "local" then
        return nil
    end
    query = query or story.title
    if type(query) ~= "string" or query == "" or self.hasVietnamese(query) then
        return nil
    end
    local source = registry:get(self.weebcentral_id)
    if not source or type(source.search) ~= "function" then
        return nil
    end
    local ok, results = pcall(source.search, source, query)
    if not ok or type(results) ~= "table" then
        Debug.write("[CoverFinder] Lỗi tìm WeebCentral '" .. query .. "': " .. tostring(results))
        return nil
    end
    local wanted = Util.normalizeSearch(query)
    for _, item in ipairs(results) do
        if type(item) == "table" and Util.normalizeSearch(item.title) == wanted then
            local id = self.seriesId(item.url)
            return id and string.format(self.weebcentral_cover, id) or item.cover_url
        end
    end
    return nil
end

function CoverFinder.parsePageCover(html, page_url)
    local image = Util.getMetaContent(html, "property", "og:image")
    if type(image) ~= "string" or image == "" then
        return nil
    end
    return Util.absoluteUrl(page_url, image)
end

function CoverFinder:pageCover(story, source)
    if type(story.url) ~= "string" or not story.url:match("^https?://") then
        return nil
    end
    local headers = source.getCoverHeaders and source:getCoverHeaders(story)
        or { ["Referer"] = tostring(source.base_url) .. "/" }
    local ok, html = pcall(Http.get, Http, story.url, headers)
    if not ok or type(html) ~= "string" then
        return nil
    end
    return self.parsePageCover(html, story.url)
end

-- Tải ứng viên vào cache; trả về đường dẫn khi đúng là ảnh.
local function tryCover(story, url, source)
    if type(url) ~= "string" or url == "" or url:match("^file://") or not source then
        return nil
    end
    local probe = { cover_url = url, source_id = source.id, url = story.url }
    local ok, path = pcall(CoverCache.download, CoverCache, probe, source)
    if ok and path then
        return path
    end
    return nil
end

-- Trang bìa của file trên máy, ghi PNG vào cache bìa.
function CoverFinder:extractLocal(file_path)
    local cover_url = "file://" .. file_path
    local existing = CoverCache:get({ cover_url = cover_url })
    if existing then
        return cover_url, existing
    end
    local ok, result = pcall(function()
        local BookInfo = require("apps/filemanager/filemanagerbookinfo")
        local image = BookInfo:getCoverImage(nil, file_path, true)
        if not image then
            return nil
        end
        local width, height = image:getWidth(), image:getHeight()
        if width > self.max_local_width then
            local scaled_ok, scaled = pcall(image.scale, image,
                self.max_local_width,
                math.floor(height * self.max_local_width / width))
            if scaled_ok and scaled then
                image:free()
                image = scaled
            end
        end
        local path = ffiutil.joinPath(
            Storage:getCoverCacheDir(),
            Util.stableHash(cover_url) .. ".png"
        )
        image:writePNG(path)
        image:free()
        return path
    end)
    if ok and result and lfs.attributes(result, "mode") == "file" then
        return cover_url, result
    end
    Debug.write("[CoverFinder] Không lấy được bìa từ file " .. tostring(file_path)
        .. ": " .. tostring(ok and "không có ảnh" or result))
    return nil
end

-- Tìm bìa cho một mục. opts.query: tên dùng khi tìm WeebCentral;
-- opts.local_file: file lấy trang bìa khi không có bìa online.
-- Trả về { cover_url, cover_source_id, cover_path } hoặc nil.
function CoverFinder:find(story, registry, opts)
    opts = opts or {}
    local weebcentral = registry:get(self.weebcentral_id)
    local candidate = weebcentral and self:weebcentralCover(story, registry, opts.query)
    local path = tryCover(story, candidate, weebcentral)
    if path then
        return { cover_url = candidate, cover_source_id = self.weebcentral_id, cover_path = path }
    end

    local source = registry:get(story.source_id)
    if source then
        local page = self:pageCover(story, source)
        path = tryCover(story, page, source)
        if path then
            return { cover_url = page, cover_source_id = source.id, cover_path = path }
        end
        path = tryCover(story, story.cover_url, source)
        if path then
            return { cover_url = story.cover_url, cover_source_id = source.id, cover_path = path }
        end
    end

    if opts.local_file then
        local cover_url, local_path = self:extractLocal(opts.local_file)
        if cover_url then
            return { cover_url = cover_url, cover_path = local_path }
        end
    end
    return nil
end

return CoverFinder
