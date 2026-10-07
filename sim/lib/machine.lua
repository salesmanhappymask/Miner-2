local U = require("util")
local Turtle = require("turtle")

local Machine = {}
Machine.__index = Machine

local SIDES = { "top", "bottom", "left", "right", "front", "back" }
local VALID_SIDE = {}
for _, s in ipairs(SIDES) do VALID_SIDE[s] = true end

function Machine.new(sim, def)
    local m = setmetatable({}, Machine)
    m.sim = sim
    m.id = def.id
    m.name = def.name or ("computer" .. def.id)
    m.kind = def.kind or "computer"
    m.label = def.label
    m.files = {}
    m.dirs = {}
    for path, content in pairs(def.files or {}) do m:writeFile(path, content) end
    m.attachments = {}
    for side, a in pairs(def.attachments or {}) do
        local copy = U.copyTable(a)
        copy.channels = {}
        m.attachments[side] = copy
    end
    m.facing = def.facing or 0
    m.fuel = def.fuel or 0
    m.fuelLimit = def.fuelLimit or 100000
    m.inv = def.inv or {}
    m.slot = 1
    m.on = false
    m.gen = 0
    m.outputs = {}
    m.screen = {}
    m.transcript = {}
    m.boots = 0
    m.dropped = 0
    m.errors = {}
    return m
end

local function normalize(path)
    path = tostring(path or "")
    path = path:gsub("\\", "/")
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 then parts[#parts] = nil end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    return table.concat(parts, "/")
end
Machine.normalize = normalize

local function parentOf(path)
    local p = path:match("^(.*)/[^/]*$")
    return p or ""
end

function Machine:isRom(path)
    return path == "rom" or path:sub(1, 4) == "rom/"
end

function Machine:makeDirs(path)
    local acc = ""
    for part in path:gmatch("[^/]+") do
        acc = acc == "" and part or (acc .. "/" .. part)
        self.dirs[acc] = true
    end
end

function Machine:writeFile(path, content)
    path = normalize(path)
    local parent = parentOf(path)
    if parent ~= "" then self:makeDirs(parent) end
    self.files[path] = content
    if self.sim and self.sim.onFileWrite then self.sim:onFileWrite(self, path, content) end
end

function Machine:readFile(path)
    return self.files[normalize(path)]
end

function Machine:exists(path)
    path = normalize(path)
    if path == "" then return true end
    if self:isRom(path) then
        return self.sim.rom.files[path] ~= nil or self.sim.rom.dirs[path] ~= nil
    end
    return self.files[path] ~= nil or self.dirs[path] == true
end

function Machine:isDir(path)
    path = normalize(path)
    if path == "" then return true end
    if self:isRom(path) then return self.sim.rom.dirs[path] ~= nil end
    return self.dirs[path] == true
end

function Machine:log(text)
    self.sim:log(self.name, text)
end

function Machine:commitScreenLine(y)
    local line = self.screen[y]
    if line and line:match("%S") then
        self.transcript[#self.transcript + 1] = string.format("[%9.2f] %s", self.sim.sched.now, line)
        if #self.transcript > 4000 then table.remove(self.transcript, 1) end
    end
end

function Machine:makeTerm()
    local m = self
    local w, h = 51, 19
    if m.kind == "turtle" then w, h = 39, 13 end
    local cx, cy = 1, 1
    m.screen = {}
    local t = {}
    function t.getSize() return w, h end
    function t.getCursorPos() return cx, cy end
    function t.setCursorPos(x, y)
        x, y = math.floor(tonumber(x) or 1), math.floor(tonumber(y) or 1)
        if y ~= cy then m:commitScreenLine(cy) end
        cx, cy = x, y
    end
    function t.write(text)
        text = tostring(text)
        local line = m.screen[cy] or ""
        if #line < cx - 1 then line = line .. string.rep(" ", cx - 1 - #line) end
        line = line:sub(1, cx - 1) .. text .. line:sub(cx + #text)
        m.screen[cy] = line:sub(1, w)
        cx = cx + #text
    end
    function t.clear()
        for y = 1, h do m:commitScreenLine(y) end
        m.screen = {}
    end
    function t.clearLine()
        m:commitScreenLine(cy)
        m.screen[cy] = ""
    end
    function t.scroll(n)
        n = tonumber(n) or 1
        for _ = 1, n do
            m:commitScreenLine(1)
            for y = 1, h - 1 do m.screen[y] = m.screen[y + 1] end
            m.screen[h] = ""
        end
    end
    function t.setCursorBlink() end
    function t.isColor() return false end
    t.isColour = t.isColor
    function t.setTextColor() end
    t.setTextColour = t.setTextColor
    function t.setBackgroundColor() end
    t.setBackgroundColour = t.setBackgroundColor
    return t
end

function Machine:makeFs()
    local m = self
    local fs = {}
    function fs.list(path)
        path = normalize(path)
        if not m:isDir(path) then error("Not a directory", 2) end
        local out, seen = {}, {}
        local function add(full)
            local rel
            if path == "" then rel = full else
                if full:sub(1, #path + 1) ~= path .. "/" then return end
                rel = full:sub(#path + 2)
            end
            local name = rel:match("^[^/]+")
            if name and not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end
        if m:isRom(path) or path == "" then
            for p in pairs(m.sim.rom.files) do add(p) end
            for p in pairs(m.sim.rom.dirs) do add(p) end
        end
        if not m:isRom(path) then
            for p in pairs(m.files) do add(p) end
            for p in pairs(m.dirs) do add(p) end
        end
        table.sort(out)
        return out
    end
    function fs.exists(path) return m:exists(path) end
    function fs.isDir(path) return m:isDir(path) end
    function fs.isReadOnly(path)
        path = normalize(path)
        return m:isRom(path)
    end
    function fs.getName(path)
        path = normalize(path)
        if path == "" then return "root" end
        return path:match("([^/]+)$")
    end
    function fs.getDrive(path)
        path = normalize(path)
        if not m:exists(path) then return nil end
        if m:isRom(path) then return "rom" end
        return "hdd"
    end
    function fs.getSize(path)
        path = normalize(path)
        if m:isRom(path) then
            local c = m.sim.rom.files[path]
            if c then return #c end
            if m.sim.rom.dirs[path] then return 0 end
            error("No such file", 2)
        end
        local c = m.files[path]
        if c then return #c end
        if m.dirs[path] then return 0 end
        error("No such file", 2)
    end
    function fs.getFreeSpace()
        local used = 0
        for _, c in pairs(m.files) do used = used + #c + 500 end
        return math.max(0, (m.sim.diskSize or 1000000) - used)
    end
    function fs.makeDir(path)
        path = normalize(path)
        if m:isRom(path) then error("Access denied", 2) end
        if m.files[path] then error("File exists", 2) end
        m:makeDirs(path)
    end
    local function subtree(path)
        local list = {}
        for p in pairs(m.files) do
            if p == path or p:sub(1, #path + 1) == path .. "/" then list[#list + 1] = { p, "f" } end
        end
        for p in pairs(m.dirs) do
            if p == path or p:sub(1, #path + 1) == path .. "/" then list[#list + 1] = { p, "d" } end
        end
        return list
    end
    function fs.delete(path)
        path = normalize(path)
        if m:isRom(path) then error("Access denied", 2) end
        if path == "" then
            m.files, m.dirs = {}, {}
            return
        end
        for _, item in ipairs(subtree(path)) do
            if item[2] == "f" then m.files[item[1]] = nil else m.dirs[item[1]] = nil end
        end
        if m.sim.onFileDelete then m.sim:onFileDelete(m, path) end
    end
    local function copyInto(a, b, move)
        a, b = normalize(a), normalize(b)
        if not m:exists(a) then error("No such file", 3) end
        if m:exists(b) then error("File exists", 3) end
        if m:isRom(b) then error("Access denied", 3) end
        if move and m:isRom(a) then error("Access denied", 3) end
        if m:isRom(a) then
            if m.sim.rom.files[a] then m:writeFile(b, m.sim.rom.files[a]) return end
            error("Cannot copy ROM directories", 3)
        end
        local items = subtree(a)
        for _, item in ipairs(items) do
            local target = b .. item[1]:sub(#a + 1)
            if item[2] == "f" then m:writeFile(target, m.files[item[1]]) else m:makeDirs(target) end
        end
        if move then
            for _, item in ipairs(items) do
                if item[2] == "f" then m.files[item[1]] = nil else m.dirs[item[1]] = nil end
            end
        end
    end
    function fs.move(a, b) copyInto(a, b, true) end
    function fs.copy(a, b) copyInto(a, b, false) end
    function fs.combine(a, b) return normalize(tostring(a) .. "/" .. tostring(b)) end
    function fs.open(path, mode)
        path = normalize(path)
        mode = tostring(mode or "r")
        if mode == "r" or mode == "rb" then
            local content
            if m:isRom(path) then content = m.sim.rom.files[path] else content = m.files[path] end
            if not content then return nil end
            local pos, open = 1, true
            local h = {}
            function h.close() open = false end
            if mode == "rb" then
                function h.read()
                    if not open then error("Stream closed", 2) end
                    if pos > #content then return nil end
                    local b = content:byte(pos)
                    pos = pos + 1
                    return b
                end
            else
                function h.readLine()
                    if not open then error("Stream closed", 2) end
                    if pos > #content then return nil end
                    local nl = content:find("\n", pos, true)
                    local line
                    if nl then
                        line = content:sub(pos, nl - 1)
                        pos = nl + 1
                    else
                        line = content:sub(pos)
                        pos = #content + 1
                    end
                    return (line:gsub("\r$", ""))
                end
                function h.readAll()
                    if not open then error("Stream closed", 2) end
                    local r = content:sub(pos)
                    pos = #content + 1
                    return r
                end
            end
            return h
        end
        if mode == "w" or mode == "a" or mode == "wb" or mode == "ab" then
            if m:isRom(path) or m.dirs[path] then return nil end
            local buffer
            if mode:sub(1, 1) == "a" then buffer = m.files[path] or "" else buffer = "" end
            m:writeFile(path, buffer)
            local open = true
            local h = {}
            local function put(text)
                if not open then error("Stream closed", 3) end
                buffer = buffer .. text
                m:writeFile(path, buffer)
            end
            if mode:sub(2, 2) == "b" then
                function h.write(b) put(string.char(math.floor(tonumber(b) or 0) % 256)) end
            else
                function h.write(text) put(tostring(text)) end
                function h.writeLine(text) put(tostring(text) .. "\n") end
            end
            function h.flush() end
            function h.close() open = false end
            return h
        end
        error("Unsupported mode", 2)
    end
    return fs
end

function Machine:sideTarget(side)
    if not VALID_SIDE[side] then return nil end
    local a = self.attachments[side]
    if a then
        if a.type == "modem" then return { kind = "modem", modem = a } end
        return nil
    end
    if self.x == nil then return nil end
    local b = self.sim.world:neighbor(self, side)
    if b and b.kind == "machine" then return { kind = "machine", machine = b.machine } end
    if b and b.peripheral then return { kind = "custom", impl = b.peripheral } end
    return nil
end

function Machine:modemMethods(side, a)
    local m = self
    local methods = {}
    function methods.isWireless() return a.wireless == true end
    function methods.open(ch)
        ch = tonumber(ch)
        if not ch or ch < 0 or ch > 65535 then error("Expected number in range 0-65535", 2) end
        a.channels[ch] = true
    end
    function methods.close(ch) a.channels[tonumber(ch)] = nil end
    function methods.isOpen(ch) return a.channels[tonumber(ch)] == true end
    function methods.closeAll() a.channels = {} end
    function methods.transmit(ch, reply, message)
        m.sim.net:transmit(m, side, a, tonumber(ch), tonumber(reply), message)
    end
    function methods.getNamesRemote() return {} end
    function methods.isPresentRemote() return false end
    function methods.getTypeRemote() return nil end
    function methods.getMethodsRemote() return nil end
    function methods.callRemote() error("No peripheral attached", 2) end
    return methods
end

function Machine:computerMethods(target)
    local sim = self.sim
    local methods = {}
    function methods.getID() return target.id end
    function methods.isOn() return target.on == true end
    function methods.turnOn()
        if not target.on then target:requestBoot(0.05, "turnOn by neighbor") end
    end
    function methods.shutdown()
        sim.sched:after(0.05, function() target:powerOff("shutdown by neighbor") end)
    end
    function methods.reboot()
        sim.sched:after(0.05, function()
            target:powerOff("reboot by neighbor")
            target:requestBoot(0.05, "reboot by neighbor")
        end)
    end
    return methods
end

function Machine:peripheralMethods(side)
    local t = self:sideTarget(side)
    if not t then return nil end
    if t.kind == "modem" then return self:modemMethods(side, t.modem), "modem" end
    if t.kind == "machine" then
        return self:computerMethods(t.machine), t.machine.kind == "turtle" and "turtle" or "computer"
    end
    if t.kind == "custom" then return t.impl.methods, t.impl.type end
    return nil
end

function Machine:makePeripheral()
    local m = self
    local p = {}
    function p.isPresent(side) return m:peripheralMethods(side) ~= nil end
    function p.getType(side)
        local _, kind = m:peripheralMethods(side)
        return kind
    end
    function p.getMethods(side)
        local methods = m:peripheralMethods(side)
        if not methods then return nil end
        local names = {}
        for k in pairs(methods) do names[#names + 1] = k end
        table.sort(names)
        return names
    end
    function p.call(side, method, ...)
        local methods = m:peripheralMethods(side)
        if not methods then error("No peripheral attached", 2) end
        local fn = methods[method]
        if not fn then error("No such method " .. tostring(method), 2) end
        return fn(...)
    end
    return p
end

function Machine:makeRedstone()
    local m = self
    local rs = {}
    function rs.getSides() return { "top", "bottom", "left", "right", "front", "back" } end
    function rs.setOutput(side, value)
        if not VALID_SIDE[side] then error("Invalid side.", 2) end
        value = value and true or false
        local old = m.outputs[side] or false
        m.outputs[side] = value
        if old ~= value then
            m.sim:log(m.name, "redstone " .. side .. " " .. tostring(value))
            m.sim.world:signal(m, side, value)
        end
    end
    function rs.getOutput(side) return m.outputs[side] or false end
    function rs.getInput() return false end
    function rs.setAnalogOutput(side, v) rs.setOutput(side, (tonumber(v) or 0) > 0) end
    rs.setAnalogueOutput = rs.setAnalogOutput
    function rs.getAnalogOutput(side) return m.outputs[side] and 15 or 0 end
    rs.getAnalogueOutput = rs.getAnalogOutput
    function rs.getAnalogInput() return 0 end
    rs.getAnalogueInput = rs.getAnalogInput
    function rs.setBundledOutput() end
    function rs.getBundledOutput() return 0 end
    function rs.getBundledInput() return 0 end
    function rs.testBundledInput() return false end
    return rs
end

function Machine:makeOs()
    local m = self
    local sim = m.sim
    local os = {}
    local timerId = 0
    function os.getComputerID() return m.id end
    os.computerID = os.getComputerID
    function os.getComputerLabel() return m.label end
    os.computerLabel = os.getComputerLabel
    function os.setComputerLabel(label)
        if label ~= nil then label = tostring(label) end
        m.label = label
    end
    function os.queueEvent(...)
        m:queueEvent(0, ...)
    end
    function os.startTimer(t)
        t = tonumber(t) or 0
        timerId = timerId + 1
        local id = timerId
        local ticks = math.max(1, math.ceil(t / 0.05 - 1e-9))
        m:queueEvent(ticks * 0.05, "timer", id)
        return id
    end
    function os.setAlarm(t)
        timerId = timerId + 1
        return timerId
    end
    function os.clock()
        return math.floor((sim.sched.now - (m.bootTime or 0)) * 20 + 0.5) / 20
    end
    function os.time()
        local ticks = (sim:worldTicks() + 6000) % 24000
        return ticks / 1000
    end
    function os.day()
        return math.floor((sim:worldTicks() + 6000) / 24000)
    end
    function os.shutdown() m.pending = "shutdown" end
    function os.reboot() m.pending = "reboot" end
    return os
end

function Machine:makeHttp()
    local m = self
    local http = {}
    function http.request(url)
        m:queueEvent(0.5, "http_failure", url)
    end
    function http.checkURL() return true end
    return http
end

local BASE = {
    "assert", "error", "getfenv", "getmetatable", "ipairs", "next", "pairs", "pcall",
    "rawequal", "rawget", "rawset", "select", "setfenv", "setmetatable", "tonumber",
    "tostring", "type", "unpack", "xpcall",
}

function Machine:makeEnv()
    local m = self
    local G = {}
    for _, name in ipairs(BASE) do G[name] = _G[name] end
    G._VERSION = "Luaj-jse 2.0.3"
    G.string = U.copyTable(string)
    G.table = U.copyTable(table)
    G.math = U.copyTable(math)
    G.coroutine = U.copyTable(coroutine)
    local hostG = _G
    G.getfenv = function(f)
        local r
        if f == nil then
            r = getfenv(2)
        elseif type(f) == "number" then
            if f == 0 then r = getfenv(0) else r = getfenv(f + 1) end
        else
            r = getfenv(f)
        end
        if r == hostG then return G end
        return r
    end
    G.setfenv = function(f, env)
        if type(f) == "number" and f > 0 then return setfenv(f + 1, env) end
        return setfenv(f, env)
    end
    G.loadstring = function(code, name)
        local fn, err = loadstring(code, name)
        if fn then setfenv(fn, G) end
        return fn, err
    end
    G.bit = U.bitApi()
    G.term = m:makeTerm()
    G.fs = m:makeFs()
    G.os = m:makeOs()
    G.peripheral = m:makePeripheral()
    G.redstone = m:makeRedstone()
    G.rs = G.redstone
    if m.sim.httpEnabled ~= false then G.http = m:makeHttp() end
    if m.kind == "turtle" then G.turtle = Turtle.make(m) end
    G._G = G
    local errorLog = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local text = table.concat(parts, " ")
        m.errors[#m.errors + 1] = { t = m.sim.sched.now, text = text }
        m.sim:log(m.name, "printError: " .. text)
        if m.sim.onProgramError then m.sim:onProgramError(m, text) end
    end
    setmetatable(G, {
        __newindex = function(t, k, v)
            if k == "printError" and type(v) == "function" then
                local original = v
                v = function(...)
                    errorLog(...)
                    return original(...)
                end
            end
            rawset(t, k, v)
        end
    })
    return G
end

function Machine:queueEvent(delay, ...)
    local ev = { n = select("#", ...), ... }
    local gen = self.gen
    self.sim.sched:after(delay, function()
        if self.gen ~= gen then return end
        self:deliver(ev)
    end)
end

function Machine:deliver(ev)
    if not self.on or not self.co then return end
    local name = ev[1]
    if self.filter ~= nil and self.filter ~= name and name ~= "terminate" then
        self.dropped = self.dropped + 1
        if name == "rednet_message" or name == "modem_message" then
            self.sim.stats.droppedMessages = self.sim.stats.droppedMessages + 1
        end
        return
    end
    self:resume(unpack(ev, 1, ev.n))
end

function Machine:resume(...)
    local sim = self.sim
    sim.current = self
    sim.watch = 0
    local ok, res = coroutine.resume(self.co, ...)
    sim.current = nil
    if not ok then
        self:log("BIOS CRASH: " .. tostring(res))
        sim:onMachineCrash(self, tostring(res))
        self:powerOff("bios crash")
        return
    end
    if coroutine.status(self.co) == "dead" then
        self:powerOff("bios ended")
        return
    end
    self.filter = res
    local pending = self.pending
    self.pending = nil
    if pending == "shutdown" then
        self:powerOff("os.shutdown")
    elseif pending == "reboot" then
        self:powerOff("os.reboot")
        self:requestBoot(0.05, "os.reboot")
    end
end

function Machine:requestBoot(delay, reason)
    self.bootPending = true
    self.sim.sched:after(delay, function() self:boot(reason) end)
end

function Machine:boot(reason)
    if self.on or self.inTransit or self.sim.serverDown then return end
    if self.x ~= nil then
        local b = self.sim.world:get(self.x, self.y, self.z)
        if not b or b.machine ~= self then return end
    end
    self.bootPending = false
    self.on = true
    self.gen = self.gen + 1
    self.boots = self.boots + 1
    self.bootTime = self.sim.sched.now
    self.outputs = {}
    self.pending = nil
    self.filter = nil
    for _, a in pairs(self.attachments) do a.channels = {} end
    self:log("boot (" .. tostring(reason) .. ")")
    local env = self:makeEnv()
    local bios, err = loadstring(self.sim.rom.bios, "bios")
    if not bios then error("bios load failed: " .. tostring(err)) end
    setfenv(bios, env)
    self.env = env
    self.co = coroutine.create(bios)
    if self.sim.onBoot then self.sim:onBoot(self, reason) end
    self:resume()
end

function Machine:powerOff(reason)
    if not self.on then return end
    self.on = false
    self.gen = self.gen + 1
    self.co = nil
    self.filter = nil
    self:commitScreenLine(1)
    for y = 1, 19 do self:commitScreenLine(y) end
    self.screen = {}
    local outputs = self.outputs
    self.outputs = {}
    for side, value in pairs(outputs) do
        if value then self.sim.world:signal(self, side, false) end
    end
    for _, a in pairs(self.attachments) do a.channels = {} end
    self:log("off (" .. tostring(reason) .. ")")
end

return Machine
