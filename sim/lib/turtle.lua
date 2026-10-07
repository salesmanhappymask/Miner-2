local U = require("util")

local Turtle = {}

local MOVE_TIME = 0.4
local SHORT_TIME = 0.05

function Turtle.make(m)
    local sim = m.sim
    local t = {}
    local commandId = 0

    local function command(duration, effect)
        commandId = commandId + 1
        local id = commandId
        local gen = m.gen
        sim.stats.turtleCommands = sim.stats.turtleCommands + 1
        sim.sched:after(0.05, function()
            if m.gen ~= gen or not m.on then
                sim:log(m.name, "turtle command lost before it took effect")
                return
            end
            local results = { effect() }
            sim.sched:after(math.max(duration - 0.05, 0), function()
                if m.gen ~= gen then
                    sim:log(m.name, "turtle command took effect but the program never heard back")
                    return
                end
                m:deliver({ n = 2 + #results, "turtle_response", id, unpack(results) })
            end)
        end)
        while true do
            local ev = { coroutine.yield("turtle_response") }
            if ev[1] == "turtle_response" and ev[2] == id then
                return unpack(ev, 3)
            end
        end
    end

    local function target(dir)
        if dir == "up" then return m.x, m.y + 1, m.z end
        if dir == "down" then return m.x, m.y - 1, m.z end
        local f = m.facing
        if dir == "back" then f = (f + 2) % 4 end
        local d = U.DIRS[f]
        return m.x + d[1], m.y + d[2], m.z + d[3]
    end

    local function move(dir)
        return command(MOVE_TIME, function()
            if m.fuel <= 0 then return false, "Out of fuel" end
            local x, y, z = target(dir)
            local b = sim.world:get(x, y, z)
            if b then return false, "Movement obstructed" end
            if sim.mobAt and sim.mobAt(x, y, z) then return false, "Movement obstructed" end
            sim.world:moveMachine(m, x, y, z)
            m.fuel = m.fuel - 1
            sim:log(m.name, string.format("moved %s to %d,%d,%d", dir, x, y, z))
            sim:onTurtleMoved(m, dir)
            return true
        end)
    end

    local function detect(dir)
        return command(SHORT_TIME, function()
            local x, y, z = target(dir)
            return sim.world:get(x, y, z) ~= nil
        end)
    end

    local function dig(dir)
        return command(MOVE_TIME, function()
            local x, y, z = target(dir)
            local b = sim.world:get(x, y, z)
            if not b then return false, "Nothing to dig here" end
            if b.kind == "machine" then
                sim:fatal(string.format("%s dug %s at %d,%d,%d", m.name, b.machine.name, x, y, z))
                return false, "Unbreakable block detected"
            end
            if b.kind == "carriage" or b.kind == "placeholder" then
                sim:fatal(string.format("%s dug part of the carriage at %d,%d,%d", m.name, x, y, z))
                return false, "Unbreakable block detected"
            end
            if b.unbreakable then return false, "Unbreakable block detected" end
            sim.world:set(x, y, z, nil)
            Turtle.insert(m, b.drop or "cobblestone", 1)
            return true
        end)
    end

    local function attack(dir)
        return command(MOVE_TIME, function()
            local x, y, z = target(dir)
            local b = sim.world:get(x, y, z)
            if b and b.kind == "machine" then
                sim:fatal(string.format("%s attacked %s", m.name, b.machine.name))
            end
            return false, "Nothing to attack here"
        end)
    end

    local function place(dir)
        return command(SHORT_TIME, function()
            local s = m.inv[m.slot]
            if not s then return false, "No items to place" end
            local x, y, z = target(dir)
            if sim.world:get(x, y, z) then return false, "Cannot place block here" end
            sim.world:set(x, y, z, { kind = "solid", name = s.name, drop = s.name })
            s.count = s.count - 1
            if s.count <= 0 then m.inv[m.slot] = nil end
            return true
        end)
    end

    local function nothing(msg)
        return function() return command(SHORT_TIME, function() return false, msg end) end
    end

    function t.forward() return move("forward") end
    function t.back() return move("back") end
    function t.up() return move("up") end
    function t.down() return move("down") end
    function t.turnLeft()
        return command(MOVE_TIME, function()
            m.facing = (m.facing + 3) % 4
            sim:log(m.name, "turned left, facing " .. m.facing)
            sim:onTurtleMoved(m, "turnLeft")
            return true
        end)
    end
    function t.turnRight()
        return command(MOVE_TIME, function()
            m.facing = (m.facing + 1) % 4
            sim:log(m.name, "turned right, facing " .. m.facing)
            sim:onTurtleMoved(m, "turnRight")
            return true
        end)
    end
    function t.detect() return detect("forward") end
    function t.detectUp() return detect("up") end
    function t.detectDown() return detect("down") end
    function t.dig() return dig("forward") end
    function t.digUp() return dig("up") end
    function t.digDown() return dig("down") end
    function t.attack() return attack("forward") end
    function t.attackUp() return attack("up") end
    function t.attackDown() return attack("down") end
    function t.place() return place("forward") end
    function t.placeUp() return place("up") end
    function t.placeDown() return place("down") end
    t.drop = nothing("No items to drop")
    t.dropUp = t.drop
    t.dropDown = t.drop
    t.suck = nothing("No items to take")
    t.suckUp = t.suck
    t.suckDown = t.suck
    function t.compare() return command(SHORT_TIME, function() return false end) end
    t.compareUp = t.compare
    t.compareDown = t.compare
    function t.select(slot)
        slot = tonumber(slot)
        if not slot or slot < 1 or slot > 16 then error("Slot number " .. tostring(slot) .. " out of range", 2) end
        return command(SHORT_TIME, function()
            m.slot = slot
            return true
        end)
    end
    function t.getSelectedSlot() return m.slot end
    function t.getItemCount(slot)
        local s = m.inv[tonumber(slot) or m.slot]
        return s and s.count or 0
    end
    function t.getItemSpace(slot)
        local s = m.inv[tonumber(slot) or m.slot]
        return s and (64 - s.count) or 64
    end
    function t.getFuelLevel() return m.fuel end
    function t.getFuelLimit() return m.fuelLimit end
    function t.refuel(n)
        return command(SHORT_TIME, function()
            local s = m.inv[m.slot]
            local value = s and Turtle.FUEL[s.name]
            if not value then return false, "Items not combustible" end
            n = math.min(tonumber(n) or s.count, s.count)
            if n == 0 then return true end
            m.fuel = math.min(m.fuelLimit, m.fuel + n * value)
            s.count = s.count - n
            if s.count <= 0 then m.inv[m.slot] = nil end
            return true
        end)
    end
    function t.compareTo(slot)
        local a, b = m.inv[m.slot], m.inv[tonumber(slot)]
        if not a and not b then return true end
        return a ~= nil and b ~= nil and a.name == b.name
    end
    function t.transferTo(slot, n)
        return command(SHORT_TIME, function()
            local s = m.inv[m.slot]
            slot = tonumber(slot)
            if not s or not slot or slot == m.slot then return false end
            local d = m.inv[slot]
            if d and d.name ~= s.name then return false end
            n = math.min(tonumber(n) or s.count, s.count, 64 - (d and d.count or 0))
            if n <= 0 then return false end
            if d then d.count = d.count + n else m.inv[slot] = { name = s.name, count = n } end
            s.count = s.count - n
            if s.count <= 0 then m.inv[m.slot] = nil end
            return true
        end)
    end
    function t.equipLeft() return command(SHORT_TIME, function() return false, "Not a valid upgrade" end) end
    t.equipRight = t.equipLeft
    return t
end

Turtle.FUEL = { coal = 80, charcoal = 80, coal_block = 800, lava_bucket = 1000, blaze_rod = 120 }

function Turtle.insert(m, name, count)
    for i = 1, 16 do
        local s = m.inv[i]
        if s and s.name == name and s.count < 64 then
            local add = math.min(64 - s.count, count)
            s.count = s.count + add
            count = count - add
        elseif not s then
            local add = math.min(64, count)
            m.inv[i] = { name = name, count = add }
            count = count - add
        end
        if count <= 0 then return 0 end
    end
    return count
end

return Turtle
