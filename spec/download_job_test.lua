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

local DownloadJob = require("truyenviet/download_job")
local tests_run = 0
local function check(condition, message)
    tests_run = tests_run + 1
    if not condition then
        error(message, 2)
    end
end

local progress_path = os.tmpname()
local function exists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

check(DownloadJob.isAvailable(), "LuaJIT có string.buffer và fork")
check(DownloadJob.status() == nil and DownloadJob.progressText() == nil, "chưa có việc")

-- Thành công: tiến độ đọc từ file trước khi xong, kết quả qua pipe.
local updates = {}
local function subscriber(status)
    table.insert(updates, status or false)
end
DownloadJob.subscribe(subscriber)
DownloadJob.subscribe(subscriber)

children.delay = 3
local got, polled
check(DownloadJob.start{
    key = "a",
    title = "Truyện A",
    total = 5,
    progress_path = progress_path,
    task = function(report)
        report({ done = 1, total = 5, downloaded = 1, failed = 0 })
        report({ done = 2, total = 5, downloaded = 1, failed = 1 })
        return { downloaded = 1, skipped = 0, errors = { "C2: lỗi" }, first_path = "/x/c1.html", fn = print }
    end,
    on_poll = function(status) polled = status end,
    on_done = function(ok, result, err) got = { ok = ok, result = result, err = err } end,
}, "chạy nền được")
check(DownloadJob.isRunning(), "đang chạy")
check(#updates == 1 and updates[1].done == 0 and updates[1].total == 5, "báo ngay khi bắt đầu, đăng ký trùng chỉ tính một")

-- Việc thứ hai bị từ chối khi đang bận.
local started, reason = DownloadJob.start{ key = "b", total = 1, progress_path = progress_path, task = function() end }
check(started == false and reason == "busy", "mỗi lúc một việc")

runUntil(1.5)
check(got == nil, "chưa xong thì chưa gọi on_done")
local status = DownloadJob.status()
check(status.done == 2 and status.failed == 1 and status.title == "Truyện A", "đọc tiến độ từ file")
check(DownloadJob.progressText() == "⤓ 2/5", "chữ tiến độ")
check(polled and polled.done == 2, "on_poll nhận trạng thái")
check(#updates == 2 and updates[2].done == 2, "subscriber nhận tiến độ mới")

runUntil(5)
check(got and got.ok and got.result.first_path == "/x/c1.html", "nhận kết quả")
check(got.result.fn == nil and got.result.errors[1] == "C2: lỗi", "kết quả thuần")
check(not DownloadJob.isRunning() and DownloadJob.status() == nil, "xong thì hết việc")
check(updates[#updates] == false, "subscriber nhận nil khi xong")
check(not exists(progress_path), "xóa file tiến độ")
check(children[next_pid].reaped and children[next_pid].read, "thu dọn tiến trình con")
DownloadJob.unsubscribe(subscriber)

-- Lỗi trong task.
got = nil
children.delay = 1
DownloadJob.start{
    key = "c", total = 1, progress_path = progress_path,
    task = function() error("mạng hỏng") end,
    on_done = function(ok, _, err) got = { ok = ok, err = err } end,
}
runUntil(clock + 5)
check(got and got.ok == false and tostring(got.err):find("mạng hỏng"), "báo lỗi của task")

-- Hủy: kill, dọn file dở ngay (đồng bộ), on_done nhận lý do.
got = nil
children.delay = 100
local cleaned = 0
DownloadJob.start{
    key = "d", total = 3, progress_path = progress_path,
    task = function(report) report({ done = 1, total = 3, downloaded = 1, failed = 0 }) end,
    cleanup = function() cleaned = cleaned + 1 end,
    on_done = function(ok, _, err) got = { ok = ok, err = err } end,
}
local d_pid = next_pid
runUntil(clock + 2)
DownloadJob.cancel("exit")
check(cleaned == 1, "dọn file dở ngay khi hủy")
check(children[d_pid].killed, "kết thúc tiến trình con")
check(not DownloadJob.isRunning(), "hủy thì hết việc")
DownloadJob.cancel("exit")
check(cleaned == 1, "hủy lần hai không làm gì")
runUntil(clock + 3)
check(got and got.ok == false and got.err == "exit", "on_done nhận lý do hủy")
check(children[d_pid].read, "đọc nốt pipe sau khi hủy")

-- Treo: không có tiến độ mới quá stall_timeout.
got = nil
cleaned = 0
DownloadJob.stall_timeout = 5
DownloadJob.start{
    key = "e", total = 3, progress_path = progress_path,
    task = function() end,
    cleanup = function() cleaned = cleaned + 1 end,
    on_done = function(ok, _, err) got = { ok = ok, err = err } end,
}
runUntil(clock + 10)
check(got and got.ok == false and tostring(got.err):find("treo"), "treo thì tự hủy")
check(cleaned == 1 and children[next_pid].killed, "treo thì dọn và kết thúc")
children.delay = nil

-- Tiến trình con thoát mà không ghi gì.
got = nil
local original_write = ffiutil.writeToFD
ffiutil.writeToFD = function() end
DownloadJob.start{
    key = "f", total = 1, progress_path = progress_path,
    task = function() return 1 end,
    on_done = function(ok, _, err) got = { ok = ok, err = err } end,
}
runUntil(clock + 5)
ffiutil.writeToFD = original_write
check(got and got.ok == false and tostring(got.err):find("không trả kết quả"), "không có dữ liệu")

-- Không fork được.
fork_fails = true
started, reason = DownloadJob.start{ key = "g", total = 1, progress_path = progress_path, task = function() end }
check(started == false and reason == "fork", "fork lỗi trả false")
check(not DownloadJob.isRunning(), "fork lỗi không giữ việc")
fork_fails = false

os.remove(progress_path)
print(string.format("download_job_test: %d checks passed", tests_run))
