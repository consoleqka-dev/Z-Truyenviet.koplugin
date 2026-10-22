local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Hệ thống file giả có dung lượng file.
local fs = {}
local function addDir(path)
    fs[path] = { mode = "directory", modification = 1 }
end
local function addFile(path, size)
    fs[path] = { mode = "file", modification = 1, size = size }
end

local settings = { data = {} }
function settings:readSetting(key, default)
    if self.data[key] == nil then
        self.data[key] = default
    end
    return self.data[key]
end
function settings:saveSetting(key, value)
    self.data[key] = value
end
function settings:flush() end

package.preload["socket.url"] = function()
    return { absolute = function(_, href) return href end }
end
package.preload["datastorage"] = function()
    return {
        getFullDataDir = function() return "/sdcard/koreader" end,
        getSettingsDir = function() return "/settings" end,
    }
end
package.preload["luasettings"] = function()
    return { open = function() return settings end }
end
package.preload["ffi/util"] = function()
    return { joinPath = function(left, right) return left .. "/" .. right end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local entry = fs[path]
            if not entry then
                return nil
            end
            if field then
                return entry[field]
            end
            return entry
        end,
        dir = function(path)
            local names = {}
            for child in pairs(fs) do
                local parent, name = child:match("^(.*)/([^/]+)$")
                if parent == path then
                    table.insert(names, name)
                end
            end
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end
package.preload["util"] = function()
    return {
        makePath = function(path)
            if not fs[path] then
                addDir(path)
            end
        end,
        stringLower = string.lower,
        htmlEntitiesToUtf8 = function(value) return value end,
    }
end
package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
end
package.preload["truyenviet/cover_cache"] = function()
    return { get = function() return nil end }
end
package.preload["truyenviet/cover_finder"] = function()
    return { hasVietnamese = function() return false end }
end
package.preload["truyenviet/async_pool"] = function()
    return { run = function() return {} end }
end

local LocalLibrary = require("truyenviet/local_library")
local Storage = require("truyenviet/storage")
local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local MB = 1024 * 1024
local plugin_root = "/sdcard/koreader/truyenviet"
local books = "/storage/emulated/0/Books"
local vagabond = books .. "/VAGABOND"
local single = books .. "/UX Principles.pdf"
for _, dir in ipairs({
    "/sdcard", "/sdcard/koreader", plugin_root, plugin_root .. "/truyenqq",
    plugin_root .. "/truyenqq/fool-night", "/storage", "/storage/emulated", "/storage/emulated/0",
    books, vagabond, vagabond .. "/Vagabond v01.sdr", books .. "/UX Principles.sdr",
}) do
    addDir(dir)
end
addFile(vagabond .. "/Vagabond v01.cbz", 40 * MB)
addFile(vagabond .. "/Vagabond v02.cbz", 60 * MB)
addFile(vagabond .. "/Vagabond v01.sdr/metadata.cbz.lua", 2048)
addFile(single, 3 * MB)
addFile(books .. "/UX Principles.sdr/metadata.pdf.lua", 1024)
addFile(books .. "/Other.pdf", 9 * MB)
addFile(plugin_root .. "/truyenqq/fool-night/chapter-1.cbz", 512 * 1024)
addFile(plugin_root .. "/truyenqq/fool-night/chapter-2.cbz", 512 * 1024)

-- Định dạng dung lượng
assertEqual("0 B", LocalLibrary.formatSize(0), "Zero")
assertEqual("512 B", LocalLibrary.formatSize(512), "Bytes")
assertEqual("1 KB", LocalLibrary.formatSize(1024), "Whole KB has no decimal")
assertEqual("1,5 MB", LocalLibrary.formatSize(1.5 * MB), "Comma decimal")
assertEqual("100 MB", LocalLibrary.formatSize(100 * MB), "Large values are rounded")
assertEqual("1,2 GB", LocalLibrary.formatSize(1.2 * 1024 * MB), "Gigabytes")

-- Dung lượng theo đường dẫn
assertEqual(100 * MB + 2048, LocalLibrary.sizeOf({ vagabond }), "Folder size is recursive")
assertEqual(0, LocalLibrary.sizeOf({ books .. "/missing" }), "Missing path")

local vagabond_story = { source_id = "local", kind = "local", title = "VAGABOND", url = vagabond }
local single_story = { source_id = "local", kind = "local", title = "UX Principles", url = single }
local fool = { source_id = "truyenqq", title = "Fool Night", url = "https://truyenqq.test/truyen-tranh/fool-night" }
assertEqual(3 * MB + 1024, LocalLibrary.storySize(single_story), "File counts its sidecar")
assertEqual(MB, LocalLibrary.storySize(fool), "Online story counts its download dir")

settings.data.favorites = {}
for _, story in ipairs({ vagabond_story, single_story, fool }) do
    settings.data.favorites[story.source_id .. "|" .. story.url] = story
end
local registry = { get = function() return { name = "TruyenQQ" } end }
local annotated = {}
for _, story in ipairs(LocalLibrary.annotate(Storage:listFavorites(), registry)) do
    annotated[story.title] = story
end
assertEqual(100 * MB + 2048, annotated["VAGABOND"].size_bytes, "Annotated folder size")
assertEqual(MB, annotated["Fool Night"].size_bytes, "Annotated online size")
assertEqual(nil, settings.data.favorites["local|" .. vagabond].size_bytes, "Size is not stored")

-- Tìm mục "Trên máy" cho file đang mở (cả đường dẫn /sdcard tương đương)
local favorites = Storage:listFavorites()
local owner = LocalLibrary.findOwner(vagabond .. "/Vagabond v02.cbz", favorites)
assertEqual("VAGABOND", owner and owner.title, "File inside a local folder")
owner = LocalLibrary.findOwner("/sdcard/Books/VAGABOND/Vagabond v02.cbz", favorites)
assertEqual("VAGABOND", owner and owner.title, "/sdcard alias")
owner = LocalLibrary.findOwner(single, favorites)
assertEqual("UX Principles", owner and owner.title, "Local file entry")
assertEqual(nil, LocalLibrary.findOwner(books .. "/Other.pdf", favorites), "Unrelated file")
assertEqual(nil, LocalLibrary.findOwner(books .. "/VAGABOND-extra/x.cbz", favorites), "Prefix is not a parent")
assertEqual(nil, LocalLibrary.findOwner(plugin_root .. "/truyenqq/fool-night/chapter-1.cbz", favorites),
    "Online downloads are not local entries")

local whole = { source_id = "local", kind = "local", title = "Books", url = books }
owner = LocalLibrary.findOwner(vagabond .. "/Vagabond v01.cbz", { whole, vagabond_story })
assertEqual("VAGABOND", owner and owner.title, "Deepest folder wins")

-- Ghi Lịch sử đọc
settings.data.history = {
    { story = fool, chapter = { title = "1", url = "c1" }, time = 1 },
}
assertEqual(true, LocalLibrary.recordRead("/sdcard/Books/VAGABOND/Vagabond v02.cbz"), "History recorded")
local history = Storage:getHistory()
assertEqual(2, #history, "New entry added")
assertEqual("local", history[1].story.source_id, "Local entry first")
assertEqual(vagabond, history[1].story.url, "Story url is the folder")
assertEqual("Vagabond v02", history[1].chapter.title, "Chapter title is the file name")
assertEqual("/sdcard/Books/VAGABOND/Vagabond v02.cbz", history[1].chapter.url, "Chapter url is the file")

LocalLibrary.recordRead(vagabond .. "/Vagabond v01.cbz")
history = Storage:getHistory()
assertEqual(2, #history, "Same story is not duplicated")
assertEqual("Vagabond v01", history[1].chapter.title, "Latest volume replaces the old one")
assertEqual(false, LocalLibrary.recordRead(books .. "/Other.pdf"), "Unrelated file is not recorded")
assertEqual(2, #Storage:getHistory(), "History unchanged")

-- Dung lượng thư mục nhớ trong phiên
local lfs_mock = require("libs/libkoreader-lfs")
local real_dir = lfs_mock.dir
local dir_calls = 0
lfs_mock.dir = function(path)
    dir_calls = dir_calls + 1
    return real_dir(path)
end
LocalLibrary.forgetSizes({ vagabond })
dir_calls = 0
assertEqual(100 * MB + 2048, LocalLibrary.sizeOfCached(vagabond), "First cached size")
assertEqual(true, dir_calls > 0, "First call scans the folder")
dir_calls = 0
assertEqual(100 * MB + 2048, LocalLibrary.sizeOfCached(vagabond), "Second cached size")
assertEqual(0, dir_calls, "Second call does not scan")
assertEqual(100 * MB + 2048, LocalLibrary.storySize(vagabond_story), "storySize uses the cache")
assertEqual(0, dir_calls, "storySize does not scan again")

addFile(vagabond .. "/Vagabond v03.cbz", 10 * MB)
fs[vagabond].modification = 2
assertEqual(110 * MB + 2048, LocalLibrary.sizeOfCached(vagabond), "Folder change is rescanned")
addFile(vagabond .. "/Vagabond v01.sdr/extra.lua", 1024)
fs[vagabond .. "/Vagabond v01.sdr"].modification = 2
assertEqual(110 * MB + 3072, LocalLibrary.sizeOfCached(vagabond), "Subfolder change is rescanned")

fs[vagabond .. "/Vagabond v03.cbz"] = nil
LocalLibrary.forgetSizes({ vagabond .. "/Vagabond v03.cbz" })
dir_calls = 0
assertEqual(100 * MB + 3072, LocalLibrary.sizeOfCached(vagabond), "Forgotten parent is rescanned")
assertEqual(true, dir_calls > 0, "Forget drops the parent entry")
assertEqual(3 * MB, LocalLibrary.sizeOfCached(single), "File size is read directly")
lfs_mock.dir = real_dir

-- Lịch sử đọc lấy bìa của mục Tủ truyện tương ứng.
local history_stories = {
    { source_id = "a", url = "/1", cover_url = nil, cover_path = "/old" },
    { source_id = "a", url = "/2", cover_url = "https://img/2.jpg" },
    { source_id = "b", url = "/3", cover_url = "https://img/old3.jpg" },
    { source_id = "c", url = "/4" },
}
local favorite_records = {
    { source_id = "a", url = "/1", cover_url = "https://found/1.jpg", cover_source_id = "weeb", cover_found = true, cover_time = 5 },
    { source_id = "a", url = "/2", cover_url = "https://img/2.jpg" },
    { source_id = "b", url = "/3", cover_url = "https://img/new3.jpg" },
    { source_id = "c", url = "/4", cover_url = "" },
}
assertEqual(2, LocalLibrary.copyFavoriteCovers(history_stories, favorite_records), "Copies two changed covers")
assertEqual("https://found/1.jpg", history_stories[1].cover_url, "Missing cover comes from favorite")
assertEqual("weeb", history_stories[1].cover_source_id, "Cover source comes from favorite")
assertEqual(true, history_stories[1].cover_found, "Cover found flag comes from favorite")
assertEqual(nil, history_stories[1].cover_path, "Old cover path is cleared")
assertEqual("https://img/new3.jpg", history_stories[3].cover_url, "Stale cover is replaced")
assertEqual(nil, history_stories[4].cover_url, "Empty favorite cover is ignored")
assertEqual(0, LocalLibrary.copyFavoriteCovers(history_stories, nil), "No favorites")

print(string.format("Local history and size tests passed: %d assertions", tests_run))
