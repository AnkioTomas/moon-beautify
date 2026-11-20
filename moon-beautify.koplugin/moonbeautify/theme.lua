--[[--
主题包：整套美化配置 + 图片素材，存成固定目录里的可切换主题，也能打包成 zip 分享。

固定目录（Path.root 之下，真机是 koreader/.moon/beautify/themes/<主题名>/）：
    theme.lua   -- return { name = "chiikawa1", conf = { ... } }
    assets/     -- 主题用到的全部图片

theme.lua 里图片路径写成 "@assets/文件名"，应用时替换成主题目录下的绝对路径——
同一份主题拷到任何设备都直接可用，图片文件名冲突自动重编号。

- 保存主题：把当前配置快照成主题（凡是指向真实图片文件的字符串一律收编进 assets）
- 应用主题：合并回当前配置（排除 last_dir 等本机状态键），改过的配置随时能切回来
- 导出 zip：theme.lua + assets 打包（moonbeautify.zip，STORED）
- 导入 zip：解到主题目录（用月读自带的 ffi/archiver.Reader），名字取包内 theme.lua 的
  name 字段，没有就用 zip 文件名；同名主题直接覆盖

zip 包是一段 Lua 代码 + 图片，导入等于执行 theme.lua——只导入自己信任的文件。

@module moonbeautify.theme
--]]--

local lfs = require("libs/libkoreader-lfs")
local Log = require("utils.log")

local Theme = {}

--- 主题包格式标识与版本：theme.lua 返回值里带 kind = THEME_KIND 才认作月读美化主题包
local THEME_KIND = "moonbeautify-theme"
local THEME_FORMAT = 1

--- 本机状态类键：不进主题、主题里出现也忽略
local LOCAL_KEYS = {
    last_dir = true,
    update_checked_at = true,
    update_auto = true,
    active_theme = true,
}

local IMAGE_EXT = { png = true, jpg = true, jpeg = true, webp = true, gif = true, bmp = true }
local ASSET_MARK = "@assets/"

--- 逐级建目录：lfs.mkdir 只建最后一级，父目录缺失时会失败（Kindle 首次保存就栽在这）
---@param path string 绝对或相对路径
---@return boolean
local function mkdirp(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    local abs = path:sub(1, 1) == "/"
    local acc, first = abs and "/" or "", true
    for seg in path:gmatch("[^/]+") do
        acc = (first and abs) and acc .. seg or (acc == "" and seg or acc .. "/" .. seg)
        first = false
        if lfs.attributes(acc, "mode") ~= "directory" and not lfs.mkdir(acc) then
            return false
        end
    end
    return lfs.attributes(path, "mode") == "directory"
end

local function note(...)
    local args = { ... }
    pcall(function()
        local out = {}
        for i = 1, #args do out[i] = tostring(args[i]) end
        Log.warn(table.concat(out, " "))
        if Log.flush then Log.flush() end
    end)
end

--- 测试可注入根目录；正常走 Paths.root()/beautify/themes
function Theme.setRoot(dir)
    Theme._root = dir
end

function Theme.root()
    if Theme._root then return Theme._root end
    local Paths = require("utils.paths")
    return Paths.root() .. "/beautify/themes"
end

--- 主题名收成安全的目录名：保留中英文数字点横线下划线，其余换 _，空名字拒绝
---@param name any
---@return string|nil
function Theme.sanitize(name)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("[^%w%._%-\128-\255]", "_")
    name = name:gsub("_+$", ""):gsub("^_+", "")
    if name == "" then return nil end
    if #name > 48 then name = name:sub(1, 48) end
    -- 纯点名会指向 root 或其上级，.import- 是导入暂存目录的保留前缀
    if name:match("^%.+$") or name:sub(1, 8) == ".import-" then return nil end
    return name
end

function Theme.dir(name)
    local safe = Theme.sanitize(name)
    if not safe then return nil end
    return Theme.root() .. "/" .. safe
end

function Theme.exists(name)
    local dir = Theme.dir(name)
    return dir ~= nil and lfs.attributes(dir .. "/theme.lua", "mode") == "file"
end

--- 删目录树
---@param path string
---@return boolean
local function removeTree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) ~= nil end
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            if not removeTree(path .. "/" .. name) then return false end
        end
    end
    return lfs.rmdir(path) ~= nil
end

--- 已保存的主题名列表（排序）；顺手清掉上次导入崩溃残留的暂存目录
---@return string[]
function Theme.list()
    local out = {}
    local root = Theme.root()
    if lfs.attributes(root, "mode") ~= "directory" then return out end
    for name in lfs.dir(root) do
        if name:sub(1, 8) == ".import-"
            and lfs.attributes(root .. "/" .. name, "mode") == "directory" then
            removeTree(root .. "/" .. name)   -- 孤儿暂存目录，自愈
        elseif name ~= "." and name ~= ".."
            and lfs.attributes(root .. "/" .. name, "mode") == "directory"
            and lfs.attributes(root .. "/" .. name .. "/theme.lua", "mode") == "file" then
            out[#out + 1] = name
        end
    end
    table.sort(out)
    return out
end


--- 主题占用统计：图片张数 + 总大小（KB）
---@param name string
---@return integer images, integer kb
function Theme.stat(name)
    local dir = Theme.dir(name)
    local images, bytes = 0, 0
    local assets = dir and (dir .. "/assets") or nil
    if assets and lfs.attributes(assets, "mode") == "directory" then
        for f in lfs.dir(assets) do
            if f ~= "." and f ~= ".." then
                local attr = lfs.attributes(assets .. "/" .. f)
                if attr and attr.mode == "file" then
                    images = images + 1
                    bytes = bytes + (attr.size or 0)
                end
            end
        end
    end
    return images, math.ceil(bytes / 1024)
end

--- 值序列化成 Lua 字面量（配置里只有 string / number / boolean / table）
local function dump(value, depth, seen, out)
    local t = type(value)
    if t == "string" then
        out[#out + 1] = string.format("%q", value)
    elseif t == "number" then
        out[#out + 1] = string.format("%.14g", value)
    elseif t == "boolean" then
        out[#out + 1] = tostring(value)
    elseif t == "table" then
        if seen[value] or depth > 10 then
            out[#out + 1] = "nil"
            return
        end
        seen[value] = true
        out[#out + 1] = "{\n"
        for k, v in pairs(value) do
            out[#out + 1] = string.rep(" ", (depth + 1) * 2)
            if type(k) == "string" and k:match("^[A-Za-z_][A-Za-z0-9_]*$") then
                out[#out + 1] = k
            elseif type(k) == "string" then
                out[#out + 1] = "[" .. string.format("%q", k) .. "]"
            else
                out[#out + 1] = "[" .. tostring(k) .. "]"
            end
            out[#out + 1] = " = "
            dump(v, depth + 1, seen, out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = string.rep(" ", depth * 2) .. "}"
    else
        out[#out + 1] = "nil"
    end
end

local function serialize(data)
    local out = {
        "-- moon-beautify 主题包（月读美化插件）\n"
        .. "-- 图片路径是 @assets/ 相对引用，随包的 assets/ 文件夹走\nreturn " }
    dump(data, 0, {}, out)
    out[#out + 1] = "\n"
    return table.concat(out)
end

local function deepcopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepcopy(v) end
    return out
end

--- 递归改写字符串值（返回新值；table 原地遍历）
local function walk(value, fn)
    if type(value) ~= "table" then return value end
    for k, v in pairs(value) do
        if type(v) == "string" then
            value[k] = fn(v)
        elseif type(v) == "table" then
            walk(v, fn)
        end
    end
    return value
end

--- assets 里已用的文件名
local function usedNames(assetsDir)
    local used = {}
    if lfs.attributes(assetsDir, "mode") == "directory" then
        for name in lfs.dir(assetsDir) do
            if name ~= "." and name ~= ".." then used[name] = true end
        end
    end
    return used
end

local function uniqueName(used, base)
    if not used[base] then
        used[base] = true
        return base
    end
    local stem, ext = base:match("^(.*)%.(%w+)$")
    if not stem or stem == "" then stem, ext = base, "bin" end
    local i = 2
    while true do
        local candidate = stem .. "_" .. i .. "." .. ext
        if not used[candidate] then
            used[candidate] = true
            return candidate
        end
        i = i + 1
    end
end

--- 把配置里指向真实图片文件的路径收编进 assetsDir，改成 @assets/ 引用
--- 同一个源文件多处引用只收编一份
---@param conf table
---@param assetsDir string
---@return integer copied 收编的文件数
---@return string|nil first 第一张收编的文件名（当封面用）
---@return string|nil err 写入失败原因
local function collectAssets(conf, assetsDir)
    local used = usedNames(assetsDir)
    local copied = 0
    local first = nil
    local err
    local seen = {}  -- 源路径 → assets 文件名
    walk(conf, function(s)
        local ext = s:lower():match("%.(%w+)$")
        if not ext or not IMAGE_EXT[ext] then return s end
        if lfs.attributes(s, "mode") ~= "file" then return s end
        if seen[s] then return ASSET_MARK .. seen[s] end
        local src, oerr = io.open(s, "rb")
        if not src then return s end
        local data = src:read("*a")
        src:close()
        if not data or data == "" then return s end
        local base = s:match("([^/\\]+)$") or "asset.bin"
        local asset = uniqueName(used, base)
        local dest = io.open(assetsDir .. "/" .. asset, "wb")
        if not dest then
            err = err or ("写不了图片 " .. asset)
            return s
        end
        local wok = dest:write(data)
        local cok = dest:close()
        if not (wok and cok) then
            err = err or ("写图片失败 " .. asset)
            return s
        end
        seen[s] = asset
        copied = copied + 1
        if not first then first = asset end
        return ASSET_MARK .. asset
    end)
    return copied, first, err
end

--- @assets/ 引用换回主题目录下的绝对路径
local function remapAssets(conf, assetsDir)
    walk(conf, function(s)
        if s:sub(1, #ASSET_MARK) == ASSET_MARK then
            return assetsDir .. "/" .. s:sub(#ASSET_MARK + 1)
        end
        return s
    end)
end

--- 当前配置（深拷贝、剔除本机状态键）
local function snapshotConf()
    local Store = require("moonbeautify.store")
    local conf = {}
    for k, v in pairs(Store.conf()) do
        if not LOCAL_KEYS[k] then conf[k] = deepcopy(v) end
    end
    return conf
end

--- 两配置深度比较（键集合与值完全一致才相等；number 留序列化精度容差）
local function confEq(a, b)
    if a == b then return true end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return false end
    if ta ~= "table" then
        if ta == "number" then return math.abs(a - b) < 1e-9 end
        return a == b
    end
    local n = 0
    for k, v in pairs(a) do
        if not confEq(v, b[k]) then return false end
        n = n + 1
    end
    for _ in pairs(b) do n = n - 1 end
    return n == 0
end

--- 目录 assets 的内容签名：文件内容 → 文件名（比较两套图是否一样用它）
---@param dir string
---@return table
local function sigOf(dir)
    local sigs = {}
    local assets = dir .. "/assets"
    if lfs.attributes(assets, "mode") ~= "directory" then return sigs end
    for f in lfs.dir(assets) do
        local p = assets .. "/" .. f
        if lfs.attributes(p, "mode") == "file" then
            local fd = io.open(p, "rb")
            if fd then
                local d = fd:read("*a")
                fd:close()
                if d and d ~= "" then sigs[d] = f end
            end
        end
    end
    return sigs
end

--- 顺序无关的简单内容哈希（FNV 变体，取模保证不丢精度）
---@param h number
---@param s string
---@return number
local function hAdd(h, s)
    for i = 1, #s do
        h = (h * 33 + s:byte(i)) % 4294967291
    end
    return h
end

local HASH_CACHE = {}

--- 图片内容身份键："大小-哈希"。缓存按（路径,大小,修改时间）失效，
--- 同一张图拷到不同目录内容不变 → 键相同，正是「应用」与「存档」能对齐的关键。
---@param path string
---@return string|nil
local function imgKey(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then return nil end
    local ck = path .. "\1" .. tostring(attr.size) .. "\1" .. tostring(attr.modification)
    local hit = HASH_CACHE[ck]
    if hit then return hit end
    local fd = io.open(path, "rb")
    if not fd then return nil end
    local h = 5381
    while true do
        local chunk = fd:read(4096)
        if not chunk then break end
        h = hAdd(h, chunk)
    end
    fd:close()
    local key = tostring(attr.size) .. "-" .. tostring(h)
    HASH_CACHE[ck] = key
    return key
end

--- 图片引用归一化：@assets/xxx 还原成 assetsDir 下的绝对路径，
--- 再换成内容身份键 "@img/<键>"；非图片字符串原样返回
---@param s string
---@param assetsDir string
---@return string
local function imgRef(s, assetsDir)
    if s:sub(1, #ASSET_MARK) == ASSET_MARK then
        s = assetsDir .. "/" .. s:sub(#ASSET_MARK + 1)
    end
    local ext = s:lower():match("%.(%w+)$")
    if not ext or not IMAGE_EXT[ext] then return s end
    local key = imgKey(s)
    return key and ("@img/" .. key) or s
end

--- 第一处不一致的路径（诊断日志用；键名拼成 a.b.c 形式）
---@param a any 当前值
---@param b any 存档值
---@param path string|nil
---@return string|nil
local function firstDiff(a, b, path)
    path = path or ""
    if a == b then return nil end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return path .. " (type " .. ta .. " vs " .. tb .. ")" end
    if ta ~= "table" then
        if ta == "number" and math.abs(a - b) < 1e-9 then return nil end
        return string.format("%s (%s vs %s)", path, tostring(a), tostring(b))
    end
    for k, v in pairs(a) do
        local d = firstDiff(v, b[k], path .. "." .. tostring(k))
        if d then return d end
    end
    for k in pairs(b) do
        if a[k] == nil then return path .. "." .. tostring(k) .. " (only in theme)" end
    end
    return nil
end

--- 应用中的主题是否被改过（当前配置与存档有出入）
--- 图片一侧不比文件名、不比路径，统一换成「内容身份键」再比：
--- assets 里允许存在同内容多副本（保存主题时同一张图从不同路径收编很常见），
--- 按文件名归一化会随机撞到哪份副本上，导致刚应用完就误报「有修改」。
---@param name string
---@return boolean
function Theme.dirty(name)
    local dir = Theme.dir(name)
    if not dir then return false end
    local chunk = loadfile(dir .. "/theme.lua")
    if not chunk then return false end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.conf) ~= "table" then return false end

    local assetsDir = dir .. "/assets"

    -- 主题存档侧：@assets/xxx 先还原成绝对路径，再统一换内容键
    walk(data.conf, function(s) return imgRef(s, assetsDir) end)
    -- 当前配置侧：本来就是绝对路径，直接换内容键
    local cur = snapshotConf()
    walk(cur, function(s) return imgRef(s, assetsDir) end)

    local same = confEq(cur, data.conf)
    if not same then
        -- 还报差异就留一条日志，直接指出是哪个键（排查用，不影响功能）
        note("moonbeautify theme dirty", Theme.sanitize(name), firstDiff(cur, data.conf) or "?")
    end
    return not same
end


--- 把当前配置里指向 fromDir 的图片引用转给内容完全相同的另一套主题
--- （两套主题一模一样时删其一：引用无缝挪到另一套，不用先手动切换）
---@param fromDir string
---@return boolean 是否转移成功
local function redirectRefs(fromDir)
    local Store = require("moonbeautify.store")
    local prefix = fromDir .. "/"
    local myName = fromDir:match("([^/]+)$")
    local conf = Store.conf()
    -- 收集本主题被引用的图片（按内容比对，与文件名无关）
    local refs = {}
    walk(conf, function(s)
        if type(s) == "string" and s:sub(1, #prefix) == prefix
            and lfs.attributes(s, "mode") == "file" then
            refs[s] = true
        end
        return s
    end)
    if not next(refs) then return false end
    for _i, other in ipairs(Theme.list()) do
        if Theme.sanitize(other) ~= myName then
            local odir = Theme.dir(other)
            if odir then
                local osigs = sigOf(odir)
                if next(osigs) then
                    -- 每张被引用的图都能在另一套的 assets 里找到同内容文件才转
                    local repl, okAll = {}, true
                    for p in pairs(refs) do
                        local fd = io.open(p, "rb")
                        local d = fd and fd:read("*a") or nil
                        if fd then fd:close() end
                        local f = d and osigs[d] or nil
                        if f then
                            repl[p] = odir .. "/assets/" .. f
                        else
                            okAll = false
                            break
                        end
                    end
                    if okAll then
                        walk(conf, function(s)
                            return repl[s] or s
                        end)
                        if conf.active_theme == myName then
                            conf.active_theme = Theme.sanitize(other)
                        end
                        Store.save()
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- 把当前配置存成主题（同名覆盖）
---@param name string
---@return boolean ok, string|nil err
function Theme.save(name)
    local safe = Theme.sanitize(name)
    if not safe then return false, "名字不能为空" end
    local dir = Theme.root() .. "/" .. safe
    if not mkdirp(dir) then
        return false, "建不了主题目录"
    end
    -- 配置里的图片可能正指向本主题旧的 assets，所以先写到临时位置，全部成功后再替换
    local newAssets = dir .. "/.assets-new"
    local tmpFile = dir .. "/.theme.lua.new"
    removeTree(newAssets)
    if not lfs.mkdir(newAssets) then return false, "建不了 assets 目录" end
    local conf = snapshotConf()
    local copied, first, cerr = collectAssets(conf, newAssets)
    if cerr then
        removeTree(newAssets)
        return false, cerr
    end
    local file, werr = io.open(tmpFile, "w")
    if not file then
        removeTree(newAssets)
        return false, werr or "写不了 theme.lua"
    end
    local wok = file:write(serialize({
        kind = THEME_KIND,          -- 格式标识：导入时先认身份
        version = THEME_FORMAT,     -- 格式版本：将来 conf 键结构升级时做迁移判断
        name = safe,
        conf = conf,
        cover = first and (ASSET_MARK .. first) or nil,   -- 列表缩略图
    }))
    local cok = file:close()
    if not (wok and cok) then
        removeTree(newAssets)
        os.remove(tmpFile)
        return false, "写 theme.lua 失败"
    end
    removeTree(dir .. "/assets")
    if not os.rename(newAssets, dir .. "/assets") or not os.rename(tmpFile, dir .. "/theme.lua") then
        return false, "替换主题文件失败"
    end
    note("moonbeautify theme saved", safe, copied .. " assets")
    return true, dir
end

--- 应用主题（合并进当前配置）
---@param name string
---@return boolean ok, string|nil err
function Theme.apply(name)
    local dir = Theme.dir(name)
    if not dir or lfs.attributes(dir .. "/theme.lua", "mode") ~= "file" then
        return false, "主题不存在"
    end
    local chunk, err = loadfile(dir .. "/theme.lua")
    if not chunk then return false, "theme.lua 损坏：" .. tostring(err) end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" or type(data.conf) ~= "table" then
        return false, "主题文件内容不对"
    end
    remapAssets(data.conf, dir .. "/assets")
    local Store = require("moonbeautify.store")
    local conf = Store.conf()
    -- 彻底替换：存档里没有的外观键一律清掉，保证应用后与主题原样一致
    for k in pairs(conf) do
        if not LOCAL_KEYS[k] then conf[k] = nil end
    end
    for k, v in pairs(data.conf) do
        if not LOCAL_KEYS[k] then conf[k] = v end
    end
    conf.active_theme = Theme.sanitize(name)
    Store.save()
    note("moonbeautify theme applied", Theme.sanitize(name))
    return true
end

--- 删除主题
---@param name string
---@return boolean ok, string|nil err
function Theme.delete(name)
    local dir = Theme.dir(name)
    if not dir then return false, "名字不合法" end
    if lfs.attributes(dir, "mode") ~= "directory" then return false, "主题不存在" end
    -- 当前配置若还引用着该主题的图片，删掉会产生悬空路径：优先转给内容相同的另一套主题，
    -- 转移不成（没有等价主题）才拒绝
    local prefix = dir .. "/"
    local used = false
    walk(require("moonbeautify.store").conf(), function(s)
        if type(s) == "string" and s:sub(1, #prefix) == prefix then used = true end
        return s
    end)
    if used and not redirectRefs(dir) then
        return false, "beautify_in_use"
    end
    -- 月读原生的界面壁纸 / 锁屏壁纸也可能引用主题图片（把主题里的图设成了壁纸），说明来源
    local okMS, MoonSettings = pcall(require, "utils.settings")
    local nativeHits = {}
    if okMS and MoonSettings then
        for _, spec in ipairs({ { "features.wallpaper", "界面壁纸" }, { "features.lockscreen", "锁屏壁纸" } }) do
            local ok, conf = pcall(function() return MoonSettings.get(spec[1]) end)
            if ok and type(conf) == "table" then
                for _, v in pairs(conf) do
                    if type(v) == "string" and v:sub(1, #prefix) == prefix then
                        nativeHits[#nativeHits + 1] = spec[2]
                        break
                    end
                end
            end
        end
    end
    if #nativeHits > 0 then
        return false, table.concat(nativeHits, "、") .. "正在使用本主题下的图片"
    end
    if not removeTree(dir) then return false, "删不掉主题目录" end
    -- 悬空标记一并清掉：否则配置里还记着这个名字，列表里会留个看不见的「应用中」
    local Store = require("moonbeautify.store")
    if Store.conf().active_theme == Theme.sanitize(name) then
        Store.conf().active_theme = nil
        Store.save()
    end
    note("moonbeautify theme deleted", Theme.sanitize(name))
    return true
end

--- 导出主题成 zip（写到 destDir/<主题名>.zip）
---@param name string
---@param destDir string
---@return boolean ok, string|nil path_or_err
function Theme.export(name, destDir)
    local dir = Theme.dir(name)
    if not dir or lfs.attributes(dir .. "/theme.lua", "mode") ~= "file" then
        return false, "主题不存在"
    end
    local safe = Theme.sanitize(name)
    local src = io.open(dir .. "/theme.lua", "rb")
    if not src then return false, "读不了 theme.lua" end
    local themeData = src:read("*a")
    src:close()
    local files = { { name = "theme.lua", data = themeData } }
    local assetsDir = dir .. "/assets"
    if lfs.attributes(assetsDir, "mode") == "directory" then
        for asset in lfs.dir(assetsDir) do
            if asset ~= "." and asset ~= ".." then
                local f = io.open(assetsDir .. "/" .. asset, "rb")
                if f then
                    files[#files + 1] = { name = "assets/" .. asset, data = f:read("*a") }
                    f:close()
                end
            end
        end
    end
    local Zip = require("moonbeautify.zip")
    local path = destDir .. "/" .. safe .. ".zip"
    local ok, err = Zip.write(path, files)
    if not ok then
        note("moonbeautify theme export failed", path, err)
        return false, err
    end
    note("moonbeautify theme exported", path, #files - 1 .. " assets")
    return true, path
end

--- 导入 zip 成主题
---@param zipPath string
---@return boolean ok, string|nil name_or_err
function Theme.importZip(zipPath)
    if type(zipPath) ~= "string" or zipPath == ""
        or lfs.attributes(zipPath, "mode") ~= "file" then
        return false, "zip 文件不存在"
    end
    local root = Theme.root()
    if not mkdirp(root) then
        return false, "建不了主题目录"
    end
    local staging = root .. "/.import-" .. tostring(os.time())
    removeTree(staging)
    if not lfs.mkdir(staging) then return false, "建不了暂存目录" end
    local reader = require("ffi/archiver").Reader:new()
    if not reader:open(zipPath) then
        removeTree(staging)
        return false, reader.err or "打不开 zip"
    end
    for entry in reader:iterate() do
        -- 只解相对路径，防 zip 路径穿越
        if entry.path and not entry.path:match("%.%.") and entry.path:sub(1, 1) ~= "/" then
            reader:extractToPath(entry.path, staging .. "/" .. entry.path)
        end
    end
    local rerr = reader.err
    reader:close()
    if rerr then
        removeTree(staging)
        return false, "解压失败：" .. tostring(rerr)
    end
    -- theme.lua 在包根或一级子目录
    local base
    if lfs.attributes(staging .. "/theme.lua", "mode") == "file" then
        base = staging
    else
        for n in lfs.dir(staging) do
            if n ~= "." and n ~= ".."
                and lfs.attributes(staging .. "/" .. n .. "/theme.lua", "mode") == "file" then
                base = staging .. "/" .. n
            end
        end
    end
    if not base then
        removeTree(staging)
        return false, "zip 里没有 theme.lua"
    end
    local chunk = loadfile(base .. "/theme.lua")
    -- 不能写 `chunk and pcall(chunk) or false`：and/or 会把 pcall 的多值截成单值，
    -- data 永远是 nil（曾经导致包内 name 字段失效，主题名一直取 zip 文件名）
    local ok, data
    if chunk then ok, data = pcall(chunk) end
    -- 身份校验：声明了 kind 但不是月读美化主题的包，明确拒绝（旧包没写 kind，照收，向后兼容）
    if ok and type(data) == "table" and data.kind ~= nil and data.kind ~= THEME_KIND then
        removeTree(staging)
        return false, "这不是月读美化的主题包"
    end
    local cname = (ok and type(data) == "table") and data.name or nil
    local zipName = zipPath:match("([^/\\]+)$")
    local fromFile = zipName and zipName:match("^(.*)%.[%w]+$") or zipName
    local name = Theme.sanitize(cname or fromFile) or "theme"
    local dest = root .. "/" .. name
    -- 先把旧主题挪开，新主题就位后再删；失败时还原，避免覆盖导入丢掉旧主题
    local backup = staging .. "-old"
    local hadOld = lfs.attributes(dest, "mode") ~= nil
    if hadOld and not os.rename(dest, backup) then
        removeTree(staging)
        return false, "挪不开旧主题"
    end
    if not os.rename(base, dest) then
        if hadOld then os.rename(backup, dest) end
        removeTree(staging)
        return false, "挪不进主题目录"
    end
    if hadOld then removeTree(backup) end
    removeTree(staging)
    note("moonbeautify theme imported", name, zipPath)
    return true, name
end

return Theme
