local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local ChapterPosition = require("truyenviet/chapter_position")

local passed = 0
local function check(expected, actual, message)
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
    passed = passed + 1
end

local function chapters(count)
    local list = {}
    for i = 1, count do
        list[i] = { url = "https://example.com/chap-" .. i, title = "Chap " .. i }
    end
    return list
end

local function format(page_data, chapter, sort_mode)
    return ChapterPosition.format(ChapterPosition.fromChapterList(page_data, chapter, sort_mode))
end

-- Oldest first: the list index is the reading index.
local asc = { chapters = chapters(20), chapter_sort = "asc" }
check("Chương 14/20", format(asc, { url = "https://example.com/chap-14" }), "asc list")
check("Chương 1/20", format(asc, { url = "https://example.com/chap-1" }), "first chapter")

-- Newest first: count from the bottom so the oldest chapter is still 1.
local desc = { chapters = {}, chapter_sort = "desc" }
for i = 20, 1, -1 do
    desc.chapters[#desc.chapters + 1] = { url = "https://example.com/chap-" .. i, title = "Chap " .. i }
end
check("Chương 14/20", format(desc, { url = "https://example.com/chap-14" }), "desc list uses reading order")
check("Chương 20/20", format(desc, { url = "https://example.com/chap-20" }), "newest chapter in desc list")

-- An explicit sort mode wins over the one stored on the page.
check("Chương 7/20", format(asc, { url = "https://example.com/chap-14" }, "desc"), "explicit sort mode")

-- Paginated chapter lists only know the position inside the open page.
local paged = { chapters = chapters(50), page = 2, total_pages = 5 }
check("Chương 14/50 · trang 2/5", format(paged, { url = "https://example.com/chap-14" }), "paginated list")
check("Chương 3/50", format({ chapters = chapters(50), page = 1, total_pages = 1 },
    { url = "https://example.com/chap-3" }), "single page hides page count")

-- Chapters missing from the list show nothing.
check(nil, format(asc, { url = "https://example.com/other" }), "unknown chapter")
check(nil, format(nil, { url = "x" }), "no page data")
check(nil, format(asc, nil), "no chapter")
check(nil, ChapterPosition.format(nil), "format nil")

-- Downloaded chapters match the online list by title or "local/<title>".
local mixed = { chapters = {
    { url = "local/Chap 1", title = "Chap 1", is_local = true },
    { url = "local/Chap 2", title = "Chap 2", is_local = true },
    { url = "https://example.com/chap-3", title = "Chap 3" },
} }
check(2, ChapterPosition.indexOf(mixed.chapters, { url = "https://example.com/chap-2", title = "Chap 2" }),
    "local item matches online chapter by title")
check(1, ChapterPosition.indexOf(mixed.chapters, { url = "elsewhere", title = "Chap 1", is_local = true }),
    "local items match by title")
check(nil, ChapterPosition.indexOf(mixed.chapters, { url = "elsewhere", title = "Chap 3", is_local = true }),
    "online item never matches a local chapter by title")

-- "Trên máy" folders count readable files; the same file may arrive via /sdcard or /storage/emulated/0.
local books = {
    "/sdcard/Manga/Bokko/v01.cbz",
    "/sdcard/Manga/Bokko/v02.cbz",
    "/sdcard/Manga/Bokko/v03.cbz",
}
check("Tập 2/3", ChapterPosition.format(ChapterPosition.fromFolder(books, "/sdcard/Manga/Bokko/v02.cbz")),
    "folder position")
check("Tập 3/3", ChapterPosition.format(ChapterPosition.fromFolder(books,
    "/storage/emulated/0/Manga/Bokko/v03.cbz")), "folder position across mount aliases")
check(nil, ChapterPosition.fromFolder(books, "/sdcard/Manga/Other/v02.cbz"), "file from another folder")
check(nil, ChapterPosition.fromFolder(nil, "/sdcard/a.cbz"), "no folder listing")

check(true, ChapterPosition.samePath("/sdcard/a/b.cbz", "/storage/emulated/0/a/b.cbz"), "samePath alias")
check(false, ChapterPosition.samePath("/sdcard/a/b.cbz", "/sdcard/c/b.cbz"), "samePath different folder")
check(false, ChapterPosition.samePath(nil, "/sdcard/a/b.cbz"), "samePath nil")

-- Plugin download folders: <root>/<source>/<story>/<file>, across mount aliases.
local download_root = "/storage/emulated/0/koreader/truyenviet"
check("/sdcard/koreader/truyenviet/truyenqq/darwin-jihen",
    ChapterPosition.downloadFolder(download_root, "/sdcard/koreader/truyenviet/truyenqq/darwin-jihen/chapter-51.cbz"),
    "story folder in the file's own path form")
check(download_root .. "/truyenqq/darwin-jihen",
    ChapterPosition.downloadFolder(download_root, download_root .. "/truyenqq/darwin-jihen/chapter-51.cbz"),
    "story folder with the same mount")
check(nil, ChapterPosition.downloadFolder(download_root, download_root .. "/truyenviet-debug.txt"), "file at root")
check(nil, ChapterPosition.downloadFolder(download_root, download_root .. "/truyenqq/chapter-1.cbz"), "file at source level")
check(nil, ChapterPosition.downloadFolder(download_root, download_root .. "/truyenqq/a/b/chapter-1.cbz"), "nested too deep")
check(nil, ChapterPosition.downloadFolder(download_root, download_root .. "/cache/covers/x.jpg"), "cache folder")
check(nil, ChapterPosition.downloadFolder(download_root, "/sdcard/Books/Manga/Bokko/v01.cbz"), "outside the plugin folder")
check(nil, ChapterPosition.downloadFolder(download_root, "/sdcard/koreader/truyenviet-old/a/b/c.cbz"),
    "sibling folder sharing the prefix")
check(nil, ChapterPosition.downloadFolder(nil, "/sdcard/a.cbz"), "no root")
check("Chương 1/2", ChapterPosition.format(ChapterPosition.fromFolder({ "/x/a/1.cbz", "/x/a/2.cbz" }, "/x/a/1.cbz",
    "Chương")), "folder label override")

print(string.format("chapter_position_test: %d checks passed", passed))
