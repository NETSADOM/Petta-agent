"""TEST FIXTURES ONLY — not real P-agent tools (you write those in Phase 5)."""


def upper(text):
    return ["ok", str(text).upper()]


def always_fails(text):
    return ["error", "service unavailable"]


def crash(text):
    raise RuntimeError("tool bug")


def raw_value(text):
    return 42                        # not ["ok", ...] → wrapped as (ok 42)


NOTES = []


def write_note(text):                # needs-approval tool: records calls
    NOTES.append(str(text))
    return ["ok", "saved"]


def note_count(_=None):
    return len(NOTES)


def sleepy(text):
    import time
    time.sleep(5)
    return ["ok", "woke up"]


def chatty(text):
    return ["ok", "x" * 10000]


def audit_has(event, tool):
    import json
    with open("data/audit.jsonl", encoding="utf-8") as f:
        return any(e["event"] == event and e["tool"] == tool
                   for e in map(json.loads, f))


CALLS = {}


def _count(name):
    CALLS[name] = CALLS.get(name, 0) + 1
    return CALLS[name]


def calls(name):
    return CALLS.get(str(name), 0)


def flaky_then_ok(text):            # fails twice with a temporary error, then works
    n = _count("flaky_then_ok")
    return ["error", "service unavailable"] if n <= 2 else ["ok", "worked on try %d" % n]


def down(text):                     # always temporarily down
    _count("down")
    return ["error", "503 service unavailable"]


def picky(text):                    # permanent error: retrying can't help
    _count("picky")
    return ["error", "invalid format"]


def backup(text):
    return ["ok", "backup result"]


# ---- verifiers: fn(goal, answer, observations) ----
def has_digit(goal, answer, observations):
    return any(c.isdigit() for c in answer)


def always_false(goal, answer, observations):
    return False


def broken_verifier(goal, answer, observations):
    raise ValueError("oops")


def reset_calls(_=None):
    CALLS.clear()
    return True


def press_cancel(text):             # simulates you typing "c" while this tool runs
    import ui
    ui.request_cancel()
    return ["ok", "working..."]


def big_text(i, n=1000):
    return (f"observation {i} " + "lorem ipsum " * (int(n) // 6 + 1))[:int(n)]


def record_size(full, windowed):
    print(f"(context-size full {full} chars, windowed {windowed} chars, "
          f"{100 - 100 * int(windowed) // int(full)}% smaller)", flush=True)
    return True


def redirect_check(url):
    """Ask http-get's redirect guard about a redirect target (raises if refused)."""
    import agent_tools
    agent_tools._CheckedRedirect().redirect_request(None, None, 302, "", {}, str(url))
    return "allowed"


def exits(text):                    # a tool that calls sys.exit(): must not end the agent
    import sys
    sys.exit(3)


def interrupted(text):              # as if Ctrl+C hit while the tool ran
    raise KeyboardInterrupt()


def has(text, part):
    return str(part) in str(text)


def make_fixtures(root):
    """Files the read-file error tests need: an empty file, a binary file, a folder."""
    import os
    os.makedirs(os.path.join(root, "folder"), exist_ok=True)
    open(os.path.join(root, "empty.txt"), "w").close()
    with open(os.path.join(root, "blob.bin"), "wb") as f:
        f.write(b"\x89PNG\x00\x00\x01binary")
    return True


DDG_PAGE = """<table><tr><td valign="top">1.&nbsp;</td><td>
<a rel="nofollow" href="https://docs.python.org/3/library/unittest.html" class='result-link'>unittest &mdash; Unit testing framework</a>
</td></tr><tr><td>&nbsp;</td><td class='result-snippet'>
The <b>unittest</b> unit testing framework was inspired by JUnit.
</td></tr>
<tr><td valign="top">2.&nbsp;</td><td>
<a rel="nofollow" href="https://example.org/unittest" class='result-link'>Python Unittest Tutorial</a>
</td></tr><tr><td>&nbsp;</td><td class='result-snippet'>A tutorial.</td></tr></table>"""


def ddg_fixture_titles(_=None):
    """web-search's parser on a saved DuckDuckGo-lite page (no network)."""
    import agent_tools
    return " || ".join(" | ".join(r) for r in agent_tools.parse_ddg(DDG_PAGE))


def timed(spec, *args):
    """→ whole seconds a call took (proves a timeout really kills, not just waits)."""
    import importlib
    import time
    module, _, name = str(spec).rpartition(".")
    start = time.time()
    getattr(importlib.import_module(module), name)(*args)
    return round(time.time() - start)
