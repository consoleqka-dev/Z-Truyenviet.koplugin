local Debug = require("truyenviet/debugger")
local UIManager = require("ui/uimanager")
local Util = require("truyenviet/helpers")
local ffiutil = require("ffi/util")

local has_buffer, buffer = pcall(require, "string.buffer")

-- Tải chương trong tiến trình con (fork) để giao diện chính không bị chặn,
-- kể cả khi đang đọc truyện khác. Tiến trình con ghi tiến độ ra một file nhỏ
-- (ghi file tạm rồi rename), kết quả cuối gửi qua pipe; tiến trình chính
-- thăm dò mỗi giây. Mỗi lúc chỉ một việc. Tiến trình con không được đụng UI,
-- settings hay coroutine của tiến trình chính.
local DownloadJob = {
    poll_interval = 1,
    collect_interval = 1,
    -- Không có tiến độ mới quá lâu thì coi như treo (một chương truyện tranh
    -- tối đa 300 s cộng thời gian lấy trang).
    stall_timeout = 600,
}

local active
local subscribers = {}

local function notify(status)
    for _, callback in ipairs(subscribers) do
        local ok, err = pcall(callback, status)
        if not ok then
            Debug.write("[Tải nền] Lỗi khi báo tiến độ: " .. tostring(err))
        end
    end
end

-- Thu dọn tiến trình con đã bị bỏ (đọc nốt pipe để nó thoát được).
local function collectLater(pid, fd)
    local function collect()
        if ffiutil.isSubProcessDone(pid) then
            if fd then
                ffiutil.readAllFromFD(fd)
            end
            return
        end
        if fd and ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            ffiutil.readAllFromFD(fd)
            fd = nil
        end
        UIManager:scheduleIn(DownloadJob.collect_interval, collect)
    end
    UIManager:scheduleIn(DownloadJob.collect_interval, collect)
end

local function writeProgress(path, status)
    local temp_path = path .. ".tmp"
    local file = io.open(temp_path, "wb")
    if not file then
        return
    end
    file:write(string.format(
        "%d %d %d %d",
        status.done or 0,
        status.total or 0,
        status.downloaded or 0,
        status.failed or 0
    ))
    file:close()
    os.rename(temp_path, path)
end

local function readProgress(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    local done, total, downloaded, failed = tostring(content):match("^(%d+) (%d+) (%d+) (%d+)")
    if not done then
        return nil
    end
    return {
        done = tonumber(done),
        total = tonumber(total),
        downloaded = tonumber(downloaded),
        failed = tonumber(failed),
    }
end

local function decode(content)
    if not content or content == "" then
        return false, nil, "Tiến trình tải nền dừng mà không trả kết quả"
    end
    local ok, payload = pcall(buffer.decode, content)
    if not ok or type(payload) ~= "table" then
        return false, nil, "Kết quả tải nền hỏng"
    end
    return payload.ok == true, payload.result, payload.err
end

local function finish(job, ok, result, err)
    if job.finished then
        return
    end
    job.finished = true
    if active == job then
        active = nil
    end
    UIManager:unschedule(job.poll)
    os.remove(job.progress_path)
    os.remove(job.progress_path .. ".tmp")
    notify(nil)
    if job.on_done then
        UIManager:nextTick(function()
            job.on_done(ok, result, err)
        end)
    end
end

local function abort(job, reason)
    if job.finished then
        return
    end
    Debug.write("[Tải nền] Dừng việc " .. tostring(job.key) .. ": " .. tostring(reason))
    ffiutil.terminateSubProcess(job.pid)
    collectLater(job.pid, job.fd)
    job.fd = nil
    -- Dọn ngay, không chờ nextTick: khi Exit, KOReader có thể thoát trước.
    if job.cleanup then
        local ok, err = pcall(job.cleanup)
        if not ok then
            Debug.write("[Tải nền] Lỗi khi dọn file dở: " .. tostring(err))
        end
    end
    finish(job, false, nil, reason)
end

function DownloadJob.isAvailable()
    return has_buffer == true and type(ffiutil.runInSubProcess) == "function"
end

function DownloadJob.isRunning()
    return active ~= nil
end

-- { key, title, done, total, downloaded, failed } hoặc nil khi không có việc.
function DownloadJob.status()
    if not active then
        return nil
    end
    return {
        key = active.key,
        title = active.title,
        done = active.progress.done,
        total = active.progress.total,
        downloaded = active.progress.downloaded,
        failed = active.progress.failed,
    }
end

function DownloadJob.progressText()
    if not active then
        return nil
    end
    return string.format("⤓ %d/%d", active.progress.done, active.progress.total)
end

-- callback(status) khi tiến độ đổi; callback(nil) khi việc kết thúc.
function DownloadJob.subscribe(callback)
    DownloadJob.unsubscribe(callback)
    table.insert(subscribers, callback)
end

function DownloadJob.unsubscribe(callback)
    for index = #subscribers, 1, -1 do
        if subscribers[index] == callback then
            table.remove(subscribers, index)
        end
    end
end

function DownloadJob.cancel(reason)
    if active then
        abort(active, reason or "cancelled")
    end
end

-- opts.task(report) chạy trong tiến trình con, trả về dữ liệu thuần; gọi
-- report({ done, total, downloaded, failed }) sau mỗi chương.
-- opts.cleanup() chạy ở tiến trình chính khi hủy (xóa .part).
-- opts.on_done(ok, result, err): err là "cancelled", "exit"... khi bị hủy.
-- opts.on_poll(status) chạy ở mỗi lần thăm dò (đồng bộ giao diện).
-- Trả về false, lý do nếu không chạy được (đang có việc, không fork được).
function DownloadJob.start(opts)
    if not DownloadJob.isAvailable() then
        return false, "unavailable"
    end
    if active then
        return false, "busy"
    end
    local progress_path = opts.progress_path
    os.remove(progress_path)

    local ok_fork, pid, fd = pcall(ffiutil.runInSubProcess, function(child_pid, child_write_fd)
        -- Mọi tiến trình con cùng thừa hưởng trạng thái math.random của tiến
        -- trình chính; gieo lại để tên file tạm không trùng nhau.
        math.randomseed(os.time() + (tonumber(child_pid) or 0))
        local function report(status)
            pcall(writeProgress, progress_path, status)
        end
        local ok, result = pcall(opts.task, report)
        local payload = ok and { ok = true, result = Util.plainData(result) }
            or { ok = false, err = tostring(result) }
        local encoded_ok, content = pcall(buffer.encode, payload)
        if not encoded_ok then
            content = buffer.encode({ ok = false, err = "Không mã hóa được kết quả" })
        end
        ffiutil.writeToFD(child_write_fd, content, true)
    end, true)
    if not ok_fork or not pid then
        Debug.write("[Tải nền] Không tạo được tiến trình con: " .. tostring(ok_fork and fd or pid))
        return false, "fork"
    end

    local job = {
        key = opts.key,
        title = opts.title,
        pid = pid,
        fd = fd,
        progress_path = progress_path,
        cleanup = opts.cleanup,
        on_done = opts.on_done,
        on_poll = opts.on_poll,
        progress = { done = 0, total = opts.total or 0, downloaded = 0, failed = 0 },
        idle = 0,
    }
    active = job
    Debug.write(string.format("[Tải nền] Bắt đầu %s (%d chương), pid=%s", tostring(job.key), job.progress.total, tostring(pid)))

    job.poll = function()
        if job.finished then
            return
        end
        local progress = readProgress(job.progress_path)
        if progress and progress.done ~= job.progress.done then
            job.progress = progress
            job.idle = 0
            notify(DownloadJob.status())
        else
            job.idle = job.idle + DownloadJob.poll_interval
        end

        local done = ffiutil.isSubProcessDone(job.pid)
        local readable = job.fd and ffiutil.getNonBlockingReadSize(job.fd) ~= 0
        if readable or done then
            local content = job.fd and ffiutil.readAllFromFD(job.fd)
            job.fd = nil
            if not done then
                collectLater(job.pid, nil)
            end
            Debug.write("[Tải nền] Xong " .. tostring(job.key))
            finish(job, decode(content))
            return
        end
        if job.idle >= DownloadJob.stall_timeout then
            abort(job, "Tải nền bị treo (không có tiến độ mới)")
            return
        end
        if job.on_poll then
            local ok, err = pcall(job.on_poll, DownloadJob.status())
            if not ok then
                Debug.write("[Tải nền] Lỗi on_poll: " .. tostring(err))
            end
        end
        UIManager:scheduleIn(DownloadJob.poll_interval, job.poll)
    end
    UIManager:scheduleIn(DownloadJob.poll_interval, job.poll)
    notify(DownloadJob.status())
    return true
end

return DownloadJob
