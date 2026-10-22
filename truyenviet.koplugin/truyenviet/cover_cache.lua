local AsyncPool = require("truyenviet/async_pool")
local Debug = require("truyenviet/debugger")
local Http = require("truyenviet/http_client")
local ImageUtils = require("truyenviet/image_utils")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")

local CoverCache = {
    extensions = { "gif", "jpg", "png", "webp" },
    max_prefetch = 10,
    prefetch_concurrency = 4,
    prefetch_deadline = 15,
}

function CoverCache:get(story)
    if not story.cover_url or story.cover_url == "" then
        return nil
    end
    local stem = Util.stableHash(story.cover_url)
    for _, extension in ipairs(self.extensions) do
        local path = ffiutil.joinPath(
            Storage:getCoverCacheDir(),
            stem .. "." .. extension
        )
        if lfs.attributes(path, "mode") == "file" then
            local file = io.open(path, "rb")
            if file then
                local content = file:read(12)
                file:close()
                if content and ImageUtils:isSupported(nil, content) then
                    return path
                else
                    os.remove(path)
                end
            else
                os.remove(path)
            end
        end
    end
end

function CoverCache:download(story, source)
    local existing = self:get(story)
    if existing then
        return existing
    end
    if not story.cover_url or story.cover_url == "" then
        return nil
    end
    -- Bìa trích từ file trên máy chỉ có trong cache, không tải được.
    if story.cover_url:match("^file://") then
        return nil
    end
    -- Bìa tìm từ nguồn khác (vd. WeebCentral) gửi header của nguồn đó.
    if story.cover_source_id and source and story.cover_source_id ~= source.id then
        local ok, registry = pcall(require, "truyenviet/source_registry")
        local cover_source = ok and registry:get(story.cover_source_id)
        if cover_source then
            source = cover_source
        end
    end

    local headers = source.getCoverHeaders and source:getCoverHeaders(story) or {
        ["Referer"] = source.base_url .. "/",
    }
    headers["Accept"] = "image/webp,image/apng,image/*,*/*;q=0.8"

    -- Một số nguồn (vd truyenc.com) trả cover_url có khoảng trắng chưa được
    -- encode (vd "...Phan 2-Quy-Co-Nu.jpg") -> server trả 400 Bad Request vì
    -- URL có khoảng trắng thô là không hợp lệ. Encode khoảng trắng thành %20
    -- trước khi gửi request (chỉ encode dấu cách, giữ nguyên phần còn lại vì
    -- URL này thường đã encode sẵn các ký tự khác).
    local request_url = story.cover_url:gsub(" ", "%%20")

    -- Trong pool copas: không retry nhiều và không fallback curl (io.popen
    -- chặn cả vòng lặp copas).
    local opts = AsyncPool.inPoolThread()
        and { timeout = 10, max_retries = 1, no_curl = true } or nil
    local content, err, response_headers = Http:requestAsync("GET", request_url, nil, headers, opts)
    if not content then
        return nil, err
    end
    if not ImageUtils:isSupported(response_headers, content) then
        return nil, "Máy chủ không trả về ảnh bìa hợp lệ"
    end

    local extension = ImageUtils:detectExtension(
        response_headers,
        content,
        story.cover_url
    )
    local path = ffiutil.joinPath(
        Storage:getCoverCacheDir(),
        Util.stableHash(story.cover_url) .. "." .. extension
    )
    local temp_path = path .. ".part"
    local file, open_err = io.open(temp_path, "wb")
    if not file then
        return nil, open_err
    end
    local ok, write_err = file:write(content)
    file:close()
    if not ok then
        os.remove(temp_path)
        return nil, write_err
    end
    os.remove(path)
    local renamed, rename_err = os.rename(temp_path, path)
    if not renamed then
        os.remove(temp_path)
        return nil, rename_err
    end
    return path
end

function CoverCache:prefetch(stories, registry)
    local fast_mode = Storage.settings and Storage.settings:readSetting("fast_mode", false)
    if fast_mode then return stories end
    
    local limit = math.min(#stories, self.max_prefetch)
    local failed = 0
    local function safePrefetch(story)
        local source = registry:get(story.source_id)
        if not source then
            return
        end
        local ok, cover_path, err = pcall(self.download, self, story, source)
        if ok then
            story.cover_path = cover_path
        end
        -- Lỗi tải bìa trước đây bị nuốt im lặng; ghi lại để biết vì sao bìa trống
        if not ok or not cover_path then
            failed = failed + 1
            Debug.write(string.format("[Cover] Lỗi tải bìa %s (%s): %s",
                tostring(story.cover_url), tostring(story.source_id),
                tostring(ok and (err or "không có đường dẫn ảnh") or cover_path)))
        end
    end

    -- Dùng AsyncPool (không tự step Copas) nên gọi lồng được từ thread của pool.
    -- Không có Copas thì AsyncPool tự chạy tuần tự.
    local tasks = {}
    for index = 1, limit do
        tasks[index] = function()
            safePrefetch(stories[index])
        end
    end
    AsyncPool.run(tasks, {
        concurrency = self.prefetch_concurrency,
        deadline = self.prefetch_deadline,
    })

    collectgarbage("collect")
    return stories
end

return CoverCache
