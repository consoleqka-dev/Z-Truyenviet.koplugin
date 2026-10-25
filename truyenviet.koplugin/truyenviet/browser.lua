local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Device = require("device")
local Screen = Device.screen
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")

local AsyncPool = require("truyenviet/async_pool")
local Builder = require("truyenviet/document_builder")
local BackgroundFetch = require("truyenviet/background_fetch")
local ChapterCache = require("truyenviet/chapter_cache")
local ChapterOrder = require("truyenviet/chapter_order")
local ChapterPosition = require("truyenviet/chapter_position")
local ChapterDownloader = require("truyenviet/chapter_downloader")
local CoverCache = require("truyenviet/cover_cache")
local CredentialManager = require("truyenviet/credential_manager")
local LocalLibrary = require("truyenviet/local_library")
local Reader = require("truyenviet/reader")
local ReadingProgress = require("truyenviet/reading_progress")
local SearchService = require("truyenviet/search_service")
local SourceRegistry = require("truyenviet/source_registry")
local Storage = require("truyenviet/storage")
local StoryResults = require("truyenviet/widgets/story_results")
local Version = require("truyenviet/version")
local Debug = require("truyenviet/debugger")
local Util = require("truyenviet/helpers")
local Windows = require("truyenviet/windows")

-- Tiến độ đọc của chương đã tải: chương trong tệp trọn bộ lấy tiến độ riêng
-- theo số chương, chương lẻ lấy tiến độ của cả file. nil là chưa có dữ liệu đọc.
local function chapterPercent(source, story, chapter, cache)
    local path = Storage:getBundleChapter(source, story, chapter)
    if path then
        return ReadingProgress.percent(path, Storage.chapterNumberOf(chapter), cache)
    end
    return ReadingProgress.percent(Builder:getExistingPath(source, story, chapter), nil, cache)
end

local function autoOpenChapter(chapters, selection)
    if type(selection) == "table" then
        return selection
    end
    if selection == "last" then
        return chapters[#chapters]
    end
    return chapters[1]
end

local ListView = Menu:extend{
    is_popout = false,
    title_bar_left_icon = "chevron.left",
}

function ListView:init()
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    Menu.init(self)
    Windows.track(self)
end

function ListView:onLeftButtonTap()
    self:onClose()
end

function ListView:onClose()
    if self._truyenviet_closed then
        return true
    end
    self._truyenviet_closed = true
    local callback = self.on_return_callback
    self.on_return_callback = nil
    UIManager:close(self)
    if callback then
        UIManager:nextTick(callback)
    end
    return true
end

-- UIManager:close() trực tiếp (closeAndRun, mở chương) không qua onClose;
-- đánh dấu để kết quả làm mới nền không cập nhật view đã đóng.
function ListView:onCloseWidget()
    self._truyenviet_hidden = true
    Windows.untrack(self)
    if Menu.onCloseWidget then
        return Menu.onCloseWidget(self)
    end
end

function ListView:onMenuHold(item)
    if item.hold_callback then
        item.hold_callback()
    end
    return true
end

local Browser = {}

local function showError(message, on_close)
    local text = "Truyện Việt\n\n"
        .. tostring(message or "Đã xảy ra lỗi không xác định")
    
    local dialog
    local buttons = {
        {
            {
                text = "Đóng",
                callback = function()
                    UIManager:close(dialog)
                    if on_close then UIManager:nextTick(on_close) end
                end,
            },
        }
    }
    
    local ErrorReporter = require("truyenviet/error_reporter")
    table.insert(buttons, 1, {
        {
            text = "Báo lỗi",
            callback = function()
                UIManager:close(dialog)
                Browser:showErrorReportDialog(tostring(message), on_close)
            end,
        }
    })

    dialog = ButtonDialog:new{
        title = "Thông báo lỗi",
        text = text,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function closeAndRun(widget, callback)
    if widget then
        UIManager:close(widget)
    end
    if callback then
        UIManager:nextTick(callback)
    end
end

local function withLoading(message, callback)
    local loading = InfoMessage:new{
            title = "Truyện Việt",
            text = message,
        dismissable = false,
    }
    UIManager:show(loading)
    UIManager:forceRePaint()

    local ok, result, err = pcall(callback)
    -- Thao tác dài chặn UI: cú chạm trong lúc chờ (vd. phần nhả của nút "Tìm")
    -- nằm lại trong hàng đợi và sẽ rơi vào màn hình mới hiện ra sau đó.
    -- Bỏ input một nhịp ngắn để không mở nhầm truyện trong danh sách kết quả.
    if Device.input and Device.input.inhibitInputUntil then
        Device.input:inhibitInputUntil(true)
    end
    UIManager:close(loading)

    if not ok then
        return nil, tostring(result)
    end
    return result, err
end

-- Bổ sung số chương/trạng thái và tải bìa SONG SONG trong một lượt AsyncPool.
-- CoverCache:prefetch tự bỏ qua khi bật fast_mode; enrich vẫn chạy vì chỉ tốn
-- vài request nhỏ. Lỗi/quá hạn của một việc không ảnh hưởng việc còn lại.
local function enrichAndPrefetch(stories)
    local results = AsyncPool.run({
        function()
            SearchService:enrichMeta(stories, { registry = SourceRegistry })
        end,
        function()
            CoverCache:prefetch(stories, SourceRegistry)
        end,
    }, { concurrency = 2, deadline = 12 })
    for index, label in ipairs({ "bổ sung số chương", "tải bìa" }) do
        local entry = results[index]
        if entry and not entry.done then
            Debug.write("[Browser] Quá hạn khi " .. label)
        elseif entry and not entry.ok then
            Debug.write("[Browser] Lỗi khi " .. label .. ": " .. tostring(entry.values))
        end
    end
end

local function isOnline()
    if NetworkMgr and type(NetworkMgr.isWifiOn) == "function" then
        return NetworkMgr:isWifiOn()
    elseif NetworkMgr and type(NetworkMgr.isWIFIOn) == "function" then
        return NetworkMgr:isWIFIOn()
    elseif NetworkMgr and type(NetworkMgr.isOnline) == "function" then
        return NetworkMgr:isOnline()
    end
    return true
end

-- Ghi md5 cho file "Trên máy" và tìm lại file bị đổi tên ngoài KOReader.
local function healLocalEntries()
    local ok, err = pcall(LocalLibrary.healMissing)
    if not ok then
        Debug.write("[Trên máy] Không tìm lại được mục bị mất: " .. tostring(err))
    end
end

-- Tủ truyện kèm số chương đã tải, loại mục và bìa trong cache.
local function loadFavorites()
    return LocalLibrary.annotate(Storage:listFavorites(), SourceRegistry)
end

local function isDirectory(path)
    local lfs = require("libs/libkoreader-lfs")
    return lfs.attributes(path, "mode") == "directory"
end

local function runOnline(callback)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(callback)
    end)
end

local function showView(title, items, on_return_callback)
    local view = ListView:new{
        title = title,
        item_table = items,
        on_return_callback = on_return_callback,
        covers_fullscreen = true,
    }
    UIManager:show(view)
    return view
end

-- Thư mục không bao giờ bị xóa (kể cả thư mục cha của chúng).
local function protectedDirs()
    local DataStorage = require("datastorage")
    local LibraryImport = require("truyenviet/library_import")
    local dirs = { Storage:getRootDir(), DataStorage:getFullDataDir(),
        "/sdcard", "/storage/emulated/0", "/mnt/onboard", "/mnt/us" }
    for _, dir in ipairs(LibraryImport.libraryDirs()) do
        table.insert(dirs, dir)
    end
    local home = rawget(_G, "G_reader_settings") and G_reader_settings:readSetting("home_dir")
    if type(home) == "string" then
        table.insert(dirs, home)
    end
    return dirs
end

-- with_size: thêm dung lượng sau mỗi đường dẫn.
local function pathList(paths, limit, with_size)
    limit = limit or 5
    local lines = {}
    for index, path in ipairs(paths) do
        if index > limit then
            table.insert(lines, string.format("… và %d mục khác", #paths - limit))
            break
        end
        local line = "• " .. path
        if with_size then
            line = line .. " (" .. LocalLibrary.formatSize(LocalLibrary.sizeOf({ path })) .. ")"
        end
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

-- Tên file plugin đặt cho các chương trong mục lục đã lưu; nil nếu chưa lưu.
local function savedChapterNames(story)
    local source = SourceRegistry:get(story.source_id)
    local chapters = source and ChapterCache.chaptersFor(story.source_id, story.url)
    if not chapters then
        return nil
    end
    local names = {}
    for _, chapter in ipairs(chapters) do
        if chapter.url then
            table.insert(names, Storage.chapterFileName(source, chapter))
        end
    end
    return names
end

-- Đích "chỉ xóa chương đã tải" của các truyện kèm số file và dung lượng.
local function downloadPlan(stories, protected)
    local plan = LocalLibrary.collectDownloadTargets(stories, protected, savedChapterNames)
    plan.protected = protected
    plan.file_count = LocalLibrary.countFiles(plan.targets)
    plan.size_text = LocalLibrary.formatSize(LocalLibrary.sizeOf(plan.targets))
    return plan
end

-- Hỏi lại rồi xóa chương đã tải của truyện online, giữ truyện trong Tủ
-- truyện. on_done(result) chạy sau khi đã xóa.
local function confirmRemoveDownloads(stories, on_done, plan)
    plan = plan or downloadPlan(stories, protectedDirs())
    if plan.file_count == 0 then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Không có chương đã tải để xóa.",
        })
        return
    end
    local lines = {
        string.format("Xóa %d file chương đã tải (%s) của %d truyện?", plan.file_count, plan.size_text, #plan.stories),
        "Truyện vẫn ở Tủ truyện, lịch sử đọc giữ nguyên; có thể tải lại sau.",
    }
    for _, story in ipairs(plan.stories) do
        if Storage:getLinkedDir(story) then
            table.insert(lines, "File bạn tự chép vào thư mục gắn ngoài sẽ được giữ nguyên.")
            break
        end
    end
    UIManager:show(ConfirmBox:new{
        title = "Truyện Việt",
        text = table.concat(lines, "\n"),
        ok_text = "Xóa chương",
        cancel_text = "Hủy",
        ok_callback = function()
            local result, err = withLoading("Đang xóa chương đã tải…", function()
                return LocalLibrary.removeDownloads(stories,
                    { protected = plan.protected, names_for = savedChapterNames })
            end)
            if not result then
                showError(err or "Không xóa được chương đã tải.")
                return
            end
            local message = {
                string.format("Đã xóa %d file (%s) của %d truyện.", result.deleted_files, plan.size_text, result.stories),
            }
            if result.skipped_local > 0 then
                table.insert(message, string.format("Bỏ qua %d truyện trên máy.", result.skipped_local))
            end
            if #result.linked_kept > 0 then
                table.insert(message, string.format(
                    "%d truyện gắn thư mục ngoài chưa có mục lục lưu nên giữ nguyên file trong đó.",
                    #result.linked_kept))
            end
            if #result.failed > 0 then
                table.insert(message, string.format("Không xóa được %d mục:\n%s", #result.failed, pathList(result.failed)))
            end
            if #result.skipped > 0 then
                table.insert(message, "Giữ nguyên thư mục được bảo vệ:\n" .. pathList(result.skipped))
            end
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = table.concat(message, "\n"),
            })
            if on_done then
                on_done(result)
            end
        end,
    })
end

-- Xóa truyện khỏi Tủ truyện với 2 lựa chọn: xóa cả file của truyện (thư mục
-- plugin tải về, thư mục trên máy đã gắn, file/thư mục "Trên máy" kèm .sdr)
-- hoặc chỉ xóa khỏi Tủ truyện. on_done(result) chạy sau khi đã xóa. Truyện
-- online có chương đã tải còn có lựa chọn chỉ xóa chương, giữ trong Tủ
-- truyện; xong thì gọi on_downloads_removed(result).
local function confirmRemoveStories(stories, on_done, on_downloads_removed)
    if #stories == 0 then
        return
    end
    local protected = protectedDirs()
    local download_plan = downloadPlan(stories, protected)
    local targets, skipped = LocalLibrary.collectTargets(stories, protected)
    local file_count = LocalLibrary.countFiles(targets)
    local size_text = LocalLibrary.formatSize(LocalLibrary.sizeOf(targets))
    local name = #stories == 1 and ("\"" .. tostring(stories[1].title) .. "\"")
        or string.format("%d truyện", #stories)

    local function finish(delete_files)
        local result, err = withLoading(delete_files and "Đang xóa file..." or "Đang xóa khỏi Tủ truyện...", function()
            return LocalLibrary.removeStories(stories, { delete_files = delete_files, protected = protected })
        end)
        if not result then
            showError(err or "Không lưu được Tủ truyện.")
            return
        end
        local lines = { string.format("Đã xóa %d truyện khỏi Tủ truyện.", result.removed) }
        if delete_files then
            table.insert(lines, string.format("Đã xóa %d file.", result.deleted_files))
            if #result.failed > 0 then
                table.insert(lines, string.format("Không xóa được %d mục:\n%s", #result.failed, pathList(result.failed)))
            end
            if #result.skipped > 0 then
                table.insert(lines, "Giữ nguyên thư mục được bảo vệ:\n" .. pathList(result.skipped))
            end
        else
            table.insert(lines, "Các file trên máy được giữ nguyên.")
        end
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = table.concat(lines, "\n"),
        })
        if on_done then
            on_done(result)
        end
    end

    local dialog
    local buttons = {
            {
                {
                    text = #targets > 0
                        and string.format("Xóa khỏi Tủ truyện và cả file đã tải (%d file · %s)",
                            file_count, size_text)
                        or "Xóa cả file đã tải (không có file trên máy)",
                    enabled = #targets > 0,
                    callback = function()
                        closeAndRun(dialog, function()
                            local text = string.format("Xóa vĩnh viễn %d file (%s) của %s trong:\n%s",
                                file_count, size_text, name, pathList(targets, nil, true))
                            if #skipped > 0 then
                                text = text .. "\n\nGiữ nguyên (thư mục được bảo vệ):\n" .. pathList(skipped)
                            end
                            UIManager:show(ConfirmBox:new{
                                title = "Truyện Việt",
                                text = text .. "\n\nKhông thể hoàn tác.",
                                ok_text = "Xóa vĩnh viễn",
                                cancel_text = "Hủy",
                                ok_callback = function()
                                    finish(true)
                                end,
                            })
                        end)
                    end,
                },
            },
            {
                {
                    text = "Chỉ xóa khỏi Tủ truyện (giữ file)",
                    callback = function()
                        closeAndRun(dialog, function()
                            finish(false)
                        end)
                    end,
                },
            },
            {
                {
                    text = "Hủy",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
    }
    if download_plan.file_count > 0 then
        table.insert(buttons, 1, {
            {
                text = string.format("Chỉ xóa chương đã tải, giữ trong Tủ truyện (%d file · %s)",
                    download_plan.file_count, download_plan.size_text),
                callback = function()
                    closeAndRun(dialog, function()
                        confirmRemoveDownloads(stories, on_downloads_removed, download_plan)
                    end)
                end,
            },
        })
    end
    dialog = ButtonDialog:new{
        title = "Xóa " .. name .. " khỏi Tủ truyện",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function toggleFavorite(story, refresh_callback)
    if Storage:isFavorite(story) then
        confirmRemoveStories({ story }, function()
            if refresh_callback then refresh_callback(false) end
        end, function()
            if refresh_callback then refresh_callback("downloads_removed") end
        end)
        return nil
    else
        local added, add_err = Storage:addFavorite(story)
        if not added then
            showError(add_err)
            return nil
        end
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Đã thêm vào tủ truyện." })
        if refresh_callback then refresh_callback(true) end
        return true
    end
end

local function formatStoryDetails(story, source, details)
    local lines = {
        source.name,
    }
    if details.author and details.author ~= "" then
        table.insert(lines, "Tác giả: " .. details.author)
    end
    if details.translator and details.translator ~= "" then
        table.insert(lines, "Nhóm dịch: " .. details.translator)
    end
    if details.status and details.status ~= "" then
        table.insert(lines, "Tình trạng: " .. details.status)
    end
    if details.genres and #details.genres > 0 then
        table.insert(lines, "Thể loại: " .. table.concat(details.genres, ", "))
    end
    table.insert(lines, "")
    table.insert(
        lines,
        details.description ~= "" and details.description
            or "Website không cung cấp mô tả cho truyện này."
    )
    table.insert(lines, "")
    table.insert(lines, story.url)
    return table.concat(lines, "\n")
end

function Browser:showStoryDetails(story, source)
    local function showDetails(details)
        story.details = details
        Storage:updateFavorite(story)
        UIManager:show(TextViewer:new{
            title = story.title,
            text = formatStoryDetails(story, source, details),
        })
    end

    if story.details then
        showDetails(story.details)
        return
    end

    runOnline(function()
        local details, err = withLoading(
            "Đang tải mô tả truyện...",
            function()
                return source:getStoryDetails(story)
            end
        )
        if not details then
            showError(err)
            return
        end
        showDetails(details)
    end)
end

function Browser:showErrorReportDialog(error_msg, on_close)
    local ErrorReporter = require("truyenviet/error_reporter")
    local dialog
    dialog = InputDialog:new{
        title = "Gửi báo lỗi",
        input_hint = "Mô tả lỗi bạn gặp phải (tùy chọn)",
        buttons = {
            {
                {
                    text = "Đóng",
                    callback = function()
                        closeAndRun(dialog, on_close)
                    end,
                },
                {
                    text = "Chép log",
                    callback = function()
                        local user_desc = dialog:getInputValue()
                        closeAndRun(dialog, function()
                            local ok, msg = ErrorReporter:copyReportToClipboard(user_desc, error_msg, true)
                            if ok then
                                ErrorReporter:clearLogAfterSubmit()
                                require("ui/widget/infomessage"):new({
                                    text = msg,
                                }):show()
                            else
                                require("ui/widget/infomessage"):new({
                                    text = "Lỗi chép log: " .. tostring(msg),
                                }):show()
                            end
                            if on_close then UIManager:nextTick(on_close) end
                        end)
                    end,
                }
            }
        }
    }
    UIManager:show(dialog)
end

function Browser:showStoryActions(story, source, refresh_callback)
    local dialog
    local buttons = {
        {
            {
                text = Storage:isFavorite(story)
                    and "Xóa khỏi tủ truyện"
                    or "Thêm vào tủ truyện",
                callback = function()
                    closeAndRun(dialog, function()
                        toggleFavorite(story, refresh_callback)
                    end)
                end,
            },
        },
        {
            {
                text = "Xem chi tiết truyện",
                callback = function()
                    closeAndRun(dialog, function()
                        self:showStoryDetails(story, source)
                    end)
                end,
            },
        },
        {
            {
                text = "Mở thư mục truyện",
                callback = function()
                    closeAndRun(dialog, function()
                        local Storage = require("truyenviet/storage")
                        local story_dir = Storage:getStoryDir(source, story)
                        local FileManager = require("apps/filemanager/filemanager")
                        local ReaderUI = require("apps/reader/readerui")
                        if ReaderUI.instance then
                            ReaderUI.instance:onClose()
                        end
                        FileManager:showFiles(story_dir)
                    end)
                end,
            },
        },
    }

    if Storage:isFavorite(story) then
        local download_plan = downloadPlan({ story }, protectedDirs())
        if download_plan.file_count > 0 then
            table.insert(buttons, 2, {
                {
                    text = string.format("Xóa chương đã tải… (%d file · %s)",
                        download_plan.file_count, download_plan.size_text),
                    callback = function()
                        closeAndRun(dialog, function()
                            confirmRemoveDownloads({ story }, function()
                                if refresh_callback then refresh_callback("downloads_removed") end
                            end, download_plan)
                        end)
                    end,
                },
            })
        end
        table.insert(buttons, 2, {
            {
                text = "Tìm lại ảnh bìa lớn",
                callback = function()
                    closeAndRun(dialog, function()
                        if story.cover_path then
                            os.remove(story.cover_path)
                            story.cover_path = nil
                        end
                        withLoading("Đang tìm ảnh bìa lớn...", function()
                            LocalLibrary.findCovers({ story }, SourceRegistry, { deadline = 30 })
                            if story.cover_found then
                                Storage:addFavorite(story)
                            end
                        end)
                        if refresh_callback then refresh_callback(true) end
                    end)
                end,
            }
        })
    end

    dialog = ButtonDialog:new{
        title = story.title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Browser:showRoot()
    -- Chỉ một phiên Truyện Việt: đang đọc chương của plugin thì đóng chương
    -- (KOReader lưu vị trí đọc) rồi mới mở trang chủ, và đóng mọi cửa sổ cũ.
    local ReaderUI = require("apps/reader/readerui")
    if Reader.active and ReaderUI.instance then
        Debug.write("Browser:showRoot closing the open chapter first")
        Reader:returnToPlugin(function()
            self:showRoot()
        end)
        return
    end
    local closed = Windows.closeAll()
    if closed > 0 then
        Debug.write("Browser:showRoot closed " .. closed .. " old window(s)")
    end

    Storage:initialize()
    pcall(function() require("truyenviet/font_helper"):setupComicFont() end)

    local view
    local items = {}

    local history = Storage:getHistory()
    if #history > 0 then
        local latest = history[1]
        -- Menu của KOReader không giới hạn độ rộng phần bên phải: tên chương
        -- dài (tên file của mục "Trên máy") làm độ rộng còn lại âm và crash.
        local chapter_title = latest.chapter.title
        if chapter_title == latest.story.title then
            chapter_title = nil
        end
        table.insert(items, {
            text = "▶ Tiếp tục: " .. latest.story.title,
            mandatory = chapter_title and Util.shorten(chapter_title, 24) or nil,
            callback = function()
                self:confirmContinue(latest, view, function()
                    self:showRoot()
                end)
            end,
        })
    end

    table.insert(items, {
        text = "Tìm trên tất cả nguồn",
        mandatory_func = function()
            return tostring(#SourceRegistry:listEnabled())
        end,
        callback = function()
            self:showSearchDialog(nil, function()
                self:showRoot()
            end, view)
            return true
        end,
    })

    table.insert(items, {
        text = "Đọc truyện",
        mandatory_func = function()
            return tostring(#SourceRegistry:listEnabled()) .. " nguồn"
        end,
        callback = function()
            closeAndRun(view, function()
                self:showSourceMenu(function()
                    self:showRoot()
                end)
            end)
        end,
    })
    table.insert(items, {
            text = "Lịch sử đọc",
            mandatory_func = function()
                return tostring(#Storage:getHistory())
            end,
            callback = function()
                closeAndRun(view, function()
                    self:showHistory(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
    table.insert(items, {
            text = "Tủ truyện",
            mandatory_func = function()
                return tostring(#Storage:listFavorites())
            end,
            callback = function()
                closeAndRun(view, function()
                    self:showFavorites(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "Thêm truyện trên máy vào Tủ truyện",
            callback = function()
                closeAndRun(view, function()
                    self:showLibraryImport(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "🌐 Dán URL Web Truyện để Tự Tạo Nguồn",
            callback = function()
                closeAndRun(view, function()
                    self:showDirectImporterDialog(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "☁ Tải Ebook từ Google Drive",
            callback = function()
                closeAndRun(view, function()
                    self:showGDriveDownloadDialog(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "⧉ Quản lý File Đã Tải & Gộp File",
            callback = function()
                closeAndRun(view, function()
                    self:showDownloadedManager(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "⚙ Cài đặt Tải ngầm & Purge",
            callback = function()
                closeAndRun(view, function()
                    self:showAdvancedSettings(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "Quản lý nguồn",
            callback = function()
                closeAndRun(view, function()
                    self:showSourceManager(function()
                        self:showRoot()
                    end)
                end)
            end,
        })
        table.insert(items, {
            text = "Mở thư mục đã tải",
            callback = function()
                closeAndRun(view, function()
                    local FileManager = require("apps/filemanager/filemanager")
                    local ReaderUI = require("apps/reader/readerui")
                    if ReaderUI.instance then
                        ReaderUI.instance:onClose()
                    end
                    FileManager:showFiles(Storage:getRootDir())
                end)
            end,
        })
        table.insert(items, {
            text = "Xóa tất cả Lịch sử đọc",
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "Bạn có chắc chắn muốn xóa TẤT CẢ Lịch sử đọc không?",
                    ok_text = "Xóa",
                    cancel_text = "Hủy",
                    ok_callback = function()
                        Storage:clearAllHistory(false)
                        UIManager:show(InfoMessage:new{
                            title = "Truyện Việt",
                            text = "Đã xóa toàn bộ lịch sử đọc."
                        })
                    end,
                })
            end,
        })
        table.insert(items, {
            text = "Xóa tất cả Tủ truyện",
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "Bạn có chắc chắn muốn xóa TẤT CẢ truyện khỏi Tủ truyện không?",
                    ok_text = "Xóa",
                    cancel_text = "Hủy",
                    ok_callback = function()
                        Storage:clearAllFavorites(false)
                        UIManager:show(InfoMessage:new{
                            title = "Truyện Việt",
                            text = "Đã xóa toàn bộ tủ truyện."
                        })
                    end,
                })
            end,
        })
        table.insert(items, {
            text = "Xóa tất cả truyện đã tải",
            callback = function()
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = "Bạn có chắc chắn muốn xóa TẤT CẢ truyện đã tải không?\nThao tác này không thể hoàn tác.",
                    ok_text = "Xóa",
                    cancel_text = "Hủy",
                    ok_callback = function()
                        local ok, err = Storage:removeAllDownloads()
                        if ok then
                            UIManager:show(InfoMessage:new{
                                title = "Truyện Việt",
                                text = "Đã xóa toàn bộ truyện tải về."
                            })
                        else
                            showError("Lỗi khi xóa: " .. tostring(err))
                        end
                    end,
                })
            end,
        })
    table.insert(items, {
            text = "Xóa bộ nhớ đệm ảnh bìa",
            callback = function()
                if Storage:clearCoverCacheDir() then
                    UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Đã xóa bộ nhớ đệm ảnh bìa." })
                else
                    showError("Không thể xóa bộ nhớ đệm.")
                end
            end,
        })
    table.insert(items, {
        text = "↻ Kiểm tra cập nhật OTA",
        callback = function()
            closeAndRun(view, function()
                local Updater = require("truyenviet/updater")
                Updater:checkManually(function()
                    self:showRoot()
                end)
            end)
        end,
    })
    table.insert(items, {
        text = "Gửi báo lỗi / Xem log",
        callback = function()
            closeAndRun(view, function()
                self:showErrorReportDialog("", function()
                    self:showRoot()
                end)
            end)
        end,
    })
    table.insert(items, {
            text = Storage.settings:readSetting("fast_mode", false) 
                and "Chế độ tải ảnh bìa: Tắt (Duyệt rất nhanh)" 
                or "Chế độ tải ảnh bìa: Bật (Tải chậm hơn)",
            callback = function()
                local is_fast = Storage.settings:readSetting("fast_mode", false)
                local ok, err = Storage:setFastMode(not is_fast)
                if not ok then
                    showError(err)
                    return
                end
                closeAndRun(view, function()
                    self:showRoot()
                end)
            end,
        })
    table.insert(items, {
        text = "✎ Cấu hình Font Be Vietnam Pro Toàn Hệ Thống",
        callback = function()
            local FontHelper = require("truyenviet/font_helper")
            local installed = FontHelper:isUserPatchInstalled()
            local ConfirmBox = require("ui/widget/confirmbox")

            UIManager:show(ConfirmBox:new{
                title = "Giao diện Font Be Vietnam Pro",
                text = installed 
                    and "Trạng thái: ✅ ĐÃ BẬT User Patch Font Be Vietnam Pro toàn giao diện KOReader.\n\nBạn có muốn TẮT và gỡ bỏ User Patch này không?"
                    or "Trạng thái: ❌ CHƯA BẬT User Patch.\n\nKích hoạt User Patch sẽ cài đặt font BeVietnamPro-Regular.ttf làm font mặc định cho TOÀN BỘ KOReader (Menu, Popup, Ô văn bản, Tiêu đề), hiển thị chuẩn 100% tiếng Việt có dấu.\n\nBạn có muốn BẬT ngay không?",
                ok_text = installed and "Tắt User Patch" or "Bật User Patch",
                cancel_text = "Hủy",
                ok_callback = function()
                    if installed then
                        FontHelper:removeUserPatch()
                        UIManager:show(InfoMessage:new{
                            title = "Truyện Việt",
                            text = "Đã gỡ bỏ User Patch font. Vui lòng khởi động lại KOReader.",
                        })
                    else
                        if FontHelper:installUserPatch() then
                            UIManager:show(InfoMessage:new{
                                title = "Truyện Việt",
                                text = "Đã cài đặt User Patch font thành công!\nVui lòng khởi động lại KOReader để áp dụng font Be Vietnam Pro toàn giao diện.",
                            })
                        else
                            showError("Không thể ghi file User Patch vào hệ thống.")
                        end
                    end
                end,
            })
        end,
    })
    table.insert(items, {
            text = "Giới thiệu & Font chữ",
            callback = function()
                local FontHelper = require("truyenviet/font_helper")
                local installed = FontHelper:isUserPatchInstalled()
                UIManager:show(TextViewer:new{
                    title = "Truyện Việt",
                    text = table.concat({
                        "🔥 Truyện Việt cho KOReader v" .. Version,
                        "Đọc truyện trực tuyến mượt mà trên máy đọc sách Kobo/Kindle/Android.",
                        "",
                        "🔤 Font chữ Be Vietnam Pro (BeVietnamPro-Regular.ttf):",
                        "Font chữ thiết kế chuẩn mực cho typography tiếng Việt với đầy đủ dấu thanh.",
                        installed and "-> Trạng thái: ✅ ĐÃ BẬT User Patch Font toàn KOReader." or "-> Trạng thái: ❌ CHƯA BẬT (Dùng tùy chọn bên trên để Bật User Patch toàn KOReader).",
                        "",
                        "Nguồn truyện chữ: TruyenFull, Truyện Dịch AI, AkayTruyen, Con Đường Bá Chủ, v.v.",
                        "Nguồn truyện tranh: TruyenQQ, Dưa Leo, Cbunu, Hắc Ám Chi Các, TVE-4U, v.v.",
                        "",
                        "Chương truyện được lưu vào thư mục truyenviet trong thư mục dữ liệu KOReader.",
                        "Nội dung và ảnh thuộc về các website nguồn và chủ sở hữu tương ứng.",
                    }, "\n"),
                })
            end,
        })
    view = showView("Truyện Việt v" .. Version, items)
end

function Browser:showSourceSectionsMenu(source, on_return_callback)
    local view
    local items = {
        {
            text = "🔥 Truyện Hot / Đề Cử",
            callback = function()
                closeAndRun(view, function()
                    self:browseSource(source, { section = "hot", name = "Truyện Hot / Đề Cử" }, 1, function()
                        self:showSourceSectionsMenu(source, on_return_callback)
                    end)
                end)
            end,
        },
        {
            text = "✅ Truyện Hoàn Thành (Full)",
            callback = function()
                closeAndRun(view, function()
                    self:browseSource(source, { section = "completed", name = "Truyện đã hoàn thành" }, 1, function()
                        self:showSourceSectionsMenu(source, on_return_callback)
                    end)
                end)
            end,
        },
        {
            text = "🆕 Truyện Đang Ra / Cập Nhật Mới",
            callback = function()
                closeAndRun(view, function()
                    self:browseSource(source, { section = "updating", name = "Truyện mới cập nhật" }, 1, function()
                        self:showSourceSectionsMenu(source, on_return_callback)
                    end)
                end)
            end,
        },
        {
            text = "☷ Tất Cả Thể Loại",
            callback = function()
                closeAndRun(view, function()
                    runOnline(function()
                        local genres, err = withLoading("Đang tải danh sách thể loại...", function()
                            if source.getGenresList then
                                local list = source:getGenresList()
                                if list and #list > 0 then return list end
                            end
                            local res = source:getCompleted(1)
                            return res and res.genres or {}
                        end)
                        if not genres or #genres == 0 then
                            showError(err or "Không đọc được danh sách thể loại từ nguồn này.", function()
                                self:showSourceSectionsMenu(source, on_return_callback)
                            end)
                            return
                        end
                        self:showGenreMenu(source, genres, function()
                            self:showSourceSectionsMenu(source, on_return_callback)
                        end)
                    end)
                end)
            end,
        },
        {
            text = "⌕ Tìm Kiếm Trên " .. source.name,
            callback = function()
                closeAndRun(view, function()
                    self:showSearchDialog(source, function()
                        self:showSourceSectionsMenu(source, on_return_callback)
                    end)
                end)
            end,
        },
    }

    view = showView(source.name .. " · Phân loại", items, on_return_callback)
end

function Browser:showSourceMenu(on_return_callback)
    local view
    local items = {}
    for _, source in ipairs(SourceRegistry:listAll()) do
        local current_source = source
        table.insert(items, {
            text = current_source.name,
            mandatory_func = function()
                if not SourceRegistry:isEnabled(current_source.id) then
                    return "Đã tắt · chạm để bật"
                end
                if current_source.kind == "ebook" then
                    return "EBOOK"
                end
                return current_source.kind == "comic" and "CBZ" or "HTML"
            end,
            callback = function()
                if not SourceRegistry:isEnabled(current_source.id) then
                    local ok, err = SourceRegistry:setEnabled(current_source.id, true)
                    if not ok then
                        showError(err)
                        return
                    end
                    closeAndRun(view, function()
                        self:showSourceMenu(on_return_callback)
                    end)
                    return
                end
                closeAndRun(view, function()
                    if current_source.kind == "ebook" then
                        self:browseEbookSource(current_source, function()
                            self:showSourceMenu(on_return_callback)
                        end)
                    else
                        self:showSourceSectionsMenu(current_source, function()
                            self:showSourceMenu(on_return_callback)
                        end)
                    end
                end)
            end,
        })
    end

    view = showView("Đọc truyện", items, on_return_callback)
end

function Browser:showSearchDialog(source, on_return_callback, parent_view)
    local dialog
    dialog = InputDialog:new{
        title = source and ("Tìm trên " .. source.name) or "Tìm trên tất cả nguồn",
        input_hint = "Tên truyện",
        buttons = {
            {
                {
                    text = "Quay lại",
                    callback = function()
                        closeAndRun(dialog, function()
                            if not parent_view and on_return_callback then 
                                on_return_callback() 
                            end
                        end)
                    end,
                },
                {
                    text = "Tìm",
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        if query == "" then
                            return
                        end
                        closeAndRun(dialog, function()
                            self:search(source, query, on_return_callback, parent_view)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:search(source, query, on_return_callback, parent_view)
    runOnline(function()
        local sources = source and { source } or SourceRegistry:listEnabled()
        if #sources == 0 then
            showError("Chưa có nguồn nào được bật.", on_return_callback)
            return
        end

        local search_result, err = withLoading(
            'Đang tìm "' .. query .. '"...',
            function()
                local stories, errors = SearchService:search(query, sources)
                enrichAndPrefetch(stories)
                return {
                    stories = stories,
                    errors = errors,
                }
            end
        )
        if not search_result then
            showError(err, function()
                self:showSearchDialog(source, on_return_callback, parent_view)
            end)
            return
        end
        local stories = search_result.stories
        if #stories == 0 then
            local message = "Không tìm thấy truyện phù hợp."
            if #search_result.errors > 0 then
                message = message .. "\n\n" .. table.concat(search_result.errors, "\n")
            end
            showError(message, function()
                self:showSearchDialog(source, on_return_callback, parent_view)
            end)
            return
        end

        if parent_view and type(parent_view.onClose) == "function" then
            UIManager:close(parent_view)
        end
        self:showStories(
            source and (source.name .. ": " .. query) or query,
            stories,
            on_return_callback,
            {
                subtitle = #search_result.errors > 0
                    and string.format(
                        "%d kết quả, %d nguồn lỗi",
                        #stories,
                        #search_result.errors
                    )
                    or string.format("%d kết quả", #stories),
            }
        )
    end)
end

function Browser:browseSource(source, genre, local_page, on_return_callback)
    local ITEMS_PER_PAGE = 10
    self.chunks_per_page = self.chunks_per_page or {}
    local cpp = self.chunks_per_page[source.id] or 1
    
    local server_page = math.ceil(local_page / cpp)
    local chunk_index = ((local_page - 1) % cpp) + 1

    runOnline(function()
        local result, err
        local cache = self.cached_listing
        if cache and cache.source_id == source.id and cache.genre_name == (genre and genre.name or nil) and cache.server_page == server_page then
            result = cache.listing
        else
            result, err = withLoading(
                string.format(
                    "Đang tải %s...\nTrang %d",
                    genre and genre.name or (source.id == "docln" and "truyện dịch" or "truyện đã hoàn thành"),
                    server_page
                ),
                function()
                    local r, e
                    if genre and genre.section == "hot" then
                        if source.getHot then
                            r, e = source:getHot(server_page)
                        else
                            r, e = source:getCompleted(server_page)
                        end
                    elseif genre and genre.section == "updating" then
                        if source.getUpdating then
                            r, e = source:getUpdating(server_page)
                        else
                            r, e = source:getCompleted(server_page)
                        end
                    elseif genre and genre.section == "completed" then
                        r, e = source:getCompleted(server_page)
                    elseif genre and (genre.url or type(genre) == "string") then
                        local g_obj = type(genre) == "string" and { name = genre, url = genre } or genre
                        if g_obj.url and not g_obj.url:find("^https?://") then
                            g_obj.url = Util.absoluteUrl(source.base_url, g_obj.url)
                        end
                        r, e = source:getGenre(g_obj, server_page)
                    else
                        r, e = source:getCompleted(server_page)
                    end
                    return r, e
                end
            )
            if result then
                result.stories = result.stories or {}
                self.cached_listing = {
                    source_id = source.id,
                    genre_name = genre and genre.name or nil,
                    server_page = server_page,
                    listing = result,
                }
                cpp = math.max(1, math.ceil(#result.stories / ITEMS_PER_PAGE))
                self.chunks_per_page[source.id] = cpp
            end
        end

        if not result then
            showError(err, on_return_callback)
            return
        end
        if #result.stories == 0 then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                title = "Truyện Việt",
                text = "Không có truyện ở trang này.",
                ok_text = "Đóng",
                ok_callback = function()
                    if on_return_callback then
                        UIManager:nextTick(on_return_callback)
                    end
                end,
            })
            return
        end

        cpp = self.chunks_per_page[source.id]
        chunk_index = math.min(chunk_index, cpp)
        
        local start_idx = (chunk_index - 1) * ITEMS_PER_PAGE + 1
        local end_idx = math.min(chunk_index * ITEMS_PER_PAGE, #result.stories)
        
        local chunked_stories = {}
        for i = start_idx, end_idx do
            if result.stories[i] then
                table.insert(chunked_stories, result.stories[i])
            end
        end

        enrichAndPrefetch(chunked_stories)

        local local_total_pages = result.total_pages * cpp

        local function showCurrentListing()
            UIManager:show(Notification:new{
                text = string.format("Đã chuyển tới trang %d", local_page)
            })
            self:showStories(
                source.name .. " · " .. result.title,
                chunked_stories,
                on_return_callback,
                {
                    subtitle = string.format(
                        "Trang web %d/%d",
                        local_page,
                        local_total_pages
                    ),
                    server_page = local_page,
                    server_total_pages = local_total_pages,
                    on_search = function(return_to_listing, parent_view)
                        self:showSearchDialog(source, return_to_listing, parent_view)
                    end,
                    on_genres = function(return_to_listing)
                        self:showGenreMenu(
                            source,
                            result.genres,
                            return_to_listing
                        )
                    end,
                    on_prev_page = local_page > 1 and function()
                        self:browseSource(
                            source,
                            genre,
                            local_page - 1,
                            on_return_callback
                        )
                    end or nil,
                    on_next_page = local_page < local_total_pages and function()
                        self:browseSource(
                            source,
                            genre,
                            local_page + 1,
                            on_return_callback
                        )
                    end or nil,
                }
            )
        end
        showCurrentListing()
    end)
end

function Browser:showGenreMenu(source, genres, on_return_callback)
    local view
    local items = {}
    for _, genre in ipairs(genres or {}) do
        local current_genre = genre
        table.insert(items, {
            text = current_genre.name,
            callback = function()
                closeAndRun(view, function()
                    self:browseSource(source, current_genre, 1, function()
                        self:showGenreMenu(source, genres, on_return_callback)
                    end)
                end)
            end,
        })
    end
    if #items == 0 then
        table.insert(items, {
            text = "Không đọc được danh sách thể loại.",
            dim = true,
            select_enabled = false,
        })
    end
    view = showView(source.name .. " · Thể loại", items, on_return_callback)
end

function Browser:showSmartFilterDialog(stories, current_title, on_return_callback, options)
    options = options or {}
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")
    local dialog

    dialog = ButtonDialog:new{
        title = "⚡ Bộ lọc thông minh",
        description = string.format("Danh sách hiện tại: %d truyện\nChọn phương thức lọc:", #stories),
        buttons = {
            {
                {
                    text = "🔤 Lọc theo từ khóa (Không dấu)",
                    callback = function()
                        UIManager:close(dialog)
                        local input_dialog
                        input_dialog = InputDialog:new{
                            title = "Lọc theo từ khóa",
                            description = "Nhập từ cần tìm (VD: 'phong', 'thien', 'full'):",
                            buttons = {
                                {
                                    {
                                        text = "Hủy",
                                        callback = function()
                                            UIManager:close(input_dialog)
                                        end,
                                    },
                                    {
                                        text = "Lọc ngay",
                                        is_default = true,
                                        callback = function()
                                            local keyword = input_dialog:getInputText()
                                            UIManager:close(input_dialog)
                                            if keyword and keyword ~= "" then
                                                local filtered = {}
                                                local norm_k = Util.normalizeSearch(keyword)
                                                for _, st in ipairs(stories) do
                                                    local norm_t = Util.normalizeSearch(st.title)
                                                    if norm_t:find(norm_k, 1, true) then
                                                        table.insert(filtered, st)
                                                    end
                                                end
                                                self:showStories(
                                                    current_title .. " [" .. keyword .. "]",
                                                    filtered,
                                                    on_return_callback,
                                                    options
                                                )
                                            end
                                        end,
                                    },
                                }
                            }
                        }
                        UIManager:show(input_dialog)
                    end,
                },
            },
            {
                {
                    text = "⇅ Sắp xếp tên A -> Z",
                    callback = function()
                        UIManager:close(dialog)
                        local sorted = {}
                        for _, st in ipairs(stories) do table.insert(sorted, st) end
                        table.sort(sorted, function(a, b)
                            return Util.normalizeSearch(a.title) < Util.normalizeSearch(b.title)
                        end)
                        self:showStories(
                            current_title .. " [A-Z]",
                            sorted,
                            on_return_callback,
                            options
                        )
                    end,
                },
                {
                    text = "⇅ Sắp xếp tên Z -> A",
                    callback = function()
                        UIManager:close(dialog)
                        local sorted = {}
                        for _, st in ipairs(stories) do table.insert(sorted, st) end
                        table.sort(sorted, function(a, b)
                            return Util.normalizeSearch(a.title) > Util.normalizeSearch(b.title)
                        end)
                        self:showStories(
                            current_title .. " [Z-A]",
                            sorted,
                            on_return_callback,
                            options
                        )
                    end,
                },
            },
            {
                {
                    text = "Quay lại danh sách",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                }
            }
        }
    }
    UIManager:show(dialog)
end

function Browser:showStories(title, stories, on_return_callback, options)
    options = options or {}
    if #stories == 0 then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            title = title,
            text = "Không có truyện khả dụng.",
            ok_text = "Đóng",
            ok_callback = function()
                if on_return_callback then
                    UIManager:nextTick(on_return_callback)
                end
            end,
        })
        return
    end

    local view
    -- Tùy chọn của lần mở lại: đứng ở trang chứa truyện vừa mở.
    local function focusOn(story)
        local next_options = {}
        for key, value in pairs(options) do
            next_options[key] = value
        end
        next_options.focus_story = story
        return next_options
    end
    -- Mở lại danh sách này (Tủ truyện thì đọc lại để có số liệu mới).
    local function reopen(focus_story)
        if options.favorites_only then
            self:showFavorites(on_return_callback, focus_story)
        else
            self:showStories(title, stories, on_return_callback, focusOn(focus_story))
        end
    end
    for _, story in ipairs(stories) do
        local source = SourceRegistry:get(story.source_id)
        if source then
            story.source_name = source.name
        elseif LocalLibrary.isLocal(story) then
            -- Mục "Trên máy" không có trong SourceRegistry; bìa trích từ file
            -- vẫn nằm trong CoverCache (vd. Lịch sử đọc).
            story.source_name = LocalLibrary.source_name
        end
        if source or LocalLibrary.isLocal(story) then
            story.cover_path = story.cover_path or CoverCache:get(story)
        end
    end

    view = StoryResults:new{
        title = title,
        subtitle = options.subtitle,
        stories = stories,
        on_return_callback = on_return_callback,
        search_callback = options.on_search and function()
            options.on_search(function()
                self:showStories(title, stories, on_return_callback, options)
            end, view)
        end or nil,
        genres_callback = options.on_genres and function()
            closeAndRun(view, function()
                options.on_genres(function()
                    self:showStories(title, stories, on_return_callback, options)
                end)
            end)
        end or nil,
        filter_callback = function()
            self:showSmartFilterDialog(stories, title, on_return_callback, options)
        end,
        server_page = options.server_page,
        server_total_pages = options.server_total_pages,
        server_prev_callback = options.on_prev_page and function()
            closeAndRun(view, options.on_prev_page)
        end or nil,
        server_next_callback = options.on_next_page and function()
            closeAndRun(view, options.on_next_page)
        end or nil,
        right_icon = options.right_icon,
        right_icon_tap_callback = options.right_icon_tap_callback,
        focus_story = options.focus_story,
        story_callback = function(story)
            if options.on_story_tap then
                options.on_story_tap(story, view)
                return
            end
            if LocalLibrary.isLocal(story) then
                self:openLocalEntry(story, view, function()
                    reopen(story)
                end)
                return
            end
            local source = SourceRegistry:get(story.source_id)
            if not source then
                showError("Nguồn truyện không còn khả dụng.")
                return
            end
            closeAndRun(view, function()
                self:loadStoryPage(story, source, 1, function()
                    if options.favorites_only then
                        local favorites = loadFavorites()
                        if #favorites == 0 then
                            on_return_callback()
                        else
                            self:showStories(
                                title,
                                favorites,
                                on_return_callback,
                                focusOn(story)
                            )
                        end
                    else
                        self:showStories(title, stories, on_return_callback, focusOn(story))
                    end
                end)
            end)
        end,
        story_hold_callback = function(story)
            if options.on_story_hold then
                options.on_story_hold(story, view)
                return
            end
            if LocalLibrary.isLocal(story) then
                self:showLocalEntryActions(story, view, function()
                    reopen(story)
                end)
                return
            end
            local source = SourceRegistry:get(story.source_id)
            if not source then
                showError("Nguồn truyện không còn khả dụng.")
                return
            end
            self:showStoryActions(story, source, function(is_favorite)
                if is_favorite == "downloads_removed" then
                    -- Đọc lại dung lượng và số chương đã tải.
                    if options.favorites_only then
                        closeAndRun(view, function()
                            reopen(story)
                        end)
                    end
                elseif options.favorites_only and not is_favorite then
                    view:removeStory(story)
                else
                    view:refreshFavorites()
                end
            end)
        end,
    }
    UIManager:show(view)
end

function Browser:showFavorites(on_return_callback, focus_story)
    healLocalEntries()
    local favorites = loadFavorites()
    -- Làm mới số chương (cũ hơn 12 giờ) và bìa còn thiếu khi có mạng.
    if isOnline() then
        local now = os.time()
        local needed = false
        for _, story in ipairs(favorites) do
            if LocalLibrary.metaStale(story, now, SourceRegistry) or LocalLibrary.coverMissing(story, now) then
                needed = true
                break
            end
        end
        if needed then
            local updated = withLoading("Đang cập nhật Tủ truyện...", function()
                return LocalLibrary.refresh(favorites, SourceRegistry)
            end)
            if updated and updated > 0 then
                favorites = loadFavorites()
            end
        end
    end

    self:showStories(
        "Tủ truyện",
        favorites,
        on_return_callback,
        {
            favorites_only = true,
            focus_story = focus_story,
            -- Chế độ chọn nhiều truyện để xóa hoặc tìm bìa lớn.
            right_icon = "check",
            right_icon_tap_callback = function(view)
                closeAndRun(view, function()
                    self:selectFavoritesToRemove(on_return_callback)
                end)
            end,
        }
    )
end

-- Chọn nhiều truyện (có "Chọn tất cả") rồi xóa khỏi Tủ truyện hoặc tìm bìa lớn.
function Browser:selectFavoritesToRemove(on_return_callback)
    local favorites = loadFavorites()
    local selected = {}
    local view
    local delete_item, cover_item, all_item = {}, {}, {}
    local menu_items = { delete_item, cover_item, all_item }

    local function countSelected()
        local count = 0
        for _, story in ipairs(favorites) do
            if selected[story] then
                count = count + 1
            end
        end
        return count
    end
    local function setTexts()
        local count = countSelected()
        local bytes = 0
        for _, story in ipairs(favorites) do
            if selected[story] then
                bytes = bytes + (tonumber(story.size_bytes) or 0)
            end
        end
        delete_item.text = string.format("Xóa %d truyện đã chọn", count)
        delete_item.mandatory = bytes > 0 and LocalLibrary.formatSize(bytes) or nil
        cover_item.text = string.format("Tìm ảnh bìa lớn cho %d truyện đã chọn", count)
        all_item.text = count == #favorites and "Bỏ chọn tất cả" or "Chọn tất cả"
        for _, menu_item in ipairs(menu_items) do
            local story = menu_item.story
            if story then
                menu_item.text = string.format("%s [%s] %s", selected[story] and "☑" or "☐",
                    tostring(story.source_name or story.source_id), tostring(story.title))
                local size = tonumber(story.size_bytes) or 0
                menu_item.mandatory = size > 0 and LocalLibrary.formatSize(size) or nil
            end
        end
    end
    local function refresh()
        setTexts()
        view:updateItems()
    end

    local function chosenStories()
        local chosen = {}
        for _, story in ipairs(favorites) do
            if selected[story] then
                table.insert(chosen, story)
            end
        end
        return chosen
    end
    delete_item.callback = function()
        -- Xóa xong thì quay về Tủ truyện (đọc lại danh sách).
        confirmRemoveStories(chosenStories(), function()
            view:onClose()
        end, function()
            view:onClose()
        end)
    end
    cover_item.callback = function()
        local chosen = chosenStories()
        if #chosen == 0 then
            return
        end
        self:findStoryCovers(chosen, function()
            view:onClose()
        end)
    end
    all_item.callback = function()
        local select_all = countSelected() < #favorites
        for _, story in ipairs(favorites) do
            selected[story] = select_all or nil
        end
        refresh()
    end
    for _, story in ipairs(favorites) do
        local menu_item = { story = story }
        menu_item.callback = function()
            selected[story] = not selected[story] or nil
            refresh()
        end
        table.insert(menu_items, menu_item)
    end
    setTexts()
    view = showView("Chọn truyện", menu_items, function()
        self:showFavorites(on_return_callback)
    end)
end

-- Mục "Trên máy": file thì mở luôn, thư mục thì liệt kê các tập,
-- không còn trên máy thì hỏi có xóa khỏi Tủ truyện không.
function Browser:openLocalEntry(story, view, reopen)
    local kind = LocalLibrary.entryType(story.url)
    if not kind then
        UIManager:show(ConfirmBox:new{
            title = "Truyện Việt",
            text = "Không còn tìm thấy trên máy:\n" .. story.url
                .. "\n\nXóa mục này khỏi Tủ truyện?",
            ok_text = "Xóa khỏi Tủ truyện",
            ok_callback = function()
                if Storage:removeFavorite(story) and view and view.removeStory then
                    view:removeStory(story)
                end
            end,
        })
        return
    end
    if kind ~= "dir" then
        closeAndRun(view, function()
            self:openEbookFile(story.url)
        end)
        return
    end
    local books = LocalLibrary.listBooks(story.url)
    if #books == 0 then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Thư mục chưa có file sách nào:\n" .. story.url,
        })
        return
    end
    -- Đánh dấu tập đọc gần nhất (Lịch sử đọc ghi lại khi mở file).
    local last_read
    for _, item in ipairs(Storage:getHistory()) do
        if item.story.source_id == story.source_id and item.story.url == story.url then
            last_read = item.chapter.url
            break
        end
    end
    local list_view
    local items = {}
    for _, path in ipairs(books) do
        table.insert(items, {
            text = path:sub(#story.url + 2),
            mandatory = path == last_read and "Đang đọc" or nil,
            callback = function()
                closeAndRun(list_view, function()
                    self:openFolderBook(books, path)
                end)
            end,
        })
    end
    closeAndRun(view, function()
        list_view = showView(story.title, items, reopen)
    end)
end

-- Mở một file trong thư mục "Trên máy", kèm "Tập X/Y" trên thanh trạng thái.
function Browser:openFolderBook(books, path)
    Reader:setPosition(path, ChapterPosition.format(ChapterPosition.fromFolder(books, path)))
    self:openEbookFile(path)
end

function Browser:showLocalEntryActions(story, view, reopen)
    local dialog
    local folder = LocalLibrary.entryType(story.url) == "dir" and story.url
        or story.url:match("^(.*)/[^/]+$")
    dialog = ButtonDialog:new{
        title = story.title,
        buttons = {
            {
                {
                    text = "Xóa khỏi Tủ truyện…",
                    callback = function()
                        closeAndRun(dialog, function()
                            confirmRemoveStories({ story }, function()
                                view:removeStory(story)
                                if #view.stories == 0 then
                                    view:onClose()
                                end
                            end)
                        end)
                    end,
                },
            },
            {
                {
                    text = "Tìm lại ảnh bìa lớn",
                    callback = function()
                        closeAndRun(dialog, function()
                            story.cover_path = nil
                            withLoading("Đang tìm ảnh bìa lớn...", function()
                                LocalLibrary.findCovers({ story }, SourceRegistry, { deadline = 30 })
                                if story.cover_found then
                                    Storage:addFavorite(story)
                                end
                            end)
                            closeAndRun(view, reopen)
                        end)
                    end,
                },
            },
            {
                {
                    text = "Mở thư mục trong trình quản lý file",
                    enabled = folder ~= nil and isDirectory(folder),
                    callback = function()
                        closeAndRun(dialog, function()
                            local FileManager = require("apps/filemanager/filemanager")
                            local ReaderUI = require("apps/reader/readerui")
                            if ReaderUI.instance then
                                ReaderUI.instance:onClose()
                            end
                            FileManager:showFiles(folder)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Tìm lại bìa lớn cho các truyện đã chọn, lưu một lần rồi gọi on_done.
function Browser:findStoryCovers(stories, on_done)
    if not isOnline() then
        showError("Cần kết nối mạng để tìm ảnh bìa.")
        return
    end
    -- Như nút "Tìm lại ảnh bìa lớn": bỏ bìa cũ để tải lại bìa tìm được.
    for _, story in ipairs(stories) do
        if story.cover_path and not LocalLibrary.isLocal(story) then
            os.remove(story.cover_path)
        end
        story.cover_path = nil
    end
    local found = 0
    withLoading(string.format("Đang tìm ảnh bìa cho %d truyện...", #stories), function()
        local tried = LocalLibrary.findCovers(stories, SourceRegistry)
        for _, story in ipairs(tried) do
            if story.cover_found then
                found = found + 1
            end
        end
        Storage:mergeFavorites(tried)
    end)
    UIManager:show(InfoMessage:new{
        title = "Truyện Việt",
        text = string.format("Đã tìm được ảnh bìa cho %d/%d truyện.", found, #stories),
    })
    if on_done then
        on_done()
    end
end

-- Quét truyện plugin đã tải và thư viện sách, cho người dùng bỏ chọn rồi thêm
-- vào Tủ truyện; sau đó tìm bìa lớn và số chương cho các mục mới.
function Browser:showLibraryImport(on_return_callback)
    local LibraryImport = require("truyenviet/library_import")
    local online = isOnline()
    local result, err = withLoading("Đang quét truyện trên máy...", function()
        return LibraryImport.collect({
            registry = SourceRegistry,
            favorites = Storage:listFavorites(),
            history = Storage:getHistory(),
            plugin_root = Storage:getRootDir(),
            library_dirs = LibraryImport.libraryDirs(),
            search = online,
        })
    end)
    if not result then
        showError(err or "Không quét được truyện trên máy.", on_return_callback)
        return
    end
    if #result.items == 0 and #result.missing == 0 then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Không có truyện mới để thêm. Mọi truyện trên máy đã có trong Tủ truyện.",
        })
        if on_return_callback then
            UIManager:nextTick(on_return_callback)
        end
        return
    end

    local view
    local menu_items = {}
    local add_item = {}
    local function countSelected()
        local count = 0
        for _, item in ipairs(result.items) do
            if item.selected then
                count = count + 1
            end
        end
        return count
    end
    local function itemText(item)
        return string.format("%s %s (%s)", item.selected and "☑" or "☐", item.label, item.note)
    end
    local function setTexts()
        add_item.text = string.format("➕ Thêm %d truyện đã chọn", countSelected())
        for _, menu_item in ipairs(menu_items) do
            if menu_item.import_item then
                menu_item.text = itemText(menu_item.import_item)
            end
        end
    end

    add_item.callback = function()
        if countSelected() == 0 then
            return
        end
        local records, apply_err
        closeAndRun(view, function()
            records, apply_err = LibraryImport.apply(result.items)
            if not records then
                showError(apply_err or "Không lưu được Tủ truyện.", on_return_callback)
                return
            end
            if online then
                withLoading(string.format("Đang tìm bìa và số chương cho %d truyện...", #records), function()
                    LocalLibrary.refresh(records, SourceRegistry, {
                        covers = records,
                        cover_limit = #records,
                        meta_limit = #records,
                        deadline = LocalLibrary.full_deadline,
                    })
                end)
            end
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = string.format("Đã thêm %d truyện vào Tủ truyện.", #records)
                    .. (online and "" or "\nBật mạng rồi mở Tủ truyện để tải bìa và số chương."),
            })
            self:showFavorites(on_return_callback)
        end)
    end
    table.insert(menu_items, add_item)
    for _, item in ipairs(result.items) do
        local menu_item = { import_item = item }
        menu_item.callback = function()
            item.selected = not item.selected
            setTexts()
            view:updateItems()
        end
        table.insert(menu_items, menu_item)
    end
    if #result.missing > 0 then
        table.insert(menu_items, {
            text = string.format("— Không tìm thấy truyện online (%d) —", #result.missing),
        })
        for _, entry in ipairs(result.missing) do
            table.insert(menu_items, {
                text = "    " .. entry.label,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        title = "Truyện Việt",
                        text = "Không ghép được với truyện online nào nên không thêm:\n" .. entry.path,
                    })
                end,
            })
        end
    end
    setTexts()
    view = showView("Thêm truyện trên máy vào Tủ truyện", menu_items, on_return_callback)
end

-- Mở một mục Lịch sử đọc: mục "Trên máy" mở lại file đã đọc (KOReader tự
-- về trang cũ), truyện online vào trang truyện. Trả về false nếu không mở được.
function Browser:openHistoryItem(item, on_return_callback)
    local story = item.story
    if LocalLibrary.isLocal(story) then
        local kind = LocalLibrary.entryType(item.chapter.url)
        if kind and kind ~= "dir" then
            if LocalLibrary.entryType(story.url) == "dir" then
                self:openFolderBook(LocalLibrary.listBooks(story.url), item.chapter.url)
            else
                self:openEbookFile(item.chapter.url)
            end
            return true
        end
        if LocalLibrary.entryType(story.url) then
            self:openLocalEntry(story, nil, on_return_callback)
            return true
        end
        return false
    end
    local source = SourceRegistry:get(story.source_id)
    if not source then
        return false
    end
    self:loadStoryPage(story, source, 1, on_return_callback)
    return true
end

-- Hỏi "Đọc tiếp" chương đọc cuối của một mục Lịch sử đọc (Lịch sử đọc, nút
-- "Tiếp tục" ở trang chủ và lệnh Tiếp tục đọc). Nút còn lại vào mục lục hoặc
-- danh sách tập. view (có thể nil) chỉ đóng khi đã chọn; back là nơi quay về.
-- story: bản sao đang hiển thị (mặc định item.story).
function Browser:confirmContinue(item, view, back, story)
    story = story or item.story
    -- Không có cửa sổ nào đang mở thì báo lỗi xong quay về back.
    local on_error = not view and back or nil
    if LocalLibrary.isLocal(story) then
        local kind = LocalLibrary.entryType(story.url)
        if not kind then
            showError("Không còn tìm thấy trên máy:\n" .. story.url, on_error)
            return
        end
        UIManager:show(ConfirmBox:new{
            title = "Truyện Việt",
            text = "Đọc tiếp: " .. item.chapter.title .. "?",
            ok_text = "Đọc tiếp",
            cancel_text = kind == "dir" and "Danh sách tập" or "Hủy",
            ok_callback = function()
                closeAndRun(view, function()
                    if not self:openHistoryItem(item, back) then
                        back()
                    end
                end)
            end,
            cancel_callback = kind == "dir" and function()
                self:openLocalEntry(story, view, back)
            end or nil,
        })
        return
    end
    local source = SourceRegistry:get(story.source_id)
    if not source then
        showError("Nguồn truyện không còn khả dụng.", on_error)
        return
    end
    UIManager:show(ConfirmBox:new{
        title = "Truyện Việt",
        text = "Đọc tiếp: " .. item.chapter.title .. "?",
        ok_text = "Đọc tiếp",
        cancel_text = "Mục lục",
        ok_callback = function()
            closeAndRun(view, function()
                self:loadStoryPage(story, source, 1, back, item.chapter)
            end)
        end,
        cancel_callback = function()
            closeAndRun(view, function()
                self:loadStoryPage(story, source, 1, back)
            end)
        end,
    })
end

function Browser:showHistory(on_return_callback, focus_story)
    healLocalEntries()
    local history = Storage:getHistory()
    if #history == 0 then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            title = "Truyện Việt",
            text = "Chưa có lịch sử đọc.",
            ok_text = "Đóng",
            ok_callback = function()
                if on_return_callback then
                    UIManager:nextTick(on_return_callback)
                end
            end,
        })
        return
    end

    local stories = {}
    local history_by_url = {}
    local progress_cache = {}
    
    for _, item in ipairs(history) do
        -- Bản sao để hiện chương đọc cuối mà không ghi thêm trường vào lịch sử.
        local story = {}
        for key, value in pairs(item.story) do
            story[key] = value
        end
        story.reading_chapter = item.chapter.title
        -- Mục lưu trước khi số chương được nâng theo chương đang đọc.
        Storage.raiseLatestChapter(story, { item.chapter })
        if LocalLibrary.isLocal(story) then
            story.reading_percent = ReadingProgress.percent(item.chapter.url, nil, progress_cache)
        else
            local source = SourceRegistry:get(story.source_id)
            if source and Storage:isDownloaded(source, story, item.chapter) then
                story.reading_percent = chapterPercent(source, story, item.chapter, progress_cache)
            end
        end
        table.insert(stories, story)
        history_by_url[story.source_id .. "|" .. story.url] = item
    end
    LocalLibrary.copyFavoriteCovers(stories, Storage:listFavorites())

    self:showStories(
        "Lịch sử đọc",
        stories,
        on_return_callback,
        {
            -- No right icon
            focus_story = focus_story,
            on_story_tap = function(story, view)
                local item = history_by_url[
                    story.source_id .. "|" .. story.url
                ]
                self:confirmContinue(item, view, function()
                    self:showHistory(on_return_callback, story)
                end, story)
            end,
            on_story_hold = function(story, view)
                UIManager:show(ConfirmBox:new{
            title = "Truyện Việt",
            text = "Xóa khỏi lịch sử đọc?",
                    ok_text = "Xóa",
                    ok_callback = function()
                        Storage:removeHistory(story)
                        view:removeStory(story)
                        if #view.stories == 0 then
                            closeAndRun(view, on_return_callback)
                        end
                    end,
                })
            end,
        }
    )
end

function Browser:showSourceManager(on_return_callback)
    local view
    local items = {
        {
            text = "⚙ TÙY CHỌN BẬT / TẮT / RESET HÀNG LOẠT",
            mandatory_func = function() return "Công cụ" end,
            callback = function()
                closeAndRun(view, function()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local bulk_dialog
                    bulk_dialog = ButtonDialog:new{
                        title = "Quản lý Hàng loạt Nguồn",
                        description = "Chọn thao tác áp dụng cho tất cả nguồn:",
                        buttons = {
                            {
                                {
                                    text = "⚡ Bật tất cả các nguồn",
                                    callback = function()
                                        SourceRegistry:enableAll()
                                        UIManager:close(bulk_dialog)
                                        self:showSourceManager(on_return_callback)
                                    end,
                                },
                                {
                                    text = "⏸ Tắt tất cả các nguồn",
                                    callback = function()
                                        SourceRegistry:disableAll()
                                        UIManager:close(bulk_dialog)
                                        self:showSourceManager(on_return_callback)
                                    end,
                                },
                            },
                            {
                                {
                                    text = "↻ Đặt lại tất cả Domain mặc định",
                                    callback = function()
                                        SourceRegistry:resetAllDomains()
                                        UIManager:close(bulk_dialog)
                                        self:showSourceManager(on_return_callback)
                                    end,
                                },
                            },
                            {
                                {
                                    text = "Quay lại",
                                    callback = function()
                                        UIManager:close(bulk_dialog)
                                        self:showSourceManager(on_return_callback)
                                    end,
                                }
                            }
                        }
                    }
                    UIManager:show(bulk_dialog)
                end)
            end,
        }
    }

    for _, source in ipairs(SourceRegistry:listAll()) do
        local current_source = source
        table.insert(items, {
            text = current_source.name,
            mandatory_func = function()
                local is_on = SourceRegistry:isEnabled(current_source.id)
                local status_text = is_on and "✓ Đang bật" or "✗ Đã tắt"
                if Storage:getCustomBaseUrl(current_source.id) then
                    status_text = status_text .. " (Domain mới)"
                end
                if SourceRegistry:isCustomSource(current_source.id) then
                    status_text = status_text .. " [Tùy chỉnh]"
                else
                    status_text = status_text .. " [Gốc]"
                end
                return status_text
            end,
            callback = function()
                self:showSourceActionDialog(current_source, on_return_callback, view)
            end,
            hold_callback = function()
                self:showSourceActionDialog(current_source, on_return_callback, view)
            end,
        })
    end

    view = ListView:new{
        title = "Quản lý Nguồn Truyện",
        item_table = items,
        on_return_callback = on_return_callback,
    }
    UIManager:show(view)
end

function Browser:showSourceActionDialog(source, on_return_callback, parent_view)
    local ButtonDialog = require("ui/widget/buttondialog")
    local InputDialog = require("ui/widget/inputdialog")
    local ConfirmBox = require("ui/widget/confirmbox")
    local TextViewer = require("ui/widget/textviewer")
    local is_enabled = SourceRegistry:isEnabled(source.id)
    local is_custom = SourceRegistry:isCustomSource(source.id)
    local custom_domain = Storage:getCustomBaseUrl(source.id)
    local current_domain = custom_domain or source.base_url or ""
    local dlg

    local function refreshSourceManager()
        if parent_view then
            closeAndRun(parent_view, function()
                self:showSourceManager(on_return_callback)
            end)
        else
            self:showSourceManager(on_return_callback)
        end
    end

    local action_buttons = {
        {
            {
                text = is_enabled and "⏸ Tắt Nguồn này" or "▶ Bật Nguồn này",
                is_default = true,
                callback = function()
                    SourceRegistry:setEnabled(source.id, not is_enabled)
                    closeAndRun(dlg, function()
                        refreshSourceManager()
                    end)
                end,
            },
        },
        {
            {
                text = "ℹ Xem Thông tin chi tiết Nguồn",
                callback = function()
                    local info_text = SourceRegistry:getSourceInfo(source.id)
                    UIManager:show(TextViewer:new{
                        title = "Thông tin: " .. source.name,
                        text = info_text,
                    })
                end,
            },
        },
        {
            {
                text = "🌐 Cập nhật Tên miền / URL (" .. (custom_domain and "Đã sửa" or "Mặc định") .. ")",
                callback = function()
                    closeAndRun(dlg, function()
                        local dialog
                        dialog = InputDialog:new{
                            title = "Đổi tên miền: " .. source.name,
                            description = "Nhập tên miền mới khi trang web thay đổi URL (vd: https://mtruyen.org):",
                            input = current_domain,
                            buttons = {
                                {
                                    {
                                        text = "Dùng Mặc định",
                                        callback = function()
                                            Storage:setCustomBaseUrl(source.id, nil)
                                            closeAndRun(dialog, function()
                                                refreshSourceManager()
                                            end)
                                        end,
                                    },
                                    {
                                        text = "Hủy",
                                        callback = function()
                                            closeAndRun(dialog, function()
                                                self:showSourceActionDialog(source, on_return_callback, parent_view)
                                            end)
                                        end,
                                    },
                                    {
                                        text = "Lưu Tên miền mới",
                                        is_default = true,
                                        callback = function()
                                            local new_url = dialog:getInputText()
                                            if new_url and new_url ~= "" then
                                                if not new_url:find("^https?://") then
                                                    new_url = "https://" .. new_url
                                                end
                                                Storage:setCustomBaseUrl(source.id, new_url)
                                            end
                                            closeAndRun(dialog, function()
                                                refreshSourceManager()
                                            end)
                                        end,
                                    },
                                }
                            }
                        }
                        UIManager:show(dialog)
                    end)
                end,
            },
        },
        {
            {
                text = "⬆ Đẩy lên trên",
                callback = function()
                    SourceRegistry:moveUp(source.id)
                    closeAndRun(dlg, function()
                        refreshSourceManager()
                    end)
                end,
            },
            {
                text = "🔝 Lên Đầu trang",
                callback = function()
                    SourceRegistry:moveToTop(source.id)
                    closeAndRun(dlg, function()
                        refreshSourceManager()
                    end)
                end,
            },
            {
                text = "⬇ Đẩy xuống dưới",
                callback = function()
                    SourceRegistry:moveDown(source.id)
                    closeAndRun(dlg, function()
                        refreshSourceManager()
                    end)
                end,
            },
        },
    }

    if source.supports_login and type(source.login) == "function" then
        table.insert(action_buttons, 3, {
            {
                text = CredentialManager:hasCredential(source.id)
                    and "● Tài khoản (Đã lưu)"
                    or "● Đăng nhập tài khoản",
                callback = function()
                    closeAndRun(dlg, function()
                        self:showSourceAccountMenu(source, function()
                            self:showSourceActionDialog(
                                source,
                                on_return_callback,
                                parent_view
                            )
                        end)
                    end)
                end,
            },
        })
    end

    if is_custom then
        table.insert(action_buttons, {
            {
                text = "✕ Xóa Nguồn Tùy chỉnh này",
                callback = function()
                    closeAndRun(dlg, function()
                        UIManager:show(ConfirmBox:new{
                            text = "Bạn có chắc chắn muốn xóa nguồn tùy chỉnh '" .. source.name .. "' không?\n(Hành động này sẽ xóa file quy tắc JSON khỏi máy)",
                            ok_text = "Xóa Nguồn",
                            cancel_text = "Hủy",
                            ok_callback = function()
                                local ok, err = SourceRegistry:deleteCustomSource(source.id)
                                if ok then
                                    UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã xóa nguồn tùy chỉnh: " .. source.name })
                                else
                                    showError(err or "Không thể xóa nguồn", on_return_callback)
                                end
                                refreshSourceManager()
                            end,
                            cancel_callback = function()
                                self:showSourceActionDialog(source, on_return_callback, parent_view)
                            end,
                        })
                    end)
                end,
            }
        })
    end

    table.insert(action_buttons, {
        {
            text = "Quay lại Danh sách Nguồn",
            callback = function()
                UIManager:close(dlg)
                if not parent_view then
                    self:showSourceManager(on_return_callback)
                end
            end,
        }
    })

    dlg = ButtonDialog:new{
        title = "Quản lý: " .. source.name,
        description = "Domain: " .. current_domain .. "\nID: " .. source.id .. (is_custom and " (Nguồn cào tự động)" or " (Nguồn gốc)"),
        buttons = action_buttons,
    }
    UIManager:show(dlg)
end

function Browser:getLocalChapters(story, source)
    local lfs = require("libs/libkoreader-lfs")
    local Storage = require("truyenviet/storage")
    local Util = require("truyenviet/helpers")
    local chapters = {}
    local seen = {}
    local extension = source.kind == "comic" and ".cbz" or ".html"

    -- Thư mục gắn ngoài (file của người dùng) trước, rồi thư mục plugin tải về;
    -- trùng số chương thì chỉ giữ một mục.
    local linked = Storage:getLinkedDir(story)
    local dirs = { Storage:getDownloadDir(source.id, story.url) }
    if linked then
        table.insert(dirs, 1, linked)
    end
    for _, dir in ipairs(dirs) do
        pcall(function()
            for file in lfs.dir(dir) do
                if file:sub(-#extension) == extension and not file:find("^%.") then
                    local basename = file:sub(1, -(#extension + 1))
                    local number = Storage.chapterNumber(basename)
                    local key = number and ("#" .. tostring(number)) or basename
                    if not seen[key] then
                        seen[key] = true
                        table.insert(chapters, {
                            title = basename,
                            url = "local/" .. basename,
                            is_local = true,
                            number = number,
                        })
                    end
                end
            end
        end)
    end

    if #chapters == 0 then
        return nil
    end

    table.sort(chapters, function(a, b)
        if a.number and b.number and a.number ~= b.number then
            return a.number < b.number
        end
        return Util.naturalCompare(a.title, b.title)
    end)

    if source.reversed_chapters then
        local rev = {}
        for i = #chapters, 1, -1 do
            table.insert(rev, chapters[i])
        end
        chapters = rev
    end

    return chapters
end

local ok_socket, socket = pcall(require, "socket")
local function preciseNow()
    if ok_socket and type(socket) == "table" and type(socket.gettime) == "function" then
        return socket.gettime()
    end
    return os.time()
end

-- Bổ sung trường còn thiếu của truyện từ bản lưu, giữ nguyên đối tượng đang dùng.
local function fillStory(story, saved)
    if type(saved) ~= "table" then
        return
    end
    for key, value in pairs(saved) do
        if story[key] == nil then
            story[key] = value
        end
    end
end

-- Nguồn sửa story tại chỗ, nhưng khi chạy nền thì việc sửa nằm ở tiến trình
-- con: chép lại các trường từ kết quả trả về.
local function copyStory(story, fresh)
    if type(fresh) ~= "table" or fresh == story then
        return
    end
    for key, value in pairs(fresh) do
        story[key] = value
    end
end

local function clockText(timestamp)
    return os.date("%H:%M", timestamp or os.time())
end

-- Dòng trạng thái đầu mục lục; nil khi mới tải lần đầu (không cần báo).
local function refreshStatusText(page_data)
    local state = page_data.refresh_state
    if state == "running" then
        return "⟳ Đang lấy chương mới…"
    elseif state == "done" then
        local when = clockText(page_data.refreshed_at)
        if (page_data.new_count or 0) > 0 then
            return string.format("Có %d chương mới · %s", page_data.new_count, when)
        end
        return "Đã là mới nhất · " .. when
    elseif state == "fresh" then
        return "Cập nhật lúc " .. clockText(page_data.cache_saved_at) .. " · chạm để làm mới"
    elseif state == "failed" then
        return "Không cập nhật được · chạm để thử lại"
    elseif state == "offline" then
        return "Ngoại tuyến · danh sách lưu lúc " .. clockText(page_data.cache_saved_at)
    end
end

-- force_refresh: bỏ qua mục lục lưu, tải lại (có hộp chờ).
function Browser:loadStoryPage(story, source, page, on_return_callback, auto_open_chapter, from_reader, chapter_sort, force_refresh)
    local started = preciseNow()
    local sort_mode = chapter_sort or ChapterOrder.defaultMode(source)

    local function present(page_data)
        Debug.verbose(string.format("[Mục lục] %s trang %d hiện sau %.2fs (%s)",
            tostring(story.title), page, preciseNow() - started,
            tostring(page_data.refresh_state or "tải mới")))
        if auto_open_chapter then
            local chapter_to_open = autoOpenChapter(
                page_data.chapters,
                auto_open_chapter
            )
            if chapter_to_open then
                self:openChapter(nil, page_data, source, chapter_to_open, on_return_callback, false, from_reader)
                return
            end
        end
        self:showChapterList(page_data, source, on_return_callback)
    end

    local online = isOnline()

    -- Có mục lục lưu: mở ngay, làm mới nền nếu đã cũ.
    local cached, saved_at
    if not force_refresh then
        cached, saved_at = ChapterCache.get(source.id, story.url, page)
    end
    if cached then
        fillStory(story, cached.story)
        Storage.raiseLatestChapter(story, cached.chapters)
        local page_data = {
            story = story,
            page = page,
            total_pages = tonumber(cached.total_pages) or 1,
            chapters = cached.chapters,
            cache_saved_at = saved_at,
        }
        ChapterOrder.apply(page_data, source, sort_mode)
        local age = saved_at and os.time() - saved_at
        if not online then
            page_data.refresh_state = "offline"
        elseif age and age >= 0 and age < ChapterCache.ttl then
            page_data.refresh_state = "fresh"
        else
            page_data.refresh_state = "running"
            self:startRefresh(page_data, source, on_return_callback)
        end
        present(page_data)
        return
    end

    if not online and not force_refresh then
        local local_chapters = self:getLocalChapters(story, source)
        if local_chapters then
            local page_data = {
                story = story,
                page = 1,
                total_pages = 1,
                chapters = local_chapters,
            }
            ChapterOrder.apply(page_data, source, sort_mode)
            present(page_data)
            return
        end
    end

    runOnline(function()
        local previous = force_refresh and ChapterCache.get(source.id, story.url, page)
        local page_data, err = withLoading(
            string.format("Đang tải danh sách chương...\nTrang %d", page),
            function()
                return source:getStoryPage(story, page)
            end
        )
        if not page_data then
            showError(err, on_return_callback)
            return
        end
        -- Lưu theo thứ tự của nguồn; thứ tự hiển thị áp lại mỗi lần mở.
        ChapterCache.put(source.id, story.url, page, page_data)
        if previous then
            page_data.refresh_state = "done"
            page_data.refreshed_at = os.time()
            page_data.new_count = ChapterCache.newChapterCount(previous.chapters, page_data.chapters)
        end
        ChapterOrder.apply(page_data, source, sort_mode)
        Storage.raiseLatestChapter(page_data.story, page_data.chapters)
        Storage:updateFavorite(page_data.story)
        present(page_data)
    end)
end

-- Lấy lại mục lục trong tiến trình con; xong thì cập nhật page_data tại chỗ
-- (openChapter tìm chương kề lúc cần nên thấy được chương mới).
function Browser:startRefresh(page_data, source, on_return_callback)
    local story = page_data.story
    local page = page_data.page
    local started = preciseNow()
    local key = table.concat({ tostring(source.id), tostring(story.url), tostring(page) }, "|")

    local function on_done(ok, result, err)
        Debug.verbose(string.format("[Mục lục] Làm mới nền %s trang %d: %.2fs, %s",
            tostring(story.title), page, preciseNow() - started, ok and "xong" or tostring(err)))
        if not ok or type(result) ~= "table" or type(result.chapters) ~= "table" then
            if err == "cancelled" then
                -- Bị thay bằng việc làm mới truyện/trang khác.
                page_data.refresh_state = "fresh"
            else
                page_data.refresh_state = "failed"
                Debug.write("[Mục lục] Không làm mới được " .. tostring(story.title)
                    .. ": " .. tostring(err or "kết quả sai"))
            end
            self:refreshChapterView(page_data, source, on_return_callback)
            return
        end

        ChapterCache.put(source.id, story.url, page, result)
        copyStory(story, result.story)
        Storage.raiseLatestChapter(story, result.chapters)
        Storage:updateFavorite(story)
        page_data.new_count = ChapterCache.newChapterCount(page_data.chapters, result.chapters)
        page_data.chapters = result.chapters
        page_data.total_pages = tonumber(result.total_pages) or page_data.total_pages
        ChapterOrder.apply(page_data, source,
            page_data.chapter_sort or ChapterOrder.defaultMode(source))
        page_data.refreshed_at = os.time()
        page_data.cache_saved_at = page_data.refreshed_at
        page_data.refresh_state = "done"
        self:refreshChapterView(page_data, source, on_return_callback)
    end

    local started_ok = BackgroundFetch.run(key, function()
        return source:getStoryPage(story, page)
    end, on_done)
    if not started_ok then
        -- Không fork được: giữ danh sách lưu, người dùng chạm dòng trạng thái để tải lại.
        page_data.refresh_state = "failed"
    end
end

-- Dựng lại mục lục đang hiện, giữ nguyên trang đang xem.
function Browser:refreshChapterView(page_data, source, on_return_callback)
    local view = page_data.view
    if not view or view._truyenviet_closed or view._truyenviet_hidden then
        return
    end
    view:switchItemTable(nil, self:buildChapterItems(page_data, source, on_return_callback), -1)
end

local Widget = require("ui/widget/widget")
-- Ô tiến độ góc dưới. Là toast: luôn nằm trên nhưng không chặn chạm (cửa sổ
-- thường nằm trên cùng sẽ nhận và nuốt mọi chạm của danh sách bên dưới).
local FloatingProgress = Widget:extend{
    text = "",
    toast = true,
    shown = false,
    init = function(self)
        local TextWidget = require("ui/widget/textwidget")
        local FrameContainer = require("ui/widget/container/framecontainer")
        local Size = require("ui/size")
        local Font = require("ui/font")
        local Blitbuffer = require("ffi/blitbuffer")

        self.text_w = TextWidget:new{
            text = self.text,
            face = Font:getFace("infofont", 18),
            fgcolor = Blitbuffer.COLOR_BLACK,
        }

        self.frame = FrameContainer:new{
            padding = Size.padding.small,
            margin = 0,
            bordersize = 2,
            background = Blitbuffer.COLOR_WHITE,
            self.text_w
        }
        self:updateGeom()
    end,
    updateGeom = function(self)
        local Screen = require("device").screen
        local Geom = require("ui/geometry")

        if self.frame.freeSizing then self.frame:freeSizing() end
        local size = self.frame:getSize()

        self.w = size.w
        self.h = size.h
        self.x = 10
        self.y = Screen:getHeight() - self.h - 10

        self.dimen = Geom:new{ x = self.x, y = self.y, w = self.w, h = self.h }
    end,
    paintTo = function(self, b, x, y)
        self.frame.dimen = self.dimen
        self.frame:paintTo(b, self.x, self.y)
    end,
    setText = function(self, text)
        if self.text == text then return end
        self.text = text
        local old_dim = { x = self.dimen.x, y = self.dimen.y, w = self.dimen.w, h = self.dimen.h }

        self.text_w:setText(text)
        self:updateGeom()
        if not self.shown then return end

        local Geom = require("ui/geometry")
        local min_x = math.min(old_dim.x, self.dimen.x)
        local min_y = math.min(old_dim.y, self.dimen.y)
        local max_right = math.max(old_dim.x + old_dim.w, self.dimen.x + self.dimen.w)
        local max_bottom = math.max(old_dim.y + old_dim.h, self.dimen.y + self.dimen.h)

        -- Vẽ lại cả cửa sổ bên dưới vùng cũ (chữ ngắn đi thì phần thừa phải xóa).
        UIManager:setDirty("all", "ui", Geom:new{
            x = min_x,
            y = min_y,
            w = max_right - min_x,
            h = max_bottom - min_y
        })
    end,
    show = function(self)
        if self.shown then return end
        self.shown = true
        UIManager:show(self)
    end,
    hide = function(self)
        if not self.shown then return end
        UIManager:close(self)
    end,
    onCloseWidget = function(self)
        self.shown = false
    end,
    -- KOReader chỉ thoát khi không còn cửa sổ nào: đóng ngay khi Exit/Restart.
    onExit = function(self)
        self:hide()
    end,
    onRestart = function(self)
        self:hide()
    end,
}

-- Chạy task_func trong coroutine của tiến trình chính (chỉ nhường UI giữa các
-- bước). Dùng cho gom file và làm đường dự phòng khi không fork được.
local function runInBackground(task_name, task_func, on_complete)
    local indicator = FloatingProgress:new{
        text = "Đang tải ngầm: " .. task_name
    }
    indicator:show()

    local co = coroutine.create(task_func)
    local final_result = nil
    local function tick()
        if coroutine.status(co) ~= "dead" then
            local ok, result = coroutine.resume(co)
            if not ok then
                indicator:hide()
                UIManager:show(InfoMessage:new{
                    title = "Truyện Việt - Lỗi tải",
                    text = "Lỗi khi chạy tải ngầm:\n" .. tostring(result),
                })
            else
                if coroutine.status(co) == "dead" then
                    final_result = result
                elseif type(result) == "string" then
                    indicator:setText(result)
                end
                UIManager:scheduleIn(0.05, tick)
            end
        else
            indicator:hide()
            UIManager:show(Notification:new{
                text = "Tải ngầm hoàn tất: " .. task_name,
            })
            if on_complete then on_complete(final_result) end
        end
    end
    UIManager:scheduleIn(0, tick)
end

local function isReading()
    return require("apps/reader/readerui").instance ~= nil
end

local function downloadJobText(status)
    return string.format(
        "⤓ %s %d/%d",
        Util.shorten(status.title, 24),
        status.done or 0,
        status.total or 0
    )
end

-- Đang có việc tải nền: hỏi hủy (mỗi lúc chỉ một việc).
function Browser:showDownloadJobDialog()
    local DownloadJob = require("truyenviet/download_job")
    local status = DownloadJob.status()
    if not status then
        return false
    end
    local dialog
    dialog = ButtonDialog:new{
        title = string.format(
            "Đang tải nền \"%s\": %d/%d chương.\nMỗi lúc chỉ tải nền một truyện.",
            tostring(status.title or ""),
            status.done or 0,
            status.total or 0
        ),
        buttons = {
            {
                {
                    text = "Hủy tải nền",
                    callback = function()
                        UIManager:close(dialog)
                        DownloadJob.cancel("cancelled")
                    end,
                },
                {
                    text = "Đóng",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    return true
end

-- Hộp hỏi gộp file như trước; đang đọc thì chỉ báo nhỏ để không cắt ngang.
function Browser:onChaptersDownloaded(view, source, story, result, already_downloaded)
    local view_visible = view and view.updateItems
        and not view._truyenviet_closed and not view._truyenviet_hidden
    if view_visible then
        view:updateItems()
    end
    local total_count = result.downloaded + (already_downloaded or 0)

    if isReading() then
        local text = string.format("Đã tải xong %d chương: %s", result.downloaded, tostring(story.title or ""))
        if #result.errors > 0 then
            text = text .. string.format(" (lỗi %d chương)", #result.errors)
        end
        UIManager:show(Notification:new{ text = text })
        return
    end

    local message = string.format(
        "Đã hoàn tất tải %d chương mới (tổng %d chương).\n\nBạn có muốn GỘP CÁC CHƯƠNG THÀNH 1 FILE (EPUB/HTML) ngay bây giờ không?",
        result.downloaded,
        total_count
    )
    if #result.errors > 0 then
        local shown = {}
        for index = 1, math.min(#result.errors, 5) do
            table.insert(shown, result.errors[index])
        end
        message = message
            .. string.format("\n(Lỗi %d chương:\n%s)", #result.errors, table.concat(shown, "\n"))
    end

    local function refreshView()
        if view and view.updateItems and not view._truyenviet_closed and not view._truyenviet_hidden then
            view:updateItems()
        end
    end
    UIManager:show(ConfirmBox:new{
        title = "Truyện Việt - Hoàn Tất Tải Chương",
        text = message,
        ok_text = "Có, Gộp File Ngay",
        cancel_text = "Để Sau",
        ok_callback = function()
            local item = {
                source_id = source.id,
                story_slug = Util.urlLeaf(story.url, Util.safeName(story.title, "story")),
                chapter_count = total_count,
            }
            self:showMergeOptionsDialog(item, refreshView)
        end,
        cancel_callback = refreshView,
    })
end

-- Tải trong tiến trình con: giao diện không bị chặn, đọc truyện khác được.
-- Trả về false nếu không chạy nền được (người gọi dùng cách cũ).
function Browser:startDownloadJob(view, source, story, chapters, already_downloaded)
    local DownloadJob = require("truyenviet/download_job")
    if not DownloadJob.isAvailable() then
        return false
    end
    ChapterDownloader:cleanupPartials(source, story, chapters)

    local title = tostring(story.title or "")
    local indicator = FloatingProgress:new{
        text = downloadJobText({ title = title, done = 0, total = #chapters }),
    }
    local function syncIndicator(status)
        if not status then
            indicator:hide()
            return
        end
        indicator:setText(downloadJobText(status))
        if isReading() then
            indicator:hide()
        else
            indicator:show()
        end
    end

    local started, reason = DownloadJob.start{
        key = tostring(source.id) .. ":" .. tostring(story.url),
        title = title,
        total = #chapters,
        progress_path = Storage:getDownloadProgressPath(),
        task = function(report)
            return ChapterDownloader:download(source, story, chapters, {
                subprocess = true,
                on_progress = report,
            })
        end,
        cleanup = function()
            ChapterDownloader:cleanupPartials(source, story, chapters)
        end,
        on_poll = syncIndicator,
        on_done = function(ok, result, err)
            indicator:hide()
            if err == "exit" then
                return
            end
            if not ok then
                if err == "cancelled" then
                    if view and view.updateItems and not view._truyenviet_closed and not view._truyenviet_hidden then
                        view:updateItems()
                    end
                    UIManager:show(Notification:new{ text = "Đã hủy tải nền: " .. title })
                else
                    ChapterDownloader:cleanupPartials(source, story, chapters)
                    showError("Lỗi tải nền: " .. tostring(err))
                end
                return
            end
            if type(result) ~= "table" then
                showError("Lỗi tải chương không mong muốn")
                return
            end
            result.errors = result.errors or {}
            result.downloaded = result.downloaded or 0
            if result.first_path and G_reader_settings and G_reader_settings.addDocument then
                G_reader_settings:addDocument(result.first_path)
                G_reader_settings:flush()
            end
            self:onChaptersDownloaded(view, source, story, result, already_downloaded)
        end,
    }
    if not started then
        if reason == "busy" then
            self:showDownloadJobDialog()
            return true
        end
        return false
    end
    syncIndicator(DownloadJob.status())
    return true
end

function Browser:downloadChapters(
    view,
    page_data,
    source,
    chapters,
    already_downloaded
)
    if self:showDownloadJobDialog() then
        return
    end
    local story = page_data.story
    -- Không bọc Trapper: tiến trình con không được thừa hưởng coroutine nào.
    NetworkMgr:runWhenOnline(function()
        if self:startDownloadJob(view, source, story, chapters, already_downloaded) then
            return
        end
        Trapper:wrap(function()
            runInBackground(string.format("Tải %d chương...", #chapters), function()
                return ChapterDownloader:download(source, story, chapters)
            end, function(result)
                if type(result) ~= "table" then
                    ChapterDownloader:cleanupPartials(source, story, chapters)
                    showError("Lỗi tải chương không mong muốn")
                    return
                end
                self:onChaptersDownloaded(view, source, story, result, already_downloaded)
            end)
        end)
    end)
end

-- Số chương đọc từ tiêu đề (hoặc URL), dùng cho khoảng "từ chương X đến Y"
local function chapterNumber(chapter)
    local title = tostring(chapter.title or ""):lower()
    local number = title:match("chương%s*(%d+%.?%d*)")
        or title:match("chapter%s*(%d+%.?%d*)")
        or title:match("chap%s*(%d+%.?%d*)")
        or title:match("(%d+%.?%d*)")
        or tostring(chapter.url or ""):match("chap%-(%d+)")
    return tonumber(number)
end

-- chapters: toàn bộ chương của truyện, xếp từ cũ nhất đến mới nhất
function Browser:showDownloadRangeDialog(view, page_data, source, chapters)
    if self:showDownloadJobDialog() then
        return
    end
    local story = page_data.story
    local pending = ChapterDownloader:listPending(source, story, chapters)
    if #pending == 0 then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Tất cả các chương đã được tải.",
        })
        return
    end
    local already_downloaded = #chapters - #pending
    local is_pending = {}
    for _, chapter in ipairs(pending) do
        is_pending[chapter] = true
    end

    -- Chọn theo số chương trong tiêu đề nếu chương nào cũng có số,
    -- nếu không thì theo vị trí trong danh sách (1 = cũ nhất)
    local keys = {}
    local by_number = true
    for index, chapter in ipairs(chapters) do
        keys[index] = chapterNumber(chapter)
        if not keys[index] then
            by_number = false
        end
    end
    if not by_number then
        for index = 1, #chapters do
            keys[index] = index
        end
    end
    local lowest, highest = math.huge, -math.huge
    for _, key in ipairs(keys) do
        lowest = math.min(lowest, key)
        highest = math.max(highest, key)
    end

    local description = string.format(
        "Truyện có %d chương: đã tải %d, còn %d chưa tải.\nCũ nhất: %s\nMới nhất: %s\n%s",
        #chapters,
        already_downloaded,
        #pending,
        tostring(chapters[1].title or chapters[1].url),
        tostring(chapters[#chapters].title or chapters[#chapters].url),
        by_number
            and "Nhập số chương theo tiêu đề."
            or "Nhập vị trí trong danh sách (1 = chương cũ nhất)."
    )
    if source.kind == "comic" then
        description = description
            .. "\nTruyện tranh có thể tốn nhiều thời gian và dung lượng lưu trữ."
    end

    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local dialog
    local function start(order)
        local fields = dialog:getFields()
        local from = tonumber(fields[1])
        local to = tonumber(fields[2])
        if not from or not to then
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = "Vui lòng nhập số hợp lệ cho cả hai ô.",
            })
            return
        end
        if from > to then
            from, to = to, from
        end
        local selected = {}
        for index, chapter in ipairs(chapters) do
            if is_pending[chapter] and keys[index] >= from and keys[index] <= to then
                table.insert(selected, chapter)
            end
        end
        if #selected == 0 then
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = "Không có chương chưa tải nào trong khoảng này.",
            })
            return
        end
        if order == "desc" then
            local reversed = {}
            for index = #selected, 1, -1 do
                table.insert(reversed, selected[index])
            end
            selected = reversed
        end
        closeAndRun(dialog, function()
            self:downloadChapters(view, page_data, source, selected, already_downloaded)
        end)
    end

    dialog = MultiInputDialog:new{
        title = "Tải chương",
        fields = {
            {
                text = string.format("%g", lowest),
                hint = "Từ chương",
                input_type = "number",
                description = description .. "\n\nTừ chương:",
            },
            {
                text = string.format("%g", highest),
                hint = "Đến chương",
                input_type = "number",
                description = "Đến chương:",
            },
        },
        buttons = {
            {
                {
                    text = "Hủy",
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = "Cũ → mới",
                    callback = function()
                        start("asc")
                    end,
                },
                {
                    text = "Mới → cũ",
                    callback = function()
                        start("desc")
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function Browser:confirmDownloadChapters(view, page_data, source)
    local story = page_data.story
    if page_data.total_pages > 1 or type(source.getAllChapters) == "function" then
        runOnline(function()
            local all_chapters = {}
            local fetch_ok = false
            local _, err = withLoading("Đang lấy danh sách toàn bộ chương...", function()
                if type(source.getAllChapters) == "function" then
                    local fetched_chapters, fetch_err =
                        source:getAllChapters(story)
                    if not fetched_chapters then
                        return nil, fetch_err
                    end
                    all_chapters = fetched_chapters
                else
                    for p = 1, page_data.total_pages do
                        local p_data = source:getStoryPage(story, p)
                        if p_data and p_data.chapters then
                            for _, c in ipairs(p_data.chapters) do
                                table.insert(all_chapters, c)
                            end
                        else
                            if not p_data or not p_data.chapters or #p_data.chapters == 0 then
                                break
                            end
                        end
                    end
                end
                local Util = require("truyenviet/helpers")
                all_chapters = Util.uniqueBy(all_chapters or {}, "url")
                table.sort(all_chapters, function(a, b)
                    return Util.naturalCompare(a.title or a.url, b.title or b.url)
                end)
                fetch_ok = true
                return true
            end)
            if fetch_ok and #all_chapters > 0 then
                self:showDownloadRangeDialog(
                    view,
                    {story = story, chapters = all_chapters, page = 1, total_pages = 1},
                    source,
                    all_chapters
                )
            else
                showError(err or "Lỗi khi lấy danh sách chương")
            end
        end)
    else
        -- Danh sách đang hiện theo thứ tự người dùng chọn; đưa về cũ nhất trước
        local chapters = {}
        local sort_mode = page_data.chapter_sort or ChapterOrder.defaultMode(source)
        if sort_mode == "desc" then
            for index = #page_data.chapters, 1, -1 do
                table.insert(chapters, page_data.chapters[index])
            end
        else
            for _, chapter in ipairs(page_data.chapters) do
                table.insert(chapters, chapter)
            end
        end
        self:showDownloadRangeDialog(view, page_data, source, chapters)
    end
end

function Browser:confirmDownloadBundle(view, page_data, source)
    local story = page_data.story
    local warning = "Tiến hành tải toàn bộ chương và gom thành 1 file HTML duy nhất?\n\nQuá trình này có thể mất nhiều thời gian tuỳ thuộc vào số lượng chương."
    
    UIManager:show(ConfirmBox:new{
        title = "Truyện Việt",
        text = warning,
        ok_text = "Tải thành 1 bộ",
        ok_callback = function()
            UIManager:scheduleIn(0, function()
                if page_data.total_pages > 1 or type(source.getAllChapters) == "function" then
                    runOnline(function()
                        local all_chapters = {}
                        local fetch_ok = false
                        local _, err = withLoading("Đang lấy danh sách toàn bộ chương...", function()
                            if type(source.getAllChapters) == "function" then
                                local fetched_chapters, fetch_err =
                                    source:getAllChapters(story)
                                if not fetched_chapters then
                                    return nil, fetch_err
                                end
                                all_chapters = fetched_chapters
                            else
                                for p = 1, page_data.total_pages do
                                    local p_data = source:getStoryPage(story, p)
                                    if p_data and p_data.chapters then
                                        for _, c in ipairs(p_data.chapters) do
                                            table.insert(all_chapters, c)
                                        end
                                    else
                                        if not p_data or not p_data.chapters or #p_data.chapters == 0 then
                                            break
                                        end
                                    end
                                end
                            end
                            local Util = require("truyenviet/helpers")
                            all_chapters = Util.uniqueBy(all_chapters or {}, "url")
                            fetch_ok = true
                            return true
                        end)
                        if fetch_ok and #all_chapters > 0 then
                            self:downloadAsBundle(story, source, all_chapters)
                        else
                            showError(err or "Lỗi khi lấy danh sách chương")
                        end
                    end)
                else
                    self:downloadAsBundle(story, source, page_data.chapters)
                end
            end)
        end,
    })
end

function Browser:downloadAsBundle(story, source, all_chapters)
    runOnline(function()
        local Storage = require("truyenviet/storage")
        local Util = require("truyenviet/helpers")
        local CoverCache = require("truyenviet/cover_cache")
        local lfs = require("libs/libkoreader-lfs")
        
        local story_dir = Storage:getStoryDir(source, story)
        local safe_title = story.title:gsub('[<>:"/\\|?*]', '_')
        local out_path = story_dir .. "/" .. safe_title .. ".html"
        
        local html_parts = {}
        table.insert(html_parts, "<!DOCTYPE html>\n<html lang=\"vi\">\n<head>\n<meta charset=\"UTF-8\">\n<title>" .. story.title .. "</title>\n")
        table.insert(html_parts, "<style>\nbody { font-family: serif; max-width: 800px; margin: auto; padding: 1em; }\n.chapter { margin-bottom: 3em; padding-top: 1em; border-top: 1px solid #ccc; }\nh2 { font-size: 1.2em; font-weight: bold; }\n</style>\n</head>\n<body>\n")
        
        -- Thêm cover image vào đầu trang HTML nếu có
        local cover_filename = nil
        if story.cover_url or story.cover_path then
            CoverCache:download(story, source)
            if story.cover_path and lfs.attributes(story.cover_path, "mode") == "file" then
                local ext = story.cover_path:match("%.([^%.]+)$") or "jpg"
                cover_filename = "cover." .. ext
                local dest_path = story_dir .. "/" .. cover_filename
                
                local inf = io.open(story.cover_path, "rb")
                if inf then
                    local data = inf:read("*a")
                    inf:close()
                    local outf = io.open(dest_path, "wb")
                    if outf then
                        outf:write(data)
                        outf:close()
                        table.insert(html_parts, '<div style="text-align: center; page-break-after: always;"><img src="' .. cover_filename .. '" style="max-width: 100%; height: auto;" /></div>\n')
                    end
                end
            end
        end

        table.insert(html_parts, "<h1>" .. story.title .. "</h1>\n")
        if story.details and story.details.author then
            table.insert(html_parts, "<p><strong>Tác giả:</strong> " .. story.details.author .. "</p>\n")
        end
        if story.details and story.details.description then
            table.insert(html_parts, "<div><strong>Giới thiệu:</strong><br/>" .. story.details.description .. "</div><hr/>\n")
        end

        runInBackground("Gom " .. #all_chapters .. " chương...", function()
            local total = #all_chapters
            local successes = 0
            for i, chapter in ipairs(all_chapters) do
                local progress = string.format("Đang gom %d/%d chương...", i, total)
                coroutine.yield(progress) -- Nhường lại UI loop NGAY TRƯỚC khi tải chương, để UI kịp render text
                local ch_data = source:getChapter(chapter)
                if ch_data then
                    table.insert(html_parts, "<div class=\"chapter\">\n<h2>" .. (chapter.title or "Chương " .. i) .. "</h2>\n")
                    table.insert(html_parts, ch_data.content or ch_data)
                    table.insert(html_parts, "\n</div>\n")
                    successes = successes + 1
                end
            end
            
            table.insert(html_parts, "</body>\n</html>")
            
            local f, err = io.open(out_path, "w")
            if not f then
                showError("Lỗi khi ghi tệp: " .. tostring(err))
                return
            end
            f:write(table.concat(html_parts))
            f:close()
            
            if G_reader_settings and G_reader_settings.addDocument then
                G_reader_settings:addDocument(out_path)
                G_reader_settings:flush()
            end
            
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = string.format("Đã lưu thành công %d/%d chương vào:\n%s\n\nBạn có thể mở tệp này bằng KOReader (trong Quản lý tệp tin).", successes, total, out_path)
            })
        end)
        
    end)
end

-- Các mục của danh sách chương; view lấy từ page_data.view lúc chạm vì
-- danh sách có thể được dựng lại sau khi làm mới nền.
function Browser:buildChapterItems(page_data, source, on_return_callback)
    local story = page_data.story
    local sort_mode = page_data.chapter_sort
        or ChapterOrder.defaultMode(source)
    local items = {}
    local progress_cache = {}
    local status = refreshStatusText(page_data)
    if status then
        table.insert(items, {
            text = status,
            dim = page_data.refresh_state == "running" or nil,
            callback = function()
                if page_data.refresh_state == "running" then
                    return
                end
                closeAndRun(page_data.view, function()
                    self:loadStoryPage(
                        story,
                        source,
                        page_data.page,
                        on_return_callback,
                        false,
                        nil,
                        sort_mode,
                        true
                    )
                end)
            end,
        })
    end
    local fixed_items = {
        {
            text = Storage:isFavorite(story)
                and "Xóa khỏi tủ truyện"
                or "Thêm vào tủ truyện",
            mandatory = source.name,
            callback = function()
                toggleFavorite(story, function()
                    closeAndRun(page_data.view, function()
                        self:showChapterList(page_data, source, on_return_callback)
                    end)
                end)
            end,
        },
        {
            text = sort_mode == "desc"
                and "Thứ tự: Mới nhất trước (Z-A)"
                or "Thứ tự: Chương 1 trước (A-Z)",
            mandatory = "Đổi thứ tự",
            callback = function()
                local next_mode = sort_mode == "desc" and "asc" or "desc"
                local target_page = ChapterOrder.targetPage(
                    source,
                    page_data.total_pages,
                    next_mode
                )
                closeAndRun(page_data.view, function()
                    self:loadStoryPage(
                        story,
                        source,
                        target_page,
                        on_return_callback,
                        false,
                        nil,
                        next_mode
                    )
                end)
            end,
        },
    }
    for _, item in ipairs(fixed_items) do
        table.insert(items, item)
    end

    if #page_data.chapters > 0 then
        table.insert(items, {
            text = "Tải truyện",
            callback = function()
                self:confirmDownloadChapters(page_data.view, page_data, source)
            end,
        })
        if source.kind == "text" then
            table.insert(items, {
                text = "Tải thành 1 bộ (gom tất cả chương)",
                callback = function()
                    self:confirmDownloadBundle(page_data.view, page_data, source)
                end,
            })
        end
    end


    if page_data.total_pages > 1 then
        table.insert(items, {
            text = string.format("Trang %d / %d", page_data.page, page_data.total_pages),
            dim = true,
            select_enabled = false,
        })
    end
    local page_step = ChapterOrder.pageStep(source, sort_mode)
    local previous_page = page_data.page - page_step
    local next_page = page_data.page + page_step
    if previous_page >= 1 and previous_page <= page_data.total_pages then
        table.insert(items, {
            text = "← Trang chương trước",
            callback = function()
                closeAndRun(page_data.view, function()
                    self:loadStoryPage(
                        story,
                        source,
                        previous_page,
                        on_return_callback,
                        false,
                        nil,
                        sort_mode
                    )
                end)
            end,
        })
    end
    if next_page >= 1 and next_page <= page_data.total_pages then
        table.insert(items, {
            text = "Trang chương sau →",
            callback = function()
                closeAndRun(page_data.view, function()
                    self:loadStoryPage(
                        story,
                        source,
                        next_page,
                        on_return_callback,
                        false,
                        nil,
                        sort_mode
                    )
                end)
            end,
        })
    end

    for _, chapter in ipairs(page_data.chapters) do
        local current_chapter = chapter
        table.insert(items, {
            text = current_chapter.title,
            mandatory_func = function()
                if not Storage:isDownloaded(source, story, current_chapter) then return "" end
                local percent = chapterPercent(source, story, current_chapter, progress_cache)
                return percent ~= nil and string.format("Đã tải · %d%%", percent) or "Đã tải · -"
            end,
            callback = function()
                self:openChapter(page_data.view, page_data, source, current_chapter, on_return_callback)
            end,
            hold_callback = function()
                self:showChapterActions(
                    page_data.view,
                    page_data,
                    source,
                    current_chapter,
                    on_return_callback
                )
            end,
        })
    end

    if #page_data.chapters == 0 then
        table.insert(items, {
            text = "Không tìm thấy chương ở trang này.",
            dim = true,
            select_enabled = false,
        })
    end

    return items
end

function Browser:showChapterList(page_data, source, on_return_callback)
    local items = self:buildChapterItems(page_data, source, on_return_callback)
    page_data.view = showView(page_data.story.title, items, on_return_callback)
end

function Browser:openChapter(view, page_data, source, chapter, on_return_callback, force, from_reader)
    local story = page_data.story

    local logger = require("logger")
    logger.info("TruyenViet: openChapter called: url=" .. tostring(chapter.url) .. ", from_reader=" .. tostring(from_reader))
    Debug.write("Browser: openChapter called: url=" .. tostring(chapter.url) .. ", from_reader=" .. tostring(from_reader))

    self:triggerPrefetchAndPurge(source, story, page_data, chapter)

    local chapter_sort = page_data.chapter_sort
        or ChapterOrder.defaultMode(source)
    -- Chương nằm trong tệp trọn bộ (mục lục tự tạo của KOReader): mở tệp đó.
    local bundle_path, bundle_page
    if not force then
        bundle_path, bundle_page = Storage:getBundleChapter(source, story, chapter)
    end
    local function chapterByNumber(number)
        for _, item in ipairs(page_data.chapters) do
            if number and Storage.chapterNumberOf(item) == number then
                return item
            end
        end
        return nil
    end
    -- Đang đọc tệp trọn bộ: chương hiện tại là chương tại trang đang mở,
    -- không phải chương đã bấm lúc đầu.
    local function currentChapter()
        local page = bundle_path and Reader:openBookPage(bundle_path)
        if not page then
            return chapter
        end
        return chapterByNumber(Storage:bundleChapterAt(bundle_path, page)) or chapter
    end
    -- Chương đích cũng trong tệp trọn bộ đang mở: lật trang tại chỗ.
    local function gotoInOpenBundle(target)
        if not bundle_path or not target then
            return false
        end
        local path, page = Storage:getBundleChapter(source, story, target)
        if path ~= bundle_path or not Reader:gotoPageInOpenBook(path, page) then
            return false
        end
        Storage:saveHistory(story, target)
        return true
    end
    -- Tìm lúc bấm chuyển chương: mục lục có thể vừa được làm mới nền.
    local function findNeighbors()
        local i = ChapterPosition.indexOf(page_data.chapters, currentChapter())
        if i then
            return page_data.chapters[
                ChapterOrder.nextChapterIndex(chapter_sort, i)
            ], page_data.chapters[
                ChapterOrder.prevChapterIndex(chapter_sort, i)
            ]
        end
    end
    local position_text = ChapterPosition.format(
        ChapterPosition.fromChapterList(page_data, chapter, chapter_sort))

    local function on_next_chapter(called_from_reader)
        local from_reader_flag = (called_from_reader ~= nil) and called_from_reader or from_reader
        local next_chapter = findNeighbors()
        Debug.write("Browser:on_next_chapter triggered, next_chapter=" .. tostring(next_chapter ~= nil) .. ", from_reader=" .. tostring(from_reader_flag))
        UIManager:nextTick(function()
            if gotoInOpenBundle(next_chapter) then
                return
            end
            if next_chapter then
                    if from_reader_flag then
                        -- Return to plugin UI first, then open next chapter from plugin context
                        Reader:returnToPlugin(function()
                            self:openChapter(nil, page_data, source, next_chapter, on_return_callback, false, from_reader_flag)
                        end)
                    else
                        self:openChapter(nil, page_data, source, next_chapter, on_return_callback, false, from_reader_flag)
                    end
                elseif page_data.total_pages > 1 then
                    local next_page = ChapterOrder.nextReadingPage(
                        source,
                        page_data.page,
                        page_data.total_pages
                    )
                    if next_page then
                        local auto_open = ChapterOrder.nextPageAutoOpen(
                            chapter_sort
                        )
                        if from_reader_flag then
                            Reader:returnToPlugin(function()
                                self:loadStoryPage(
                                    story,
                                    source,
                                    next_page,
                                    on_return_callback,
                                    auto_open,
                                    from_reader_flag,
                                    chapter_sort
                                )
                            end)
                        else
                            self:loadStoryPage(
                                story,
                                source,
                                next_page,
                                on_return_callback,
                                auto_open,
                                from_reader_flag,
                                chapter_sort
                            )
                        end
                    else
                        -- Đóng chương rồi gọi lại danh sách đã lưu khi mở reader.
                        Reader:returnToPlugin()
                    end
                else
                    Reader:returnToPlugin()
                end
            end)
        end

    local function on_prev_chapter(called_from_reader)
        local from_reader_flag = (called_from_reader ~= nil) and called_from_reader or from_reader
        local _, prev_chapter = findNeighbors()
        Debug.write("Browser:on_prev_chapter triggered, prev_chapter=" .. tostring(prev_chapter ~= nil) .. ", from_reader=" .. tostring(from_reader_flag))
        UIManager:nextTick(function()
            if gotoInOpenBundle(prev_chapter) then
                return
            end
            if prev_chapter then
                    if from_reader_flag then
                        Reader:returnToPlugin(function()
                            self:openChapter(nil, page_data, source, prev_chapter, on_return_callback, false, from_reader_flag)
                        end)
                    else
                        self:openChapter(nil, page_data, source, prev_chapter, on_return_callback, false, from_reader_flag)
                    end
                elseif page_data.total_pages > 1 then
                    local prev_page = ChapterOrder.prevReadingPage(
                        source,
                        page_data.page,
                        page_data.total_pages
                    )
                    if prev_page then
                        local auto_open = ChapterOrder.prevPageAutoOpen(
                            chapter_sort
                        )
                        if from_reader_flag then
                            Reader:returnToPlugin(function()
                                self:loadStoryPage(
                                    story,
                                    source,
                                    prev_page,
                                    on_return_callback,
                                    auto_open,
                                    from_reader_flag,
                                    chapter_sort
                                )
                            end)
                        else
                            self:loadStoryPage(
                                story,
                                source,
                                prev_page,
                                on_return_callback,
                                auto_open,
                                from_reader_flag,
                                chapter_sort
                            )
                        end
                    else
                        UIManager:show(InfoMessage:new{
                        title = "Truyện Việt",
                        text = "Đã tới chương đầu tiên ở thời điểm hiện tại." })
                    end
                else
                    UIManager:show(InfoMessage:new{
                    title = "Truyện Việt",
                    text = "Đã tới chương đầu tiên ở thời điểm hiện tại." })
                end
            end)
        end

    if bundle_path then
        if view then UIManager:close(view) end
        Storage:saveHistory(story, chapter)
        Debug.write("Browser: chapter in bundle, opening " .. tostring(bundle_path) .. " at page " .. tostring(bundle_page))
        Reader:setPosition(bundle_path, nil)
        -- Lật sang chương khác trong tệp: Lịch sử đọc ghi chương đang đọc.
        Reader:setStartPage(bundle_path, bundle_page, Storage.chapterNumberOf(chapter), function(number)
            local reading = chapterByNumber(number)
            if reading then
                Storage:saveHistory(story, reading)
            end
        end)
        Reader:show(bundle_path, function()
            self:showChapterList(page_data, source, on_return_callback)
        end, on_next_chapter, from_reader, on_prev_chapter)
        return
    end

    local existing = Builder:getExistingPath(source, story, chapter)
    if existing and not force then
        if view then UIManager:close(view) end
        Storage:saveHistory(story, chapter)
        Debug.write("Browser:existing found, calling Reader:show existing=" .. tostring(existing) .. ", from_reader=" .. tostring(from_reader))
        Reader:setPosition(existing, position_text)
        Reader:show(existing, function()
            self:showChapterList(page_data, source, on_return_callback)
            end, on_next_chapter, from_reader, on_prev_chapter)
        return
    end

    runOnline(function()
        local payload, fetch_err = withLoading(
            "Đang lấy " .. chapter.title .. "...",
            function()
                return source:getChapter(chapter)
            end
        )
        if not payload then
            if view then
                showError(fetch_err)
            else
                showError(fetch_err, function()
                    self:showChapterList(page_data, source, on_return_callback)
                end)
            end
            return
        end

        local action = source.kind == "comic" and "Đang tải ảnh và đóng gói CBZ..." or "Đang tạo tệp HTML..."
        local completed, path, build_err = Trapper:dismissableRunInSubprocess(
            function()
                return Builder:build(source, story, chapter, payload, force, true)
            end,
            action
        )

        if not completed then
            os.remove(Storage:getChapterPath(source, story, chapter) .. ".part")
            if view then
                UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Đã hủy tải chương." })
            else
                showError("Đã hủy tải chương.", function()
                    self:showChapterList(page_data, source, on_return_callback)
                end)
            end
            return
        end
        if not path then
            if view then
                showError(build_err)
            else
                showError(build_err, function()
                    self:showChapterList(page_data, source, on_return_callback)
                end)
            end
            return
        end

        if view then UIManager:close(view) end
        Storage:saveHistory(story, chapter)
        Debug.write("Browser:build completed, path=" .. tostring(path) .. ", from_reader=" .. tostring(from_reader))
        Reader:setPosition(path, position_text)
        Reader:show(path, function()
            self:showChapterList(page_data, source, on_return_callback)
        end, on_next_chapter, from_reader, on_prev_chapter)
    end)
end

function Browser:showChapterActions(view, page_data, source, chapter, on_return_callback)
    local story = page_data.story
    -- Chỉ file lẻ mới xóa được; chương trong tệp trọn bộ giữ nguyên.
    local downloaded = Storage:hasChapterFile(source, story, chapter)
    local dialog
    local buttons = {
        {
            {
                text = "Mở chương",
                callback = function()
                    closeAndRun(dialog, function()
                        self:openChapter(
                            view,
                            page_data,
                            source,
                            chapter,
                                    on_return_callback,
                                    false,
                                    from_reader
                                )
                    end)
                end,
            },
        },
        {
            {
                text = "Tải lại chương",
                callback = function()
                    closeAndRun(dialog, function()
                        self:openChapter(
                            view,
                            page_data,
                            source,
                            chapter,
                            on_return_callback,
                            true
                        )
                    end)
                end,
            },
        },
    }
    if downloaded then
        table.insert(buttons, {
            {
                text = "Xóa bản đã tải",
                callback = function()
                    closeAndRun(dialog, function()
                        Storage:removeDownload(source, story, chapter)
                        view:updateItems()
                        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Đã xóa bản tải." })
                    end)
                end,
            },
        })
    end

    dialog = ButtonDialog:new{
        title = chapter.title,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

-- ============================
-- EBOOK SOURCE BROWSING (TVE-4U, Dilib)
-- ============================

function Browser:showLoginDialog(source, on_success, on_cancel)
    local dialog
    local existing = CredentialManager:getCredential(source.id)
    dialog = InputDialog:new{
        title = "Đăng nhập " .. source.name,
        input = existing and existing.username or "",
        input_hint = "Email / Tên đăng nhập",
        buttons = {
            {
                {
                    text = "Quay lại",
                    callback = function()
                        closeAndRun(dialog, on_cancel)
                    end,
                },
                {
                    text = "Đăng nhập",
                    is_enter_default = true,
                    callback = function()
                        local username = dialog:getInputText()
                        if username == "" then return end
                        closeAndRun(dialog, function()
                            self:showPasswordDialog(source, username, on_success, on_cancel)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:showPasswordDialog(source, username, on_success, on_cancel)
    local dialog
    dialog = InputDialog:new{
        title = "Mật khẩu cho " .. username,
        input_hint = "Mật khẩu",
        text_type = "password",
        buttons = {
            {
                {
                    text = "Quay lại",
                    callback = function()
                        closeAndRun(dialog, function()
                            self:showLoginDialog(source, on_success, on_cancel)
                        end)
                    end,
                },
                {
                    text = "Đăng nhập",
                    is_enter_default = true,
                    callback = function()
                        local password = dialog:getInputText()
                        if password == "" then return end
                        closeAndRun(dialog, function()
                            runOnline(function()
                                local result, err = withLoading("Đang đăng nhập...", function()
                                    local ok, login_err = source:login(username, password)
                                    if not ok then
                                        error(login_err or "Đăng nhập thất bại")
                                    end
                                    -- Save credentials on success
                                    CredentialManager:saveCredential(source.id, username, password)
                                    return true
                                end)
                                if result then
                                    UIManager:show(Notification:new{
                                        text = "Đăng nhập thành công!",
                                    })
                                    if on_success then
                                        UIManager:nextTick(on_success)
                                    end
                                else
                                    showError(err, function()
                                        self:showLoginDialog(source, on_success, on_cancel)
                                    end)
                                end
                            end)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:showSourceAccountMenu(source, on_return_callback)
    local view
    local items = {}
    local credential = CredentialManager:getCredential(source.id)
    local logged_in = type(source.isLoggedIn) == "function"
        and source:isLoggedIn()

    if credential then
        table.insert(items, {
            text = "Tài khoản: " .. tostring(credential.username),
            dim = true,
            select_enabled = false,
        })
        table.insert(items, {
            text = logged_in
                and "Trạng thái: Đã đăng nhập"
                or "Trạng thái: Chưa xác minh phiên",
            dim = true,
            select_enabled = false,
        })
        table.insert(items, {
            text = "Đăng nhập lại",
            callback = function()
                source._logged_in = false
                source._cookies = nil
                closeAndRun(view, function()
                    self:showLoginDialog(
                        source,
                        on_return_callback,
                        on_return_callback
                    )
                end)
            end,
        })
        table.insert(items, {
            text = "Xóa tài khoản đã lưu",
            callback = function()
                CredentialManager:removeCredential(source.id)
                source._logged_in = false
                source._cookies = nil
                UIManager:show(Notification:new{
                    text = "Đã xóa tài khoản " .. source.name,
                })
                closeAndRun(view, on_return_callback)
            end,
        })
    else
        table.insert(items, {
            text = "Đăng nhập",
            callback = function()
                closeAndRun(view, function()
                    self:showLoginDialog(
                        source,
                        on_return_callback,
                        on_return_callback
                    )
                end)
            end,
        })
    end

    view = showView(
        source.name .. " · Tài khoản",
        items,
        on_return_callback
    )
end

function Browser:browseEbookSource(source, on_return_callback)
    if source.id == "tve4u" then
        self:browseTve4u(source, on_return_callback)
    elseif source.id == "dilib" then
        self:browseDilib(source, on_return_callback)
    else
        showError("Nguồn ebook không được hỗ trợ.", on_return_callback)
    end
end

-- ============ TVE-4U ============

function Browser:browseTve4u(source, on_return_callback)
    -- Check if login is needed
    if source.requires_auth and not source:isLoggedIn() then
        if CredentialManager:hasCredential(source.id) then
            -- Try auto-login
            runOnline(function()
                local result, err = withLoading("Đang đăng nhập TVE-4U...", function()
                    local ok, login_err = source:ensureLoggedIn()
                    if not ok then error(login_err or "Đăng nhập thất bại") end
                    return true
                end)
                if result then
                    self:showTve4uForumList(source, on_return_callback)
                else
                    showError(err, function()
                        self:showLoginDialog(source, function()
                            self:showTve4uForumList(source, on_return_callback)
                        end, on_return_callback)
                    end)
                end
            end)
        else
            self:showLoginDialog(source, function()
                self:showTve4uForumList(source, on_return_callback)
            end, on_return_callback)
        end
        return
    end

    self:showTve4uForumList(source, on_return_callback)
end

function Browser:showTve4uForumList(source, on_return_callback)
    runOnline(function()
        local forums, err = withLoading("Đang tải danh mục...", function()
            return source:getForumList()
        end)
        if not forums then
            showError(err, on_return_callback)
            return
        end

        local view
        local items = {
            {
                text = "Tìm kiếm trên TVE-4U",
                callback = function()
                    self:showSearchDialog(source, function()
                        self:showTve4uForumList(source, on_return_callback)
                    end, view)
                end,
            },
            {
                text = "Quản lý tài khoản",
                mandatory = CredentialManager:hasCredential(source.id) and "Đã lưu" or "",
                callback = function()
                    closeAndRun(view, function()
                        self:showTve4uAccountMenu(source, function()
                            self:showTve4uForumList(source, on_return_callback)
                        end)
                    end)
                end,
            },
        }

        for _, forum in ipairs(forums) do
            local current_forum = forum
            table.insert(items, {
                text = current_forum.name,
                callback = function()
                    closeAndRun(view, function()
                        self:showTve4uThreadList(source, current_forum, 1, function()
                            self:showTve4uForumList(source, on_return_callback)
                        end)
                    end)
                end,
            })
        end

        if #forums == 0 then
            table.insert(items, {
                text = "Không tìm thấy diễn đàn nào.",
                dim = true,
                select_enabled = false,
            })
        end

        view = showView("TVE-4U · Diễn đàn", items, on_return_callback)
    end)
end

function Browser:showTve4uAccountMenu(source, on_return_callback)
    local view
    local items = {}

    if CredentialManager:hasCredential(source.id) then
        local cred = CredentialManager:getCredential(source.id)
        table.insert(items, {
            text = "Tài khoản: " .. (cred and cred.username or "N/A"),
            dim = true,
            select_enabled = false,
        })
        table.insert(items, {
            text = "Đăng nhập lại",
            callback = function()
                closeAndRun(view, function()
                    source._logged_in = false
                    source._cookies = nil
                    self:showLoginDialog(source, on_return_callback, on_return_callback)
                end)
            end,
        })
        table.insert(items, {
            text = "Xóa tài khoản đã lưu",
            callback = function()
                CredentialManager:removeCredential(source.id)
                source._logged_in = false
                source._cookies = nil
                UIManager:show(InfoMessage:new{
                    title = "Truyện Việt",
                    text = "Đã xóa thông tin tài khoản.",
                })
                closeAndRun(view, on_return_callback)
            end,
        })
    else
        table.insert(items, {
            text = "Đăng nhập",
            callback = function()
                closeAndRun(view, function()
                    self:showLoginDialog(source, on_return_callback, on_return_callback)
                end)
            end,
        })
    end

    view = showView("TVE-4U · Tài khoản", items, on_return_callback)
end

function Browser:showTve4uThreadList(source, forum, page, on_return_callback)
    runOnline(function()
        local result, err = withLoading(
            string.format("Đang tải %s...\nTrang %d", forum.name, page),
            function()
                return source:getThreadList(forum, page)
            end
        )
        if not result then
            showError(err, on_return_callback)
            return
        end

        local view
        local items = {}

        if result.total_pages > 1 then
            table.insert(items, {
                text = string.format("Trang %d / %d", result.page, result.total_pages),
                dim = true,
                select_enabled = false,
            })
        end
        if page > 1 then
            table.insert(items, {
                text = "← Trang trước",
                callback = function()
                    closeAndRun(view, function()
                        self:showTve4uThreadList(source, forum, page - 1, on_return_callback)
                    end)
                end,
            })
        end

        for _, thread in ipairs(result.threads) do
            local current_thread = thread
            table.insert(items, {
                text = current_thread.title,
                callback = function()
                    closeAndRun(view, function()
                        self:showTve4uThreadDetail(source, current_thread, function()
                            self:showTve4uThreadList(source, forum, page, on_return_callback)
                        end)
                    end)
                end,
            })
        end

        if page < result.total_pages then
            table.insert(items, {
                text = "Trang sau →",
                callback = function()
                    closeAndRun(view, function()
                        self:showTve4uThreadList(source, forum, page + 1, on_return_callback)
                    end)
                end,
            })
        end

        if #result.threads == 0 then
            table.insert(items, {
                text = "Không có bài viết nào.",
                dim = true,
                select_enabled = false,
            })
        end

        view = showView(forum.name, items, on_return_callback)
    end)
end

function Browser:showTve4uThreadDetail(source, thread, on_return_callback)
    runOnline(function()
        local detail, err = withLoading("Đang tải chi tiết...", function()
            return source:getThreadDetail(thread)
        end)
        if not detail then
            showError(err, on_return_callback)
            return
        end

        local view
        local items = {}

        -- Read Thread Content
        if detail.posts and #detail.posts > 0 then
            table.insert(items, {
                text = "Đọc nội dung chủ đề",
                callback = function()
                    local text = {}
                    for i, post in ipairs(detail.posts) do
                        table.insert(text, "@ " .. post.author .. " (" .. post.date .. ")")
                        table.insert(text, string.rep("-", 40))
                        local plain = post.content:gsub("<br/?>", "\n"):gsub("</p>", "\n\n")
                        plain = Util.stripTags(plain)
                        table.insert(text, Util.trim(plain))
                        table.insert(text, "\n")
                    end
                    UIManager:show(TextViewer:new{
                        title = thread.title,
                        text = table.concat(text, "\n"),
                    })
                end,
            })
        end

        -- Attachments & Links
        local total_links = (detail.attachments and #detail.attachments or 0) + (detail.external_links and #detail.external_links or 0)
        if total_links > 0 then
            table.insert(items, {
                text = string.format("[Link] Tệp đính kèm & Link tải (%d)", total_links),
                callback = function()
                    local link_items = {}
                    
                    if detail.attachments then
                        for _, att in ipairs(detail.attachments) do
                            local current_att = att
                            local book_stub = { title = thread.title, url = thread.url }
                            local downloaded, existing_path = Storage:isEbookDownloaded(source, book_stub, current_att.filename)
                            table.insert(link_items, {
                                text = "[File] " .. current_att.filename,
                                mandatory = downloaded and "Đã tải" or (current_att.size ~= "" and current_att.size or "Tải về"),
                                callback = function()
                                    if downloaded then
                                        self:openEbookFile(existing_path, function() end)
                                    else
                                        self:downloadTve4uAttachment(source, book_stub, current_att, function() end)
                                    end
                                end,
                            })
                        end
                    end

                    if detail.external_links then
                        for _, lnk in ipairs(detail.external_links) do
                            local domain = lnk.url:match("://([^/]+)") or "Link ngoài"
                            table.insert(link_items, {
                                text = "[Web] " .. domain .. " (" .. lnk.author .. ")",
                                callback = function()
                                    UIManager:show(ConfirmBox:new{
                                        text = "Mở link sau trong thiết bị?\n" .. lnk.url,
                                        ok_text = "Mở",
                                        ok_callback = function()
                                            UIManager:show(TextViewer:new{
                                                title = "Link tải",
                                                text = lnk.url,
                                            })
                                        end,
                                    })
                                end,
                            })
                        end
                    end
                    
                    showView("Tệp đính kèm & Link", link_items, function()
                        -- Return to thread detail
                        self:showTve4uThreadDetail(source, thread, on_return_callback)
                    end)
                end,
            })
        else
            table.insert(items, {
                text = "Không tìm thấy link tải hay đính kèm nào.",
                dim = true,
                select_enabled = false,
            })
        end

        view = showView(thread.title, items, on_return_callback)
    end)
end

function Browser:downloadTve4uAttachment(source, book, attachment, on_complete)
    runOnline(function()
        local save_path = Storage:getEbookPath(source, book, attachment.filename)
        local result, err = withLoading(
            "Đang tải " .. attachment.filename .. "...",
            function()
                return source:downloadAttachment(attachment, save_path)
            end
        )
        if result then
            UIManager:show(ConfirmBox:new{
                title = "Truyện Việt",
                text = "Đã tải xong: " .. attachment.filename .. "\nMở file ngay?",
                ok_text = "Mở",
                ok_callback = function()
                    self:openEbookFile(save_path, on_complete)
                end,
                cancel_text = "Đóng",
                cancel_callback = on_complete,
            })
        else
            showError("Lỗi tải file: " .. tostring(err))
        end
    end)
end

-- ============ DILIB ============

function Browser:browseDilib(source, on_return_callback)
    local categories = source:getCategories()
    local view
    local items = {
        {
            text = "Tìm kiếm trên Dilib",
            callback = function()
                self:showDilibSearchDialog(source, function()
                    self:browseDilib(source, on_return_callback)
                end, view)
            end,
        },
    }

    for _, cat in ipairs(categories) do
        local current_cat = cat
        table.insert(items, {
            text = current_cat.name,
            callback = function()
                closeAndRun(view, function()
                    self:showDilibBookList(source, current_cat, 1, function()
                        self:browseDilib(source, on_return_callback)
                    end)
                end)
            end,
        })
    end

    view = showView("Dilib · Thư Viện Số", items, on_return_callback)
end

function Browser:showDilibSearchDialog(source, on_return_callback, parent_view)
    local dialog
    dialog = InputDialog:new{
        title = "Tìm sách trên Dilib",
        input_hint = "Tên sách hoặc tác giả",
        buttons = {
            {
                {
                    text = "Quay lại",
                    callback = function()
                        closeAndRun(dialog, function()
                            if not parent_view and on_return_callback then
                                on_return_callback()
                            end
                        end)
                    end,
                },
                {
                    text = "Tìm",
                    is_enter_default = true,
                    callback = function()
                        local query = dialog:getInputText()
                        if query == "" then return end
                        closeAndRun(dialog, function()
                            self:searchDilib(source, query, on_return_callback, parent_view)
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:searchDilib(source, query, on_return_callback, parent_view)
    runOnline(function()
        local results, err = withLoading(
            'Đang tìm "' .. query .. '"...',
            function()
                return source:search(query)
            end
        )
        if not results then
            showError(err, function()
                self:showDilibSearchDialog(source, on_return_callback, parent_view)
            end)
            return
        end
        if #results == 0 then
            showError("Không tìm thấy sách phù hợp.", function()
                self:showDilibSearchDialog(source, on_return_callback, parent_view)
            end)
            return
        end

        if parent_view and type(parent_view.onClose) == "function" then
            UIManager:close(parent_view)
        end

        local view
        local items = {}
        for _, book in ipairs(results) do
            local current_book = book
            table.insert(items, {
                text = current_book.title,
                mandatory = Util.shorten(current_book.author, 24),
                callback = function()
                    closeAndRun(view, function()
                        self:showDilibBookDetail(source, current_book, function()
                            self:searchDilib(source, query, on_return_callback, nil)
                        end)
                    end)
                end,
            })
        end

        view = showView(
            string.format("Dilib: %s (%d)", query, #results),
            items,
            on_return_callback
        )
    end)
end

function Browser:showDilibBookList(source, category, page, on_return_callback)
    runOnline(function()
        local result, err = withLoading(
            string.format("Đang tải %s...\nTrang %d", category.name, page),
            function()
                return source:getCategoryBooks(category, page)
            end
        )
        if not result then
            showError(err, on_return_callback)
            return
        end

        local view
        local items = {}

        if result.total_pages > 1 then
            table.insert(items, {
                text = string.format("Trang %d / %d", result.page, result.total_pages),
                dim = true,
                select_enabled = false,
            })
        end
        if page > 1 then
            table.insert(items, {
                text = "← Trang trước",
                callback = function()
                    closeAndRun(view, function()
                        self:showDilibBookList(source, category, page - 1, on_return_callback)
                    end)
                end,
            })
        end

        for _, book in ipairs(result.books) do
            local current_book = book
            table.insert(items, {
                text = current_book.title,
                callback = function()
                    closeAndRun(view, function()
                        self:showDilibBookDetail(source, current_book, function()
                            self:showDilibBookList(source, category, page, on_return_callback)
                        end)
                    end)
                end,
            })
        end

        if page < result.total_pages then
            table.insert(items, {
                text = "Trang sau →",
                callback = function()
                    closeAndRun(view, function()
                        self:showDilibBookList(source, category, page + 1, on_return_callback)
                    end)
                end,
            })
        end

        if #result.books == 0 then
            table.insert(items, {
                text = "Không có sách nào.",
                dim = true,
                select_enabled = false,
            })
        end

        view = showView(category.name, items, on_return_callback)
    end)
end

function Browser:showDilibBookDetail(source, book, on_return_callback)
    local Util = require("truyenviet/helpers")
    runOnline(function()
        local detail, err = withLoading("Đang tải chi tiết sách...", function()
            return source:getBookDetail(book)
        end)
        if not detail then
            showError(err, on_return_callback)
            return
        end

        local view
        local items = {}

        -- Book info
        local info_lines = { source.name }
        if detail.author then
            table.insert(info_lines, "Tác giả: " .. detail.author)
        end
        if detail.narrator then
            table.insert(info_lines, "Giọng đọc: " .. detail.narrator)
        end
        if detail.format then
            table.insert(info_lines, "Định dạng: " .. detail.format)
        end
        if detail.pages then
            table.insert(info_lines, "Số trang: " .. detail.pages)
        end
        if detail.size then
            table.insert(info_lines, "Kích thước: " .. detail.size)
        end
        if #detail.genres > 0 then
            table.insert(info_lines, "Thể loại: " .. table.concat(detail.genres, ", "))
        end
        if detail.description and detail.description ~= "" then
            table.insert(info_lines, "")
            table.insert(info_lines, detail.description)
        end

        table.insert(items, {
            text = "Xem thông tin sách",
            callback = function()
                UIManager:show(TextViewer:new{
                    title = detail.title,
                    text = table.concat(info_lines, "\n"),
                })
            end,
        })

        -- PDF Download
        if detail.has_pdf then
            local book_stub = { title = detail.title, url = book.url }
            local pdf_name = Util.safeName(detail.title, "book") .. ".pdf"
            local downloaded, existing_path = Storage:isEbookDownloaded(source, book_stub, pdf_name)
            table.insert(items, {
                text = downloaded and "Mở sách PDF" or "Tải sách PDF",
                mandatory = downloaded and "Đã tải" or (detail.size or ""),
                callback = function()
                    if downloaded then
                        self:openEbookFile(existing_path, function()
                            closeAndRun(view, function()
                                self:showDilibBookDetail(source, book, on_return_callback)
                            end)
                        end)
                    else
                        closeAndRun(view, function()
                            self:downloadDilibPdf(source, book, detail, function()
                                self:showDilibBookDetail(source, book, on_return_callback)
                            end)
                        end)
                    end
                end,
            })
        end

        -- Audio Download
        if detail.has_audio then
            local book_stub = { title = detail.title, url = book.url }
            local audio_name = Util.safeName(detail.title, "audio") .. ".mp3"
            local downloaded, existing_path = Storage:isEbookDownloaded(source, book_stub, audio_name)

            table.insert(items, {
                text = downloaded and "Sách nói đã tải" or "Tải sách nói MP3",
                mandatory = downloaded and "Đã tải" or (detail.audio_size or ""),
                callback = function()
                    if downloaded then
                        UIManager:show(InfoMessage:new{
                            title = "Truyện Việt",
                            text = "File audio đã được lưu tại:\n" .. existing_path .. "\n\nVui lòng dùng ứng dụng phát nhạc để nghe.",
                        })
                    else
                        closeAndRun(view, function()
                            self:downloadDilibAudio(source, book, detail, function()
                                self:showDilibBookDetail(source, book, on_return_callback)
                            end)
                        end)
                    end
                end,
            })
        end

        -- Audio chapters info
        if detail.audio_chapters and #detail.audio_chapters > 0 then
            table.insert(items, {
                text = "Xem mục lục audio (" .. #detail.audio_chapters .. " phần)",
                callback = function()
                    local toc_lines = {}
                    for _, ch in ipairs(detail.audio_chapters) do
                        local minutes = math.floor(ch.start_time / 60)
                        local seconds = math.floor(ch.start_time % 60)
                        local name = ch.name or ("Phần " .. (ch.index + 1))
                        table.insert(toc_lines, string.format(
                            "%s  [%d:%02d]", name, minutes, seconds
                        ))
                    end
                    UIManager:show(TextViewer:new{
                        title = detail.title .. " · Mục lục",
                        text = table.concat(toc_lines, "\n"),
                    })
                end,
            })
        end

        -- Build info HTML page
        table.insert(items, {
            text = "Tạo trang thông tin (đọc offline)",
            callback = function()
                local book_stub = { title = detail.title, url = book.url }
                local info_name = Util.safeName(detail.title, "info") .. ".html"
                local save_path = Storage:getEbookPath(source, book_stub, info_name)
                local result, build_err = source:buildInfoPage(detail, save_path)
                if result then
                    self:openEbookFile(save_path, function()
                        closeAndRun(view, function()
                            self:showDilibBookDetail(source, book, on_return_callback)
                        end)
                    end)
                else
                    showError("Lỗi tạo trang: " .. tostring(build_err))
                end
            end,
        })

        view = showView(detail.title, items, on_return_callback)
    end)
end

function Browser:downloadDilibPdf(source, book, detail, on_complete)
    runOnline(function()
        local book_stub = { title = detail.title, url = book.url }
        local pdf_name = Util.safeName(detail.title, "book") .. ".pdf"
        local save_path = Storage:getEbookPath(source, book_stub, pdf_name)

        local result, run_err = withLoading("Đang tải PDF " .. detail.title .. "...", function()
            return source:downloadPdf(detail, save_path)
        end)

        if result then
            UIManager:show(ConfirmBox:new{
                title = "Truyện Việt",
                text = "Đã tải xong: " .. pdf_name .. "\nMở sách ngay?",
                ok_text = "Mở",
                ok_callback = function()
                    self:openEbookFile(save_path, on_complete)
                end,
                cancel_text = "Đóng",
                cancel_callback = on_complete,
            })
        else
            os.remove(save_path .. ".part")
            showError("Lỗi tải PDF: " .. tostring(run_err), on_complete)
        end
    end)
end

function Browser:downloadDilibAudio(source, book, detail, on_complete)
    runOnline(function()
        local book_stub = { title = detail.title, url = book.url }
        local audio_name = Util.safeName(detail.title, "audio") .. ".mp3"
        local save_path = Storage:getEbookPath(source, book_stub, audio_name)

        local result, run_err = withLoading("Đang tải sách nói " .. detail.title .. "...\n" .. (detail.audio_size or ""), function()
            return source:downloadAudio(detail, save_path)
        end)

        if result then
            -- Also build info page
            local info_name = Util.safeName(detail.title, "info") .. ".html"
            local info_path = Storage:getEbookPath(source, book_stub, info_name)
            source:buildInfoPage(detail, info_path)

            UIManager:show(ConfirmBox:new{
                title = "Truyện Việt",
                text = "Đã tải sách nói: " .. audio_name .. "\n\nFile đã lưu tại:\n" .. save_path .. "\n\nVui lòng dùng ứng dụng phát nhạc để nghe.",
                ok_text = "Đóng",
            })
            if on_complete then UIManager:nextTick(on_complete) end
        else
            os.remove(save_path .. ".part")
            showError("Lỗi tải audio: " .. tostring(run_err), on_complete)
        end
    end)
end

-- ============ SHARED EBOOK UTILS ============

function Browser:openEbookFile(file_path, on_return_callback)
    local ext = file_path:match("%.([^%.]+)$")
    if ext then ext = ext:lower() end

    -- Check if KOReader can open this format
    local supported = {
        html = true, epub = true, pdf = true, mobi = true,
        txt = true, fb2 = true, cbz = true, cbr = true,
        azw3 = true, azw = true, prc = true, djvu = true,
    }
    if ext and supported[ext] then
        local FileManager = require("apps/filemanager/filemanager")
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
        ReaderUI:showReader(file_path)
    elseif ext == "rar" or ext == "zip" or ext == "7z" then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "File nén (" .. ext:upper() .. ") cần được giải nén trước khi đọc.\n\nĐường dẫn file:\n" .. file_path,
        })
    elseif ext == "mp3" or ext == "m4a" or ext == "ogg" then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "File audio (" .. ext:upper() .. ") không thể phát trên máy đọc sách.\n\nĐường dẫn file:\n" .. file_path,
        })
    else
        -- Try opening anyway
        local ReaderUI = require("apps/reader/readerui")
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
        local ok = pcall(ReaderUI.showReader, ReaderUI, file_path)
        if not ok then
            UIManager:show(InfoMessage:new{
                title = "Truyện Việt",
                text = "Không thể mở file này.\n\nĐường dẫn:\n" .. file_path,
            })
        end
    end
end

function Browser:triggerPrefetchAndPurge(source, story, page_data, current_chapter)
    if not source or not story or not page_data or not page_data.chapters or not current_chapter then
        return
    end

    local curr_idx = nil
    for i, c in ipairs(page_data.chapters) do
        if c.url == current_chapter.url or (c.is_local and current_chapter.is_local and c.title == current_chapter.title) then
            curr_idx = i
            break
        end
    end

    if not curr_idx then return end

    -- Danh sách có thể đang hiện "Mới nhất trước": tính hướng đi tới chương mới hơn
    -- để không xóa nhầm chương mới và tải trước nhầm chương cũ
    local sort_mode = page_data.chapter_sort or ChapterOrder.defaultMode(source)
    local newer_step = sort_mode == "desc" and -1 or 1

    -- 1. Auto Purging (Xóa cuốn chiếu A - Purge Distance)
    if Storage:isAutoPurgeEnabled() then
        local purge_dist = math.max(1, tonumber(Storage:getPurgeDistance()) or 1)
        local p = curr_idx - newer_step * purge_dist
        while p >= 1 and p <= #page_data.chapters do
            local old_chap = page_data.chapters[p]
            if old_chap and Storage:hasChapterFile(source, story, old_chap) then
                Storage:removeDownload(source, story, old_chap)
                Debug.write("[AutoPurge] Removed old chapter: " .. tostring(old_chap.title))
            end
            p = p - newer_step
        end
    end

    -- 2. Rolling Prefetching (Tải ngầm A + 1, A + 2, A + 3)
    -- Truyện tranh (hoặc nguồn không có getChapterAsync) tải cả chương một mạch trên UI loop,
    -- chặn thao tác lật trang hàng chục giây khiến Android báo ANR và đóng KOReader
    local can_prefetch_async = source.kind ~= "comic" and type(source.getChapterAsync) == "function"
    if Storage:isPrefetchEnabled() and not can_prefetch_async then
        Debug.write("[RollingPrefetch] Skipped: source downloads synchronously")
    end
    if Storage:isPrefetchEnabled() and can_prefetch_async then
        local prefetch_count = Storage:getPrefetchCount()
        local prefetch_chaps = {}
        for p = 1, prefetch_count do
            local next_c = page_data.chapters[curr_idx + newer_step * p]
            if next_c and not Storage:isDownloaded(source, story, next_c) then
                table.insert(prefetch_chaps, next_c)
            end
        end

        if #prefetch_chaps > 0 then
            UIManager:scheduleIn(1.5, function()
                local ChapterDownloader = require("truyenviet/chapter_downloader")
                Debug.write("[RollingPrefetch] Starting prefetch for " .. #prefetch_chaps .. " chapters")
                local routine = coroutine.create(function()
                    ChapterDownloader:download(source, story, prefetch_chaps)
                end)
                local function step()
                    if coroutine.status(routine) ~= "dead" then
                        local ok, err = coroutine.resume(routine)
                        if ok then
                            UIManager:scheduleIn(0.2, step)
                        end
                    end
                end
                step()
            end)
        end
    end
end

function Browser:executeImport(url, mode, on_return)
    local DirectImporter = require("truyenviet/direct_importer")
    withLoading("Đang phân tích & sinh nguồn từ URL...", function()
        DirectImporter:importFromUrl(url, mode, function(schema, err)
            if schema then
                UIManager:show(InfoMessage:new{
                    title = "Thành công",
                    text = string.format("Đã sinh thành công Nguồn mới: %s\nPhương pháp cào: %s\nFile quy tắc: custom_sources/%s.json", schema.name, schema.matched_template or "Local Engine", schema.id),
                })
                if on_return then on_return() end
            else
                showError("Thất bại: " .. tostring(err), on_return)
            end
        end)
    end)
end

function Browser:showGDriveDownloadDialog(on_return)
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")
    local GDriveDownloader = require("truyenviet/gdrive_downloader")

    local dialog
    dialog = InputDialog:new{
        title = "Tải Ebook từ Google Drive",
        description = "Nhập liên kết công khai hoặc File ID Google Drive:\n(Hỗ trợ EPUB, CBZ, CBR, MOBI, PDF, AZW3, TXT...)",
        input = "",
        buttons = {
            {
                {
                    text = "Hủy",
                    callback = function()
                        UIManager:close(dialog)
                        if on_return then on_return() end
                    end,
                },
                {
                    text = "Tải về",
                    is_default = true,
                    callback = function()
                        local input_text = dialog:getInputText()
                        UIManager:close(dialog)
                        if not input_text or Util.trim(input_text) == "" then
                            showError("Vui lòng nhập liên kết hoặc File ID Google Drive!", on_return)
                            return
                        end

                        local file_id = GDriveDownloader:extractFileId(input_text)
                        if not file_id then
                            showError("Không nhận diện được File ID Google Drive hợp lệ từ liên kết!", on_return)
                            return
                        end

                        runOnline(function()
                            local saved_path, err_msg
                            withLoading("Đang kết nối & tải file từ Google Drive...\n(Quá trình có thể mất một vài giây)", function()
                                saved_path, err_msg = GDriveDownloader:download(file_id)
                            end)

                            if saved_path then
                                local filename = saved_path:match("([^/\\]+)$") or saved_path
                                local success_dialog
                                success_dialog = ButtonDialog:new{
                                    title = "Tải thành công! ☁",
                                    description = "Đã tải file thành công về máy:\n" .. filename .. "\n\nĐường dẫn:\n" .. saved_path,
                                    buttons = {
                                        {
                                            {
                                                text = "▶ Mở đọc ngay",
                                                is_default = true,
                                                callback = function()
                                                    UIManager:close(success_dialog)
                                                    self:openEbookFile(saved_path, on_return)
                                                end,
                                            },
                                            {
                                                text = "Xong",
                                                callback = function()
                                                    UIManager:close(success_dialog)
                                                    if on_return then on_return() end
                                                end,
                                            },
                                        },
                                    },
                                }
                                UIManager:show(success_dialog)
                            else
                                showError("Lỗi tải từ Google Drive:\n" .. tostring(err_msg or "Không rõ nguyên nhân"), on_return)
                            end
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    if dialog.onShowKeyboard then
        dialog:onShowKeyboard()
    end
end

function Browser:showDirectImporterDialog(on_return)
    local InputDialog = require("ui/widget/inputdialog")
    local ButtonDialog = require("ui/widget/buttondialog")

    local dialog
    dialog = InputDialog:new{
        title = "Tạo nguồn truyện từ URL Web",
        description = "Nhập tên miền hoặc URL trang web truyện (vd: mtruyen.net):",
        input = "",
        buttons = {
            {
                {
                    text = "Hủy",
                    callback = function()
                        UIManager:close(dialog)
                        if on_return then on_return() end
                    end,
                },
                {
                    text = "Cào & Sinh Nguồn",
                    is_default = true,
                    callback = function()
                        local url = dialog:getInputText()
                        UIManager:close(dialog)
                        if not url or url == "" then
                            showError("Vui lòng nhập đường dẫn URL!", on_return)
                            return
                        end

                        url = Util.trim(url)
                        if not url:find("^https?://") then
                            url = "https://" .. url
                        end

                        local choice_dialog
                        choice_dialog = ButtonDialog:new{
                            title = "Chọn Phương Pháp Cào Trang Web",
                            description = "Vui lòng chọn phương thức bóc tách dữ liệu cho URL:\n" .. url,
                            buttons = {
                                {
                                    {
                                        text = "⚙ Tự động (Local Heuristic -> Firecrawl Fallback)",
                                        is_default = true,
                                        callback = function()
                                            UIManager:close(choice_dialog)
                                            self:executeImport(url, "auto", on_return)
                                        end,
                                    },
                                },
                                {
                                    {
                                        text = "⚡ Ép dùng Firecrawl Cloud API (Web JS/Cloudflare)",
                                        callback = function()
                                            UIManager:close(choice_dialog)
                                            self:executeImport(url, "firecrawl", on_return)
                                        end,
                                    },
                                },
                                {
                                    {
                                        text = "⚡ Chỉ dùng Local Engine (Bóc tách HTML offline)",
                                        callback = function()
                                            UIManager:close(choice_dialog)
                                            self:executeImport(url, "local", on_return)
                                        end,
                                    },
                                },
                            }
                        }
                        UIManager:show(choice_dialog)
                    end,
                },
            }
        }
    }
    UIManager:show(dialog)
end

function Browser:showFirecrawlKeyDialog(on_return)
    local CredentialManager = require("truyenviet/credential_manager")
    local InputDialog = require("ui/widget/inputdialog")
    local masked_key = CredentialManager:getMaskedFirecrawlKey()

    local dialog
    dialog = InputDialog:new{
        title = "Firecrawl.dev API Key",
        description = "Nhập API Key Firecrawl để vượt rào cản Cloudflare / JS động khi cào nguồn web phức tạp:\nHiện tại: [" .. masked_key .. "]",
        input = "",
        buttons = {
            {
                {
                    text = "Khôi phục Mặc định",
                    callback = function()
                        CredentialManager:saveFirecrawlKey(nil)
                        UIManager:close(dialog)
                        UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã khôi phục API Key hệ thống mặc định." })
                        if on_return then on_return() end
                    end,
                },
                {
                    text = "Hủy",
                    callback = function()
                        UIManager:close(dialog)
                        if on_return then on_return() end
                    end,
                },
                {
                    text = "Lưu API Key Tùy chỉnh",
                    is_default = true,
                    callback = function()
                        local key = dialog:getInputText()
                        if key and key ~= "" then
                            CredentialManager:saveFirecrawlKey(key)
                            UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã lưu API Key Firecrawl tùy chỉnh thành công." })
                        end
                        UIManager:close(dialog)
                        if on_return then on_return() end
                    end,
                },
            }
        }
    }
    UIManager:show(dialog)
end

function Browser:showMergeOptionsDialog(item, on_return)
    local Storage = require("truyenviet/storage")
    local source = { id = item.source_id }
    local story = { title = item.story_slug, url = item.story_slug }
    
    local default_name = (item.story_slug or "truyen"):gsub("[^%w_]", "_") .. "_gop"
    local options = {
        format = "epub",              -- "epub" or "html"
        include_cover = true,         -- boolean
        include_toc = true,           -- boolean
        output_filename = default_name,
        delete_source_files = false,  -- boolean
    }

    local function refreshMenu()
        local items = {
            {
                text = "1. Định dạng file: [ " .. options.format:upper() .. " (." .. options.format .. ") ]",
                callback = function()
                    options.format = (options.format == "epub") and "html" or "epub"
                    refreshMenu()
                end,
            },
            {
                text = "2. Bao gồm Ảnh bìa: [ " .. (options.include_cover and "☑ BẬT" or "☐ TẮT") .. " ]",
                callback = function()
                    options.include_cover = not options.include_cover
                    refreshMenu()
                end,
            },
            {
                text = "3. Tạo Mục lục (Links nhảy): [ " .. (options.include_toc and "☑ BẬT" or "☐ TẮT") .. " ]",
                callback = function()
                    options.include_toc = not options.include_toc
                    refreshMenu()
                end,
            },
            {
                text = "4. Tên file xuất ra: [ " .. options.output_filename .. "." .. options.format .. " ]",
                callback = function()
                    local InputDialog = require("ui/widget/inputdialog")
                    local dlg
                    dlg = InputDialog:new{
                        title = "Nhập tên file xuất ra",
                        description = "Tên file (không cần nhập đuôi file):",
                        input = options.output_filename,
                        buttons = {
                            {
                                { text = "Hủy", callback = function() UIManager:close(dlg) end },
                                {
                                    text = "Đồng ý",
                                    is_default = true,
                                    callback = function()
                                        local val = dlg:getInputText():match("^%s*(.-)%s*$")
                                        if val and val ~= "" then
                                            options.output_filename = val
                                        end
                                        UIManager:close(dlg)
                                        refreshMenu()
                                    end,
                                },
                            }
                        }
                    }
                    UIManager:show(dlg)
                end,
            },
            {
                text = "5. Xóa các file chương gốc sau khi gộp: [ " .. (options.delete_source_files and "☑ BẬT" or "☐ TẮT") .. " ]",
                callback = function()
                    options.delete_source_files = not options.delete_source_files
                    refreshMenu()
                end,
            },
            {
                text = "⚡ BẮT ĐẦU GỘP FILE",
                mandatory = "Thực hiện",
                callback = function()
                    local Trapper = require("ui/trapper")
                    local completed, out_path, err, chapters = Trapper:dismissableRunInSubprocess(
                        function()
                            return Storage:mergeChapters(source, story, options)
                        end,
                        "Đang xử lý & gộp file (" .. options.format:upper() .. ")..."
                    )

                    if not completed then
                        UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã hủy thao tác gộp file." })
                        return
                    end

                    if out_path then
                        local msg = string.format("Đã gộp thành công %d chương (%s)!\n\nLưu tại:\n%s", #(chapters or {}), options.format:upper(), tostring(out_path))
                        if options.delete_source_files then
                            msg = msg .. "\n\n(Đã tự động xóa các file chương gốc)"
                        end
                        UIManager:show(InfoMessage:new{
                            title = "Truyện Việt - Thành công",
                            text = msg,
                        })
                        if on_return then on_return() end
                    else
                        showError("Lỗi gộp file: " .. tostring(err))
                    end
                end,
            },
        }

        local view = ListView:new{
            title = "⚙ Cấu Hình Gộp File: " .. item.story_slug,
            item_table = items,
            on_return_callback = on_return,
        }
        UIManager:show(view)
    end

    refreshMenu()
end

function Browser:showDownloadedStoryChapters(item, on_return)
    local Storage = require("truyenviet/storage")
    local source = { id = item.source_id }
    local story = { title = item.story_slug, url = item.story_slug }
    local chapters = Storage:listDownloadedChapters(source, story)

    if #chapters == 0 then
        UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Không còn file chương nào." })
        if on_return then on_return() end
        return
    end

    local items = {}
    for i, chap in ipairs(chapters) do
        local current_chap = chap
        local size_kb = string.format("%.1f KB", (chap.size or 0) / 1024)
        table.insert(items, {
            text = string.format("[%d] %s (%s)", i, chap.filename, size_kb),
            callback = function()
                local ButtonDialog = require("ui/widget/buttondialog")
                local dlg
                dlg = ButtonDialog:new{
                    title = chap.filename,
                    text = "Dung lượng: " .. size_kb,
                    buttons = {
                        {
                            {
                                text = "▶ Đọc chương này",
                                callback = function()
                                    UIManager:close(dlg)
                                    Reader:show(current_chap.path, function()
                                        self:showDownloadedStoryChapters(item, on_return)
                                    end)
                                end,
                            },
                            {
                                text = "✕ Xóa chương này",
                                callback = function()
                                    UIManager:close(dlg)
                                    os.remove(current_chap.path)
                                    UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã xóa " .. current_chap.filename })
                                    self:showDownloadedStoryChapters(item, on_return)
                                end,
                            },
                        }
                    }
                }
                UIManager:show(dlg)
            end,
        })
    end

    local view = ListView:new{
        title = "☰ Danh Sách Chương (" .. #chapters .. " chương)",
        item_table = items,
        on_return_callback = on_return,
    }
    UIManager:show(view)
end

function Browser:showDownloadedManager(on_return)
    Storage:initialize()
    local stories = Storage:listDownloadedStories()

    if #stories == 0 then
        UIManager:show(InfoMessage:new{
            title = "Truyện Việt",
            text = "Chưa có file truyện nào được tải về máy.",
        })
        if on_return then on_return() end
        return
    end

    local items = {}
    for _, item in ipairs(stories) do
        local cur_item = item
        local size_mb = string.format("%.2f MB", (cur_item.total_bytes or 0) / (1024 * 1024))
        table.insert(items, {
            text = string.format("[%s] %s (%d chương - %s)", cur_item.source_id, cur_item.story_slug, cur_item.chapter_count, size_mb),
            callback = function()
                local story_menu_items = {
                    {
                        text = "⚙ Gộp file (Tùy chọn EPUB/HTML, Bìa, Mục lục, Tên file...)",
                        callback = function()
                            self:showMergeOptionsDialog(cur_item, function()
                                self:showDownloadedManager(on_return)
                            end)
                        end,
                    },
                    {
                        text = "☰ Xem & Xóa từng chương lẻ (" .. cur_item.chapter_count .. " chương)",
                        callback = function()
                            self:showDownloadedStoryChapters(cur_item, function()
                                self:showDownloadedManager(on_return)
                            end)
                        end,
                    },
                    {
                        text = "✕ Xóa tất cả chương của truyện này",
                        callback = function()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:show(ConfirmBox:new{
                                text = "Xóa tất cả chương đã tải của " .. cur_item.story_slug .. "?",
                                ok_text = "Xóa",
                                cancel_text = "Hủy",
                                ok_callback = function()
                                    local lfs = require("libs/libkoreader-lfs")
                                    for f in lfs.dir(cur_item.dir_path) do
                                        if f ~= "." and f ~= ".." then
                                            os.remove(cur_item.dir_path .. "/" .. f)
                                        end
                                    end
                                    lfs.rmdir(cur_item.dir_path)
                                    UIManager:show(InfoMessage:new{ title = "Truyện Việt", text = "Đã xóa xong." })
                                    self:showDownloadedManager(on_return)
                                end,
                            })
                        end,
                    },
                }

                local story_view = ListView:new{
                    title = "Truyện: " .. cur_item.story_slug .. " (" .. cur_item.chapter_count .. " chương)",
                    item_table = story_menu_items,
                    on_return_callback = function()
                        self:showDownloadedManager(on_return)
                    end,
                }
                UIManager:show(story_view)
            end,
        })
    end

    local view = ListView:new{
        title = "Quản lý File Đã Tải (" .. #stories .. " truyện)",
        item_table = items,
        on_return_callback = on_return,
    }
    UIManager:show(view)
end



function Browser:showAdvancedSettings(on_return)
    Storage:initialize()
    local items = {}

    local prefetch_status = Storage:isPrefetchEnabled() and "ĐANG BẬT" or "ĐÃ TẮT"
    table.insert(items, {
        text = "Tự động tải ngầm chương trước (Prefetch): [" .. prefetch_status .. "]",
        callback = function()
            Storage:setPrefetchEnabled(not Storage:isPrefetchEnabled())
            self:showAdvancedSettings(on_return)
        end,
    })

    table.insert(items, {
        text = "Số chương tải trước ngầm: [" .. Storage:getPrefetchCount() .. " chương]",
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title = "Số chương tải ngầm",
                description = "Nhập số chương muốn tự động tải ngầm (mặc định: 3):",
                input = tostring(Storage:getPrefetchCount()),
                buttons = {
                    {
                        { text = "Hủy", callback = function() UIManager:close(dlg) end },
                        {
                            text = "Lưu",
                            is_default = true,
                            callback = function()
                                local num = tonumber(dlg:getInputText()) or 3
                                Storage:setPrefetchCount(num)
                                UIManager:close(dlg)
                                self:showAdvancedSettings(on_return)
                            end,
                        },
                    }
                }
            }
            UIManager:show(dlg)
        end,
    })

    local purge_status = Storage:isAutoPurgeEnabled() and "ĐANG BẬT" or "ĐÃ TẮT"
    table.insert(items, {
        text = "Tự động xóa chương cũ (Auto-Purge): [" .. purge_status .. "]",
        callback = function()
            Storage:setAutoPurgeEnabled(not Storage:isAutoPurgeEnabled())
            self:showAdvancedSettings(on_return)
        end,
    })

    table.insert(items, {
        text = "Khoảng cách xóa chương cũ (Purge Distance): [" .. Storage:getPurgeDistance() .. " chương]",
        callback = function()
            local InputDialog = require("ui/widget/inputdialog")
            local dlg
            dlg = InputDialog:new{
                title = "Khoảng cách xóa chương cũ",
                description = "Ví dụ nhập 5: Đọc chương A sẽ tự xóa chương A-5 (mặc định: 5):",
                input = tostring(Storage:getPurgeDistance()),
                buttons = {
                    {
                        { text = "Hủy", callback = function() UIManager:close(dlg) end },
                        {
                            text = "Lưu",
                            is_default = true,
                            callback = function()
                                local num = tonumber(dlg:getInputText()) or 5
                                Storage:setPurgeDistance(num)
                                UIManager:close(dlg)
                                self:showAdvancedSettings(on_return)
                            end,
                        },
                    }
                }
            }
            UIManager:show(dlg)
        end,
    })

    local CredentialManager = require("truyenviet/credential_manager")
    local fc_key = CredentialManager:getFirecrawlKey()
    local fc_status = (fc_key and fc_key ~= "") and "ĐÃ LƯU" or "CHƯA CÀI"
    table.insert(items, {
        text = "Cấu hình Firecrawl API Key: [" .. fc_status .. "]",
        callback = function()
            self:showFirecrawlKeyDialog(function()
                self:showAdvancedSettings(on_return)
            end)
        end,
    })

    -- Cài đặt OTA Updates
    local ota_status = Storage:isAutoUpdateCheckEnabled() and "ĐANG BẬT" or "ĐÃ TẮT"
    table.insert(items, {
        text = "Tự động kiểm tra cập nhật OTA: [" .. ota_status .. "]",
        callback = function()
            Storage:setAutoUpdateCheckEnabled(not Storage:isAutoUpdateCheckEnabled())
            self:showAdvancedSettings(on_return)
        end,
    })

    local freq = Storage:getUpdateCheckFrequency()
    local freq_text = (freq == 0 and "Mỗi khi khởi động")
        or (freq <= 86400 and "Mỗi 24 giờ")
        or "Mỗi 7 ngày"
    table.insert(items, {
        text = "Tần suất tự động kiểm tra OTA: [" .. freq_text .. "]",
        callback = function()
            local next_freq = (freq == 86400 and 604800) or (freq == 604800 and 0) or 86400
            Storage:setUpdateCheckFrequency(next_freq)
            self:showAdvancedSettings(on_return)
        end,
    })

    local ignored = Storage:getIgnoredUpdateVersion()
    if ignored and ignored ~= "" then
        table.insert(items, {
            text = "Xóa phiên bản bỏ qua: [" .. ignored .. "]",
            callback = function()
                Storage:setIgnoredUpdateVersion("")
                UIManager:show(InfoMessage:new{
                    title = "Truyện Việt",
                    text = "Đã xóa phiên bản bị bỏ qua.",
                })
                self:showAdvancedSettings(on_return)
            end,
        })
    end

    local view = ListView:new{
        title = "Cài đặt Nâng cao & Tải ngầm",
        item_table = items,
        on_return_callback = on_return,
    }
    UIManager:show(view)
end

return Browser
