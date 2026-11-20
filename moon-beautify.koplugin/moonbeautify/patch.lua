--[[--
对月读本体的四处轻量补丁（不改月读源码，只替换模块表上的函数）。

1. Icon.widget / Icon.label：name 看起来是图片路径（含 / 且后缀是图片）就画图，否则走原字体图标。
2. Tabbar.widget：按配置 tab_icons[tab.id] 把底栏格子的 icon 换成图片路径。
3. Base.build / Base.refresh：给指定组件的内容外面套背景图（配置 widget_bg[组件 id]）、
   叠花边（配置 widget_lace：all 统一 + 组件 id 覆盖）。
4. 设置入口（settings.entries）另在 settings.lua。

全部包在 pcall 里，月读升级导致字段变化时最多失效，不影响启动。

@module moonbeautify.patch
--]]

local Theme = require("ui/themes")
local CenterContainer = require("ui/widget/container/centercontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")

local Image = require("ui/themes/widgets/image")
local Text = require("ui.themes.widgets.text")
local ImageUtil = require("utils.image")

local Store = require("moonbeautify.store")

local Patch = {}
local installed = false

--- 名字是不是图片路径：带目录分隔符且后缀是已知图片。
---@param name any
---@return boolean
local function isImagePath(name)
    return type(name) == "string" and name:find("/", 1, true) ~= nil and ImageUtil.suffix(name) ~= nil
end
Patch.isImagePath = isImagePath

--- 图标槽换成图片：方盒居中，保比例。
---@param path string
---@param size number 逻辑字号
---@return table
local function imageIcon(path, size)
    local box = Theme.px(size)
    return CenterContainer:new{
        dimen = Geom:new{ w = box, h = box },
        Image.widget{ src = path, width = box, height = box, stretch = false, style = {}, fallback = "" },
    }
end

--- 补丁 1：图标字体 -> 图片
local function patchIcon()
    local Icon = require("ui.themes.widgets.icon")
    if Icon._beautify then return end
    Icon._beautify = true

    local origWidget = Icon.widget
    Icon.widget = function(opts)
        if isImagePath(opts and opts.name) then return imageIcon(opts.name, opts.size or 24) end
        return origWidget(opts)
    end

    local origLabel = Icon.label

    --- 图片路径 + 文字的组合标签；text 缺失时只画图标
    ---@param opts table
    ---@return table
    local function labelWidget(opts)
        if not opts.text then return imageIcon(opts.name, opts.size or 24) end
        local color = opts.color or Theme.color(Theme.current().color.accent)
        local column = opts.direction == "column"
        local icon = imageIcon(opts.name, opts.size or 24)
        local text = Text.tint(TextWidget:new{
            text = opts.text,
            face = Theme.face(opts.face or "xx_smallinfofont", opts.font_size or 12),
            fgcolor = opts.text_color or color,
            max_width = opts.max_width,
        })
        local group = (column and VerticalGroup or HorizontalGroup):new{ align = "center" }
        group[1] = opts.trailing and text or icon
        group[2] = (column and VerticalSpan or HorizontalSpan):new{ width = opts.gap or Theme.px(4) }
        group[3] = opts.trailing and icon or text
        return group
    end

    Icon.label = function(opts)
        if not isImagePath(opts and opts.name) then return origLabel(opts) end
        -- 组合标签出错（字段变化等）就退回原生文字标签，不能让桌面画不出来
        local ok, result = pcall(labelWidget, opts)
        if ok and result then return result end
        return origLabel(opts)
    end
end

--- 补丁 2：底栏图标按配置换图
local function patchTabbar()
    local Tabbar = require("ui.themes.widgets.tabbar")
    if Tabbar._beautify then return end
    Tabbar._beautify = true
    local orig = Tabbar.widget
    Tabbar.widget = function(opts)
        local ok, tabs = pcall(function()
            local map = Store.conf().tab_icons
            if type(map) ~= "table" or type(opts.tabs) ~= "table" then return nil end
            local copy, changed = {}, false
            for i, tab in ipairs(opts.tabs) do
                local path = map[tab.id]
                if type(path) == "string" and path ~= "" then
                    copy[i] = { id = tab.id, text = tab.text, icon = path, owner = tab.owner, after = tab.after }
                    changed = true
                else
                    copy[i] = tab
                end
            end
            return changed and copy or nil
        end)
        if ok and tabs then opts.tabs = tabs end
        -- 图标顺序：tab_order 里配置了的格子按用户顺序排，没配置的（扩展格子等）保持原顺序跟在后面
        local okr, ordered = pcall(function()
            local order = Store.conf().tab_order
            if type(order) ~= "table" or #order == 0 or type(opts.tabs) ~= "table" or #opts.tabs < 2 then
                return nil
            end
            local rank = {}
            for i, id in ipairs(order) do
                if type(id) == "string" and rank[id] == nil then rank[id] = i end
            end
            local idx, copy = {}, {}
            for i, tab in ipairs(opts.tabs) do
                idx[tab] = i
                copy[i] = tab
            end
            table.sort(copy, function(a, b)
                local ra, rb = rank[a.id], rank[b.id]
                if ra and rb then
                    if ra ~= rb then return ra < rb end
                    return idx[a] < idx[b]
                end
                if ra then return true end
                if rb then return false end
                return idx[a] < idx[b]
            end)
            for i, tab in ipairs(copy) do
                if tab ~= opts.tabs[i] then return copy end
            end
            return nil
        end)
        if okr and ordered then opts.tabs = ordered end
        return orig(opts)
    end
end

--- 组件内容内边距：widget_pad.all 统一，组件自己的键覆盖（0 = 不收）
---@param conf table
---@param id string
---@return integer
local function padOf(conf, id)
    local map = conf.widget_pad
    if type(map) ~= "table" then return 0 end
    local own = map[id]
    local v = tonumber((own ~= nil) and own or map.all) or 0
    if v < 0 then v = 0 end
    if v > 24 then v = 24 end
    return math.floor(v)
end

--- 补丁 3：组件背景 + 花边包裹
---@param self table 组件实例（Base 子类）
---@param widget table 组件内容
---@return table
local function decorate(self, widget)
    local ok, wrapped = pcall(function()
        local conf = Store.conf()
        -- 花边：逐组件设置（false/空串表示关）
        local lace
        local laceConf = conf.widget_lace
        if type(laceConf) == "table" then lace = laceConf[self.id] end
        if type(lace) ~= "string" or lace == "" then lace = nil end
        local item = type(conf.widget_bg) == "table" and conf.widget_bg[self.id] or nil
        local hasBg = type(item) == "table" and type(item.src) == "string" and item.src ~= ""
        local pad = padOf(conf, self.id)
        if not hasBg and not lace and pad <= 0 then return nil end
        -- 有内边距时组件是按缩小尺寸建的（_beautify_full 记着整槽尺寸），居中放回去
        local dims = self._beautify_full
        local opts = self.opts or {}
        local w = (dims and dims.w) or opts.width or widget.dimen and widget.dimen.w
        local h = (dims and dims.h) or opts.height or widget.dimen and widget.dimen.h
        if not (w and h) then return nil end
        local inner = widget
        if dims and pad > 0 then
            inner = CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, widget }
        end
        return require("moonbeautify.view").background(w, h,
            hasBg and item.src or nil, hasBg and (tonumber(item.veil) or 0) or 0, inner, lace,
            hasBg and item.fit or nil)
    end)
    if ok and wrapped then return wrapped end
    return widget
end
Patch.decorate = decorate

local function patchHome()
    local Base = require("desktop.pages.home.base")
    if Base._beautify then return end
    Base._beautify = true

    local origBuild = Base.build
    Base.build = function(self, ctx, opts)
        -- 内边距：把组件按缩小后的宽高建出来，槽位本身保持原尺寸，
        -- decorate 里再居中放回去——背景 / 边框 / 花边仍铺满整槽。
        local build_opts = opts
        local pad = padOf(Store.conf(), self.id)
        local full
        if pad > 0 and opts and tonumber(opts.width) and tonumber(opts.height) then
            local w, h = math.floor(opts.width), math.floor(opts.height)
            full = { w = w, h = h }
            self._beautify_full = full
            build_opts = {}
            for k, v in pairs(opts) do build_opts[k] = v end
            build_opts.width = math.max(24, w - pad * 2)
            build_opts.height = math.max(24, h - pad * 2)
        else
            self._beautify_full = nil
        end
        local slot = origBuild(self, ctx, build_opts)
        if slot then
            if full and slot.dimen then
                slot.dimen.w, slot.dimen.h = full.w, full.h
            end
            if slot[1] then slot[1] = decorate(self, slot[1]) end
        end
        return slot
    end

    -- 整体替换 refresh：重建内容后重新套装饰
    Base.refresh = function(self)
        local slot = self.slot
        if not slot then return end
        local old = slot[1]
        slot[1] = decorate(self, self:createWidget())
        if old then old:free() end
        self:dirty()
    end
end

--- 补丁 4：首页「同一行并排」——接管 layout.build / paginate（仅配置了组合时生效）
local function patchRows()
    require("moonbeautify.rows").install()
end

--- 补丁 5：选图器的「上次目录」记忆。
--- 月读自己的壁纸/锁屏/设备头像选择器都走 ui.themes.widgets.path_picker，
--- 这里统一记一个 last_dir：谁先选过图，后面所有选择器（含吧唧/组件背景）都从那里开。
--- 已经显式配过路径的（组件自己的 src/dir、壁纸自己的图）不受影响，仍从自己那个目录开。
local function patchPicker()
    local lfs = require("libs/libkoreader-lfs")
    local PathPicker = require("ui.themes.widgets.path_picker")
    if PathPicker._beautify then return end
    PathPicker._beautify = true

    local function isDir(path)
        return type(path) == "string" and path ~= "" and lfs.attributes(path, "mode") == "directory"
    end

    --- 记住这次选的目录：选文件记它所在目录，选目录就记目录本身
    ---@param picked string
    ---@param select_file boolean
    local function remember(picked, select_file)
        if type(picked) ~= "string" or picked == "" then return end
        local dir = select_file and picked:match("^(.*)/") or picked
        if isDir(dir) then
            local conf = Store.conf()
            if conf.last_dir ~= dir then
                conf.last_dir = dir
                Store.save()
            end
        end
    end

    local orig_init = PathPicker.init
    PathPicker.init = function(self)
        local home = require("apps/filemanager/filemanagerutil").getHomeFolder()
        local last = Store.conf().last_dir
        -- 传进来的是「用户目录」这种没信息量的兜底，或者干脆不是有效目录 → 用上次的
        if isDir(last) and (not isDir(self.path) or self.path == home) then
            self.path = last
        end
        local orig_select = self.on_select
        if type(orig_select) == "function" then
            self.on_select = function(picked)
                pcall(remember, picked, self.select_file)
                return orig_select(picked)
            end
        end
        return orig_init(self)
    end
end

--- 安装全部补丁（幂等）。
function Patch.install()
    if installed then return end
    installed = true
    for _idx, fn in ipairs({ patchIcon, patchTabbar, patchHome, patchRows, patchPicker }) do
        local ok = pcall(fn)
        if not ok then
            pcall(function() require("utils.log").error("moonbeautify patch failed") end)
        end
    end
end

return Patch
