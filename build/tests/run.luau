--!nonstrict
-- build/tests/run.luau — the workspace test command: `lune run build/tests/run.luau` (run from the repo root).
-- Discovers every `*_spec.luau` under build/tests/spec (recursively, sorted), runs it, prints TAP-style
-- lines plus a `N passed, M failed` summary, and exits 1 on any failure.
--
-- Spec file shape (file names must end in `_spec.luau` and contain no other dots — Lune's require
-- treats a dot as a path component):
--   return function(t)
--       t.test("does the thing", function() t.eq(1 + 1, 2) end)
--   end
-- `t.test(name, fn)` registers and runs one test; `t.eq(actual, expected, msg?)` asserts equality;
-- `t.near(actual, expected, tol?, msg?)` asserts |a-b| <= tol (default 1e-6); `t.throws(fn, pattern?)`
-- asserts fn errors (optionally matching pattern). Test names in plan acceptance criteria are written
-- `build/tests/spec/<dir>/<file>_spec.luau::<name>`.
local fs = require("@lune/fs")
local process = require("@lune/process")

local SPEC_ROOT = "build/tests/spec"

local specs = {}
local function walk(dir)
	if not fs.isDir(dir) then return end
	for _, entry in fs.readDir(dir) do
		local p = dir .. "/" .. entry
		if fs.isDir(p) then
			walk(p)
		elseif entry:match("_spec%.luau$") then
			table.insert(specs, p)
		end
	end
end
walk(SPEC_ROOT)
table.sort(specs)

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

for _, spec in specs do
	-- run.luau lives in build/tests, so spec paths become "./spec/…" relative requires (no extension).
	local rel = "./" .. spec:gsub("^build/tests/", ""):gsub("%.luau$", "")
	local okLoad, factory = pcall(require, rel)
	if not okLoad then
		n += 1; failed += 1
		print(("not ok %d - %s::<load>"):format(n, spec))
		print("  " .. tostring(factory))
	else
		local okRun, err = pcall(factory, makeT(spec))
		if not okRun then
			n += 1; failed += 1
			print(("not ok %d - %s::<factory>"):format(n, spec))
			print("  " .. tostring(err))
		end
	end
end

print(("%d passed, %d failed"):format(passed, failed))
process.exit(failed == 0 and 0 or 1)
