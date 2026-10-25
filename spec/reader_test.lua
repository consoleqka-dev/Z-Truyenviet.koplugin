local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["ui/event"] = function()
    return {
        new = function(_, name, ...)
            return { name = name, args = { ... } }
        end,
    }
end

local close_count = 0
local show_files_count = 0
local broadcast_count = 0
local show_reader_path
local switched_path

local ReaderUI = {
    instance = nil,
}
function ReaderUI:showReader(path)
    show_reader_path = path
end
package.preload["apps/reader/readerui"] = function()
    return ReaderUI
end

local FileManager = {
    showFiles = function()
        show_files_count = show_files_count + 1
    end,
}
package.preload["apps/filemanager/filemanager"] = function()
    return FileManager
end

package.preload["ui/widget/infomessage"] = function()
    return {
        new = function(_, def)
            return def
        end,
    }
end

-- Set to a table to queue scheduled callbacks like the real UIManager does.
local queue
local function schedule(callback)
    if queue then
        table.insert(queue, callback)
    else
        callback()
    end
end
local function drain()
    while queue and #queue > 0 do
        table.remove(queue, 1)()
    end
end

package.preload["ui/uimanager"] = function()
    return {
        broadcastEvent = function()
            broadcast_count = broadcast_count + 1
        end,
        nextTick = function(_, callback)
            schedule(callback)
        end,
        scheduleIn = function(_, _, callback)
            schedule(callback)
        end,
        show = function() end,
        close = function() end,
    }
end

package.preload["logger"] = function()
    return {
        dbg = function() end,
        info = function() end,
        warn = function() end,
        err = function() end,
    }
end

package.preload["truyenviet/debugger"] = function()
    return {
        write = function() end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return {
        new = function(_, definition)
            return definition
        end,
    }
end

local download_root = "/storage/emulated/0/koreader/truyenviet"
-- Keyed by <source>/<story>: on Android /sdcard and /storage/emulated/0 are the same folder.
local offline_dirs = {
    ["weebcentral/Diamond-No-Ace"] = {
        files = { "chapter-410.cbz", "chapter-411.cbz", "chapter-412.cbz" },
    },
    ["weebcentral/Ace-Bundle"] = {
        files = { "Ace-tron-bo.cbz", "chapter-1.cbz" },
        bundles = { ["Ace-tron-bo.cbz"] = { { number = 1, page = 1 }, { number = 2, page = 30 } } },
    },
}
package.preload["truyenviet/storage"] = function()
    return {
        getRootDir = function()
            return download_root
        end,
        getOfflineIndex = function(_, dir)
            return offline_dirs[dir:match("([^/]+/[^/]+)$")]
        end,
        bundleChapterAt = function(_, _, page)
            return page >= 30 and 2 or 1
        end,
    }
end

-- Việc tải nền giả: tiến độ do test đặt, subscriber gọi tay.
local download_status
local download_subscribers = {}
local download_cancels = {}
package.preload["truyenviet/download_job"] = function()
    return {
        status = function()
            return download_status
        end,
        progressText = function()
            return download_status and string.format("⤓ %d/%d", download_status.done, download_status.total)
        end,
        subscribe = function(callback)
            download_subscribers[callback] = true
        end,
        unsubscribe = function(callback)
            download_subscribers[callback] = nil
        end,
        cancel = function(reason)
            table.insert(download_cancels, reason)
        end,
    }
end
local function notifyDownload(status)
    download_status = status
    for callback in pairs(download_subscribers) do
        callback(status)
    end
end

local Reader = require("truyenviet/reader")
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

Reader.active = true
ReaderUI.instance = {
    onClose = function() end,
}
Reader:show("chapter-2.html", function() end, function() end)
assertEqual("chapter-2.html", show_reader_path, "Switches an active reader")
assertEqual(true, Reader.active, "Keeps plugin reader session active")

local normal_return_count = 0
ReaderUI.instance = {
    onClose = function()
        close_count = close_count + 1
        ReaderUI.instance = nil
    end,
}
Reader.on_return_callback = function()
    normal_return_count = normal_return_count + 1
end
Reader:returnToPlugin()
Reader:returnToPlugin()
assertEqual(1, close_count, "Closes reader once")
assertEqual(1, show_files_count, "Restores file manager once")
assertEqual(1, normal_return_count, "Runs return callback once")
assertEqual(false, Reader.active, "Ends reader session")

ReaderUI.instance = nil
broadcast_count = 0
Reader:show("chapter-1.html", function() end, function() end)
assertEqual(1, broadcast_count, "Prepares existing UI before opening reader")
assertEqual("chapter-1.html", show_reader_path, "Opens a new reader")

local normal_count = 0
local next_count = 0
Reader.active = true
Reader.on_return_callback = function()
    normal_count = normal_count + 1
end
ReaderUI.instance = {
    onClose = function()
        close_count = close_count + 1
        ReaderUI.instance = nil
    end,
}
Reader:returnToPlugin(function()
    next_count = next_count + 1
end)
assertEqual(0, normal_count, "Next chapter skips normal return callback")
assertEqual(1, next_count, "Runs next chapter callback")

Reader:setPosition("/sdcard/truyenviet/truyenqq/story/chap-14.html", "Chương 14/20")
assertEqual("Chương 14/20", Reader:positionText("/sdcard/truyenviet/truyenqq/story/chap-14.html"),
    "Shows position for the file it was set for")
assertEqual("Chương 14/20", Reader:positionText("/storage/emulated/0/truyenviet/truyenqq/story/chap-14.html"),
    "Shows position across mount aliases")
assertEqual(nil, Reader:positionText("/sdcard/Books/other.epub"), "Hides position for other files")
Reader:setPosition("/sdcard/Books/other.epub", nil)
assertEqual(nil, Reader:positionText("/sdcard/Books/other.epub"), "Clears position")

-- Opened straight from KOReader (History, file browser): position among downloaded chapters.
assertEqual("Chương 2/3", Reader:positionText(download_root .. "/weebcentral/Diamond-No-Ace/chapter-411.cbz"),
    "Counts downloaded chapters of the story folder")
assertEqual("Chương 3/3", Reader:positionText("/sdcard/koreader/truyenviet/weebcentral/Diamond-No-Ace/chapter-412.cbz"),
    "Matches the folder through the /sdcard alias")
assertEqual(nil, Reader:positionText(download_root .. "/weebcentral/Other-Story/chapter-1.cbz"),
    "No position for a folder without downloads")
Reader:setPosition(download_root .. "/weebcentral/Diamond-No-Ace/chapter-411.cbz", "Chương 411/412")
assertEqual("Chương 411/412", Reader:positionText(download_root .. "/weebcentral/Diamond-No-Ace/chapter-411.cbz"),
    "Chapter list position wins over the download count")

assertEqual(nil, Reader:positionText(download_root .. "/weebcentral/Ace-Bundle/Ace-tron-bo.cbz"),
    "No folder position for a bundle file")

-- Tệp trọn bộ: sau khi KOReader khôi phục trang đọc dở, nhảy tới trang đầu chương.
local bundle_file = download_root .. "/weebcentral/Ace-Bundle/Ace-tron-bo.cbz"
local bundle_uis = {}
local function openBundleUI(last_page)
    local ui = {
        {},
        menu = { registerToMainMenu = function() end },
        document = { file = bundle_file },
        page = last_page,
        events = {},
    }
    function ui:registerPostInitCallback(callback)
        self.post_init = callback
    end
    function ui:registerPostReaderReadyCallback(callback)
        self.ready = callback
    end
    function ui:getCurrentPage()
        return self.page
    end
    function ui:handleEvent(event)
        table.insert(self.events, event)
        if event.name == "GotoPage" then
            self.page = event.args[1]
        end
    end
    Reader:initializeFromReaderUI(ui)
    ui.post_init()
    ui.ready()
    table.insert(bundle_uis, ui)
    return ui
end
-- Lật trang như KOReader: đổi trang rồi gửi PageUpdate tới listener.
local function turnTo(ui, page)
    ui.page = page
    ui[2].onPageUpdate(page)
end
Reader:setStartPage(bundle_file, 30, 2)
local bundle_ui = openBundleUI(5)
assertEqual(30, bundle_ui.page, "Bundle jumps to the chapter's first page")
assertEqual(nil, Reader.start_page, "Start page is used once")
bundle_ui = openBundleUI(5)
assertEqual(0, #bundle_ui.events, "Reopening the bundle without a chapter keeps the reading page")
Reader:setStartPage(bundle_file, 30, 2)
bundle_ui = openBundleUI(42)
assertEqual(42, bundle_ui.page, "Reading page inside the chosen chapter is kept")
Reader:setStartPage("/sdcard/other.cbz", 30, 2)
bundle_ui = openBundleUI(5)
assertEqual(0, #bundle_ui.events, "Start page of another book is ignored")
Reader:setStartPage(nil)

-- Lật sang chương khác trong tệp trọn bộ: báo chương đang đọc một lần.
local reported = {}
Reader:setStartPage(bundle_file, 30, 2, function(number) table.insert(reported, number) end)
bundle_ui = openBundleUI(5)
assertEqual(0, #reported, "Jumping to the chosen chapter is not a chapter change")
turnTo(bundle_ui, 31)
assertEqual(0, #reported, "Turning pages inside the chapter reports nothing")
turnTo(bundle_ui, 29)
assertEqual(1, reported[1], "Turning back into chapter 1 reports it")
turnTo(bundle_ui, 28)
assertEqual(1, #reported, "Same chapter is reported once")
turnTo(bundle_ui, 30)
assertEqual(2, reported[2], "Turning forward reports chapter 2")
reported = {}
Reader:setStartPage(bundle_file, 30, 2)
bundle_ui = openBundleUI(5)
turnTo(bundle_ui, 1)
assertEqual(0, #reported, "No callback when none was given")
bundle_ui = openBundleUI(5)
turnTo(bundle_ui, 31)
assertEqual(0, #reported, "Bundle opened without a start page is not watched")
bundle_ui = openBundleUI(5)

ReaderUI.instance = bundle_ui
assertEqual(5, Reader:openBookPage(bundle_file), "Current page of the open bundle")
assertEqual(nil, Reader:openBookPage("/sdcard/other.cbz"), "No page for a book that is not open")
assertEqual(true, Reader:gotoPageInOpenBook(bundle_file, 30), "Turns the open bundle in place")
assertEqual(30, bundle_ui.page, "In-place turn reaches the page")
assertEqual(false, Reader:gotoPageInOpenBook("/sdcard/other.cbz", 1), "Other books are not turned")
ReaderUI.instance = nil
for _, ui in ipairs(bundle_uis) do
    ui[2].onCloseWidget()
end

-- Opening a chapter from the plugin while another chapter is still open:
-- the old reader closes after the new session started and must not end it.
local function openReaderUI()
    local ui = {
        {},
        menu = { registerToMainMenu = function() end },
        registerPostInitCallback = function(_, callback)
            callback()
        end,
    }
    Reader:initializeFromReaderUI(ui)
    local listener = ui[2]
    ReaderUI.instance = {
        onClose = function(instance)
            if ReaderUI.instance == instance then
                ReaderUI.instance = nil
            end
            listener.onCloseWidget()
        end,
    }
    return listener
end

queue = {}
Reader.active = false
Reader.returning = false
ReaderUI.instance = nil
local returns_a, returns_b, nexts_b = 0, 0, 0
Reader:show("ace-412.cbz", function() returns_a = returns_a + 1 end, function() end)
drain()
openReaderUI()
assertEqual(true, Reader.active, "First chapter starts a session")

local next_opened = 0
local function next_b()
    nexts_b = nexts_b + 1
    Reader:returnToPlugin(function() next_opened = next_opened + 1 end)
end
Reader:show("darwin-50.cbz", function() returns_b = returns_b + 1 end, next_b)
drain()
local listener_b = openReaderUI()
drain()
assertEqual("darwin-50.cbz", show_reader_path, "Switches to the new chapter")
assertEqual(true, Reader.active, "Closing the old chapter keeps the new session active")
assertEqual(0, returns_a, "Old chapter's return callback does not run on switch")
assertEqual(0, returns_b, "New chapter's return callback does not run on switch")

assertEqual(true, listener_b.onEndOfBook(), "End of book is handled by the plugin")
drain()
assertEqual(1, nexts_b, "End of book asks for the next chapter")
assertEqual(1, next_opened, "Leaves the reader to open the next chapter")
assertEqual(false, Reader.active, "Leaving for the next chapter ends the session")
assertEqual(0, returns_b, "Next chapter skips the normal return callback")

-- Closing the current chapter normally still returns to the plugin.
Reader:show("darwin-51.cbz", function() returns_b = returns_b + 1 end, next_b)
drain()
openReaderUI()
ReaderUI.instance:onClose()
drain()
assertEqual(false, Reader.active, "Closing the reader ends the session")
assertEqual(1, returns_b, "Closing the reader returns to the plugin")

-- KOReader Exit/Restart closes the reader and quits once no window is left:
-- reopening the chapter list would keep KOReader running.
for _, event in ipairs({ "onExit", "onRestart" }) do
    local returns = 0
    Reader:show("darwin-50.cbz", function() returns = returns + 1 end, next_b)
    drain()
    local listener = openReaderUI()
    assertEqual(nil, listener[event](), event .. " lets KOReader keep handling the event")
    ReaderUI.instance:onClose()
    drain()
    assertEqual(0, returns, event .. " does not reopen the chapter list")
    assertEqual(false, Reader.active, event .. " ends the session")
    assertEqual(nil, Reader.on_return_callback, event .. " drops the return callback")
end

-- The next chapter's reader is not affected by an earlier Exit.
Reader:show("darwin-51.cbz", function() returns_b = returns_b + 1 end, next_b)
drain()
openReaderUI()
ReaderUI.instance:onClose()
drain()
assertEqual(2, returns_b, "A new reader still returns to the plugin after an earlier Exit")
queue = nil

-- KOReader closes History/Collections before opening a book from them; the
-- plugin opens the reader itself, so it must close them or Exit cannot quit.
local closed_lists = {}
local function bookList(module, key)
    module[key] = {
        close_callback = function()
            table.insert(closed_lists, key .. "@" .. broadcast_count)
            module[key] = nil
        end,
    }
end
local history, collections, reader_history = {}, {}, {}
bookList(history, "booklist_menu")
bookList(collections, "booklist_menu")
bookList(collections, "coll_list")
bookList(reader_history, "booklist_menu")
FileManager.instance = { history = history, collections = collections }
ReaderUI.instance = { history = reader_history, onClose = function() end }
Reader.active = false
broadcast_count = 0
Reader:show("ace-413.cbz", function() end, function() end)
assertEqual(4, #closed_lists, "Closes History and Collections of FileManager and ReaderUI")
assertEqual("booklist_menu@0", closed_lists[1], "Closes the book lists before opening the reader")
assertEqual(nil, history.booklist_menu, "History is closed")
assertEqual(nil, collections.coll_list, "Collection list is closed")
assertEqual("ace-413.cbz", show_reader_path, "Still opens the chapter")

-- No FileManager (opened from a reader): still closes the reader's lists, and
-- nothing breaks when there is nothing to close.
closed_lists = {}
FileManager.instance = nil
bookList(reader_history, "booklist_menu")
Reader.active = false
Reader:show("ace-414.cbz", function() end, function() end)
assertEqual(1, #closed_lists, "Closes the reader's History without a FileManager")
ReaderUI.instance = nil
Reader.active = false
Reader:show("ace-415.cbz", function() end, function() end)
assertEqual(1, #closed_lists, "Nothing to close is fine")
assertEqual("ace-415.cbz", show_reader_path, "Opens the chapter without any book list")

-- Switching chapters closes lists too, right before the new reader opens.
queue = {}
closed_lists = {}
FileManager.instance = { history = history }
bookList(history, "booklist_menu")
ReaderUI.instance = { onClose = function() end }
Reader.active = true
Reader:show("ace-416.cbz", function() end, function() end)
assertEqual(0, #closed_lists, "Switch waits for the old reader to close")
drain()
assertEqual(1, #closed_lists, "Switch closes History before the new reader")
assertEqual("ace-416.cbz", show_reader_path, "Switch opens the new chapter")
queue = nil
FileManager.instance = nil
ReaderUI.instance = nil

-- Tải nền: thanh trạng thái có "⤓ x/y" khi đang tải, gỡ khi xong hoặc đóng sách.
local function footerText(footer)
    local parts = {}
    for _, content in ipairs(footer.contents) do
        local value = content()
        if value then
            table.insert(parts, value)
        end
    end
    return table.concat(parts, " | ")
end
local function newFooterUI()
    local footer = { contents = {}, updates = 0 }
    function footer:addAdditionalFooterContent(fn)
        table.insert(self.contents, fn)
    end
    function footer:removeAdditionalFooterContent(fn)
        for index, value in ipairs(self.contents) do
            if value == fn then
                table.remove(self.contents, index)
                return
            end
        end
    end
    function footer:onUpdateFooter(force)
        self.updates = self.updates + 1
        self.forced = force
    end
    local ui = {
        {},
        menu = { registerToMainMenu = function() end },
        view = { footer = footer, footer_visible = true },
        document = { file = "/sdcard/Books/other.epub" },
        registerPostInitCallback = function(_, callback)
            callback()
        end,
    }
    Reader:initializeFromReaderUI(ui)
    return ui[2], footer
end

download_status = { done = 2, total = 10 }
local listener, footer = newFooterUI()
assertEqual("⤓ 2/10", footerText(footer), "Shows download progress when the book opens")
notifyDownload({ done = 3, total = 10 })
assertEqual("⤓ 3/10", footerText(footer), "Updates download progress")
assertEqual(true, footer.forced, "Repaints a visible footer")
local updates = footer.updates
notifyDownload({ done = 3, total = 10 })
assertEqual(updates, footer.updates, "Same progress does not repaint")
notifyDownload(nil)
assertEqual(0, #footer.contents, "Removes download progress when the job ends")
notifyDownload({ done = 1, total = 4 })
assertEqual("⤓ 1/4", footerText(footer), "A job started while reading shows up")
listener.onCloseWidget()
assertEqual(0, #footer.contents, "Closing the book removes download progress")
assertEqual(nil, next(download_subscribers), "Closing the book unsubscribes")

download_status = nil
listener, footer = newFooterUI()
assertEqual(0, #footer.contents, "No footer content without a download")
listener.onExit()
listener.onRestart()
assertEqual("exit", download_cancels[1], "Exit cancels the background download")
assertEqual("exit", download_cancels[2], "Restart cancels the background download")
listener.onCloseWidget()

print(string.format("Reader tests passed: %d assertions", tests_run))
