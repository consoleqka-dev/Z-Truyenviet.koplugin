local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Hệ thống file giả giống máy đọc: thư mục plugin và /sdcard/Books.
local fs = {}
local function addDir(path)
    fs[path] = { mode = "directory", modification = 1 }
end
local function addFile(path)
    fs[path] = { mode = "file", modification = 1 }
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
        getFullDataDir = function() return "/ko" end,
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
    return {
        hasVietnamese = function(text)
            return tostring(text):find("[\128-\255]") ~= nil
        end,
    }
end
package.preload["truyenviet/async_pool"] = function()
    return { run = function() return {} end }
end

local LibraryImport = require("truyenviet/library_import")
local LocalLibrary = require("truyenviet/local_library")
local Storage = require("truyenviet/storage")
local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

-- Hàm thuần
assertEqual("darwin-jihen", LibraryImport.stripSuffix("darwin-jihen-21048"), "Strip numeric suffix")
assertEqual("fool-night-12615", LibraryImport.fileSlug("fool-night-12615-chap-19.cbz"), "File slug")
assertEqual(nil, LibraryImport.fileSlug("Dorohedoro v01 (2010).pdf"), "No slug in volume name")
assertEqual("Dorohedoro", LocalLibrary.displayName("Dorohedoro - Seinen - Horror"), "Display name")
assertEqual("Yugo - Kẻ Thương Thuyết", LocalLibrary.displayName("Yugo - Kẻ Thương Thuyết"),
    "Vietnamese subtitle is kept")

-- Thư mục plugin
local plugin_root = "/ko/truyenviet"
for _, dir in ipairs({
    "/ko", plugin_root, plugin_root .. "/cache", plugin_root .. "/custom_sources", plugin_root .. "/oldsource",
    plugin_root .. "/truyenqq", plugin_root .. "/zettruyen", plugin_root .. "/aztruyen", plugin_root .. "/weebcentral",
    plugin_root .. "/truyenqq/giant-killing", plugin_root .. "/truyenqq/darwin-jihen",
    plugin_root .. "/truyenqq/darwin-jihen-21048", plugin_root .. "/truyenqq/ngoai-truyen-x-18110",
    plugin_root .. "/zettruyen/crows", plugin_root .. "/aztruyen/crows-zero-413813444",
    plugin_root .. "/weebcentral/Diamond-No-Ace", plugin_root .. "/oldsource/gone",
}) do
    addDir(dir)
end
addFile(plugin_root .. "/truyenqq/giant-killing/chapter-1.cbz")
addFile(plugin_root .. "/truyenqq/giant-killing/chapter-2.cbz")
addFile(plugin_root .. "/zettruyen/crows/chapter-1.cbz")
addFile(plugin_root .. "/weebcentral/Diamond-No-Ace/chapter-1.cbz")

-- Thư viện /sdcard/Books
local books = "/sdcard/Books"
local manga = books .. "/Manga"
local fool = manga .. "/Fool Night - Seinen Psychology - Tree"
local yugo = manga .. "/Yugo - Kẻ Thương Thuyết"
local doro = manga .. "/Dorohedoro - Seinen - Horror"
for _, dir in ipairs({ "/sdcard", books, manga, fool, yugo, doro, manga .. "/Empty",
    fool .. "/fool-night-12615-chap-1.sdr", books .. "/.hidden" }) do
    addDir(dir)
end
addFile(fool .. "/fool-night-12615-chap-1.cbz")
addFile(fool .. "/fool-night-12615-chap-2.cbz")
addFile(yugo .. "/yugo-ke-thuong-thuyet-3216-chap-1.cbz")
addFile(doro .. "/Dorohedoro v01 (2010).pdf")
addFile(doro .. "/Dorohedoro v02 (2010).pdf")
addFile(manga .. "/Usogui - Sako Toshio - Seinen - Gambling.cbz")
addFile(books .. "/UX Principles.pdf")
addFile(books .. "/notes.docx")
addFile(books .. "/.hidden/secret.pdf")

local sources = {}
local search_queries = {}
for _, id in ipairs({ "truyenqq", "zettruyen", "aztruyen", "weebcentral" }) do
    sources[id] = { id = id, name = id, kind = "comic" }
end
sources.aztruyen.search = function(_, query)
    table.insert(search_queries, query)
    return { { title = "Crows Zero", url = "https://aztruyen.test/truyen/crows-zero-413813444" } }
end
sources.truyenqq.search = function(_, query)
    table.insert(search_queries, query)
    return {}
end
local registry = { get = function(_, id) return sources[id] end }

settings.data.favorites = {
    ["truyenqq|https://truyenqq.test/truyen-tranh/darwin-jihen"] = {
        source_id = "truyenqq", title = "Darwin Jihen", url = "https://truyenqq.test/truyen-tranh/darwin-jihen",
    },
    ["truyenqq|https://truyenqq.test/truyen-tranh/fool-night"] = {
        source_id = "truyenqq", title = "Fool Night", url = "https://truyenqq.test/truyen-tranh/fool-night",
        cover_url = "https://img/fool.jpg", latest_chapter = 83,
    },
}
settings.data.history = {
    { story = { source_id = "truyenqq", title = "Giant Killing", url = "https://truyenqq.test/truyen-tranh/giant-killing" },
        chapter = { title = "1", url = "c1" } },
    { story = { source_id = "zettruyen", title = "Crows", url = "https://zettruyen.test/truyen/crows" },
        chapter = { title = "1", url = "c1" } },
    { story = { source_id = "weebcentral", title = "Diamond no Ace",
        url = "https://weebcentral.com/series/01J76XY7PHMCR5ZPE547BAM412/Diamond-No-Ace" },
        chapter = { title = "1", url = "c1" } },
    { story = { source_id = "truyenqq", title = "Yugo - Kẻ Thương Thuyết",
        url = "https://truyenqq.test/truyen-tranh/yugo-ke-thuong-thuyet-3216" },
        chapter = { title = "1", url = "c1" } },
}

local function context()
    return {
        registry = registry,
        favorites = Storage:listFavorites(),
        history = Storage:getHistory(),
        plugin_root = plugin_root,
        library_dirs = { books },
        search = true,
    }
end

local result = LibraryImport.collect(context())
local by_title = {}
for _, item in ipairs(result.items) do
    by_title[item.record.title] = item
end

assertEqual(LibraryImport.NOTE_NEW, by_title["Giant Killing"] and by_title["Giant Killing"].note,
    "Plugin dir matched from history")
assertEqual("https://zettruyen.test/truyen/crows", by_title["Crows"] and by_title["Crows"].record.url,
    "Zettruyen from history")
assertEqual("https://aztruyen.test/truyen/crows-zero-413813444",
    by_title["Crows Zero"] and by_title["Crows Zero"].record.url, "Empty dir matched by source search")
assertEqual("crows zero", search_queries[1], "Search query from slug")
assertEqual(true, by_title["Diamond no Ace"] ~= nil, "WeebCentral dir from history")
assertEqual(nil, by_title["Darwin Jihen"], "Existing favorite is not re-added")

local fool_item = by_title["Fool Night"]
assertEqual(LibraryImport.NOTE_LINK, fool_item and fool_item.note, "Fool Night folder links to favorite")
assertEqual(fool, fool_item.record.offline_dir, "Linked dir stored")
assertEqual(83, fool_item.record.latest_chapter, "Linked favorite keeps its fields")
local yugo_item = by_title["Yugo - Kẻ Thương Thuyết"]
assertEqual(yugo, yugo_item and yugo_item.record.offline_dir, "Yugo links to history story")
assertEqual("truyenqq", yugo_item.record.source_id, "Yugo stays a truyenqq entry")

local doro_item = by_title["Dorohedoro"]
assertEqual(LibraryImport.NOTE_LOCAL, doro_item and doro_item.note, "Unmatched folder is a local entry")
assertEqual("local", doro_item.record.source_id, "Local source id")
assertEqual(doro, doro_item.record.url, "Local url is the folder")
assertEqual(true, by_title["Usogui - Sako Toshio - Seinen - Gambling"] ~= nil, "Loose file beside folders")
assertEqual(true, by_title["UX Principles"] ~= nil, "Loose file in library root")
assertEqual(nil, by_title["secret"], "Hidden folder skipped")
assertEqual(nil, by_title["notes"], "Non-book file skipped")
assertEqual(nil, by_title["Empty"], "Empty library folder skipped")

-- Thư mục rỗng không ghép được (ngoại truyện) và nguồn lạ
assertEqual(1, #result.missing, "One unmatched plugin dir")
assertEqual(plugin_root .. "/truyenqq/ngoai-truyen-x-18110", result.missing[1].path, "Unmatched dir listed")
for _, item in ipairs(result.items) do
    assertEqual(false, item.record.url:find("oldsource", 1, true) ~= nil, "Unknown source skipped")
end

-- Không trùng: darwin-jihen-21048 không tạo mục mới
local count = 0
for _, item in ipairs(result.items) do
    if item.record.title:find("Darwin") then
        count = count + 1
    end
end
assertEqual(0, count, "Numeric-suffix duplicate is dropped")
assertEqual(9, #result.items, "Total candidates")

-- Bỏ chọn rồi ghi; chạy lại không thêm gì
by_title["UX Principles"].selected = false
local written = LibraryImport.apply(result.items)
assertEqual(8, #written, "Only selected items written")
local favorites = settings.data.favorites
assertEqual(fool, favorites["truyenqq|https://truyenqq.test/truyen-tranh/fool-night"].offline_dir,
    "Favorite now has offline_dir")
assertEqual("https://img/fool.jpg", favorites["truyenqq|https://truyenqq.test/truyen-tranh/fool-night"].cover_url,
    "Favorite cover kept")
assertEqual(true, favorites["local|" .. doro] ~= nil, "Local entry stored under local|path")

local again = LibraryImport.collect(context())
assertEqual(1, #again.items, "Second run only offers the unselected file")
assertEqual("UX Principles", again.items[1].record.title, "Unselected item offered again")

print(string.format("Library import tests passed: %d assertions", tests_run))
