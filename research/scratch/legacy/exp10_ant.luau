-- Minimal port of AfterNotTouchedClass semantics (reference/live/AfterNotTouchedClass.luau:38-78) over the legacy core
local tick = require("./LegacyTick")
local Storage = {}
local nextId = 0
local freed = {}
local function SafeStopClock(c) if c == nil then return nil end c:stop() return nil end
local ANT = {}; ANT.__index = ANT
function ANT.new(group, _time, fn)
  local self = setmetatable({}, ANT)
  nextId += 1; self.Id = nextId; self.isDestroying = false
  self.Clock = group:delay(function() fn(); self:Destroy() end, _time)   -- :45-51
  Storage[self.Id] = self                                                -- :53
  return self
end
function ANT:Touch() if self.isDestroying then return end self.Clock:reset() end
function ANT:Destroy() if self.isDestroying then return end self.isDestroying = true; self.Clock = SafeStopClock(self.Clock); freed[self.Id] = true; Storage[self.Id] = nil end
local function count(t) local n = 0 for _ in pairs(t) do n += 1 end return n end
local function falseKeys(g) local n = 0 for k, v in pairs(g) do if v == false then n += 1 end end return n end

print("=== 10a: normal fire: Destroy runs inside the callback => SafeStopClock on an already-removed clock => F3 false key per fire ===")
do local g = tick.group(); for i = 1, 100 do ANT.new(g, 0.1, function() end); g:update(1) end
  print("  Storage=", count(Storage), " false-keys in group=", falseKeys(g), "(one per natural fire)") end

print("=== 10b: fn errors => Destroy never runs => object stays in Storage, Id never freed, Touch() is a silent no-op forever ===")
do local g = tick.group(); local o = ANT.new(g, 0.1, function() error("fn boom") end)
  print("  update:", pcall(function() g:update(1) end)); print("  in Storage?", Storage[o.Id] ~= nil, " isDestroying=", o.isDestroying, " Id freed?", freed[o.Id] == true)
  o:Touch(); g:update(1); print("  after Touch+update: still in Storage?", Storage[o.Id] ~= nil, " clock in group?", #g) ; o:Destroy() end

print("=== 10c: created inside a callback with a delay shorter than the residual => immediate path => Destroy runs BEFORE self.Clock/Storage are assigned ===")
do local g = tick.group(); local o
  g:delay(function() o = ANT.new(g, 0.1, function() end) end, 0.5)  -- residual -0.5 => 0.1-0.5<0 => fn+Destroy run synchronously inside :45
  g:update(1)
  print("  isDestroying=", o.isDestroying, " but Storage still holds it?", Storage[o.Id] ~= nil, " and o.Clock is the dummy?", o.Clock ~= nil, " => zombie registered after its own Destroy")
  print("  dummy clock still in group #=", #g, "(fires noop next frame)") end
