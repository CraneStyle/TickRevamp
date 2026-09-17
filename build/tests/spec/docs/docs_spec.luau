--!nonstrict
--[[
	docs_spec — WP9 acceptance for build/docs/API.md and build/docs/MIGRATION.md
	(docs/DESIGN.md §9 `docs/docs_spec`, §12 WP9). Test names are the §9 names verbatim.
	The md files are read relative to process.cwd(), which the runner fixes at the
	workspace root (the same convention env_spec uses for build/src/Veron/VeronEvent).
]]

local fs = require("@lune/fs")

local API_PATH = "build/docs/API.md"
local MIGRATION_PATH = "build/docs/MIGRATION.md"

-- §2.1 config keys
local CONFIG_KEYS = {
	"Name", "TimeScale", "MaxCatchUp", "Valve", "MaxDt", "MaxUpdateDepth", "OnError",
	"Strict", "LegacyRecurBase",
}

-- §2.2 Veron members, canonical spellings plus every alias of the closed alias set
local VERON_MEMBERS = {
	"Update", "update", "UpdateTo", "Now", "SetTimeScale", "GetTimeScale", "Pause", "Resume",
	"IsPaused", "Delay", "delay", "Recur", "recur", "DelayAt", "Stop", "Remove", "remove",
	"Complete", "ForceEventComplete", "CompleteNow", "GetRemaining", "GetClocks", "getClocks",
	"GetStats", "Validate", "Describe", "SetOnError", "SetMaxCatchUp", "GetMaxCatchUp",
	"SetValve", "SetMaxDt", "SetStrict", "Clear", "Attach", "Detach", "GetChildren", "Drive",
	"Destroy", "IsDestroyed", "IsUpdating", "GetBase", "Name",
}

-- §2.3 VeronEvent members, canonical spellings plus the LEGACY SURFACE aliases
local HANDLE_MEMBERS = {
	"Stop", "stop", "Destroy", "Reset", "reset", "Adjust", "adjust", "After", "after",
	"SetPeriod", "GetPeriod", "SetRemaining", "GetRemaining", "Pause", "Resume", "IsPaused",
	"Toggle", "Restart", "Complete", "CompleteNow", "SetCatchUp", "GetState", "GetStateId",
	"IsActive", "IsRecurring", "GetId", "GetScheduler", "Describe", "Id",
}

-- §7.3 rows (DV-16/18/19/22 are left with their scope and have no row by design)
local DV_IDS = {
	1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 17, 20, 21, 23, 24,
}

-- §7.4 prior 2.0.0 names
local PRIOR_NAMES = {
	"TickAPI.new", "h:pause()", "h:resume()", "h:getRemaining()", "h:setPeriod()",
	"h:getState()", "h:isActive()", "h:complete()", "h:fireNow()", "group:pause",
	"group:resume", "group:getRemaining", "group:now", "group:setTimeScale",
	"group:getTimeScale", "group:clear", "group:getStats", "maxCatchUpPerFrame", "timeScale",
	"onError", "examined", "stale", "live",
}

-- the same-instance recur+delay files of MIGRATION.md §4 (basenames)
local RECUR_NESTED_FILES = {
	"FxPackage.luau", "EventSpawnerClass.luau", "Spawner.luau", "EntitySurgeConductor.luau",
	"GroupClass.luau", "CharacterSheet.luau", "CharacterSheet_Animation.luau",
	"CharacterSheet_StatAdjustments.luau", "QuestHudManager.luau",
	"SetupCliffAreaScreenSize_AndANIMATION.luau", "AnimatedFlipLoadingWheel.client.luau",
	"InputMouseManager.luau", "AbilityClass_Utility.luau", "HitFlashObject.luau",
	"UI_Initilizer.luau", "AnimatingLoadingWheel.client.luau", "TowerOfTest.luau",
}

--[[
	Plain (non-pattern) containment check with a readable failure message. Both
	sides are whitespace-normalized first (runs of spaces/newlines → one space), so
	a sentence pinned here survives re-wrapping of the markdown but not rewording.
]]
local function _flatten(text)
	return (text:gsub("%s+", " "))
end

local function _contains(text, needle, label)
	if not _flatten(text):find(_flatten(needle), 1, true) then
		error(("%s: missing %q"):format(label or "contains", needle), 2)
	end
end

--[[
	A member name must appear as a whole identifier somewhere in the text, so `Stop`
	is not satisfied by `StopOnFire` alone. `Id` and `Name` are short, hence the
	boundary check instead of plain containment.
]]
local function _containsIdentifier(text, name, label)
	local escaped = name:gsub("%p", "%%%0")
	local pattern = "%f[%w_]" .. escaped .. "%f[^%w_]"

	if not text:find(pattern) then
		error(("%s: member %q not found as an identifier"):format(label or "member", name), 2)
	end
end

--[[
	DV ids need a boundary too: `DV-1` must not be satisfied by `DV-10`.
]]
local function _containsDv(text, id)
	local pattern = "DV%-" .. id .. "%f[^%d]"

	if not text:find(pattern) then
		error(("DV-%d does not appear in MIGRATION.md"):format(id), 2)
	end
end

local function _headingPosition(text, heading)
	local position = text:find(heading, 1, true)

	if not position then
		error(("heading %q not found"):format(heading), 2)
	end

	return position
end

return function(t)
	local api = fs.readFile(API_PATH)
	local migration = fs.readFile(MIGRATION_PATH)

	t.test("every public member of §2 appears in build/docs/API.md", function()
		for _, key in CONFIG_KEYS do
			_containsIdentifier(api, key, "config key")
		end

		for _, name in VERON_MEMBERS do
			_containsIdentifier(api, name, "Veron member")
		end

		for _, name in HANDLE_MEMBERS do
			_containsIdentifier(api, name, "VeronEvent member")
		end

		-- the alias relations themselves, not just the names
		_contains(api, "`Remove`, `remove`", "Stop aliases")
		_contains(api, "`ForceEventComplete` (= `Complete`)", "Complete alias")
		_contains(api, "`stop`, `Destroy`", "handle Stop aliases")
		_contains(api, "Recur's third argument", "Recur third argument section")
		_contains(api, "h:SetCatchUp", "SetCatchUp section")
	end)

	t.test("API.md states the retention rule at the top", function()
		local rulePosition = _headingPosition(api, "## Retention rule")
		local firstMember = _headingPosition(api, "## Veron members")
		local timeModel = _headingPosition(api, "## Time model, in plain language")

		t.eq(rulePosition < timeModel, true, "retention rule precedes the time model")
		t.eq(rulePosition < firstMember, true, "retention rule precedes the member tables")
		t.eq(rulePosition < 1500, true, "retention rule is within the first 1500 bytes")

		_contains(api, "holds every handle strongly until the handle is terminal", "rule sentence")
		_contains(api, "A recurring timer never dies unless it is stopped", "recurring clause")
		_contains(api, "Paused handle is retained until it is resumed or stopped", "paused clause")
		_contains(api, "Chained child (`h:After`) lives as long as its parent", "chained clause")
	end)

	t.test("API.md explains the rolling-clock decision in plain language", function()
		_headingPosition(api, "## Time model, in plain language")
		_contains(api, "keeps a countdown PER timer and subtracts `dt`", "legacy O(n) sentence")
		_contains(api, "A heap needs ONE comparable number per timer", "heap sentence")
		_contains(api, "only the clock advances (`now += dt`)", "rolling clock sentence")
		_contains(api, "that number grows forever, and no, it does not matter", "growth sentence")
		_contains(api, "accurate to a tenth of a microsecond", "precision claim")
		_contains(api, "`Update(dt)` accumulating is the natural fit", "delta fit sentence")
		_contains(api, "`UpdateTo(t)`) is the same loop with the clock SET instead of advanced", "UpdateTo sentence")
		_contains(api, "a handle belongs to exactly one Veron", "one-clock rule")
	end)

	t.test("API.md documents the per-instance footprint", function()
		_headingPosition(api, "### Per-instance footprint")
		_contains(api, "34 dual dot/colon closures under 41 keys", "closure count")
		_contains(api, "~7-9 KB and ~40 GC objects per instance", "size estimate")
		_contains(api, "bench P15", "bench reference")
		_contains(api, "one `Drive`n child per subsystem, never one Veron per entity", "advice")
	end)

	t.test("every DV of §7.3 appears in MIGRATION.md", function()
		for _, id in DV_IDS do
			_containsDv(migration, id)
		end

		t.eq(#DV_IDS, 20, "twenty §7.3 rows")
		_contains(migration, "DV-16, DV-18, DV-19 and DV-22 are not", "scope note for the absent ids")
	end)

	t.test("MIGRATION.md maps every prior 2.0.0 name", function()
		_headingPosition(migration, "Prior build (TickAPIOptimize 2.0.0)")

		for _, name in PRIOR_NAMES do
			_contains(migration, name, "prior name")
		end

		_contains(migration, "`Veron.new(cfg)`", "new constructor")
		_contains(migration, "`h:CompleteNow()`", "fireNow target")
		_contains(migration, "attempt to call a nil value", "lowercase miss note")
	end)

	t.test("MIGRATION.md lists M0–M3 and the out-of-scope items", function()
		for _, step in { "M0", "M1", "M2", "M3" } do
			_contains(migration, "**" .. step .. "**", "migration step")
		end

		local order = _headingPosition(migration, "## 2. Migration order")
		_contains(migration, "| Verify | Rollback |", "verify/rollback columns")
		t.eq(order > 0, true)

		_headingPosition(migration, "## 6. Out of scope")
		_contains(migration, "RoBase plugin", "RoBase")
		_contains(migration, "SyncedTimerClass", "SyncedTimer")
		_contains(migration, "DashStacks:22", "DashStacks")
		_contains(migration, "UpdateAction_ActionServerHitScan:113", "HitScan adjust")
		_contains(migration, "CharacterSheet:772", "CharacterSheet SafeStopClock")
	end)

	t.test("MIGRATION.md lists the recur-nested files and the one-period-earlier warning", function()
		_contains(migration, "one parent-period EARLIER", "warning phrase")
		_contains(migration, "not cumulative drift", "drift clause")
		_contains(migration, "LegacyRecurBase = true", "A/B knob")
		_contains(migration, "research/callsites.md", "survey citation")

		for _, file in RECUR_NESTED_FILES do
			_contains(migration, file, "recur-nested file")
		end

		_contains(migration, "FxPackage.luau` | Tickh:1049", "FxPackage recur line")
		_contains(migration, "EventSpawnerClass.luau` | Tick:406", "EventSpawnerClass recur line")
	end)

	t.test("API.md states the reuse-over-recreate rule with the 576 B / 0 B numbers", function()
		_headingPosition(api, "### Reuse over recreate")
		_contains(api, "576 B", "handle size")
		_contains(api, "0 B", "zero bytes short form")
		_contains(api, "0 bytes", "zero bytes")
		_contains(api, "~250 ns", "push cost")
		_contains(api, "~100–300 ns", "move cost")
		_contains(api, "~5.8 MB/s", "garbage rate")
		_contains(api, "hold the handle and reuse it whenever the same thing repeats", "the rule")
		_contains(api, "recreate only when the owner is gone", "recreate clause")
	end)
end
