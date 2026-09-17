--!nonstrict
--[[
	Env is the small platform seam for Veron. It is the only module in
	the tree that touches `game` or `script`, so everything else reaches
	the platform through this table and runs the same under Lune (the
	tests and the bench) and inside Roblox.

	The whole surface is five keys:

		IsRoblox   boolean         true when running inside Roblox
		Warn       function(msg)   the warn function; SetWarn swaps it
		Traceback  function        debug.traceback
		Load       function(name)  loads a module that sits next to Env
		SetWarn    function(fn)    test hook, returns a restore function

	Load leans on one Lune rule. Inside an init.luau, `./` is the directory
	that contains this module's own directory, so from here `./` is
	build/src/Veron/, where the sibling modules live.
]]

local IS_ROBLOX = typeof(script) == "Instance"

local Env = {}

Env.IsRoblox = IS_ROBLOX
Env.Warn = warn
Env.Traceback = debug.traceback

--[[
	Loads a module that sits next to Env, by name. On Roblox that is
	script.Parent[name]; under Lune it is require("./" .. name), resolved
	against Env's own file. Ask for "VeronEvent" and you get that module.
	Every caller gets back the same cached module object.
]]
function Env.Load(name)
	if IS_ROBLOX then
		return require(script.Parent[name])
	end

	return require("./" .. name)
end

--[[
	Swaps in `fn` as Env.Warn so a test can capture warnings, and returns
	a restore function that puts the previous Warn back. Restores nest
	last-in first-out. Calling the same restore twice does nothing the
	second time, so one test cannot accidentally undo the restore of an
	outer scope.
]]
function Env.SetWarn(fn)
	if type(fn) ~= "function" then
		error(("Env: SetWarn expects a function, got %s"):format(typeof(fn)), 2)
	end

	local previous = Env.Warn
	local restored = false

	Env.Warn = fn

	return function()
		if restored then
			return
		end

		restored = true
		Env.Warn = previous
	end
end

return Env
