--[[--
设置界面：组件自己的设置（首页编辑态的齿轮）+ 月读设置页里的两行入口（底栏图标 / 组件背景）。

都是月读自己的控件（List、PathPicker、Spin、Row），选完写扩展配置、落盘、重画。

@module moonbeautify.settings
--]]

local lfs = require("libs/libkoreader-lfs")
local UIManager = require("ui/uimanager")
local List = require("ui.themes.widgets.list")
local Row = require("ui.themes.widgets.row")
local Button = require("ui.themes.widgets.button")
local UITheme = require("ui.themes")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Spin = require("ui.themes.widgets.spin")
local Input = require("ui.themes.widgets.input")
local Overlay = require("desktop.pages.setting.overlay")
local Image = require("utils.image")
local _ = require("gettext")
-- gettext 的 %1 占位符只有 template 认识，string.format 会报 invalid option '%1'
local T = require("ffi/util").template

local Store = require("moonbeautify.store")

local Settings = {}

--- 选完设置重画首页（桌面还在就整屏刷一次）
---@param desktop table|nil
local function repaint(desktop)
    if not desktop then return end
    pcall(function() desktop:updateView() end)
    -- desktop:updateView 里已顺带重刷设置页；这里标全屏让整条 window stack 一起重画
    pcall(function() UIManager:setDirty("all", "ui") end)
end

--- 记下配置、落盘、重画
---@param desktop table|nil
---@param key string
---@param value any
local function put(desktop, key, value)
    Store.conf()[key] = value
    Store.save()
    repaint(desktop)
end

--- 弹路径选择器。
---@param desktop table|nil
---@param current string|nil 当前路径（文件或目录）
---@param is_file boolean 选文件 or 选目录
---@param apply fun(path: string)
local function pickPath(desktop, current, is_file, apply)
    local start
    if type(current) == "string" and current ~= "" then
        local dir = is_file and current:match("^(.*)/") or current
        if dir and lfs.attributes(dir, "mode") == "directory" then start = dir end
    end
    -- 自己没配过 → 用上次任意选图器用过的目录（和界面壁纸共用同一份记忆）
    local last = Store.conf().last_dir
    if not start and type(last) == "string" and last ~= "" and lfs.attributes(last, "mode") == "directory" then
        start = last
    end
    start = start or require("apps/filemanager/filemanagerutil").getHomeFolder()
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = is_file,
        filter = is_file and function(name) return Image.suffix(name) ~= nil end or nil,
        on_select = function(path)
            local dir = is_file and path:match("^(.*)/") or path
            if type(dir) == "string" and dir ~= "" and lfs.attributes(dir, "mode") == "directory" then
                Store.conf().last_dir = dir
            end
            apply(path)
            Store.save()
            repaint(desktop)
        end,
    }:show()
end

--- 单选 / 动作弹窗。
---@param title string
---@param items table[]
---@param current any
---@param on_select fun(value: any)
local function choose(title, items, current, on_select)
    List:new{
        title = title,
        items = items,
        current = current,
        centered = true,
        on_select = function(value)
            if value == nil then return end
            on_select(value)
        end,
    }:show()
end

local SIZES = {
    { value = "s", text = _("小") },
    { value = "m", text = _("中") },
    { value = "l", text = _("大") },
}

local SIZE_TEXT = { s = _("小"), m = _("中"), l = _("大") }

---@param conf table
---@param key string
---@return string
local function sizeText(conf, key)
    return SIZE_TEXT[Store.enum(conf, key, { s = true, m = true, l = true }, "m")]
end

--- 特效：细闪 / 雨滴 / 星星（可多选，打开面板会重新弹出来，方便连点）
---@param desktop table|nil
---@param key string 配置键，如 "badge_effects"
local function effectsPage(desktop, key)
    local Effects = require("moonbeautify.effects")
    local cur = Store.conf()[key]
    if type(cur) ~= "table" then cur = {} end
    local items = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        items[#items + 1] = { value = id, text = (cur[id] and "✓ " or "　") .. _(Effects.LABEL[id]) }
    end
    items[#items + 1] = { value = "none", text = _("全部关掉") }
    choose(_("特效"), items, nil, function(v)
        local now = Store.conf()[key]
        if type(now) ~= "table" then now = {} end
        if v == "none" then
            now = {}
        else
            now[v] = (not now[v]) and true or nil
        end
        put(desktop, key, now)
        UIManager:scheduleIn(0.15, function() effectsPage(desktop, key) end)
    end)
end

--- 贴图：把组件均分成 8 份（并排时 4 份），逐格配图
---@param desktop table|nil
---@param key string
---@param i number
local function slotPage(desktop, key, i)
    local map = Store.conf()[key]
    if type(map) ~= "table" then map = {} end
    choose(T(_("第 %1 格"), i), {
        { value = "pick", text = _("选一张图…") },
        { value = "clear", text = _("清空这一格") },
    }, nil, function(v)
        if v == "pick" then
            pickPath(desktop, map[i], true, function(path)
                local now = Store.conf()[key]
                if type(now) ~= "table" then now = {} end
                now[i] = path
                put(desktop, key, now)
            end)
        else
            local now = Store.conf()[key]
            if type(now) == "table" then
                now[i] = nil
                put(desktop, key, now)
            end
        end
    end)
end

---@param desktop table|nil
---@param key string
local function slotsPage(desktop, key)
    local map = Store.conf()[key]
    if type(map) ~= "table" then map = {} end
    local items = {}
    for i = 1, 8 do
        local name = type(map[i]) == "string" and (map[i]:match("([^/]+)$") or map[i]) or _("空")
        -- 格子摆成田字：上排 1–4，下排 5–8。并排（组合）时只显示中间两列，
        -- 四角的 1、4、5、8 不显示，单独一行时才出现
        local edge = (i == 1 or i == 4 or i == 5 or i == 8)
        items[#items + 1] = {
            value = i,
            text = T(_("第 %1 格：%2"), i, name) .. (edge and _("（仅单独一行时显示）") or ""),
        }
    end
    choose(_("贴图（上 4 下 4 共 8 格，并排时只显示中间 4 格）"), items, nil, function(i)
        slotPage(desktop, key, i)
    end)
end

--- 叠加素材：一张带透明通道的 PNG，压在照片上（方形素材会被裁成圆/矩形）
---@param desktop table|nil
---@param key string
local function overlayPage(desktop, key)
    choose(_("叠加素材"), {
        { value = "pick", text = _("选一张透明 PNG…") },
        { value = "clear", text = _("清除") },
    }, nil, function(v)
        if v == "pick" then
            pickPath(desktop, Store.conf()[key], true, function(path) put(desktop, key, path) end)
        else
            put(desktop, key, nil)
        end
    end)
end

--- 图源：固定一张 / 文件夹里挑一张
---@param desktop table|nil
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param title string
local function srcPage(desktop, prefix, title)
    local conf = Store.conf()
    local pick = Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file")
    local items = {
        { value = "how", text = T(_("图片来源：%1"), pick == "folder" and _("文件夹") or _("固定一张")) },
    }
    if pick == "folder" then
        local dir = conf[prefix .. "dir"]
        items[#items + 1] = { value = "dir", text = T(_("文件夹：%1"),
            (type(dir) == "string" and dir ~= "") and (dir:match("([^/]+)$") or dir) or _("未选择")) }
        items[#items + 1] = { value = "mode", text = T(_("换图节奏：%1"),
            Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily") == "shuffle"
                and _("每次刷新随机") or _("每天一张")) }
    else
        local src = conf[prefix .. "src"]
        items[#items + 1] = { value = "file", text = T(_("图片：%1"),
            (type(src) == "string" and src ~= "") and (src:match("([^/]+)$") or src) or _("未选择")) }
    end
    choose(_(title), items, nil, function(v)
        if v == "how" then
            choose(_("图片来源"), {
                { value = "file", text = _("固定一张图") },
                { value = "folder", text = _("文件夹里挑一张") },
            }, pick, function(how) put(desktop, prefix .. "pick", how) end)
        elseif v == "dir" then
            pickPath(desktop, conf[prefix .. "dir"], false, function(path) put(desktop, prefix .. "dir", path) end)
        elseif v == "file" then
            pickPath(desktop, conf[prefix .. "src"], true, function(path) put(desktop, prefix .. "src", path) end)
        elseif v == "mode" then
            choose(_("换图节奏"), {
                { value = "daily", text = _("每天一张") },
                { value = "shuffle", text = _("每次刷新随机") },
            }, Store.enum(conf, prefix .. "mode", { daily = true, shuffle = true }, "daily"),
                function(m) put(desktop, prefix .. "mode", m) end)
        end
    end)
end

--- 特效文字：启用中的特效名字
---@param conf table
---@param key string
---@return string
local function effectsText(conf, key)
    local Effects = require("moonbeautify.effects")
    local t = conf[key]
    if type(t) ~= "table" then return _("无") end
    local out = {}
    for _i, id in ipairs({ "glitter", "rain", "stars" }) do
        if t[id] then out[#out + 1] = _(Effects.LABEL[id]) end
    end
    return #out > 0 and table.concat(out, "·") or _("无")
end

--- 叠加素材文字
---@param conf table
---@param key string
---@return string
local function overlayText(conf, key)
    local p = conf[key]
    if type(p) ~= "string" or p == "" then return _("未设置") end
    return p:match("([^/]+)$") or p
end

--- 外圈文字
---@param conf table
---@param prefix string
---@return string
local function ringText(conf, prefix)
    local v = conf[prefix .. "ring"]
    if v == true then return _("珠链") end
    if type(v) == "string" and v ~= "" then
        return _(require("moonbeautify.badge").RING_LABEL[v] or _("未设置"))
    end
    return _("无")
end

--- 贴图文字
---@param conf table
---@param key string
---@return string
local function slotsText(conf, key)
    local m = conf[key]
    if type(m) ~= "table" then return _("空") end
    local n = 0
    for _k, v in pairs(m) do
        if type(v) == "string" and v ~= "" then n = n + 1 end
    end
    return n > 0 and T(_("%1 格已配图"), n) or _("空")
end

--- 转动只有开 / 关，开就是最快（约 24 秒一圈）
local SPIN_ON = 24

---@param conf table
---@param prefix string
---@return boolean
local function spinning(conf, prefix)
    return (tonumber(conf[prefix .. "spin"]) or 0) > 0
end

--- 从配置前缀还原显示名："badge_" → 吧唧；"badge2_" → 吧唧 2
---@param prefix string
---@return string
local function prefixTitle(prefix)
    local n = tonumber(prefix:match("^badge(%d*)_$") or "")
    if not n or n == 1 then return _("吧唧") end
    return T(_("吧唧 %1"), n)
end

--- 吧唧的设置。每个吧唧实例用 id 前缀区分（badge_ / badge2_ ...），互不影响。
---@param desktop table|nil
---@param prefix string
local function badgeSettings(desktop, prefix)
    local conf = Store.conf()
    local items = {
        { value = "src", text = T(_("图片：%1（固定图 / 文件夹）"),
            Store.enum(conf, prefix .. "pick", { file = true, folder = true }, "file") == "folder"
                and _("文件夹") or _("固定一张")) },
        { value = "shape", text = T(_("形状：%1"),
            ({ circle = _("圆形"), round = _("圆角"), square = _("直角") })[
                Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle")]) },
        { value = "size", text = T(_("尺寸：%1"), sizeText(conf, prefix .. "size")) },
        { value = "effects", text = T(_("特效：%1"), effectsText(conf, prefix .. "effects")) },
        { value = "overlay", text = T(_("叠加素材：%1"), overlayText(conf, prefix .. "overlay")) },
        { value = "ring", text = T(_("光环：%1"), ringText(conf, prefix)) },
        { value = "slots", text = T(_("贴图：%1"), slotsText(conf, prefix .. "slots")) },
        { value = "spin", text = T(_("转动：%1"), spinning(conf, prefix) and _("开") or _("关")) },
    }
    choose(prefixTitle(prefix), items, nil, function(value)
        if value == "src" then
            srcPage(desktop, prefix, prefixTitle(prefix) .. _("图片"))
        elseif value == "shape" then
            choose(_("形状"), {
                { value = "circle", text = _("圆形") },
                { value = "round", text = _("圆角") },
                { value = "square", text = _("直角") },
            }, Store.enum(conf, prefix .. "shape", { circle = true, round = true, square = true }, "circle"),
                function(v) put(desktop, prefix .. "shape", v) end)
        elseif value == "size" then
            choose(_("尺寸"), SIZES,
                Store.enum(conf, prefix .. "size", { s = true, m = true, l = true }, "m"),
                function(v) put(desktop, prefix .. "size", v) end)
        elseif value == "effects" then
            effectsPage(desktop, prefix .. "effects")
        elseif value == "overlay" then
            overlayPage(desktop, prefix .. "overlay")
        elseif value == "ring" then
            choose(_("光环（画在吧唧本体外面的一圈）"), {
                { value = "none", text = _("无") },
                { value = "double", text = _("双线（两条细环）") },
            }, (function()
                local v = conf[prefix .. "ring"]
                -- 旧配置的 true / beads / lace 统一按双线处理
                if v == true or v == "beads" or v == "lace" then return "double" end
                if type(v) == "string" and v ~= "" then return v end
                return "none"
            end)(), function(v)
                put(desktop, prefix .. "ring", v == "none" and nil or v)
            end)
        elseif value == "slots" then
            slotsPage(desktop, prefix .. "slots")
        elseif value == "spin" then
            choose(_("转动"), {
                { value = 0, text = _("关") },
                { value = SPIN_ON, text = _("开") },
            }, spinning(conf, prefix) and SPIN_ON or 0, function(v) put(desktop, prefix .. "spin", v) end)
        end
    end)
end

--- 设置入口（widget.settings(desktop, id)）
---@param prefix string 配置前缀，如 "badge_" / "badge2_"
---@param desktop table|nil
function Settings.show(prefix, desktop)
    return badgeSettings(desktop, prefix)
end

-- 月读设置页入口 ------------------------------------------------------------

--- 底栏格子清单：优先用桌面当前的 Tab，取不到就退回已知 id。
---@param desktop table|nil
---@return table[] {{ id, text }}
local function tabList(desktop)
    local out = {}
    local tabs = desktop and desktop._tabs
    if type(tabs) == "table" then
        for _idx, tab in ipairs(tabs) do
            out[#out + 1] = { id = tab.id, text = tab.text or tab.id, icon = type(tab.icon) == "string" and tab.icon or nil }
        end
    end
    if #out == 0 then
        out = {
            { id = "home", text = _("首页") }, { id = "library", text = _("图书馆") },
            { id = "store", text = _("书城") }, { id = "insight", text = _("统计") },
            { id = "settings", text = _("设置") },
        }
    end
    return out
end

local refreshOverlayPage -- 前置声明，定义在 themePageTable 之后

--- 单个底栏格子的图标：选图 / 恢复默认
---@param desktop table|nil
---@param tab table { id, text }
local function tabIconDialog(desktop, tab)
    local map = Store.conf().tab_icons
    local current = type(map) == "table" and map[tab.id] or nil
    choose(tab.text or tab.id, {
        { value = "pick", text = _("选一张图…") },
        { value = "reset", text = _("恢复默认图标"), enabled = current ~= nil },
    }, nil, function(value)
        if value == "pick" then
            pickPath(desktop, current, true, function(path)
                local conf = Store.conf()
                conf.tab_icons = type(conf.tab_icons) == "table" and conf.tab_icons or {}
                conf.tab_icons[tab.id] = path
                Store.save()
                repaint(desktop)
                refreshOverlayPage(desktop)
            end)
        elseif value == "reset" then
            local conf = Store.conf()
            if type(conf.tab_icons) == "table" then
                conf.tab_icons[tab.id] = nil
                if next(conf.tab_icons) == nil then conf.tab_icons = nil end
                Store.save()
                repaint(desktop)
                refreshOverlayPage(desktop)
            end
        end
    end)
end

--- 组件清单：月读首页注册表（内置 + 扩展）
---@return table[] {{ id, label }}
local function componentList()
    local out = {}
    local ok, list = pcall(function() return require("desktop.pages.home.registry").list() end)
    if ok and type(list) == "table" then
        for _idx, comp in ipairs(list) do
            out[#out + 1] = { id = comp.id, label = comp.label or comp.id }
        end
    end
    return out
end

--- 单个组件的背景：选图 / 不透明度 / 移除
---@param desktop table|nil
---@param comp table { id, label }
local function widgetBgDialog(desktop, comp)
    local conf = Store.conf()
    local all = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local item = all[comp.id]
    local veil = type(item) == "table" and tonumber(item.veil) or 0
    local padMap = type(conf.widget_pad) == "table" and conf.widget_pad or {}
    local pad = tonumber(padMap[comp.id]) or 0
    local Bg = require("moonbeautify.bg")
    local fit = (type(item) == "table" and Bg.MODES[item.fit]) and item.fit or "stretch"
    local fitLabels = {}
    for mode, label in pairs(Bg.MODES) do fitLabels[mode] = label end
    choose(comp.label, {
        { value = "pick", text = _("选一张背景图…") },
        { value = "fit", text = T(_("填充方式：%1"), _(fitLabels[fit])) },
        { value = "veil", text = T(_("内容提亮：%1%"), veil) },
        { value = "pad", text = T(_("内容内边距：%1"), pad > 0 and (pad .. " px") or _("关")) },
        { value = "reset", text = _("移除背景"), enabled = item ~= nil },
    }, nil, function(value)
        local function save(mutate)
            local c = Store.conf()
            c.widget_bg = type(c.widget_bg) == "table" and c.widget_bg or {}
            mutate(c.widget_bg)
            if next(c.widget_bg) == nil then c.widget_bg = nil end
            Store.save()
            repaint(desktop)
        end
        if value == "pick" then
            pickPath(desktop, type(item) == "table" and item.src or nil, true, function(path)
                save(function(bg)
                    bg[comp.id] = bg[comp.id] or {}
                    bg[comp.id].src = path
                end)
            end)
        elseif value == "fit" then
            local items, order = {}, { "stretch", "fill", "fit", "tile" }
            for _i, mode in ipairs(order) do
                items[#items + 1] = { value = mode, text = _(fitLabels[mode]), mandatory = mode == fit and _("当前") or nil }
            end
            choose(_("填充方式"), items, nil, function(mode)
                save(function(bg)
                    bg[comp.id] = bg[comp.id] or {}
                    bg[comp.id].fit = mode
                end)
            end)
        elseif value == "veil" then
            Spin:new{
                title = _("内容提亮"),
                fields = { {
                    value = veil, min = 0, max = 90, step = 10,
                    format = function(v) return v .. "%" end,
                } },
                callback = function(v)
                    save(function(bg)
                        bg[comp.id] = bg[comp.id] or {}
                        bg[comp.id].veil = math.floor(v)
                    end)
                end,
            }:show()
        elseif value == "pad" then
            Spin:new{
                title = _("内容内边距"),
                fields = { {
                    value = pad, min = 0, max = 24, step = 2,
                    format = function(v) return (v <= 0) and _("关") or (v .. " px") end,
                } },
                callback = function(v)
                    local c = Store.conf()
                    c.widget_pad = type(c.widget_pad) == "table" and c.widget_pad or {}
                    local n = math.floor(v)
                    c.widget_pad[comp.id] = n > 0 and n or nil
                    if next(c.widget_pad) == nil then c.widget_pad = nil end
                    Store.save()
                    repaint(desktop)
                end,
            }:show()
        elseif value == "reset" then
            save(function(bg) bg[comp.id] = nil end)
        end
    end)
end

--- 组件背景总入口
---@param desktop table|nil
local function widgetBgPage(desktop)
    local conf = Store.conf()
    local all = type(conf.widget_bg) == "table" and conf.widget_bg or {}
    local items = {}
    for _idx, comp in ipairs(componentList()) do
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = type(all[comp.id]) == "table" and _("已设") or nil,
        }
    end
    choose(_("组件背景"), items, nil, function(id)
        for _i, comp in ipairs(componentList()) do
            if comp.id == id then return widgetBgDialog(desktop, comp) end
        end
    end)
end

--- 轻提示（KOReader 原生 InfoMessage：左侧信息图标，点一下即关，默认 2 秒自动消失）
---@param text string
---@param seconds number|nil
local function themeToast(text, seconds)
    if not text or text == "" then return end
    pcall(function()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = text,
            timeout = seconds or 2,
        })
    end)
end

--- 当前顺序数组：用户配置里还存在的格子按配置排，没配的按默认顺序补在后面
---@param desktop table|nil
---@return string[] id 数组
local function currentTabOrder(desktop)
    local conf = Store.conf()
    local order = type(conf.tab_order) == "table" and conf.tab_order or {}
    local seen, out = {}, {}
    for _idx, id in ipairs(order) do
        if type(id) == "string" and not seen[id] then
            seen[id] = true
            out[#out + 1] = id
        end
    end
    for _idx, tab in ipairs(tabList(desktop)) do
        if not seen[tab.id] then
            seen[tab.id] = true
            out[#out + 1] = tab.id
        end
    end
    return out
end

--- 底栏页的一行：左侧图标（自定义图优先），右侧 设置 / 上移 / 下移，和阅读页底部状态栏同一套交互。
---@param desktop table|nil
---@param tab table { id, text, icon }
---@param order string[]
---@param index integer
---@return fun(iw: number): table
local function tabRow(desktop, tab, order, index)
    return function(iw)
        local map = Store.conf().tab_icons
        local custom = type(map) == "table" and type(map[tab.id]) == "string" and map[tab.id] ~= "" and map[tab.id] or nil
        local size = UITheme.px(36)
        local function arrow(icon, enabled, callback)
            return Button:new{
                icon = icon, variant = "ghost", width = size, height = size,
                enabled = enabled, callback = callback,
            }
        end
        local function shift(delta)
            local to = index + delta
            order[index], order[to] = order[to], order[index]
            Store.conf().tab_order = order
            Store.save()
            repaint(desktop)
            refreshOverlayPage(desktop)
        end
        local trailing = HorizontalGroup:new{
            align = "center",
            arrow("settings", true, function() tabIconDialog(desktop, tab) end),
            HorizontalSpan:new{ width = UITheme.px(4) },
            arrow("arrow_upward", index > 1, function() shift(-1) end),
            HorizontalSpan:new{ width = UITheme.px(4) },
            arrow("arrow_downward", index < #order, function() shift(1) end),
        }
        return Row.widget({
            width = iw,
            chevron = false,
            icon = not custom and (tab.icon or "dashboard") or nil,
            image = custom,
            title = tab.text,
            subtitle = custom and _("自定义图标") or nil,
            status = trailing,
        })
    end
end

--- 底栏页：每个格子一行，设置里换图标，上下箭头调顺序
---@param desktop table|nil
---@return table page
local function tabBarPage(desktop)
    return {
        title = _("底栏"),
        sections = function()
            local order = currentTabOrder(desktop)
            local byId = {}
            for _idx, tab in ipairs(tabList(desktop)) do byId[tab.id] = tab end
            local rows = {}
            for i, id in ipairs(order) do
                rows[#rows + 1] = tabRow(desktop, byId[id] or { id = id, text = id }, order, i)
            end
            local ordered = type(Store.conf().tab_order) == "table" and #Store.conf().tab_order > 0
            return {
                { title = _("图标"), rows = rows },
                { title = _("恢复"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, chevron = false, kind = "action", icon = "restart_alt",
                            title = _("恢复默认顺序"),
                            subtitle = ordered and _("按月读原来的排列") or nil,
                            enabled = ordered,
                            callback = function()
                                Store.conf().tab_order = nil
                                Store.save()
                                repaint(desktop)
                                refreshOverlayPage(desktop)
                                themeToast(_("已恢复默认顺序"))
                            end,
                        })
                    end,
                } },
            }
        end,
    }
end

--- 保存当前配置为主题
---@param desktop table|nil
local function themeSave(desktop)
    local dialog = Input:new{
        title = _("主题名字"),
        fields = { { text = "", hint = _("例如 主题1") } },
        ok_text = _("保存"),
        callback = function(value)
            local Theme = require("moonbeautify.theme")
            local safe = Theme.sanitize(value)
            if not safe then
                themeToast(_("名字不能为空"))
                return
            end
            if lfs.attributes(Theme.root() .. "/" .. safe, "mode") == "directory" then
                themeToast(_("该名称已被占用"))
                return
            end
            local ok, dir_or_err = Theme.save(safe)
            if ok then
                put(desktop, "active_theme", safe)
                refreshOverlayPage(desktop)
                themeToast(T(_("已保存为主题：%1"), safe))
            else
                themeToast(T(_("保存失败：%1"), dir_or_err or ""))
            end
        end,
    }
    -- 选择器关闭动画期间直接开输入框会被顶掉，等下一帧再弹
    local deferred = false
    if UIManager.nextTick then
        deferred = pcall(function()
            UIManager:nextTick(function() dialog:show() end)
        end)
    end
    if not deferred then dialog:show() end
end

--- 从 zip 导入主题
---@param desktop table|nil
local function themeImport(desktop)
    local start = Store.conf().last_dir
    if not (type(start) == "string" and start ~= ""
        and lfs.attributes(start, "mode") == "directory") then
        start = require("apps/filemanager/filemanagerutil").getHomeFolder()
    end
    require("ui.themes.widgets.path_picker"):new{
        path = start,
        select_file = true,
        filter = function(name) return name:lower():match("%.zip$") ~= nil end,
        on_select = function(path)
            local Theme = require("moonbeautify.theme")
            local ok, name_or_err = Theme.importZip(path)
            if ok then
                refreshOverlayPage(desktop)
                themeToast(T(_("已导入主题：%1"), name_or_err))
            else
                themeToast(T(_("导入失败：%1"), name_or_err or ""))
            end
        end,
    }:show()
end

--- 单个主题：应用 / 导出 / 删除
---@param desktop table|nil
---@param name string
---@param active string|nil 当前应用中的主题名
local function themeItem(desktop, name, active)
    local applied = name == active
    choose(name, {
        { value = "apply", text = _("应用"),
          mandatory = applied and _("当前正在使用中") or _("点击应用") },
        { value = "export", text = _("导出主题 zip"),
          mandatory = _("导到指定文件夹") },
        { value = "delete", text = _("删除"),
          mandatory = applied and _("使用中的主题无法删除") or _("删掉存档和图片") },
    }, nil, function(v)
        local Theme = require("moonbeautify.theme")
        if v == "apply" then
            local ok, err = Theme.apply(name)
            if ok then
                refreshOverlayPage(desktop)
                repaint(desktop)
                themeToast(_("已使用该主题"))
            else
                themeToast(T(_("应用失败：%1"), err or ""))
            end
        elseif v == "export" then
            pickPath(desktop, nil, false, function(dir)
                local ok, path_or_err = Theme.export(name, dir)
                if ok then
                    themeToast(T(_("已导出：%1"), path_or_err), 5)
                else
                    themeToast(T(_("导出失败：%1"), path_or_err or ""))
                end
            end)
        elseif v == "delete" then
            local ok, err = Theme.delete(name)
            if ok then
                refreshOverlayPage(desktop)
                themeToast(_("已删除主题"))
            elseif err == "beautify_in_use" then
                themeToast(_("应用中删除失败，请先应用其他主题"))
            else
                themeToast(T(_("应用中删除失败，%1"), err or _("主题目录删不掉")))
            end
        end
    end)
end

--- 主题管理页：保存 / 导入 / 已导入主题列表
---@param desktop table|nil
---@return table page
local function themePageTable(desktop)
    return {
        title = _("主题"),
        sections = function()
            local Theme = require("moonbeautify.theme")
            local active = Store.conf().active_theme
            local themeRows = {}
            for _idx, name in ipairs(Theme.list()) do
                themeRows[#themeRows + 1] = function(iw)
                    local n, kb = Theme.stat(name)
                    local applied = name == active
                    local status
                    if applied then
                        status = Theme.dirty(name) and _("应用中（有修改）") or _("应用中")
                    end
                    return Row.widget({
                        width = iw,
                        icon = "palette",
                        title = name,
                        subtitle = T(_("%1 张图 · %2 KB"), n, kb),
                        status = status,
                        status_on = applied,
                        chevron = true,
                        callback = function() themeItem(desktop, name, active) end,
                    })
                end
            end
            if #themeRows == 0 then
                themeRows[#themeRows + 1] = function(iw)
                    return Row.widget({
                        width = iw, chevron = false, icon = "palette",
                        title = _("还没有主题"),
                        subtitle = _("先保存当前配置，或导入一个 zip"),
                    })
                end
            end
            return {
                { title = _("保存与导入"), rows = {
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "save", chevron = true,
                            title = _("当前配置保存为主题"),
                            subtitle = _("保存当前整套设置配置"),
                            callback = function() themeSave(desktop) end,
                        })
                    end,
                    function(iw)
                        return Row.widget({
                            width = iw, icon = "download", chevron = true,
                            title = _("导入主题 zip"),
                            subtitle = _("不管 zip 在哪，导入即归档到固定目录"),
                            callback = function() themeImport(desktop) end,
                        })
                    end,
                } },
                { title = _("已导入主题"), rows = themeRows },
            }
        end,
    }
end

--- 让当前主题页重新取数据（sections 是函数，rebuild 会重新调用）
---@param desktop table|nil
function refreshOverlayPage(desktop)
    if not desktop then return end
    local ov = desktop.settings_overlay
    if not ov then return end
    pcall(function()
        ov.page = nil      -- 列表变短后旧页码会越界，重置回第一页
        ov:rebuild()
        UIManager:setDirty(ov, "ui")
    end)
end

--- 依次点两个组件，存成一组并排（一个组件只能进一组）
---@param desktop table|nil
---@param first string|nil 已选的第一个组件 id
local function pickPair(desktop, first)
    local list = componentList()
    local labels = {}
    for _i, comp in ipairs(list) do labels[comp.id] = comp.label end
    local index = require("moonbeautify.rows").groupIndex(Store.conf().rows)
    if not first then
        local items = {}
        for _i, comp in ipairs(list) do
            local g = index[comp.id]
            local mate
            if g then
                for _j, id in ipairs(g.ids) do
                    if id ~= comp.id and labels[id] then mate = labels[id] break end
                end
            end
            items[#items + 1] = {
                value = comp.id,
                text = comp.label,
                mandatory = mate and T(_("已和「%1」并排"), mate) or nil,
                enabled = not g,
            }
        end
        return choose(_("第一个组件"), items, nil, function(id)
            if id then pickPair(desktop, id) end
        end)
    end
    -- 第二个：只挑还没进任何组的
    local items = {}
    for _i, comp in ipairs(list) do
        if comp.id ~= first and not index[comp.id] then
            items[#items + 1] = { value = comp.id, text = comp.label }
        end
    end
    if #items == 0 then
        themeToast(_("其余组件都已有组合，没有可并排的了"))
        return
    end
    choose(T(_("和「%1」并排"), labels[first] or first), items, nil, function(id)
        local c = Store.conf()
        c.rows = type(c.rows) == "table" and c.rows or {}
        c.rows[#c.rows + 1] = { first, id }
        Store.save()
        repaint(desktop)
    end)
end

--- 组件花边总入口：逐个组件设置
---@param desktop table|nil
local function widgetLacePage(desktop)
    local conf = Store.conf()
    local map = type(conf.widget_lace) == "table" and conf.widget_lace or {}
    local items = {}
    local labels = {}
    for _idx, comp in ipairs(componentList()) do
        labels[comp.id] = comp.label
        local own = map[comp.id]
        items[#items + 1] = {
            value = comp.id,
            text = comp.label,
            mandatory = (type(own) == "string" and own ~= "" and _("已设置") or nil),
        }
    end
    List:new{
        title = _("组件花边"),
        subtitle = _("给单个组件叠一圈花边（透明 PNG，中间镂空不挡内容）"),
        items = items,
        centered = true,
        on_select = function(value)
            local current = type(map[value]) == "string" and map[value] or nil
            choose(labels[value] or value, {
                { value = "pick", text = _("选一张花边（透明 PNG）…") },
                { value = "reset", text = _("移除花边"), enabled = current ~= nil },
            }, nil, function(v)
                local c = Store.conf()
                if v == "pick" then
                    pickPath(desktop, current, true, function(path)
                        c.widget_lace = type(c.widget_lace) == "table" and c.widget_lace or {}
                        c.widget_lace[value] = path
                        Store.save()
                        repaint(desktop)
                    end)
                elseif v == "reset" then
                    c.widget_lace = type(c.widget_lace) == "table" and c.widget_lace or {}
                    c.widget_lace[value] = nil
                    if next(c.widget_lace) == nil then c.widget_lace = nil end
                    Store.save()
                    repaint(desktop)
                end
            end)
        end,
    }:show()
end

--- 并排组合管理页
---@param desktop table|nil
local function rowsPage(desktop)
    local conf = Store.conf()
    -- 自愈：旧版本可能存过成员重叠的组合（渲染层只认先出现的那组），打开本页时清掉
    local cleaned, changed = require("moonbeautify.rows").cleanGroups(conf.rows)
    if changed then
        conf.rows = #cleaned > 0 and cleaned or nil
        Store.save()
        repaint(desktop)
        themeToast(_("清理了与其他组合重叠的无效组合"))
    end
    local groups = cleaned
    local labels = {}
    for _i, comp in ipairs(componentList()) do labels[comp.id] = comp.label end

    local items = {}
    for i, group in ipairs(groups) do
        local names = {}
        for _j, id in ipairs(group) do names[#names + 1] = labels[id] or id end
        items[#items + 1] = { value = i, text = table.concat(names, " ＋ "), mandatory = _("并排") }
    end
    items[#items + 1] = { value = "new", text = _("新建并排组合…") }

    List:new{
        title = _("并排组合"),
        subtitle = _("同一页的两个组件合成一行，宽度均分"),
        items = items,
        centered = true,
        on_select = function(value)
            if value == "new" then return pickPair(desktop, nil) end
            if type(value) ~= "number" then return end
            local text = items[value] and items[value].text or _("并排")
            choose(text, { { value = "remove", text = _("解散这一组") } }, nil, function()
                local c = Store.conf()
                if type(c.rows) == "table" then
                    table.remove(c.rows, value)
                    if #c.rows == 0 then c.rows = nil end
                end
                Store.save()
                repaint(desktop)
            end)
        end,
    }:show()
end

--- 月读设置页（外观分组顶部）的「月华美化」入口，点开后是扩展自己的页面。
---@param desktop table|nil
---@return table[]
function Settings.entries(desktop)
    local Update = require("moonbeautify.update")
    local ver = Update.version()
    local title = ver and T(_("月华美化（%1）"), ver) or _("月华美化")

    local function count(map)
        local n = 0
        if type(map) == "table" then for _k in pairs(map) do n = n + 1 end end
        return n
    end

    local function link(icon, name, subtitle, open)
        return function(iw)
            return Row.widget({
                width = iw, icon = icon, title = name, subtitle = subtitle,
                chevron = true, callback = open,
            })
        end
    end

    local function sections()
        local conf = Store.conf()
        local tab_count = count(conf.tab_icons)
        local bg_count = count(conf.widget_bg)
        local lace_count = count(conf.widget_lace)
        local row_count = type(conf.rows) == "table" and #conf.rows or 0
        local custom_order = type(conf.tab_order) == "table" and #conf.tab_order > 0
        local theme_count = #require("moonbeautify.theme").list()
        local auto = Update.autoEnabled()
        return {
            { title = _("主题"), rows = {
                link("save", _("主题"),
                    theme_count > 0 and T(_("%1 套已保存，可随时切换"), theme_count)
                        or _("整套美化连图片存档、分享、一键切换"),
                    function() Overlay.push(desktop, themePageTable(desktop)) end),
            } },
            { title = _("底栏"), rows = {
                link("dashboard", _("底栏图标与顺序"),
                    (tab_count > 0 or custom_order) and _("已自定义图标或顺序") or _("换图标、调顺序"),
                    function() Overlay.push(desktop, tabBarPage(desktop)) end),
            } },
            { title = _("首页组件"), rows = {
                link("image", _("组件背景"),
                    bg_count > 0 and T(_("已设置 %1 个组件"), bg_count) or _("给首页组件加背景图"),
                    function() widgetBgPage(desktop) end),
                link("border_style", _("组件花边"),
                    lace_count > 0 and T(_("%1 个组件已配"), lace_count) or _("给首页组件加一圈花边"),
                    function() widgetLacePage(desktop) end),
                link("view_column", _("并排组合"),
                    row_count > 0 and T(_("已有 %1 组"), row_count) or _("两个组件挤同一行"),
                    function() rowsPage(desktop) end),
            } },
            { title = _("更新"), rows = {
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "toggle", icon = "update",
                        title = _("自动检查更新"),
                        subtitle = _("每天最多一次，发现新版本时弹窗提示"),
                        status = auto and _("开") or _("关"), status_on = auto,
                        callback = function()
                            Update.setAuto(not auto)
                            if desktop then pcall(function() desktop:updateView() end) end
                        end,
                    })
                end,
                function(iw)
                    return Row.widget({
                        width = iw, chevron = false, kind = "action", icon = "settings_suggest",
                        title = _("检查更新"),
                        status = ver or "", status_on = true,
                        callback = function() Update.check(false) end,
                    })
                end,
            } },
        }
    end

    return {
        {
            id = "main",
            group = "appearance",
            order = 1,
            icon = "auto_awesome",
            title = title,
            subtitle = _("主题、底栏、组件背景与花边"),
            page = { title = title, sections = sections },
        },
    }
end

return Settings
