local romDir = arg[1] or "sim/ccrom"
local outPath = arg[2] or "tools/luals/library/cc163.lua"

local NATIVE = {
    os = { "queueEvent", "startTimer", "setAlarm", "shutdown", "reboot", "computerID", "getComputerID",
        "setComputerLabel", "computerLabel", "getComputerLabel", "clock", "time", "day", "cancelTimer",
        "cancelAlarm", "version", "pullEventRaw", "pullEvent", "run", "loadAPI", "unloadAPI", "sleep" },
    fs = { "list", "combine", "getName", "getSize", "exists", "isDir", "isReadOnly", "makeDir", "move",
        "copy", "delete", "open", "getDrive", "getFreeSpace", "find", "getDir" },
    term = { "write", "scroll", "setCursorPos", "setCursorBlink", "getCursorPos", "getSize", "clear",
        "clearLine", "setTextColour", "setTextColor", "setBackgroundColour", "setBackgroundColor",
        "isColour", "isColor" },
    redstone = { "getSides", "setOutput", "getOutput", "getInput", "setBundledOutput", "getBundledOutput",
        "getBundledInput", "testBundledInput", "setAnalogOutput", "setAnalogueOutput", "getAnalogOutput",
        "getAnalogueOutput", "getAnalogInput", "getAnalogueInput" },
    http = { "request", "get", "post" },
    bit = { "bnot", "band", "bor", "bxor", "brshift", "blshift", "blogic_rshift" },
    turtle = { "forward", "back", "up", "down", "turnLeft", "turnRight", "dig", "digUp", "digDown",
        "place", "placeUp", "placeDown", "drop", "select", "getItemCount", "getItemSpace", "detect",
        "detectUp", "detectDown", "compare", "compareUp", "compareDown", "attack", "attackUp",
        "attackDown", "dropUp", "dropDown", "suck", "suckUp", "suckDown", "getFuelLevel", "refuel",
        "compareTo", "transferTo", "getSelectedSlot", "getFuelLimit", "equipLeft", "equipRight", "craft" },
    shell = { "aliases", "clearAlias", "dir", "exit", "getRunningProgram", "path", "programs", "resolve",
        "resolveProgram", "run", "setAlias", "setDir", "setPath" },
    multishell = { "getCount", "getCurrent", "getFocus", "getTitle", "launch", "setFocus", "setTitle" },
}

local FIELDS = {
    turtle = { "native" },
}

local OPEN = { keys = true, colors = true, colours = true }

local function read(path)
    local h = io.open(path, "rb")
    if not h then return nil end
    local s = h:read("*a")
    h:close()
    return s
end

local apis = {}
local order = {}
local function api(name)
    if not apis[name] then
        apis[name] = { funcs = {}, fields = {} }
        order[#order + 1] = name
    end
    return apis[name]
end

for name, list in pairs(NATIVE) do
    local a = api(name)
    for _, f in ipairs(list) do a.funcs[f] = true end
end
for name, list in pairs(FIELDS) do
    local a = api(name)
    for _, f in ipairs(list) do a.fields[f] = true end
end

local p = io.popen('ls "' .. romDir .. '/rom/apis"')
for file in p:lines() do
    local src = read(romDir .. "/rom/apis/" .. file)
    if src then
        local a = api(file)
        for f in src:gmatch("\nfunction ([%w_]+)%s*%(") do a.funcs[f] = true end
        for f in src:gmatch("^function ([%w_]+)%s*%(") do a.funcs[f] = true end
        for f in src:gmatch("\n([%a_][%w_]*)%s*=[^=]") do
            if f ~= "local" then a.fields[f] = true end
        end
    end
end
p:close()
api("rs")
table.sort(order)

local out = { "---@meta", "" }
local function emit(line) out[#out + 1] = line end

for _, name in ipairs(order) do
    if name ~= "rs" then
        local a = apis[name]
        if OPEN[name] then
            emit(name .. " = {}")
            for f in pairs(a.funcs) do emit("function " .. name .. "." .. f .. "(...) end") end
        else
            emit("---@class cc163." .. name)
            local fields = {}
            for f in pairs(a.fields) do if not a.funcs[f] then fields[#fields + 1] = f end end
            table.sort(fields)
            for _, f in ipairs(fields) do emit("---@field " .. f .. " any") end
            local funcs = {}
            for f in pairs(a.funcs) do funcs[#funcs + 1] = f end
            table.sort(funcs)
            for _, f in ipairs(funcs) do emit("---@field " .. f .. " fun(...):...") end
            emit(name .. " = {}")
        end
        emit("")
    end
end

emit("---@type cc163.redstone")
emit("rs = {}")
emit("")
for _, g in ipairs({ "sleep", "write", "print", "printError", "read", "loadfile", "dofile", "loadstring" }) do
    emit("function " .. g .. "(...) end")
end

local h = assert(io.open(outPath, "wb"))
h:write(table.concat(out, "\n"), "\n")
h:close()
print("wrote " .. outPath)
