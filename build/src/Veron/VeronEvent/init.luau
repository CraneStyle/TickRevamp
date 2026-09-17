--!nonstrict
--[[
	VeronEvent is the handle a Veron gives you when you arm a timer. Everything
	you do to that timer afterwards goes through this handle.

	This is a plain module, and the module table doubles as the metatable for
	handles. The scheduler builds each handle as a small table and stamps
	VeronEvent onto it with setmetatable, so method calls resolve here. Building
	a handle by hand is refused; only a Veron makes them.

	Every method checks it was called with a colon (event:Stop(), not
	event.Stop()), then hands the work to the scheduler that owns the timer. The
	scheduler is the only thing that touches the timing structures, so nothing in
	this file reads or writes them. The query methods read the handle's own
	fields, and Describe also reads the owner's name.

	Every method still works after a timer has fired or been stopped. The
	chainable ones hand the handle back, Stop returns nothing, and the queries
	answer 0, false, or "Stopped".
]]
local VeronEvent = {}
VeronEvent.__index = VeronEvent
VeronEvent._VERSION = "3.0.0"

local getmetatable = getmetatable

-- The five states a handle moves through, low to high: Pending, Paused,
-- Chained, Fired, Stopped. Fired and Stopped are terminal, meaning any
-- _State at FIRED or beyond.
local PENDING, PAUSED, CHAINED, FIRED, STOPPED = 1, 2, 3, 4, 5

-- _Flags packs a few bits. This file reads them with plain arithmetic
-- rather than bit32: a re-pause is owed when _Flags is 8 or more, and a
-- stop-after-fire when _Flags % 8 is 4 or more.
local REPAUSE = 8

local COLON_MESSAGE = "VeronEvent: methods take a colon: "
	.. "event:Stop(), not event.Stop()"
local CONSTRUCT_MESSAGE = "VeronEvent: handles are created by a Veron "
	.. "(Delay/Recur/After)"

VeronEvent.STATE_NAMES = table.freeze({
	"Pending",
	"Paused",
	"Chained",
	"Fired",
	"Stopped",
})

local STATE_NAMES = VeronEvent.STATE_NAMES
local eventDict = VeronEvent

--[[
	Handles are only ever built by a Veron, so building one by hand is refused.
	Both VeronEvent.new() and VeronEvent:new() land here and raise, blaming the
	call site rather than this function.
]]
function VeronEvent.new()
	error(CONSTRUCT_MESSAGE, 2)
end

--[[
	True when class is VeronEvent. Lets outside code confirm a table is one of
	our handles the same way it would check any class instance.
]]
function VeronEvent:isInstanceOf(class)
	return class == VeronEvent
end

-- Calling the module like a constructor, VeronEvent(), is refused the same way
-- as VeronEvent.new(), since only a Veron makes handles.
setmetatable(VeronEvent, {
	__call = function()
		error(CONSTRUCT_MESSAGE, 2)
	end,
})

-------------------------------------------------------------------
-- Timer controls. Each one hands the work to the scheduler that owns
-- the timer.
-------------------------------------------------------------------

--[[
	Cancels the timer for good. It never fires again and its state reads
	Stopped from here on.
]]
function VeronEvent:Stop()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	self._Scheduler:_Stop(self)
end

--[[
	Starts the countdown over at a full period from now, as if the timer
	had just been armed. A chained or already-finished timer ignores it.
]]
function VeronEvent:Reset()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Reset(self)
end

--[[
	Changes the total period while keeping how far along the timer
	already is. Halfway through a 10 second timer, Adjust(20) leaves it
	halfway, so 10 seconds remain. newTotal must be greater than zero.
]]
function VeronEvent:Adjust(newTotal)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Adjust(self, newTotal)
end

--[[
	Schedules fn to run `delay` seconds after this timer fires, and hands
	back the handle for that follow-up. You cannot chain onto a recurring
	timer.
]]
function VeronEvent:After(fn, delay)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_After(self, fn, delay)
end

--[[
	Sets the period used the next time the timer arms. It does not
	disturb the countdown already running. A recurring timer needs a
	period above zero; a one-shot allows zero.
]]
function VeronEvent:SetPeriod(period)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_SetPeriod(self, period)
end

--[[
	Sets how many seconds from now until the timer fires, without
	touching its period. Good for nudging a single fire earlier or later.
]]
function VeronEvent:SetRemaining(remaining)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_SetRemaining(self, remaining)
end

--[[
	Freezes the timer and remembers how much time was left. It will not
	fire while paused. Resume picks up from the time that remained.
]]
function VeronEvent:Pause()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Pause(self)
end

--[[
	Unfreezes a paused timer. It fires after the time that was left when
	it was paused.
]]
function VeronEvent:Resume()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Resume(self)
end

--[[
	Pauses the timer if it is running, resumes it if it is paused. Handy
	for a single key that flips a timer on and off.
]]
function VeronEvent:Toggle()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Toggle(self)
end

--[[
	Arms the timer again from now. A one-shot that already fired runs
	once more a full period out; one that is still waiting is reset and
	resumed.
]]
function VeronEvent:Restart()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Restart(self)
end

--[[
	Forces the callback to run on the next update pass instead of waiting
	for its due time. Pass { Stop = true } to also stop a recurring timer
	after that forced run. Returns true when the fire is queued.
]]
function VeronEvent:Complete(opts)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_Complete(self, opts, 3)
end

--[[
	Runs the callback right now, before this call returns, instead of
	waiting for the next update. Pass { Stop = true } to stop a recurring
	timer after it runs.
]]
function VeronEvent:CompleteNow(opts)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_CompleteNow(self, opts, 3)
end

--[[
	Controls how a recurring timer handles repeats it missed while the
	clock jumped ahead. mode is "cap" with a count, "all" to fire every
	missed repeat, "drop" to fire once and skip the rest, or "inherit" to
	follow the scheduler's own setting. One-shots ignore it.
]]
function VeronEvent:SetCatchUp(mode, count)
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_SetCatchUp(self, mode, count)
end

--[[
	Seconds until the timer next fires. A finished timer answers 0.
]]
function VeronEvent:GetRemaining()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler:_GetRemaining(self)
end

-------------------------------------------------------------------
-- Queries. These read the handle's own fields and leave the scheduler
-- alone.
-------------------------------------------------------------------

--[[
	The period the timer was set up with, in seconds.
]]
function VeronEvent:GetPeriod()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Period
end

--[[
	True while the timer is paused. It also reads true in one in-between
	case: a recurring timer that was paused and then force-completed still
	counts as paused until its forced fire parks it again, even though its
	raw state reads Pending for that moment.
]]
function VeronEvent:IsPaused()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	local state = self._State
	if state == PAUSED then
		return true
	end
	return state == PENDING and self._Flags >= REPAUSE
end

--[[
	The current state as a word: "Pending", "Paused", "Chained", "Fired"
	or "Stopped".
]]
function VeronEvent:GetState()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return STATE_NAMES[self._State]
end

--[[
	The current state as its number, 1 through 5, matching the words
	above.
]]
function VeronEvent:GetStateId()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._State
end

--[[
	True while the timer can still fire, which covers Pending, Paused and
	Chained. It turns false once the timer has fired or been stopped.
]]
function VeronEvent:IsActive()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._State <= CHAINED
end

--[[
	True for a repeating timer, false for a one-shot.
]]
function VeronEvent:IsRecurring()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._IsRecur
end

--[[
	The number the scheduler stamped on this timer when it was armed.
]]
function VeronEvent:GetId()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self.Id
end

--[[
	The Veron that owns this handle.
]]
function VeronEvent:GetScheduler()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	return self._Scheduler
end

--[[
	A short line for logs and debugging, such as
	`VeronEvent<Tick#42 recur 0.5s Pending>`. A recurring timer set to
	stop or re-pause after its next fire shows `+stop` or `+repause`
	after the state.
]]
function VeronEvent:Describe()
	if getmetatable(self) ~= eventDict then
		error(COLON_MESSAGE, 2)
	end
	local flags = self._Flags
	local suffix = ""
	if flags >= REPAUSE then
		suffix = "+repause"
	elseif flags % 8 >= 4 then
		suffix = "+stop"
	end
	return ("VeronEvent<%s#%d %s %gs %s%s>"):format(
		self._Scheduler.Name,
		self.Id,
		if self._IsRecur then "recur" else "delay",
		self._Period,
		STATE_NAMES[self._State],
		suffix
	)
end

-------------------------------------------------------------------
-- Lowercase aliases. Some call sites spell these methods in lowercase,
-- so each name points at the same function as its PascalCase version.
-- Destroy is another name for Stop.
-------------------------------------------------------------------

VeronEvent.stop = VeronEvent.Stop
VeronEvent.reset = VeronEvent.Reset
VeronEvent.adjust = VeronEvent.Adjust
VeronEvent.after = VeronEvent.After
VeronEvent.Destroy = VeronEvent.Stop

return VeronEvent
