local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Thư mục thật trong spec/, xóa khi xong (không để lại file tạm).
local cache_dir = root .. "/spec/.chapter-cache-test-" .. tostring(os.time())
os.execute("mkdir -p '" .. cache_dir .. "'")

local function listDir(path)
    local names = {}
    local pipe = io.popen("ls -1 '" .. path .. "' 2>/dev/null")
    for name in pipe:lines() do
        table.insert(names, name)
    end
    pipe:close()
    return names
end

package.preload["socket.url"] = function()
    return { absolute = function(_, href) return href end }
end
package.preload["util"] = function()
    return { stringLower = string.lower, htmlEntitiesToUtf8 = function(value) return value end }
end
package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
end
package.preload["truyenviet/storage"] = function()
    return { getChapterCacheDir = function() return cache_dir end }
end
package.preload["ffi/util"] = function()
    return { joinPath = function(left, right) return left .. "/" .. right end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        dir = function(path)
            local names = listDir(path)
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        attributes = function(path, field)
            local pipe = io.popen("stat -f %m '" .. path .. "' 2>/dev/null")
            local value = tonumber(pipe:read("*l"))
            pipe:close()
            if field then
                return value
            end
            return value and { modification = value } or nil
        end,
    }
end

local ChapterCache = require("truyenviet/chapter_cache")
local tests_run = 0
local function check(condition, message)
    tests_run = tests_run + 1
    if not condition then
        error(message, 2)
    end
end

local ok, err = pcall(function()
    check(ChapterCache.isAvailable(), "string.buffer phải có trong LuaJIT")
    check(ChapterCache.get("src", "https://a.test/story", 1) == nil, "chưa lưu thì không có mục lục")

    local page_data = {
        story = { title = "Truyện A", url = "https://a.test/story", source_id = "src" },
        page = 1,
        total_pages = 2,
        chapters = {
            { title = "Chương 1", url = "https://a.test/c1" },
            { title = "Chương 2", url = "https://a.test/c2", fn = function() end },
        },
        view = setmetatable({}, { __index = function() return 1 end }),
    }
    check(ChapterCache.put("src", "https://a.test/story", 1, page_data), "lưu trang 1")
    local data, saved_at = ChapterCache.get("src", "https://a.test/story", 1)
    check(data and #data.chapters == 2, "đọc lại đủ 2 chương")
    check(data.chapters[2].fn == nil, "bỏ function khi lưu")
    check(data.view == nil, "chỉ lưu story/page/total_pages/chapters")
    check(data.story.title == "Truyện A" and data.total_pages == 2, "giữ story và total_pages")
    check(type(saved_at) == "number" and os.time() - saved_at < 5, "có thời điểm lưu")
    check(ChapterCache.get("src", "https://a.test/story", 2) == nil, "trang khác chưa lưu")
    check(ChapterCache.get("other", "https://a.test/story", 1) == nil, "nguồn khác không dùng chung")

    -- Gộp chương mọi trang; thiếu trang 1 vẫn tìm từ trang có lưu.
    check(ChapterCache.put("src", "https://a.test/story", 2, {
        page = 2, total_pages = 2, chapters = { { title = "Chương 3", url = "https://a.test/c3" } },
    }), "lưu trang 2")
    local all = ChapterCache.chaptersFor("src", "https://a.test/story")
    check(all and #all == 3 and all[3].url == "https://a.test/c3", "gộp 3 chương của 2 trang")
    check(ChapterCache.chaptersFor("src", "https://none.test") == nil, "truyện chưa lưu trả nil")

    check(ChapterCache.newChapterCount(page_data.chapters, {
        { url = "https://a.test/c1" }, { url = "https://a.test/c2" }, { url = "https://a.test/c9" },
    }) == 1, "đếm 1 chương mới")
    check(ChapterCache.newChapterCount(nil, { { url = "x" } }) == 1, "danh sách cũ rỗng")

    -- File hỏng bị xóa.
    local names = listDir(cache_dir)
    local broken
    for _, name in ipairs(names) do
        broken = cache_dir .. "/" .. name
        break
    end
    local file = io.open(broken, "wb")
    file:write("hỏng")
    file:close()
    local first = ChapterCache.get("src", "https://a.test/story", 1)
    local second = ChapterCache.get("src", "https://a.test/story", 2)
    check(first == nil or second == nil, "file hỏng không đọc được")
    check(io.open(broken, "rb") == nil, "file hỏng bị xóa")

    -- Dọn bớt khi vượt giới hạn.
    ChapterCache.max_files = 5
    ChapterCache.keep_files = 3
    for index = 1, 7 do
        ChapterCache.put("src", "https://b.test/" .. index, 1, { chapters = {} })
    end
    local count = 0
    for _, name in ipairs(listDir(cache_dir)) do
        if name:match("%.bin$") then
            count = count + 1
        end
        check(not name:match("%.tmp$"), "không để lại file .tmp")
    end
    check(count <= ChapterCache.max_files, "dọn bớt khi vượt giới hạn (còn " .. count .. ")")

    ChapterCache.clear()
    check(#listDir(cache_dir) == 0, "clear xóa hết")
    check(not ChapterCache.put("src", "u", 1, { chapters = "x" }), "từ chối dữ liệu sai")
end)

os.execute("rm -rf '" .. cache_dir .. "'")
if not ok then
    error(err, 0)
end
print(string.format("chapter_cache_test: %d checks passed", tests_run))
