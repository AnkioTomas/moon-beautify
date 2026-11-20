--[[--
最小 zip 打包器（仅写入，STORED 不压缩）。

图片素材是几百 KB 到几 MB 的量级，STORED 足够用，换来的是零依赖——
纯 Lua 实现本地文件头 + 中央目录 + CRC32，不碰外部命令和压缩库。
解压交给月读自带的 ffi/archiver.Reader（libarchive，能读 STORED 和 DEFLATE）。

@module moonbeautify.zip
--]]--

local bit = require("bit")

local Zip = {}

--- CRC32 查表
local CRC_TABLE = {}
for i = 0, 255 do
    local c = i
    for _ = 1, 8 do
        if bit.band(c, 1) == 1 then
            c = bit.bxor(0xedb88320, bit.rshift(c, 1))
        else
            c = bit.rshift(c, 1)
        end
    end
    CRC_TABLE[i] = c
end

local function crc32(data)
    local crc = 0xffffffff
    for i = 1, #data do
        crc = bit.bxor(bit.rshift(crc, 8), CRC_TABLE[bit.band(bit.bxor(crc, data:byte(i)), 0xff)])
    end
    return bit.bnot(crc) % 4294967296
end

--- 小端字节串（不用 string.pack，兼容 LuaJIT 5.1）
local function u16(v)
    v = v % 65536
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
    v = v % 4294967296
    return string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256
    )
end

--- 当前时间的 DOS 时间戳
---@return integer date integer time
local function dosTime()
    local t = os.date("*t")
    local date = bit.bor(bit.bor((t.year - 1980) * 512, t.month * 32), t.day)
    local time = bit.bor(bit.bor(t.hour * 2048, t.min * 32), math.floor(t.sec / 2))
    return date, time
end

--- 打包：files 是 { { name = "theme.lua", data = "..." }, ... }，name 用 / 分隔
---@param zipPath string
---@param files table
---@return boolean ok, string|nil err
function Zip.write(zipPath, files)
    if type(files) ~= "table" or #files == 0 then return false, "没有要打包的文件" end
    local date, time = dosTime()
    local locals, centrals = {}, {}
    local offset = 0
    for _i, f in ipairs(files) do
        local name = tostring(f.name):gsub("\\", "/")
        local data = tostring(f.data or "")
        local crc = crc32(data)
        local size = #data
        local local_header = "PK\x03\x04" .. u16(20) .. u16(0) .. u16(0)
            .. u16(time) .. u16(date) .. u32(crc) .. u32(size) .. u32(size)
            .. u16(#name) .. u16(0) .. name
        locals[#locals + 1] = local_header .. data
        centrals[#centrals + 1] = "PK\x01\x02" .. u16(20) .. u16(20) .. u16(0) .. u16(0)
            .. u16(time) .. u16(date) .. u32(crc) .. u32(size) .. u32(size)
            .. u16(#name) .. u16(0) .. u16(0) .. u16(0) .. u16(0) .. u32(0) .. u32(offset) .. name
        offset = offset + #local_header + size
    end
    local central = table.concat(centrals)
    local eocd = "PK\x05\x06" .. u16(0) .. u16(0) .. u16(#centrals) .. u16(#centrals)
        .. u32(#central) .. u32(offset) .. u16(0)
    local blob = table.concat(locals) .. central .. eocd
    local file, err = io.open(zipPath, "wb")
    if not file then return false, err or "打不开文件" end
    local wok = file:write(blob)
    local cok = file:close()
    if not (wok and cok) then return false, "写入 zip 失败" end
    return true
end

return Zip
