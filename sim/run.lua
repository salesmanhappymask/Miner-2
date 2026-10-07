local here = (arg and arg[0] or "run.lua"):match("^(.*)/[^/]*$") or "."
package.path = here .. "/lib/?.lua;" .. here .. "/scenarios/?.lua;" .. package.path

local U = require("util")
local Sim = require("sim")

local opts = {}
for i = 1, #arg do
    local k, v = arg[i]:match("^([%w_]+)=(.*)$")
    if k then opts[k] = v else opts[#opts + 1] = arg[i] end
end
local function opt(name, default)
    local v = opts[name]
    if v == nil then v = os.getenv("SIM_" .. name:upper()) end
    if v == nil or v == "" then return default end
    return v
end
local function point(text, default)
    if not text then return default end
    local x, y, z = text:match("^(-?%d+),(-?%d+),(-?%d+)$")
    if not x then error("bad point " .. text) end
    return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end
local function events(text)
    local list = {}
    for _, spec in ipairs(U.split(text or "", ",")) do
        local kind, target, t = spec:match("^(%a+):([%w_]+)@([%d%.]+)$")
        if kind then
            list[#list + 1] = { kind = kind, target = target, t = tonumber(t) }
        else
            kind, t = spec:match("^(%a+)@([%d%.]+)$")
            if not kind then error("bad event " .. spec) end
            list[#list + 1] = { kind = kind, t = tonumber(t) }
        end
    end
    return list
end
local function wiring(text)
    if not text then return nil end
    local ids = { Drive2 = 2700, Drive1 = 2701 }
    local list = {}
    for _, spec in ipairs(U.split(text, ";")) do
        local who, side, dir = spec:match("^(%w+):(%a+)=(%a)$")
        if not who then error("bad wiring " .. spec) end
        list[#list + 1] = { owner = ids[who] or tonumber(who), side = side, dir = dir }
    end
    return list
end

local scenarioName = opts[1] or "cairn_quarry"
local out = opt("out", here .. "/out/")
os.execute('mkdir -p "' .. out .. '"')

local sim = Sim.new({
    romDir = opt("ccrom", here .. "/ccrom"),
    out = out,
    verbose = opt("verbose") == "1",
    dumpFiles = opt("dumpfiles") == "1",
    httpEnabled = opt("http", "1") == "1",
    world = {
        motionTime = tonumber(opt("motion", "1.0")),
        wireCheck = opt("wirecheck", "1") == "1",
    },
    net = { range = tonumber(opt("range", "64")) },
})
sim:installWatchdog(tonumber(opt("watchdog", "3000")))

local Scenario = require(scenarioName)
local start = point(opt("start"), { x = 100, y = 64, z = 200 })
local scenario = Scenario.new(sim, {
    cairnDir = opt("cairn", here .. "/../cairn"),
    swarmDir = opt("swarm", here .. "/.."),
    start = start,
    dest = point(opt("dest"), { x = start.x + 37, y = start.y, z = start.z - 21 }),
    cruise = tonumber(opt("cruise")),
    mineTime = tonumber(opt("mine", "20")),
    returnTrip = opt("return", "1") == "1",
    events = events(opt("events")),
    wiring = wiring(opt("wiring")),
})
scenario:build()
sim:scheduleAutosaves()

local limit = tonumber(opt("tlimit", "2000"))
local stall = tonumber(opt("stall", "300"))
sim:run(limit, function()
    if scenario:done() then return true end
    if #sim.fatals > 0 then return true end
    return sim.sched.now - scenario.lastProgress > stall
end)
scenario:finalChecks()
local text, outcome = scenario:report()
print(text)
sim:dumpTranscripts()
sim:close()
os.exit(outcome == "PASS" and 0 or (outcome == "SAFE_STOP" and 2 or 1))
