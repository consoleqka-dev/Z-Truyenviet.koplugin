local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

-- Đồng hồ ảo cho UIManager và tiến trình con giả.
local clock = 0
local queue = {}
local UIManager = {}
function UIManager:scheduleIn(delay, callback)
    table.insert(queue, { at = clock + delay, callback = callback })
end
function UIManager:nextTick(callback)
    table.insert(queue, { at = clock, callback = callback })
end
function UIManager:unschedule(callback)
    for index = #queue, 1, -1 do
        if queue[index].callback == callback then
            table.remove(queue, index)
        end
    end
end
local function runUntil(limit)
    while #queue > 0 do
        table.sort(queue, function(left, right) return left.at < right.at end)
        if queue[1].at > limit then
            break
        end
        local item = table.remove(queue, 1)
        clock = math.max(clock, item.at)
        item.callback()
    end
    clock = math.max(clock, limit)
end

-- Tiến trình con giả: chạy func ngay, giữ dữ liệu ghi ra; "xong" sau ready_at.
local children = {}
local next_pid = 100
local fork_fails = false
local ffiutil = {}
function ffiutil.runInSubProcess(func, with_pipe)
    assert(with_pipe == true, "phải mở pipe")
    if fork_fails then
        return false, "fork failed"
    end
    next_pid = next_pid + 1
    local child = { pid = next_pid, ready_at = clock + (children.delay or 1), reaped = false }
    children[next_pid] = child
    func(next_pid, child)
    return next_pid, child
end
function ffiutil.writeToFD(fd, data, close)
    fd.data = data
    fd.closed_by_child = close
end
function ffiutil.isSubProcessDone(pid)
    local child = children[pid]
    if child.killed or clock >= child.ready_at then
        child.reaped = true
        return true
    end
    return false
end
function ffiutil.getNonBlockingReadSize(fd)
    if clock >= fd.ready_at and fd.data then
        return #fd.data
    end
    return 0
end
function ffiutil.readAllFromFD(fd)
    fd.read = true
    return fd.data or ""
end
function ffiutil.terminateSubProcess(pid)
    children[pid].killed = true
end

package.preload["ui/uimanager"] = function() return UIManager end
package.preload["ffi/util"] = function() return ffiutil end
package.preload["socket.url"] = function()
    return { absolute = function(_, href) return href end }
end
package.preload["util"] = function()
    return { stringLower = string.lower, htmlEntitiesToUtf8 = function(value) return value end }
end
package.preload["truyenviet/debugger"] = function()
    return { write = function() end }
end

local BackgroundFetch = require("truyenviet/background_fetch")
local tests_run = 0
local function check(condition, message)
    tests_run = tests_run + 1
    if not condition then
        error(message, 2)
    end
end

check(BackgroundFetch.isAvailable(), "LuaJIT có string.buffer và fork")

-- Thành công: kết quả thuần, bỏ function.
local got
check(BackgroundFetch.run("a", function()
    return { chapters = { { title = "C1", fn = print } }, total_pages = 3 }
end, function(ok, result, err)
    got = { ok = ok, result = result, err = err }
end), "chạy nền được")
check(BackgroundFetch.isRunning("a") and BackgroundFetch.isRunning(), "đang chạy việc a")
runUntil(0.5)
check(got == nil, "chưa xong thì chưa gọi callback")
runUntil(5)
check(got and got.ok and got.result.total_pages == 3, "nhận kết quả từ tiến trình con")
check(got.result.chapters[1].fn == nil and got.result.chapters[1].title == "C1", "kết quả thuần")
check(not BackgroundFetch.isRunning(), "xong thì không còn việc")
local pid = next_pid
check(children[pid].reaped and children[pid].read, "thu dọn tiến trình con và đóng pipe")

-- Lỗi trong task.
got = nil
BackgroundFetch.run("b", function() error("mạng hỏng") end, function(ok, _, err)
    got = { ok = ok, err = err }
end)
runUntil(clock + 5)
check(got and got.ok == false and tostring(got.err):find("mạng hỏng"), "báo lỗi của task")

-- Cùng key thì chờ chung; khác key thì hủy việc cũ.
local calls = {}
BackgroundFetch.run("c", function() return 1 end, function(ok, result) table.insert(calls, { "c1", ok, result }) end)
BackgroundFetch.run("c", function() return 2 end, function(ok, result) table.insert(calls, { "c2", ok, result }) end)
local c_pid = next_pid
BackgroundFetch.run("d", function() return 4 end, function(ok, result, err)
    table.insert(calls, { "d", ok, result, err })
end)
runUntil(clock + 5)
check(#calls == 3, "đủ 3 callback (có " .. #calls .. ")")
check(calls[1][1] == "c1" and calls[1][2] == false and calls[2][1] == "c2", "việc c bị hủy cho cả 2 callback")
check(children[c_pid].killed and children[c_pid].read, "hủy thì kết thúc và đọc nốt pipe")
check(calls[3][2] == true and calls[3][3] == 4, "việc d chạy xong")

-- Quá thời gian.
got = nil
children.delay = 100
BackgroundFetch.run("e", function() return 1 end, function(ok, _, err) got = { ok = ok, err = err } end, { timeout = 3 })
runUntil(clock + 10)
check(got and got.ok == false and got.err == "Quá thời gian chờ", "hết giờ thì hủy")
check(children[next_pid].killed, "hết giờ thì kết thúc tiến trình con")
children.delay = nil

-- Tiến trình con thoát mà không ghi gì.
got = nil
local original_write = ffiutil.writeToFD
ffiutil.writeToFD = function() end
BackgroundFetch.run("f", function() return 1 end, function(ok, _, err) got = { ok = ok, err = err } end)
runUntil(clock + 5)
ffiutil.writeToFD = original_write
check(got and got.ok == false and got.err == "Tiến trình nền không trả kết quả", "không có dữ liệu")

-- Không fork được thì trả false để người gọi chạy cách cũ.
fork_fails = true
check(BackgroundFetch.run("g", function() end, function() end) == false, "fork lỗi trả false")
check(not BackgroundFetch.isRunning(), "fork lỗi không giữ việc")
fork_fails = false

print(string.format("background_fetch_test: %d checks passed", tests_run))
