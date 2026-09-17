local T = require("./LegacyTick")
print("loaded", type(T), type(T.delay))
local gc = collectgarbage("count")
print("gc count", gc)
