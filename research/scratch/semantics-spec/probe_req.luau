local ok1, r1 = pcall(require, "C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickAPIOptimize/reference/lune/Tick")
print("abs legacy:", ok1, ok1 and type(r1) or r1)
local ok2, r2 = pcall(require, "../../../../TickAPIOptimize/reference/lune/Tick")
print("rel legacy:", ok2, ok2 and type(r2) or r2)
local ok3, r3 = pcall(require, "../../../../TickAPIOptimize/build/src/TickAPI")
print("rel prior:", ok3, ok3 and type(r3) or r3)
if ok3 then print("prior VERSION", r3.VERSION, "Tick?", r3.Tick ~= nil, "Tickr?", r3.Tickr ~= nil) end
