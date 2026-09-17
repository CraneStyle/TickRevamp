--!nonstrict
--[[
	env_spec — checks the Env platform seam: the IsRoblox flag, the warn hook and
	its restore behavior, the traceback function, and the sibling loader.
]]

local fs = require("@lune/fs")

local Env = require("../../../src/Veron/Env")

local EXPECTED_KEYS = { "IsRoblox", "Load", "SetWarn", "Traceback", "Warn" }

local function _sortedKeys(tbl)
	local keys = {}

	for key in pairs(tbl) do
		table.insert(keys, tostring(key))
	end

	table.sort(keys)

	return keys
end

return function(t)
	t.test("SetWarn restores", function()
		local original = Env.Warn
		local seenOuter, seenInner = {}, {}

		t.throws(function()
			Env.SetWarn("not a function")
		end, "Env: SetWarn expects a function, got string")
		t.eq(Env.Warn, original, "a rejected SetWarn leaves Warn untouched")

		local restoreOuter = Env.SetWarn(function(message)
			table.insert(seenOuter, message)
		end)
		Env.Warn("outer 1")
		t.eq(#seenOuter, 1, "outer seam captures")

		local restoreInner = Env.SetWarn(function(message)
			table.insert(seenInner, message)
		end)
		Env.Warn("inner 1")
		t.eq(#seenInner, 1, "inner seam captures")
		t.eq(#seenOuter, 1, "outer seam is shadowed")

		restoreInner()
		Env.Warn("outer 2")
		t.eq(#seenOuter, 2, "inner restore returns to the outer seam")

		restoreInner()
		t.eq(#seenOuter, 2, "a second inner restore is a no-op")
		Env.Warn("outer 3")
		t.eq(#seenOuter, 3, "outer seam still installed after the no-op")

		restoreOuter()
		t.eq(Env.Warn, original, "outer restore returns the original Warn")
		t.eq(#seenInner, 1, "inner seam never saw later messages")
	end)

	t.test("Load resolves siblings", function()
		-- Env is itself a module directory under build/src/Veron/, so Load("Env")
		-- proves the Lune resolution root is that directory (cache identity).
		t.eq(Env.Load("Env"), Env, "Load(\"Env\") is the cached Env table")

		if fs.isDir("build/src/Veron/VeronEvent") then
			local direct = require("../../../src/Veron/VeronEvent")
			t.eq(Env.Load("VeronEvent"), direct, "Load(\"VeronEvent\") is the cached VeronEvent module")
		end

		t.throws(function()
			Env.Load("EnvSpecNoSuchSibling")
		end)
	end)

	t.test("IsRoblox is false under Lune and Env exposes exactly IsRoblox/Warn/Traceback/Load/SetWarn", function()
		t.eq(Env.IsRoblox, false, "IsRoblox")
		t.eq(getmetatable(Env), nil, "Env is a plain table")

		local keys = _sortedKeys(Env)
		t.eq(#keys, #EXPECTED_KEYS, "key count")
		for index, key in EXPECTED_KEYS do
			t.eq(keys[index], key, ("key %d"):format(index))
		end

		t.eq(type(Env.Warn), "function", "Warn type")
		t.eq(Env.Warn, warn, "Warn defaults to the global warn")
		t.eq(Env.Traceback, debug.traceback, "Traceback is debug.traceback")
		t.eq(type(Env.Load), "function", "Load type")
		t.eq(type(Env.SetWarn), "function", "SetWarn type")
	end)
end
