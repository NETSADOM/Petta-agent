"""CLI renderer for P-agent events. The ONLY place that decides how things look.

The agent core never prints: it calls (emit EVENT). With (config ui pretty)
each event arrives here as a Python list, e.g. ["step", 1, "t1", "calc", "2+3"].
A web UI later would replace this file, not the agent.
"""
import os
import select
import sys

COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None


def _c(code, text):
    return f"\033[{code}m{text}\033[0m" if COLOR else str(text)


def dim(t): return _c("2", t)
def bold(t): return _c("1", t)
def red(t): return _c("31", t)
def green(t): return _c("32", t)
def yellow(t): return _c("33", t)
def cyan(t): return _c("36", t)


def fmt(x, limit=160):
    """Atom (nested lists) → readable text."""
    if isinstance(x, (list, tuple)):
        s = "(" + " ".join(fmt(i, limit) for i in x) + ")"
    else:
        s = str(x)
    return s if len(s) <= limit else s[:limit] + "…"


_ANSI = __import__("re").compile(r"\033\[[0-9;]*m")
_LOG = {"file": None, "path": None}


def start_log(directory=None):
    """Start a session transcript: everything shown and typed, without colours.
    PAGENT_LOG_DIR (default logs/). Returns the path; never fails the CLI."""
    import time
    try:
        d = directory or os.environ.get("PAGENT_LOG_DIR", "logs")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, time.strftime("session-%Y%m%d-%H%M%S.log"))
        _LOG["file"] = open(path, "a", encoding="utf-8", buffering=1)
        _LOG["path"] = path
        log_line(f"# P-agent session started {time.strftime('%Y-%m-%d %H:%M:%S')}")
        return path
    except OSError:
        return ""


def log_line(text):
    f = _LOG["file"]
    if f:
        try:
            f.write(_ANSI.sub("", str(text)) + "\n")
        except (OSError, ValueError):
            pass
    return True


def log_input(prompt, answer):
    """What the user typed (io_helper calls this), so the log reads like the screen."""
    return log_line(f"{_ANSI.sub('', str(prompt)).rstrip()} {answer}")


def _out(line):
    print(line, flush=True)
    log_line(line)


STATUS_ICON = {"pending": "○", "ready": "○", "running": "◐", "completed": "●",
               "blocked": "⊘", "failed": "✗", "cancelled": "–"}


def render(event):
    e = event if isinstance(event, list) else [event]
    kind = str(e[0]) if e else ""
    a = e[1:]

    if kind == "plan-result":
        r = a[0] if a else None
        if isinstance(r, list) and r and r[0] in ("planned", "error"):
            return True       # planned: the plan event shows tasks; error: the stop message says it
        _out(yellow(f"  ⚠ no usable plan ({fmt(r)}) — working without one"))
    elif kind == "plan":
        _out(bold("Plan"))
        for t in (a[0] if a else []):
            tid, desc, status = t[0], t[1], t[2]
            _out(f"  {STATUS_ICON.get(str(status), '?')} {tid}  {desc}")
    elif kind == "step":
        n, task, tool, tool_input = a
        task_txt = "" if str(task) == "none" else dim(f"[{task}] ")
        _out(f"{dim(f'{n:>2}.')} {task_txt}{cyan(tool)} {fmt(tool_input, 100)}")
    elif kind == "result":
        r = a[0]
        if isinstance(r, list) and r and r[0] == "ok":
            _out(green("    ✓ ") + fmt(r[1] if len(r) > 1 else "", 200))
        else:
            _out(red("    ✗ ") + fmt(r[1:] if isinstance(r, list) else r, 200))
    elif kind == "retry":
        _out(yellow(f"    ↻ retry {a[0]} of {a[1]}: {fmt(a[2], 100)}"))
    elif kind == "task-done":
        _out(green(f"    ● {a[0]} done"))
    elif kind == "task-failed":
        _out(red(f"    ✗ {a[0]} failed") + dim(f"  {fmt(a[1])}"))
    elif kind == "replanned":
        _out(yellow("  ↺ replanning"))
    elif kind == "missing-capability":
        _out(yellow(f"  ⚑ missing capability noted for you: {fmt(a[0])}"))
    elif kind == "learn":
        ok = isinstance(a[1], list) and a[1] and a[1][0] == "ok"
        _out((green("  ✎ remembered ") if ok else dim("  ✎ not remembered ")) + fmt(a[0]) +
             ("" if ok else dim(f"  {fmt(a[1])}")))
    elif kind == "final-rejected":
        _out(yellow("  ⚠ answer rejected by verification: ") + fmt(a[0], 200))
    elif kind == "gemini-reply":
        _out(dim(f"  · ignored unusable reply: {fmt(a[0])}"))
    elif kind == "gemini-error":
        _out(yellow(f"  ⚠ Gemini error: {fmt(a[0])} — retrying"))
    elif kind == "stop-report":
        _stop_report(a)
    elif kind == "cancel-hint":
        if sys.stdin.isatty():
            _out(dim("  (type c + Enter to cancel)"))
    else:
        _out(dim(fmt(e)))
    return True


def _field(parts, name):
    for p in parts:
        if isinstance(p, list) and p and str(p[0]) == name:
            return p[1:]
    return []


def _why(reason):
    r = reason if isinstance(reason, list) else [reason]
    kind = str(r[0]) if r else "?"
    return {
        "iteration-limit": "I used all my turns for this goal without finishing it.",
        "repeated-failure": "I kept trying the same failing step: " + fmt(r[1:], 120),
        "no-progress": "My last steps all failed, so I stopped instead of guessing.",
        "too-many-invalid-replies": "The language model kept giving replies I could not use.",
        "error": "The language model could not be reached: " + fmt(r[1:], 160),
    }.get(kind, fmt(r, 200))


def _stop_report(parts):
    """A run ended without an answer: say so plainly, with what you can do."""
    # parts: (goal G) (reason R) (progress (turns N) (steps N) (tasks-done D of T) (open ..)) (recent-errors ..)
    reason = (_field(parts, "reason") or ["?"])[0]
    _out("")
    _out(red(bold("■ I'm stuck — no final answer for this goal")))
    _out(f"  why:   {_why(reason)}")
    goal = _field(parts, "goal")
    if goal:
        _out(f"  goal:  {fmt(goal[0], 200)}")
    p = next((x for x in parts if isinstance(x, list) and x and str(x[0]) == "progress"), [])
    done = _field(p[1:], "tasks-done")
    turns = _field(p[1:], "turns")
    if done and len(done) >= 3 and str(done[2]) != "0":
        opened = _field(p[1:], "open")
        _out(f"  plan:  {fmt(done[0])} of {fmt(done[2])} tasks done after {fmt(turns[0]) if turns else '?'} turns"
             + (f"; open: {fmt(opened[0])}" if opened and opened[0] else ""))
    errs = (_field(parts, "recent-errors") or [[]])[0]
    for e in (errs if isinstance(errs, list) else [])[:3]:
        if isinstance(e, list) and len(e) >= 3:
            _out(dim(f"  step {e[0]} {e[1]}: {fmt(e[2], 150)}"))
    _out("  you can: add the missing detail, approve the step it needs, or rephrase the goal")
    return True


def show_text(title, text):
    _out(bold(title))
    for line in str(text).splitlines() or [""]:
        _out("  " + line)
    return True


def task_header(n, goal):
    _out("")
    _out(bold(f"── task {n} ") + dim("─" * 40))
    log_line(f"goal: {goal}")
    return True


def internal_error(why):
    _out(red("\n✗ internal error while working on this goal: ") + fmt(why, 300))
    _out(dim("  the session continues — type the next goal"))
    return True


def show_result(result):
    """Final outcome of one goal."""
    r = result if isinstance(result, list) else [result]
    kind = str(r[0])
    if kind == "done":
        _box(green("✔ verified answer"), r[1])
    elif kind == "done-unverified":
        _box(yellow("⚠ answer NOT fully verified"), r[1])
    elif kind == "cancelled":
        _out(yellow("\n■ cancelled by you"))
    else:
        _out(red("\n✗ stopped: ") + fmt(r[1:] if len(r) > 1 else r, 300))
    return True


def _box(title, text):
    _out("")
    _out(title)
    for line in str(text).splitlines() or [""]:
        _out("  " + line)


def banner(tools, skills, stats, _key_set=None, _model=None):
    # key/model are read here: a Python bool passed through MeTTa comes back
    # as the TEXT "false", which Python treats as true.
    import llm_client
    _out(bold("P-agent") + dim("  — MeTTa/PeTTa reasoning + an LLM"))
    _out(f"  tools:  {', '.join(str(t[0]) for t in tools) or dim('none yet (add them in my_capabilities.metta)')}")
    _out(f"  skills: {', '.join(str(s[0]) for s in skills) or dim('none available')}")
    _out(f"  memory: {fmt(stats[1:])}  (AtomSpace &kb, saved to disk)")
    if not llm_client.configured():
        _out(yellow("  ⚠ no LLM configured: set GEMINI_API_KEY, or OPENAI_API_KEY + OPENAI_MODEL "
                    "(+ OPENAI_BASE_URL for other providers) — goals will fail until then"))
    _out(dim(f"  llm:    {llm_client.describe()}"))
    _out(dim("  commands: help tools skills memory quit   ·   anything else is a goal"))
    return True


def help_text():
    _out("\n".join([
        "  help     this text",
        "  tools    declared tools and their permission level",
        "  skills   declared skills and whether they are available",
        "  memory   what is stored in long-term memory",
        "  history  the goals of this session and how they ended",
        "  quit     save memory and exit",
        "  While the agent works: type c + Enter to cancel the current goal.",
    ]))
    return True


def list_rows(title, rows):
    _out(bold(title))
    for r in rows or []:
        _out("  " + fmt(r, 200))
    if not rows:
        _out(dim("  (none)"))
    return True


# ---------------- cancellation ----------------
_CANCEL = {"flag": False}


def request_cancel(_=None):
    """Test hook / programmatic cancel."""
    _CANCEL["flag"] = True
    return True


def cancel_requested(_=None):
    """True if the user typed c (or cancel/stop) + Enter. Never blocks.
    Only reads a real terminal, so piped input (tests) is never consumed."""
    if _CANCEL["flag"]:
        _CANCEL["flag"] = False
        return True
    if not sys.stdin.isatty():
        return False
    try:
        if select.select([sys.stdin], [], [], 0)[0]:
            return sys.stdin.readline().strip().lower() in ("c", "cancel", "stop")
    except (OSError, ValueError):
        pass
    return False


def key_set(_=None):
    return bool(os.environ.get("GEMINI_API_KEY", "").strip())


def model(_=None):
    return os.environ.get("GEMINI_MODEL", "gemini-2.5-flash")


def quit_now(_=None):
    """Exit at once after `quit` (memory is already saved): otherwise PeTTa
    prints the results of every top-level expression on the way out."""
    _out("bye")
    sys.stdout.flush()
    os._exit(0)


def approval_question(tool, tool_input):
    return (yellow("  ? ") + bold(f"allow {tool}") +
            f" with input {fmt(tool_input, 200)!s} ?")


def question_text(question):
    return yellow("  ? the agent asks: ") + str(question)


def agent_message(text):
    """A message the agent sends you with the send-message tool."""
    lines = str(text).splitlines() or [""]
    _out(cyan("  ✉ agent: ") + lines[0])
    for line in lines[1:]:
        _out("           " + line)
    return True
