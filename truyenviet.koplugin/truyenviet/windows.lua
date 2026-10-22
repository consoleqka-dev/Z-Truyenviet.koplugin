-- Các cửa sổ Truyện Việt đang mở. Mở trang chủ thì đóng hết cửa sổ cũ thay vì
-- chồng thêm một lớp lên trên.
local UIManager = require("ui/uimanager")

local Windows = {
    open = setmetatable({}, { __mode = "k" }),
}

function Windows.track(widget)
    Windows.open[widget] = true
end

function Windows.untrack(widget)
    Windows.open[widget] = nil
end

function Windows.count()
    local count = 0
    for _ in pairs(Windows.open) do
        count = count + 1
    end
    return count
end

-- Đóng mà không chạy callback quay về của từng cửa sổ: các callback đó sẽ mở
-- lại màn trước, đúng thứ đang cần dọn.
function Windows.closeAll()
    local widgets = {}
    for widget in pairs(Windows.open) do
        widgets[#widgets + 1] = widget
    end
    for _, widget in ipairs(widgets) do
        widget._truyenviet_closed = true
        widget.on_return_callback = nil
        Windows.open[widget] = nil
        UIManager:close(widget)
    end
    return #widgets
end

return Windows
