local T = require("../../../../TickAPIOptimize/build/src/TickAPI")
local function G() return T.new({ driver = "Manual" }) end
local function section(s) print("\n== "..s) end

section("P1 NaN / inf delay accepted?")
do local g=G(); print("NaN delay:", pcall(function() return g.delay(function() end, 0/0) end)); g.update(100); print("  getClocks:",g.getClocks(), "stats.heapSize:", g.getStats().heapSize)
 local n=0; local ok=pcall(function() g.delay(function() n+=1 end, 1) end); g.update(2); print("  a later 1s timer fires with NaN in heap?", n)
 local g2=G(); print("inf delay:", pcall(function() return g2.delay(function() end, math.huge) end)); print("recur NaN:", pcall(function() return g2.recur(function() end, 0/0) end)); print("recur inf:", pcall(function() return g2.recur(function() end, math.huge) end))
end

section("P2 pause on Chained / pause on Paused / resume on Pending")
do local g=G(); local p=g.delay(function() end,1); local c=p:after(function() end,1)
 print("c:pause():", pcall(function() c:pause() end)); print("p:pause();p:pause():", pcall(function() p:pause(); p:pause() end))
 local g2=G(); local h=g2.delay(function() end,1); print("resume on Pending:", pcall(function() h:resume() end), "state:",h:getState(),"clocks:",g2.getClocks()) end

section("P3 after() on Fired parent returns parent?")
do local g=G(); local log={}; local p=g.delay(function() table.insert(log,"p") end,1); g.update(1); local c=p:after(function() table.insert(log,"c") end,1); print("returned==parent:", c==p, "state:", c:getState()); g.update(5); print("log:",table.concat(log,",")) end

section("P4 reset/adjust/resume from ANOTHER handle's callback: measured from firing due (base) or now?")
do local g=G(); local t=g.delay(function() end,10); g.delay(function() t:reset() end,1); g.update(1.5); print("reset in cb: remaining=",t:getRemaining(),"(10 = from now; 9.5 = from firing due)")
 local g2=G(); local t2=g2.delay(function() end,10); g2.delay(function() t2:adjust(20) end,1); g2.update(1.5); print("adjust in cb: remaining=",t2:getRemaining(),"(now-based: (8.5/10)*20=17; base-based: 16.5)")
 local g3=G(); local t3=g3.delay(function() end,10); t3:pause(); g3.delay(function() t3:resume() end,1); g3.update(1.5); print("resume in cb: remaining=",t3:getRemaining(),"(10 = from now; 9.5 = from due)")
end

section("P5 re-entrant update from own callback")
do local g=G(); local log={}
 g.recur(function() table.insert(log,"r") if #log==1 then g.update(1) end end,1); g.delay(function() table.insert(log,"d") end,1.5)
 print("reentrant:", pcall(function() g.update(1) end)); print(table.concat(log,","), "now=",g.now())
end

section("P6 stop self inside recurring callback while lagging")
do local g=G(); local n=0; local h; h=g.recur(function() n+=1; h:stop() end,1); g.update(3.5); print("fires:",n,"state:",h:getState()) end

section("P7 recur catch-up on dt 10 (unbounded) / with maxCatchUpPerFrame=3")
do local g=G(); local n=0; g.recur(function() n+=1 end,1); g.update(10); print("unbounded fires:",n)
 local g2=T.new({driver="Manual",maxCatchUpPerFrame=3}); local m=0; g2.recur(function() m+=1 end,1); g2.update(10); print("capped fires:",m); g2.update(0); print("  next update(0):",m) end

section("P8 stop another entry due this frame before it pops")
do local g=G(); local log={}; local b=g.delay(function() table.insert(log,"b") end,1.2); g.delay(function() table.insert(log,"a"); b:stop() end,1); g.update(2); print(table.concat(log,","),"stats.stale:",g.getStats().stale) end

section("P9 getRemaining under timeScale 2")
do local g=G(); g.setTimeScale(2); local h=g.delay(function() end,10); g.update(1); print("after wall 1s @x2: remaining=",h:getRemaining(),"now=",g.now()) end

section("P10 dot misuse on handle / remove handle from other group / remove(non-handle)")
do local g=G(); local h=g.delay(function() end,1); print("h.stop():", pcall(function() h.stop() end))
 local g2=G(); local h2=g2.delay(function() end,1); print("g.remove(h2 of g2):", pcall(function() g.remove(h2) end), "h2 state:",h2:getState(),"g2 clocks:",g2.getClocks())
 print("g.remove(str):", pcall(function() g.remove("x") end)); print("g.remove(nil):", pcall(function() g.remove(nil) end)) end

section("P11 parent callback errors -> chained children still armed?")
do local g=G(); local log={}; local p=g.delay(function() error("boom") end,1); p:after(function() table.insert(log,"c1") end,1); p:after(function() table.insert(log,"c2") end,1); g.update(1); g.update(1); print("children fired:",table.concat(log,","), "(warn printed above is the default policy)") end

section("P12 onError=error policy: rest of frame still runs, error re-raised after")
do local g=T.new({driver="Manual",onError="error"}); local log={}; g.delay(function() error("first") end,1); g.delay(function() table.insert(log,"second") end,1); local ok,err=pcall(function() g.update(1) end); print("ok:",ok,"log:",table.concat(log,","),"err starts:",tostring(err):sub(1,40)) end

section("P13 adjust from inside own recurring callback / reset inside own one-shot callback")
do local g=G(); local dues={}; local h; h=g.recur(function() table.insert(dues,h:getRemaining()); if #dues==1 then h:adjust(4) end end,2); g.update(2); print("recur adjust in own cb: remaining after=",h:getRemaining(),"period=",h.period)
 local g2=G(); local n=0; local h2; h2=g2.delay(function() n+=1; h2:reset() end,1); g2.update(1); g2.update(5); print("one-shot reset in own cb: fires=",n,"state=",h2:getState()) end

section("P14 same-due ordering: created-in-callback vs pre-existing same due")
do local g=G(); local log={}; g.delay(function() table.insert(log,"p"); g.delay(function() table.insert(log,"nested@2") end,1) end,1); g.delay(function() table.insert(log,"pre@2") end,2); g.update(2); print(table.concat(log,",")) end

section("P15 adjust on period-0 one-shot (RF-001)")
do local g=G(); local h=g.delay(function() end,0); print("adjust(5):", pcall(function() h:adjust(5) end), "remaining=",h:getRemaining(), "due=",h._due) end

section("P16 Chained child: getRemaining / adjust / reset / stop before parent fires / grandchild")
do local g=G(); local log={}; local p=g.delay(function() table.insert(log,"p") end,1); local c=p:after(function() table.insert(log,"c") end,2); local gc=c:after(function() table.insert(log,"gc") end,1)
 print("c remaining(Chained)=",c:getRemaining(),"state=",c:getState()); c:adjust(4); print("after adjust(4): period=",c.period); c:reset()
 g.update(1); print("after parent: c state=",c:getState(),"remaining=",c:getRemaining()); g.update(4); g.update(1); print(table.concat(log,","))
 local g2=G(); local log2={}; local p2=g2.delay(function() table.insert(log2,"p") end,1); local c2=p2:after(function() table.insert(log2,"c") end,1); c2:stop(); g2.update(1); g2.update(1); print("child stopped before parent:",table.concat(log2,","),"c2 state:",c2:getState())
 local g3=G(); local p3=g3.delay(function() end,1); local c3=p3:after(function() end,1); p3:stop(); print("parent stopped -> child state:",c3:getState()) end

section("P17 dt negative / NaN / non-number")
do local g=G(); local n=0; g.delay(function() n+=1 end,1); print("update(-5):", pcall(function() g.update(-5) end), "now=",g.now()); print("update(NaN):", pcall(function() g.update(0/0) end), "now=",g.now()); print("update(5):", pcall(function() g.update(5) end), "fired?",n) end

section("P18 delay 0 fires at next update even with dt 0; nested delay(0) in callback")
do local g=G(); local n=0; g.delay(function() n+=1 end,0); g.update(0); print("delay0+dt0 fired:",n)
 local g2=G(); local log={}; g2.delay(function() table.insert(log,"p"); g2.delay(function() table.insert(log,"n0") end,0) end,1); g2.update(1); print("nested delay0 exact hit:",table.concat(log,",")) end
