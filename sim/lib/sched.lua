local Sched = {}
Sched.__index = Sched

function Sched.new()
    return setmetatable({ now = 0, heap = {}, seq = 0, processed = 0 }, Sched)
end

local function less(a, b)
    if a.t ~= b.t then return a.t < b.t end
    return a.seq < b.seq
end

function Sched:at(t, fn)
    if t < self.now then t = self.now end
    self.seq = self.seq + 1
    local heap = self.heap
    local item = { t = t, seq = self.seq, fn = fn }
    heap[#heap + 1] = item
    local i = #heap
    while i > 1 do
        local p = math.floor(i / 2)
        if less(heap[i], heap[p]) then
            heap[i], heap[p] = heap[p], heap[i]
            i = p
        else
            break
        end
    end
end

function Sched:after(dt, fn)
    self:at(self.now + dt, fn)
end

function Sched:pop()
    local heap = self.heap
    local n = #heap
    if n == 0 then return nil end
    local top = heap[1]
    heap[1] = heap[n]
    heap[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, m = 2 * i, 2 * i + 1, i
        if l <= n and less(heap[l], heap[m]) then m = l end
        if r <= n and less(heap[r], heap[m]) then m = r end
        if m == i then break end
        heap[i], heap[m] = heap[m], heap[i]
        i = m
    end
    return top
end

function Sched:peekTime()
    local top = self.heap[1]
    return top and top.t or nil
end

function Sched:run(limit, stop)
    while true do
        local t = self:peekTime()
        if not t or t > limit then return "limit" end
        local item = self:pop()
        self.now = item.t
        self.processed = self.processed + 1
        item.fn()
        if stop and stop() then return "stopped" end
    end
end

return Sched
