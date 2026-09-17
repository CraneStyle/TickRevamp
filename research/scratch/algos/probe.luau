-- probe: can we require the prior Group via relative path from this scratch dir?
local ok, err = pcall(function()
	local Group = require("../../../../TickAPIOptimize/build/src/TickAPI/Group")
	local Variants = require("../../../../TickAPIOptimize/build/src/TickAPI/Variants")
	local g = Group.new(Variants.resolve({ driver = "Manual" }))
	local fired = 0
	g:delay(function() fired += 1 end, 0.5)
	g:update(1)
	print("relative require OK, fired =", fired, "collectgarbage count", collectgarbage("count"))
end)
print(ok, err)
