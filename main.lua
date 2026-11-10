--[[--
Quick panel: an Android-style quick settings sheet.
Swipe down from the top of the screen to open it; tap the top still opens the normal menu.
--]]--

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local lfs = require("libs/libkoreader-lfs")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local Screen = Device.screen

local QuickPanel = WidgetContainer:extend{
    name = "quickpanel",
    is_doc_only = false,
}

local function enabled()
    return G_reader_settings:nilOrTrue("quickpanel_swipe")
end

function QuickPanel:onDispatcherRegisterActions()
    Dispatcher:registerAction("quickpanel_show",
        {category="none", event="ShowQuickPanel", title=_("Quick panel"), general=true})
end

function QuickPanel:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:registerSwipe()
    -- FileManagerMenu registers its zones after plugins load: register again afterwards
    UIManager:nextTick(function() self:registerSwipe() end)
end

-- ReaderMenu (re)registers its touch zones in onReaderReady, which drops our
-- override ordering, so register again once the reader is ready.
function QuickPanel:onReaderReady()
    self:registerSwipe()
end

function QuickPanel:registerSwipe()
    if not Device:isTouchDevice() then return end
    local handler = function(ges)
        if enabled() and ges.direction == "south" then
            -- a pan fires many times while the finger moves: open only once
            if not self._qp_dialog then
                self:onShowQuickPanel()
            end
            return true
        end
    end
    local overrides = {
        swipe = { "readermenu_swipe", "readermenu_ext_swipe", "filemanager_swipe", "filemanager_ext_swipe" },
        pan = { "readermenu_pan", "readermenu_ext_pan", "filemanager_pan", "filemanager_ext_pan" },
    }
    local zones = {}
    for _, area in ipairs({ "DTAP_ZONE_MENU", "DTAP_ZONE_MENU_EXT" }) do
        local z = G_defaults:readSetting(area)
        for _, ges in ipairs({ "swipe", "pan" }) do
            table.insert(zones, {
                id = "quickpanel_" .. ges .. (area == "DTAP_ZONE_MENU_EXT" and "_ext" or ""),
                ges = ges,
                screen_zone = { ratio_x = z.x, ratio_y = z.y, ratio_w = z.w, ratio_h = z.h },
                overrides = overrides[ges],
                handler = handler,
            })
        end
    end
    -- ReaderMenu registers its zones on the ReaderUI, FileManagerMenu on itself:
    -- ours must live on the same widget to be ordered before them.
    local target = self.ui.document and self.ui or (self.ui.menu or self.ui)
    target:registerTouchZones(zones)
end

function QuickPanel:addToMainMenu(menu_items)
    menu_items.quickpanel = {
        text = _("Quick panel"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Open quick panel"),
                callback = function() self:onShowQuickPanel() end,
            },
            {
                text = _("Swipe down from top opens quick panel"),
                checked_func = enabled,
                callback = function()
                    G_reader_settings:flipNilOrTrue("quickpanel_swipe")
                end,
            },
        },
    }
end

-- helpers ---------------------------------------------------------------

local function powerd() return Device:getPowerDevice() end

local function flText()
    if not Device:hasFrontlight() then return "Đèn: không có" end
    local p = powerd()
    if not p:isFrontlightOn() then return "Đèn: tắt" end
    return string.format("Đèn %d/%d", p:frontlightIntensity(), p.fl_max)
end

local function statusText()
    local p = powerd()
    local parts = { os.date("%H:%M") }
    local ok, cap = pcall(function() return p:getCapacity() end)
    if ok and cap then
        local charging = p:isCharging() and " (đang sạc)" or ""
        table.insert(parts, string.format("Pin %d%%%s", cap, charging))
    end
    if Device:hasWifiToggle() then
        table.insert(parts, NetworkMgr:isWifiOn() and "Wi-Fi bật" or "Wi-Fi tắt")
    end
    return table.concat(parts, "   ·   ")
end

function QuickPanel:run(action, value)
    -- close first so the action's own dialogs appear on a clean screen
    if self._qp_dialog then
        UIManager:close(self._qp_dialog)
        self._qp_dialog = nil
    end
    UIManager:nextTick(function()
        Dispatcher:execute({ [action] = value == nil and true or value })
    end)
end

function QuickPanel:stepLight(delta)
    local p = powerd()
    local step = math.max(1, math.floor(p.fl_max / 12))
    local cur = p:isFrontlightOn() and p:frontlightIntensity() or 0
    local new = math.max(p.fl_min or 0, math.min(p.fl_max, cur + delta * step))
    p:setIntensity(new)
    self:refreshLightButton()
end

function QuickPanel:refreshLightButton()
    if not self._qp_dialog then return end
    local btn = self._qp_dialog:getButtonById("ql_light")
    if btn then
        btn:setText(flText(), btn.width)
        UIManager:setDirty(self._qp_dialog, "ui", btn.dimen)
    end
end

-- KOReader crashes on "open previous document" when there is none, so check first.
function QuickPanel:openPrevious()
    local prev
    if self.ui.document then
        prev = self.ui.menu and self.ui.menu.getPreviousFile and self.ui.menu:getPreviousFile()
    else
        prev = G_reader_settings:readSetting("lastfile")
    end
    if prev and lfs.attributes(prev, "mode") == "file" then
        self:run("open_previous_document")
    else
        if self._qp_dialog then UIManager:close(self._qp_dialog) end
        UIManager:show(InfoMessage:new{ text = "Chưa có sách nào khác để mở lại.", timeout = 2 })
    end
end

-- panel -----------------------------------------------------------------

function QuickPanel:onShowQuickPanel()
    if self._qp_dialog then
        UIManager:close(self._qp_dialog)
        self._qp_dialog = nil
    end
    local in_reader = self.ui.document ~= nil
    local h = Screen:scaleBySize(62)
    local function b(text, cb, id)
        return { text = text, callback = cb, height = h, id = id }
    end

    local rows = {}
    if Device:hasFrontlight() then
        table.insert(rows, {
            b("Tối hơn", function() self:stepLight(-1) end),
            b(flText(), function()
                powerd():toggleFrontlight()
                UIManager:nextTick(function() self:refreshLightButton() end)
            end, "ql_light"),
            b("Sáng hơn", function() self:stepLight(1) end),
        })
    end
    table.insert(rows, {
        b(NetworkMgr:isWifiOn() and "Wi-Fi: bật" or "Wi-Fi: tắt", function() self:run("toggle_wifi") end),
        b(G_reader_settings:isTrue("night_mode") and "Ban đêm: bật" or "Ban đêm: tắt", function() self:run("night_mode") end),
        b("Làm mới màn", function() self:run("full_refresh") end),
    })
    if in_reader then
        table.insert(rows, {
            b("Mục lục", function() self:run("toc") end),
            b("Chữ nhỏ hơn", function() self:run("decrease_font", 1) end),
            b("Chữ to hơn", function() self:run("increase_font", 1) end),
        })
    end
    table.insert(rows, {
        b("Lịch sử", function() self:run("history") end),
        b("Sách vừa đọc", function() self:openPrevious() end),
        b("Calibre", function() self:run("calibre_start_connection") end),
    })
    table.insert(rows, {
        b("Xoay màn", function() self:run("iterate_rotation") end),
        b("Menu đầy đủ", function() self:run("show_menu") end),
        b("Ngủ", function() self:run("suspend") end),
    })
    table.insert(rows, {
        b("Thoát KOReader", function() self:run("exit") end),
    })

    self._qp_dialog = ButtonDialog:new{
        title = statusText(),
        title_align = "center",
        width = Screen:getWidth(),
        buttons = rows,
        anchor = function()
            return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = 0 }, true
        end,
        tap_close_callback = function() self._qp_dialog = nil end,
    }
    -- The finger is still moving when the panel appears: without this, the rest of
    -- the pan drags the panel down (MovableContainer) and repaints it many times,
    -- which is slow over images. Make it fixed and swallow the rest of the gesture.
    local d = self._qp_dialog
    if d.movable then d.movable.ges_events = {} end
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    d.ges_events.QPSwallow = {
        GestureRange:new{ ges = "pan", range = full },
        GestureRange:new{ ges = "swipe", range = full },
        GestureRange:new{ ges = "pan_release", range = full },
    }
    d.onQPSwallow = function() return true end
    local orig_close = self._qp_dialog.onCloseWidget
    self._qp_dialog.onCloseWidget = function(this)
        self._qp_dialog = nil
        if orig_close then return orig_close(this) end
    end
    UIManager:show(self._qp_dialog)
    return true
end

return QuickPanel
