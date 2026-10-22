local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Hệ thống file giả: thư mục plugin, thư viện /sdcard/Books.
local fs = {}
local function addDir(path)
    fs[path] = { mode = "directory", modification = 1 }
end
local function addFile(path)
    fs[path] = { mode = "file", modification = 1 }
end
local function exists(path)
    return fs[path] ~= nil
end
local function children(path)
    local names = {}
    for child in pairs(fs) do
        local parent, name = child:match("^(.*)/([^/]+)$")
        if parent == path then
            table.insert(names, name)
        end
    end
    return names
end

local settings = { data = {}, flushes = 0 }
function settings:readSetting(key, default)
    if self.data[key] == nil then
        self.data[key] = default
    end
    return self.data[key]
end
function settings:saveSetting(key, value)
    self.data[key] = value
end
function settings:flush()
    self.flushes = self.flushes + 1
end

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
            return field and entry[field] or entry
        end,
        dir = function(path)
            local names = children(path)
            local index = 0
            return function()
                index = index + 1
                return names[index]
            end
        end,
        rmdir = function(path)
            if fs[path] and fs[path].mode == "directory" and #children(path) == 0 then
                fs[path] = nil
                return true
            end
            return nil, "not empty"
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

os.remove = function(path)
    if fs[path] and fs[path].mode == "file" then
        fs[path] = nil
        return true
    end
    return nil, "no such file"
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

local plugin_root = "/sdcard/koreader/truyenviet"
local books = "/sdcard/Books"
local manga = books .. "/Manga"
local fool_linked = manga .. "/Fool Night"
local doro = manga .. "/Dorohedoro"
local single = books .. "/UX Principles.pdf"
for _, dir in ipairs({
    "/sdcard", "/sdcard/koreader", plugin_root, plugin_root .. "/truyenqq",
    plugin_root .. "/truyenqq/fool-night", plugin_root .. "/truyenqq/giant-killing",
    books, manga, fool_linked, fool_linked .. "/fool-night-chap-1.sdr", doro,
    books .. "/UX Principles.sdr",
}) do
    addDir(dir)
end
for _, file in ipairs({
    plugin_root .. "/truyenqq/fool-night/chapter-1.cbz",
    plugin_root .. "/truyenqq/fool-night/chapter-2.cbz",
    plugin_root .. "/truyenqq/giant-killing/chapter-1.cbz",
    fool_linked .. "/fool-night-chap-1.cbz",
    fool_linked .. "/fool-night-chap-1.sdr/metadata.cbz.lua",
    doro .. "/Dorohedoro v01.pdf",
    doro .. "/Dorohedoro v02.pdf",
    single,
    books .. "/UX Principles.sdr/metadata.pdf.lua",
    books .. "/Other.pdf",
}) do
    addFile(file)
end

local fool = {
    source_id = "truyenqq", title = "Fool Night",
    url = "https://truyenqq.test/truyen-tranh/fool-night", offline_dir = fool_linked,
}
local giant = {
    source_id = "truyenqq", title = "Giant Killing",
    url = "https://truyenqq.test/truyen-tranh/giant-killing",
}
local doro_story = { source_id = "local", kind = "local", title = "Dorohedoro", url = doro }
local single_story = { source_id = "local", kind = "local", title = "UX Principles", url = single }
local not_downloaded = {
    source_id = "truyenqq", title = "Chưa tải", url = "https://truyenqq.test/truyen-tranh/chua-tai",
}
settings.data.favorites = {}
for _, story in ipairs({ fool, giant, doro_story, single_story, not_downloaded }) do
    settings.data.favorites[story.source_id .. "|" .. story.url] = story
end

local protected = { plugin_root, "/sdcard/koreader", books, "/sdcard", "/storage/emulated/0" }

-- Bảo vệ đường dẫn
assertEqual(true, LocalLibrary.isProtected("/", protected), "Root is protected")
assertEqual(true, LocalLibrary.isProtected("", protected), "Empty path is protected")
assertEqual(true, LocalLibrary.isProtected("relative/dir", protected), "Relative path is protected")
assertEqual(true, LocalLibrary.isProtected(books .. "/../koreader", protected), "Dot-dot path is protected")
assertEqual(true, LocalLibrary.isProtected(books, protected), "Library root is protected")
assertEqual(true, LocalLibrary.isProtected(books .. "/", protected), "Trailing slash is protected")
assertEqual(true, LocalLibrary.isProtected("/storage", protected), "Ancestor of protected dir")
assertEqual(true, LocalLibrary.isProtected(plugin_root, protected), "Plugin root is protected")
assertEqual(false, LocalLibrary.isProtected(fool_linked, protected), "Story folder can be deleted")
assertEqual(false, LocalLibrary.isProtected(plugin_root .. "/truyenqq/fool-night", protected),
    "Plugin story dir can be deleted")

-- Đường dẫn của từng loại mục
local fool_targets = LocalLibrary.deleteTargets(fool)
assertEqual(2, #fool_targets, "Online story: plugin dir and linked dir")
assertEqual(plugin_root .. "/truyenqq/fool-night", fool_targets[1], "Plugin dir first")
assertEqual(fool_linked, fool_targets[2], "Linked dir second")
local single_targets = LocalLibrary.deleteTargets(single_story)
assertEqual(2, #single_targets, "Local file and its sidecar")
assertEqual(books .. "/UX Principles.sdr", single_targets[2], "Sidecar dir")
assertEqual(1, #LocalLibrary.deleteTargets(doro_story), "Local folder")
assertEqual(0, #LocalLibrary.deleteTargets(not_downloaded), "Nothing on device")

-- Story mở từ tìm kiếm không có offline_dir: tra Tủ truyện
local from_search = { source_id = fool.source_id, url = fool.url, title = fool.title }
assertEqual(2, #LocalLibrary.deleteTargets(from_search), "Linked dir found via favorites")

-- Gộp, bỏ trùng, bỏ đường dẫn con và đường dẫn được bảo vệ
local nested = { source_id = "local", kind = "local", title = "Manga", url = manga }
local targets, skipped = LocalLibrary.collectTargets({ fool, nested, from_search }, protected)
assertEqual(2, #targets, "Nested linked dir merged into parent")
assertEqual(manga, targets[1], "Parent folder kept")
assertEqual(0, #skipped, "Nothing protected")
local whole = { source_id = "local", kind = "local", title = "Books", url = books }
targets, skipped = LocalLibrary.collectTargets({ whole, single_story }, protected)
assertEqual(1, #skipped, "Library root skipped")
assertEqual(2, #targets, "Children of a protected dir are still deleted")
assertEqual(4, LocalLibrary.countFiles(LocalLibrary.collectTargets({ fool }, protected)), "File count")

-- Chỉ xóa khỏi Tủ truyện: giữ file, một lần lưu
local flushes = settings.flushes
local result = LocalLibrary.removeStories({ giant, doro_story }, { delete_files = false, protected = protected })
assertEqual(2, result.removed, "Two stories removed")
assertEqual(flushes + 1, settings.flushes, "Batch removal saves once")
assertEqual(nil, settings.data.favorites["truyenqq|" .. giant.url], "Giant Killing removed")
assertEqual(nil, settings.data.favorites["local|" .. doro], "Dorohedoro removed")
assertEqual(true, exists(plugin_root .. "/truyenqq/giant-killing/chapter-1.cbz"), "Download kept")
assertEqual(true, exists(doro .. "/Dorohedoro v01.pdf"), "Local folder kept")
assertEqual(0, result.deleted_files, "No files deleted")

-- Xóa cả file
result = LocalLibrary.removeStories({ fool, single_story, not_downloaded },
    { delete_files = true, protected = protected })
assertEqual(3, result.removed, "Three stories removed")
assertEqual(6, result.deleted_files, "Plugin, linked and sidecar files deleted")
assertEqual(0, #result.failed, "No failures")
assertEqual(false, exists(plugin_root .. "/truyenqq/fool-night"), "Plugin dir gone")
assertEqual(false, exists(fool_linked), "Linked dir gone")
assertEqual(false, exists(single), "Local file gone")
assertEqual(false, exists(books .. "/UX Principles.sdr"), "Sidecar gone")
assertEqual(true, exists(books .. "/Other.pdf"), "Neighbour file kept")
assertEqual(true, exists(manga), "Parent folder kept")
assertEqual(true, exists(plugin_root .. "/truyenqq"), "Source dir kept")
assertEqual(true, exists(plugin_root .. "/truyenqq/giant-killing"), "Other story kept")
assertEqual(nil, next(settings.data.favorites), "Tủ truyện is empty")

-- Thư mục được bảo vệ không bị xóa dù là mục "Trên máy"
settings.data.favorites["local|" .. books] = whole
result = LocalLibrary.removeStories({ whole }, { delete_files = true, protected = protected })
assertEqual(1, #result.skipped, "Protected library root reported")
assertEqual(true, exists(books .. "/Other.pdf"), "Library root content kept")

-- Chỉ xóa chương đã tải, giữ truyện trong Tủ truyện
local kingdom_dir = plugin_root .. "/truyenqq/kingdom"
local kingdom_linked = manga .. "/Kingdom"
local berserk_linked = manga .. "/Berserk"
for _, dir in ipairs({
    kingdom_dir, kingdom_dir .. "/chapter-1.sdr", kingdom_linked, kingdom_linked .. "/chuong-1.sdr",
    berserk_linked, plugin_root .. "/truyenqq/vinland",
}) do
    addDir(dir)
end
for _, file in ipairs({
    kingdom_dir .. "/chapter-1.cbz", kingdom_dir .. "/chapter-1.sdr/metadata.cbz.lua",
    kingdom_linked .. "/chuong-1.cbz", kingdom_linked .. "/chuong-1.sdr/metadata.cbz.lua",
    kingdom_linked .. "/chuong-2.cbz", kingdom_linked .. "/ghi-chu.txt",
    kingdom_linked .. "/chuong-1-tu-chep.html", berserk_linked .. "/chuong-1.cbz",
    plugin_root .. "/truyenqq/vinland/chapter-1.cbz",
}) do
    addFile(file)
end
local kingdom = {
    source_id = "truyenqq", title = "Kingdom",
    url = "https://truyenqq.test/truyen-tranh/kingdom", offline_dir = kingdom_linked,
}
local berserk = {
    source_id = "truyenqq", title = "Berserk",
    url = "https://truyenqq.test/truyen-tranh/berserk", offline_dir = berserk_linked,
}
local vinland = {
    source_id = "truyenqq", title = "Vinland", url = "https://truyenqq.test/truyen-tranh/vinland",
}
settings.data.favorites = {}
for _, story in ipairs({ kingdom, berserk, vinland, doro_story }) do
    settings.data.favorites[story.source_id .. "|" .. story.url] = story
end
local function names_for(story)
    if story == kingdom then
        return { "chuong-1.cbz", "chuong-2.cbz", "chuong-3.cbz", "../escape.cbz" }
    end
    return nil
end

local collected = LocalLibrary.collectDownloadTargets({ kingdom, berserk, doro_story }, protected, names_for)
assertEqual(1, #collected.stories, "Only Kingdom has downloads")
assertEqual(1, #collected.skipped_local, "Local story is skipped")
assertEqual(1, #collected.linked_without_index, "Berserk has no saved index")
assertEqual(5, LocalLibrary.countFiles(collected.targets), "Counted files match targets")

flushes = settings.flushes
result = LocalLibrary.removeDownloads({ kingdom, berserk, doro_story },
    { protected = protected, names_for = names_for })
assertEqual(1, result.stories, "One story cleaned")
assertEqual(5, result.deleted_files, "Plugin dir, plugin-named files and sidecar deleted")
assertEqual(0, #result.failed, "No failures")
assertEqual(1, result.skipped_local, "Local story reported")
assertEqual(1, #result.linked_kept, "Linked folder without index reported")
assertEqual(flushes, settings.flushes, "Tủ truyện is not rewritten")
assertEqual(kingdom, settings.data.favorites["truyenqq|" .. kingdom.url], "Kingdom stays in Tủ truyện")
assertEqual(false, exists(kingdom_dir), "Plugin download dir gone")
assertEqual(false, exists(kingdom_linked .. "/chuong-1.cbz"), "Plugin-named linked file gone")
assertEqual(false, exists(kingdom_linked .. "/chuong-1.sdr"), "Its sidecar gone")
assertEqual(false, exists(kingdom_linked .. "/chuong-2.cbz"), "Second plugin-named file gone")
assertEqual(true, exists(kingdom_linked), "Linked folder kept")
assertEqual(true, exists(kingdom_linked .. "/ghi-chu.txt"), "User note kept")
assertEqual(true, exists(kingdom_linked .. "/chuong-1-tu-chep.html"), "Differently named file kept")
assertEqual(true, exists(berserk_linked .. "/chuong-1.cbz"), "No index: linked files kept")
assertEqual(true, exists(doro .. "/Dorohedoro v01.pdf"), "Local story untouched")

result = LocalLibrary.removeDownloads({ vinland },
    { protected = { plugin_root .. "/truyenqq/vinland" }, names_for = names_for })
assertEqual(1, #result.skipped, "Protected download dir skipped")
assertEqual(true, exists(plugin_root .. "/truyenqq/vinland/chapter-1.cbz"), "Protected download kept")

print(string.format("Favorite removal tests passed: %d assertions", tests_run))
