local U = require("util")

local Net = {}
Net.__index = Net

function Net.new(sim, opts)
    return setmetatable({ sim = sim, range = opts.range or 64, sent = 0, delivered = 0, outOfRange = 0 }, Net)
end

local function distance(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Net:transmit(from, side, modem, channel, reply, message)
    self.sent = self.sent + 1
    local sim = self.sim
    local payload = U.deepcopy(message)
    local fx, fy, fz = from.x, from.y, from.z
    local origin = { x = fx, y = fy, z = fz }
    for _, to in ipairs(sim.machines) do
        if to ~= from then
            for toSide, a in pairs(to.attachments) do
                if a.type == "modem" and a.wireless == modem.wireless then
                    local reachable, dist = false, 0
                    if modem.wireless then
                        if to.x and fx then
                            dist = distance(origin, to)
                            reachable = dist <= self.range
                            if not reachable then self.outOfRange = self.outOfRange + 1 end
                        end
                    else
                        reachable = a.network ~= nil and a.network == modem.network
                    end
                    if reachable then
                        sim.sched:after(0.05, function()
                            if to.on and not to.inTransit and a.channels[channel] then
                                self.delivered = self.delivered + 1
                                to:deliver({ n = 6, "modem_message", toSide, channel, reply, U.deepcopy(payload), dist })
                            end
                        end)
                    end
                end
            end
        end
    end
end

return Net
