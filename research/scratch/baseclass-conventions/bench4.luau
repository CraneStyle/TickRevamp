-- Guard variants for colon-vs-dot protection on a BaseClass instance method.
local BaseClass = require("../../../../../../../GitHub/BaseClass/src/core/BaseClass")
local clock = os.clock
local N = 10000000
local function bench(label, fn)
	local best = math.huge
	for _ = 1, 3 do
		local t0 = clock()
		fn()
		local dt = clock() - t0
		if dt < best then best = dt end
	end
	print(string.format("%-58s %8.2f ns/op", label, best / N * 1e9))
end
local Ev = BaseClass.class("P4Ev")
function Ev:initialize(v) self._Due = v end
local dict = Ev.__instanceDict
local getmetatable_ = getmetatable
local type_ = type
function Ev:A(b) return self._Due + b end
function Ev:B(b)
	if getmetatable_(self) ~= dict then error("colon") end
	return self._Due + b
end
function Ev:C(b)
	if type_(self) ~= "table" or self.class ~= Ev then error("colon") end
	return self._Due + b
end
function Ev:D(b)
	if self.class ~= Ev then error("colon") end
	return self._Due + b
end
function Ev:E(b)
	if rawget(self, "class") ~= Ev then error("colon") end
	return self._Due + b
end
local e = Ev:new(1)
bench("no guard", function() local acc = 0 for i = 1, N do acc = e:A(i) end end)
bench("guard: localized getmetatable(self) ~= dict", function() local acc = 0 for i = 1, N do acc = e:B(i) end end)
bench("guard: type(self) ~= 'table' or self.class ~= Ev", function() local acc = 0 for i = 1, N do acc = e:C(i) end end)
bench("guard: self.class ~= Ev (rawget hit)", function() local acc = 0 for i = 1, N do acc = e:D(i) end end)
bench("guard: rawget(self,'class') ~= Ev", function() local acc = 0 for i = 1, N do acc = e:E(i) end end)
-- what the misuse errors look like
for _, name in { "A", "B", "C", "D" } do
	local ok, err = pcall(function() return e[name](5) end)
	print(name, "dot-misuse ->", ok, tostring(err):gsub("^.-bench4:%d+: ", ""):sub(1, 60))
end
