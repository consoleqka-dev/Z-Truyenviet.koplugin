local Debug = require("truyenviet/debugger")
local LocalLibrary = require("truyenviet/local_library")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")
local lfs = require("libs/libkoreader-lfs")

-- "Thêm truyện trên máy vào Tủ truyện": quét thư mục plugin tải về và thư viện
-- sách (mặc định /sdcard/Books), ghép với truyện online, rồi trả danh sách để
-- người dùng xác nhận. Chỉ thêm hoặc bổ sung offline_dir, không xóa gì.
local LibraryImport = {
    skip_plugin_dirs = { cache = true, custom_sources = true },
    library_extensions = {
        azw3 = true, cbr = true, cbz = true, djvu = true,
        epub = true, fb2 = true, mobi = true, pdf = true,
    },
    default_library_dir = "/sdcard/Books",
    max_depth = 3,
}

local NOTE_NEW = "mới"
local NOTE_LINK = "gắn thư mục trên máy"
local NOTE_LOCAL = "trên máy"
LibraryImport.NOTE_NEW = NOTE_NEW
LibraryImport.NOTE_LINK = NOTE_LINK
LibraryImport.NOTE_LOCAL = NOTE_LOCAL

-- "darwin-jihen-21048" -> "darwin-jihen"
function LibraryImport.stripSuffix(slug)
    return (tostring(slug or ""):lower():gsub("%-%d+$", ""))
end

local function leafOf(url)
    return Util.urlLeaf(url, "story")
end

function LibraryImport.dedupeKey(source_id, url)
    if source_id == LocalLibrary.source_id then
        return source_id .. "|" .. tostring(url)
    end
    return source_id .. "|" .. LibraryImport.stripSuffix(leafOf(url))
end

-- Slug truyện từ tên file chương: "fool-night-12615-chap-19.cbz" -> "fool-night-12615".
function LibraryImport.fileSlug(name)
    local lower = tostring(name or ""):lower()
    for _, keyword in ipairs({ "chap", "chapter", "chuong" }) do
        local slug = lower:match("^(.-)%-" .. keyword .. "%-%d")
        if slug and slug ~= "" then
            return slug
        end
    end
    return nil
end

local function isHidden(name)
    return name:sub(1, 1) == "."
end

local function listDir(path)
    local entries = {}
    pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." and not isHidden(name) then
                table.insert(entries, name)
            end
        end
    end)
    table.sort(entries, Util.naturalCompare)
    return entries
end

local function isLibraryBook(name)
    local extension = name:match("%.([%w]+)$")
    return extension ~= nil and LibraryImport.library_extensions[extension:lower()] == true
end

-- Thư mục plugin: <root>/<source_id>/<slug>, tính cả thư mục rỗng.
function LibraryImport.scanPluginDirs(root, registry)
    local entries = {}
    for _, source_id in ipairs(listDir(root)) do
        local source_dir = root .. "/" .. source_id
        if not LibraryImport.skip_plugin_dirs[source_id]
                and lfs.attributes(source_dir, "mode") == "directory"
                and registry:get(source_id) then
            for _, slug in ipairs(listDir(source_dir)) do
                local dir = source_dir .. "/" .. slug
                if lfs.attributes(dir, "mode") == "directory" then
                    local count = 0
                    for _, name in ipairs(listDir(dir)) do
                        if Storage.isBookFile(name) then
                            count = count + 1
                        end
                    end
                    table.insert(entries, { source_id = source_id, slug = slug, dir = dir, count = count })
                end
            end
        end
    end
    return entries
end

-- Thư viện sách: thư mục chỉ chứa file sách là một bộ; file nằm cạnh thư mục
-- con (hoặc ở gốc) là truyện lẻ. Bỏ qua thư mục ẩn, .sdr và thư mục plugin.
function LibraryImport.scanLibrary(root, skip)
    skip = skip or {}
    local series, singles = {}, {}
    local function walk(dir, depth)
        local books, subdirs = {}, {}
        for _, name in ipairs(listDir(dir)) do
            local path = dir .. "/" .. name
            local mode = lfs.attributes(path, "mode")
            if mode == "file" and isLibraryBook(name) then
                table.insert(books, path)
            elseif mode == "directory" and not name:match("%.sdr$") and not skip[path] then
                table.insert(subdirs, path)
            end
        end
        if dir ~= root and #subdirs == 0 then
            if #books > 0 then
                table.insert(series, { dir = dir, books = books })
            end
            return
        end
        for _, path in ipairs(books) do
            table.insert(singles, path)
        end
        if depth < LibraryImport.max_depth then
            for _, path in ipairs(subdirs) do
                walk(path, depth + 1)
            end
        end
    end
    if lfs.attributes(root, "mode") == "directory" then
        walk(root, 0)
    end
    return series, singles
end

-- Danh sách truyện online đã biết (Tủ truyện trước, rồi lịch sử).
local function knownStories(ctx)
    local known = {}
    for _, story in ipairs(ctx.favorites) do
        table.insert(known, { story = story, favorite = true })
    end
    for _, item in ipairs(ctx.history) do
        table.insert(known, { story = item.story or item, favorite = false })
    end
    return known
end

local function findKnown(known, source_id, matches)
    for _, entry in ipairs(known) do
        if (not source_id or entry.story.source_id == source_id) and matches(leafOf(entry.story.url)) then
            return entry
        end
    end
end

local function searchSource(source, slug)
    if type(source.search) ~= "function" then
        return {}
    end
    local query = LibraryImport.stripSuffix(slug):gsub("%-", " ")
    local ok, results = pcall(source.search, source, query)
    if not ok or type(results) ~= "table" then
        Debug.write("[Nhập Tủ truyện] Lỗi tìm '" .. query .. "' trên " .. tostring(source.id)
            .. ": " .. tostring(results))
        return {}
    end
    return results
end

-- URL online cho thư mục plugin: Tủ truyện, lịch sử, tìm kiếm trên nguồn,
-- rồi so khớp sau khi bỏ hậu tố số. Trả về entry { story, favorite } hoặc nil.
function LibraryImport.resolvePluginEntry(entry, ctx, known)
    local exact = function(leaf) return leaf == entry.slug end
    local found = findKnown(known, entry.source_id, exact)
    if found then
        return found
    end
    local results = {}
    if ctx.search ~= false then
        local source = ctx.registry:get(entry.source_id)
        for _, story in ipairs(searchSource(source, entry.slug)) do
            if type(story) == "table" and type(story.url) == "string" then
                story.source_id = story.source_id or entry.source_id
                story.kind = story.kind or source.kind
                table.insert(results, { story = story, favorite = false })
            end
        end
        found = findKnown(results, entry.source_id, exact)
        if found then
            return found
        end
    end
    local stripped = LibraryImport.stripSuffix(entry.slug)
    local loose = function(leaf) return LibraryImport.stripSuffix(leaf) == stripped end
    return findKnown(known, entry.source_id, loose) or findKnown(results, entry.source_id, loose)
end

local function storyRecord(story)
    return {
        source_id = story.source_id,
        title = story.title,
        url = story.url,
        cover_url = story.cover_url,
        kind = story.kind,
        latest_chapter = story.latest_chapter,
        chapter_count = story.chapter_count,
        completed = story.completed,
    }
end

local function copyRecord(story)
    local record = {}
    for key, value in pairs(story) do
        record[key] = value
    end
    return record
end

local function baseName(path)
    return path:match("([^/]+)$") or path
end

-- Quét và ghép. ctx: { registry, favorites, history, plugin_root,
-- library_dirs, search }. Trả về { items, missing }:
--   items[i] = { record, note, label, selected }
--   missing[i] = { label, path }
function LibraryImport.collect(ctx)
    local known = knownStories(ctx)
    local seen = {}
    for _, story in ipairs(ctx.favorites) do
        seen[LibraryImport.dedupeKey(story.source_id, story.url)] = true
    end
    local items, missing = {}, {}
    -- Bản ghi mới hoặc bản ghi Tủ truyện được bổ sung offline_dir, theo khóa favorites.
    local pending = {}

    local function sourceName(source_id)
        if source_id == LocalLibrary.source_id then
            return LocalLibrary.source_name
        end
        local source = ctx.registry:get(source_id)
        return source and source.name or source_id
    end
    local function add(record, note)
        local key = LibraryImport.dedupeKey(record.source_id, record.url)
        if seen[key] then
            return false
        end
        seen[key] = true
        local item = {
            record = record,
            note = note,
            label = string.format("[%s] %s", sourceName(record.source_id), record.title),
            selected = true,
        }
        table.insert(items, item)
        pending[record.source_id .. "|" .. record.url] = item
        return true
    end

    -- 1. Thư mục plugin tải về
    for _, entry in ipairs(LibraryImport.scanPluginDirs(ctx.plugin_root, ctx.registry)) do
        local found = LibraryImport.resolvePluginEntry(entry, ctx, known)
        if not found then
            table.insert(missing, {
                label = string.format("[%s] %s (%d file)", sourceName(entry.source_id), entry.slug, entry.count),
                path = entry.dir,
            })
        elseif not found.favorite then
            add(storyRecord(found.story), NOTE_NEW)
        end
    end

    -- 2. Thư viện sách
    local skip = { [ctx.plugin_root] = true }
    for _, root in ipairs(ctx.library_dirs) do
        local series, singles = LibraryImport.scanLibrary(root, skip)
        for _, group in ipairs(series) do
            local slug = LibraryImport.fileSlug(baseName(group.books[1]))
            local stripped = slug and LibraryImport.stripSuffix(slug)
            local found = stripped and findKnown(known, nil, function(leaf)
                return LibraryImport.stripSuffix(leaf) == stripped
            end)
            if found then
                local key = found.story.source_id .. "|" .. found.story.url
                local record = pending[key] and pending[key].record
                if record then
                    record.offline_dir = group.dir
                    pending[key].note = NOTE_LINK
                elseif found.favorite then
                    if found.story.offline_dir ~= group.dir then
                        record = copyRecord(found.story)
                        record.offline_dir = group.dir
                        seen[LibraryImport.dedupeKey(record.source_id, record.url)] = nil
                        add(record, NOTE_LINK)
                    end
                else
                    record = storyRecord(found.story)
                    record.offline_dir = group.dir
                    add(record, NOTE_LINK)
                end
            else
                add({
                    source_id = LocalLibrary.source_id,
                    kind = "local",
                    url = group.dir,
                    title = LocalLibrary.displayName(baseName(group.dir)),
                }, NOTE_LOCAL)
            end
        end
        for _, path in ipairs(singles) do
            add({
                source_id = LocalLibrary.source_id,
                kind = "local",
                url = path,
                title = baseName(path):gsub("%.[%w]+$", ""),
            }, NOTE_LOCAL)
        end
    end
    return { items = items, missing = missing }
end

-- Ghi các mục được chọn vào Tủ truyện trong một lần lưu. Trả về các bản ghi đã ghi.
function LibraryImport.apply(items)
    local records = {}
    for _, item in ipairs(items) do
        if item.selected then
            table.insert(records, item.record)
        end
    end
    if #records == 0 then
        return records
    end
    local ok, err = Storage:mergeFavorites(records)
    if not ok then
        return nil, err
    end
    return records
end

-- Thư mục thư viện: setting local_library_dirs, home_dir của KOReader, rồi /sdcard/Books.
function LibraryImport.libraryDirs()
    local dirs = Storage.settings and Storage.settings:readSetting("local_library_dirs")
    if type(dirs) == "table" and #dirs > 0 then
        return dirs
    end
    local home = rawget(_G, "G_reader_settings") and G_reader_settings:readSetting("home_dir")
    if type(home) == "string" and home ~= "" then
        return { home }
    end
    return { LibraryImport.default_library_dir }
end

return LibraryImport
