local root = "."
package.path = table.concat({
    root .. "/truyenviet.koplugin/?.lua",
    root .. "/truyenviet.koplugin/?/init.lua",
    package.path,
}, ";")

local actions = {}
package.preload["dispatcher"] = function()
    return {
        registerAction = function(_, name, value)
            actions[name] = value
        end,
    }
end

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WidgetContainer = {}
    function WidgetContainer:extend(definition)
        return definition
    end
    return WidgetContainer
end

package.preload["truyenviet/browser"] = function() return {} end
package.preload["truyenviet/reader"] = function() return {} end
package.preload["truyenviet/version"] = function() return "test" end

local Plugin = require("main")
Plugin:onDispatcherRegisterActions()

-- Same rule as KOReader's Dispatcher:isActionEnabled (v2026.07.1).
local function isEnabled(action, context)
    local disabled
    if context == "paging" then
        disabled = action.rolling
    elseif context == "rolling" then
        disabled = action.paging
    else
        disabled = action.reader or action.rolling or action.paging
    end
    return not disabled
end

local passed = 0
local function check(condition, message)
    assert(condition, message)
    passed = passed + 1
end

local everywhere = {
    "start_truyenviet",
    "truyenviet_continue",
    "truyenviet_history",
    "truyenviet_downloaded",
    "truyenviet_gdrive_download",
    "truyenviet_check_update",
}
local reader_only = {
    "truyenviet_chapter_list",
    "truyenviet_next_chapter",
    "truyenviet_prev_chapter",
    "truyenviet_story_page",
}

for _, name in ipairs(everywhere) do
    local action = actions[name]
    check(action ~= nil, name .. " must be registered")
    check(action.general == true, name .. " must stay in the General section")
    check(action.filemanager == true, name .. " must stay in the File browser section")
    for _, context in ipairs({ "filemanager", "paging", "rolling" }) do
        check(isEnabled(action, context), name .. " must run in " .. context)
    end
end

for _, name in ipairs(reader_only) do
    local action = actions[name]
    check(action ~= nil, name .. " must be registered")
    check(action.reader == true, name .. " needs an open chapter, keep it reader-only")
    check(isEnabled(action, "paging") and isEnabled(action, "rolling"), name .. " must run in the reader")
end

local count = 0
for _ in pairs(actions) do count = count + 1 end
check(count == #everywhere + #reader_only, "unexpected action count " .. count)

print(string.format("dispatcher_actions_test: %d checks passed", passed))
