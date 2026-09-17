import re, os, collections, io
H = r"C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp"
S = r"C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickRevamp/research/scratch/callsites"
out = io.StringIO()
def P(*a): print(*a, file=out)
def short(p):
    p = re.sub(r"_\[[A-Za-z]+\]", "", p)
    for a, b in [("ReplicatedStorage/SharedModules/", "RS/SM/"), ("ReplicatedFirst/LocalOnly/", "RF/LO/"), ("ServerScriptService/", "SSS/"), ("ServerStorage/", "SS/"), ("StarterGui/", "SG/"), ("StarterPlayer/StarterPlayerScripts/", "SP/SPS/"), ("ReplicatedStorage/", "RS/"), ("ReplicatedFirst/", "RF/")]:
        p = p.replace(a, b)
    return p

recs = []
with open(os.path.join(S, "all_lines.txt"), encoding="utf-8", errors="replace") as f:
    for ln in f:
        m = re.match(r"^\.?[\\/]?(.*?\.luau):(\d+):(.*)$", ln.rstrip("\n"))
        if m: recs.append((m.group(1).replace("\\", "/"), int(m.group(2)), m.group(3)))
LIB_RE = re.compile(r"(TickAPI_\[Module\]/(TickAPI|Tick|Tick2|Tick3|AfterNotTouchedClass)_\[Module\]\.luau$|StrikeTickAPI_\[Module\]/(StrikeTickAPI|Tick)_\[Module\]\.luau$|SyncedTimerClass_\[Module\]\.luau$)")
def is_lib(p): return bool(LIB_RE.search(p))
def tier(p):
    if re.search(r"ARCHIVE|DEVELOPER_\[Folder\]|ARCHIVES_", p): return "archive"
    if p.startswith("ServerStorage/RoBase_") or p.startswith("ServerStorage/Custom_Plugin_Service"): return "plugin"
    return "live"
tick_files = sorted({p for p, l, t in recs if re.search(r"TickAPI|StrikeTickAPI|TimeManagerAPI", t)})
srcs = {p: open(os.path.join(H, p), encoding="utf-8", errors="replace").read() for p in tick_files}
def is_comment(line): return line.strip().startswith("--")

P("## T. Counts by tier (live game / RoBase+plugin / archive), caller files only, commented-out lines excluded")
P("| shape | live | plugin | archive | total | live files |\n|---|---|---|---|---|---|")
shapes = [
 ("TickAPI.Tick.delay(", r"(?<!Strike)TickAPI\.Tick\.delay\("), ("TickAPI.Tick.recur(", r"(?<!Strike)TickAPI\.Tick\.recur\("),
 ("TickAPI.Tickh.delay(", r"TickAPI\.Tickh\.delay\("), ("TickAPI.Tickh.recur(", r"TickAPI\.Tickh\.recur\("),
 ("TickAPI.Tickr.delay(", r"TickAPI\.Tickr\.delay\("), ("TickAPI.Tickr.recur(", r"TickAPI\.Tickr\.recur\("),
 ("TickAPI.Tick:remove( (colon misuse)", r"TickAPI\.Tick:remove\("),
 ("TickAPI.SafeStopClock(", r"(?<!Manager)(?<!Strike)TickAPI\.SafeStopClock\("), ("TimeManagerAPI.SafeStopClock(", r"TimeManagerAPI\.SafeStopClock\("),
 ("TickAPI.GetAfterNotTouched(", r"TickAPI\.GetAfterNotTouched\("),
 ("StrikeTickAPI.Tick.delay(", r"StrikeTickAPI\.Tick\.delay\("),
 ("TimeManagerAPI.Tick.delay( (FxPackageLite/plugin)", r"TimeManagerAPI\.Tick\.delay\("), ("TimeManagerAPI.Tick.recur(", r"TimeManagerAPI\.Tick\.recur\("),
 ("TimeManagerAPI.Tickh.delay( (FxPackage alias)", r"TimeManagerAPI\.Tickh\.delay\("), ("TimeManagerAPI.Tickh.recur(", r"TimeManagerAPI\.Tickh\.recur\("),
]
commented = collections.Counter()
for name, pat in shapes:
    rx = re.compile(pat); c = collections.Counter(); files = set()
    for p in tick_files:
        if is_lib(p): continue
        for i, ln in enumerate(srcs[p].split("\n"), 1):
            k = len(rx.findall(ln))
            if not k: continue
            if is_comment(ln): commented[name] += k; continue
            c[tier(p)] += k
            if tier(p) == "live": files.add(p)
    P(f"| {name} | {c['live']} | {c['plugin']} | {c['archive']} | {sum(c.values())} | {len(files)} |")
P("commented-out occurrences excluded:", dict(commented))

# ---------- handle names ----------
P("\n## U. Handle-name analysis (names assigned from a Tick delay/recur/after/GetAfterNotTouched call)")
ASSIGN = re.compile(r"(?m)^\s*(?:local\s+)?([A-Za-z_][\w\.]*(?:\[[^\]]+\])?)\s*=\s*(?:TickAPI|StrikeTickAPI|TimeManagerAPI)\.(?:Tick|Tickh|Tickr)\.(delay|recur)\s*\(")
ASSIGN_ANT = re.compile(r"(?m)^\s*(?:local\s+)?([A-Za-z_][\w\.]*)\s*=\s*TickAPI\.GetAfterNotTouched\(")
CALL_UNASSIGNED = re.compile(r"(?m)^\s*(?:TickAPI|StrikeTickAPI|TimeManagerAPI)\.(?:Tick|Tickh|Tickr)\.(delay|recur)\s*\(")
handles = {}  # (file, name) -> kind
n_assigned = 0; n_unassigned = 0; n_unassigned_recur = 0; unassigned_recur_ex = []
for p in tick_files:
    if is_lib(p): continue
    src = srcs[p]
    for m in ASSIGN.finditer(src):
        if is_comment(src[src.rfind("\n", 0, m.start())+1:m.end()]): continue
        handles[(p, m.group(1))] = m.group(2); n_assigned += 1
    for m in CALL_UNASSIGNED.finditer(src):
        line = src[src.rfind("\n", 0, m.start())+1:m.end()]
        if is_comment(line): continue
        n_unassigned += 1
        if m.group(1) == "recur":
            n_unassigned_recur += 1
            if len(unassigned_recur_ex) < 12: unassigned_recur_ex.append(f"{short(p)}:{src.count(chr(10), 0, m.start())+1}")
P(f"assigned handles (distinct file+name): {len(handles)}; assignment sites: {n_assigned}; fire-and-forget calls (result discarded, statement-level): {n_unassigned}, of which recur (unstoppable forever-timers): {n_unassigned_recur}")
P("   unstoppable recur examples:", unassigned_recur_ex)
# usage of each handle name
use = collections.Counter(); ex = collections.defaultdict(list)
per_tier = collections.defaultdict(collections.Counter)
for (p, name), kind in handles.items():
    src = srcs[p]; nm = re.escape(name)
    checks = {
        ":stop()": nm + r"\s*:stop\(\)", ":reset()": nm + r"\s*:reset\(\)", ":after(": nm + r"\s*:after\(", ":adjust(": nm + r"\s*:adjust\(",
        "SafeStopClock(name)": r"SafeStopClock\(\s*" + nm + r"\s*\)", "name = SafeStopClock(name)": nm + r"\s*=\s*\w+\.SafeStopClock\(\s*" + nm,
        "name = nil": nm + r"\s*=\s*nil\b", "~= nil / == nil check": nm + r"\s*(~=|==)\s*nil", "if name then": r"if\s+(not\s+)?" + nm + r"\s*then",
        "[name] as key": r"\[\s*" + nm + r"\s*\]", "name == x (non-nil)": nm + r"\s*(==|~=)\s*(?!nil)\S",
        ".timer field": nm + r"\.timer\b", ".delay field": nm + r"\.delay\b", ".fn field": nm + r"\.fn\b", ".recur field": nm + r"\.recur\b", ".parent field": nm + r"\.parent\b",
        ".class/.type/.name": nm + r"\.(class|type|name)\b", "type(name)": r"type\(\s*" + nm + r"\s*\)", "table.insert(_, name)": r"table\.insert\([^,]+,\s*" + nm + r"\s*\)",
        "passed as arg / stored elsewhere": r"[,(]\s*" + nm + r"\s*[,)]",
        ":Touch() (AfterNotTouched)": nm + r"\s*:Touch\(\)", ":Destroy() on handle": nm + r"\s*:Destroy\(\)",
    }
    for k, rx in checks.items():
        n = len(re.findall(rx, src))
        # exclude commented lines
        n = sum(1 for mm in re.finditer(rx, src) if not is_comment(src[src.rfind("\n", 0, mm.start())+1: mm.end()]))
        if n:
            use[k] += n; per_tier[k][tier(p)] += n
            if len(ex[k]) < 5:
                mm = next(mm for mm in re.finditer(rx, src) if not is_comment(src[src.rfind("\n", 0, mm.start())+1: mm.end()]))
                ex[k].append(f"{short(p)}:{src.count(chr(10), 0, mm.start())+1} [{kind}] {name}")
P("| usage on a Tick handle | count | live/plugin/archive | examples |\n|---|---|---|---|")
for k in ["stop()", ":stop()", ":reset()", ":after(", ":adjust(", "SafeStopClock(name)", "name = SafeStopClock(name)", "name = nil", "~= nil / == nil check", "if name then", "[name] as key", "name == x (non-nil)", ".timer field", ".delay field", ".fn field", ".recur field", ".parent field", ".class/.type/.name", "type(name)", "table.insert(_, name)", "passed as arg / stored elsewhere", ":Touch() (AfterNotTouched)", ":Destroy() on handle"]:
    if k in use: P(f"| {k} | {use[k]} | {per_tier[k]['live']}/{per_tier[k]['plugin']}/{per_tier[k]['archive']} | " + "<br>".join(ex[k]) + " |")
P("recur handles that receive :reset():")
for (p, name), kind in handles.items():
    if kind == "recur" and re.search(re.escape(name) + r"\s*:reset\(\)", srcs[p]): P("   ", short(p), name)
P("recur handles that receive :after( or :adjust(:")
for (p, name), kind in handles.items():
    if kind == "recur" and re.search(re.escape(name) + r"\s*:(after|adjust)\(", srcs[p]): P("   ", short(p), name)

# ---------- whole-mirror lowercase handle-method counts (to reconcile ASSESSMENT) ----------
P("\n## V. Whole-mirror counts of lowercase handle-method tokens (all *.luau, any receiver) — for reconciling ASSESSMENT.md")
for name, pat in [(":stop(", r":stop\("), (":reset(", r":reset\("), (":after(", r":after\("), (":adjust(", r":adjust\(")]:
    rx = re.compile(pat); tot = 0; files = set(); recv = collections.Counter(); intick = 0
    for p, l, t in recs:
        for m in re.finditer(r"([A-Za-z_][\w\.\[\]]*)\s*" + pat, t):
            tot += 1; files.add(p); recv[m.group(1)] += 1
            if p in srcs: intick += 1
    P(f"{name}: total={tot} files={len(files)} in-tick-caller-files={intick}; top receivers: {recv.most_common(12)}")

# ---------- fixed generic field scan ----------
P("\n## W. Generic field tokens .timer/.fn/.parent/.err and .recur-not-call in tick-caller files (non-library, non-comment)")
gen = re.compile(r"\.(timer|fn|parent|err)\b|\.recur\b(?!\s*\()")
for p in tick_files:
    if is_lib(p): continue
    for i, ln in enumerate(srcs[p].split("\n"), 1):
        if gen.search(ln) and not is_comment(ln): P(f"   {short(p)}:{i}: {ln.strip()[:150]}")

# ---------- SafeStopClock enclosing function names ----------
P("\n## X. SafeStopClock enclosing function names (callers, non-comment)")
fnames = collections.Counter(); fn_ex = collections.defaultdict(list)
for p in tick_files:
    if is_lib(p): continue
    cur = "<top>"
    for i, ln in enumerate(srcs[p].split("\n"), 1):
        m = re.search(r"^\s*(?:local\s+)?function\s+([\w\.:]+)\s*\(", ln)
        if m: cur = m.group(1)
        elif re.search(r"^\s*(?:local\s+)?[\w\.:]+\s*=\s*function\s*\(", ln): cur = re.search(r"([\w\.:]+)\s*=\s*function", ln).group(1)
        if "SafeStopClock(" in ln and not is_comment(ln):
            key = cur.split(":")[-1].split(".")[-1]
            fnames[key] += 1
            if len(fn_ex[key]) < 2: fn_ex[key].append(f"{short(p)}:{i}")
P("by enclosing function (leaf name):", fnames.most_common(60))
destroy_like = sum(v for k, v in fnames.items() if re.search(r"Destroy|Destruct|Cleanup|CleanUp|Clean|Dispose|Remove|Release|Kill|Stop|Cancel|Clear|Reset|onRelease|Unload|Close|Hide|Exit|Leave|Disconnect", k))
P("SafeStopClock inside destroy/cleanup/stop/reset-like functions:", destroy_like, "of", sum(fnames.values()))

# ---------- FPS & tiny delays ----------
P("\n## Y. Identifier delays that are frame-rate-ish constants (FPS etc.)")
for p in tick_files:
    if is_lib(p): continue
    for i, ln in enumerate(srcs[p].split("\n"), 1):
        if re.search(r"^\s*local\s+FPS\s*=|^\s*FPS\s*=", ln): P(f"   {short(p)}:{i}: {ln.strip()[:120]}")

# ---------- nested-scanner sanity test ----------
P("\n## Z. Nesting scanner sanity test on synthetic snippet")
import importlib.util, sys
snippet = '''
local a = TickAPI.Tickh.delay(function()
    local b = TickAPI.Tick.delay(function()
        TickAPI.Tickr.recur(function() end, 0.1)
    end, 2)
end, 1)
TickAPI.Tickh.delay(self.Fn, 3)
local c = TickAPI.Tick.delay(function() end, 1):after(function() end, 2):after(function() end, 3)
'''
# reuse scanner by exec of survey.py section is heavy; re-implement minimal depth check via indentation is not equivalent, so just report that survey.py section E ran with its own logic.
P("(see survey.py section E; synthetic test executed in survey_nesttest.py)")

with open(os.path.join(S, "survey2_out.md"), "w", encoding="utf-8") as f: f.write(out.getvalue())
print(out.getvalue())
