local Blitbuffer = require("ffi/blitbuffer")
local InfoMessage = require("ui/widget/infomessage")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")

local source = debug.getinfo(1, "S").source:sub(2)
local directory = assert(source:match("^(.*[/\\])"), "Cannot locate plugin")
local Core = dofile(directory .. "core.lua")

local LiveTint = WidgetContainer:extend{
    name = "segmenttintlive",
    is_doc_only = true,
    enabled = false,
    period = 48,
    mask = nil,
    page_phase_cache = nil,
    layout_cache = nil,
    last_error = nil,
}

function LiveTint:init()
    -- onReadSettings loads these from the current book's sidecar file.
    self.enabled = false
    self.period = 48
    self.page_phase_cache = {}
    self.layout_cache = {}
    self.ui.menu:registerToMainMenu(self)
end

function LiveTint:onReadSettings(config)
    self.enabled = config:isTrue("segment_tint_live_enabled")
    local period = tonumber(config:readSetting("segment_tint_live_period"))
    self.period = period == 96 and 96 or 48
end

function LiveTint:onSaveSettings()
    self:_save()
end

function LiveTint:_supportedDocument()
    return self.ui and self.ui.document and self.ui.document.provider == "crengine"
end

function LiveTint:_save()
    -- doc_settings belongs to the currently open book, so enabling the
    -- gradient here cannot silently enable it in other books.
    if not self.ui or not self.ui.doc_settings then return end
    self.ui.doc_settings:saveSetting("segment_tint_live_enabled", self.enabled)
    self.ui.doc_settings:saveSetting("segment_tint_live_period", self.period)
end

function LiveTint:_redraw()
    self.last_error = nil
    self.page_phase_cache = {}
    self.layout_cache = {}
    if self.view and self.view.dialog then
        UIManager:setDirty(self.view.dialog, "full")
    end
end

function LiveTint:_setEnabled(enabled)
    self.enabled = enabled and true or false
    self:_save()
    self:_redraw()
end

function LiveTint:_setPeriod(period)
    self.period = period == 96 and 96 or 48
    self:_save()
    self:_redraw()
end

function LiveTint:addToMainMenu(menu_items)
    menu_items.segment_tint_live = {
        text = _("循彩阅读"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("启用（不修改原书）"),
                checked_func = function() return self.enabled end,
                enabled_func = function() return self:_supportedDocument() end,
                callback = function() self:_setEnabled(not self.enabled) end,
            },
            {
                text = _("标准 48 字（默认）"),
                checked_func = function() return self.period == 48 end,
                callback = function() self:_setPeriod(48) end,
            },
            {
                text = _("舒缓 96 字"),
                checked_func = function() return self.period == 96 end,
                callback = function() self:_setPeriod(96) end,
            },
            {
                text = _("状态与限制"),
                keep_menu_open = true,
                callback = function()
                    local state = self.enabled and _("已启用") or _("未启用")
                    local detail = self.last_error and ("\n\n" .. _("最近错误：") .. self.last_error) or ""
                    UIManager:show(InfoMessage:new{
                        text = state .. "\n" .. _("目标版本：KOReader 2026.07.2")
                            .. "\n" .. _("开关和渐变周期只对当前这本书生效。")
                            .. "\n" .. _("原 EPUB 不会被修改。插件按页面文字框实时着色；比例字体与复杂排版仍需更多设备验证。")
                            .. detail,
                    })
                end,
            },
        },
    }
end

function LiveTint:_installColorRefreshHook()
    if self._original_view_paint or not self.view then return end
    self._original_view_paint = self.view.paintTo
    local plugin = self
    self._view_paint_wrapper = function(view, bb, x, y)
        plugin._original_view_paint(view, bb, x, y)
        if plugin.enabled and plugin._painted_this_frame then
            -- ReaderView sets this after view modules have painted. Set it once
            -- more so Kaleido devices request a color-capable waveform.
            view.dialog.dithered = true
        end
        plugin._painted_this_frame = false
    end
    self.view.paintTo = self._view_paint_wrapper
end

function LiveTint:onReaderReady()
    self.view = self.ui.view
    self.view:registerViewModule("segment_tint_live", self)
    self:_installColorRefreshHook()
end

function LiveTint:_baseIndexForXPointer(current_xp)
    if not current_xp then return 0 end
    local cached = self.page_phase_cache[current_xp]
    if cached ~= nil then return cached end
    local first_xp = self.ui.document:getPageXPointer(1)
    if not first_xp then return 0 end
    local text = self.ui.document:getTextFromXPointers(first_xp, current_xp)
    local index = text and Core.count(text) or 0
    self.page_phase_cache[current_xp] = index
    return index
end

function LiveTint:_layoutForCurrentView()
    local document = self.ui.document
    local view_xp = document:getXPointer() or tostring(self.ui:getCurrentPage())
    local cached = self.layout_cache[view_xp]
    if cached then return cached end

    local visible = document:getTextFromPositions(
        { x = 0, y = 0 },
        { x = Screen:getWidth(), y = Screen:getHeight() },
        true)
    if not visible or not visible.sboxes then return nil end

    local lines = {}
    local first_pos
    for _, box in ipairs(visible.sboxes) do
        if box.w > 0 and box.h > 0 then
            local middle_y = box.y + math.floor(box.h / 2)
            local line = document:getTextFromPositions(
                { x = box.x, y = middle_y },
                { x = box.x + box.w, y = middle_y },
                true)
            if line and line.text and Core.count(line.text) > 0 then
                first_pos = first_pos or line.pos0
                lines[#lines + 1] = {
                    {
                        x0 = box.x,
                        y0 = box.y,
                        x1 = box.x + box.w,
                        y1 = box.y + box.h,
                        word = line.text,
                    },
                }
            end
        end
    end

    local layout = { lines = lines, first_pos = first_pos }
    -- Only the current view is useful; discard old screen-coordinate layouts.
    self.layout_cache = { [view_xp] = layout }
    return layout
end

function LiveTint:_ensureMask(source_bb)
    local width, height = source_bb:getWidth(), source_bb:getHeight()
    if self.mask and (self.mask:getWidth() ~= width or self.mask:getHeight() ~= height) then
        self.mask:free()
        self.mask = nil
    end
    if not self.mask then
        self.mask = Blitbuffer.new(width, height, Blitbuffer.TYPE_BB8)
    end
    return self.mask
end

function LiveTint:_paintLive(bb)
    if not self.enabled or not self:_supportedDocument() then return end
    local source_bb = self.ui.document.buffer
    if not source_bb then return end
    local layout = self:_layoutForCurrentView()
    if not layout or #layout.lines == 0 then return end

    local mask = self:_ensureMask(source_bb)
    mask:blitFrom(source_bb, 0, 0, 0, 0, source_bb:getWidth(), source_bb:getHeight())
    mask:invertRect(0, 0, mask:getWidth(), mask:getHeight())

    local fragments = Core.fragments(layout.lines,
        self:_baseIndexForXPointer(layout.first_pos), self.period)
    for _, fragment in ipairs(fragments) do
        local color = Blitbuffer.colorFromString(fragment.color)
        bb:colorblitFromRGB32(mask,
            fragment.x, fragment.y,
            fragment.x, fragment.y,
            fragment.w, fragment.h,
            color)
    end
    if #fragments > 0 then self._painted_this_frame = true end
end

function LiveTint:paintTo(bb)
    local ok, err = pcall(self._paintLive, self, bb)
    if not ok then
        self.last_error = tostring(err)
        self.enabled = false
        self:_save()
        logger.err("SegmentTintLive disabled after paint error:", err)
    end
end

function LiveTint:onDocumentRerendered()
    self.page_phase_cache = {}
    self.layout_cache = {}
end

function LiveTint:onChangeViewMode()
    -- Page and continuous mode may keep the same top XPointer while changing
    -- every screen coordinate. Never reuse page-mode boxes in scroll mode.
    self:_redraw()
end

function LiveTint:onCloseWidget()
    if self.view then
        self.view.view_modules["segment_tint_live"] = nil
        if self._view_paint_wrapper and self.view.paintTo == self._view_paint_wrapper then
            self.view.paintTo = self._original_view_paint
        end
    end
    if self.mask then
        self.mask:free()
        self.mask = nil
    end
end

return LiveTint
