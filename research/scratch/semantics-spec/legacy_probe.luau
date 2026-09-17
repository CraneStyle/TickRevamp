local Legacy = require("../../../../TickAPIOptimize/reference/lune/Tick")
local function G() return Legacy.group() end
local function keys(g) local n=0 for k,v in pairs(g) do if type(k)=="table" then n+=1 end end return n end
local function section(s) print("\n== "..s) end

section("L1 recurring stops ITSELF inside callback while lagging (period 1, dt 3.5)")
do local g=G(); local fires=0; local h; h=g:recur(function() fires+=1; h:stop() end,1); g:update(3.5); print("fires after stop-in-callback:",fires,"(1 = correct; >1 = loop kept firing a stopped recur)") end

section("L2 callback stops ANOTHER not-yet-processed timer -> swapped element double-ticked?")
do local g=G(); local log={}
 local x=g:delay(function() table.insert(log,"x") end, 5)      -- idx1 (victim)
 local y=g:delay(function() table.insert(log,"y") end, 1.2)    -- idx2 processed 2nd; swapped to idx1 after x removed
 local z=g:delay(function() table.insert(log,"z"); x:stop() end, 0.5) -- idx3 processed first
 g:update(1); print("after update(1):",table.concat(log,","),"y.timer=",y.timer,"(0.2 = ticked once; fired/-0.8 = double-ticked)")
end
do local g=G(); local log={}
 local a=g:delay(function() table.insert(log,"a") end, 1.5)   -- idx1 processed last
 local b=g:delay(function() table.insert(log,"b") end, 5)     -- idx2 victim
 local c=g:delay(function() table.insert(log,"c"); b:stop() end, 0.5) -- idx3 processed first; after c removed, last=b? then b removed -> a moves?
 g:update(1); print("variant2 after update(1):",table.concat(log,","),"a.timer=",a.timer,"(0.5 = once)")
end

section("L3 nested past-due creation fires synchronously; ordering vs other due entries")
do local g=G(); local log={}
 g:delay(function() table.insert(log,"p(due1)"); g:delay(function() table.insert(log,"nested(due1.5)") end,0.5) end,1)
 g:delay(function() table.insert(log,"q(due1.2)") end,1.2)
 g:update(2); print(table.concat(log," > ")) end

section("L4 NaN / inf / numeric string / callable table inputs")
do local g=G()
 print("NaN delay:", pcall(function() g:delay(function() end, 0/0) end)); g:update(100); print("  clocks after update(100):", g:getClocks(), "(1 = accepted, never fires, leaks)")
 local g2=G(); print("inf delay:", pcall(function() g2:delay(function() end, math.huge) end)); g2:update(1e9); print("  clocks:", g2:getClocks())
 local g3=G(); print("string 2:", pcall(function() return g3:delay(function() end, "2") end))
 local g4=G(); local ct=setmetatable({},{__call=function() end}); print("callable table:", pcall(function() return g4:delay(ct, 1) end))
 local g5=G(); print("recur -1:", pcall(function() return g5:recur(function() end, -1) end))
 local g6=G(); print("fn nil:", pcall(function() return g6:delay(nil, 1) end))
end

section("L5 adjust on delay-0 handle / negative adjust / adjust recurring mid-cycle")
do local g=G(); local h=g:delay(function() end,0); h:adjust(5); print("adjust(5) on delay0: timer=",h.timer,"delay=",h.delay)
 local g2=G(); local n=0; local h2=g2:delay(function() n+=1 end,4); g2:update(1); h2:adjust(-2); print("adjust(-2): timer=",h2.timer,"delay=",h2.delay); g2:update(0); print("  fired on update(0)?",n)
 local g3=G(); local h3=g3:recur(function() end,4); g3:update(1); h3:adjust(8); print("recur adjust 4->8 at t=1: timer=",h3.timer,"(6 = ratio-preserving)")
end

section("L6 colon vs dot on bound module table")
print("Legacy:delay(...) =>", pcall(function() return Legacy:delay(function() end, 1) end))
print("Legacy.delay(...) =>", pcall(function() return Legacy.delay(function() end, 1) end))
do local g=G(); print("h.stop() dot misuse =>", pcall(function() local h=g:delay(function() end,1); h.stop() end)) end
print("Legacy.getClocks() on bound table =>", pcall(function() return Legacy.getClocks(Legacy) end))

section("L7 multiple after() on one parent, same delay: order")
do local g=G(); local log={}
 local p=g:delay(function() table.insert(log,"p") end,1)
 p:after(function() table.insert(log,"c1") end,1); p:after(function() table.insert(log,"c2") end,1)
 g:update(1); g:update(1); print(table.concat(log,","))
end

section("L8 after() on already-fired parent / on stopped parent")
do local g=G(); local log={}; local p=g:delay(function() table.insert(log,"p") end,1); g:update(1)
 local c=p:after(function() table.insert(log,"c") end,1); g:update(5); print("fired parent:",table.concat(log,","), " child identity distinct:", c~=p)
 local g2=G(); local p2=g2:delay(function() table.insert(log,"p2") end,1); p2:stop(); p2:after(function() table.insert(log,"c2") end,1); g2:update(5); print("stopped parent:",table.concat(log,","))
end

section("L9 double stop / stop after natural fire -> false-key leak (F3)")
do local g=G(); local h=g:delay(function() end,1); g:update(1); print("keys before stop:",keys(g)); h:stop(); print("keys after stop-on-fired:",keys(g)); h:stop(); print("after 2nd stop:",keys(g)) end

section("L10 stop(nil)/remove(non-handle)/remove handle of other group")
do local g=G(); print("remove(nil):", pcall(function() g:remove(nil) end)); print("remove(str):", pcall(function() g:remove("x") end), "keys:",keys(g))
 local g2=G(); local h=g2:delay(function() end,1); print("g:remove(h of g2):", pcall(function() g:remove(h) end), "g2 clocks:",g2:getClocks(),"g keys:",keys(g)) end

section("L11 reset from ANOTHER callback: is the target measured from now or now-dt?")
do local g=G(); local t=g:delay(function() end,10)       -- idx1 processed LAST
 local r=g:delay(function() t:reset() end,1)             -- idx2 processed FIRST
 g:update(1); print("target at idx1 (not yet ticked when reset): timer=",t.timer,"(10 = from now; 9 = from now-dt)")
 local g2=G(); local r2; local t2
 r2=g2:delay(function() t2:reset() end,1)                 -- idx1 processed last
 t2=g2:delay(function() end,10)                           -- idx2 processed first
 g2:update(1); print("target at idx2 (already ticked): timer=",t2.timer)
end

section("L12 dt negative / dt NaN / dt 0 with delay 0")
do local g=G(); local n=0; g:delay(function() n+=1 end,1); g:update(-5); print("dt -5: fired?",n); g:update(0/0); print("dt NaN: fired?",n); g:update(100); print("then dt 100: fired?",n)
 local g2=G(); local m=0; g2:delay(function() m+=1 end,0); g2:update(0); print("delay0 + dt0 fired?",m) end

section("L13 re-entrant update from inside own callback")
do local g=G(); local log={}
 g:recur(function() table.insert(log,"r@"..tostring(#log)) if #log==1 then g:update(1) end end,1)
 g:delay(function() table.insert(log,"d") end,1.5)
 print("reentrant:", pcall(function() g:update(1) end)); print(table.concat(log,","))
end

section("L14 stop then reset in same callback (one-shot self) -> resurrect?")
do local g=G(); local n=0; local h; h=g:delay(function() n+=1; h:stop(); h:reset() end,1); g:update(1); g:update(5); print("fires:",n,"clocks:",g:getClocks(),"keys:",keys(g)) end

section("L15 huge dt catch-up on recur (period 1, dt 10)")
do local g=G(); local n=0; g:recur(function() n+=1 end,1); g:update(10); print("fires:",n) end

section("L16 nested delay(0) inside callback when overshoot==0 vs >0")
do local g=G(); local log={}; g:delay(function() table.insert(log,"p"); g:delay(function() table.insert(log,"n0") end,0) end,1); g:update(1); print("exact hit:",table.concat(log,","),"clocks:",g:getClocks()); g:update(0); print("  after update(0):",table.concat(log,","))
 local g2=G(); local log2={}; g2:delay(function() table.insert(log2,"p"); g2:delay(function() table.insert(log2,"n0") end,0) end,1); g2:update(1.5); print("overshoot:",table.concat(log2,",")) end

section("L17 chained child stop before parent fires (F8) / parent stop -> child")
do local g=G(); local log={}; local p=g:delay(function() table.insert(log,"p") end,1); local c=p:after(function() table.insert(log,"c") end,1); c:stop(); g:update(1); g:update(1); print("child stopped early:",table.concat(log,","),"keys:",keys(g)) end
