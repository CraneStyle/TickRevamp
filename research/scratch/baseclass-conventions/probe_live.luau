--[[
	Can the LIVE BaseClass.luau (reference copy, identical to the HeroicSouls
	mirror) load under Lune, with or without a stubbed `game` global?
]]

local ok, err = pcall(require, "../../../reference/baseclass/BaseClass")
print("live BaseClass, no stub ->", ok, tostring(err):sub(1, 160))

-- Stub `game` as a global; does the module body see it, and does its
-- `require(game.ReplicatedStorage.SharedModules.JsonR)` then work?
local fakeJsonR = { isRegistered = function() return false end, BaseClassAutoRegister = function() end }
game = { ReplicatedStorage = { SharedModules = { JsonR = fakeJsonR } } }
local ok2, err2 = pcall(require, "../../../reference/baseclass/BaseClass")
print("live BaseClass, game stubbed ->", ok2, tostring(err2):sub(1, 160))

-- Which pure mixins load standalone?
for _, name in { "Stateful", "ObjectPool", "Invoker", "Callbacks", "Beholder" } do
	local okM, errM = pcall(require, "../../../reference/baseclass/" .. name)
	print(string.format("%-11s loads under Lune -> %s %s", name, tostring(okM), okM and "" or tostring(errM):sub(1, 90)))
end
