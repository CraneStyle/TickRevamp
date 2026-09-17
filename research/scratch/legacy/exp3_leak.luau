local tick = require("./LegacyTick")
local MODE = (require("@lune/process").args[1]) or "leak"
local function falseCount(g) local n = 0 for k, v in pairs(g) do if v == false then n += 1 end end return n end
local function churn() -- force several GC cycles without collectgarbage("collect") (Lune only exposes "count")
  for _ = 1, 40 do local t = table.create(200000, 1) t = nil end
end
local g = tick.group()
local N = 20000
local weak = setmetatable({}, { __mode = "k" })
for i = 1, N do
  local payload = table.create(32, i)      -- stands in for a captured game object
  weak[payload] = true
  local h = g:delay(function() return payload end, 0.001)
  g:update(1)                                -- fires; removed from the array; g[h] = nil
  if MODE == "leak" then h:stop() end        -- SafeStopClock idiom after fire => g[h] = false (F3)
end
churn()
local alive = 0 for _ in pairs(weak) do alive += 1 end
print(string.format("mode=%s  #array=%d  false-keys=%d  payloads-still-alive=%d/%d  heap=%.0f KB", MODE, #g, falseCount(g), alive, N, collectgarbage("count")))
