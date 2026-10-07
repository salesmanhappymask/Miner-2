local U = require("util")

local Scenario = {}
Scenario.__index = Scenario

local DRIVE2_ID = 2700
local DRIVE1_ID = 2701
local CONTROL_ID = 2705
local RM_ID = 412
local QUARRY_PROTOCOL = "cairn.quarry.v2"

local function serialize(v, indent)
    local t = type(v)
    if t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            local ks
            if type(k) == "string" and k:match("^[%a_][%w_]*$") then ks = k
            elseif type(k) == "number" then ks = "[" .. k .. "]"
            else ks = "[" .. string.format("%q", tostring(k)) .. "]" end
            parts[#parts + 1] = ks .. "=" .. serialize(v[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif t == "string" then
        return string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        return tostring(v)
    end
    return "nil"
end

local function chunkSouthWest(x, z)
    return math.floor(x / 16) * 16, math.floor(z / 16) * 16 + 15
end

local function readProgram(dir, name)
    local text = U.readHostFile(dir .. "/" .. name)
    if not text then error("Missing program file " .. dir .. "/" .. name) end
    return text
end

local CONTROLLER_PROGRAM = [[
local commands = %s
rednet.open("top")
local seq = 0
local function record(line)
    local h = fs.open("replies", "a")
    h.writeLine(line)
    h.close()
end
for _, c in ipairs(commands) do
    if c.wait then sleep(c.wait) end
    seq = seq + 1
    c.token = "sim:" .. seq
    local answered = false
    for attempt = 1, 60 do
        rednet.send(2700, c, "cairn.nav.command")
        local deadline = os.clock() + 1.5
        while os.clock() < deadline do
            local id, msg = rednet.receive("cairn.nav.reply", deadline - os.clock())
            if type(msg) == "table" and msg.token == c.token then
                record(tostring(c.command) .. " ok=" .. tostring(msg.ok) .. " " .. tostring(msg.message))
                answered = true
                break
            end
        end
        if answered then break end
    end
    if not answered then record(tostring(c.command) .. " NO REPLY") end
end
record("done")
]]

local RETURN_STUB = [[
rednet.open("left")
while true do
    local id, msg = rednet.receive("cairn.quarry.v2")
    if (id == 2700 or id == 2701) and type(msg) == "table" and msg.type == "quarry_status_query" then
        rednet.send(2700, {
            type = "quarry_complete",
            jobToken = msg.jobToken,
            phase = "DOCKED",
            version = 169,
            rmId = os.getComputerID()
        }, "cairn.quarry.v2")
    end
end
]]

function Scenario.new(sim, opts)
    local s = setmetatable({}, Scenario)
    s.sim = sim
    s.opts = opts
    sim.scenario = s
    s.start = opts.start
    s.dest = opts.dest
    s.cruise = opts.cruise or math.max(opts.start.y, opts.dest.y)
    s.mineTime = opts.mineTime or 20
    s.returnTrip = opts.returnTrip ~= false
    s.rmErrors = {}
    s.cairnErrors = {}
    s.events = {}
    s.lastProgress = 0
    s.moveCommits = 0
    s.physicalFailures = 0
    local gx, gz = chunkSouthWest(s.start.x, s.start.z)
    s.grid = { x = opts.gridX or gx, z = opts.gridZ or gz }
    local dsx = s.grid.x + math.floor((s.dest.x - s.grid.x) / 16) * 16
    local dsz = s.grid.z + math.ceil((s.dest.z - s.grid.z) / 16) * 16
    s.expectedSeed = { x = dsx - 1, y = s.dest.y - 3, z = dsz + 1 }
    s.expectedDock = { x = s.dest.x, y = s.dest.y + 1, z = s.dest.z - 4 }
    return s
end

function Scenario:build()
    local sim, o = self.sim, self.opts
    local w = sim.world
    local x, y, z = self.start.x, self.start.y, self.start.z
    w.groundTop = math.min(self.start.y, self.dest.y) - 4
    for dz = 1, 3 do w:addCarriage(x, y, z - dz) end

    local cairn = readProgram(o.cairnDir, "cairn")
    local cairnStartup = readProgram(o.cairnDir, "startup")
    local state = {
        version = 7,
        start = { x = x, y = y, z = z },
        destination = { x = x, y = y, z = z },
        current = { x = x, y = y, z = z },
        cruise = y,
        stage = "idle",
        routeMode = "idle",
        paused = false,
        sequence = 0,
        quarrySequence = 0,
        southEndpointCorrectionDone = false,
    }
    self.drive2 = sim:addMachine({
        id = DRIVE2_ID, name = "Drive2", kind = "computer", x = x, y = y, z = z, facing = 2,
        files = { startup = cairnStartup, cairn = cairn, cairn_drive_state = serialize(state) },
        attachments = {
            left = { type = "modem", wireless = false, network = "cairn" },
            right = { type = "modem", wireless = true },
        },
    })
    self.drive1 = sim:addMachine({
        id = DRIVE1_ID, name = "Drive1", kind = "computer", x = x, y = y, z = z - 4, facing = 2,
        files = { startup = cairnStartup, cairn = cairn },
        attachments = {
            bottom = { type = "modem", wireless = false, network = "cairn" },
            front = { type = "modem", wireless = true },
        },
    })

    local startup = readProgram(o.swarmDir, "startup")
    startup = startup:gsub("local%s+REGIONAL_MANAGER%s*=%s*%d+", "local REGIONAL_MANAGER = 1", 1)
    local version = readProgram(o.swarmDir, "version"):match("%d+")
    self.rm = sim:addMachine({
        id = RM_ID, name = "RM", kind = "turtle", label = "Regional Manager",
        x = x, y = y + 1, z = z - 4, facing = 0, fuel = o.rmFuel or 5000,
        files = {
            startup = startup,
            common = readProgram(o.swarmDir, "common"),
            manager = readProgram(o.swarmDir, "manager"),
            version = version .. "\n",
            [".clean_install_release"] = version .. "\n",
        },
        attachments = { left = { type = "modem", wireless = true } },
        inv = { [1] = { name = "coal", count = 32 } },
    })

    local commands = {
        { command = "set_chunk_grid", gridX = self.grid.x, gridZ = self.grid.z, wait = o.commandAt or 8 },
        { command = "quarry", x = self.dest.x, y = self.dest.y, z = self.dest.z, cruise = self.cruise,
            gridX = self.grid.x, gridZ = self.grid.z },
    }
    self.controller = sim:addMachine({
        id = CONTROL_ID, name = "Controller", kind = "computer",
        x = x, y = w.groundTop - 2, z = z, facing = 0,
        files = { startup = string.format(CONTROLLER_PROGRAM, serialize(commands)) },
        attachments = { top = { type = "modem", wireless = true } },
    })

    local wiring = o.wiring or {
        { owner = DRIVE2_ID, side = "back", dir = "N" },
        { owner = DRIVE1_ID, side = "back", dir = "S" },
        { owner = DRIVE1_ID, side = "right", dir = "E" },
        { owner = DRIVE1_ID, side = "left", dir = "W" },
        { owner = DRIVE2_ID, side = "bottom", dir = "U" },
        { owner = DRIVE1_ID, side = "top", dir = "D" },
    }
    for _, e in ipairs(wiring) do w:addEngine(e) end

    for _, m in ipairs(sim.machines) do
        sim.sched:after(0.05 * (m.id % 5), function() m:boot("world load") end)
    end
    for _, ev in ipairs(o.events or {}) do self:scheduleEvent(ev) end
end

function Scenario:scheduleEvent(ev)
    local sim = self.sim
    sim.sched:at(ev.t, function()
        if ev.kind == "restart" or ev.kind == "crash" then
            sim:serverStop(ev.kind, ev.downtime or 20)
        elseif ev.kind == "reboot" then
            local m = sim.byName[ev.target]
            if m and m.on then
                sim:log("SIM", "reboot " .. m.name)
                m:powerOff("scenario reboot")
                m:requestBoot(0.05, "scenario reboot")
            end
        elseif ev.kind == "off" then
            local m = sim.byName[ev.target]
            if m then m:powerOff("scenario power cut") end
        end
    end)
end

local function samePos(a, b)
    return type(a) == "table" and type(b) == "table" and a.x == b.x and a.y == b.y and a.z == b.z
end

function Scenario:progress()
    self.lastProgress = self.sim.sched.now
end

function Scenario:onFileWrite(m, path, content)
    local sim = self.sim
    if m == self.drive2 and path == "cairn_drive_state" then
        local st = U.decode(content)
        if type(st) ~= "table" then return end
        local prev = self.cairn
        self.cairn = st
        if not prev or prev.stage ~= st.stage or not samePos(prev.current, st.current) then
            self:progress()
        end
        if prev and type(prev.current) == "table" and not samePos(prev.current, st.current) then
            self.moveCommits = self.moveCommits + 1
        end
        if not st.tx and type(st.current) == "table" then
            local actual = { x = m.x, y = m.y, z = m.z }
            if not samePos(st.current, actual) then
                local text = "Drive2 saved position " .. U.posText(st.current) .. " but is really at " .. U.posText(actual)
                if self.lastCairnDrift ~= text then
                    self.lastCairnDrift = text
                    sim:violation("CAIRN_POSITION", text)
                end
            end
        end
        if st.stage == "quarry_contact" and not self.arrivedAt then
            self.arrivedAt = sim.sched.now
            sim:log("SCENARIO", "Cairn reached the quarry destination")
        end
        if st.lastMoveError and st.lastMoveError ~= self.lastMoveErrorSeen then
            self.lastMoveErrorSeen = st.lastMoveError
            self.physicalFailures = self.physicalFailures + 1
        end
    elseif m == self.rm and path == "cairn_rm.cfg" then
        local st = U.decode(content)
        if type(st) ~= "table" then return end
        self.rmState = st
        self:progress()
        if not st.routeIntent and type(st.current) == "table" then
            local actual = { x = m.x, y = m.y, z = m.z }
            if not samePos(st.current, actual) then
                local text = "RM saved position " .. U.posText(st.current) .. " but is really at " .. U.posText(actual)
                if self.lastRmDrift ~= text then
                    self.lastRmDrift = text
                    sim:violation("RM_POSITION", text)
                end
            elseif tonumber(st.dir) and tonumber(st.dir) ~= m.facing and st.phase ~= "DEPLOYING" then
                sim:violation("RM_FACING", "RM saved facing " .. tostring(st.dir) .. " but faces " .. tostring(m.facing))
            end
        end
        if st.phase == "DEPLOYING" and not self.rmAtSeedAt then
            self.rmAtSeedAt = sim.sched.now
            local actual = { x = m.x, y = m.y, z = m.z }
            sim:log("SCENARIO", "RM reports DEPLOYING at " .. U.posText(actual))
            if not samePos(actual, self.expectedSeed) then
                sim:violation("RM_SEED", "RM started deploying at " .. U.posText(actual) .. ", expected seed " .. U.posText(self.expectedSeed))
            elseif m.facing ~= 0 then
                sim:violation("RM_SEED", "RM is at the seed but faces " .. tostring(m.facing) .. " instead of north")
            end
            sim.sched:after(0, function()
                m:powerOff("scenario: quarry mining stands in for the swarm")
            end)
            if self.returnTrip then
                sim.sched:after(self.mineTime, function() self:returnRm() end)
            end
        end
    elseif m == self.rm and path:match("_error%.log$") then
        self.rmErrors[#self.rmErrors + 1] = content
        sim:log("SCENARIO", "RM runtime error: " .. content)
    elseif m == self.controller and path == "replies" then
        self.replies = content
    end
end

function Scenario:onProgramError(m, text)
    if m == self.drive2 or m == self.drive1 then
        self.cairnErrors[#self.cairnErrors + 1] = m.name .. ": " .. text
    end
end

function Scenario:onTurtleMoved(m, how)
    if m == self.rm then self:progress() end
end

function Scenario:returnRm()
    local sim, m = self.sim, self.rm
    if m.on then return end
    local d1 = self.drive1
    local dock = { x = d1.x, y = d1.y + 1, z = d1.z }
    if not sim.world:isAir(dock.x, dock.y, dock.z) then
        sim:violation("RM_RETURN", "the dock above Drive1 is blocked at " .. U.posText(dock))
        return
    end
    sim.world:set(m.x, m.y, m.z, nil)
    sim.world:placeMachine(m, dock.x, dock.y, dock.z, 0)
    m.files.startup = RETURN_STUB
    sim:log("SCENARIO", "RM return is simulated: it is placed on the dock and answers quarry_complete")
    self.rmReturnedAt = sim.sched.now
    m:requestBoot(0.05, "scenario: back on the dock")
end

function Scenario:done()
    local st = self.cairn
    if self.returnTrip then
        return st and st.stage == "arrived" and type(st.quarry) == "table" and st.quarry.phase == "RETURNED"
    end
    return self.rmAtSeedAt ~= nil
end

function Scenario:safeStop()
    local reasons = {}
    for _, e in ipairs(self.rmErrors) do
        if e:find("reconciliation", 1, true) or e:find("requires cancellation", 1, true) or
            e:find("not docked on Drive1", 1, true) then
            reasons[#reasons + 1] = "RM stopped: " .. e
        end
    end
    local st = self.cairn
    if st and st.paused and st.lastMoveError then
        reasons[#reasons + 1] = "Cairn paused: " .. tostring(st.lastMoveError)
    end
    if st and type(st.quarry) == "table" and st.quarry.phase == "ERROR" then
        reasons[#reasons + 1] = "Cairn quarry error: " .. tostring(st.quarry.error)
    end
    if st and st.tx and (st.tx.recoveryReboots or 0) > 3 then
        reasons[#reasons + 1] = "Cairn waits for a person after movement recovery failed"
    end
    return reasons
end

function Scenario:finalChecks()
    local sim = self.sim
    if not self:done() then return end
    if self.returnTrip then
        local d2 = self.drive2
        local actual = { x = d2.x, y = d2.y, z = d2.z }
        if not samePos(actual, self.start) then
            sim:violation("CAIRN_RETURN", "Cairn finished at " .. U.posText(actual) .. ", it started at " .. U.posText(self.start))
        end
        local rm = self.rm
        if not (rm.x == d2.x and rm.y == d2.y + 1 and rm.z == d2.z - 4) then
            sim:violation("RM_DOCK", "RM is not on the Drive1 dock at the end")
        end
    end
end

function Scenario:report()
    local sim = self.sim
    local lines = {}
    local function add(...) lines[#lines + 1] = string.format(...) end
    local outcome
    local safe = self:safeStop()
    if #sim.fatals > 0 or #sim.violations > 0 then
        outcome = "FAIL"
    elseif self:done() then
        outcome = "PASS"
    elseif #safe > 0 then
        outcome = "SAFE_STOP"
    else
        outcome = "STALLED"
    end
    add("Cairn quarry scenario")
    add("  start %s, destination %s, cruise %d, grid SW %d,%d", U.posText(self.start), U.posText(self.dest), self.cruise, self.grid.x, self.grid.z)
    add("  expected RM seed %s", U.posText(self.expectedSeed))
    add("  simulated time %.1f s, %d events", sim.sched.now, sim.sched.processed)
    add("  carriage motions %d, refused motions %d, Cairn move commits %d", sim.world.motions, sim.world.motionFailures, self.moveCommits)
    add("  Drive2 boots %d, Drive1 boots %d, RM boots %d", self.drive2.boots, self.drive1.boots, self.rm.boots)
    if self.arrivedAt then add("  Cairn reached the destination at %.1f s", self.arrivedAt) end
    if self.rmAtSeedAt then add("  RM reached the seed at %.1f s", self.rmAtSeedAt) end
    if self.rmReturnedAt then add("  RM placed back on the dock (simulated) at %.1f s", self.rmReturnedAt) end
    if self.cairn then
        add("  Cairn final stage %s, quarry phase %s, paused %s", tostring(self.cairn.stage),
            tostring(type(self.cairn.quarry) == "table" and self.cairn.quarry.phase or "-"), tostring(self.cairn.paused))
        if self.cairn.lastMoveError then add("  Cairn last movement error: %s", self.cairn.lastMoveError) end
    end
    if self.rmState then add("  RM final phase %s", tostring(self.rmState.phase)) end
    if self.replies then
        for line in self.replies:gmatch("[^\n]+") do add("  controller: %s", line) end
    end
    for _, w in ipairs(sim.warnings) do add("^ WARN %s", w) end
    for _, r in ipairs(safe) do add("^ SAFE %s", r) end
    for _, e in ipairs(self.cairnErrors) do add("^ ERROR %s", e) end
    for _, v in ipairs(sim.violations) do add("^ VIOLATION t=%.2f %s: %s", v.t, v.kind, v.text) end
    for _, f in ipairs(sim.fatals) do add("^ FATAL %s", f) end
    add("RESULT: %s", outcome)
    return table.concat(lines, "\n"), outcome
end

return Scenario
