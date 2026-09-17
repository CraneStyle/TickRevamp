import re, os, sys, collections, io
H = r"C:/Users/Faded/Documents/GitHub/HeroicSouls-BackUp"
S = r"C:/Users/Faded/Documents/ClaudeProjects/RbxProjects/STUDIO_TASKS/TickRevamp/research/scratch/callsites"
out = io.StringIO()
def P(*a): print(*a, file=out)

# ---------- load line dump ----------
recs = []
with open(os.path.join(S, "all_lines.txt"), encoding="utf-8", errors="replace") as f:
    for ln in f:
        ln = ln.rstrip("\n")
        m = re.match(r"^\.?[\\/]?(.*?\.luau):(\d+):(.*)$", ln)
        if not m: continue
        path = m.group(1).replace("\\", "/")
        recs.append((path, int(m.group(2)), m.group(3)))
P("records:", len(recs))

LIB_RE = re.compile(r"(TickAPI_\[Module\]/(TickAPI|Tick|Tick2|Tick3|AfterNotTouchedClass)_\[Module\]\.luau$|StrikeTickAPI_\[Module\]/(StrikeTickAPI|Tick)_\[Module\]\.luau$|SyncedTimerClass_\[Module\]\.luau$)")
def is_lib(p): return bool(LIB_RE.search(p))

def survey(name, pat, only_callers=True, exclude=None, n_ex=3, show=None):
    rx = re.compile(pat); exr = re.compile(exclude) if exclude else None
    tot = 0; files = collections.OrderedDict(); ex = []
    for p, l, t in recs:
        if only_callers and is_lib(p): continue
        if exr and exr.search(t): continue
        k = len(rx.findall(t))
        if k:
            tot += k; files[p] = files.get(p, 0) + k
            if len(ex) < n_ex: ex.append(f"{p}:{l}")
    P(f"| {name} | {tot} | {len(files)} | " + "<br>".join(ex) + " |")
    if show:
        for p, l, t in recs:
            if only_callers and is_lib(p): continue
            if exr and exr.search(t): continue
            if rx.search(t): P(f"    {p}:{l}: {t.strip()[:170]}")
    return tot, files

P("\n## A. Call shapes (callers only = excluding the library/wrapper module files themselves)")
P("| shape | matches | files | examples |\n|---|---|---|---|")
for k in ["Tick", "Tickh", "Tickr"]:
    survey(f"TickAPI.{k}.delay(", rf"TickAPI\.{k}\.delay\(")
    survey(f"TickAPI.{k}.recur(", rf"TickAPI\.{k}\.recur\(")
    survey(f"TickAPI.{k}.remove(", rf"TickAPI\.{k}\.remove\(", show=True)
    survey(f"TickAPI.{k}.update(", rf"TickAPI\.{k}\.update\(", only_callers=False, show=True)
    survey(f"TickAPI.{k}.getClocks", rf"TickAPI\.{k}\.getClocks", show=True)
    survey(f"TickAPI.{k}.event(", rf"TickAPI\.{k}\.event\(", show=True)
    survey(f"TickAPI.{k}:<colon call>", rf"TickAPI\.{k}:[A-Za-z_]+", show=True)
    survey(f"TickAPI.{k} bare (alias/pass)", rf"TickAPI\.{k}\b(?![.:\w])", show=True)
survey("TickAPI[<dynamic>]", r"TickAPI\[", only_callers=False, show=True)
survey("TickAPI.SafeStopClock(", r"TickAPI\.SafeStopClock\(")
survey("SafeStopClock( (any prefix)", r"SafeStopClock\(", only_callers=False)
survey("GetAfterNotTouched(", r"GetAfterNotTouched\(", show=True)
survey("TickAPI.<other member>", r"TickAPI\.(?!Tick\b|Tickh\b|Tickr\b|SafeStopClock\b|GetAfterNotTouched\b|_VERSION)[A-Za-z_]+", show=True)
survey("StrikeTickAPI.Tick.delay(", r"StrikeTickAPI\.Tick\.delay\(", show=True)
survey("StrikeTickAPI.Tick.<other>", r"StrikeTickAPI\.Tick\.(?!delay\b)[A-Za-z_]+", only_callers=False, show=True)
survey("TimeManagerAPI.<x> (FxPackageLite alias)", r"TimeManagerAPI\.[A-Za-z_.]+", show=True)
survey("getClocks (anywhere)", r"getClocks", only_callers=False, show=True)
survey(".group( (anywhere)", r"\.group\(", only_callers=False, show=True)
survey(":event( (anywhere)", r":event\(", only_callers=False, show=True)
survey(":setClock(", r":setClock\(", only_callers=False, show=True)

# ---------- caller file set ----------
caller_files = sorted({p for p, l, t in recs if re.search(r"TickAPI|StrikeTickAPI|TimeManagerAPI|SyncedTime", t)})
P("\n## B. Caller file set:", len(caller_files), "files mention TickAPI/StrikeTickAPI/TimeManagerAPI/SyncedTime")
tick_files = sorted({p for p, l, t in recs if re.search(r"TickAPI|StrikeTickAPI|TimeManagerAPI", t)})
P("files mentioning TickAPI/StrikeTickAPI/TimeManagerAPI:", len(tick_files))

def side(p):
    root = p.split("/")[0]
    if p.endswith(".client.luau"): kind = "LocalScript"
    elif p.endswith(".server.luau"): kind = "Script"
    else: kind = "ModuleScript"
    if root in ("ReplicatedFirst", "StarterGui", "StarterPlayer"): s = "client"
    elif root in ("ServerScriptService", "ServerStorage"): s = "server"
    elif root == "ReplicatedStorage": s = "shared"
    else: s = root
    return s, kind
cnt = collections.Counter(); kinds = collections.Counter()
for p in tick_files:
    s, k = side(p); cnt[s] += 1; kinds[(s, k)] += 1
P("by side:", dict(cnt)); P("by side+kind:", dict(kinds))
P("Tickr users by side:")
tickr_files = sorted({p for p, l, t in recs if "TickAPI.Tickr" in t and not is_lib(p)})
for p in tickr_files: P("   ", side(p), p)
P("Tick (Stepped) users on ServerStorage/RoBase (plugin) vs game:")
robase = [p for p in tick_files if p.startswith("ServerStorage/RoBase_")]
P("   RoBase plugin files mentioning TickAPI:", len(robase))
P("   ARCHIVE/dev-only files:", len([p for p in tick_files if "ARCHIVE" in p or "DEVELOPER_" in p]))

# ---------- concatenated dump ----------
dump = os.path.join(S, "tickfiles_dump.txt")
srcs = {}
with open(dump, "w", encoding="utf-8") as d:
    for p in caller_files:
        fp = os.path.join(H, p)
        try:
            txt = open(fp, encoding="utf-8", errors="replace").read()
        except Exception as e:
            P("!! cannot read", p, e); continue
        srcs[p] = txt
        for i, ln in enumerate(txt.split("\n"), 1):
            d.write(f"{p}:{i}:{ln}\n")
P("dump written:", dump, "files:", len(srcs))

# ---------- handle methods (lowercase rxi-style) within tick caller files ----------
P("\n## C. Handle methods in tick-caller files (lowercase, rxi-style; receivers tabulated)")
def recv_table(pat):
    rx = re.compile(r"([A-Za-z_][\w\.\[\]\"']*)\s*" + pat)
    tot = 0; files = set(); recv = collections.Counter(); ex = []
    for p in tick_files:
        for i, ln in enumerate(srcs.get(p, "").split("\n"), 1):
            for m in rx.finditer(ln):
                tot += 1; files.add(p); recv[m.group(1)] += 1
                if len(ex) < 4: ex.append(f"{p}:{i}")
    return tot, files, recv, ex
for name, pat in [(":stop()", r":stop\(\)"), (":reset()", r":reset\(\)"), (":after(", r":after\("), (":adjust(", r":adjust\("), (":setClock(", r":setClock\("), (":remove(", r":remove\("), (":stop( with args", r":stop\([^)]")]:
    tot, files, recv, ex = recv_table(pat)
    P(f"\n### {name}: matches={tot} files={len(files)}  examples: {'; '.join(ex)}")
    P("   receivers:", recv.most_common(40))

# ---------- direct field access on handles ----------
P("\n## D. Direct field access on handles / handles as keys / .type/.class")
fld = re.compile(r"(?<![\w.])((?:self\.)?[A-Za-z_]\w*(?:[Cc]lock|[Tt]imer|Clk|Handle)\w*)\.(timer|delay|fn|recur|parent|type|class|name|Id|err)\b")
for p in tick_files:
    for i, ln in enumerate(srcs.get(p, "").split("\n"), 1):
        if is_lib(p): continue
        for m in fld.finditer(ln):
            if "SyncedTimer" in m.group(1) or "TimeManagerAPI" in m.group(1): continue
            P(f"   FIELD {p}:{i}: {ln.strip()[:160]}")
P("-- generic .timer/.recur/.fn/.parent/.err field tokens in tick-caller files (any receiver, excluding library):")
gen = re.compile(r"\.(timer|recur|fn|parent|err)\b")
for p in tick_files:
    for i, ln in enumerate(srcs.get(p, "").split("\n"), 1):
        if is_lib(p): continue
        if gen.search(ln) and not ln.strip().startswith("--"): P(f"   GEN {p}:{i}: {ln.strip()[:160]}")
key = re.compile(r"\[\s*[A-Za-z_][\w\.]*(?:[Cc]lock|[Tt]imer)\w*\s*\]\s*=|\[\s*self\.\w*[Cc]lock\w*\s*\]")
for p in tick_files:
    for i, ln in enumerate(srcs.get(p, "").split("\n"), 1):
        if is_lib(p): continue
        if key.search(ln): P(f"   KEY {p}:{i}: {ln.strip()[:160]}")
cmp = re.compile(r"(\w*[Cc]lock\w*)\s*(==|~=)\s*(?!\s*nil)")
for p in tick_files:
    for i, ln in enumerate(srcs.get(p, "").split("\n"), 1):
        if is_lib(p): continue
        if cmp.search(ln) and "SyncedTimer" not in ln: P(f"   CMP {p}:{i}: {ln.strip()[:160]}")

# ---------- Luau-aware scanner: nesting depth, after-chains, delay args ----------
P("\n## E. Nesting / after-chain / delay-argument scan")
TICKCALL = re.compile(r"(?:TickAPI\.(Tick|Tickh|Tickr)|StrikeTickAPI\.(Tick)|TimeManagerAPI\.(Tick))\.(delay|recur)\s*\(")
def strip_lua(txt):
    # replace comments and strings with spaces (keep newlines); mark strings as STR
    res = []; i = 0; n = len(txt)
    while i < n:
        c = txt[i]
        if txt.startswith("--", i):
            m = re.match(r"--\[(=*)\[", txt[i:])
            if m:
                close = "]" + m.group(1) + "]"; j = txt.find(close, i)
                j = n if j < 0 else j + len(close)
            else:
                j = txt.find("\n", i); j = n if j < 0 else j
            res.append(re.sub(r"[^\n]", " ", txt[i:j])); i = j; continue
        if c in "\"'":
            j = i + 1
            while j < n and txt[j] != c:
                if txt[j] == "\\": j += 1
                if txt[j] == "\n": break
                j += 1
            res.append(" STR "); i = j + 1; continue
        m = re.match(r"\[(=*)\[", txt[i:])
        if m:
            close = "]" + m.group(1) + "]"; j = txt.find(close, i); j = n if j < 0 else j + len(close)
            res.append(" STR " + re.sub(r"[^\n]", " ", txt[i:j])); i = j; continue
        res.append(c); i += 1
    return "".join(res)

TOK = re.compile(r"[A-Za-z_][\w]*|\d+\.?\d*|\.\.\.|[()\[\]{}.:,=<>~+\-*/%^#]|\n")
OPEN = {"function", "if", "for", "while", "do", "repeat"}
depth_hist = collections.Counter(); nested_examples = []; chain_max = (0, None); chain_hist = collections.Counter()
delay_args = collections.Counter(); delay_examples = collections.defaultdict(list)
inside_callback_creates = 0
for p in tick_files:
    if is_lib(p): continue
    txt = strip_lua(srcs.get(p, ""))
    toks = list(TOK.finditer(txt)); line = 1
    stack = []   # entries: dict(kind, tick(bool), paren)
    paren = 0
    pending = None  # tick call awaiting its callback function: dict(paren, line, kind)
    open_calls = []  # tick calls whose arg-list is open: (paren_depth_at_open, start_idx, line)
    last_pop_chain = None  # (paren depth, position) after closing a tick callback
    i = 0
    tstrs = [m.group(0) for m in toks]
    while i < len(toks):
        t = tstrs[i]
        if t == "\n": line += 1; i += 1; continue
        # detect tick call: pattern ident . (Tick|Tickh|Tickr) . (delay|recur) (
        if t in ("delay", "recur") and i >= 4 and tstrs[i-1] == "." and tstrs[i-2] in ("Tick", "Tickh", "Tickr") and tstrs[i-3] == "." and tstrs[i-4] in ("TickAPI", "StrikeTickAPI", "TimeManagerAPI") and i + 1 < len(toks) and tstrs[i+1] == "(":
            d = sum(1 for s in stack if s["tick"])
            depth_hist[d] += 1
            if d >= 1:
                inside_callback_creates += 1
                if len(nested_examples) < 40: nested_examples.append((d, f"{p}:{line}", tstrs[i-2] + "." + t))
            pending = {"paren": paren, "line": line, "kind": t, "chain": 0}
            open_calls.append({"paren": paren, "line": line, "kind": t, "start": i, "argstart": None, "fnclosed": False})
            i += 2; paren += 1
            open_calls[-1]["inner"] = paren
            continue
        if t == ":" and i + 2 < len(toks) and tstrs[i+1] == "after" and tstrs[i+2] == "(":
            # chained after
            chain = 1
            if last_pop_chain is not None and last_pop_chain[0] == paren: chain = last_pop_chain[1] + 1
            chain_hist[chain] += 1
            if chain > chain_max[0]: chain_max = (chain, f"{p}:{line}")
            pending = {"paren": paren, "line": line, "kind": "after", "chain": chain}
            open_calls.append({"paren": paren, "line": line, "kind": "after", "start": i, "inner": paren + 1, "chain": chain})
            i += 3; paren += 1; continue
        if t == "(": paren += 1; i += 1; continue
        if t == ")":
            paren -= 1
            # closing a tick call arg list?
            if open_calls and open_calls[-1]["inner"] == paren + 1:
                oc = open_calls.pop()
                # capture delay-arg text: from after the callback 'end' (or from comma) to here
                seg = txt[toks[oc["start"]].start():toks[i].end()]
                # arg after the last top-level comma
                # crude: take text after last "end" if present else after first comma
                m = re.search(r"\bend\s*,\s*(.*)\)\s*$", seg, re.S)
                if not m: m = re.search(r"\(\s*[^,]*,\s*(.*)\)\s*$", seg, re.S)
                arg = (m.group(1).strip() if m else "?")
                arg1 = re.sub(r"\s+", " ", arg)[:60]
                if re.fullmatch(r"\d+\.?\d*", arg1):
                    v = float(arg1); cat = "num:0" if v == 0 else ("num:<0.05" if v < 0.05 else ("num:<0.5" if v < 0.5 else "num:>=0.5"))
                elif arg1 == "STR": cat = "string-literal"
                elif arg1 == "nil": cat = "nil"
                elif arg1 == "?": cat = "unparsed"
                elif re.fullmatch(r"[\w\.\[\]]+", arg1): cat = "identifier/field"
                else: cat = "expression"
                if oc["kind"] != "after": delay_args[cat] += 1
                if len(delay_examples[cat]) < 6: delay_examples[cat].append(f"{p}:{oc['line']} -> {arg1}")
                if oc["kind"] in ("delay", "recur", "after"):
                    last_pop_chain = (paren, oc.get("chain", 0)) if oc["kind"] == "after" else (paren, 0)
                pending = None
            i += 1; continue
        if t in OPEN:
            if t == "function":
                is_cb = pending is not None and pending["paren"] < paren
                stack.append({"kind": "function", "tick": is_cb}); pending = None
            elif t == "do" and i >= 1 and stack and stack[-1]["kind"] in ("for-hdr", "while-hdr"):
                stack[-1]["kind"] = stack[-1]["kind"][:-4]
            elif t == "do":
                stack.append({"kind": "do", "tick": False})
            elif t == "if":
                stack.append({"kind": "if", "tick": False})
            elif t == "for":
                stack.append({"kind": "for-hdr", "tick": False})
            elif t == "while":
                stack.append({"kind": "while-hdr", "tick": False})
            elif t == "repeat":
                stack.append({"kind": "repeat", "tick": False})
            i += 1; continue
        if t == "elseif":
            i += 1; continue
        if t == "end":
            if stack: stack.pop()
            i += 1; continue
        if t == "until":
            if stack and stack[-1]["kind"] == "repeat": stack.pop()
            i += 1; continue
        i += 1
P("tick delay/recur calls by nesting depth (0 = top level, n = created inside n enclosing tick callbacks):", dict(sorted(depth_hist.items())))
P("calls made inside a tick callback:", inside_callback_creates)
for d, loc, k in nested_examples: P(f"   depth={d} {loc} ({k})")
P("after-chain length histogram (1 = single :after):", dict(sorted(chain_hist.items())), " max:", chain_max)
P("delay/recur argument categories:", dict(delay_args))
for k, v in delay_examples.items():
    P(f"   {k}:"); [P("      ", e) for e in v]

# ---------- adjust / reset context ----------
P("\n## F. adjust / reset / recur-reset context lines")
for p in tick_files:
    if is_lib(p): continue
    lines = srcs.get(p, "").split("\n")
    for i, ln in enumerate(lines, 1):
        if re.search(r":adjust\(", ln): P(f"   ADJUST {p}:{i}: {ln.strip()[:150]}")
P("-- recurring handles that get :reset() (heuristic: same file assigns X = ...recur( and calls X:reset())")
for p in tick_files:
    if is_lib(p): continue
    txt = srcs.get(p, "")
    recur_vars = set(re.findall(r"([\w\.]+)\s*=\s*(?:TickAPI|StrikeTickAPI|TimeManagerAPI)\.Tick[hr]?\.recur\(", txt))
    for v in recur_vars:
        if re.search(re.escape(v) + r"\s*:reset\(\)", txt):
            P(f"   RECUR+RESET {p}: var {v}")
        if re.search(re.escape(v) + r"\s*:adjust\(", txt):
            P(f"   RECUR+ADJUST {p}: var {v}")
        if re.search(re.escape(v) + r"\s*:after\(", txt):
            P(f"   RECUR+AFTER {p}: var {v}")

# ---------- SafeStopClock in Destroy ----------
P("\n## G. SafeStopClock usage context")
n_in_destroy = 0; n_total = 0; n_reassign = 0; n_bare = 0; ex_destroy = []; ex_bare = []
for p in tick_files:
    if is_lib(p): continue
    lines = srcs.get(p, "").split("\n")
    fn_name = None
    for i, ln in enumerate(lines, 1):
        m = re.search(r"function\s+([\w\.:]+)\s*\(", ln)
        if m: fn_name = m.group(1)
        if "SafeStopClock(" in ln:
            n_total += 1
            if re.search(r"=\s*\w+\.SafeStopClock\(", ln): n_reassign += 1
            else:
                n_bare += 1
                if len(ex_bare) < 5: ex_bare.append(f"{p}:{i}: {ln.strip()[:120]}")
            if fn_name and re.search(r"Destroy|Cleanup|CleanUp|Clean|Dispose|Remove|Destruct|Release", fn_name):
                n_in_destroy += 1
                if len(ex_destroy) < 5: ex_destroy.append(f"{p}:{i} in {fn_name}")
P(f"SafeStopClock calls in callers: {n_total}; assigned-back (x = SafeStopClock(x)): {n_reassign}; bare: {n_bare}; inside Destroy/Cleanup-like fn: {n_in_destroy}")
P("   destroy examples:", ex_destroy); P("   bare examples:", ex_bare)

# ---------- SyncedTimer ----------
P("\n## H. SyncedTimer callers")
ST_M = ["AddEvent", "ForceEventComplete", "DeleteEvent", "ResetTimer", "AdjustTime", "GetRemainingTime", "HasObject", "GetWorldTime", "GetItemFromStorage"]
P("| method | matches | files | examples |\n|---|---|---|---|")
for m in ST_M:
    survey(f"SyncedTimer:{m}(", rf"[:.]{m}\(", exclude=r"^\s*function\s|^\s*local function", show=(m != "AddEvent"))
P("-- AddEvent call bodies (line + following 8 lines):")
for p in caller_files:
    if is_lib(p): continue
    lines = srcs.get(p, "").split("\n")
    for i, ln in enumerate(lines):
        if re.search(r"[:.]AddEvent\(", ln) and not re.search(r"function", ln):
            P(f"   {p}:{i+1}")
            for j in range(i, min(i + 9, len(lines))): P("      " + lines[j].rstrip()[:140])

# ---------- other timer-like utilities ----------
P("\n## I. Other timer-like utilities (whole mirror line dump)")
P("| pattern | matches | files |\n|---|---|---|")
for name, pat in [("task.delay(", r"task\.delay\("), ("task.wait(", r"task\.wait\("), ("wait( (legacy global)", r"(?<![.\w])wait\("), ("delay( (legacy global)", r"(?<![.\w:])delay\("), ("Promise.delay", r"Promise\.delay"), ("Promise (any)", r"\bPromise\b"), ("Debounce", r"Debounce"), ("Cooldown/CoolDown", r"Cool[Dd]own"), ("os.clock(", r"os\.clock\("), ("tick()", r"\btick\(\)"), ("Heartbeat:Connect", r"Heartbeat:Connect"), ("Stepped:Connect", r"(?<!Render)Stepped:Connect"), ("RenderStepped:Connect", r"RenderStepped:Connect"), ("BindToRenderStep", r"BindToRenderStep"), ("Timer (word)", r"\bTimer\b"), ("Countdown", r"Countdown"), ("Stopwatch", r"Stopwatch")]:
    survey(name, pat, only_callers=False)
P("-- Heartbeat/Stepped/RenderStepped connections outside the Tick wrappers:")
for p, l, t in recs:
    if re.search(r"(Heartbeat|Stepped|RenderStepped):Connect|BindToRenderStep", t) and not is_lib(p):
        P(f"   {p}:{l}: {t.strip()[:120]}")

with open(os.path.join(S, "survey_out.md"), "w", encoding="utf-8") as f: f.write(out.getvalue())
compact = re.sub(r"_\[[A-Za-z]+\]", "", out.getvalue())
compact = compact.replace("ReplicatedStorage/SharedModules/", "RS/SM/").replace("ReplicatedFirst/LocalOnly/", "RF/LO/").replace("ServerScriptService/", "SSS/").replace("ServerStorage/", "SS/").replace("StarterGui/", "SG/").replace("StarterPlayer/StarterPlayerScripts/", "SP/SPS/").replace("ReplicatedStorage/", "RS/").replace("ReplicatedFirst/", "RF/")
with open(os.path.join(S, "survey_compact.md"), "w", encoding="utf-8") as f: f.write(compact)
print("lines:", compact.count("\n"))
