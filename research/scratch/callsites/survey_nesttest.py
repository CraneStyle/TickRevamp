# Runs survey.py's section-E scanner logic on a synthetic file to prove it detects nesting and chains.
import re, os, sys, types
S = r"C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickRevamp/research/scratch/callsites"
src = open(os.path.join(S, "survey.py"), encoding="utf-8").read()
# extract strip_lua + scanner block and run it against a fake srcs/tick_files
start = src.index("def strip_lua(txt):"); end = src.index('P("tick delay/recur calls by nesting depth')
code = src[start:end]
snippet = '''
local a = TickAPI.Tickh.delay(function()
    local b = TickAPI.Tick.delay(function()
        TickAPI.Tickr.recur(function() end, 0.1)
    end, 2)
    if x then
        for i = 1, 3 do
            TickAPI.Tick.delay(function() end, i)
        end
    end
end, 1)
TickAPI.Tickh.delay(self.Fn, 3)
local c = TickAPI.Tick.delay(function() end, 1):after(function() end, 2):after(function() end, 3)
local d = TickAPI.Tick.delay(function() end, "5")
local e = TickAPI.Tick.recur(function() end, 0)
'''
g = {"re": re, "collections": __import__("collections"), "P": print, "srcs": {"x.luau": snippet}, "tick_files": ["x.luau"], "is_lib": lambda p: False}
exec(code, g)
print("depth_hist:", dict(g["depth_hist"]))
print("nested_examples:", g["nested_examples"])
print("chain_hist:", dict(g["chain_hist"]), "max:", g["chain_max"])
print("delay_args:", dict(g["delay_args"]))
for k, v in g["delay_examples"].items(): print("  ", k, v)
