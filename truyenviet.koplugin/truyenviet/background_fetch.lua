local Debug = require("truyenviet/debugger")
local UIManager = require("ui/uimanager")
local Util = require("truyenviet/helpers")
local ffiutil = require("ffi/util")

local has_buffer, buffer = pcall(require, "string.buffer")

-- Chạy một việc mạng trong tiến trình con (fork) và nhận kết quả qua pipe mà
-- không chặn giao diện: UIManager thăm dò định kỳ. Dùng cho nguồn cần
-- force_luasec (nhánh Copas của AsyncPool bỏ qua tùy chọn này).
-- Mỗi lúc chỉ chạy một việc; tiến trình con không được đụng UI hay settings.
local BackgroundFetch = {
    timeout = 45,
    first_interval = 0.25,
    max_interval = 1,
    polls_per_step = 4,
    collect_interval = 1,
}

local active

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
        UIManager:scheduleIn(BackgroundFetch.collect_interval, collect)
    end
    UIManager:scheduleIn(BackgroundFetch.collect_interval, collect)
end

local function finish(job, ok, result, err)
    if job.finished then
        return
    end
    job.finished = true
    if active == job then
        active = nil
    end
    if job.poll then
        UIManager:unschedule(job.poll)
    end
    for _, callback in ipairs(job.callbacks) do
        UIManager:nextTick(function()
            callback(ok, result, err)
        end)
    end
end

-- Dừng việc đang chạy; callback nhận (false, nil, reason).
local function abort(job, reason)
    if job.finished then
        return
    end
    ffiutil.terminateSubProcess(job.pid)
    collectLater(job.pid, job.fd)
    job.fd = nil
    finish(job, false, nil, reason)
end

local function decode(content)
    if not content or content == "" then
        return false, nil, "Tiến trình nền không trả kết quả"
    end
    local ok, payload = pcall(buffer.decode, content)
    if not ok or type(payload) ~= "table" then
        return false, nil, "Kết quả nền hỏng"
    end
    return payload.ok == true, payload.result, payload.err
end

function BackgroundFetch.isAvailable()
    return has_buffer == true and type(ffiutil.runInSubProcess) == "function"
end

function BackgroundFetch.isRunning(key)
    return active ~= nil and (key == nil or active.key == key)
end

function BackgroundFetch.cancel(key)
    if active and (key == nil or active.key == key) then
        abort(active, "cancelled")
    end
end

-- task() chạy trong tiến trình con, trả về dữ liệu thuần (bảng/chuỗi/số).
-- on_done(ok, result, err) chạy ở tiến trình chính. Cùng key với việc đang
-- chạy thì chỉ chờ chung; khác key thì việc cũ bị hủy ("cancelled").
-- Trả về false nếu không chạy nền được (người gọi tự chạy theo cách cũ).
function BackgroundFetch.run(key, task, on_done, opts)
    opts = opts or {}
    if not BackgroundFetch.isAvailable() then
        return false
    end
    if active and active.key == key then
        table.insert(active.callbacks, on_done)
        return true
    end
    if active then
        abort(active, "cancelled")
    end

    local ok_fork, pid, fd = pcall(ffiutil.runInSubProcess, function(_, child_write_fd)
        local ok, result = pcall(task)
        local payload = ok and { ok = true, result = Util.plainData(result) }
            or { ok = false, err = tostring(result) }
        local encoded_ok, content = pcall(buffer.encode, payload)
        if not encoded_ok then
            content = buffer.encode({ ok = false, err = "Không mã hóa được kết quả" })
        end
        ffiutil.writeToFD(child_write_fd, content, true)
    end, true)
    if not ok_fork or not pid then
        Debug.write("[Nền] Không tạo được tiến trình con: " .. tostring(ok_fork and fd or pid))
        return false
    end

    local job = {
        key = key,
        pid = pid,
        fd = fd,
        callbacks = { on_done },
        waited = 0,
        timeout = opts.timeout or BackgroundFetch.timeout,
        interval = BackgroundFetch.first_interval,
        polls = 0,
    }
    active = job

    job.poll = function()
        if job.finished then
            return
        end
        local done = ffiutil.isSubProcessDone(job.pid)
        local readable = job.fd and ffiutil.getNonBlockingReadSize(job.fd) ~= 0
        if readable or done then
            local content = job.fd and ffiutil.readAllFromFD(job.fd)
            job.fd = nil
            if not done then
                collectLater(job.pid, nil)
            end
            finish(job, decode(content))
            return
        end
        if job.waited >= job.timeout then
            Debug.write("[Nền] Quá thời gian chờ: " .. tostring(job.key))
            abort(job, "Quá thời gian chờ")
            return
        end
        job.polls = job.polls + 1
        if job.polls % BackgroundFetch.polls_per_step == 0 then
            job.interval = math.min(job.interval * 2, BackgroundFetch.max_interval)
        end
        job.waited = job.waited + job.interval
        UIManager:scheduleIn(job.interval, job.poll)
    end
    job.waited = job.interval
    UIManager:scheduleIn(job.interval, job.poll)
    return true
end

return BackgroundFetch
