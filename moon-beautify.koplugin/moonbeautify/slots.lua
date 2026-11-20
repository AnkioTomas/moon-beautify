--[[--
组件里的「贴图格」：8 个格子摆成田字——上排 1–4，下排 5–8，压在吧唧上层。
单独一行时 8 格全显示；并排（组合，半宽）时只显示中间两列，
也就是上排的 2、3 格和下排的 6、7 格，四角的 1、4、5、8 格不显示。

@module moonbeautify.slots
--]]

local CenterContainer = require("ui/widget/container/centercontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local Widget = require("ui/widget/widget")
local Geom = require("ui/geometry")

local Image = require("ui.themes.widgets.image")

local Slots = {}

--- 当前显示哪几格：并排时半宽，只留中间两列（上 2、3 / 下 6、7）；满宽时 1–8 全显示
---@return number[]
function Slots.indices()
    local ok, Rows = pcall(require, "moonbeautify.rows")
    if ok and Rows.dense then return { 2, 3, 6, 7 } end
    return { 1, 2, 3, 4, 5, 6, 7, 8 }
end

local function blank(w, h)
    return Widget:new{ dimen = Geom:new{ w = w, h = h } }
end

--- 造贴图格（上排 + 下排，田字样式）
---@param w number
---@param h number
---@param map table|nil { [i] = 图片路径 }
---@return table|nil 没有任何贴图时返回 nil
function Slots.build(w, h, map)
    if type(map) ~= "table" then return nil end
    -- 只看当前真正显示的那几格：并排时若四角（1、4、5、8）才有图，就整块不显示
    local list = Slots.indices()
    local used = false
    for _i, idx in ipairs(list) do
        local v = map[idx]
        if type(v) == "string" and v ~= "" then used = true break end
    end
    if not used then return nil end

    local cols = math.ceil(#list / 2) -- 满宽 4 列，并排 2 列
    local cw = math.max(1, math.floor(w / cols))
    local rh = math.max(1, math.floor(h / 2))

    local grid = VerticalGroup:new{}
    for row_i = 0, 1 do
        local row = HorizontalGroup:new{ align = "center" }
        for col_i = 0, cols - 1 do
            local idx = list[row_i * cols + col_i + 1]
            local path = idx and map[idx] or nil
            local cell_w = (col_i == cols - 1) and math.max(1, w - cw * (cols - 1)) or cw
            local child
            if type(path) == "string" and path ~= "" then
                -- 贴图只占格子的一部分，四周留白，吧唧露得多一些
                local side = math.max(8, math.floor(math.min(cell_w, rh) * 0.72))
                child = Image.widget{
                    src = path,
                    width = side,
                    height = side,
                    stretch = false,
                    style = {},
                    fallback = "",
                }
            else
                child = blank(math.max(1, cell_w - 4), math.max(1, rh - 4))
            end
            row[#row + 1] = CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = rh },
                child,
            }
        end
        grid[#grid + 1] = row
    end
    return grid
end

return Slots
