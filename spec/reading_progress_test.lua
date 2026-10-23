package.path = "./truyenviet.koplugin/?.lua;" .. package.path
local records, opens = {}, 0
local DocSettings = {}
function DocSettings:findSidecarFile(path)
    return records[path] and path .. ".sdr/metadata.lua"
end
function DocSettings:open(path)
    opens = opens + 1
    assert(not records[path].broken, "corrupt metadata")
    return { readSetting = function(_, key) return records[path][key] end }
end
package.preload["docsettings"] = function() return DocSettings end
package.preload["truyenviet/storage"] = function()
    return { chapterNumber = function(title) return tonumber(title:match("(%d+%.?%d*)")) end }
end
local Progress = require("truyenviet/reading_progress")
local checks = 0
local function equal(actual, expected, message)
    checks = checks + 1
    assert(actual == expected, (message or "unexpected progress") .. ": " .. tostring(actual))
end

records["chapter.cbz"] = { percent_finished = 0.426 }
equal(Progress.percent("chapter.cbz"), 43, "round native CBZ progress")
records["chapter.html"] = { percent_finished = 0.75 }
equal(Progress.percent("chapter.html"), 75, "native text progress")
equal(Progress.percent("unopened.cbz"), nil, "downloaded but unopened")
equal(Progress.percent(nil), nil, "missing file")
records.empty = {}
equal(Progress.percent("empty"), nil, "sidecar without reading progress")
records.zero = { percent_finished = 0 }
equal(Progress.percent("zero"), 0, "opened at zero progress is not unopened")
records.zero.percent_finished = 0.001
equal(Progress.percent("zero"), 0, "small saved progress rounding to zero stays numeric")
records.bad = { percent_finished = "invalid" }
equal(Progress.percent("bad"), nil, "invalid percentage")
records.bad.percent_finished = 0/0
equal(Progress.percent("bad"), nil, "NaN percentage")
records.bad.percent_finished = 2
equal(Progress.percent("bad"), 100, "clamp percentage")
records.bad.percent_finished = -1
equal(Progress.percent("bad"), 0, "clamp negative percentage")
records.bad.broken = true
equal(Progress.percent("bad"), nil, "corrupt sidecar does not break list")
local missing_cache = {}
local missing_before = opens
equal(Progress.percent("unopened.cbz", nil, missing_cache), nil)
equal(Progress.percent("unopened.cbz", nil, missing_cache), nil)
equal(opens, missing_before, "unopened metadata does not open a document")
local cache, before = {}, opens
equal(Progress.percent("chapter.cbz", nil, cache), 43)
equal(Progress.percent("chapter.cbz", nil, cache), 43)
equal(opens - before, 1, "one metadata read per file per list")
records["chapter.cbz"].percent_finished = 0.8
equal(Progress.percent("chapter.cbz", nil, {}), 80, "new list refreshes progress")

local toc = { { title = "Chapter 1", page = 1 }, { title = "Chapter 2", page = 11 },
    { title = "Chapter 3", page = 21 } }
records.bundle = { handmade_toc = toc, last_page = 15, doc_pages = 30,
    percent_finished = 0.5 }
equal(Progress.percent("bundle", 1), nil, "do not infer skipped chapters as opened")
equal(Progress.percent("bundle", 2), 50, "recover current chapter from native last page")
equal(Progress.percent("bundle", 3), nil, "future chapter has no progress")
records.bundle.truyenviet_chapter_progress = { ["1"] = 0.3, ["3"] = 1 }
equal(Progress.percent("bundle", 1), 30, "independent saved chapter progress")
equal(Progress.percent("bundle", 3), 100, "independent completed chapter")
equal(Progress.percent("bundle", 99), nil, "unknown chapter")
records.bundle.truyenviet_chapter_progress["1"] = 0
equal(Progress.percent("bundle", 1), 0, "explicit bundle zero remains numeric")

local ready, page, saves = nil, 1, 0
local settings = { data = { handmade_toc = toc, doc_pages = 30 } }
function settings:readSetting(key) return self.data[key] end
function settings:saveSetting(key, value) self.data[key] = value; saves = saves + 1 end
local ui = { doc_settings = settings, document = { info = { number_of_pages = 30 } },
    getCurrentPage = function() return page end,
    registerPostReaderReadyCallback = function(_, callback) ready = callback end }
local record = Progress.observe(ui)
record()
equal(saves, 0, "ignore initial page restoration before reader ready")
page = 15; ready()
equal(settings.data.truyenviet_chapter_progress["2"], 0.5, "record actual opened chapter")
equal(settings.data.truyenviet_chapter_progress["1"], nil, "opening chapter 2 does not mark 1")
record(); equal(saves, 1, "unchanged page does not rewrite settings")
page = 20; record()
equal(settings.data.truyenviet_chapter_progress["2"], 1, "chapter end records completion")
page = 25; record()
equal(settings.data.truyenviet_chapter_progress["3"], 0.5, "record next chapter independently")
equal(settings.data.truyenviet_chapter_progress["2"], 1, "retain earlier chapter progress")
page = 30; record()
equal(settings.data.truyenviet_chapter_progress["3"], 1, "last chapter uses total document pages")
ui.document = nil; record()
equal(saves, 4, "closing document does not lose progress or write again")
equal(type(Progress.observe({})), "function", "unavailable reader metadata is harmless")
Progress.observe({})()
records.bundle = settings.data
equal(Progress.percent("bundle", 2), 100, "recorded progress can be read after returning")
equal(Progress.percent("bundle", 3), 100)

print("Reading progress tests passed: " .. checks .. " checks")
