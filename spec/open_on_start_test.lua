local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

package.preload["dispatcher"] = function()
    return { registerAction = function() end }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_, definition) return definition end }
end

local show_root_count = 0
package.preload["truyenviet/browser"] = function()
    return { showRoot = function() show_root_count = show_root_count + 1 end }
end
package.preload["truyenviet/reader"] = function() return {} end
package.preload["truyenviet/version"] = function() return "test" end

local open_on_start = false
package.preload["truyenviet/storage"] = function()
    return {
        isOpenOnStartEnabled = function() return open_on_start end,
        setOpenOnStartEnabled = function(_, enabled) open_on_start = enabled == true end,
    }
end

local ticks = {}
package.preload["ui/uimanager"] = function()
    return { nextTick = function(_, callback) table.insert(ticks, callback) end }
end

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

local function freshPlugin()
    package.loaded["main"] = nil
    ticks = {}
    show_root_count = 0
    return require("main")
end

local function runTicks()
    for _, callback in ipairs(ticks) do
        callback()
    end
end

-- Off by default: nothing opens.
local Plugin = freshPlugin()
Plugin:openOnStart()
runTicks()
check(show_root_count == 0, "stays closed when the option is off")

-- On: opens once on the next tick, after KOReader has shown History on top.
open_on_start = true
Plugin = freshPlugin()
Plugin:openOnStart()
check(show_root_count == 0, "waits for the next tick")
runTicks()
check(show_root_count == 1, "opens Truyện Việt at startup")

-- Later FileManager/ReaderUI instances in the same run do not reopen it.
ticks = {}
Plugin:openOnStart()
runTicks()
check(show_root_count == 1, "opens only once per KOReader start")

-- Menu toggle reflects and flips the saved option.
local menu_items = {}
Plugin.addToMainMenu({ ui = { name = "FileManager" } }, menu_items)
local toggle
for _, item in ipairs(menu_items.truyenviet.sub_item_table) do
    if item.text == "Mở Truyện Việt khi khởi động KOReader" then
        toggle = item
    end
end
check(toggle ~= nil, "menu has the startup toggle")
check(toggle.checked_func() == true, "toggle shows the option is on")
toggle.callback()
check(open_on_start == false and toggle.checked_func() == false, "toggle turns the option off")
toggle.callback()
check(open_on_start == true, "toggle turns the option back on")

print(string.format("open_on_start_test: %d checks passed", passed))
