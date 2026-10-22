local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["socket.url"] = function()
    return { absolute = function(_, href) return href end }
end
package.preload["util"] = function()
    return {}
end

local Util = require("truyenviet/helpers")
local tests_run = 0
local function assertEqual(expected, actual, message)
    tests_run = tests_run + 1
    if expected ~= actual then
        error(string.format("%s: expected %s, got %s", message, tostring(expected), tostring(actual)))
    end
end

-- Menu của KOReader crash khi phần bên phải quá dài nên phải rút gọn theo ký tự UTF-8.
assertEqual("Chapter 1", Util.shorten("Chapter 1", 24), "Short text unchanged")
assertEqual("abcde", Util.shorten("abcde", 5), "Exact limit unchanged")
assertEqual("abcd…", Util.shorten("abcdef", 5), "Long ASCII is cut")
assertEqual("Tiếng…", Util.shorten("Tiếng Việt dài", 6), "Multibyte cut on character boundary")
assertEqual("Chương", Util.shorten("Chương", 6), "Multibyte exact limit")
assertEqual("", Util.shorten(nil, 24), "Nil becomes empty")
local long_name = "Jeff Johnson - Designing with the Mind in Mind Simple Guide to Understanding User Interface"
assertEqual(24, select(2, Util.shorten(long_name, 24):gsub("[%z\1-\127\194-\244][\128-\191]*", "")),
    "Result has at most the limit characters")

print(string.format("Shorten tests passed: %d assertions", tests_run))
