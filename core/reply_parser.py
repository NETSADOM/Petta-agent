"""Turns an LLM reply into ONE MeTTa S-expression (text) for sread.

P-agent's protocol is S-expressions, but models (especially OpenAI-style ones)
often answer with JSON tool calls. Both are accepted; JSON is translated into
the same atoms, so validation and permission checks are identical.

    (action calc "2+3")                         S-expression (preferred)
    {"tool": "calc", "input": "2+3"}            → (action calc "2+3")
    {"final": "5"}  {"answer": "5"}             → (final "5")
    {"task_done": "t1"}                         → (task-done t1)
    {"ask_user": "which file?"}                 → (ask-user "which file?")
    {"plan": [{"id": "t1", "task": "..", "after": ["t0"], "uses": "math"}]}
    {"verdict": "supported", "reason": ".."}    → (verdict supported "..")

extract(text) → ["found", sexpr] | ["none"]
"""
import json
import re
import shlex

from gemini import _first_sexpr


def q(s):
    """A MeTTa string literal with the content EXACTLY preserved: newlines and tabs
    are escaped (sread turns \\n back into a newline), never flattened to spaces —
    that broke Python code and changed the files write-file wrote."""
    s = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s.replace("\r", "\\r").replace("\n", "\\n").replace("\t", "\\t") + '"'


def write_file_input(path, content):
    """(action write-file "PATH" "CONTENT") → the JSON input write_file takes.
    The content arrives already unescaped (sread turned \\n into a newline)."""
    return json.dumps({"path": str(path), "content": str(content)}, ensure_ascii=False)


def sym(s):
    """A MeTTa symbol: lowercase, - instead of _ / spaces, safe characters only."""
    s = re.sub(r"[\s_]+", "-", str(s).strip().lower())
    s = re.sub(r"[^a-z0-9\-.+*/]", "", s)
    return s or "unknown"


def _value_text(v):
    return v if isinstance(v, str) else json.dumps(v)


# Namespaces some models put in front of tool names, from the harness they were
# trained in: gpt-oss writes repo_browser.list_files / functions.run_shell,
# Gemini default_api.calc. P-agent's tool names have no dots.
TOOL_NAMESPACES = ("repo_browser", "functions", "container", "default_api", "tools", "tool")


def tool_name(name):
    name = str(name).strip()
    head, dot, rest = name.partition(".")
    if dot and rest and head.lower().replace("-", "_") in TOOL_NAMESPACES:
        name = rest
    return sym(name)


# Keys that hold THE input when a model sends it as an object with extras, e.g.
# {"cmd": [...], "timeout": 60000}. An object with "content" is write-file's own
# JSON input and is kept whole.
PRIMARY_KEYS = ("cmd", "command", "code", "script", "query", "q", "url", "expression",
                "question", "message", "text", "input", "path", "file", "name")


def tool_input(inp):
    """A model's input value → the text the tool gets."""
    if isinstance(inp, str) and inp.lstrip().startswith("{"):
        try:
            inp = json.loads(inp, strict=False)
        except ValueError:
            pass
    if isinstance(inp, dict) and "content" not in inp:
        if not inp:
            inp = ""
        elif len(inp) == 1:
            inp = next(iter(inp.values()))
        else:
            key = next((k for k in PRIMARY_KEYS if k in inp), None)
            if key is not None:
                inp = inp[key]
    if isinstance(inp, list) and inp and all(isinstance(x, str) for x in inp):
        # {"cmd": ["bash", "-lc", "python3 -m unittest"]}: keep the quoting, or
        # bash -lc would run only "python3"
        inp = inp[0] if len(inp) == 1 else shlex.join(inp)
    return _value_text(inp if inp is not None else "")


def _first_json_object(text):
    text = re.sub(r"```[a-zA-Z]*", "", str(text))
    start = text.find("{")
    while start >= 0:
        depth, in_str, esc = 0, False, False
        for i in range(start, len(text)):
            c = text[i]
            if in_str:
                esc = (not esc and c == "\\")
                if c == '"' and not esc:
                    in_str = False
                if c != "\\":
                    esc = False
            elif c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    try:
                        return json.loads(text[start:i + 1], strict=False)   # raw newlines in strings are common
                    except ValueError:
                        break
        start = text.find("{", start + 1)
    return None


def _get(d, *names):
    for n in names:
        for k in (n, n.replace("_", "-"), n.replace("-", "_")):
            if k in d:
                return d[k]
    return None


def _plan(tasks):
    parts = []
    for i, t in enumerate(tasks if isinstance(tasks, list) else [], 1):
        if isinstance(t, str):
            t = {"task": t}
        if not isinstance(t, dict):
            return ""
        tid = sym(_get(t, "id") or f"t{i}")
        desc = _get(t, "task", "description", "desc", "name") or ""
        opts = ""
        after = _get(t, "after", "depends_on", "dependencies")
        if after:
            after = after if isinstance(after, list) else [after]
            opts += " (after " + " ".join(sym(a) for a in after) + ")"
        uses = _get(t, "uses", "skill")
        if uses:
            opts += f" (uses {sym(uses)})"
        parts.append(f"(task {tid} {q(desc)}{opts})")
    return "(plan " + " ".join(parts) + ")" if parts else ""


def json_to_sexpr(d):
    if not isinstance(d, dict):
        return ""
    if "plan" in d:
        return _plan(d["plan"])
    if "verdict" in d:
        return f"(verdict {sym(d['verdict'])} {q(_get(d, 'reason', 'why') or '')})"
    tool = _get(d, "tool", "action", "name", "function")
    if isinstance(tool, dict):                     # {"function": {"name":.., "arguments":..}}
        d, tool = tool, _get(tool, "name")
    args = _get(d, "arguments", "args", "parameters")
    if isinstance(args, str):
        try:
            args = json.loads(args, strict=False)
        except ValueError:
            pass
    if str(tool).lower() in CHANNELS and isinstance(args, dict):
        # gpt-oss names its output CHANNEL, the real call is inside:
        # {"name": "commentary", "arguments": {"action": "read-skill", "input": "x"}}
        return json_to_sexpr(args)
    if tool and str(tool).lower() not in ("final", "answer"):
        inp = _get(d, "input", "arguments", "args", "query", "parameters")
        if inp is None:      # {"tool": "run-shell", "cmd": "ls"}: the other keys are the input
            inp = {k: v for k, v in d.items() if k not in ("tool", "action", "name", "function")}
        return f"(action {tool_name(tool)} {q(tool_input(inp))})"
    final = _get(d, "final", "answer", "final_answer", "response")
    if final is not None:
        return f"(final {q(_value_text(final))})"
    done = _get(d, "task_done", "done")
    if done is not None:
        return f"(task-done {sym(done)})"
    ask = _get(d, "ask_user", "question")
    if ask is not None:
        return f"(ask-user {q(ask)})"
    return ""


CHANNELS = ("commentary", "analysis", "assistant")   # gpt-oss channel names, not tools
MAX_CALLS = 5          # tool calls run from one reply; more are dropped (told to the model)


def _all_sexprs(text):
    """Every top-level S-expression in the text, in order."""
    out, rest = [], re.sub(r"```[a-zA-Z]*", "", str(text))
    while True:
        s = _first_sexpr(rest)
        if not s:
            return out
        out.append(s)
        rest = rest[rest.find(s) + len(s):]


def _first_json_value(text):
    """The first JSON array of objects, or the first JSON object."""
    t = re.sub(r"```[a-zA-Z]*", "", str(text)).strip()
    if t.startswith("["):
        try:
            v = json.loads(t[:t.rindex("]") + 1], strict=False)
            if isinstance(v, list):
                return v
        except ValueError:
            pass
    return _first_json_object(t)


# heads of the forms the agent understands (act, plan and verify replies)
REPLY_HEADS = ("action", "actions", "final", "ask-user", "task-done", "task-failed", "replan",
               "missing-capability", "learn", "plan", "verdict")


def _head(s):
    words = s.lstrip("( \n\t").split(None, 1)
    return words[0].rstrip(")") if words else ""


def _calls(sexprs):
    """The reply's forms → ONE S-expression.
    Prose around the reply may contain parentheses, "(carefully)": those are
    skipped, only forms with a known head count. Several (action ..) forms →
    (actions ..), with any (task-done ..) among them kept in order; otherwise
    the first known form. No known form at all → the first one (it is then
    reported to the model as a bad shape)."""
    known = [_bare_task_done(s) for s in sexprs if _head(s) in REPLY_HEADS]
    # a batch: calls and task-dones in a row, optionally ENDED by one final
    batch, final = [], None
    for s in known:
        if _head(s) in ("action", "task-done"):
            batch.append(s)
        else:
            if _head(s) == "final":
                final = fix_string_form(s)
            break
    has_action = any(_head(s) == "action" for s in batch)
    if batch and (has_action or final) and len(batch) + (final is not None) >= 2:
        return "(actions " + " ".join(batch[:MAX_CALLS] + ([final] if final else [])) + ")"
    if known:
        return fix_string_form(known[0])
    return sexprs[0] if sexprs else ""


_STRING = re.compile(r'\s*"(?:[^"\\]|\\.)*"')


def _bare_task_done(s):
    """(task-done t1 "what I found") → (task-done t1): task-done takes ids only;
    models add a note, and the whole reply was refused as a bad shape. Inside an
    (actions ..) batch too. Findings belong in a note or the final."""
    if _head(s) == "task-done":
        return _STRING.sub("", s)
    if _head(s) == "actions":
        inner = s.strip()[1:-1].lstrip().split(None, 1)   # "actions", "(..) (..)"
        items = _all_sexprs(inner[1]) if len(inner) == 2 else []
        if any(_head(i) == "task-done" for i in items):
            return "(actions " + " ".join(_bare_task_done(i) for i in items) + ")"
    return s


# (final "text") / (ask-user "text"): ONE string. A model writing a long answer
# often leaves a quote inside it unescaped: (final "it "drops" units") then reads
# as several pieces (bad shape), or never closes (no expression). The whole text
# between the first and the last quote is the string: its inner quotes are escaped.
_STRING_FORM = re.compile(r'^\(\s*(final|ask-user)\s+"(.*)"\s*\)$', re.S)
_GOOD_STRING_FORM = re.compile(r'^\(\s*(final|ask-user)\s+"(?:[^"\\]|\\.)*"\s*\)$', re.S)


def fix_string_form(s):
    s = s.strip()
    if _GOOD_STRING_FORM.match(s):
        return s
    m = _STRING_FORM.match(s)
    if not m:
        return s
    inner = re.sub(r'(?<!\\)"', r'\\"', m.group(2))
    return f'({m.group(1)} "{inner}")'


def _unclosed_string_form(text):
    """A final / ask-user whose quotes never balance, so no S-expression was found:
    from '(final "' to the last '")' in the reply."""
    for head in ("final", "ask-user"):
        m = re.search(r'\(\s*' + head + r'\s+"', text)
        end = text.rfind('")')
        if m and end > m.start():
            fixed = fix_string_form(text[m.start():end + 2])
            if _GOOD_STRING_FORM.match(fixed):
                return fixed
    return ""


def json_value_to_sexpr(v):
    if isinstance(v, dict) and isinstance(v.get("tool_calls"), list):
        v = v["tool_calls"]
    if isinstance(v, list):
        return _calls([s for s in (json_to_sexpr(x) for x in v) if s])
    return json_to_sexpr(v)


_LAST = {"text": ""}


def last_reply(_=None):
    """The latest reply text given to extract(), shortened: shown to the model
    when that reply could not be used (core/llm.metta repair-reply). It is
    also written to the audit log, so unusable replies can be diagnosed."""
    shown = " ".join(_LAST["text"].split())
    shown = shown[:400] + ("..." if len(shown) > 400 else "")
    try:
        import toolrunner
        toolrunner.audit("unusable-reply", "llm", _LAST["text"][:2000], "invalid")
    except Exception:
        pass
    return shown or "(an empty reply)"


def _extract(text):
    """→ ["found", sexpr] | ["none"]. A reply with several tool calls becomes
    ONE (actions (action T "in") ...) atom: they run in order, in one turn."""
    t = str(text).strip()
    _LAST["text"] = t
    json_first = t.startswith(("{", "[")) or t.lower().startswith("```json")
    order = ("json", "sexpr") if json_first else ("sexpr", "json")
    for kind in order:
        if kind == "sexpr":
            s = _calls(_all_sexprs(t))
        else:
            s = json_value_to_sexpr(_first_json_value(t))
        if s:
            return ["found", s]
    s = _unclosed_string_form(re.sub(r"```[a-zA-Z]*", "", t))
    return ["found", s] if s else ["none"]


def extract(text):
    """Malformed model data is a recoverable reply, never a Python exception."""
    try:
        return _extract(text)
    except (TypeError, ValueError, KeyError, IndexError, RecursionError):
        return ["none"]


def prose_final(text):
    """Last format-repair fallback: quote substantial prose as a final proposal.

    Never infer tool calls. The caller must require semantic verification, so
    formatting recovery cannot turn unsupported prose into a successful answer.
    """
    text = str(text).strip()
    if len(text) < 120 or text.startswith(("{", "[", "(", "```")):
        return ""
    if len(re.findall(r"[.!?](?:\s|$)|\n", text)) < 2:
        return ""
    if re.search(r"\((?:action|actions|final|task-done|plan)\b", text):
        return ""
    return "(final " + q(text) + ")"
