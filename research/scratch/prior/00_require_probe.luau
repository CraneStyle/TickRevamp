-- Probe which require path forms Lune 0.10.5 accepts for the prior build's TickAPI.
local results = {}
local function try(label, path)
	local ok, res = pcall(require, path)
	results[#results + 1] = ("%-10s %-70s -> %s"):format(label, path, ok and ("OK (VERSION=" .. tostring((res :: any).VERSION) .. ")") or ("FAIL: " .. tostring(res)))
end
try("absolute", "C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize/build/src/TickAPI")
try("relative", "../../../../TickAPIOptimize/build/src/TickAPI")
try("rel-Group", "../../../../TickAPIOptimize/build/src/TickAPI/Group")
try("rel-shim", "../../../../TickAPIOptimize/reference/lune/Tick")
for _, r in results do print(r) end
-- collectgarbage support
local okc, cnt = pcall(collectgarbage, "count")
print("collectgarbage('count') ->", okc, cnt)
local oks, r2 = pcall(collectgarbage, "collect")
print("collectgarbage('collect') ->", oks, r2)
print("math.max(NaN,0) =", math.max(0/0, 0), " math.max(0,NaN) =", math.max(0, 0/0))
print("inf % 1 =", math.huge % 1, " NaN<0 =", (0/0) < 0, " inf<0 =", math.huge < 0)
-- xpcall on a callable table
local ct = setmetatable({}, { __call = function() return "called" end })
print("xpcall(callableTable) ->", xpcall(ct, debug.traceback))
