local Dispatcher = require("dispatcher")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Browser = require("truyenviet/browser")
local Reader = require("truyenviet/reader")
local Version = require("truyenviet/version")

local TruyenViet = WidgetContainer:extend{
    name = "truyenviet",
    title = "Truyện Việt",
    fullname = "Truyện Việt",
    is_doc_only = false,
    VERSION = Version,
}

-- ZenOS launch methods. Do not define onShow/onOpen: KOReader broadcasts
-- Show/Open events to plugin modules, which would reopen the browser over
-- a freshly opened chapter.
function TruyenViet:show()
    Browser:showRoot()
end

function TruyenViet:open()
    Browser:showRoot()
end

function TruyenViet:launch()
    Browser:showRoot()
end

function TruyenViet:onTruyenviet()
    Browser:showRoot()
end

-- Đổi tên/dời file hay thư mục trong File manager: KOReader không phát sự
-- kiện nào nhưng luôn gọi ReadHistory để sửa lịch sử của nó. Bọc các hàm đó
-- (một lần cho cả phiên) để sửa luôn mục "Trên máy" trong Tủ truyện/Lịch sử.
function TruyenViet.hookReadHistory()
    local ok, ReadHistory = pcall(require, "readhistory")
    if not ok or type(ReadHistory) ~= "table" or ReadHistory._truyenviet_relocate then
        return
    end
    ReadHistory._truyenviet_relocate = true
    local function relocate(old_path, new_path)
        local LocalLibrary = require("truyenviet/local_library")
        local relocated, err = pcall(LocalLibrary.relocate, old_path, new_path)
        if not relocated then
            require("truyenviet/debugger").write("[Trên máy] Không dời được: " .. tostring(err))
        end
    end
    local function wrap(name, after)
        local original = ReadHistory[name]
        if type(original) ~= "function" then
            return
        end
        ReadHistory[name] = function(self, old_path, new_path, ...)
            local function done(...)
                after(old_path, new_path)
                return ...
            end
            return done(original(self, old_path, new_path, ...))
        end
    end
    wrap("updateItem", relocate)
    wrap("updateItemsByPath", relocate)
    wrap("updateItems", function(files, new_dir)
        if type(files) ~= "table" or type(new_dir) ~= "string" then
            return
        end
        for file in pairs(files) do
            if type(file) == "string" then
                relocate(file, new_dir .. "/" .. (file:match("([^/]+)/*$") or file))
            end
        end
    end)
end

function TruyenViet:init()
    local FontHelper = require("truyenviet/font_helper")
    FontHelper:setupFont()

    if self.ui then
        self.ui.truyenviet = self
    end

    TruyenViet.hookReadHistory()

    if self.ui.name == "ReaderUI" then
        Reader:initializeFromReaderUI(self.ui)
    end

    if self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    local UIManager = require("ui/uimanager")
    UIManager:nextTick(function()
        if self.ui.title_bar and not self._topbar_button_added then
            self._topbar_button_added = true
            if type(self.ui.title_bar.addButton) == "function" then
                self.ui.title_bar:addButton({
                    icon = "book",
                    title = "Truyện Việt v" .. Version,
                    callback = function()
                        Browser:showRoot()
                    end,
                })
            end
        end
    end)

    self:onDispatcherRegisterActions()
    self:openOnStart()

    local Updater = require("truyenviet/updater")
    Updater:scheduleBackgroundCheck()
end

-- Mỗi lần KOReader khởi động chỉ mở một lần, ở plugin được nạp đầu tiên.
-- Không dựa vào profile "on KOReader start": khi KOReader khởi động vào màn
-- Lịch sử, sự kiện của profile chỉ tới màn Lịch sử và bị bỏ qua.
local start_checked = false

function TruyenViet:openOnStart()
    if start_checked then
        return
    end
    start_checked = true
    local Storage = require("truyenviet/storage")
    if not Storage:isOpenOnStartEnabled() then
        return
    end
    -- nextTick chạy sau khi KOReader đã mở Lịch sử / Yêu thích nên Truyện Việt nằm trên cùng.
    require("ui/uimanager"):nextTick(function()
        Browser:showRoot()
    end)
end

function TruyenViet:onDispatcherRegisterActions()
    -- KOReader's Dispatcher treats `reader = true` as reader-only and skips the
    -- action in the file browser and History, so gestures and profiles bound
    -- to it do nothing there. Only chapter actions keep the flag.
    Dispatcher:registerAction("start_truyenviet", {
        category = "none",
        event = "StartTruyenViet",
        title = "Truyện Việt",
        general = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_chapter_list", {
        category = "none",
        event = "TruyenVietBackToChapters",
        title = "☰ Truyện Việt: Danh sách chương",
        general = true,
        reader = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_continue", {
        category = "none",
        event = "TruyenVietContinue",
        title = "▶ Truyện Việt: Tiếp tục đọc",
        general = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_history", {
        category = "none",
        event = "TruyenVietHistory",
        title = "⟲ Truyện Việt: Lịch sử đọc",
        general = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_downloaded", {
        category = "none",
        event = "TruyenVietDownloaded",
        title = "⤓ Truyện Việt: Đã tải xuống",
        general = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_next_chapter", {
        category = "none",
        event = "TruyenVietNextChapter",
        title = "➡ Truyện Việt: Chương tiếp",
        general = true,
        reader = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_prev_chapter", {
        category = "none",
        event = "TruyenVietPrevChapter",
        title = "⬅ Truyện Việt: Chương trước",
        general = true,
        reader = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_story_page", {
        category = "none",
        event = "TruyenVietStoryPage",
        title = "⌂ Truyện Việt: Về nguồn",
        general = true,
        reader = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_gdrive_download", {
        category = "none",
        event = "TruyenVietGDriveDownload",
        title = "☁ Truyện Việt: Tải từ Google Drive",
        general = true,
        filemanager = true,
        plugin = true,
    })

    Dispatcher:registerAction("truyenviet_check_update", {
        category = "none",
        event = "TruyenVietCheckUpdate",
        title = "↻ Truyện Việt: Kiểm tra cập nhật OTA",
        general = true,
        filemanager = true,
        plugin = true,
    })
end

function TruyenViet:addToMainMenu(menu_items)
    local clean_title = "Truyện Việt"

    local sub_items = {
        {
            text = "🔥 Mở Truyện Việt (Trang chủ)",
            callback = function()
                self:onStartTruyenViet()
            end,
        },
        {
            text = "▶ Tiếp tục đọc",
            callback = function()
                self:onTruyenVietContinue()
            end,
        },
        {
            text = "☰ Danh sách chương",
            callback = function()
                self:onTruyenVietBackToChapters()
            end,
        },
        {
            text = "➡ Chương tiếp",
            callback = function()
                self:onTruyenVietNextChapter()
            end,
        },
        {
            text = "⬅ Chương trước",
            callback = function()
                self:onTruyenVietPrevChapter()
            end,
        },
        {
            text = "⌂ Về nguồn truyện",
            callback = function()
                self:onTruyenVietStoryPage()
            end,
        },
        {
            text = "⟲ Lịch sử đọc",
            callback = function()
                self:onTruyenVietHistory()
            end,
        },
        {
            text = "⤓ Đã tải xuống",
            callback = function()
                self:onTruyenVietDownloaded()
            end,
        },
        {
            text_func = function()
                local status = require("truyenviet/download_job").status()
                if status then
                    return string.format("⤓ Hủy tải nền (%d/%d)", status.done or 0, status.total or 0)
                end
                return "⤓ Hủy tải nền (không có việc)"
            end,
            enabled_func = function()
                return require("truyenviet/download_job").isRunning()
            end,
            callback = function()
                require("truyenviet/download_job").cancel("cancelled")
            end,
        },
        {
            text = "☁ Tải từ Google Drive",
            callback = function()
                self:onTruyenVietGDriveDownload()
            end,
        },
        {
            text = "↻ Kiểm tra cập nhật OTA",
            callback = function()
                self:onTruyenVietCheckUpdate()
            end,
        },
        {
            text = "Mở Truyện Việt khi khởi động KOReader",
            checked_func = function()
                return require("truyenviet/storage"):isOpenOnStartEnabled()
            end,
            callback = function()
                local Storage = require("truyenviet/storage")
                Storage:setOpenOnStartEnabled(not Storage:isOpenOnStartEnabled())
            end,
        },
    }

    menu_items.truyenviet = {
        text = clean_title,
        callback = function()
            self:onStartTruyenViet()
        end,
        sorting_hint = "tools",
        sub_item_table = sub_items,
    }

    if self.ui and self.ui.name == "ReaderUI" then
        menu_items.truyenviet_reader_tools = {
            text = clean_title,
            callback = function()
                self:onStartTruyenViet()
            end,
            sorting_hint = "tools",
            sub_item_table = sub_items,
        }
    else
        menu_items.truyenviet_search = {
            text = clean_title,
            callback = function()
                self:onStartTruyenViet()
            end,
            sorting_hint = "search",
            sub_item_table = sub_items,
        }
        menu_items.truyenviet_tools = {
            text = clean_title,
            callback = function()
                self:onStartTruyenViet()
            end,
            sorting_hint = "tools",
            sub_item_table = sub_items,
        }
    end
end

-- Exit/Restart từ File manager hoặc danh sách: dừng việc tải nền để không
-- còn tiến trình con chạy sau khi KOReader thoát.
function TruyenViet:onExit()
    local DownloadJob = package.loaded["truyenviet/download_job"]
    if DownloadJob then
        DownloadJob.cancel("exit")
    end
end

function TruyenViet:onRestart()
    self:onExit()
end

-- Mở file thuộc mục "Trên máy" (từ Tủ truyện, File manager, lịch sử
-- KOReader...) thì ghi vào Lịch sử đọc. Không trả về true để sự kiện
-- ReaderReady vẫn tới các module khác.
function TruyenViet:onReaderReady()
    local document = self.ui and self.ui.document
    local file = document and document.file
    if type(file) == "string" then
        local LocalLibrary = require("truyenviet/local_library")
        local ok, err = pcall(LocalLibrary.recordRead, file)
        if not ok then
            require("truyenviet/debugger").write("[Lịch sử] Không ghi được: " .. tostring(err))
        end
    end
end

function TruyenViet:onStartTruyenViet()
    Browser:showRoot()
end

function TruyenViet:onTruyenVietBackToChapters()
    local Reader = require("truyenviet/reader")
    local ReaderUI = require("apps/reader/readerui")
    if Reader.active and ReaderUI.instance then
        Reader:returnToPlugin()
        return
    end
    local function openLatest()
        local Storage = require("truyenviet/storage")
        local LocalLibrary = require("truyenviet/local_library")
        local history = Storage:getHistory()
        local latest = history[1]
        if not latest then
            Browser:showRoot()
            return
        end
        local function back()
            Browser:showRoot()
        end
        -- Mục "Trên máy": danh sách tập trong thư mục thay cho mục lục.
        if LocalLibrary.isLocal(latest.story) and LocalLibrary.entryType(latest.story.url) == "dir" then
            Browser:openLocalEntry(latest.story, nil, back)
        elseif not Browser:openHistoryItem(latest, back) then
            Browser:showHistory(back)
        end
    end
    -- Sách mở ngoài plugin: đóng trước, danh sách chương không nằm đè lên sách.
    if ReaderUI.instance then
        Reader:returnToPlugin(openLatest)
    else
        openLatest()
    end
end

function TruyenViet:onTruyenVietContinue()
    local Storage = require("truyenviet/storage")
    local latest = Storage:getHistory()[1]
    if not latest then
        Browser:showRoot()
        return
    end
    Browser:confirmContinue(latest, nil, function()
        Browser:showRoot()
    end)
end

function TruyenViet:onTruyenVietHistory()
    Browser:showHistory(function() Browser:showRoot() end)
end

function TruyenViet:onTruyenVietDownloaded()
    Browser:showDownloadedManager(function() Browser:showRoot() end)
end

function TruyenViet:onTruyenVietGDriveDownload()
    Browser:showGDriveDownloadDialog(function()
        Browser:showRoot()
    end)
end

function TruyenViet:onTruyenVietCheckUpdate()
    local Updater = require("truyenviet/updater")
    Updater:checkManually(function()
        Browser:showRoot()
    end)
end






function TruyenViet:onTruyenVietNextChapter()
    local Reader = require("truyenviet/reader")
    if Reader.on_next_chapter_callback then
        Reader.on_next_chapter_callback(true)
    end
end

function TruyenViet:onTruyenVietPrevChapter()
    local Reader = require("truyenviet/reader")
    if Reader.on_prev_chapter_callback then
        Reader.on_prev_chapter_callback(true)
    end
end

function TruyenViet:onTruyenVietStoryPage()
    local Reader = require("truyenviet/reader")
    if Reader.active then
        Reader:returnToPlugin(function()
            Browser:showRoot()
        end)
    else
        Browser:showRoot()
    end
end
return TruyenViet
