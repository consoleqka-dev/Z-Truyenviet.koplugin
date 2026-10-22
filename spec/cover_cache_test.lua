local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["truyenviet/http_client"] = function()
    return {}
end
package.preload["truyenviet/image_utils"] = function()
    return {}
end
package.preload["truyenviet/storage"] = function()
    return {
        settings = {
            readSetting = function()
                return false
            end,
        },
    }
end
package.preload["truyenviet/helpers"] = function()
    return {}
end
package.preload["ffi/util"] = function()
    return {
        joinPath = function(left, right)
            return left .. "/" .. right
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function()
            return nil
        end,
    }
end

local CoverCache = require("truyenviet/cover_cache")
local download_calls = 0
CoverCache.download = function(_, story)
    download_calls = download_calls + 1
    if story.id == 3 then
        error("simulated broken cover")
    end
    return "/tmp/" .. story.id .. ".jpg"
end

local stories = {}
for index = 1, 25 do
    stories[index] = {
        id = index,
        source_id = "source",
        cover_url = "https://example.test/" .. index .. ".jpg",
    }
end

local returned = CoverCache:prefetch(stories, {
    get = function()
        return { base_url = "https://example.test" }
    end,
})

assert(returned == stories, "prefetch did not preserve the result list")
assert(
    download_calls == CoverCache.max_prefetch,
    string.format(
        "prefetch must cap cover downloads at %d (got %d)",
        CoverCache.max_prefetch,
        download_calls
    )
)
assert(stories[1].cover_path ~= nil, "valid cover result was not stored")
assert(stories[3].cover_path == nil, "broken cover escaped exception isolation")

-- Nhánh song song với Copas giả (thời gian ảo): giới hạn 4 tải đồng thời, 10 ảnh
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
        if entry.wake_at <= clock then
            in_thread = true
            local ok, result = coroutine.resume(entry.co)
            in_thread = false
            assert(ok, tostring(result))
            if coroutine.status(entry.co) == "dead" then
                fake_copas.removethread(entry.co)
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
package.loaded["truyenviet/cover_cache"] = nil
CoverCache = require("truyenviet/cover_cache")

local active, peak, parallel_calls = 0, 0, 0
CoverCache.download = function(_, story)
    parallel_calls = parallel_calls + 1
    active = active + 1
    peak = math.max(peak, active)
    fake_copas.sleep(0.05)
    active = active - 1
    return "/tmp/" .. story.id .. ".jpg"
end

local parallel_stories = {}
for index = 1, 25 do
    parallel_stories[index] = {
        id = index,
        source_id = "source",
        cover_url = "https://example.test/" .. index .. ".jpg",
    }
end
CoverCache:prefetch(parallel_stories, {
    get = function()
        return { base_url = "https://example.test" }
    end,
})
assert(parallel_calls == CoverCache.max_prefetch, "parallel prefetch must cap at max_prefetch")
assert(peak == 4, "parallel prefetch must run 4 downloads at once, got " .. peak)
assert(parallel_stories[10].cover_path == "/tmp/10.jpg", "parallel prefetch lost a cover")
assert(parallel_stories[11].cover_path == nil, "prefetch went beyond the limit")

print("Cover cache tests passed")
