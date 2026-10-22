local AsyncPool = require("truyenviet/async_pool")
local CoverCache = require("truyenviet/cover_cache")
local CoverFinder = require("truyenviet/cover_finder")
local Debug = require("truyenviet/debugger")
local Storage = require("truyenviet/storage")
local Util = require("truyenviet/helpers")
local lfs = require("libs/libkoreader-lfs")

-- Tủ truyện: mục "Trên máy" (source_id "local", url = đường dẫn tuyệt đối)
-- và làm mới số chương/bìa cho các mục online.
local LocalLibrary = {
    source_id = "local",
    source_name = "Trên máy",
    meta_ttl = 12 * 60 * 60,
    -- Mở Tủ truyện: chỉ làm mới vài mục, không chặn lâu.
    auto_meta_limit = 12,
    auto_cover_limit = 4,
    auto_deadline = 15,
    -- Lệnh "Tìm lại bìa lớn": chạy hết, tuần tự để WeebCentral không trả 429.
    full_deadline = 180,
}

function LocalLibrary.isLocal(story)
    return type(story) == "table" and story.source_id == LocalLibrary.source_id
end

-- "Fool Night - Seinen" -> "Fool Night"; phần sau " - " có tiếng Việt thì giữ cả.
function LocalLibrary.displayName(name)
    name = tostring(name or "")
    local head, rest = name:match("^(.-)%s+%-%s+(.+)$")
    if head and head ~= "" and not CoverFinder.hasVietnamese(rest) then
        return head
    end
    return name
end

-- "dir" cho thư mục, đuôi file viết thường cho file; nil khi không còn trên máy.
function LocalLibrary.entryType(path)
    local mode = lfs.attributes(path, "mode")
    if mode == "directory" then
        return "dir"
    elseif mode == "file" then
        return (tostring(path):match("%.([%w]+)$") or "file"):lower()
    end
    return nil
end

-- File sách trong thư mục (cả thư mục con một cấp), sắp theo tên tự nhiên.
function LocalLibrary.listBooks(dir)
    local books = {}
    local function scan(path, depth)
        local ok = pcall(function()
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." and not name:find("^%.") then
                    local full = path .. "/" .. name
                    local mode = lfs.attributes(full, "mode")
                    if mode == "file" and Storage.isBookFile(name) then
                        table.insert(books, full)
                    elseif mode == "directory" and depth < 1 and not name:match("%.sdr$") then
                        scan(full, depth + 1)
                    end
                end
            end
        end)
        return ok
    end
    scan(dir, 0)
    table.sort(books, function(left, right)
        return Util.naturalCompare(left:sub(#dir + 2), right:sub(#dir + 2))
    end)
    return books
end

-- File dùng để trích trang bìa: chính file, hoặc tập đầu trong thư mục.
function LocalLibrary.coverFile(story)
    local kind = LocalLibrary.entryType(story.url)
    if kind == "dir" then
        return LocalLibrary.listBooks(story.url)[1]
    end
    return kind and story.url or nil
end

-- Thêm số liệu hiển thị (không lưu) cho từng mục Tủ truyện.
function LocalLibrary.annotate(stories, registry)
    for _, story in ipairs(stories) do
        if LocalLibrary.isLocal(story) then
            story.source_name = LocalLibrary.source_name
            story.local_type = LocalLibrary.entryType(story.url) or "missing"
            if story.local_type == "dir" then
                story.offline_count = #LocalLibrary.listBooks(story.url)
            end
            story.size_bytes = LocalLibrary.storySize(story)
            story.cover_path = story.cover_path or CoverCache:get(story)
        else
            local source = registry:get(story.source_id)
            if source then
                story.source_name = source.name
            end
            story.offline_count = Storage:countOfflineChapters(story)
            story.size_bytes = LocalLibrary.storySize(story)
            story.cover_path = story.cover_path or CoverCache:get(story)
        end
    end
    return stories
end

local COVER_FIELDS = { "cover_url", "cover_source_id", "cover_found", "cover_time" }

-- Lịch sử đọc lưu bản chụp truyện lúc đọc; bìa tìm được sau đó chỉ nằm ở
-- Tủ truyện. Lấy bìa của mục Tủ truyện tương ứng (khi có) cho từng truyện.
function LocalLibrary.copyFavoriteCovers(stories, favorites)
    local by_key = {}
    for _, favorite in ipairs(favorites or {}) do
        if favorite.cover_url and favorite.cover_url ~= "" then
            by_key[tostring(favorite.source_id) .. "|" .. tostring(favorite.url)] = favorite
        end
    end
    local copied = 0
    for _, story in ipairs(stories) do
        local favorite = by_key[tostring(story.source_id) .. "|" .. tostring(story.url)]
        if favorite and favorite.cover_url ~= story.cover_url then
            for _, field in ipairs(COVER_FIELDS) do
                story[field] = favorite[field]
            end
            story.cover_path = nil
            copied = copied + 1
        end
    end
    return copied
end

-- Số chương lưu quá 12 giờ và nguồn có thể lấy lại.
function LocalLibrary.metaStale(story, now, registry)
    if LocalLibrary.isLocal(story) then
        return false
    end
    local source = registry and registry:get(story.source_id)
    if registry and not (source and type(source.fetchSearchMeta) == "function") then
        return false
    end
    return (tonumber(story.meta_time) or 0) + LocalLibrary.meta_ttl < (now or os.time())
end

-- Chưa có bìa và chưa thử tìm trong 12 giờ qua (tránh tìm lại mỗi lần mở).
function LocalLibrary.coverMissing(story, now)
    return not story.cover_found
        and (tonumber(story.cover_time) or 0) + LocalLibrary.meta_ttl < (now or os.time())
        and CoverCache:get(story) == nil
end

-- Tìm bìa cho các mục; trả về danh sách mục đã thử (cover_found khi tìm được).
function LocalLibrary.findCovers(stories, registry, opts)
    opts = opts or {}
    local changed = {}
    local tasks = {}
    for _, story in ipairs(stories) do
        if #tasks >= (opts.limit or math.huge) then
            break
        end
        table.insert(tasks, function()
            local local_file = LocalLibrary.isLocal(story) and LocalLibrary.coverFile(story)
                or (story.offline_dir and LocalLibrary.listBooks(story.offline_dir)[1])
            local found = CoverFinder:find(story, registry, {
                query = story.title,
                local_file = local_file,
            })
            story.cover_time = os.time()
            if found then
                story.cover_url = found.cover_url
                story.cover_source_id = found.cover_source_id
                story.cover_path = found.cover_path
                story.cover_found = true
            end
            table.insert(changed, story)
        end)
    end
    AsyncPool.run(tasks, { concurrency = 1, deadline = opts.deadline or LocalLibrary.full_deadline })
    return changed
end

-- Làm mới số chương (meta cũ hơn 12 giờ) và bìa còn thiếu, rồi lưu một lần.
-- opts.covers: danh sách mục cần tìm bìa (mặc định: mục chưa có bìa, giới hạn).
-- Trả về số mục đã cập nhật.
function LocalLibrary.refresh(stories, registry, opts)
    opts = opts or {}
    local SearchService = require("truyenviet/search_service")
    local now = os.time()
    local updated = {}
    local function mark(story)
        updated[story] = true
    end

    local stale = {}
    for _, story in ipairs(stories) do
        if LocalLibrary.metaStale(story, now, registry) then
            table.insert(stale, story)
        end
    end
    local covers = opts.covers
    if not covers then
        covers = {}
        local fast_mode = Storage.settings and Storage.settings:readSetting("fast_mode", false)
        if not fast_mode then
            for _, story in ipairs(stories) do
                if LocalLibrary.coverMissing(story, now) then
                    table.insert(covers, story)
                end
            end
        end
    end
    if #stale == 0 and #covers == 0 then
        return 0
    end

    local deadline = opts.deadline or LocalLibrary.auto_deadline
    local results = AsyncPool.run({
        function()
            if #stale > 0 then
                SearchService:enrichMeta(stale, {
                    registry = registry,
                    force = true,
                    limit = opts.meta_limit or LocalLibrary.auto_meta_limit,
                    deadline = deadline,
                    on_success = function(story)
                        story.meta_time = now
                        mark(story)
                    end,
                })
            end
        end,
        function()
            for _, story in ipairs(LocalLibrary.findCovers(covers, registry, {
                limit = opts.cover_limit or LocalLibrary.auto_cover_limit,
                deadline = deadline,
            })) do
                mark(story)
            end
        end,
    }, { concurrency = 2, deadline = deadline + 5 })
    for index, label in ipairs({ "làm mới số chương", "tìm bìa" }) do
        local entry = results[index]
        if entry and not entry.ok then
            Debug.write("[Tủ truyện] Lỗi khi " .. label .. ": " .. tostring(entry.values))
        end
    end

    local records = {}
    for _, story in ipairs(stories) do
        if updated[story] then
            table.insert(records, story)
        end
    end
    if #records > 0 then
        local ok, err = Storage:mergeFavorites(records)
        if not ok then
            Debug.write("[Tủ truyện] Không lưu được cập nhật: " .. tostring(err))
            return 0
        end
    end
    return #records
end

local function trimSlash(path)
    path = tostring(path or "")
    if #path > 1 then
        path = path:gsub("/+$", "")
    end
    return path
end

local function isUnder(path, parent)
    return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

-- Symlink chỉ xóa chính link, không đi vào thư mục đích.
local function linkMode(path)
    if lfs.symlinkattributes then
        return lfs.symlinkattributes(path, "mode")
    end
    return lfs.attributes(path, "mode")
end

-- Không xóa "/", đường dẫn tương đối hay có "..", và mọi thư mục bằng hoặc
-- chứa một thư mục được bảo vệ (gốc plugin, thư viện sách, /sdcard...).
function LocalLibrary.isProtected(path, protected)
    path = trimSlash(path)
    if path == "" or path == "/" or path:sub(1, 1) ~= "/"
            or path:find("/%.%.?/") or path:find("/%.%.?$") then
        return true
    end
    for _, dir in ipairs(protected or {}) do
        dir = trimSlash(dir)
        if dir ~= "" and isUnder(dir, path) then
            return true
        end
    end
    return false
end

-- Đường dẫn bị xóa khi chọn "xóa cả file" (chỉ những đường dẫn còn trên máy):
-- mục Trên máy là file (kèm thư mục .sdr) hoặc thư mục; truyện online là
-- thư mục plugin tải về và thư mục trên máy đã gắn (offline_dir).
-- Gọi trước khi xóa khỏi Tủ truyện vì getLinkedDir còn tra Tủ truyện.
function LocalLibrary.deleteTargets(story)
    local targets, seen = {}, {}
    local function add(path)
        path = type(path) == "string" and trimSlash(path) or ""
        if path ~= "" and not seen[path] and linkMode(path) then
            seen[path] = true
            table.insert(targets, path)
        end
    end
    if LocalLibrary.isLocal(story) then
        add(story.url)
        if LocalLibrary.entryType(story.url) ~= "dir" then
            local base = tostring(story.url):match("^(.*)%.[^./]+$")
            add(base and base .. ".sdr")
        end
    else
        add(Storage:getDownloadDir(story.source_id, story.url))
        add(Storage:getLinkedDir(story))
    end
    return targets
end

-- Bỏ trùng và bỏ đường dẫn nằm trong đường dẫn khác. Trả về targets (sẽ
-- xóa) và skipped (được bảo vệ, không xóa).
local function mergeTargets(all, protected)
    -- Đường dẫn ngắn trước để thư mục cha được giữ, thư mục con bị bỏ.
    table.sort(all, function(left, right)
        if #left ~= #right then
            return #left < #right
        end
        return left < right
    end)
    local targets, skipped, kept = {}, {}, {}
    for _, path in ipairs(all) do
        local nested = false
        for _, parent in ipairs(kept) do
            if isUnder(path, parent) then
                nested = true
                break
            end
        end
        if nested then
            -- Đã nằm trong một thư mục sẽ xóa.
        elseif LocalLibrary.isProtected(path, protected) then
            table.insert(skipped, path)
        else
            table.insert(kept, path)
            table.insert(targets, path)
        end
    end
    return targets, skipped
end

-- Gộp đường dẫn "xóa cả file" của nhiều truyện.
function LocalLibrary.collectTargets(stories, protected)
    local all = {}
    for _, story in ipairs(stories or {}) do
        for _, path in ipairs(LocalLibrary.deleteTargets(story)) do
            table.insert(all, path)
        end
    end
    return mergeTargets(all, protected)
end

-- Đích xóa khi chỉ xóa chương đã tải của truyện online: cả thư mục plugin
-- tải về; trong thư mục gắn ngoài chỉ file trùng đúng tên plugin đặt (kèm
-- thư mục .sdr), file người dùng tự chép vào được giữ.
-- names: tên file chương theo mục lục đã lưu, nil nếu chưa lưu.
-- Trả về paths, linked_without_index (có thư mục gắn ngoài mà thiếu names).
function LocalLibrary.downloadTargets(story, names)
    local paths, seen = {}, {}
    if LocalLibrary.isLocal(story) then
        return paths, false
    end
    local function add(path)
        if not seen[path] and linkMode(path) then
            seen[path] = true
            table.insert(paths, path)
        end
    end
    add(trimSlash(Storage:getDownloadDir(story.source_id, story.url)))
    local linked = Storage:getLinkedDir(story)
    if not linked then
        return paths, false
    end
    if type(names) ~= "table" then
        return paths, true
    end
    linked = trimSlash(linked)
    for _, name in ipairs(names) do
        if type(name) == "string" and name ~= "" and not name:find("/", 1, true) then
            local path = linked .. "/" .. name
            if linkMode(path) == "file" then
                add(path)
                local base = name:match("^(.*)%.[^.]+$")
                if base and base ~= "" then
                    add(linked .. "/" .. base .. ".sdr")
                end
            end
        end
    end
    return paths, false
end

-- Gộp đích "chỉ xóa chương đã tải" của nhiều truyện. names_for(story) trả về
-- tên file chương theo mục lục đã lưu (nil nếu chưa có).
function LocalLibrary.collectDownloadTargets(stories, protected, names_for)
    local all = {}
    local result = { stories = {}, skipped_local = {}, linked_without_index = {} }
    for _, story in ipairs(stories or {}) do
        if LocalLibrary.isLocal(story) then
            table.insert(result.skipped_local, story)
        else
            -- Chỉ tra mục lục đã lưu khi có thư mục gắn ngoài.
            local names = names_for and Storage:getLinkedDir(story) and names_for(story)
            local paths, no_index = LocalLibrary.downloadTargets(story, names or nil)
            if no_index then
                table.insert(result.linked_without_index, story)
            end
            if #paths > 0 then
                table.insert(result.stories, story)
            end
            for _, path in ipairs(paths) do
                table.insert(all, path)
            end
        end
    end
    result.targets, result.skipped_protected = mergeTargets(all, protected)
    return result
end

-- Số file (không tính thư mục) trong các đường dẫn.
function LocalLibrary.countFiles(paths)
    local count = 0
    local function walk(path)
        local mode = linkMode(path)
        if mode == "directory" then
            pcall(function()
                for name in lfs.dir(path) do
                    if name ~= "." and name ~= ".." then
                        walk(path .. "/" .. name)
                    end
                end
            end)
        elseif mode then
            count = count + 1
        end
    end
    for _, path in ipairs(paths or {}) do
        walk(path)
    end
    return count
end

-- Tổng dung lượng (byte) của các đường dẫn; symlink chỉ tính chính link.
function LocalLibrary.sizeOf(paths)
    local total = 0
    local function walk(path)
        local mode = linkMode(path)
        if mode == "directory" then
            pcall(function()
                for name in lfs.dir(path) do
                    if name ~= "." and name ~= ".." then
                        walk(path .. "/" .. name)
                    end
                end
            end)
        elseif mode == "file" then
            total = total + (tonumber(lfs.attributes(path, "size")) or 0)
        end
    end
    for _, path in ipairs(paths or {}) do
        walk(path)
    end
    return total
end

-- Dung lượng thư mục nhớ trong phiên: dùng lại khi thời điểm sửa của thư mục
-- và của các thư mục con trực tiếp không đổi (thêm/xóa file ở hai cấp đó làm
-- đổi thời điểm sửa). File thêm vào sâu hơn chỉ được tính sau khi khởi động lại.
local size_cache = {}

function LocalLibrary.sizeOfCached(path)
    if linkMode(path) ~= "directory" then
        return LocalLibrary.sizeOf({ path })
    end
    local modified = lfs.attributes(path, "modification")
    local entry = size_cache[path]
    if entry and entry.modified == modified then
        local fresh = true
        for subdir, sub_modified in pairs(entry.subdirs) do
            if lfs.attributes(subdir, "modification") ~= sub_modified then
                fresh = false
                break
            end
        end
        if fresh then
            return entry.bytes
        end
    end
    local subdirs = {}
    pcall(function()
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                local child = path .. "/" .. name
                if linkMode(child) == "directory" then
                    subdirs[child] = lfs.attributes(child, "modification")
                end
            end
        end
    end)
    local bytes = LocalLibrary.sizeOf({ path })
    size_cache[path] = { modified = modified, subdirs = subdirs, bytes = bytes }
    return bytes
end

-- Quên dung lượng đã nhớ của các đường dẫn, đường dẫn con và thư mục cha.
function LocalLibrary.forgetSizes(paths)
    for cached in pairs(size_cache) do
        for _, path in ipairs(paths or {}) do
            path = trimSlash(path)
            if isUnder(cached, path) or isUnder(path, cached) then
                size_cache[cached] = nil
                break
            end
        end
    end
end

-- 1234567 -> "1,2 MB" (dấu phẩy thập phân).
function LocalLibrary.formatSize(bytes)
    bytes = tonumber(bytes) or 0
    local units = { "B", "KB", "MB", "GB", "TB" }
    local index = 1
    while bytes >= 1024 and index < #units do
        bytes = bytes / 1024
        index = index + 1
    end
    local text
    if index == 1 or bytes >= 100 then
        text = string.format("%d", math.floor(bytes + 0.5))
    else
        text = string.format("%.1f", bytes):gsub("%.0$", ""):gsub("%.", ",")
    end
    return text .. " " .. units[index]
end

-- Dung lượng các file của truyện (cùng các đường dẫn "xóa cả file" sẽ xóa).
function LocalLibrary.storySize(story)
    local total = 0
    for _, path in ipairs((LocalLibrary.collectTargets({ story }))) do
        total = total + LocalLibrary.sizeOfCached(path)
    end
    return total
end

-- /storage/emulated/0/... và /sdcard/... là cùng một chỗ trên Android.
local function pathAliases(path)
    path = trimSlash(path)
    local aliases = { path }
    for _, pair in ipairs({ { "/storage/emulated/0", "/sdcard" }, { "/sdcard", "/storage/emulated/0" } }) do
        if isUnder(path, pair[1]) then
            table.insert(aliases, pair[2] .. path:sub(#pair[1] + 1))
        end
    end
    return aliases
end

-- Mục "Trên máy" chứa file đang mở: chính file đó hoặc thư mục cha của nó.
-- Ưu tiên mục có đường dẫn dài nhất (thư mục con khớp trước thư mục cha).
function LocalLibrary.findOwner(path, favorites)
    if type(path) ~= "string" or path == "" then
        return nil
    end
    local aliases = pathAliases(path)
    local owner, owner_len
    for _, story in ipairs(favorites or {}) do
        if LocalLibrary.isLocal(story) and type(story.url) == "string" then
            local url = trimSlash(story.url)
            for _, candidate in ipairs(aliases) do
                for _, alias in ipairs(pathAliases(url)) do
                    if alias ~= "" and alias ~= "/" and isUnder(candidate, alias)
                            and (not owner_len or #url > owner_len) then
                        owner, owner_len = story, #url
                    end
                end
            end
        end
    end
    return owner
end

-- Ghi Lịch sử đọc khi mở một file thuộc mục "Trên máy" (từ Tủ truyện, File
-- manager hay lịch sử của KOReader). chapter.url là file đang đọc.
function LocalLibrary.recordRead(path)
    local owner = LocalLibrary.findOwner(path, Storage:listFavorites())
    if not owner then
        return false
    end
    local title = tostring(path):match("([^/]+)$") or tostring(path)
    title = title:gsub("%.[^.]+$", "")
    return Storage:saveHistory(owner, { title = title, url = path }) == true
end

-- Xóa đệ quy; trả về số file đã xóa và danh sách đường dẫn không xóa được.
local function removeTree(path, failed)
    local deleted = 0
    if linkMode(path) == "directory" then
        local names = {}
        pcall(function()
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then
                    table.insert(names, name)
                end
            end
        end)
        for _, name in ipairs(names) do
            deleted = deleted + removeTree(path .. "/" .. name, failed)
        end
        local ok = lfs.rmdir(path)
        if not ok then
            table.insert(failed, path)
        end
    elseif linkMode(path) then
        if os.remove(path) then
            deleted = deleted + 1
        else
            table.insert(failed, path)
        end
    end
    return deleted
end

-- Xóa các truyện khỏi Tủ truyện (một lần lưu). opts.delete_files: xóa luôn
-- file theo collectTargets, bỏ qua đường dẫn trong opts.protected.
-- Trả về { removed, deleted_files, skipped, failed } hoặc nil, lỗi.
function LocalLibrary.removeStories(stories, opts)
    opts = opts or {}
    local targets, skipped = {}, {}
    if opts.delete_files then
        targets, skipped = LocalLibrary.collectTargets(stories, opts.protected)
    end
    local ok, err = Storage:removeFavorites(stories)
    if not ok then
        return nil, err
    end
    local result = { removed = #stories, deleted_files = 0, skipped = skipped, failed = {} }
    for _, path in ipairs(targets) do
        result.deleted_files = result.deleted_files + removeTree(path, result.failed)
    end
    LocalLibrary.forgetSizes(targets)
    if #result.failed > 0 or #skipped > 0 then
        Debug.write(string.format("[Tủ truyện] Xóa file: %d lỗi, %d bỏ qua",
            #result.failed, #skipped))
    end
    return result
end

-- Xóa chương đã tải nhưng giữ truyện trong Tủ truyện (không ghi settings).
-- opts.protected, opts.names_for như collectDownloadTargets.
-- Trả về { stories, deleted_files, failed, skipped, skipped_local, linked_kept }.
function LocalLibrary.removeDownloads(stories, opts)
    opts = opts or {}
    local collected = LocalLibrary.collectDownloadTargets(stories, opts.protected, opts.names_for)
    local result = {
        stories = #collected.stories,
        deleted_files = 0,
        failed = {},
        skipped = collected.skipped_protected,
        skipped_local = #collected.skipped_local,
        linked_kept = collected.linked_without_index,
    }
    for _, path in ipairs(collected.targets) do
        result.deleted_files = result.deleted_files + removeTree(path, result.failed)
    end
    LocalLibrary.forgetSizes(collected.targets)
    Debug.write(string.format("[Tủ truyện] Xóa chương đã tải: %d file, %d lỗi, %d bỏ qua",
        result.deleted_files, #result.failed, #result.skipped))
    return result
end

return LocalLibrary
