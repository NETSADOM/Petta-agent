"""Runs one tool call safely and writes the audit log. Called from core/tools.metta.

run(...) returns ["ok", value] or ["error", reason] — never raises.

Timeout limitation (honest): Python threads cannot be killed. A timed-out tool
is abandoned (the agent moves on) but keeps running in the background until it
returns. Tools that may hang should use their own timeouts too (e.g. urllib's
timeout=). Real process isolation is a later sandbox phase.
"""
import importlib
import json
import os
import re
import threading
import time

AUDIT_PATH = os.environ.get("PAGENT_AUDIT", "data/audit.jsonl")


def as_text(value):
    return value if isinstance(value, str) else str(value)


def length(value):
    return len(as_text(value))


def is_blank(value):
    return as_text(value).strip() == ""


def matches(pattern, value):
    try:
        return re.fullmatch(str(pattern), as_text(value)) is not None
    except re.error:
        return False                 # a broken pattern rejects everything


def _resolve(spec):
    """'module.function' → the function. The module was already imported by
    MeTTa's !(import! &self "module.py"), so it is in sys.modules."""
    module, _, name = str(spec).rpartition(".")
    return getattr(importlib.import_module(module), name)


def _normalize(result, max_output):
    """Tool contract: ["ok", x] / ["error", msg]; anything else counts as ok."""
    if isinstance(result, (list, tuple)) and len(result) == 2 and result[0] in ("ok", "error"):
        kind, value = result
    else:
        kind, value = "ok", result
    if not isinstance(value, (str, int, float, bool)):
        value = str(value)           # dicts/objects → text MeTTa can hold
    if isinstance(value, str) and len(value) > max_output:
        value = value[:max_output] + f"... [truncated, {len(value)} chars]"
    return [kind, value]


def check(spec, tool_input):
    """Run a yes/no check fn(input) → bool. Any error means NO (ask the user)."""
    try:
        return _resolve(spec)(as_text(tool_input)) is True
    except BaseException:
        return False


def run(tool, spec, tool_input, timeout, max_output):
    start = time.time()
    box = {}

    def work():
        try:
            box["result"] = _normalize(_resolve(spec)(tool_input), int(max_output))
        except BaseException as e:   # tool bug, sys.exit(), Ctrl+C → error, never a crash
            box["result"] = ["error", f"exception {type(e).__name__}: {e}"[:300]]

    try:
        worker = threading.Thread(target=work, daemon=True)
        worker.start()
        worker.join(float(timeout))
        if worker.is_alive():
            result = ["error", f"timeout after {timeout}s"]
        else:
            result = box.get("result", ["error", "the tool returned nothing"])
    except BaseException as e:       # e.g. Ctrl+C while waiting for the tool
        result = ["error", f"tool call interrupted: {type(e).__name__}"]
    audit("run", tool, tool_input, result[0], result[1], round(time.time() - start, 3))
    return result


def audit(event, tool, tool_input, outcome, detail="", seconds=None):
    """Append one JSON line. Never lets logging break the agent."""
    entry = {"time": time.strftime("%Y-%m-%dT%H:%M:%S"), "event": str(event),
             "tool": str(tool), "input": as_text(tool_input)[:500],
             "outcome": str(outcome), "detail": as_text(detail)[:500]}
    if seconds is not None:
        entry["seconds"] = seconds
    try:
        os.makedirs(os.path.dirname(os.path.abspath(AUDIT_PATH)), exist_ok=True)
        with open(AUDIT_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(entry) + "\n")
    except OSError:
        pass
    return True


def run_verifier(spec, goal, answer, observations, timeout=10):
    """Run a developer verifier fn(goal, answer, observations) with a timeout.
    Returns ["ok", note] or ["error", reason]. A crash or timeout is a failure."""
    box = {}

    def work():
        try:
            r = _resolve(spec)(str(goal), str(answer), str(observations))
            if isinstance(r, bool):        # a check may simply return True / False
                r = ["ok", "passed"] if r else ["error", "check did not pass"]
            box["result"] = _normalize(r, 300)
        except BaseException as e:
            box["result"] = ["error", f"verifier crashed: {type(e).__name__}: {e}"[:300]]

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    worker.join(float(timeout))
    result = box.get("result", ["error", f"verifier timeout after {timeout}s"])
    audit("verify", spec, answer, result[0], result[1])
    return result
