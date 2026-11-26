"""Console input/output for P-agent. Only Python reads stdin (never mix with readln!).

Two of the agent's tools live here, because talking to the user is part of the
agent itself, not an optional capability (declared in core/agent.metta):

    send_message(text)   show the user a message; does not wait     → ["ok", ...]
    ask_user(question)   ask and wait for one line of answer         → ["ok", answer]

Both always return ["ok", text] or ["error", text] and never raise — not even
on a closed stdin, a broken stdout or Ctrl+C at the prompt.
"""
import os
import sys

ASK_TIMEOUT = float(os.environ.get("PAGENT_ASK_TIMEOUT", "600"))   # seconds; 0 = wait forever


def _log(prompt, answer):
    """Copy what was asked and typed into the session transcript (ui.start_log)."""
    try:
        import ui
        ui.log_input(prompt, answer)
    except Exception:
        pass


def confirm(question):
    """Yes/no. Anything except y/yes — including EOF — means NO (safe default)."""
    try:
        answer = input(f"{question} [y/N] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        _log(f"{question} [y/N]", "(no answer: input closed) -> no")
        return False
    _log(f"{question} [y/N]", answer)
    return answer in ("y", "yes")


# ---------------- approvals remembered for the session ----------------
# Exact (tool, input) pairs you said yes to, for tools with remember-approval yes
# (core/tools.metta). Kept here, not in &wm: a helper agent starts with an empty
# working memory and would otherwise ask you about the same URL again.
_APPROVED = set()


def remember_approval(tool, tool_input):
    _APPROVED.add((str(tool), str(tool_input).strip()))
    return True


_ALLOWED_TOOLS = set()     # "a" at the prompt: this tool, any input, for the session


def approved_before(tool, tool_input):
    return (str(tool) in _ALLOWED_TOOLS
            or (str(tool), str(tool_input).strip()) in _APPROVED)


def forget_approvals():
    _APPROVED.clear()
    _ALLOWED_TOOLS.clear()
    return True


def confirm_remembered(question, tool, tool_input):
    """confirm() for tools with remember-approval yes, which also offer "a":
    y = this exact call (and the same call again later), a = every call of
    this tool for the rest of the session, anything else = no."""
    try:
        answer = input(f"{question} [y/N/a = allow {tool} for this session] ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        _log(f"{question} [y/N/a]", "(no answer: input closed) -> no")
        return False
    _log(f"{question} [y/N/a]", answer)
    if answer in ("a", "all", "always"):
        _ALLOWED_TOOLS.add(str(tool))
        return True
    if answer in ("y", "yes"):
        remember_approval(tool, tool_input)
        return True
    return False


def discard_typeahead():
    """Drop keys typed while the agent was working but never sent with Enter.
    They stay in the terminal's buffer and would be glued to the next goal:
    "cle" + "what is dropout" became the goal "clewhat is dropout".
    Only on a real POSIX terminal: piped input (tests, drive_session) is kept."""
    try:
        if os.name == "posix" and sys.stdin.isatty():
            import termios
            termios.tcflush(sys.stdin, termios.TCIFLUSH)
            return True
    except (ImportError, OSError, ValueError):
        pass
    return False


def read_goal():
    """Next goal from the user; EOF counts as quit."""
    discard_typeahead()
    try:
        goal = input("\nyou> ").strip() or "quit"
    except (EOFError, KeyboardInterrupt):
        goal = "quit"
    _log("\nyou>", goal)
    return goal


# ---------------- tools: send-message, ask-user ----------------
def _audit(event, tool, text, outcome, detail=""):
    try:
        import toolrunner
        toolrunner.audit(event, tool, text, outcome, detail)
    except Exception:
        pass


def send_message(text):
    """Show a message to the user (progress, partial result, warning)."""
    try:
        msg = str(text).strip()
        if not msg:
            return ["error", "empty message: nothing was sent"]
        try:
            import ui
            ui.agent_message(msg)
        except ImportError:
            print(f"agent: {msg}", flush=True)
        _audit("run", "send-message", msg, "ok")
        return ["ok", "message shown to the user"]
    except BaseException as e:                   # a broken stdout must not crash the agent
        return ["error", f"could not show the message: {type(e).__name__}: {e}"]


def _read_line(timeout):
    """One line from stdin → (text, None) or (None, why).
    The timeout applies only to a real terminal: with piped input Python may
    already hold the next lines in its buffer, where select() can't see them."""
    try:
        if timeout and timeout > 0 and sys.stdin.isatty() and os.name == "posix":
            import select
            if not select.select([sys.stdin], [], [], timeout)[0]:
                return None, f"no answer within {timeout:g}s"
        line = sys.stdin.readline()
    except (OSError, ValueError) as e:
        return None, f"input is not available ({e})"
    if line == "":
        return None, "input is closed (no user at the terminal)"
    return line.rstrip("\r\n"), None


def ask_user(question, timeout=None):
    """Ask the user a question and wait for one line. When no answer can be
    had (EOF, timeout, Ctrl+C) the error says why, so the agent can go on."""
    try:
        q = str(question).strip()
        if not q:
            return ["error", "empty question: nothing was asked"]
        try:
            import ui
            prompt = ui.question_text(q)
        except ImportError:
            prompt = f"? {q}"
        print(f"{prompt}\n> ", end="", flush=True)
        answer, why = _read_line(ASK_TIMEOUT if timeout is None else float(timeout))
        if answer is None:
            print("", flush=True)
            _audit("ask", "ask-user", q, "error", why)
            _log(prompt + " >", f"(no answer: {why})")
            return ["error", f"the user did not answer: {why}. "
                             "Do not guess what you asked: do what does not need it, then say what is blocked."]
        answer = answer.strip()
        _audit("ask", "ask-user", q, "ok", answer)
        _log(prompt + " >", answer)
        if not answer:
            return ["error", "the user did not answer: blank response. Ask again or report what is blocked; do not guess."]
        return ["ok", answer]
    except BaseException as e:                   # Ctrl+C at the prompt included
        print("", flush=True)
        return ["error", f"the user did not answer ({type(e).__name__}). "
                         "Do not guess what you asked: do what does not need it, then say what is blocked."]
