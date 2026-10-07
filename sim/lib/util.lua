local U = {}

U.DIRS = {
    [0] = { 0, 0, -1 },
    [1] = { 1, 0, 0 },
    [2] = { 0, 0, 1 },
    [3] = { -1, 0, 0 },
}

U.WORLD_DIRS = {
    N = { 0, 0, -1 },
    S = { 0, 0, 1 },
    E = { 1, 0, 0 },
    W = { -1, 0, 0 },
    U = { 0, 1, 0 },
    D = { 0, -1, 0 },
}

function U.key(x, y, z)
    return x .. "," .. y .. "," .. z
end

function U.unkey(k)
    local x, y, z = k:match("^(-?%d+),(-?%d+),(-?%d+)$")
    return tonumber(x), tonumber(y), tonumber(z)
end

function U.sideVector(facing, side)
    if side == "top" then return 0, 1, 0 end
    if side == "bottom" then return 0, -1, 0 end
    local f = facing
    if side == "back" then f = (facing + 2) % 4
    elseif side == "left" then f = (facing + 3) % 4
    elseif side == "right" then f = (facing + 1) % 4
    elseif side ~= "front" then return nil end
    local d = U.DIRS[f]
    return d[1], d[2], d[3]
end

function U.deepcopy(v, seen)
    if type(v) ~= "table" then
        if type(v) == "function" or type(v) == "thread" or type(v) == "userdata" then return nil end
        return v
    end
    seen = seen or {}
    if seen[v] then return nil end
    seen[v] = true
    local r = {}
    for k, x in pairs(v) do
        local ck = U.deepcopy(k, seen)
        if ck ~= nil then r[ck] = U.deepcopy(x, seen) end
    end
    seen[v] = nil
    return r
end

function U.copyTable(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

function U.decode(text)
    if type(text) ~= "string" then return nil end
    local fn = loadstring("return " .. text)
    if not fn then return nil end
    setfenv(fn, {})
    local ok, value = pcall(fn)
    if ok then return value end
    return nil
end

function U.posText(p)
    if type(p) ~= "table" then return "nil" end
    return tostring(p.x) .. "," .. tostring(p.y) .. "," .. tostring(p.z)
end

function U.readHostFile(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local data = h:read("*a")
    h:close()
    return data
end

function U.writeHostFile(path, data)
    local h = assert(io.open(path, "wb"))
    h:write(data)
    h:close()
end

function U.split(text, sep)
    local out = {}
    for part in (text or ""):gmatch("[^" .. sep .. "]+") do out[#out + 1] = part end
    return out
end

local function band32(a, b)
    local r, bit = 0, 1
    a = a % 4294967296
    b = b % 4294967296
    for _ = 1, 32 do
        if a % 2 == 1 and b % 2 == 1 then r = r + bit end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bit = bit * 2
    end
    return r
end

local function bor32(a, b)
    a = a % 4294967296
    b = b % 4294967296
    return a + b - band32(a, b)
end

local function bxor32(a, b)
    a = a % 4294967296
    b = b % 4294967296
    return a + b - 2 * band32(a, b)
end

local function signed(v)
    v = v % 4294967296
    if v >= 2147483648 then return v - 4294967296 end
    return v
end

U.bitApi = function()
    return {
        band = function(a, b) return signed(band32(a, b)) end,
        bor = function(a, b) return signed(bor32(a, b)) end,
        bxor = function(a, b) return signed(bxor32(a, b)) end,
        bnot = function(a) return signed(4294967295 - (a % 4294967296)) end,
        blshift = function(a, n) return signed((a % 4294967296) * 2 ^ n) end,
        brshift = function(a, n)
            local v = signed(a)
            return math.floor(v / 2 ^ n)
        end,
        blogic_rshift = function(a, n) return signed(math.floor((a % 4294967296) / 2 ^ n)) end,
    }
end

return U
