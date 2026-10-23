-- Execute the production Browser, Reader, ChapterOrder and ChapterPosition.
-- Only KOReader/platform boundaries are substituted; no network is contacted.
local results = {}
local plugin_root = "./truyenviet.koplugin"
local original_require = require
local function equal(actual, expected, message)
    assert(actual == expected, (message or "unexpected result")
        .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function harness(options)
    options = options or {}
    local h = { queue = {}, dialogs = {}, lists = {}, closes = 0,
        opens = {}, page_loads = {}, history = {}, filemanager_opens = 0 }
    local widget = {}
    function widget:extend(fields)
        fields.__index = fields
        return setmetatable(fields, { __index = self })
    end
    function widget:new(fields)
        return setmetatable(fields or {}, { __index = self })
    end
    local manager = {}
    function manager:nextTick(callback) table.insert(h.queue, callback) end
    function manager:show(dialog) table.insert(h.dialogs, dialog) end
    function manager:close() end
    function manager:broadcastEvent() end
    local reader_ui = {}
    local filemanager = {}
    function filemanager:showFiles() h.filemanager_opens = h.filemanager_opens + 1 end
    if options.filemanager then
        filemanager.instance = { reinit = function()
            h.filemanager_opens = h.filemanager_opens + 1
        end }
    end
    local storage = {}
    function storage.chapterNumberOf(chapter) return chapter.number end
    function storage.chapterNumber(title) return tonumber(title:match("(%d+%.?%d*)")) end
    function storage:getBundleChapter(_, _, chapter)
        if options.bundle then return "/books/bundle.cbz", chapter.number * 10 end
    end
    function storage:bundleChapterAt(_, page)
        if page >= 560 then return 56 end
        if page >= 550 then return 55 end
    end
    function storage:saveHistory(story, chapter)
        table.insert(h.history, { story = story, chapter = chapter })
    end
    local builder = {}
    function builder:getExistingPath(_, _, chapter)
        return "/books/" .. chapter.number .. ".cbz"
    end
    local modules = {
        ["ui/event"] = { new = function(_, name, value)
            return { name = name, value = value }
        end },
        ["ui/uimanager"] = manager,
        ["apps/reader/readerui"] = reader_ui,
        ["apps/filemanager/filemanager"] = filemanager,
        ["ui/widget/container/widgetcontainer"] = widget,
        ["ui/widget/menu"] = widget,
        ["ui/widget/widget"] = widget,
        ["ui/widget/infomessage"] = widget,
        ["logger"] = { info = function() end },
        ["truyenviet/debugger"] = { write = function() end },
        ["truyenviet/storage"] = storage,
        ["truyenviet/document_builder"] = builder,
        ["truyenviet/download_job"] = {
            subscribe = function() end, unsubscribe = function() end,
            status = function() return nil end,
        },
        ["device"] = { screen = {} },
    }
    -- Imported by Browser but unused by the navigation paths under test.
    for _, name in ipairs({ "ui/widget/buttondialog", "ui/widget/confirmbox",
        "ui/widget/inputdialog", "ui/network/manager", "ui/widget/notification",
        "ui/widget/textviewer", "ui/trapper", "truyenviet/async_pool",
        "truyenviet/background_fetch", "truyenviet/chapter_cache",
        "truyenviet/chapter_downloader", "truyenviet/cover_cache",
        "truyenviet/credential_manager", "truyenviet/local_library",
        "truyenviet/search_service", "truyenviet/source_registry",
        "truyenviet/widgets/story_results", "truyenviet/helpers",
        "truyenviet/windows", "socket" }) do
        modules[name] = {}
    end
    require = function(name)
        if modules[name] ~= nil then return modules[name] end
        local actual = {
            ["truyenviet/reader"] = true, ["truyenviet/browser"] = true,
            ["truyenviet/chapter_order"] = true,
            ["truyenviet/chapter_position"] = true, ["truyenviet/version"] = true,
            ["truyenviet/reading_progress"] = true,
        }
        assert(actual[name], "unexpected dependency: " .. name)
        local value = assert(loadfile(plugin_root .. "/" .. name .. ".lua"))()
        modules[name] = value
        return value
    end
    h.reader = require("truyenviet/reader")
    h.browser = require("truyenviet/browser")
    function reader_ui:showReader(path)
        table.insert(h.opens, path)
        local ui = { document = { file = path }, view = {}, menu = {
            registerToMainMenu = function() end,
        } }
        if options.bundle then
            ui.document.info = { number_of_pages = 570 }
            ui.doc_settings = { data = { handmade_toc = {
                { title = "Chapter 55", page = 550 }, { title = "Chapter 56", page = 560 },
            } } }
            function ui.doc_settings:readSetting(key) return self.data[key] end
            function ui.doc_settings:saveSetting(key, value) self.data[key] = value end
        end
        function ui:getCurrentPage() return h.current_page or 1 end
        function ui:registerPostReaderReadyCallback(callback)
            self.ready = self.ready or {}
            table.insert(self.ready, callback)
        end
        function ui:registerPostInitCallback(callback) self.post_init = callback end
        function ui:handleEvent(event)
            if event.name == "GotoPage" then
                h.current_page = event.value
                if self[2] and self[2].onPageUpdate then self[2].onPageUpdate() end
            end
        end
        function ui:onClose()
            h.closes = h.closes + 1
            if self[2] and self[2].onCloseWidget then self[2].onCloseWidget() end
            self.document = nil
            if reader_ui.instance == self then reader_ui.instance = nil end
        end
        reader_ui.instance = ui
        h.reader:initializeFromReaderUI(ui)
        ui.post_init()
        for _, callback in ipairs(ui.ready or {}) do callback() end
        h.ui = ui
    end
    function h.browser:triggerPrefetchAndPurge() end
    function h.browser:showChapterList(page_data, source, back)
        table.insert(h.lists, { data = page_data, source = source, back = back,
            reader_closed = reader_ui.instance == nil })
    end
    function h.browser:loadStoryPage(story, source, page, back, auto_open, from_reader, sort)
        table.insert(h.page_loads, { story = story, source = source, page = page,
            back = back, auto_open = auto_open, from_reader = from_reader, sort = sort })
    end
    h.first = { number = 55, title = "Chapter 55", url = "/55" }
    h.last = { number = 56, title = "Chapter 56", url = "/56" }
    h.source = { id = "truyenqq", kind = "comic", reversed_chapters = options.reversed }
    h.data = { story = { title = "Darwin Jihen", url = "/darwin-jihen" },
        chapters = options.desc and { h.last, h.first } or { h.first, h.last },
        chapter_sort = options.desc and "desc" or "asc",
        total_pages = options.total_pages or 1, page = options.page or 1,
        refresh_state = options.refresh_state }
    h.back = function() end
    function h:open(chapter)
        self.bundle_chapter = chapter.number
        self.browser:openChapter(nil, self.data, self.source, chapter, self.back)
    end
    function h:drain()
        local count = 0
        while #self.queue > 0 do
            count = count + 1
            assert(count < 100, "UI callback loop")
            table.remove(self.queue, 1)()
        end
    end
    function h:nextBeyondEnd() self.ui[2].onEndOfBook() end
    function h:assertReturned()
        equal(self.closes, 1, "chapter must close exactly once")
        equal(#self.lists, 1, "chapter list must open exactly once")
        equal(self.lists[1].data, self.data, "same chapter list context")
        equal(self.lists[1].source, self.source, "same source")
        equal(self.lists[1].back, self.back, "same parent navigation")
        equal(self.lists[1].reader_closed, true, "close before showing list")
        equal(self.reader.active, false, "reader session ended")
        equal(self.reader.returning, false, "return flag reset")
        equal(#self.dialogs, 0, "no blocking final-chapter dialog")
        equal(#self.opens, 1, "do not reopen the completed chapter")
    end
    return h
end

local function test(name, callback)
    local ok, err = pcall(callback)
    table.insert(results, { name = name, passed = ok, error = ok and "" or tostring(err) })
end

test("last chapter: Next closes reader then restores its chapter list", function()
    local h = harness(); h:open(h.last); h:nextBeyondEnd(); h:drain(); h:assertReturned()
end)
test("reaching the last page alone does not close the chapter", function()
    local h = harness(); h:open(h.last); h.current_page = 999; h:drain()
    equal(h.closes, 0); equal(#h.lists, 0); equal(h.reader.active, true)
end)
test("rapid repeated Next opens only one chapter list", function()
    local h = harness(); h:open(h.last)
    h:nextBeyondEnd(); h:nextBeyondEnd(); h:nextBeyondEnd()
    h:drain(); h:assertReturned()
    h:nextBeyondEnd(); h.reader:returnToPlugin(); h:drain(); h:assertReturned()
end)
test("existing FileManager is reused when returning", function()
    local h = harness({ filemanager = true }); h:open(h.last)
    h:nextBeyondEnd(); h:drain(); h:assertReturned(); equal(h.filemanager_opens, 1)
end)
for _, state in ipairs({ "offline", "failed", "running", "fresh" }) do
    test("end of known list returns with refresh state " .. state, function()
        local h = harness({ refresh_state = state }); h:open(h.last)
        h:nextBeyondEnd(); h:drain(); h:assertReturned(); equal(h.data.refresh_state, state)
    end)
end
test("last chapter in descending display order returns", function()
    local h = harness({ desc = true }); h:open(h.last)
    h:nextBeyondEnd(); h:drain(); h:assertReturned()
end)
test("last page of ascending paginated source returns", function()
    local h = harness({ total_pages = 3, page = 3 }); h:open(h.last)
    h:nextBeyondEnd(); h:drain(); h:assertReturned(); equal(#h.page_loads, 0)
end)
test("last reading page of reversed source returns", function()
    local h = harness({ total_pages = 3, page = 1, reversed = true, desc = true })
    h:open(h.last); h:nextBeyondEnd(); h:drain(); h:assertReturned()
end)
for _, reversed in ipairs({ false, true }) do
  for _, desc in ipairs({ false, true }) do
    test("another list page loads, reversed=" .. tostring(reversed) .. ", descending=" .. tostring(desc), function()
        local h = harness({ total_pages = 3, page = 2, reversed = reversed, desc = desc })
        h:open(h.last); h:nextBeyondEnd(); h:drain()
        equal(#h.page_loads, 1); equal(h.page_loads[1].page, reversed and 1 or 3)
        equal(h.page_loads[1].auto_open, desc and "last" or true)
        equal(#h.lists, 0); equal(#h.dialogs, 0)
    end)
  end
end
for _, desc in ipairs({ false, true }) do
    test("normal next chapter remains available, descending=" .. tostring(desc), function()
        local h = harness({ desc = desc }); h:open(h.first)
        h:nextBeyondEnd(); h:drain()
        equal(#h.opens, 2); equal(h.opens[2], "/books/56.cbz")
        equal(#h.lists, 0); equal(h.reader.active, true)
    end)
end
test("previous chapter action keeps working", function()
    local h = harness(); h:open(h.last); h.reader.on_prev_chapter_callback(true); h:drain()
    equal(#h.opens, 2); equal(h.opens[2], "/books/55.cbz"); equal(#h.lists, 0)
end)
test("previous at first chapter retains its boundary message", function()
    local h = harness(); h:open(h.first); h.reader.on_prev_chapter_callback(true); h:drain()
    equal(h.closes, 0); equal(#h.opens, 1); equal(#h.lists, 0)
    equal(#h.dialogs, 1)
    equal(h.dialogs[1].text, "Đã tới chương đầu tiên ở thời điểm hiện tại.")
end)
test("next chapter inside an open bundle turns pages without closing", function()
    local h = harness({ bundle = true }); h:open(h.first)
    h:nextBeyondEnd(); h:drain()
    equal(h.current_page, 560); equal(h.closes, 0); equal(#h.opens, 1); equal(#h.lists, 0)
end)
test("last chapter in an open bundle closes and returns", function()
    local h = harness({ bundle = true }); h:open(h.last)
    h:nextBeyondEnd(); h:drain(); h:assertReturned()
end)
test("reader records bundle progress after start-page restoration", function()
    local h = harness({ bundle = true }); h:open(h.first)
    local saved = h.ui.doc_settings.data.truyenviet_chapter_progress
    equal(saved["55"], 0.1, "record requested chapter after jumping to its first page")
    equal(saved["56"], nil, "do not record another chapter during restoration")
    h.current_page = 554; h.ui[2].onPageUpdate()
    equal(saved["55"], 0.5, "page updates record the active chapter")
    h:nextBeyondEnd(); h:drain()
    equal(saved["55"], 0.5, "jumping to next chapter preserves partial progress")
    equal(saved["56"], 1 / 11, "new chapter has its own progress")
end)
test("explicit next-chapter menu at the end also returns", function()
    local h = harness(); h:open(h.last); h.reader.on_next_chapter_callback(false)
    h:drain(); h:assertReturned()
end)

require = original_require
local failed = 0
for _, result in ipairs(results) do
    if not result.passed then
        failed = failed + 1
        io.stderr:write("FAIL " .. result.name .. ": " .. result.error .. "\n")
    end
end
assert(failed == 0, tostring(failed) .. " end-of-series navigation case(s) failed")
print("End-of-series tests passed: " .. tostring(#results) .. " cases")
