local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local ListView = require("ui/widget/listview")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local Storage = require("truyenviet/storage")
local Windows = require("truyenviet/windows")

local Screen = Device.screen
local Input = Device.input

local StoryItem = InputContainer:extend{
    width = nil,
    height = nil,
    story = nil,
    callback = nil,
    hold_callback = nil,
}

function StoryItem:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    local padding = Size.padding.default
    local border = Size.border.thin
    local cover_height = math.max(self.height - (padding + border) * 2, 1)
    local cover_width = math.max(math.floor(cover_height * 0.68), 1)
    local text_width = math.max(
        self.width - cover_width - padding * 4 - border * 2,
        1
    )
    local source_height = math.min(
        Screen:scaleBySize(24),
        math.max(self.height - padding * 3, 1)
    )

    local cover_widget
    if self.story.cover_path then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(self.story.cover_path, "mode") ~= "file" then
            self.story.cover_path = nil
        end
    end
    if self.story.cover_path then
        local ok
        ok, cover_widget = pcall(function()
            return ImageWidget:new{
                file = self.story.cover_path,
                width = cover_width,
                height = cover_height,
                scale_factor = 0,
            }
        end)
        if not ok or not cover_widget then
            cover_widget = nil
            os.remove(self.story.cover_path)
            self.story.cover_path = nil
        end
    end
local FontHelper = require("truyenviet/font_helper")

    if not cover_widget then
        cover_widget = FrameContainer:new{
            width = cover_width,
            height = cover_height,
            CenterContainer:new{
                dimen = Geom:new{ w = cover_width, h = cover_height },
                TextWidget:new{
                    text = "No Cover",
                    face = FontHelper:getFace("smallinfofont", 16),
                    max_width = cover_width,
                }
            }
        }
    end

    self.source_widget = TextWidget:new{
        text = self:getSourceText(),
        face = FontHelper:getFace("xx_smallinfofont"),
        max_width = text_width,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        TextWidget:new{
            text = self.story.title,
            face = FontHelper:getFace("smallinfofont", 22),
            bold = true,
            max_width = text_width,
        },
        VerticalSpan:new{ width = padding },
        self.source_widget,
    }
    local detail = self:getDetailText()
    if detail then
        table.insert(text_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(text_group, TextWidget:new{
            text = detail,
            face = FontHelper:getFace("xx_smallinfofont"),
            max_width = text_width,
        })
    end
    local row = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = cover_width, h = cover_height },
            cover_widget,
        },
        HorizontalSpan:new{ width = padding * 2 },
        LeftContainer:new{
            dimen = Geom:new{ w = text_width, h = cover_height },
            text_group,
        },
    }
    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        padding = padding,
        margin = 0,
        bordersize = border,
        background = Blitbuffer.COLOR_WHITE,
        row,
    }

    if Device:isTouchDevice() then
        self.ges_events.TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
        self.ges_events.HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        }
    end
end

local function numberLabel(value)
    return value % 1 == 0 and string.format("%d", value) or tostring(value)
end

-- Phần "Đã tải X/N" của Tủ truyện (story.offline_count chỉ có ở Tủ truyện).
local function offlineText(story)
    if story.kind == "local" then
        local files = tonumber(story.offline_count)
        if story.local_type == "dir" then
            return string.format("Trên máy · %d tập", files or 0)
        elseif not story.local_type then
            -- Lịch sử đọc: chưa kiểm tra file nên không ghi loại.
            return "Trên máy"
        end
        return "Trên máy · " .. tostring(story.local_type):upper()
    end
    local downloaded = tonumber(story.offline_count) or 0
    if downloaded <= 0 then
        return " · Chưa tải"
    end
    local total = tonumber(story.chapter_count)
    if not total or total <= 0 then
        total = tonumber(story.latest_chapter)
    end
    if total and total > 0 then
        -- Chương lẻ (411.1, 411.2...) làm số chương đã tải vượt số chương mới nhất.
        if downloaded > total then
            return " · Đã tải hết"
        end
        return string.format(" · Đã tải %d/%s", downloaded, numberLabel(total))
    end
    return string.format(" · Đã tải %d chương", downloaded)
end

function StoryItem:getSourceText()
    if self.story.kind == "local" then
        return offlineText(self.story)
    end
    local in_library = self.story.offline_count ~= nil
    -- Mọi mục trong Tủ truyện đều là yêu thích nên không cần dấu sao.
    local favorite = not in_library and Storage:isFavorite(self.story) and "  ★" or ""
    -- Ưu tiên "Chương N" (chương mới nhất); nguồn chỉ biết tổng thì hiện
    -- "N chương".
    local latest = tonumber(self.story.latest_chapter)
    local chapter_count = tonumber(self.story.chapter_count)
    local progress = ""
    if latest and latest > 0 then
        progress = " · Chương " .. numberLabel(latest)
    elseif chapter_count and chapter_count > 0 then
        progress = string.format(" · %d chương", chapter_count)
    end
    if self.story.completed then
        progress = progress .. " · Hoàn thành"
    end
    if in_library then
        progress = progress .. offlineText(self.story)
    end
    return tostring(self.story.source_name or self.story.source_id)
        .. progress .. favorite
end

-- Dòng 3: chương đọc cuối ở Lịch sử đọc (reading_chapter), dung lượng file
-- trên máy ở Tủ truyện (size_bytes do annotate tính).
function StoryItem:getDetailText()
    local reading = self.story.reading_chapter
    if type(reading) == "string" and reading ~= "" then
        return "Đang đọc: " .. reading
    end
    local size_bytes = tonumber(self.story.size_bytes)
    if size_bytes and size_bytes > 0 then
        local LocalLibrary = require("truyenviet/local_library")
        return "Dung lượng: " .. LocalLibrary.formatSize(size_bytes)
    end
    return nil
end

function StoryItem:refreshFavorite()
    self.source_widget:setText(self:getSourceText())
end

function StoryItem:onTapSelect()
    if self.callback then
        self.callback()
    end
    return true
end

function StoryItem:onHoldSelect()
    if self.hold_callback then
        self.hold_callback()
    end
    return true
end

local StoryResults = InputContainer:extend{
    title = "",
    subtitle = nil,
    stories = nil,
    story_callback = nil,
    story_hold_callback = nil,
    on_return_callback = nil,
    search_callback = nil,
    genres_callback = nil,
    filter_callback = nil,
    server_page = nil,
    server_total_pages = nil,
    server_prev_callback = nil,
    server_next_callback = nil,
}

function StoryResults:init()
    Windows.track(self)
    self.width = Screen:getWidth()
    self.height = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.story_items = {}

    self.title_bar = TitleBar:new{
        width = self.width,
        fullscreen = true,
        title = self.title,
        subtitle = self.subtitle,
        left_icon = "chevron.left",
        left_icon_tap_callback = function()
            self:onClose()
        end,
        right_icon = self.right_icon or (self.search_callback and "appbar.search" or nil),
        right_icon_tap_callback = function()
            if self.right_icon_tap_callback then
                self.right_icon_tap_callback(self)
            elseif self.search_callback then
                self.search_callback()
            end
        end,
        with_bottom_line = true,
    }

    if self.server_page then
        local genre_width = math.floor(self.width * 2 / 5)
        local control_width = math.floor((self.width - genre_width) / 3)
        self.genre_button = Button:new{
            text = self.filter_callback and "Lọc & Thể loại" or "Thể loại",
            width = genre_width,
            callback = function()
                if self.filter_callback then
                    self.filter_callback()
                elseif self.genres_callback then
                    self.genres_callback()
                end
            end,
        }
        self.previous_button = Button:new{
            text = "‹",
            width = control_width,
            callback = function()
                if self.server_prev_callback then
                    self.server_prev_callback()
                end
            end,
        }
        self.page_button = Button:new{
            text = string.format(
                "%d/%d",
                self.server_page,
                self.server_total_pages or self.server_page
            ),
            width = control_width,
            enabled = false,
        }
        self.next_button = Button:new{
            text = "›",
            width = self.width - genre_width - control_width * 2,
            callback = function()
                if self.server_next_callback then
                    self.server_next_callback()
                end
            end,
        }
        self.previous_button:enableDisable(self.server_page > 1)
        self.next_button:enableDisable(
            self.server_page < (self.server_total_pages or self.server_page)
        )
        self.footer = HorizontalGroup:new{
            self.genre_button,
            self.previous_button,
            self.page_button,
            self.next_button,
        }
    else
        local button_width = math.floor(self.width / 4)
        self.previous_button = Button:new{
            text = "‹",
            width = button_width,
            callback = function()
                self.list:prevPage()
            end,
        }
        self.page_button = Button:new{
            text = "1 / 1",
            width = self.width - button_width * 2,
            enabled = false,
        }
        self.next_button = Button:new{
            text = "›",
            width = button_width,
            callback = function()
                self.list:nextPage()
            end,
        }
        self.footer = HorizontalGroup:new{
            self.previous_button,
            self.page_button,
            self.next_button,
        }
    end
    local list_height = self.height
        - self.title_bar:getSize().h
        - self.footer:getSize().h
    list_height = math.max(list_height, 1)
    local item_height = math.max(
        math.min(Screen:scaleBySize(116), list_height),
        1
    )

    local items = {}
    for _, story in ipairs(self.stories or {}) do
        local current_story = story
        local item
        item = StoryItem:new{
            width = self.width,
            height = item_height,
            story = current_story,
            callback = function()
                if self.story_callback then
                    self.story_callback(current_story)
                end
            end,
            hold_callback = function()
                if self.story_hold_callback then
                    self.story_hold_callback(current_story, item)
                end
            end,
        }
        table.insert(items, item)
        table.insert(self.story_items, item)
    end

    self.list = ListView:new{
        padding = 0,
        items = items,
        width = self.width,
        height = list_height,
        item_height = item_height,
        page_update_cb = function(current_page, total_pages)
            total_pages = math.max(total_pages, 1)
            if self.server_page then
                self.title_bar:setSubTitle(string.format(
                    "Trang web %d/%d · danh sách %d/%d",
                    self.server_page,
                    self.server_total_pages or self.server_page,
                    current_page,
                    total_pages
                ), true)
            else
                self.page_button:setText(
                    string.format("%d / %d", current_page, total_pages),
                    self.page_button.width
                )
                self.previous_button:enableDisable(current_page > 1)
                self.next_button:enableDisable(current_page < total_pages)
            end
            UIManager:setDirty(self, "ui")
        end,
    }
    self:showStoryPage(self.focus_story)

    self[1] = FrameContainer:new{
        padding = 0,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.title_bar,
            self.list,
            self.footer,
        },
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Input.group.Back } }
        self.key_events.NextPage = { { Input.group.PgFwd } }
        self.key_events.PrevPage = { { Input.group.PgBack } }
    end
end

function StoryResults:refreshFavorites()
    for _, item in ipairs(self.story_items) do
        item:refreshFavorite()
    end
    UIManager:setDirty(self, "ui")
end

local function isSameStory(left, right)
    return left == right
        or (
            left
            and right
            and left.source_id == right.source_id
            and left.url == right.url
        )
end

function StoryResults:removeStory(story)
    local item_index
    for index, item in ipairs(self.story_items) do
        if isSameStory(item.story, story) then
            item_index = index
            break
        end
    end
    if not item_index then
        return false
    end

    table.remove(self.story_items, item_index)
    table.remove(self.list.items, item_index)
    for index, current_story in ipairs(self.stories) do
        if isSameStory(current_story, story) then
            table.remove(self.stories, index)
            break
        end
    end

    local total_pages = math.max(
        math.ceil(#self.list.items / self.list.items_per_page),
        1
    )
    self.list.show_page = math.min(self.list.show_page, total_pages)
    self.list:_populateItems()
    UIManager:setDirty(self, "ui")
    return true
end

-- Chuyển tới trang chứa truyện (truyện vừa mở) khi quay lại danh sách.
function StoryResults:showStoryPage(story)
    local per_page = self.list and self.list.items_per_page
    if not story or not per_page or per_page < 1 then
        return false
    end
    for index, item in ipairs(self.story_items) do
        if isSameStory(item.story, story) then
            local page = math.ceil(index / per_page)
            if page ~= self.list.show_page then
                self.list.show_page = page
                self.list:_populateItems()
            end
            return true
        end
    end
    return false
end

function StoryResults:onNextPage()
    self.list:nextPage()
    return true
end

function StoryResults:onPrevPage()
    self.list:prevPage()
    return true
end

function StoryResults:onClose()
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

function StoryResults:onCloseWidget()
    Windows.untrack(self)
    if InputContainer.onCloseWidget then
        return InputContainer.onCloseWidget(self)
    end
end

-- Công khai StoryItem để spec kiểm tra định dạng dòng phụ (nguồn · số chương · trạng thái)
StoryResults.StoryItem = StoryItem

return StoryResults
