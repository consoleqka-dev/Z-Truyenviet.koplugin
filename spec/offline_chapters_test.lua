local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Hệ thống file giả: path -> { mode, modification } ; thư mục liệt kê con theo tiền tố.
local fs = {}
local removed = {}
local function addDir(path)
    fs[path] = { mode = "directory", modification = 1 }
end
local function addFile(path)
    fs[path] = { mode = "file", modification = 1, size = 10 }
    local dir = path:match("^(.*)/[^/]+$")
    if fs[dir] then
        fs[dir].modification = fs[dir].modification + 1
    end
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
        getFullDataDir = function() return "/data" end,
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
        rmdir = function(path)
            fs[path] = nil
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

-- Sidecar KOReader giả: đường dẫn sách -> { sidecar, toc }
local sidecars = {}
package.preload["docsettings"] = function()
    local DocSettings = {}
    function DocSettings:findSidecarFile(path)
        local entry = sidecars[path]
        return entry and entry.sidecar
    end
    function DocSettings:open(path)
        local entry = sidecars[path] or {}
        return {
            readSetting = function(_, key)
                if key == "handmade_toc" then
                    return entry.toc
                end
            end,
        }
    end
    return DocSettings
end

local real_remove = os.remove
os.remove = function(path)
    if fs[path] then
        fs[path] = nil
        table.insert(removed, path)
        return true
    end
    return real_remove(path)
end

local Storage = require("truyenviet/storage")
local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

-- Số chương từ tên file / URL / tiêu đề
assertEqual(83, Storage.chapterNumber("chapter-83"), "Plugin leaf")
assertEqual(19, Storage.chapterNumber("fool-night-12615-chap-19.cbz"), "User file name")
assertEqual(12.5, Storage.chapterNumber("fool-night-12615-chap-12-5.cbz"), "Dash decimal at end")
assertEqual(12.5, Storage.chapterNumber("chap-12.5.cbz"), "Dot decimal")
assertEqual(7, Storage.chapterNumber("Chương 7: Mở đầu"), "Vietnamese title")
assertEqual(5, Storage.chapterNumber("chuong-5-2-nguoi"), "Dash not at end is not a decimal")
assertEqual(nil, Storage.chapterNumber("Dorohedoro v01 (2010).pdf"), "Volume is not a chapter")
assertEqual(false, Storage.isBookFile("cover.jpg"), "Cover is not a book")
assertEqual(false, Storage.isBookFile("x.cbz.part"), "Partial download is not a book")
assertEqual(true, Storage.isBookFile("x.CBZ"), "Extension is case-insensitive")

-- Truyện truyenqq gắn thư mục trên máy
local linked = "/sdcard/Books/Manga/Fool Night - Seinen"
addDir("/sdcard")
addDir("/sdcard/Books")
addDir("/sdcard/Books/Manga")
addDir(linked)
addFile(linked .. "/fool-night-12615-chap-1.cbz")
addFile(linked .. "/fool-night-12615-chap-2.cbz")
addFile(linked .. "/fool-night-12615-chap-19.cbz")
addDir(linked .. "/fool-night-12615-chap-19.sdr")

local source = { id = "truyenqq", kind = "comic" }
local story = {
    source_id = "truyenqq",
    url = "https://truyenqq.com.vn/fool-night",
    title = "Fool Night",
}
settings.data.favorites = {
    ["truyenqq|https://truyenqq.com.vn/fool-night"] = {
        source_id = "truyenqq",
        url = story.url,
        title = "Fool Night",
        offline_dir = linked,
    },
}
local function chapter(n)
    return { url = "https://truyenqq.com.vn/fool-night/chapter-" .. n, title = "Chapter " .. n }
end

assertEqual(linked, Storage:getLinkedDir(story), "Linked dir found through favorites")
assertEqual(linked, Storage:getStoryDir(source, story), "Story dir is the linked dir")
assertEqual(linked .. "/fool-night-12615-chap-19.cbz", Storage:getChapterPath(source, story, chapter(19)),
    "Chapter resolves to the user file by number")
assertEqual(true, Storage:isDownloaded(source, story, chapter(19)), "User file counts as downloaded")
assertEqual(false, Storage:isDownloaded(source, story, chapter(20)), "Missing chapter is not downloaded")
assertEqual(linked .. "/chapter-20.cbz", Storage:getChapterPath(source, story, chapter(20)),
    "New download goes into the linked dir")

-- File plugin tự tải được ưu tiên, đếm không trùng
addFile(linked .. "/chapter-20.cbz")
addFile(linked .. "/chapter-2.cbz")
assertEqual(linked .. "/chapter-2.cbz", Storage:getChapterPath(source, story, chapter(2)), "Plugin file wins")
local plugin_dir = "/data/truyenviet/truyenqq/fool-night"
addDir("/data")
addDir("/data/truyenviet")
addDir("/data/truyenviet/truyenqq")
addDir(plugin_dir)
addFile(plugin_dir .. "/chapter-21.cbz")
addFile(plugin_dir .. "/chapter-1.cbz")
addFile(plugin_dir .. "/chapter-22.cbz.part")
assertEqual(plugin_dir .. "/chapter-21.cbz", Storage:getChapterPath(source, story, chapter(21)),
    "Old plugin download is still found")
assertEqual(5, Storage:countOfflineChapters(story), "Counts distinct chapters 1, 2, 19, 20, 21")

-- Xóa: file của người dùng không bao giờ bị xóa
removed = {}
assertEqual(true, Storage:removeDownload(source, story, chapter(19)), "Purge of user file reports success")
assertEqual(0, #removed, "User file is kept")
assertEqual("file", fs[linked .. "/fool-night-12615-chap-19.cbz"].mode, "User file still exists")
Storage:removeDownload(source, story, chapter(20))
assertEqual(linked .. "/chapter-20.cbz", removed[1], "Plugin download in linked dir can be purged")

removed = {}
Storage:clearAllFavorites(true)
assertEqual("directory", fs[linked] and fs[linked].mode, "Linked dir survives clearing favorites")
assertEqual("file", fs[linked .. "/fool-night-12615-chap-1.cbz"].mode, "User files survive clearing favorites")
assertEqual(nil, fs[plugin_dir], "Plugin dir is removed")

-- Ghi Tủ truyện giữ offline_dir và bìa lớn khi cập nhật từ tìm kiếm
settings.data.favorites = {}
Storage:addFavorite({
    source_id = "truyenqq", url = story.url, title = "Fool Night",
    offline_dir = linked, cover_url = "https://big/cover.jpg", cover_found = true,
    cover_source_id = "weebcentral", latest_chapter = 83,
})
Storage:updateFavorite({ source_id = "truyenqq", url = story.url, title = "Fool Night",
    cover_url = "https://small/80x105.jpg" })
local record = settings.data.favorites["truyenqq|" .. story.url]
assertEqual(linked, record.offline_dir, "Update keeps offline_dir")
assertEqual("https://big/cover.jpg", record.cover_url, "Update keeps found cover")
assertEqual("weebcentral", record.cover_source_id, "Update keeps cover source")
assertEqual(83, record.latest_chapter, "Update keeps saved meta")

-- Truyện không gắn thư mục vẫn dùng thư mục plugin
local other = { source_id = "truyenqq", url = "https://truyenqq.com.vn/giant-killing", title = "GK" }
assertEqual(nil, Storage:getLinkedDir(other), "No link")
assertEqual("/data/truyenviet/truyenqq/giant-killing/chapter-3.cbz",
    Storage:getChapterPath(source, other, { url = "https://truyenqq.com.vn/giant-killing/chapter-3" }),
    "Plugin path unchanged")
assertEqual(0, Storage:countOfflineChapters(other), "Nothing downloaded")

-- Tệp trọn bộ: file không có số chương nhưng có mục lục tự tạo trong .sdr
local wc_source = { id = "weebcentral", kind = "comic" }
local ace = { source_id = "weebcentral", url = "https://weebcentral.com/series/01J76/Diamond-No-Ace" }
local ace_dir = "/data/truyenviet/weebcentral/Diamond-No-Ace"
local bundle = ace_dir .. "/Diamond-No-Ace-tron-bo.cbz"
local sidecar = ace_dir .. "/Diamond-No-Ace-tron-bo.sdr/metadata.cbz.lua"
local function aceChapter(number)
    local leaf = tostring(number):gsub("%.", "-")
    return {
        url = "https://weebcentral.com/chapters/01J8/chapter-" .. leaf,
        title = "Chapter " .. tostring(number),
    }
end
addDir("/data/truyenviet/weebcentral")
addDir(ace_dir)
addFile(ace_dir .. "/chapter-1.cbz")
addFile(ace_dir .. "/chapter-411-2.cbz")
addDir(ace_dir .. "/Diamond-No-Ace-tron-bo.sdr")
fs[sidecar] = { mode = "file", modification = 1 }
sidecars[bundle] = {
    sidecar = sidecar,
    toc = {
        { depth = 1, page = 1, title = "Bìa" },
        { depth = 1, page = 1, title = "Chương 1" },
        { depth = 1, page = 30, title = "Chương 2" },
        { depth = 1, page = 900, title = "Chương 411.1" },
        { depth = 1, page = 920, title = "Chương 411.2" },
        { depth = 1, page = 950, title = "Chương 412" },
    },
}
addFile(bundle)
-- Tập riêng chỉ có một chương trong mục lục: vẫn là một file thường
local volume = ace_dir .. "/Ngoai-truyen.cbz"
sidecars[volume] = { sidecar = ace_dir .. "/Ngoai-truyen.sdr/metadata.cbz.lua",
    toc = { { depth = 1, page = 1, title = "Chương 0" } } }
addFile(volume)

assertEqual(6, Storage:countOfflineChapters(ace),
    "Counts bundle chapters 1, 2, 411.1, 411.2, 412 and the plain volume, not the bundle file")
assertEqual(true, Storage:isDownloaded(wc_source, ace, aceChapter(2)), "Bundled chapter is downloaded")
assertEqual(false, Storage:hasChapterFile(wc_source, ace, aceChapter(2)), "Bundled chapter has no own file")
assertEqual(true, Storage:hasChapterFile(wc_source, ace, aceChapter(411.2)), "Single file still found")
assertEqual(false, Storage:isDownloaded(wc_source, ace, aceChapter(413)), "Chapter past the bundle is missing")
local bundle_path, bundle_page = Storage:getBundleChapter(wc_source, ace, aceChapter(411.1))
assertEqual(bundle, bundle_path, "Bundle path for a decimal chapter")
assertEqual(900, bundle_page, "Bundle page for a decimal chapter")
assertEqual(nil, Storage:getBundleChapter(wc_source, ace, aceChapter(413)), "No bundle page past the TOC")
assertEqual(1, Storage:bundleChapterAt(bundle, 29), "Page before chapter 2 belongs to chapter 1")
assertEqual(411.2, Storage:bundleChapterAt(bundle, 925), "Page inside chapter 411.2")
assertEqual(412, Storage:bundleChapterAt(bundle, 5000), "Last pages belong to the last chapter")
assertEqual(nil, Storage:bundleChapterAt(volume, 1), "Plain volume is not a bundle")

-- Sửa mục lục (sidecar đổi) thì đếm lại dù thư mục không đổi
table.insert(sidecars[bundle].toc, { depth = 1, page = 980, title = "Chương 413" })
fs[sidecar].modification = 2
assertEqual(7, Storage:countOfflineChapters(ace), "Edited TOC is read again")
assertEqual(true, Storage:isDownloaded(wc_source, ace, aceChapter(413)), "New TOC chapter is downloaded")

os.remove = real_remove
print(string.format("Offline chapters tests passed: %d assertions", tests_run))
