local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local fail_flush = false
local flush_count = 0
local settings = {
    data = {
        disabled_sources = {
            dualeo = true,
            truyenqq = true,
        },
    },
}

function settings:readSetting(key, default)
    if self.data[key] == nil then
        self.data[key] = default
    end
    return self.data[key]
end

function settings:saveSetting(key, value)
    self.data[key] = value
    return self
end

function settings:flush()
    if fail_flush then
        error("simulated write failure")
    end
    flush_count = flush_count + 1
    return self
end

package.preload["datastorage"] = function()
    return {
        getFullDataDir = function()
            return "data"
        end,
        getSettingsDir = function()
            return "settings"
        end,
    }
end

package.preload["luasettings"] = function()
    return {
        open = function()
            return settings
        end,
    }
end

package.preload["ffi/util"] = function()
    return {
        joinPath = function(left, right)
            return left .. "/" .. right
        end,
    }
end

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function()
            return nil
        end,
    }
end

package.preload["util"] = function()
    return {
        makePath = function() end,
    }
end

package.preload["truyenviet/helpers"] = function()
    return {
        urlLeaf = function(_, fallback)
            return fallback
        end,
        safeName = function(_, fallback)
            return fallback
        end,
    }
end

local Storage = require("truyenviet/storage")
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

assertEqual(false, Storage:isSourceEnabled("dualeo"), "Reads disabled source")
assertEqual(false, Storage:isSourceEnabled("truyenqq"), "Reads second disabled source")

local ok = Storage:setSourceEnabled("dualeo", true)
assertEqual(true, ok, "Enables source")
assertEqual(true, Storage:isSourceEnabled("dualeo"), "Enabled state is immediate")
assertEqual(nil, settings.data.disabled_sources.dualeo, "Enabled source is removed")
assertEqual(true, settings.data.disabled_sources.truyenqq, "Other source is preserved")

ok = Storage:setSourceEnabled("dualeo", false)
assertEqual(true, ok, "Disables source")
assertEqual(false, Storage:isSourceEnabled("dualeo"), "Disabled state is immediate")

fail_flush = true
local failed, err = Storage:setSourceEnabled("dualeo", true)
assertEqual(nil, failed, "Reports write failure")
assertEqual(true, type(err) == "string", "Returns write error")
assertEqual(false, Storage:isSourceEnabled("dualeo"), "Rolls back failed write")

local story = {
    source_id = "truyenfull",
    title = "Demo",
    url = "https://example.test/demo",
}
failed, err = Storage:addFavorite(story)
assertEqual(nil, failed, "Favorite write failure is contained")
assertEqual(false, Storage:isFavorite(story), "Failed favorite write is rolled back")

fail_flush = false

-- dualeo tắt mặc định đúng một lần; bật lại thì không bị tắt lần nữa
assertEqual(true, settings.data.default_disabled_applied.dualeo, "Records one-time default disable")
assertEqual(true, Storage:setSourceEnabled("dualeo", true), "Re-enables default-disabled source")
Storage.settings = nil
Storage:initialize()
assertEqual(true, Storage:isSourceEnabled("dualeo"), "User re-enable survives restart")
assertEqual(false, Storage:isSourceEnabled("truyenqq"), "Other disabled source survives restart")
settings.data.default_disabled_applied = nil
settings.data.disabled_sources = {}
Storage.settings = nil
Storage:initialize()
assertEqual(false, Storage:isSourceEnabled("dualeo"), "Fresh settings disable dualeo by default")
assertEqual(true, settings.data.disabled_sources.dualeo, "Default disable is persisted")

assertEqual(
    true,
    Storage:setCustomBaseUrl("truyenfull", " https://mirror.example/ "),
    "Saves custom base URL"
)
assertEqual(
    "https://mirror.example",
    Storage:getCustomBaseUrl("truyenfull"),
    "Normalizes custom base URL"
)
assertEqual(true, Storage:setFastMode(true), "Saves fast mode")
assertEqual(true, settings.data.fast_mode, "Persists fast mode")

-- Cập nhật Tủ truyện không đổi gì thì không ghi lại settings.
local unchanged = {
    source_id = "truyenfull",
    title = "Không đổi",
    url = "https://example.test/same",
    details = { author = "A", tags = { "x", "y" } },
}
assertEqual(true, Storage:addFavorite(unchanged), "Adds favorite for unchanged check")
local flushes = flush_count
assertEqual(true, Storage:updateFavorite({
    source_id = "truyenfull",
    title = "Không đổi",
    url = "https://example.test/same",
    details = { author = "A", tags = { "x", "y" } },
}), "Unchanged update succeeds")
assertEqual(flushes, flush_count, "Unchanged favorite skips flush")
assertEqual(true, Storage:updateFavorite({
    source_id = "truyenfull",
    title = "Không đổi",
    url = "https://example.test/same",
}), "Update without details keeps old details")
assertEqual(flushes, flush_count, "Kept fields alone do not trigger flush")
assertEqual(true, Storage:updateFavorite({
    source_id = "truyenfull",
    title = "Đã đổi",
    url = "https://example.test/same",
    details = { author = "A", tags = { "x", "z" } },
}), "Changed update succeeds")
assertEqual(flushes + 1, flush_count, "Changed favorite flushes once")
assertEqual("z", Storage:getFavorites()["truyenfull|https://example.test/same"].details.tags[2], "Nested change saved")

settings.data.custom_url_truyenqq = 123
assertEqual(nil, Storage:getCustomBaseUrl("truyenqq"), "Ignores invalid custom URL")
settings.data.history = { "broken", { story = {}, chapter = {} } }
assertEqual(0, #Storage:getHistory(), "Ignores invalid history records")

print(string.format("Storage tests passed: %d assertions", tests_run))
