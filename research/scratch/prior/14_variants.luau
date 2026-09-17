local C = require("./_common")
local Variants = C.Variants
C.section("freeze")
do
	local v = Variants.resolve({ driver = "Manual" })
	print("set field ->", pcall(function() (v :: any).name = "x" end))
	print("table.isfrozen:", table.isfrozen(v))
end
C.section("onError function receives (message, handle)")
do
	local got
	local g = C.G({ onError = function(m, h) got = { m = m, h = h } end })
	local h = g.delay(function() error("xyz") end, 1)
	g.update(1)
	print("handle identity:", got.h == h, "| message starts with:", (got.m:sub(1, 60):gsub("\n", " ")))
	local g2 = C.G({ onError = function() error("handler-broke") end })
	g2.delay(function() error("cb") end, 1)
	print("handler error shielded ->", pcall(function() g2.update(1) end))
end
C.section("default name counter is module-global and pre-consumed by the builtins")
do
	print("next default name:", Variants.resolve().name, "then", Variants.resolve().name)
	print("failed resolve still consumes a number:", pcall(Variants.resolve, { bogus = 1 }), Variants.resolve().name)
end
C.section("callable-table callback runs through xpcall")
do
	local g = C.G()
	local ran = false
	local ct = setmetatable({}, { __call = function() ran = true end })
	g.delay(ct, 1); g.update(1)
	print("callable table fired:", ran)
end
