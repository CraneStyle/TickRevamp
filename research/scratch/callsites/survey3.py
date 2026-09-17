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
def side(p):
    root = p.split("/")[0]
    if root in ("ReplicatedFirst", "StarterGui", "StarterPlayer"): return "client"
    if root in ("ServerScriptService",): return "server"
    if root == "ServerStorage": return "server"
    if root == "ReplicatedStorage": return "shared"
    return root
tick_files = sorted({p for p, l, t in recs if re.search(r"TickAPI|StrikeTickAPI|TimeManagerAPI", t)})
srcs = {p: open(os.path.join(H, p), encoding="utf-8", errors="replace").read() for p in tick_files}
def is_comment(line): return line.strip().startswith("--")

# ---- require-source classification ----
P("## R. Require source per tick-caller file")
cls = collections.Counter(); nores = []
for p in tick_files:
    if is_lib(p): continue
    src = srcs[p]
    k = []
    if re.search(r"require\(\s*game\.ReplicatedStorage\.SharedModules\.TickAPI\s*\)|require\(\s*(game\.)?ReplicatedStorage\.SharedModules:WaitForChild\(\"TickAPI\"\)|require\(\s*SharedModules(\.TickAPI|:WaitForChild\(\"TickAPI\"\))|require\(\s*ReplicatedStorage\.SharedModules\.TickAPI|WaitForChild\(\"SharedModules\"\):WaitForChild\(\"TickAPI\"\)", src): k.append("main")
    if re.search(r"PluginGuiService\.CoreHolder\.Core\.TickAPI|CoreReference\.TickAPI|CoreHolder\.Core\.TickAPI|require\(\s*Core\.TickAPI", src): k.append("robase")
    if "StrikeManager.StrikeTickAPI" in src: k.append("strike")
    if re.search(r"require\(\s*script\.TickAPI\s*\)", src): k.append("fxlite")
    has_calls = bool(re.search(r"(?m)^(?!\s*--).*\b(TickAPI|StrikeTickAPI|TimeManagerAPI)\.(Tick|Tickh|Tickr|SafeStopClock|GetAfterNotTouched)\b", src))
    key = "+".join(k) if k else ("none(has live calls)" if has_calls else "none(comment/other only)")
    cls[(tier(p), key)] += 1
    if not k and has_calls: nores.append(short(p))
for k, v in sorted(cls.items()): P(f"   {k}: {v}")
P("   files with live TickAPI calls but no recognised require (param/upvalue/other path):")
for p in nores: P("      ", p)
# show how those get TickAPI
for p in tick_files:
    if is_lib(p) or short(p) not in nores: continue
    for i, ln in enumerate(srcs[p].split("\n"), 1):
        if re.search(r"TickAPI\s*=|TickAPI\)", ln) and not is_comment(ln): P(f"         {short(p)}:{i}: {ln.strip()[:130]}"); break

# ---- per-side x wrapper-key counts (live tier, non-comment) ----
P("\n## S. Live-tier calls by side x wrapper key (non-comment)")
c = collections.Counter()
for p in tick_files:
    if is_lib(p) or tier(p) != "live": continue
    for ln in srcs[p].split("\n"):
        if is_comment(ln): continue
        for m in re.finditer(r"\b(TickAPI|StrikeTickAPI|TimeManagerAPI)\.(Tick|Tickh|Tickr)\.(delay|recur)\(", ln):
            c[(side(p), m.group(1) + "." + m.group(2) + "." + m.group(3))] += 1
for k in sorted(c): P(f"   {k[0]:7s} {k[1]:32s} {c[k]}")
P("   server-side files that reference TickAPI.Tickr (would be nil on server):")
for p in tick_files:
    if is_lib(p) or tier(p) != "live": continue
    if side(p) == "server" and re.search(r"(?m)^(?!\s*--).*TickAPI\.Tickr\b", srcs[p]): P("      ", short(p))

# ---- dot-misuse on handles: name.stop() / name.reset() ----
P("\n## M. Dot-call misuse on handles (name.stop() etc.) in tick-caller files")
for p in tick_files:
    if is_lib(p): continue
    for i, ln in enumerate(srcs[p].split("\n"), 1):
        if re.search(r"\w\.(stop|reset|adjust|after)\(\)", ln) and not is_comment(ln) and not re.search(r"tick\.(remove|update|delay|recur)", ln):
            P(f"   {short(p)}:{i}: {ln.strip()[:140]}")

# ---- scanner: self-stop inside own callback, loop-created calls ----
src_py = open(os.path.join(S, "survey.py"), encoding="utf-8").read()
start = src_py.index("def strip_lua(txt):"); end = src_py.index("TOK = re.compile")
exec(src_py[start:end])
TOK = re.compile(r"[A-Za-z_][\w]*|\d+\.?\d*|\.\.\.|[()\[\]{}.:,=<>~+\-*/%^#]|\n")
OPEN = {"function", "if", "for", "while", "do", "repeat"}
self_stop = []; loop_created = []; call_in_each = []
for p in tick_files:
    if is_lib(p): continue
    raw = srcs[p]; txt = strip_lua(raw)
    lines = raw.split("\n")
    toks = list(TOK.finditer(txt)); tstrs = [m.group(0) for m in toks]
    line = 1; stack = []; paren = 0; pending = None; open_calls = []
    i = 0
    while i < len(toks):
        t = tstrs[i]
        if t == "\n": line += 1; i += 1; continue
        if t in ("delay", "recur") and i >= 4 and tstrs[i-1] == "." and tstrs[i-2] in ("Tick", "Tickh", "Tickr") and tstrs[i-3] == "." and tstrs[i-4] in ("TickAPI", "StrikeTickAPI", "TimeManagerAPI") and i + 1 < len(toks) and tstrs[i+1] == "(":
            # LHS name: look back on the same line text
            lt = lines[line-1]
            mm = re.search(r"([A-Za-z_][\w\.]*(?:\[[^\]]+\])?)\s*=\s*(?:TickAPI|StrikeTickAPI|TimeManagerAPI)\.", lt)
            name = mm.group(1) if mm else None
            in_for = any(s["kind"] == "for" for s in stack)
            # Lume.each / ipairs closure: check previous 2 lines for 'each(' or 'ipairs(' or 'pairs('
            prev = "\n".join(lines[max(0, line-3):line])
            if in_for: loop_created.append((short(p), line, t, "for"))
            elif re.search(r"\.each\(|\.map\(|\bipairs\(|\bpairs\(", prev): call_in_each.append((short(p), line, t))
            pending = {"paren": paren, "line": line, "kind": t, "name": name}
            open_calls.append({"inner": paren + 1, "line": line, "kind": t, "name": name, "start_line": line})
            i += 2; paren += 1; continue
        if t == "(": paren += 1; i += 1; continue
        if t == ")":
            paren -= 1
            if open_calls and open_calls[-1]["inner"] == paren + 1:
                oc = open_calls.pop()
                if oc["name"]:
                    body = "\n".join(lines[oc["start_line"]-1: line])
                    nm = re.escape(oc["name"])
                    # exclude the assignment line itself
                    body2 = "\n".join(lines[oc["start_line"]: line])
                    if re.search(r"SafeStopClock\(\s*" + nm + r"\s*\)|" + nm + r"\s*:stop\(\)", body2):
                        self_stop.append((short(p), oc["start_line"], oc["kind"], oc["name"]))
                pending = None
            i += 1; continue
        if t in OPEN:
            if t == "function": stack.append({"kind": "function"}); pending = None
            elif t == "do" and stack and stack[-1]["kind"] in ("for-hdr", "while-hdr"): stack[-1]["kind"] = stack[-1]["kind"][:-4]
            elif t == "do": stack.append({"kind": "do"})
            elif t == "if": stack.append({"kind": "if"})
            elif t == "for": stack.append({"kind": "for-hdr"})
            elif t == "while": stack.append({"kind": "while-hdr"})
            elif t == "repeat": stack.append({"kind": "repeat"})
            i += 1; continue
        if t == "end":
            if stack: stack.pop()
            i += 1; continue
        if t == "until":
            if stack and stack[-1]["kind"] == "repeat": stack.pop()
            i += 1; continue
        i += 1
P("\n## N. Callbacks that stop/SafeStopClock their OWN handle from inside the callback:", len(self_stop))
for e in self_stop: P("   ", e)
P("\n## O. Tick calls created inside a for-loop:", len(loop_created))
for e in loop_created: P("   ", e)
P("## O2. Tick calls created inside a Lume.each/ipairs/pairs closure (equal-delay batch candidates):", len(call_in_each))
for e in call_in_each: P("   ", e)

with open(os.path.join(S, "survey3_out.md"), "w", encoding="utf-8") as f: f.write(out.getvalue())
print(out.getvalue())
