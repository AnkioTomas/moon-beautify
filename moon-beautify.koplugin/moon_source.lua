--[[--
月读扩展描述：不是书源。往首页加两个图片组件，并补丁两处外观（底栏图片图标 / 组件背景）。

契约（api = 1，id = ext.<name>，provides.source = false）：
  home_widgets 简写表 { id, title, icon, build = fun(ctx, w, h), heightRange = fun(ctx, opts), settings = fun(desktop, id) }
  build 返回占满 w × h 的控件；settings 让首页编辑态出现设置按钮（设置里抛错会被月读记日志）。
  provides.features.setting 往「设置 → 外观」顶部加「月华美化」入口，点开是扩展自己的页面。
组件 id 由月读补成 ext.beautify.<短名>，发布后不要改。

--]]

local _ = require("gettext")

local ID = "ext.beautify"

-- 加载信号：月读首次访问源注册表时 dofile 本文件；日志里有这行说明描述表被认了。
pcall(function()
    local Log = require("utils.log")
    Log.dbg("moonbeautify descriptor loaded")
    if Log.flush then Log.flush() end
end)

-- 补丁：图标图片化 / 底栏换图 / 组件背景。必须在首页第一次 build 之前装上（本文件就是那个时机）。
pcall(function() require("moonbeautify.patch").install() end)

-- 更新检查：挂到「桌面回到前台」，每天最多查一次（和月读自己的更新检查同一个事件）
pcall(function() require("moonbeautify.update").install() end)

--- 高度按可用宽度的比例报，跟屏幕大小无关；用户在编辑态里还能自己拖。
--- 这里按「最大档」给足高度，具体直径由设置里的尺寸决定（s/m/l 缩放边长），
--- 这样改尺寸只动吧唧大小，不会把整页排版顶来顶去。
local RATIO = 0.62

---@param opts table|nil { width }
---@return { height: number }
local function heightOf(opts)
    local w = (opts and opts.width) or 540
    return { height = math.max(60, math.floor(w * RATIO)) }
end

--- 造一个吧唧组件。月读的首页组件按 id 唯一，所以想放多个吧唧就得有多个 id，
--- 每个 id 用「id + 下划线」当自己的配置前缀（badge_ / badge2_ / ...），互不干扰。
---@param id string
---@param title string
---@return table
local function badgeWidget(id, title)
    local prefix = id .. "_"
    return {
        id = id, -- 月读补成 ext.beautify.<id>
        title = _(title),
        icon = "image",
        heightRange = function(_ctx, opts) return heightOf(opts) end,
        build = function(_ctx, w, h)
            return require("moonbeautify.view").badge(w, h, prefix)
        end,
        settings = function(desktop, _id)
            -- 不在这里 pcall：月读的 guard 会 pcall 并记日志，套两层会把错误吞掉。
            require("moonbeautify.settings").show(prefix, desktop)
        end,
    }
end

return {
    api = 1,
    id = ID,
    provides = {
        source = false,
        home_widgets = {
            badgeWidget("badge", "吧唧"),
            badgeWidget("badge2", "吧唧 2"),
            badgeWidget("badge3", "吧唧 3"),
            badgeWidget("badge4", "吧唧 4"),
        },
        features = {
            setting = {
                entries = function(desktop)
                    return require("moonbeautify.settings").entries(desktop)
                end,
            },
        },
    },
}
