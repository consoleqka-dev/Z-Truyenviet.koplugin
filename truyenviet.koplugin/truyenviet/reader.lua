local Event = require("ui/event")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local Debug = require("truyenviet/debugger")
local ChapterPosition = require("truyenviet/chapter_position")

local Reader = {
    active = false,
    returning = false,
    on_return_callback = nil,
    on_next_chapter_callback = nil,
    on_prev_chapter_callback = nil,
    position = nil,
    -- Mở tệp trọn bộ ở một chương: { path, page, number, on_chapter } chờ
    -- sách mở xong.
    start_page = nil,
    -- Tăng mỗi lần mở chương; reader chỉ được kết thúc phiên của chính nó.
    session = 0,
}

-- Ghi "Chương X/Y" cho file sắp mở; thanh trạng thái chỉ hiện khi đúng file đó.
function Reader:setPosition(path, text)
    self.position = text and { path = path, text = text } or nil
end

-- Mở tệp trọn bộ: sau khi KOReader khôi phục trang đọc dở thì nhảy tới trang
-- đầu chương number (page), trừ khi trang đọc dở đã nằm trong chương đó.
-- on_chapter(number) chạy mỗi khi lật sang chương khác trong tệp này.
function Reader:setStartPage(path, page, number, on_chapter)
    self.start_page = path and page and {
        path = path, page = page, number = number, on_chapter = on_chapter,
    } or nil
end

-- Trang hiện tại khi sách đang mở đúng là path; nil nếu không.
function Reader:openBookPage(path)
    local ui = ReaderUI.instance
    local file = ui and ui.document and ui.document.file
    if file and ChapterPosition.samePath(file, path) and type(ui.getCurrentPage) == "function" then
        return ui:getCurrentPage()
    end
    return nil
end

-- Lật sách đang mở tới page; false khi sách đang mở không phải path.
function Reader:gotoPageInOpenBook(path, page)
    if not page or not self:openBookPage(path) then
        return false
    end
    ReaderUI.instance:handleEvent(Event:new("GotoPage", page))
    return true
end

-- Mở thẳng file trong thư mục tải của plugin (Lịch sử KOReader, trình duyệt
-- file...): vị trí trong số chương đã tải của truyện đó.
function Reader:positionText(file)
    local position = self.position
    if position and ChapterPosition.samePath(position.path, file) then
        return position.text
    end
    local Storage = require("truyenviet/storage")
    local dir = ChapterPosition.downloadFolder(Storage:getRootDir(), file)
    local index = dir and Storage:getOfflineIndex(dir)
    if not index then
        return nil
    end
    -- Tệp trọn bộ: KOReader đã hiện tên chương theo mục lục.
    local name = type(file) == "string" and file:match("([^/]+)$")
    if index.bundles and name and index.bundles[name] then
        return nil
    end
    local paths = {}
    for i, name in ipairs(index.files) do
        paths[i] = dir .. "/" .. name
    end
    return ChapterPosition.format(ChapterPosition.fromFolder(paths, file, "Chương"))
end

-- Mở sách từ Lịch sử/Bộ sưu tập, KOReader tự đóng các danh sách đó. Plugin mở
-- reader trực tiếp nên phải tự đóng: danh sách còn nằm dưới reader thì Exit chỉ
-- đóng reader, KOReader không thoát.
local function closeBookLists()
    local FileManager = require("apps/filemanager/filemanager")
    local closed = 0
    local uis = { FileManager.instance or false, ReaderUI.instance or false }
    for _, ui in ipairs(uis) do
        for _, name in ipairs({ "history", "collections" }) do
            for _, key in ipairs({ "booklist_menu", "coll_list" }) do
                local module = ui and ui[name]
                local menu = module and module[key]
                if menu and menu.close_callback then
                    local ok, err = pcall(menu.close_callback, true)
                    if ok then
                        closed = closed + 1
                    else
                        Debug.write("Reader: failed to close KOReader " .. key .. ": " .. tostring(err))
                    end
                end
            end
        end
    end
    if closed > 0 then
        Debug.write("Reader: closed " .. closed .. " KOReader book list(s) before opening a chapter")
    end
end

local function openReader(path)
    closeBookLists()
    UIManager:broadcastEvent(Event:new("SetupShowReader"))
    ReaderUI:showReader(path)
end

function Reader:show(path, on_return_callback, on_next_chapter_callback, from_reader, on_prev_chapter_callback)
    self.session = self.session + 1
    self.on_return_callback = on_return_callback
    self.on_next_chapter_callback = on_next_chapter_callback
    self.on_prev_chapter_callback = on_prev_chapter_callback

    Debug.write("Reader:show path=" .. tostring(path) .. ", from_reader=" .. tostring(from_reader))

    if self.active and ReaderUI.instance then
        logger.info("TruyenViet: performing async switch with muted FileManager, from_reader=" .. tostring(from_reader))
        local current_ui = ReaderUI.instance
        local InfoMessage = require("ui/widget/infomessage")
        local FileManager = require("apps/filemanager/filemanager")
        
        local loading_msg = InfoMessage:new{
            text = "Đang chuyển chương...",
        }
        
        UIManager:nextTick(function()
            UIManager:show(loading_msg)
            
            -- Mute FileManager to prevent it from stealing focus
            local old_onCloseReader = nil
            if FileManager.instance and FileManager.instance.onCloseReader then
                old_onCloseReader = FileManager.instance.onCloseReader
                FileManager.instance.onCloseReader = function() end
            end
            
            if not from_reader and current_ui then
                current_ui:onClose()
            end
            
            -- Restore FileManager
            if FileManager.instance and old_onCloseReader then
                FileManager.instance.onCloseReader = old_onCloseReader
            end
            
            -- Wait for C engines to fully release file locks and memory
            UIManager:scheduleIn(0.6, function()
                openReader(path)
                UIManager:close(loading_msg)
            end)
        end)
    else
        openReader(path)
    end
    self.active = true
end

function Reader:initializeFromReaderUI(ui)
    ui.menu:registerToMainMenu(self)

    -- Tệp trọn bộ mở từ danh sách chương: { file, number, callback } để báo
    -- chương đang đọc mỗi lần lật sang chương khác.
    local chapter_watch
    local function followBundleChapter()
        local page = chapter_watch and type(ui.getCurrentPage) == "function" and ui:getCurrentPage()
        if not page then
            return
        end
        local Storage = require("truyenviet/storage")
        local number = Storage:bundleChapterAt(chapter_watch.file, page)
        if number and number ~= chapter_watch.number then
            chapter_watch.number = number
            local ok, err = pcall(chapter_watch.callback, number)
            if not ok then
                Debug.write("Reader: bundle chapter callback failed: " .. tostring(err))
            end
        end
    end

    -- ReadSettings (khôi phục last_page) chạy trước PostReaderReady nên trang
    -- nhảy tới ở đây không bị ghi đè.
    if type(ui.registerPostReaderReadyCallback) == "function" then
        ui:registerPostReaderReadyCallback(function()
            local start = self.start_page
            local file = ui.document and ui.document.file
            if not start or not ChapterPosition.samePath(start.path, file) then
                return
            end
            self.start_page = nil
            if type(start.on_chapter) == "function" and start.number then
                chapter_watch = { file = file, number = start.number, callback = start.on_chapter }
            end
            local current = type(ui.getCurrentPage) == "function" and ui:getCurrentPage()
            if start.number and current then
                local Storage = require("truyenviet/storage")
                if Storage:bundleChapterAt(file, current) == start.number then
                    Debug.write("Reader: bundle reopened inside chapter " .. tostring(start.number) .. ", page kept")
                    return
                end
            end
            Debug.write("Reader: bundle jumps to page " .. tostring(start.page))
            ui:handleEvent(Event:new("GotoPage", start.page))
            followBundleChapter()
        end)
    end
    
    ui:registerPostInitCallback(function()
        local listener = WidgetContainer:new({})
        local session = self.session
        local record_progress
        if self.on_return_callback then
            record_progress = require("truyenviet/reading_progress").observe(ui)
            listener.onPosUpdate = record_progress
            listener.onSaveSettings = record_progress
        end
        listener.onPageUpdate = function(...)
            if record_progress then
                record_progress(...)
            end
            followBundleChapter()
        end

        local footer = ui.view and ui.view.footer
        local position_content
        if footer and type(footer.addAdditionalFooterContent) == "function" then
            local file = ui.document and ui.document.file
            local ok, text = pcall(self.positionText, self, file)
            if ok and text then
                position_content = function()
                    return text
                end
                footer:addAdditionalFooterContent(position_content)
            end
        end

        -- Tải nền đang chạy: thêm "⤓ x/y" vào thanh trạng thái, gỡ khi xong.
        local DownloadJob = require("truyenviet/download_job")
        local download_content
        local download_text
        local function onDownloadProgress(status)
            if not footer or type(footer.addAdditionalFooterContent) ~= "function" then
                return
            end
            local text = status and DownloadJob.progressText()
            if text == download_text then
                return
            end
            download_text = text
            if text and not download_content then
                download_content = function()
                    return download_text
                end
                footer:addAdditionalFooterContent(download_content)
            elseif not text and download_content then
                footer:removeAdditionalFooterContent(download_content)
                download_content = nil
            end
            if type(footer.onUpdateFooter) == "function" then
                footer:onUpdateFooter(ui.view and ui.view.footer_visible)
            end
        end
        DownloadJob.subscribe(onDownloadProgress)
        onDownloadProgress(DownloadJob.status())

        -- Exit/Restart của KOReader chỉ đóng reader rồi để KOReader tự thoát khi
        -- không còn cửa sổ nào: mở lại danh sách chương sẽ giữ KOReader sống.
        local quitting
        listener.onExit = function()
            quitting = "Exit"
            Debug.write("Reader: KOReader Exit while a chapter is open")
            DownloadJob.cancel("exit")
        end
        listener.onRestart = function()
            quitting = "Restart"
            Debug.write("Reader: KOReader Restart while a chapter is open")
            DownloadJob.cancel("exit")
        end

        listener.onCloseWidget = function()
            DownloadJob.unsubscribe(onDownloadProgress)
            if position_content then
                footer:removeAdditionalFooterContent(position_content)
            end
            if download_content then
                footer:removeAdditionalFooterContent(download_content)
                download_content = nil
            end
            -- Mở chương khác khi chương này còn mở: chương này đóng sau khi phiên
            -- mới đã bắt đầu, không được tắt phiên hay gọi callback quay về của nó.
            if session ~= self.session then
                Debug.write("Reader:onCloseWidget from an earlier chapter, session kept")
                return
            end
            self.active = false
            if quitting then
                self.on_return_callback = nil
                Debug.write("Reader:onCloseWidget by KOReader " .. quitting .. ", not reopening Truyện Việt")
            elseif self.returning then
                Debug.write("Reader:onCloseWidget by Truyện Việt")
            elseif self.on_return_callback then
                Debug.write("Reader:onCloseWidget, returning to Truyện Việt")
                local UIManager = require("ui/uimanager")
                local callback = self.on_return_callback
                self.on_return_callback = nil
                -- Use nextTick to ensure the reader is fully closed before showing the browser
                UIManager:nextTick(callback)
            else
                Debug.write("Reader:onCloseWidget, no return callback")
            end
        end

        listener.onEndOfBook = function()
            Debug.write("Reader:onEndOfBook triggered, has_callback=" .. tostring(self.on_next_chapter_callback ~= nil))
            if self.on_next_chapter_callback then
                -- signal that the callback is invoked from inside the Reader
                self.on_next_chapter_callback(true)
                Debug.write("Reader:onEndOfBook called on_next_chapter_callback (from_reader=true)")
                return true
            end
        end

        table.insert(ui, 2, listener)
    end)
end

function Reader:addToMainMenu(menu_items)
    menu_items.go_back_to_truyenviet = {
        text = "Quay lại Truyện Việt",
        sorting_hint = "main",
        callback = function()
            -- Sách mở ngoài plugin không có màn để quay về: đóng sách, mở trang chủ.
            if self.active then
                self:returnToPlugin()
            else
                require("truyenviet/browser"):showRoot()
            end
        end,
    }
    if self.on_next_chapter_callback then
        menu_items.truyenviet_next_chapter = {
            text = "Chương tiếp theo",
            sorting_hint = "main",
            callback = function()
                if self.on_next_chapter_callback then
                    self.on_next_chapter_callback(false)
                end
            end,
        }
    end
    if self.on_prev_chapter_callback then
        menu_items.truyenviet_prev_chapter = {
            text = "Chương trước",
            sorting_hint = "main",
            callback = function()
                if self.on_prev_chapter_callback then
                    self.on_prev_chapter_callback(false)
                end
            end,
        }
    end
end

-- Đóng sách đang mở rồi chạy callback_override (hoặc màn quay về của chương).
-- Sách mở ngoài plugin (file "Trên máy", File manager) cũng được đóng.
function Reader:returnToPlugin(callback_override)
    Debug.write("Reader:returnToPlugin called")
    if self.returning or not (self.active or ReaderUI.instance) then
        Debug.write("Reader:returnToPlugin early return, returning=" .. tostring(self.returning) .. ", active=" .. tostring(self.active))
        return
    end
    self.returning = true

    local callback = callback_override or self.on_return_callback
    self.active = false
    self.on_return_callback = nil
    self.on_next_chapter_callback = nil

    UIManager:nextTick(function()
        local FileManager = require("apps/filemanager/filemanager")
        Debug.write("Reader:returnToPlugin closing reader (if exists) and restoring FileManager")
        if ReaderUI.instance then
            Debug.write("Reader:returnToPlugin: ReaderUI.instance exists, calling onClose()")
            ReaderUI.instance:onClose()
        end
        if FileManager.instance then
            Debug.write("Reader:returnToPlugin: FileManager.instance.reinit()")
            FileManager.instance:reinit()
        else
            Debug.write("Reader:returnToPlugin: FileManager.showFiles()")
            FileManager:showFiles()
        end
        self.returning = false
        if callback then
            UIManager:nextTick(callback)
        end
    end)
end

return Reader
