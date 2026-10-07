local U = require("util")
local Sched = require("sched")
local World = require("world")
local Net = require("net")
local Machine = require("machine")

local Sim = {}
Sim.__index = Sim

local function loadRom(dir)
    local rom = { files = {}, dirs = { rom = true } }
    rom.bios = U.readHostFile(dir .. "/bios.lua")
    if not rom.bios then
        error("ComputerCraft ROM not found in " .. dir .. " (run sim/fetch_rom.sh with your ComputerCraft jar)")
    end
    local p = io.popen('cd "' .. dir .. '" && find rom -type f')
    for path in p:lines() do
        rom.files[path] = U.readHostFile(dir .. "/" .. path)
        local acc = ""
        for part in path:gmatch("[^/]+") do
            acc = acc == "" and part or (acc .. "/" .. part)
            if acc ~= path then rom.dirs[acc] = true end
        end
    end
    p:close()
    return rom
end

function Sim.new(opts)
    local s = setmetatable({}, Sim)
    s.opts = opts
    s.sched = Sched.new()
    s.rom = loadRom(opts.romDir)
    s.world = World.new(s, opts.world or {})
    s.net = Net.new(s, opts.net or {})
    s.machines = {}
    s.byId = {}
    s.byName = {}
    s.fatals = {}
    s.warnings = {}
    s.warned = {}
    s.violations = {}
    s.notes = {}
    s.stats = { droppedMessages = 0, turtleCommands = 0, crashes = 0, restarts = 0 }
    s.worldOffset = 0
    s.httpEnabled = opts.httpEnabled
    s.out = opts.out
    s.logLines = {}
    if s.out then
        s.logFile = assert(io.open(s.out .. "sim.log", "w"))
    end
    s.autosaveEvery = opts.autosaveEvery or 45
    return s
end

function Sim:log(who, text)
    local line = string.format("[%9.2f] %-14s %s", self.sched.now, who, text)
    if self.logFile then self.logFile:write(line, "\n") end
    if self.opts.verbose then print(line) end
end

function Sim:fatal(text)
    self.fatals[#self.fatals + 1] = string.format("t=%.2f %s", self.sched.now, text)
    self:log("FATAL", text)
end

function Sim:warn(text)
    if self.warned[text] then return end
    self.warned[text] = true
    self.warnings[#self.warnings + 1] = string.format("t=%.2f %s", self.sched.now, text)
    self:log("WARN", text)
end

function Sim:violation(kind, text)
    self.violations[#self.violations + 1] = { t = self.sched.now, kind = kind, text = text }
    self:log("VIOLATION", kind .. ": " .. text)
end

function Sim:note(text)
    self.notes[#self.notes + 1] = string.format("t=%.2f %s", self.sched.now, text)
    self:log("NOTE", text)
end

function Sim:addMachine(def)
    local m = Machine.new(self, def)
    self.machines[#self.machines + 1] = m
    self.byId[m.id] = m
    self.byName[m.name] = m
    if def.x then self.world:placeMachine(m, def.x, def.y, def.z, def.facing) end
    return m
end

function Sim:worldTicks()
    return math.floor((self.sched.now - self.worldOffset) * 20)
end

function Sim:onFileWrite(m, path, content)
    if self.scenario and self.scenario.onFileWrite then self.scenario:onFileWrite(m, path, content) end
end

function Sim:onFileDelete(m, path)
end

function Sim:onBoot(m, reason)
    if self.scenario and self.scenario.onBoot then self.scenario:onBoot(m, reason) end
end

function Sim:onTurtleMoved(m, how)
    if self.scenario and self.scenario.onTurtleMoved then self.scenario:onTurtleMoved(m, how) end
end

function Sim:onMotion()
    if self.autosavePending then self:autosave() end
    if self.scenario and self.scenario.onMotion then self.scenario:onMotion() end
end

function Sim:onProgramError(m, text)
    if self.scenario and self.scenario.onProgramError then self.scenario:onProgramError(m, text) end
end

function Sim:onMachineCrash(m, text)
    self.stats.crashes = self.stats.crashes + 1
    if text:find("Too long without yielding", 1, true) then
        self:fatal(m.name .. " looped without yielding")
    else
        self:fatal(m.name .. " bios crashed: " .. text)
    end
end

function Sim:autosave()
    if self.world.moving then
        self.autosavePending = true
        return
    end
    self.autosavePending = false
    self.saved = self.world:snapshot()
    self.saved.worldTicks = self:worldTicks()
end

function Sim:scheduleAutosaves()
    local function tick()
        self:autosave()
        self.sched:after(self.autosaveEvery, tick)
    end
    self.sched:after(0, tick)
end

function Sim:serverStop(kind, downtime)
    self.serverDown = true
    if kind == "crash" then
        self.stats.crashes = self.stats.crashes + 1
        self:log("SERVER", string.format("*** server crash: world rolls back to the last autosave, computer files do not ***"))
    else
        self.stats.restarts = self.stats.restarts + 1
        self:log("SERVER", "*** server restart: world saved, every computer stops ***")
        if self.world.pendingMotion then self.world:finishMotion() end
    end
    local wasOn = {}
    for _, m in ipairs(self.machines) do
        if m.on or m.inTransit or m.bootPending then wasOn[m] = true end
        m:powerOff("server " .. kind)
    end
    if kind == "crash" and self.saved then
        self.world:restore(self.saved)
        self.worldOffset = self.sched.now - self.saved.worldTicks / 20
    end
    self.sched:after(downtime or 20, function()
        self.serverDown = false
        self:log("SERVER", "*** server back up ***")
        if kind ~= "crash" then self:autosave() end
        for _, m in ipairs(self.machines) do
            if wasOn[m] or m.bootPending then
                self.sched:after(0.05 + 0.05 * (m.id % 7), function() m:boot("server start") end)
            end
        end
        if self.scenario and self.scenario.onServerStart then self.scenario:onServerStart(kind) end
    end)
end

function Sim:installWatchdog(limit)
    local sim = self
    sim.watch = 0
    debug.sethook(function()
        if sim.current then
            sim.watch = sim.watch + 1
            if sim.watch > limit then
                sim.watch = 0
                error("Too long without yielding", 0)
            end
        end
    end, "", 100000)
end

function Sim:run(limit, stop)
    return self.sched:run(limit, stop)
end

function Sim:dumpTranscripts()
    if not self.out then return end
    for _, m in ipairs(self.machines) do
        for y = 1, 19 do m:commitScreenLine(y) end
        local h = io.open(self.out .. "screen_" .. m.name:gsub("[^%w]", "_") .. ".txt", "w")
        if h then
            h:write(table.concat(m.transcript, "\n"), "\n")
            h:close()
        end
        if self.opts.dumpFiles then
            local dir = self.out .. "files_" .. m.name:gsub("[^%w]", "_")
            os.execute('mkdir -p "' .. dir .. '"')
            for path, content in pairs(m.files) do
                if not path:find("/", 1, true) then
                    U.writeHostFile(dir .. "/" .. path:gsub("[^%w%._%-]", "_"), content)
                elseif path:match("^logs/") then
                    U.writeHostFile(dir .. "/" .. path:gsub("/", "__"), content)
                end
            end
        end
    end
end

function Sim:close()
    if self.logFile then self.logFile:close() end
end

return Sim
