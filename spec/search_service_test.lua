local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["socket.url"] = function()
    return {
        absolute = function(base, href)
            if href:match("^https?://") then
                return href
            end
            return base:gsub("/+$", "") .. "/" .. href:gsub("^/+", "")
        end,
    }
end

package.preload["util"] = function()
    return {
        htmlEntitiesToUtf8 = function(value)
            return value
        end,
        stringLower = function(value)
            return value:lower()
        end,
    }
end

local SearchService = require("truyenviet/search_service")

local results, errors = SearchService:search("", {
    {
        id = "empty",
        name = "Empty",
        search = function()
            error("must not call source for empty query")
        end,
    },
})
assert(#results == 0, "empty query returned search results")
assert(#errors == 1, "empty query did not return a clear error")

local malformed_results, malformed_errors = SearchService:search("bachu", {
    {
        id = "malformed",
        name = "Malformed",
        search = function()
            return "not a story list"
        end,
    },
    {
        id = "valid",
        name = "Valid",
        search = function()
            return {
                { title = "Thiếu URL", source_id = "valid" },
                {
                    title = "Con Đường Bá Chủ",
                    source_id = "valid",
                    url = "https://example.test/story",
                },
            }
        end,
    },
})
assert(#malformed_results == 1, "malformed source crashed or leaked invalid results")
assert(
    malformed_results[1].title == "Con Đường Bá Chủ",
    "valid search result was lost"
)
assert(#malformed_errors == 1, "malformed source error was not isolated")

local thrown_results, thrown_errors = SearchService:search("bachu", {
    {
        id = "throws",
        name = "Throws",
        search = function()
            error("simulated network/parser failure")
        end,
    },
})
assert(#thrown_results == 0, "throwing source returned results")
assert(
    thrown_errors[1]:find("simulated network/parser failure", 1, true),
    "source exception was not surfaced as an error"
)

local failed_calls = 0
SearchService:search("đường", {
    {
        id = "slow-failure",
        name = "Slow Failure",
        search = function()
            failed_calls = failed_calls + 1
            error("simulated timeout")
        end,
    },
})
assert(
    failed_calls == 1,
    "failed accented search was retried and doubled the wait time"
)

-- Phần dưới chạy với Copas giả (thời gian ảo) để kiểm tra nhánh song song.
-- step() bị cấm gọi từ bên trong thread để bắt lỗi re-entrancy.
local clock = 0
local threads = {}
local in_thread = false
local fake_copas = {}

function fake_copas.addthread(handler, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return handler(unpack(args))
    end)
    table.insert(threads, { co = co, wake_at = clock })
    return co
end

function fake_copas.removethread(co)
    for index, entry in ipairs(threads) do
        if entry.co == co then
            entry.removed = true
            table.remove(threads, index)
            return
        end
    end
end

function fake_copas.sleep(seconds)
    assert(in_thread, "copas.sleep gọi ngoài thread")
    coroutine.yield(seconds or 0)
end

function fake_copas.step(timeout)
    assert(not in_thread, "copas.step không được gọi từ bên trong thread của pool")
    clock = clock + (timeout or 0.05)
    local snapshot = {}
    for index, entry in ipairs(threads) do
        snapshot[index] = entry
    end
    for _, entry in ipairs(snapshot) do
        if not entry.removed and entry.wake_at <= clock then
            in_thread = true
            local ok, result = coroutine.resume(entry.co)
            in_thread = false
            assert(ok, tostring(result))
            if coroutine.status(entry.co) == "dead" then
                entry.removed = true
                for index, candidate in ipairs(threads) do
                    if candidate == entry then
                        table.remove(threads, index)
                        break
                    end
                end
            else
                entry.wake_at = clock + (result or 0)
            end
        end
    end
    return true
end

package.preload["copas"] = function()
    return fake_copas
end
package.preload["socket"] = function()
    return {
        gettime = function()
            return clock
        end,
    }
end
package.loaded["copas"] = nil
package.loaded["socket"] = nil
package.loaded["truyenviet/async_pool"] = nil
package.loaded["truyenviet/search_service"] = nil
SearchService = require("truyenviet/search_service")
local AsyncPool = require("truyenviet/async_pool")

local function newStory(source_id, url, title)
    return { source_id = source_id, url = url, title = title }
end

local function sleepSteps(count)
    for _ = 1, count do
        fake_copas.sleep(0.05)
    end
end

-- Kết quả gộp theo thứ tự nguồn gốc dù nguồn chậm xong sau
do
    SearchService:clearCache()
    local slow = {
        id = "slow",
        name = "Slow",
        search = function()
            sleepSteps(6)
            return { newStory("shared", "https://example.test/x", "Truyen Chung") }
        end,
    }
    local fast = {
        id = "fast",
        name = "Fast",
        search = function()
            return {
                newStory("shared", "https://example.test/x", "Truyen Chung"),
                newStory("fast", "https://example.test/y", "Truyen Chung"),
            }
        end,
    }
    local found, found_errors = SearchService:search("truyen chung", { slow, fast })
    assert(#found_errors == 0, "parallel search produced errors")
    assert(#found == 2, "duplicate across sources was not removed")
    assert(found[1].source_id == "shared" and found[1].source_name == "Slow",
        "dedup must keep the story from the earlier source even if it finished later")
    assert(found[2].source_id == "fast", "sort order changed")
end

-- Nguồn treo bị cắt đúng hạn và không chặn nguồn khác
do
    SearchService:clearCache()
    SearchService.search_deadline = 0.5
    local hang = {
        id = "hang",
        name = "Hang",
        search = function()
            while true do
                fake_copas.sleep(0.05)
            end
        end,
    }
    local alive = {
        id = "alive",
        name = "Alive",
        search = function()
            return { newStory("alive", "https://example.test/1", "Truyen Song") }
        end,
    }
    local found, found_errors = SearchService:search("truyen", { hang, alive })
    SearchService.search_deadline = 15
    assert(#found == 1 and found[1].source_id == "alive", "healthy source lost after timeout")
    assert(#found_errors == 1, "timed-out source did not produce exactly one error")
    assert(found_errors[1] == "Hang: quá thời gian (0.5s)",
        "unexpected timeout message: " .. tostring(found_errors[1]))
end

-- Tổng thời gian ~ nguồn chậm nhất, không phải tổng các nguồn
do
    SearchService:clearCache()
    local sources = {}
    for index = 1, 3 do
        sources[index] = {
            id = "wait" .. index,
            name = "Wait" .. index,
            search = function()
                sleepSteps(10)
                return { newStory("wait" .. index, "https://example.test/w", "Truyen Cho") }
            end,
        }
    end
    local started = clock
    local found = SearchService:search("truyen cho", sources)
    local elapsed = clock - started
    assert(#found == 3, "parallel sources lost results")
    assert(elapsed < 0.9, "sources ran sequentially, elapsed " .. elapsed)
end

-- Cache phiên: không gọi lại nguồn, bản sao độc lập với UI, có TTL
do
    SearchService:clearCache()
    local calls = 0
    local source = {
        id = "cached",
        name = "Cached",
        search = function()
            calls = calls + 1
            return { newStory("cached", "https://example.test/c", "Truyen Cache") }
        end,
    }
    local first = SearchService:search("truyen cache", { source })
    first[1].cover_path = "/tmp/cover.jpg"
    local second = SearchService:search("truyen cache", { source })
    assert(calls == 1, "second identical search hit the source again")
    assert(second[1] ~= first[1], "cached story table must not be shared with earlier results")
    assert(second[1].cover_path == nil, "UI mutation leaked into the cache")

    SearchService.cache_ttl = -1
    SearchService:search("truyen cache", { source })
    SearchService.cache_ttl = 600
    assert(calls == 2, "expired cache entry was reused")

    SearchService:clearCache()
    SearchService.cache_max_entries = 2
    for _, term in ipairs({ "truyen one", "truyen two", "truyen three" }) do
        SearchService:search(term, { source })
    end
    local before = calls
    SearchService:search("truyen three", { source })
    SearchService.cache_max_entries = 30
    assert(calls == before, "newest cache entry was evicted")
end

-- Lỗi TLS: thử lại tuần tự ngoài pool đúng một nguồn
do
    SearchService:clearCache()
    local counters = {}
    local function tlsSource(id)
        return {
            id = id,
            name = id,
            search = function()
                counters[id] = (counters[id] or 0) + 1
                if AsyncPool.inPoolThread() then
                    return nil, "ssl handshake failed"
                end
                return { newStory(id, "https://example.test/" .. id, "Truyen Tls") }
            end,
        }
    end
    local found, found_errors = SearchService:search("truyen tls", { tlsSource("tlsa") })
    assert(#found == 1 and #found_errors == 0, "TLS failure was not recovered by sync retry")
    assert(counters.tlsa == 2, "sync retry must run exactly once")

    SearchService:clearCache()
    counters = {}
    found, found_errors = SearchService:search("truyen tls", { tlsSource("tlsb"), tlsSource("tlsc") })
    assert(#found == 0 and #found_errors == 2, "multiple TLS failures must not trigger sync retries")
    assert(counters.tlsb == 1 and counters.tlsc == 1, "sync retry ran despite multiple failures")
end

-- enrichMeta
local function makeRegistry(list)
    local by_id = {}
    for _, source in ipairs(list) do
        by_id[source.id] = source
    end
    return {
        get = function(_, source_id)
            return by_id[source_id]
        end,
    }
end

do
    SearchService:clearCache()
    local fetch_calls = 0
    local meta_source = {
        id = "meta",
        name = "Meta",
        fetchSearchMeta = function(_, story)
            fetch_calls = fetch_calls + 1
            fake_copas.sleep(0.05)
            if story.url:find("bad", 1, true) then
                return { chapter_count = 0, completed = "yes", latest_chapter = -1 }
            end
            if story.url:find("err", 1, true) then
                return nil, "boom"
            end
            if story.url:find("throw", 1, true) then
                error("kaboom")
            end
            return { chapter_count = 120.0, completed = true, latest_chapter = "119.5" }
        end,
    }
    local plain_source = { id = "plain", name = "Plain" }
    local registry = makeRegistry({ meta_source, plain_source })
    local stories = {
        newStory("meta", "https://m.test/1", "A"),
        newStory("meta", "https://m.test/bad", "B"),
        newStory("meta", "https://m.test/err", "C"),
        newStory("meta", "https://m.test/throw", "D"),
        newStory("plain", "https://p.test/1", "E"),
        { source_id = "meta", url = "https://m.test/full", title = "F", chapter_count = 5, latest_chapter = 7, completed = false },
        -- Có tổng số chương nhưng thiếu chương mới nhất -> vẫn cần fetch
        { source_id = "meta", url = "https://m.test/count", title = "G", chapter_count = 5, completed = false },
    }
    local returned = SearchService:enrichMeta(stories, { registry = registry })
    assert(returned == stories, "enrichMeta must return the same list")
    assert(stories[1].chapter_count == 120 and stories[1].completed == true,
        "valid meta was not assigned")
    assert(stories[1].latest_chapter == 119.5, "latest_chapter must keep decimals")
    assert(stories[2].chapter_count == nil and stories[2].completed == nil
        and stories[2].latest_chapter == nil,
        "invalid meta must be ignored")
    assert(stories[3].chapter_count == nil and stories[4].chapter_count == nil,
        "failed fetch must not assign meta")
    assert(stories[5].chapter_count == nil, "source without fetchSearchMeta was touched")
    assert(stories[6].chapter_count == 5 and stories[6].completed == false,
        "story with complete meta must not be refetched or changed")
    assert(stories[7].latest_chapter == 119.5 and stories[7].chapter_count == 120,
        "story without latest_chapter was not enriched")
    assert(fetch_calls == 5, "unexpected fetch count " .. fetch_calls)

    -- Lần sau: kết quả hợp lệ (kể cả rỗng) lấy từ cache, chỉ lỗi mới fetch lại
    local again = {
        newStory("meta", "https://m.test/1", "A again"),
        newStory("meta", "https://m.test/bad", "B again"),
        newStory("meta", "https://m.test/err", "C again"),
        newStory("meta", "https://m.test/throw", "D again"),
    }
    SearchService:enrichMeta(again, { registry = registry })
    assert(again[1].chapter_count == 120 and again[1].completed == true
        and again[1].latest_chapter == 119.5,
        "meta cache was not applied")
    assert(fetch_calls == 7, "meta cache did not prevent refetch, calls " .. fetch_calls)
end

-- enrichMeta: giới hạn số truyện, concurrency theo nguồn và tổng
do
    local active, peak = 0, 0
    local calls = 0
    local function trackedSource(id, meta_concurrency)
        return {
            id = id,
            name = id,
            meta_concurrency = meta_concurrency,
            fetchSearchMeta = function()
                calls = calls + 1
                active = active + 1
                peak = math.max(peak, active)
                fake_copas.sleep(0.05)
                active = active - 1
                return { chapter_count = 10 }
            end,
        }
    end
    local function storiesFor(id, count)
        local list = {}
        for index = 1, count do
            list[index] = newStory(id, "https://" .. id .. ".test/" .. index, "T" .. index)
        end
        return list
    end

    local default_source = trackedSource("def")
    SearchService:enrichMeta(storiesFor("def", 5), { registry = makeRegistry({ default_source }) })
    assert(peak == 2, "per-source concurrency default must be 2, got " .. peak)

    active, peak = 0, 0
    local single_source = trackedSource("single", 1)
    SearchService:enrichMeta(storiesFor("single", 4), { registry = makeRegistry({ single_source }) })
    assert(peak == 1, "source.meta_concurrency was ignored, got " .. peak)

    calls = 0
    local limited = trackedSource("limited")
    SearchService:enrichMeta(storiesFor("limited", 15), { registry = makeRegistry({ limited }) })
    assert(calls == 12, "enrichMeta must cap candidates at 12, got " .. calls)

    active, peak = 0, 0
    local many = {}
    local combined = {}
    for _, id in ipairs({ "ga", "gb", "gc", "gd" }) do
        table.insert(many, trackedSource(id))
        for _, story in ipairs(storiesFor(id, 3)) do
            table.insert(combined, story)
        end
    end
    SearchService:enrichMeta(combined, { registry = makeRegistry(many) })
    assert(peak == 6, "global meta concurrency must be 6, got " .. peak)
end

-- enrichMeta: quá hạn thì dừng, không treo
do
    local hang_source = {
        id = "hangmeta",
        name = "HangMeta",
        fetchSearchMeta = function()
            while true do
                fake_copas.sleep(0.05)
            end
        end,
    }
    local list = { newStory("hangmeta", "https://hang.test/1", "T") }
    SearchService:enrichMeta(list, { registry = makeRegistry({ hang_source }), deadline = 0.5 })
    assert(list[1].chapter_count == nil, "timed-out meta fetch assigned data")
end

print("Search service tests passed")
