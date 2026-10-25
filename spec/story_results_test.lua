local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local empty_modules = {
    "ffi/blitbuffer",
    "ui/widget/button",
    "ui/widget/container/centercontainer",
    "ui/font",
    "ui/widget/container/framecontainer",
    "ui/geometry",
    "ui/gesturerange",
    "ui/widget/horizontalgroup",
    "ui/widget/horizontalspan",
    "ui/widget/iconwidget",
    "ui/widget/imagewidget",
    "ui/widget/container/leftcontainer",
    "ui/widget/listview",
    "ui/size",
    "ui/widget/textboxwidget",
    "ui/widget/textwidget",
    "ui/widget/titlebar",
    "ui/widget/verticalgroup",
    "ui/widget/verticalspan",
}

for _, module_name in ipairs(empty_modules) do
    package.preload[module_name] = function()
        return {}
    end
end

package.preload["device"] = function()
    return {
        screen = {},
        input = {},
    }
end

package.preload["ui/widget/container/inputcontainer"] = function()
    return {
        extend = function(_, definition)
            return definition
        end,
    }
end

local dirty_count = 0
local close_count = 0
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function()
            dirty_count = dirty_count + 1
        end,
        close = function()
            close_count = close_count + 1
        end,
        nextTick = function(_, callback)
            callback()
        end,
    }
end

package.preload["truyenviet/storage"] = function()
    return {}
end

local StoryResults = require("truyenviet/widgets/story_results")
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

local first = {
    source_id = "truyenfull",
    url = "https://example.test/first",
}
local second = {
    source_id = "truyenqq",
    url = "https://example.test/second",
}
local third = {
    source_id = "dualeo",
    url = "https://example.test/third",
}
local stories = { first, second, third }
local story_items = {
    { story = first },
    { story = second },
    { story = third },
}
local populate_count = 0
local list = {
    items = {
        story_items[1],
        story_items[2],
        story_items[3],
    },
    items_per_page = 2,
    show_page = 2,
}

function list:_populateItems()
    populate_count = populate_count + 1
    self.pages = math.ceil(#self.items / self.items_per_page)
end

local view = {
    stories = stories,
    story_items = story_items,
    list = list,
}

assertEqual(true, StoryResults.removeStory(view, third), "Removes story")
assertEqual(2, #view.stories, "Removes story data")
assertEqual(2, #view.story_items, "Removes story widget")
assertEqual(2, #view.list.items, "Removes list item")
assertEqual(1, view.list.show_page, "Clamps page after removing last page")

assertEqual(
    true,
    StoryResults.removeStory(view, {
        source_id = second.source_id,
        url = second.url,
    }),
    "Matches copied favorite record"
)
assertEqual(first, view.stories[1], "Preserves remaining story")
assertEqual(false, StoryResults.removeStory(view, third), "Ignores missing story")
assertEqual(2, populate_count, "Only refreshes after successful removal")

assertEqual(true, StoryResults.removeStory(view, first), "Removes final story")
assertEqual(0, #view.stories, "Allows empty favorites")
assertEqual(0, #view.list.items, "Clears final list item")
assertEqual(1, view.list.show_page, "Keeps valid page when empty")
assertEqual(3, dirty_count, "Repaints after each removal")

-- Quay lại danh sách: đứng ở trang chứa truyện vừa mở.
local focus_items = {}
local focus_list_items = {}
for index = 1, 7 do
    local item = { story = { source_id = "s", url = "u" .. index } }
    table.insert(focus_items, item)
    table.insert(focus_list_items, item)
end
local focus_populates = 0
local focus_view = {
    story_items = focus_items,
    list = {
        items = focus_list_items,
        items_per_page = 3,
        show_page = 1,
        _populateItems = function() focus_populates = focus_populates + 1 end,
    },
}
assertEqual(true, StoryResults.showStoryPage(focus_view, { source_id = "s", url = "u5" }), "Finds focused story")
assertEqual(2, focus_view.list.show_page, "Opens page of focused story")
assertEqual(1, focus_populates, "Repopulates once for new page")
assertEqual(true, StoryResults.showStoryPage(focus_view, focus_items[7].story), "Finds story on last page")
assertEqual(3, focus_view.list.show_page, "Opens last page")
assertEqual(false, StoryResults.showStoryPage(focus_view, { source_id = "s", url = "gone" }), "Missing story")
assertEqual(3, focus_view.list.show_page, "Missing story keeps page")
assertEqual(false, StoryResults.showStoryPage(focus_view, nil), "No focus story")
assertEqual(false, StoryResults.showStoryPage({ story_items = {}, list = {} }, focus_items[1].story),
    "Empty list has no items_per_page")
focus_populates = 0
StoryResults.showStoryPage(focus_view, focus_items[7].story)
assertEqual(0, focus_populates, "Same page does not repopulate")

local return_count = 0
local close_view = {
    on_return_callback = function()
        return_count = return_count + 1
    end,
}
assertEqual(true, StoryResults.onClose(close_view), "Closes results")
assertEqual(true, StoryResults.onClose(close_view), "Ignores duplicate close")
assertEqual(1, close_count, "Closes widget once")
assertEqual(1, return_count, "Runs return callback once")

-- Dòng phụ của StoryItem: nguồn · số chương · Hoàn thành (+ sao yêu thích)
local Storage = require("truyenviet/storage")
Storage.isFavorite = function(_, story)
    return story.favorite == true
end
local function sourceText(story)
    return StoryResults.StoryItem.getSourceText({ story = story })
end

assertEqual(
    "Nguồn A · 120 chương · Hoàn thành",
    sourceText({ source_name = "Nguồn A", chapter_count = 120, completed = true }),
    "Count and completed"
)
assertEqual(
    "Nguồn A · 120 chương",
    sourceText({ source_name = "Nguồn A", chapter_count = 120, completed = false }),
    "Count only (ongoing)"
)
assertEqual(
    "Nguồn A · 120 chương",
    sourceText({ source_name = "Nguồn A", chapter_count = "120" }),
    "Count given as numeric string"
)
assertEqual(
    "Nguồn A · Hoàn thành",
    sourceText({ source_name = "Nguồn A", completed = true }),
    "Completed only"
)
assertEqual(
    "Nguồn A",
    sourceText({ source_name = "Nguồn A" }),
    "Neither count nor completed"
)
assertEqual(
    "Nguồn A",
    sourceText({ source_name = "Nguồn A", chapter_count = 0 }),
    "Zero count is not shown"
)
assertEqual(
    "truyenqq · 8 chương · Hoàn thành  ★",
    sourceText({ source_id = "truyenqq", chapter_count = 8, completed = true, favorite = true }),
    "Favorite marker stays last and source_id is the fallback name"
)
assertEqual(
    "Nguồn A · Chương 170 · Hoàn thành",
    sourceText({ source_name = "Nguồn A", latest_chapter = 170, chapter_count = 165, completed = true }),
    "Latest chapter wins over total count"
)
assertEqual(
    "Nguồn A · Chương 12.5",
    sourceText({ source_name = "Nguồn A", latest_chapter = "12.5" }),
    "Decimal latest chapter is kept"
)
assertEqual(
    "Nguồn A · 120 chương",
    sourceText({ source_name = "Nguồn A", latest_chapter = 0, chapter_count = 120 }),
    "Invalid latest chapter falls back to count"
)

-- Tủ truyện: số chương đã tải trên tổng số, không có dấu sao
assertEqual(
    "truyenqq · Chương 83 · Hoàn thành · Đã tải 78/83",
    sourceText({ source_id = "truyenqq", latest_chapter = 83, completed = true,
        offline_count = 78, favorite = true }),
    "Downloaded over latest chapter"
)
assertEqual(
    "Nguồn A · Chương 125 · Đã tải 5/120",
    sourceText({ source_name = "Nguồn A", chapter_count = 120, latest_chapter = 125, offline_count = 5 }),
    "Exact count is the total when known"
)
assertEqual(
    "weebcentral · Chương 412 · Đã tải 412/412",
    sourceText({ source_id = "weebcentral", latest_chapter = 412, offline_count = 412 }),
    "Every chapter downloaded"
)
assertEqual(
    "weebcentral · Chương 412 · Đã tải hết",
    sourceText({ source_id = "weebcentral", latest_chapter = 412, offline_count = 418 }),
    "Extra decimal chapters push the count past the latest chapter"
)
assertEqual(
    "zettruyen · Chương 12 · Chưa tải",
    sourceText({ source_id = "zettruyen", latest_chapter = 12, offline_count = 0 }),
    "Nothing downloaded"
)
assertEqual(
    "Nguồn A · Đã tải 6 chương",
    sourceText({ source_name = "Nguồn A", offline_count = 6 }),
    "Unknown total"
)
assertEqual(
    "Trên máy · 10 tập",
    sourceText({ source_id = "local", kind = "local", local_type = "dir", offline_count = 10 }),
    "Local folder"
)
assertEqual(
    "Trên máy · PDF",
    sourceText({ source_id = "local", kind = "local", local_type = "pdf" }),
    "Local single file"
)

-- Dòng 3: chương đọc cuối (Lịch sử đọc) ưu tiên hơn dung lượng (Tủ truyện)
package.preload["truyenviet/local_library"] = function()
    return { formatSize = function(bytes) return bytes .. " B" end }
end
local function detailText(story)
    return StoryResults.StoryItem.getDetailText({ story = story })
end
assertEqual("Đang đọc: Chương 205", detailText({ reading_chapter = "Chương 205" }), "History shows last chapter")
assertEqual("Dung lượng: 10 B", detailText({ size_bytes = 10 }), "Library shows size")
assertEqual("Đang đọc: Tập 3", detailText({ reading_chapter = "Tập 3", size_bytes = 10 }),
    "Last chapter wins over size")
assertEqual("Đang đọc: Chapter 84 · 80%", detailText({ reading_chapter = "Chapter 84", reading_percent = 80 }),
    "History shows reading progress")
assertEqual("Đang đọc: Chapter 1 · 0%", detailText({ reading_chapter = "Chapter 1", reading_percent = 0 }),
    "Zero progress is still shown")
assertEqual(nil, detailText({ reading_chapter = "", reading_percent = 50 }), "Progress needs a chapter title")
assertEqual(nil, detailText({ reading_chapter = "" }), "Empty chapter title shows nothing")
assertEqual(nil, detailText({}), "Search results have no third line")

print(string.format("Story results tests passed: %d assertions", tests_run))
