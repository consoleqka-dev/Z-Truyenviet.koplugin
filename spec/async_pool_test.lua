local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Copas giả chạy theo thời gian ảo: mỗi lần step() đẩy đồng hồ tiến lên và
-- resume các thread đã đến hạn. step() bị cấm gọi từ bên trong thread để kiểm
-- tra đúng quy tắc "không step lồng nhau".
local clock = 0
local threads = {}
local in_thread = false
local step_calls = 0
local removed_count = 0
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
            removed_count = removed_count + 1
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
    step_calls = step_calls + 1
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
                fake_copas.removethread(entry.co)
                removed_count = removed_count - 1
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

local AsyncPool = require("truyenviet/async_pool")
local tests_run = 0

local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format(
            "%s: expected %s, got %s",
            message,
            tostring(expected),
            tostring(actual)
        ))
    end
end

-- Thứ tự kết quả theo index dù task hoàn tất lệch thứ tự
do
    local finish_order = {}
    local function task(label, steps)
        return function()
            for _ = 1, steps do
                fake_copas.sleep(0.05)
            end
            table.insert(finish_order, label)
            return label, steps
        end
    end
    local results = AsyncPool.run({ task("slow", 6), task("fast", 1), task("mid", 3) })
    assertEqual("fast", finish_order[1], "Task nhanh xong trước")
    assertEqual("slow", results[1].values[1], "Kết quả giữ đúng index 1")
    assertEqual("fast", results[2].values[1], "Kết quả giữ đúng index 2")
    assertEqual("mid", results[3].values[1], "Kết quả giữ đúng index 3")
    assertEqual(2, results[2].values.n, "Đếm đúng số giá trị trả về")
    assertEqual(true, results[1].done and results[1].ok, "Task hoàn tất được đánh dấu done/ok")
end

-- Giới hạn concurrency
do
    local active, peak = 0, 0
    local tasks = {}
    for index = 1, 6 do
        tasks[index] = function()
            active = active + 1
            peak = math.max(peak, active)
            fake_copas.sleep(0.05)
            active = active - 1
            return index
        end
    end
    local results = AsyncPool.run(tasks, { concurrency = 2 })
    assertEqual(2, peak, "Không vượt concurrency")
    assertEqual(6, results[6].values[1], "Mọi task đều chạy")
end

-- Task ném lỗi bị cô lập
do
    local results = AsyncPool.run({
        function() error("boom") end,
        function() return "fine" end,
    })
    assertEqual(true, results[1].done, "Task lỗi vẫn done")
    assertEqual(false, results[1].ok, "Task lỗi ok=false")
    assertEqual(true, tostring(results[1].values):find("boom", 1, true) ~= nil, "Giữ thông báo lỗi")
    assertEqual("fine", results[2].values[1], "Task khác không bị ảnh hưởng")
end

-- Quá hạn: task treo bị huỷ, task xong vẫn giữ kết quả
do
    local before_removed = removed_count
    local results = AsyncPool.run({
        function()
            while true do
                fake_copas.sleep(0.05)
            end
        end,
        function() return "quick" end,
    }, { concurrency = 2, deadline = 1 })
    assertEqual(false, results[1].done, "Task treo bị đánh dấu chưa xong")
    assertEqual("quick", results[2].values[1], "Task nhanh vẫn có kết quả")
    assertEqual(true, removed_count > before_removed, "Thread treo bị removethread")

    local queued = AsyncPool.run({
        function()
            while true do
                fake_copas.sleep(0.05)
            end
        end,
        function() return "never" end,
    }, { concurrency = 1, deadline = 1 })
    assertEqual(false, queued[2].done, "Task chưa kịp bắt đầu bị đánh dấu chưa xong")
end

-- inPoolThread: false ngoài pool (kể cả coroutine thường kiểu Trapper), true trong task
do
    assertEqual(false, AsyncPool.inPoolThread(), "Main không phải pool thread")
    local plain_result
    local co = coroutine.create(function()
        plain_result = AsyncPool.inPoolThread()
    end)
    coroutine.resume(co)
    assertEqual(false, plain_result, "Coroutine thường không phải pool thread")

    local inside, cancelled
    AsyncPool.run({ function()
        inside = AsyncPool.inPoolThread()
        cancelled = AsyncPool.isCancelled()
    end })
    assertEqual(true, inside, "Task chạy trong pool thread")
    assertEqual(false, cancelled, "Lượt chạy bình thường chưa bị huỷ")
end

-- Gọi lồng: không step từ trong thread, kết quả lồng đúng
do
    local steps_before = step_calls
    local results = AsyncPool.run({
        function()
            local inner = AsyncPool.run({
                function()
                    fake_copas.sleep(0.05)
                    return "inner-a"
                end,
                function() return "inner-b" end,
            }, { concurrency = 2 })
            return inner[1].values[1] .. "+" .. inner[2].values[1]
        end,
    })
    assertEqual("inner-a+inner-b", results[1].values[1], "Gọi lồng trả đúng kết quả")
    assertEqual(true, step_calls > steps_before, "Vòng ngoài vẫn step")
end

-- Gọi lồng bị huỷ theo lượt chạy cha khi quá hạn
do
    local inner_cancelled_seen = false
    local results = AsyncPool.run({
        function()
            AsyncPool.run({
                function()
                    while true do
                        fake_copas.sleep(0.05)
                        if AsyncPool.isCancelled() then
                            inner_cancelled_seen = true
                        end
                    end
                end,
            }, { deadline = 100 })
        end,
    }, { deadline = 1 })
    assertEqual(false, results[1].done, "Lượt ngoài quá hạn")
    local before = clock
    for _ = 1, 5 do
        fake_copas.step(0.05)
    end
    assertEqual(true, clock > before, "Thread bị huỷ không còn được resume")
    assertEqual(false, inner_cancelled_seen, "Thread lồng đã bị gỡ khỏi Copas")
end

-- Danh sách rỗng
do
    assertEqual(0, #AsyncPool.run({}), "Danh sách rỗng")
end

-- Không có Copas: chạy tuần tự theo đúng thứ tự
do
    package.loaded["truyenviet/async_pool"] = nil
    package.loaded["copas"] = nil
    package.preload["copas"] = function()
        error("copas không khả dụng")
    end
    local SequentialPool = require("truyenviet/async_pool")
    local order = {}
    local results = SequentialPool.run({
        function() table.insert(order, 1) return "a" end,
        function() table.insert(order, 2) error("fail") end,
        function() table.insert(order, 3) return "c" end,
    })
    assertEqual("1,2,3", table.concat(order, ","), "Fallback chạy tuần tự")
    assertEqual("a", results[1].values[1], "Fallback giữ kết quả")
    assertEqual(false, results[2].ok, "Fallback cô lập lỗi")
    assertEqual("c", results[3].values[1], "Fallback tiếp tục sau lỗi")
    assertEqual(false, SequentialPool.inPoolThread(), "Fallback không có pool thread")

    -- Gọi lồng trong fallback cũng chỉ là gọi tuần tự
    local nested = SequentialPool.run({
        function()
            local inner = SequentialPool.run({ function() return "x" end })
            return inner[1].values[1]
        end,
    })
    assertEqual("x", nested[1].values[1], "Gọi lồng ở fallback")
end

print(string.format("Async pool tests passed: %d assertions", tests_run))
