local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Hệ thống file giả: /sdcard là symlink tới /storage/emulated/0.
local fs = {}
local function real(path)
    if path == "/sdcard" or path:sub(1, 8) == "/sdcard/" then
        return "/storage/emulated/0" .. path:sub(8)
    end
    return path
end
local function addDir(path)
    fs[real(path)] = { mode = "directory", modification = 1 }
end
local function addFile(path, md5)
    fs[real(path)] = { mode = "file", modification = 1, size = 1, md5 = md5 }
end
local function touchDir(path)
    local entry = fs[real(path)]
    entry.modification = entry.modification + 1
end
local function exists(path)
    return fs[real(path)] ~= nil
end
local function move(from, to)
    from, to = real(from), real(to)
    local moved = {}
    for path, entry in pairs(fs) do
        if path == from or path:sub(1, #from + 1) == from .. "/" then
            moved[path] = entry
        end
    end
    for path, entry in pairs(moved) do
        fs[path] = nil
        fs[to .. path:sub(#from + 1)] = entry
    end
end

local settings = { data = {} }
function settings:readSetting(key, default)
    if self.data[key] == nil then
        self.data[key] = default
    end
    return self.data[key]
end
local saves = 0
function settings:saveSetting(key, value)
    saves = saves + 1
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
    return {
        joinPath = function(left, right) return left .. "/" .. right end,
        realpath = function(path)
            return fs[real(path)] and real(path) or nil
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, field)
            local entry = fs[real(path)]
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
                if parent == real(path) then
                    table.insert(names, name)
                end
            end
            table.sort(names)
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
    }
end
local md5_reads = 0
package.preload["util"] = function()
    return {
        makePath = function(path)
            if not fs[real(path)] then
                addDir(path)
            end
        end,
        partialMD5 = function(path)
            md5_reads = md5_reads + 1
            local entry = fs[real(path)]
            return entry and entry.md5
        end,
    }
end
package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
end
package.preload["truyenviet/cover_cache"] = function()
    return { extensions = { "gif", "jpg", "png", "webp" }, get = function() return nil end }
end
package.preload["truyenviet/cover_finder"] = function()
    return { hasVietnamese = function() return false end }
end
package.preload["truyenviet/async_pool"] = function()
    return { run = function() return {} end }
end

os.rename = function(from, to)
    move(from, to)
    return true
end

local LocalLibrary = require("truyenviet/local_library")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")

local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

local function localStory(url, title, extra)
    local story = { source_id = "local", kind = "local", url = url, title = title }
    for key, value in pairs(extra or {}) do
        story[key] = value
    end
    return story
end
local function favorite(url)
    return Storage:getFavorites()["local|" .. url]
end
local function historyItem(url)
    for _, item in ipairs(Storage:getHistory()) do
        if item.story.url == url then
            return item
        end
    end
end

local books = "/sdcard/Books"
local manga = "/sdcard/Manga"
for _, dir in ipairs({ "/storage", "/storage/emulated", "/storage/emulated/0", books, manga,
    "/sdcard/Archive" }) do
    addDir(dir)
end
local covers = Storage:getCoverCacheDir()

-- Đổi tên một file tại chỗ: url, tên, bìa file://, cache bìa và lịch sử đi theo.
local ui_old = books .. "/713574649-How-to-Design.pdf"
local ui_new = books .. "/How-to-Design.pdf"
addFile(ui_new, "ui")
local ui_story = localStory(ui_old, "713574649-How-to-Design", { cover_url = "file://" .. ui_old })
Storage:mergeFavorites({ ui_story })
Storage:saveHistory(ui_story, { title = "713574649-How-to-Design", url = ui_old })
local ui_cover = covers .. "/" .. Util.stableHash("file://" .. ui_old) .. ".png"
addFile(ui_cover)

assertEqual(2, LocalLibrary.relocate(ui_old, ui_new), "Renamed file rewrites favorite and history")
assertEqual(nil, favorite(ui_old), "Old favorite key is gone")
local renamed = favorite(ui_new)
assertEqual("How-to-Design", renamed and renamed.title, "Title follows the file name")
assertEqual("file://" .. ui_new, renamed.cover_url, "Local cover URL follows the file")
assertEqual(false, exists(ui_cover), "Old cover cache file is moved")
assertEqual(true, exists(covers .. "/" .. Util.stableHash("file://" .. ui_new) .. ".png"),
    "Cover cache is keyed by the new URL")
local ui_history = historyItem(ui_new)
assertEqual(ui_new, ui_history and ui_history.chapter.url, "History chapter path follows the file")
assertEqual("How-to-Design", ui_history.chapter.title, "History chapter title follows the file")
assertEqual("How-to-Design", ui_history.story.title, "History story title follows the file")

-- Tên người dùng tự đặt thì giữ nguyên.
local custom_old = books .. "/scan-0042.cbz"
local custom_new = books .. "/scan-final.cbz"
addFile(custom_new)
Storage:mergeFavorites({ localStory(custom_old, "Sổ tay thiết kế") })
assertEqual(1, LocalLibrary.relocate(custom_old, custom_new), "Custom-titled entry is moved")
assertEqual("Sổ tay thiết kế", favorite(custom_new).title, "Custom title is kept")

-- Đổi tên thư mục bằng đường dẫn thật (KOReader realpath khi dán): bản ghi
-- giữ kiểu /sdcard, mục con trong lịch sử và offline_dir của truyện online đi theo.
local fool_old = manga .. "/Fool Night - Seinen"
local fool_new = manga .. "/Fool Night Complete"
addDir(fool_new)
addFile(fool_new .. "/v01.cbz")
local fool = localStory(fool_old, "Fool Night", { cover_url = "file://" .. fool_old .. "/v01.cbz" })
local online = { source_id = "truyenqq", url = "https://example.test/fool", title = "Fool Night",
    offline_dir = fool_old }
Storage:mergeFavorites({ fool, online })
Storage:saveHistory(fool, { title = "v01", url = fool_old .. "/v01.cbz" })
assertEqual(3, LocalLibrary.relocate(real(fool_old), real(fool_new)), "Folder rename with real paths")
local fool_record = favorite(fool_new)
assertEqual("Fool Night Complete", fool_record and fool_record.title, "Folder title is the new display name")
assertEqual("file://" .. fool_new .. "/v01.cbz", fool_record.cover_url, "Cover inside the folder follows")
assertEqual(fool_new, Storage:getFavorites()["truyenqq|https://example.test/fool"].offline_dir,
    "Linked offline folder follows")
local fool_history = historyItem(fool_new)
assertEqual(fool_new .. "/v01.cbz", fool_history and fool_history.chapter.url, "Chapter inside folder follows")
assertEqual("v01", fool_history.chapter.title, "Chapter title inside a renamed folder is unchanged")

-- Dời sang thư mục khác: giữ tên, quy về /sdcard.
local other_old = books .. "/Other.pdf"
local other_new = "/sdcard/Archive/Other.pdf"
addFile(other_new)
Storage:mergeFavorites({ localStory(other_old, "Other") })
assertEqual(1, LocalLibrary.relocate(real(other_old), real(other_new)), "Moved file")
assertEqual("Other", favorite(other_new) and favorite(other_new).title, "Moved file keeps /sdcard path and title")

-- Đường dẫn không liên quan (kể cả trùng tiền tố) không ghi gì.
local saves_before = saves
assertEqual(0, LocalLibrary.relocate(books .. "/Oth", books .. "/X"), "Prefix of a name is not a parent")
assertEqual(0, LocalLibrary.relocate("/sdcard/Unrelated", "/sdcard/Elsewhere"), "Unrelated path")
assertEqual(saves_before, saves, "Unrelated moves do not save settings")

-- Tìm lại khi mở Tủ truyện: ghi md5 cho file còn trên máy.
local keep = books .. "/Keep.epub"
addFile(keep, "keep-md5")
Storage:mergeFavorites({ localStory(keep, "Keep") })
assertEqual(0, LocalLibrary.healMissing(), "Nothing missing")
assertEqual("keep-md5", favorite(keep).partial_md5, "Present file gets its partial md5")

-- Khớp md5: tên mới khác hẳn tên cũ.
local md5_old = books .. "/Untitled.epub"
local md5_new = books .. "/Real Title.epub"
Storage:mergeFavorites({ localStory(md5_old, "Untitled", { partial_md5 = "abc" }) })
addFile(md5_new, "abc")
touchDir(books)
assertEqual(1, LocalLibrary.healMissing(), "Renamed file is found by partial md5")
assertEqual("Real Title", favorite(md5_new) and favorite(md5_new).title, "Healed by md5")

-- Bản ghi cũ chưa có md5: đúng một file cùng đuôi có tên chứa tên cũ.
local legacy_old = books .. "/99-Atomic Design.pdf"
local legacy_new = books .. "/Atomic Design.pdf"
Storage:mergeFavorites({ localStory(legacy_old, "99-Atomic Design") })
addFile(legacy_new)
touchDir(books)
assertEqual(1, LocalLibrary.healMissing(), "Legacy entry is found by name")
assertEqual("Atomic Design", favorite(legacy_new) and favorite(legacy_new).title, "Healed by name")

-- "Vol 1" không khớp "Vol 10"; hai ứng viên thì không đoán; file đã có mục
-- riêng không bị lấy; mục thư mục bị bỏ qua.
local vol_old = manga .. "/Vol 1.cbz"
Storage:mergeFavorites({ localStory(vol_old, "Vol 1") })
addFile(manga .. "/Vol 10.cbz")
local twin_old = manga .. "/Saga.cbz"
Storage:mergeFavorites({ localStory(twin_old, "Saga") })
addFile(manga .. "/Saga - part A.cbz")
addFile(manga .. "/Saga - part B.cbz")
local owned_old = books .. "/Keep Old.epub"
Storage:mergeFavorites({ localStory(owned_old, "Keep Old"), localStory(manga .. "/Gone Folder", "Gone Folder") })
touchDir(manga)
touchDir(books)
assertEqual(0, LocalLibrary.healMissing(), "Ambiguous or unsafe matches are not healed")
assertEqual("Vol 1", favorite(vol_old).title, "Vol 1 stays missing")
assertEqual("Saga", favorite(twin_old).title, "Two candidates stay missing")
assertEqual("Keep Old", favorite(owned_old).title, "A file owned by another entry is not taken")

-- Dò thất bại thì nhớ theo thời điểm sửa thư mục: lần mở sau không đọc lại.
local reads_before = md5_reads
Storage:mergeFavorites({ localStory(manga .. "/Lost.cbz", "Lost", { partial_md5 = "zzz" }) })
assertEqual(0, LocalLibrary.healMissing(), "Lost file is not found")
local reads_after_first = md5_reads
assertEqual(true, reads_after_first > reads_before, "First scan reads candidates")
LocalLibrary.healMissing()
assertEqual(reads_after_first, md5_reads, "Unchanged folder is not scanned again")

-- Hướng A: bọc ReadHistory của KOReader (một lần), gọi relocate sau hàm gốc.
package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, definition) return definition end }
end
package.preload["truyenviet/browser"] = function() return {} end
package.preload["truyenviet/reader"] = function() return {} end
package.preload["truyenviet/version"] = function() return "test" end
local original_calls = 0
local ReadHistory = {
    updateItem = function() original_calls = original_calls + 1 end,
    updateItemsByPath = function() original_calls = original_calls + 1 end,
    updateItems = function() original_calls = original_calls + 1 end,
}
package.preload["readhistory"] = function() return ReadHistory end
local Plugin = require("main")
Plugin.hookReadHistory()
local wrapped = ReadHistory.updateItem
Plugin.hookReadHistory()
assertEqual(wrapped, ReadHistory.updateItem, "Hooks are installed once")

addFile(books .. "/Atomic Design 2e.pdf")
move(legacy_new, books .. "/tmp")
ReadHistory:updateItem(legacy_new, books .. "/Atomic Design 2e.pdf")
assertEqual(1, original_calls, "Original updateItem still runs")
assertEqual("Atomic Design 2e", favorite(books .. "/Atomic Design 2e.pdf")
    and favorite(books .. "/Atomic Design 2e.pdf").title, "Rename in File manager updates the library")

addDir("/sdcard/Comics")
ReadHistory:updateItemsByPath(real(fool_new), real("/sdcard/Comics/Fool Night Complete"))
assertEqual("Fool Night Complete", favorite("/sdcard/Comics/Fool Night Complete")
    and favorite("/sdcard/Comics/Fool Night Complete").title, "Folder move updates the library")

ReadHistory:updateItems({ [real(keep)] = true }, real("/sdcard/Archive"))
assertEqual("Keep", favorite("/sdcard/Archive/Keep.epub") and favorite("/sdcard/Archive/Keep.epub").title,
    "Multi-select move updates the library")
assertEqual(3, original_calls, "Every original runs")

print(string.format("Local relocate tests passed: %d assertions", tests_run))
