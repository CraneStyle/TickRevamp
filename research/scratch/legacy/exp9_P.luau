local ok, TickAPI = pcall(require, "../../../../TickAPIOptimize/build/src/TickAPI")
if not ok then print("P require failed:", TickAPI) return end
local DT = 1/60
local function G() return TickAPI.new({ driver = "Manual" }) end

print("=== 9a: P — nested delay inside a RECURRING callback ===")
do local g = G(); local t = 0; local c, f
  g.recur(function() if not c then c = t; g.delay(function() f = t end, 0.5) end end, 1)
  for _ = 1, 200 do t += DT; g.update(DT); if f then break end end
  print(string.format("  created@%.4f fired@%.4f wait=%.4f (legacy gave 1.5)", c, f, f - c)) end

print("=== 9b: P — delay(NaN) ===")
do local g = G(); local fired = false
  local ok2, e = pcall(function() g.delay(function() fired = true end, 0/0) end)
  print("  accepted?", ok2, e); if ok2 then g.update(DT); print("  fired on first update?", fired, " getClocks=", g.getClocks()) end end

print("=== 9c: P — replace pattern inside callback (stop old, create new) ===")
do local g = G(); local t = 0; local A = g.delay(function() end, 10); local cAt, fAt
  g.delay(function() A:stop(); cAt = t; g.delay(function() fAt = t end, 1) end, 0.5)
  for _ = 1, 200 do t += DT; g.update(DT); if fAt then break end end
  print(string.format("  new timer created@%.4f fired@%.4f wait=%.4f (ideal 1.0 measured from parent's due 0.5 => fires @1.5)", cAt, fAt, fAt - cAt)) end

print("=== 9d: P — tiny period catch-up with default (unbounded) maxCatchUpPerFrame ===")
do local g = G(); local n = 0; g.recur(function() n += 1 end, 1e-4); g.update(1); print("  recur(1e-4) fires in one update(1):", n, " (recur(1e-9) would be 1e9)") end

print("=== 9e: P — handle available inside its own callback for a past-due nested event? ===")
do local g = G(); local msg = "ok"
  g.delay(function() local h; h = g.delay(function() if h == nil then msg = "h is nil" else h:stop() end end, 0.1) end, 0.5)
  g.update(1); print("  nested past-due event: ", msg) end

print("=== 9f: P — one-shot stops itself inside its callback; double stop; stop during catch-up ===")
do local g = G(); local h; h = g.delay(function() h:stop() end, 0.1); g.update(1); h:stop()
  local s = g.getStats(); print("  live=", s.live, " stale=", s.stale, " heap=", s.heapSize, " state=", h:getState())
  local n = 0; local R; R = g.recur(function() n += 1; R:stop() end, 0.1); g.update(0.35); print("  recur self-stop while lagging: fires=", n, " (legacy 3)") end

print("=== 9g: P — yield inside callback (coroutine simulation), second update while suspended ===")
do local g = G(); local log = {}
  local A = g.recur(function() table.insert(log, "A") end, 10)
  g.delay(function() coroutine.yield(); g.delay(function() table.insert(log, "nested") end, 0) end, 0.5)
  local co = coroutine.create(function() g.update(1) end)
  print("  frame1 resume:", coroutine.resume(co))
  print("  suspended: now=", g.now(), " base=", tostring(g._base))
  g.update(1); print("  frame2 done: now=", g.now(), " base=", tostring(g._base))
  print("  frame1 resume2:", coroutine.resume(co), " now=", g.now(), " stats.live=", g.getStats().live, " heap=", g.getStats().heapSize)
  g.update(0.001); print("  log:", table.concat(log, ","), " (nested delay(0) armed from now=2 instead of due=0.5)") end

print("=== 9h: P — colon vs dot on handle / group ===")
do local g = G(); local h = g.delay(function() end, 1)
  print("  h.stop():", pcall(function() return h.stop() end)); print("  g:delay ok:", pcall(function() return g:delay(function() end, 1) ~= nil end)); print("  g:remove(h):", pcall(function() return g:remove(h) end), h:getState()) end

print("=== 9i: P — adjust on zero-period (F6 absent) ===")
do local g = G(); local h = g.delay(function() end, 0); h:adjust(5); print("  remaining=", h:getRemaining(), " period=", h.period); g.update(DT); print("  state after 1 frame:", h:getState(), "(should still be Pending for 5s)") end

print("=== 9j: P — error policy leaves scheduler consistent; no err poisoning ===")
do local g = G(); g.recur(function() error("boom") end, 1)
  local warned = 0; local oldwarn = warn; warn = function() warned += 1 end
  for _ = 1, 60 do g.update(DT) end; warn = oldwarn
  local t0 = g.now(); local f; g.delay(function() f = g.now() end, 0.5); for _ = 1, 60 do g.update(DT); if f then break end end
  print("  warned:", warned, " top-level delay(0.5) waited", f - t0) end
