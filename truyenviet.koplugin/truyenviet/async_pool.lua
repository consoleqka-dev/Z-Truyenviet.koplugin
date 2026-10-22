-- AsyncPool: chạy nhiều tác vụ song song trên Copas với hạn chót (deadline).
--
-- Quy ước quan trọng (đã rút ra từ các lỗi re-entrancy trước đây):
--   * Ngoài pool (coroutine chính hoặc coroutine của Trapper:wrap): thêm thread
--     bằng copas.addthread rồi tự "bơm" vòng lặp bằng copas.step(0.05).
--   * Trong một thread của pool (gọi lồng): TUYỆT ĐỐI KHÔNG gọi copas.step vì
--     Copas không cho phép step lồng nhau; chỉ chờ bằng copas.sleep (yield về
--     bộ điều phối của Copas) rồi poll.
--   * Coroutine của Trapper KHÔNG phải thread của pool: nó chỉ là coroutine
--     thường, nên inPoolThread() trả về false ở đó và HTTP vẫn chạy đồng bộ.
--   * Không có Copas -> chạy tuần tự như hành vi cũ.

local AsyncPool = {}

local DEFAULT_CONCURRENCY = 6
local DEFAULT_DEADLINE = 15
local POLL_INTERVAL = 0.05

local ok_copas, copas = pcall(require, "copas")
if not ok_copas or type(copas) ~= "table"
        or type(copas.addthread) ~= "function"
        or type(copas.removethread) ~= "function" then
    copas = nil
end

local ok_socket, socket = pcall(require, "socket")
local socket_gettime = ok_socket and type(socket) == "table"
    and type(socket.gettime) == "function" and socket.gettime or nil

local function now()
    if socket_gettime then
        return socket_gettime()
    end
    return os.time()
end

-- Thread do pool tạo -> trạng thái của lượt chạy (run) sở hữu thread đó.
-- Khoá yếu để thread đã chết được GC; state.threads cũng là bảng giá trị yếu
-- để không tạo vòng tham chiếu state -> thread -> state (Lua 5.1 không có
-- ephemeron nên vòng này sẽ không bao giờ được dọn).
local pool_threads = setmetatable({}, { __mode = "k" })

function AsyncPool.inPoolThread()
    local co = coroutine.running()
    return co ~= nil and pool_threads[co] ~= nil
end

-- Task có thể gọi để tự dừng sớm khi lượt chạy đã bị huỷ (quá hạn).
function AsyncPool.isCancelled()
    local state = pool_threads[coroutine.running()]
    return state ~= nil and state.cancelled == true
end

local function cancelState(state)
    if state.cancelled then
        return
    end
    state.cancelled = true
    for _, co in pairs(state.threads) do
        pcall(copas.removethread, co)
    end
    for _, child in ipairs(state.children) do
        cancelState(child)
    end
end

local function finish(entry, ok, ...)
    entry.done = true
    entry.ok = ok and true or false
    if ok then
        entry.values = { n = select("#", ...), ... }
    else
        entry.values = (...)
    end
end

-- Chạy `tasks` (mảng function) song song.
-- opts.concurrency: số thread tối đa chạy cùng lúc (mặc định 6)
-- opts.deadline: tổng thời gian tối đa tính bằng giây (mặc định 15)
-- Trả về mảng results theo đúng index của tasks, mỗi phần tử:
--   { done = true,  ok = true,  values = { n = <số giá trị>, ... } }  task trả về bình thường
--   { done = true,  ok = false, values = <thông báo lỗi> }             task ném lỗi
--   { done = false, ok = false }                                       chưa xong khi quá hạn
function AsyncPool.run(tasks, opts)
    opts = opts or {}
    local count = #tasks
    local results = {}
    for index = 1, count do
        results[index] = { done = false, ok = false }
    end
    if count == 0 then
        return results
    end

    local deadline = tonumber(opts.deadline) or DEFAULT_DEADLINE
    local concurrency = math.floor(tonumber(opts.concurrency) or DEFAULT_CONCURRENCY)
    if concurrency < 1 then
        concurrency = 1
    end
    local expires_at = now() + deadline

    -- Không có Copas: chạy tuần tự, vẫn tôn trọng hạn chót giữa các task.
    if not copas then
        for index = 1, count do
            if index > 1 and now() >= expires_at then
                break
            end
            finish(results[index], pcall(tasks[index]))
        end
        return results
    end

    local parent_state = pool_threads[coroutine.running()]
    local in_pool = parent_state ~= nil
    local state = {
        cancelled = false,
        threads = setmetatable({}, { __mode = "v" }),
        children = {},
    }
    if parent_state then
        -- Để khi lượt chạy cha bị huỷ thì lượt chạy lồng này cũng bị huỷ theo
        table.insert(parent_state.children, state)
    end

    local next_index = 1
    local finished = 0
    local function worker()
        pool_threads[coroutine.running()] = state
        while not state.cancelled and next_index <= count do
            local index = next_index
            next_index = index + 1
            finish(results[index], pcall(tasks[index]))
            finished = finished + 1
        end
    end

    -- Giữ tham chiếu mạnh tới các thread cho tới khi lượt chạy kết thúc
    -- (state.threads chỉ giữ tham chiếu yếu).
    local strong_threads = {}
    for slot = 1, math.min(concurrency, count) do
        local co = copas.addthread(worker)
        strong_threads[slot] = co
        state.threads[slot] = co
    end

    while finished < count and now() < expires_at do
        if in_pool then
            -- Gọi lồng: chỉ yield về Copas, không bao giờ step.
            copas.sleep(POLL_INTERVAL)
        else
            local ok_step = pcall(copas.step, POLL_INTERVAL)
            if not ok_step then
                break
            end
        end
    end

    if finished < count then
        cancelState(state)
    end
    if parent_state then
        for index, child in ipairs(parent_state.children) do
            if child == state then
                table.remove(parent_state.children, index)
                break
            end
        end
    end
    return results
end

return AsyncPool
