--!nonstrict
-- build/tests/run_one.luau — run ONE spec file: `lune run build/tests/run_one.luau spec/heap/heap_spec`
-- (path relative to build/tests, no extension). Same `t` helpers as run.luau. Exit 1 on any failure.
local process = require("@lune/process")

local target = process.args[1]
if not target then
	print("usage: lune run build/tests/run_one.luau spec/<area>/<name>_spec")
	process.exit(2)
end

local passed, failed, n = 0, 0, 0

local function makeT(specPath)
	local t = {}
	function t.test(name, fn)
		n += 1
		local ok, err = pcall(fn)
		if ok then
			passed += 1
			print(("ok %d - %s::%s"):format(n, specPath, name))
		else
			failed += 1
			print(("not ok %d - %s::%s"):format(n, specPath, name))
			print("  " .. tostring(err))
		end
	end
	function t.eq(actual, expected, msg)
		if actual ~= expected then
			error(("%s: expected %s, got %s"):format(msg or "eq", tostring(expected), tostring(actual)), 2)
		end
	end
	function t.near(actual, expected, tol, msg)
		tol = tol or 1e-6
		if type(actual) ~= "number" or math.abs(actual - expected) > tol then
			error(("%s: expected %s ± %s, got %s"):format(msg or "near", tostring(expected), tostring(tol), tostring(actual)), 2)
		end
	end
	function t.throws(fn, pattern)
		local ok, err = pcall(fn)
		if ok then error("expected an error, none thrown", 2) end
		if pattern and not tostring(err):find(pattern) then
			error(("error %q does not match %q"):format(tostring(err), pattern), 2)
		end
	end
	return t
end

local rel = "./" .. target:gsub("^build/tests/", ""):gsub("%.luau$", "")
local okLoad, factory = pcall(require, rel)
if not okLoad then
	print("not ok - " .. target .. "::<load>")
	print("  " .. tostring(factory))
	process.exit(1)
end
local okRun, err = pcall(factory, makeT(target))
if not okRun then
	print("not ok - " .. target .. "::<factory>")
	print("  " .. tostring(err))
	failed += 1
end
print(("%d passed, %d failed"):format(passed, failed))
process.exit(failed == 0 and 0 or 1)
