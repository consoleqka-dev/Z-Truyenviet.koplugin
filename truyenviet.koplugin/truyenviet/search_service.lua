local AsyncPool = require("truyenviet/async_pool")
local Util = require("truyenviet/helpers")

-- Debugger kéo theo Storage/KOReader; nạp an toàn để module vẫn dùng được
-- trong môi trường test không có các module đó.
local ok_debug, Debug = pcall(require, "truyenviet/debugger")
local function log(message)
    if ok_debug and type(Debug) == "table" and type(Debug.write) == "function" then
        pcall(Debug.write, message)
    end
end

local SearchService = {
    -- Hạn chót cho cả lượt tìm (giây) và số nguồn chạy đồng thời
    search_deadline = 15,
    search_concurrency = 6,
    -- Cache kết quả theo phiên: TTL (giây) và số entry tối đa
    cache_ttl = 600,
    cache_max_entries = 30,
    -- Bổ sung số chương/trạng thái cho kết quả
    meta_limit = 12,
    meta_deadline = 8,
    meta_concurrency = 6,
    meta_per_source = 2,
    meta_cache_max_entries = 500,
}

-- result_cache[key] = { time = os.time(), stories = { ...bản sao nông... } }
local result_cache = {}
-- meta_cache[story.url] = { latest_chapter = n|nil, chapter_count = n|nil, completed = bool|nil }
local meta_cache = {}
local meta_cache_size = 0

-- Bản sao nông từng story: SearchService gán source_name/search_score và UI gán
-- cover_path/chapter_count lên chính các bảng này, nên cache không được giữ
-- chung tham chiếu với danh sách trả về cho UI.
local function copyStories(stories)
    local copy = {}
    for index, story in ipairs(stories) do
        if type(story) == "table" then
            local story_copy = {}
            for key, value in pairs(story) do
                story_copy[key] = value
            end
            copy[index] = story_copy
        else
            copy[index] = story
        end
    end
    return copy
end

local function cacheKey(source, query)
    return tostring(source.id) .. "\0" .. tostring(source.base_url or "") .. "\0" .. query
end

local function cacheGet(key)
    local entry = result_cache[key]
    if not entry then
        return nil
    end
    if os.time() - entry.time > SearchService.cache_ttl then
        result_cache[key] = nil
        return nil
    end
    return copyStories(entry.stories)
end

local function cachePut(key, stories)
    result_cache[key] = { time = os.time(), stories = copyStories(stories) }
    local count = 0
    local oldest_key, oldest_time
    for entry_key, entry in pairs(result_cache) do
        count = count + 1
        if entry_key ~= key and (not oldest_time or entry.time < oldest_time) then
            oldest_key, oldest_time = entry_key, entry.time
        end
    end
    if count > SearchService.cache_max_entries and oldest_key then
        result_cache[oldest_key] = nil
    end
end

function SearchService:clearCache()
    result_cache = {}
    meta_cache = {}
    meta_cache_size = 0
end

-- Đếm số lượng truyện thực tế (loại trừ các thông báo lỗi Parse giả)
local function countValid(stories)
    local valid_count = 0
    if type(stories) == "table" then
        for _, story in ipairs(stories) do
            if type(story) == "table" and type(story.title) == "string" and not story.title:find("^Lỗi Parse") then
                valid_count = valid_count + 1
            end
        end
    end
    return valid_count
end

-- Tìm trên một nguồn; trả về ok, stories, err như pcall(source.search).
local function runSourceSearch(source, query, unaccented_query)
    local ok, stories, err = pcall(source.search, source, query)
    local valid_count = countValid(stories)

    -- Nếu tìm theo từ có dấu không ra kết quả, thử lại với từ không dấu
    if ok and valid_count == 0 and unaccented_query ~= query then
        local ok2, stories2, err2 = pcall(source.search, source, unaccented_query)
        if ok2 and type(stories2) == "table" and #stories2 > 0 then
            ok, stories, err = ok2, stories2, err2
        end
    end
    return ok, stories, err
end

local function sourceLabel(source)
    return tostring(source.name or source.id or "Nguồn")
end

-- Văn bản lỗi của một lượt tìm trên nguồn (nil nếu thành công).
local function outcomeError(outcome)
    if not outcome.ok then
        return tostring(outcome.stories)
    end
    if type(outcome.stories) ~= "table" then
        local source_error = outcome.err
        if not source_error and type(outcome.stories) == "string" then
            source_error = outcome.stories
        end
        return tostring(source_error or "Lỗi không xác định")
    end
    return nil
end

local TLS_ERROR_PATTERNS = { "handshake", "wantread", "wantwrite", "ssl", "tls", "certificate" }

-- Lỗi do TLS/handshake (không phải timeout): đường async của copas có thể
-- không xử lý được, còn đường đồng bộ (luasec/curl) thì thường qua được.
local function isTlsFailure(error_text)
    local lowered = tostring(error_text):lower()
    if lowered:find("timeout", 1, true) or lowered:find("quá thời gian", 1, true) then
        return false
    end
    for _, pattern in ipairs(TLS_ERROR_PATTERNS) do
        if lowered:find(pattern, 1, true) then
            return true
        end
    end
    return false
end

function SearchService:search(query, sources)
    query = Util.trim(query or "")
    local results = {}
    local errors = {}
    local seen = {}
    local unaccented_query = Util.removeAccents(query)
    if query == "" then
        return results, { "Từ khóa tìm kiếm không được để trống" }
    end

    local started_at = os.time()
    -- outcomes[source_index] = { ok, stories, err, timed_out, key, from_cache }
    local outcomes = {}
    local tasks = {}
    local task_source_index = {}
    for source_index, source in ipairs(sources) do
        if type(source.search) == "function" then
            local key = cacheKey(source, query)
            local cached = cacheGet(key)
            if cached then
                outcomes[source_index] = { ok = true, stories = cached, from_cache = true }
            else
                outcomes[source_index] = { key = key }
                table.insert(tasks, function()
                    return runSourceSearch(source, query, unaccented_query)
                end)
                task_source_index[#tasks] = source_index
            end
        end
    end

    local deadline = self.search_deadline
    local pool_results = AsyncPool.run(tasks, {
        concurrency = self.search_concurrency,
        deadline = deadline,
    })
    for task_index, entry in ipairs(pool_results) do
        local outcome = outcomes[task_source_index[task_index]]
        if not entry.done then
            outcome.timed_out = true
        elseif not entry.ok then
            outcome.ok, outcome.stories = false, entry.values
        else
            outcome.ok = entry.values[1]
            outcome.stories = entry.values[2]
            outcome.err = entry.values[3]
        end
    end

    -- Thử lại tuần tự (ngoài pool, có curl/force_luasec) cho nguồn lỗi TLS.
    -- Chỉ làm khi có đúng một nguồn như vậy và còn thời gian, để một lượt tìm
    -- không bị kéo dài bởi nhiều request chặn.
    if not AsyncPool.inPoolThread() and os.time() - started_at < deadline then
        local tls_failed = {}
        for source_index, outcome in pairs(outcomes) do
            if not outcome.from_cache and not outcome.timed_out then
                local error_text = outcomeError(outcome)
                if error_text and isTlsFailure(error_text) then
                    table.insert(tls_failed, source_index)
                end
            end
        end
        if #tls_failed == 1 then
            local source_index = tls_failed[1]
            local source = sources[source_index]
            log(string.format("[Search] Thử lại tuần tự nguồn %s sau lỗi TLS", sourceLabel(source)))
            local ok, stories, err = runSourceSearch(source, query, unaccented_query)
            if ok and type(stories) == "table" then
                local outcome = outcomes[source_index]
                outcome.ok, outcome.stories, outcome.err = ok, stories, err
            end
        end
    end

    -- Lưu cache các lượt tìm có kết quả thật (trước khi bước gộp gán thêm trường)
    for _, outcome in pairs(outcomes) do
        if outcome.key and not outcome.timed_out and outcome.ok
                and countValid(outcome.stories) > 0 then
            cachePut(outcome.key, outcome.stories)
        end
    end

    -- Gộp theo đúng thứ tự nguồn gốc để dedup/điểm số không phụ thuộc nguồn nào xong trước
    for source_index, source in ipairs(sources) do
        local outcome = outcomes[source_index]
        if outcome then
            local stories = outcome.stories
            if outcome.timed_out then
                log(string.format("[Search] Nguồn %s quá thời gian %ss", sourceLabel(source), tostring(deadline)))
                table.insert(
                    errors,
                    sourceLabel(source)
                        .. ": quá thời gian (" .. tostring(deadline) .. "s)"
                )
            elseif not outcome.ok then
                table.insert(
                    errors,
                    sourceLabel(source)
                        .. ": " .. tostring(stories)
                )
            elseif type(stories) ~= "table" then
                table.insert(errors, sourceLabel(source) .. ": " .. outcomeError(outcome))
            else
                for result_index, story in ipairs(stories) do
                    if type(story) == "table"
                            and type(story.source_id) == "string"
                            and story.source_id ~= ""
                            and type(story.url) == "string"
                            and story.url ~= ""
                            and type(story.title) == "string"
                            and story.title ~= ""
                            and not story.title:find("^Lỗi Parse") then
                        local key = story.source_id .. "|" .. story.url
                        if not seen[key] then
                            seen[key] = true
                            story.source_name = source.name
                            story.search_score = Util.searchScore(
                                query,
                                story.title,
                                result_index + (source_index - 1) * 100
                            )
                            table.insert(results, story)
                        end
                    end
                end
            end
        end
    end

    table.sort(results, function(left, right)
        if left.search_score ~= right.search_score then
            return left.search_score > right.search_score
        end
        local left_title = Util.normalizeSearch(left.title)
        local right_title = Util.normalizeSearch(right.title)
        if left_title ~= right_title then
            return left_title < right_title
        end
        return left.source_id < right.source_id
    end)

    return results, errors
end

-- Chỉ nhận số chương là số > 0 và completed là boolean. latest_chapter giữ
-- phần thập phân (vd chương 12.5).
local function validateMeta(meta)
    local entry = {}
    local latest = tonumber(meta.latest_chapter)
    if latest and latest > 0 then
        entry.latest_chapter = latest
    end
    local count = tonumber(meta.chapter_count)
    if count then
        count = math.floor(count)
        if count > 0 then
            entry.chapter_count = count
        end
    end
    if type(meta.completed) == "boolean" then
        entry.completed = meta.completed
    end
    return entry
end

local function applyMeta(story, entry)
    if entry.latest_chapter then
        story.latest_chapter = entry.latest_chapter
    end
    if entry.chapter_count then
        story.chapter_count = entry.chapter_count
    end
    if entry.completed ~= nil then
        story.completed = entry.completed
    end
end

local function putMetaCache(url, entry)
    if meta_cache[url] == nil then
        if meta_cache_size >= SearchService.meta_cache_max_entries then
            meta_cache = {}
            meta_cache_size = 0
        end
        meta_cache_size = meta_cache_size + 1
    end
    meta_cache[url] = entry
end

local function hasLatestChapter(story)
    local latest = tonumber(story.latest_chapter)
    return latest ~= nil and latest > 0
end

-- Bổ sung latest_chapter/chapter_count/completed cho các truyện đầu danh sách còn thiếu bằng
-- Source:fetchSearchMeta (nếu nguồn có). Gọi lồng an toàn trong AsyncPool.
-- opts.registry: đối tượng có :get(source_id) (mặc định SourceRegistry),
-- opts.limit (12), opts.deadline (8s), opts.concurrency (6).
-- opts.force: lấy lại cả truyện đã đủ meta (Tủ truyện làm mới định kỳ);
-- opts.on_success(story): gọi khi truyện nhận được meta hợp lệ.
-- Giá trị hợp lệ lấy từ fetchSearchMeta được coi là chính xác hơn nên ghi đè.
-- Trả về chính danh sách `stories` (đã sửa tại chỗ).
function SearchService:enrichMeta(stories, opts)
    opts = opts or {}
    if type(stories) ~= "table" or #stories == 0 then
        return stories
    end

    local registry = opts.registry
    if not registry then
        local ok, loaded = pcall(require, "truyenviet/source_registry")
        if not ok then
            log("[Meta] Không nạp được source_registry: " .. tostring(loaded))
            return stories
        end
        registry = loaded
    end

    local limit = tonumber(opts.limit) or self.meta_limit
    local candidates = {}
    for _, story in ipairs(stories) do
        if type(story) == "table" and type(story.url) == "string" and story.url ~= "" then
            local cached = meta_cache[story.url]
            if cached then
                applyMeta(story, cached)
                if opts.on_success then
                    opts.on_success(story)
                end
            elseif #candidates < limit
                    and (opts.force or not hasLatestChapter(story) or story.completed == nil) then
                local source = registry:get(story.source_id)
                if source and type(source.fetchSearchMeta) == "function" then
                    table.insert(candidates, { story = story, source = source })
                end
            end
        end
    end
    if #candidates == 0 then
        return stories
    end

    -- Mỗi nguồn có hàng đợi riêng và tối đa `meta_concurrency` worker (mặc định
    -- 2) để không dồn request vào một server; pool giới hạn tổng số thread.
    local groups, group_order = {}, {}
    for _, candidate in ipairs(candidates) do
        local source_id = candidate.story.source_id
        local group = groups[source_id]
        if not group then
            local per_source = math.floor(tonumber(candidate.source.meta_concurrency) or self.meta_per_source)
            group = { source = candidate.source, queue = {}, workers = math.max(1, per_source) }
            groups[source_id] = group
            table.insert(group_order, group)
        end
        table.insert(group.queue, candidate.story)
    end

    local deadline = tonumber(opts.deadline) or self.meta_deadline
    local started_at = os.time()
    local function makeWorker(group)
        return function()
            while #group.queue > 0
                    and not AsyncPool.isCancelled()
                    and os.time() - started_at <= deadline do
                local story = table.remove(group.queue, 1)
                local source = group.source
                local ok, meta, err = pcall(source.fetchSearchMeta, source, story)
                if ok and type(meta) == "table" then
                    local entry = validateMeta(meta)
                    putMetaCache(story.url, entry)
                    applyMeta(story, entry)
                    if opts.on_success then
                        opts.on_success(story)
                    end
                else
                    log(string.format("[Meta] %s lỗi lấy số chương %s: %s",
                        sourceLabel(source), tostring(story.url),
                        tostring(ok and err or meta)))
                end
            end
        end
    end

    -- Xếp worker xen kẽ giữa các nguồn để mọi nguồn đều được bắt đầu sớm
    local tasks = {}
    local round = 1
    local added = true
    while added do
        added = false
        for _, group in ipairs(group_order) do
            if round <= math.min(group.workers, #group.queue) then
                table.insert(tasks, makeWorker(group))
                added = true
            end
        end
        round = round + 1
    end

    AsyncPool.run(tasks, {
        concurrency = tonumber(opts.concurrency) or self.meta_concurrency,
        deadline = deadline,
    })
    return stories
end

return SearchService
