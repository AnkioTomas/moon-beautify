--[[--
首页「并排」：把同一页上的两个（或更多）组件合成一行。

月读原生布局是严格竖排（每个组件占满整行），这里替换 desktop.pages.home.layout 的
build / paginate，按扩展配置 rows 分组：

  rows = { { "weather_forecast", "ext.beautify.badge" }, ... }

- 同一组内按 placements 的 order 从左到右排，宽度均分（中间留 gap）。
- 行高 = 组内成员里最高的那个（各成员按自己的 height 撑，矮的那边留白）。
- 成员各自的 margin 仍然生效（左/右会进一步压窄），所以之前手动加的边距可以清掉。
- 没配 rows，或配了但成员不在同一页：完全退回月读原生逻辑（不接管）。
- 布局被我们接管时，paginate 也按组合算高度，避免整页重排把一对拆到两页。

@module moonbeautify.rows
--]]

local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Registry = require("desktop.pages.home.registry")
local Widgets = require("desktop.pages.home.placements")
local Layout = require("desktop.pages.home.layout")
local Box = require("ui/themes/widgets/box")
local Store = require("moonbeautify.store")

local Rows = {}

--- id → { index, ids }：查某组件属于哪一组
---@param groups table[]
---@return table<string, { index: number, ids: string[] }>
local function groupIndex(groups)
    local out = {}
    for gi, group in ipairs(groups) do
        if type(group) == "table" and #group >= 2 then
            for _i, id in ipairs(group) do
                if type(id) == "string" and id ~= "" then out[id] = { index = gi, ids = group } end
            end
        end
    end
    return out
end
Rows.groupIndex = groupIndex

--- 清掉互相重叠的组合：一个成员只能属于先出现的那组，冲突组整体解散
---@param groups table[]
---@return table[] cleaned, boolean changed
local function cleanGroups(groups)
    if type(groups) ~= "table" then return {}, false end
    local used, out, changed = {}, {}, false
    for _i, group in ipairs(groups) do
        local ok = type(group) == "table" and #group >= 2
        if ok then
            for _j, id in ipairs(group) do
                if used[id] then ok = false break end
            end
        end
        if ok then
            out[#out + 1] = group
            for _j, id in ipairs(group) do used[id] = true end
        else
            changed = true
        end
    end
    return out, changed
end
Rows.cleanGroups = cleanGroups

--- 单组件的占位高度（内容 + 上下边距），与原生 packHeight 同口径
local packHeight = Layout.packHeight

--- 把一页的 ranges 折成「行」：普通组件自成一行，组合合成一行
---@param ranges table[]
---@param index table
---@return table[] {{ raws = table[], height = integer, id = string }}
local function unitsOf(ranges, index)
    local out, seen = {}, {}
    for _i, raw in ipairs(ranges) do
        local g = index[raw.id]
        if not g then
            out[#out + 1] = { raws = { raw }, height = packHeight(raw), id = raw.id }
        elseif not seen[g.index] then
            seen[g.index] = true
            local members = {}
            for _j, other in ipairs(ranges) do
                local og = index[other.id]
                if og and og.index == g.index then members[#members + 1] = other end
            end
            if #members > 1 then
                local h = 0
                for _k, m in ipairs(members) do h = math.max(h, packHeight(m)) end
                out[#out + 1] = { raws = members, height = math.max(1, h), id = members[1].id }
            else
                -- 搭档不在本页：当普通组件处理
                for _k, m in ipairs(members) do out[#out + 1] = { raws = { m }, height = packHeight(m), id = m.id } end
            end
        end
    end
    return out
end
Rows.unitsOf = unitsOf

--- 组合感知的分页：packs 里每个元素仍是 range（保持原契约），只是同组成员必定同页
---@param ranges table[]
---@param available integer
---@param gap integer
---@param groups table[]
---@return table[][]
function Rows.paginate(ranges, available, gap, groups)
    local units = unitsOf(ranges, groupIndex(groups))
    local pages, cur, used = {}, {}, 0
    for _i, unit in ipairs(units) do
        local h = unit.height
        if #cur > 0 and used + gap + h > available then
            pages[#pages + 1] = cur
            cur, used = {}, 0
        end
        used = used + (#cur > 0 and gap or 0) + h
        for _k, raw in ipairs(unit.raws) do cur[#cur + 1] = raw end
    end
    pages[#pages + 1] = cur
    return pages
end

--- 单行内某个成员的宽度份额（余数给最后一个，避免像素缝）
---@param inner_w integer
---@param n integer
---@param gap integer
---@param i integer
---@return integer
local function share(inner_w, n, gap, i)
    local usable = math.max(1, inner_w - gap * (n - 1))
    local base = math.floor(usable / n)
    if i == n then return math.max(1, usable - base * (n - 1)) end
    return math.max(1, base)
end

--- 组合感知的整页排版（结构照抄月读 layout.build，只把「每个组件一行」换成「每行一组」）
---@param ctx table
---@param components table
---@param page integer
---@param opts table
---@param groups table[]
---@return table body, integer page, integer pages, table visible
function Rows.build(ctx, components, page, opts, groups)
    opts = opts or {}
    local groups_index = groupIndex(groups)
    local w = ctx.width
    local body_h = opts.body_height or ctx.height
    local placements = Registry.widgets()
    local inner_w, inner_h, gap = Layout.metrics(w, body_h)

    -- 逐钉页取组件、算 range、折成行、再分页（编辑态不重排）
    local display = {}
    for pinned = 1, Widgets.pageCount(placements) do
        local ranges = {}
        for _idx, place in ipairs(Widgets.onPage(placements, pinned)) do
            local comp = components[place.id]
            if comp then
                local range = comp:heightRange(ctx, { width = inner_w, height = inner_h })
                range.comp = comp
                range.id = place.id
                range.placement = place
                ranges[#ranges + 1] = range
            end
        end
        if opts.wrap then
            display[#display + 1] = ranges
        else
            for _idx, pack in ipairs(Rows.paginate(ranges, math.floor(inner_h * Layout.OVERFLOW_SLACK), gap, groups)) do
                display[#display + 1] = pack
            end
        end
    end

    local pages = #display
    for i, ranges in ipairs(display) do
        for _idx, raw in ipairs(ranges) do
            if raw.id == opts.focus then page = i end
        end
    end
    page = math.max(1, math.min(pages, page))
    local ranges = display[page] or {}
    local units = unitsOf(ranges, groups_index)

    -- 高度分配沿用原生 allocate：喂给它「每行一个伪 range」，拿回每行高度
    local pseudo = {}
    for _i, unit in ipairs(units) do
        pseudo[#pseudo + 1] = { height = unit.height, placement = { height = "default" }, id = unit.id }
    end
    local _selected, heights, unused = Layout.allocate(pseudo, inner_h, gap)

    local kids = { align = "left" }
    local visible = {}
    for ui, unit in ipairs(units) do
        local slot_h = heights[ui] or unit.height
        if ui > 1 then kids[#kids + 1] = VerticalSpan:new{ width = gap } end
        local n = #unit.raws
        -- 半宽时组件内的贴图格只分 4 份（满宽 8 份），让 View.slots 读到
        Rows.dense = n > 1
        local row = HorizontalGroup:new{ align = "top" }
        for mi, raw in ipairs(unit.raws) do
            -- 组合里只有一个成员时保持原生宽度；否则均分
            local slot_w = n > 1 and share(inner_w, n, gap, mi) or inner_w
            if n > 1 and mi > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            visible[raw.id] = true

            local top, right, bottom, left = Widgets.marginBox(raw.placement)
            if top + bottom > 0 and slot_h <= top + bottom then
                local scale = (slot_h - 1) / (top + bottom)
                top, bottom = math.max(0, math.floor(top * scale)), math.max(0, math.floor(bottom * scale))
            end
            if left + right > 0 and slot_w <= left + right then
                local scale = (slot_w - 1) / (left + right)
                left, right = math.max(0, math.floor(left * scale)), math.max(0, math.floor(right * scale))
            end
            local content_w = math.max(1, slot_w - left - right)
            local content_h = math.max(1, slot_h - top - bottom)

            local part = raw.comp:build(ctx, { width = content_w, height = content_h })
            part = Layout.pad(part, top, right, bottom, left)
            if opts.wrap then
                part = opts.wrap(part, {
                    id = raw.id,
                    height = slot_h,
                    width = slot_w,
                    placement = raw.placement,
                    range = { height = raw.height, fill = false, limit = inner_h },
                })
            end
            row[#row + 1] = part
        end
        kids[#kids + 1] = (n > 1) and row or row[1]
    end
    Rows.dense = nil
    if unused and unused > 0 then kids[#kids + 1] = VerticalSpan:new{ width = unused } end

    local body = Box:new{ style = {}, width = w, height = body_h, VerticalGroup:new(kids) }
    return body, page, pages, visible
end

--- 装上补丁（幂等）。只在配置了 rows 时接管，否则一行代码都不改行为。
function Rows.install()
    if Layout._beautify then return end
    Layout._beautify = true

    local origBuild = Layout.build
    Layout.build = function(ctx, components, page, opts)
        local groups = Store.conf().rows
        if type(groups) ~= "table" or #groups == 0 then
            return origBuild(ctx, components, page, opts)
        end
        local ok, body, p, pages, visible = pcall(Rows.build, ctx, components, page, opts, groups)
        Rows.dense = nil -- build 中途抛错时不能残留半宽状态
        if ok then return body, p, pages, visible end
        return origBuild(ctx, components, page, opts)
    end

    local origPaginate = Layout.paginate
    Layout.paginate = function(ranges, available, gap)
        local groups = Store.conf().rows
        if type(groups) ~= "table" or #groups == 0 then
            return origPaginate(ranges, available, gap)
        end
        local ok, pages = pcall(Rows.paginate, ranges, available, gap, groups)
        if ok then return pages end
        return origPaginate(ranges, available, gap)
    end
end

return Rows
