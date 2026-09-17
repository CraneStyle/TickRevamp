local weak = setmetatable({}, { __mode = "v" })
weak.A = { Remove = true }
local ok, err = pcall(collectgarbage, "collect")
print("collectgarbage(collect) ok =", ok, err)
print("weak.A after collect =", weak.A)
