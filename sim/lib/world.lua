local U = require("util")

local World = {}
World.__index = World

local NEIGHBORS = { { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 } }

function World.new(sim, opts)
    local w = setmetatable({}, World)
    w.sim = sim
    w.groundTop = opts.groundTop or 60
    w.over = {}
    w.engines = {}
    w.motionTime = opts.motionTime or 1.0
    w.maxBurden = opts.maxBurden or 5000
    w.wireCheck = opts.wireCheck ~= false
    w.moving = false
    w.anchor = nil
    w.motions = 0
    w.motionFailures = 0
    return w
end

function World:terrain(x, y, z)
    if y <= self.groundTop then return { kind = "terrain", name = "stone" } end
    return nil
end

function World:get(x, y, z)
    local k = U.key(x, y, z)
    local v = self.over[k]
    if v == false then return nil end
    if v ~= nil then return v end
    return self:terrain(x, y, z)
end

function World:set(x, y, z, block)
    local k = U.key(x, y, z)
    if block == nil then
        if self:terrain(x, y, z) then self.over[k] = false else self.over[k] = nil end
    else
        self.over[k] = block
    end
end

function World:isAir(x, y, z)
    return self:get(x, y, z) == nil
end

function World:placeMachine(m, x, y, z, facing)
    m.x, m.y, m.z = x, y, z
    if facing then m.facing = facing end
    self:set(x, y, z, { kind = "machine", machine = m })
end

function World:moveMachine(m, nx, ny, nz)
    self:set(m.x, m.y, m.z, nil)
    m.x, m.y, m.z = nx, ny, nz
    self:set(nx, ny, nz, { kind = "machine", machine = m })
end

function World:neighbor(m, side)
    local dx, dy, dz = U.sideVector(m.facing or 0, side)
    if not dx then return nil end
    local x, y, z = m.x + dx, m.y + dy, m.z + dz
    return self:get(x, y, z), x, y, z
end

function World:addCarriage(x, y, z)
    self:set(x, y, z, { kind = "carriage" })
    if not self.anchor then self.anchor = { x = x, y = y, z = z } end
end

function World:addEngine(e)
    e.input = false
    e.signalled = false
    self.engines[#self.engines + 1] = e
end

function World:wireReaches(m, side)
    if not self.wireCheck then return true end
    local b = self:neighbor(m, side)
    if b and b.kind == "machine" then return false, b.machine end
    return true
end

function World:signal(m, side, value)
    for _, e in ipairs(self.engines) do
        if e.owner == m.id and e.side == side then
            local reaches, blocker = self:wireReaches(m, side)
            if value and not reaches then
                if not e.blockedLogged then
                    e.blockedLogged = true
                    self.sim:warn(string.format("%s pulsed %s for %s, but %s occupies that block, so no cable can reach the drive",
                        m.name, side, e.dir, blocker and blocker.name or "a computer"))
                end
                self.sim:log("RIM", string.format("%s %s pulse blocked by %s", m.name, side, blocker and blocker.name or "?"))
                value = false
            end
            e.input = value and true or false
            if e.input then
                self.sim.sched:after(0.05, function() self:engineTick(e) end)
            else
                self.sim.sched:after(0.05, function()
                    if not e.input then e.signalled = false end
                end)
            end
        end
    end
end

function World:engineTick(e)
    if not e.input or e.signalled or self.moving then return end
    e.signalled = true
    self:tryMotion(e)
end

function World:collectPackage()
    local a = self.anchor
    if not a then return nil, "no carriage" end
    local start = U.key(a.x, a.y, a.z)
    local seen = { [start] = true }
    local list = { { a.x, a.y, a.z } }
    local queue = { { a.x, a.y, a.z } }
    local carried = 0
    local head = 1
    while head <= #queue do
        local p = queue[head]
        head = head + 1
        for d = 1, 6 do
            local v = NEIGHBORS[d]
            local x, y, z = p[1] + v[1], p[2] + v[2], p[3] + v[3]
            local k = U.key(x, y, z)
            if not seen[k] then
                seen[k] = true
                local b = self:get(x, y, z)
                if b then
                    list[#list + 1] = { x, y, z }
                    queue[#queue + 1] = { x, y, z }
                    if b.kind ~= "carriage" then
                        carried = carried + 1
                        if carried > self.maxBurden then
                            return nil, "carriage overburdened (it touches terrain or other blocks)"
                        end
                    end
                end
            end
        end
    end
    return list, seen
end

function World:tryMotion(e)
    local dir = U.WORLD_DIRS[e.dir]
    local list, inPackage = self:collectPackage()
    if not list then
        self.motionFailures = self.motionFailures + 1
        self.sim:log("RIM", "motion " .. e.dir .. " refused: " .. tostring(inPackage))
        return
    end
    for _, p in ipairs(list) do
        local tx, ty, tz = p[1] + dir[1], p[2] + dir[2], p[3] + dir[3]
        if self:get(tx, ty, tz) and not inPackage[U.key(tx, ty, tz)] then
            self.motionFailures = self.motionFailures + 1
            self.sim:log("RIM", string.format("motion %s obstructed at %d,%d,%d", e.dir, tx, ty, tz))
            return
        end
    end
    local blocks = {}
    local machines = {}
    for _, p in ipairs(list) do
        local b = self:get(p[1], p[2], p[3])
        blocks[#blocks + 1] = { p = p, b = b }
        if b.kind == "machine" then machines[#machines + 1] = b.machine end
    end
    for _, m in ipairs(machines) do
        m.wasOnBeforeMotion = m.on or m.bootPending
        m:powerOff("carriage motion")
        m.inTransit = true
    end
    for _, item in ipairs(blocks) do
        self:set(item.p[1], item.p[2], item.p[3], nil)
    end
    for _, item in ipairs(blocks) do
        local p = item.p
        self:set(p[1] + dir[1], p[2] + dir[2], p[3] + dir[3], { kind = "placeholder" })
    end
    self.moving = true
    self.motions = self.motions + 1
    self.sim:log("RIM", string.format("carriage moving %s with %d blocks, %d computers", e.dir, #blocks, #machines))
    self.pendingMotion = { blocks = blocks, machines = machines, dir = dir }
    self.sim.sched:after(self.motionTime, function() self:finishMotion() end)
end

function World:finishMotion()
    local pm = self.pendingMotion
    if not pm then return end
    self.pendingMotion = nil
    local dir = pm.dir
    for _, item in ipairs(pm.blocks) do
        local p = item.p
        self:set(p[1] + dir[1], p[2] + dir[2], p[3] + dir[3], nil)
    end
    for _, item in ipairs(pm.blocks) do
        local p = item.p
        local nx, ny, nz = p[1] + dir[1], p[2] + dir[2], p[3] + dir[3]
        self:set(nx, ny, nz, item.b)
        if item.b.kind == "machine" then
            local m = item.b.machine
            m.x, m.y, m.z = nx, ny, nz
        end
    end
    self.anchor = { x = self.anchor.x + dir[1], y = self.anchor.y + dir[2], z = self.anchor.z + dir[3] }
    self.moving = false
    for _, e in ipairs(self.engines) do
        e.input = false
    end
    for _, m in ipairs(pm.machines) do
        m.inTransit = false
        if m.wasOnBeforeMotion and not self.sim.serverDown then
            self.sim.sched:after(0.05, function() m:boot("after carriage motion") end)
        elseif m.wasOnBeforeMotion then
            m.bootWhenServerUp = true
        end
    end
    self.sim:log("RIM", "carriage motion complete, anchor " .. U.posText(self.anchor))
    self.sim:onMotion()
end

function World:snapshot()
    local snap = { over = {}, machines = {}, anchor = U.copyTable(self.anchor or {}) }
    for k, v in pairs(self.over) do
        if type(v) == "table" then snap.over[k] = U.copyTable(v) else snap.over[k] = v end
    end
    for _, m in ipairs(self.sim.machines) do
        snap.machines[m] = { x = m.x, y = m.y, z = m.z, facing = m.facing, fuel = m.fuel,
            inv = U.deepcopy(m.inv or {}) }
    end
    return snap
end

function World:restore(snap)
    self.over = {}
    for k, v in pairs(snap.over) do
        if type(v) == "table" then self.over[k] = U.copyTable(v) else self.over[k] = v end
    end
    for m, s in pairs(snap.machines) do
        m.x, m.y, m.z, m.facing, m.fuel = s.x, s.y, s.z, s.facing, s.fuel
        m.inv = U.deepcopy(s.inv)
        m.inTransit = false
    end
    self.anchor = U.copyTable(snap.anchor)
    self.pendingMotion = nil
    self.moving = false
    for _, e in ipairs(self.engines) do
        e.input = false
        e.signalled = false
    end
end

return World
