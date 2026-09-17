local C = require("./_common")
local G = C.G
C.section("getRemaining under timeScale 2 reports group-time seconds")
do
	local g = G()
	g.setTimeScale(2)
	local h = g.delay(function() end, 10)
	print("remaining at creation =", h:getRemaining())
	g.update(1) -- 1 wall second = 2 group seconds
	print("after 1 wall-second: remaining =", h:getRemaining(), "(group-time 8; wall-time would be 4) now =", g.now())
end
C.section("setTimeScale(0): delay never fires; delay(fn,0) still fires on the next update")
do
	local g = G()
	g.setTimeScale(0)
	local a, b = false, false
	g.delay(function() a = true end, 1)
	g.delay(function() b = true end, 0)
	for _ = 1, 10 do g.update(1) end
	print("delay(1) fired:", a, "| delay(0) fired while frozen:", b)
end
C.section("setTimeScale(inf) / setTimeScale(NaN) are ACCEPTED and poison _now")
do
	local g = G()
	print("setTimeScale(math.huge) ->", pcall(function() g.setTimeScale(math.huge) end))
	g.update(0.016)
	print("now =", g.now())
	local fired = false
	g.delay(function() fired = true end, 3600)
	g.update(0.016)
	print("delay(3600) fired on the next frame:", fired)
	local g2 = G()
	print("setTimeScale(0/0) ->", pcall(function() g2.setTimeScale(0 / 0) end))
	print("Variants.resolve({timeScale=0/0}) ->", pcall(function() return C.Variants.resolve({ timeScale = 0 / 0 }).timeScale end))
	print("Variants.resolve({timeScale=math.huge}) ->", pcall(function() return C.Variants.resolve({ timeScale = math.huge }).timeScale end))
end
