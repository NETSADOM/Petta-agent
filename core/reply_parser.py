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

from gemini import _first_sexpr


def q(s):
    """A MeTTa string literal. Newlines become spaces (one atom per line on disk)."""
    s = " ".join(str(s).split()) if "\n" in str(s) else str(s)
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def sym(s):
    """A MeTTa symbol: lowercase, - instead of _ / spaces, safe characters only."""
    s = re.sub(r"[\s_]+", "-", str(s).strip().lower())
    s = re.sub(r"[^a-z0-9\-.+*/]", "", s)
    return s or "unknown"


def _value_text(v):
    return v if isinstance(v, str) else json.dumps(v)


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
                        return json.loads(text[start:i + 1])
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
    if tool and str(tool).lower() not in ("final", "answer"):
        inp = _get(d, "input", "arguments", "args", "query", "parameters")
        if isinstance(inp, dict) and len(inp) == 1:
            inp = next(iter(inp.values()))
        return f"(action {sym(tool)} {q(_value_text(inp if inp is not None else ''))})"
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
            v = json.loads(t[:t.rindex("]") + 1])
            if isinstance(v, list):
                return v
        except ValueError:
            pass
    return _first_json_object(t)


def _calls(sexprs):
    """Several (action ...) forms → (actions ...); otherwise the first form."""
    actions = [s for s in sexprs if s.lstrip("( \n\t").startswith("action ")]
    if len(actions) >= 2:
        return "(actions " + " ".join(actions[:MAX_CALLS]) + ")"
    return sexprs[0] if sexprs else ""


def json_value_to_sexpr(v):
    if isinstance(v, dict) and isinstance(v.get("tool_calls"), list):
        v = v["tool_calls"]
    if isinstance(v, list):
        return _calls([s for s in (json_to_sexpr(x) for x in v) if s])
    return json_to_sexpr(v)


def extract(text):
    """→ ["found", sexpr] | ["none"]. A reply with several tool calls becomes
    ONE (actions (action T "in") ...) atom: they run in order, in one turn."""
    t = str(text).strip()
    json_first = t.startswith(("{", "[")) or t.lower().startswith("```json")
    order = ("json", "sexpr") if json_first else ("sexpr", "json")
    for kind in order:
        if kind == "sexpr":
            s = _calls(_all_sexprs(t))
        else:
            s = json_value_to_sexpr(_first_json_value(t))
        if s:
            return ["found", s]
    return ["none"]
