"""TEST FIXTURES ONLY — not real P-agent tools."""


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


def html_fixture_ok(_=None):
    """A heavy page: unclosed-looking head CSS, multi-line comments, nav, an article."""
    import agent_tools
    page = ("<!doctype html><html><head><title>Loops guide</title>"
            "<!-- Critical font preloads\n spanning lines -->"
            "<style>" + ".a{color:red}" * 20000 + "</style>"
            "<script>var x = '<p>not text</p>';</script></head><body>"
            "<nav><a>Home</a><a>Blog</a></nav><article><h1>Agentic loops</h1>"
            "<p>" + "Loop engineering matters. " * 30 + "</p><ul><li>ReAct</li><li>Reflexion</li></ul>"
            "</article><footer>Subscribe</footer></body></html>")
    text = agent_tools.html_to_text(page)
    return (text.startswith("Loops guide") and "# Agentic loops" in text and "- ReAct" in text
            and "color:red" not in text and "not text" not in text and "preloads" not in text
            and "Home" not in text and "Subscribe" not in text
            and agent_tools.looks_like_html(page) and not agent_tools.looks_like_html("a,b\n1,2", "x.csv"))


def speed_fixes_ok(_=None):
    """Python side of the speed fixes (no network)."""
    import builtins
    import agent_tools
    import io_helper
    import openai_compat
    import gemini
    checks = []
    # arxiv-search input parsing
    checks.append(agent_tools.arxiv_query("latest cs.LG | 3") == ("cat:cs.LG", "submittedDate", 3))
    checks.append(agent_tools.arxiv_query("vision transformers") ==
                  ("all:vision AND all:transformers", "relevance", 5))
    checks.append(agent_tools.arxiv_query("recent machine learning | 99")[1:] == ("submittedDate", 10))
    # arXiv PDF links go to the abstract page
    m = agent_tools._ARXIV_PDF.match("https://arxiv.org/pdf/2405.00074.pdf")
    checks.append(bool(m) and m.group(1) == "2405.00074")
    checks.append(agent_tools._ARXIV_PDF.match("https://arxiv.org/pdf/2309.16588v2").group(1) == "2309.16588v2")
    checks.append(not agent_tools._ARXIV_PDF.match("https://arxiv.org/abs/2405.00074"))
    # a daily limit is not retried
    checks.append(gemini.is_temporary("rate-limit") and not gemini.is_temporary("quota"))
    checks.append(openai_compat.name_of_limit("on tokens per day (TPD): Limit 200000") ==
                  "the provider's DAILY limit")
    checks.append(openai_compat._pretty_wait(1139.4) == "18 min 59 s")
    # "a" at the approval prompt: the tool is allowed for the rest of the session
    real_input = builtins.input
    try:
        builtins.input = lambda prompt="": "a"
        checks.append(io_helper.confirm_remembered("allow?", "web-tool", "http://x/1") is True)
        checks.append(io_helper.approved_before("web-tool", "http://other/2"))
        checks.append(not io_helper.approved_before("other-tool", "http://x/1"))
        builtins.input = lambda prompt="": "y"
        checks.append(io_helper.confirm_remembered("allow?", "web-tool-2", "u1") is True)
        checks.append(io_helper.approved_before("web-tool-2", "u1")
                      and not io_helper.approved_before("web-tool-2", "u2"))
        builtins.input = lambda prompt="": "n"
        checks.append(io_helper.confirm_remembered("allow?", "web-tool-3", "u1") is False)
    finally:
        builtins.input = real_input
        io_helper.forget_approvals()
    return all(checks) or [i for i, c in enumerate(checks) if not c]


def long_text(n):
    return "word " * (int(n) // 5)


SHELL_CASES = {
    # option and operand bypasses: must ASK
    "git diff --output=file": False, "git diff --output file": False,
    "git branch --delete=name": False, "git branch -d x": False, "git branch -D x": False,
    "git branch newbranch": False, "git branch -m a b": False, "git tag v1": False,
    "git tag -d v1": False, "git remote add o u": False, "git -c core.pager=sh log": False,
    "git grep -O foo": False, "git diff --ext-diff": False, "git push": False,
    "sort -o out in": False, "sort -ro out in": False, "sort --output=o in": False,
    "tree -o out": False, "file -C -m x": False, "rg --pre sh foo": False,
    "date -s now": False, "date 01010000": False, "uniq a b": False, "hostname evil": False,
    "find . -delete": False, "cat a > b": False, "python3 x.py": False, "rm -rf x": False,
    "echo $(rm x)": False, "curl http://x": False,
    "ls a#b; rm -rf x": False, "echo hi#\nrm x": False,
    # git always asks: repository config can run programs (core.fsmonitor ...)
    "git branch": False, "git branch -a": False, "git tag -l": False, "git remote -v": False,
    "git -C sub status": False, "git log --oneline -5": False, "git show HEAD:file": False,
    # plain reading: runs without asking
    "sort -k2 -t, in": True, "echo hi # note": True,
    "tree -L 2": True, "file a.txt": True, "rg -n foo": True, "date +%Y": True,
    "uniq a": True, "hostname": True, "find . -name x": True, "ls -la | grep x": True,
}


def shell_rules_ok(_=None):
    import agent_tools
    bad = [c for c, want in SHELL_CASES.items() if agent_tools.shell_is_read_only(c) != want]
    return True if not bad else bad


# code with newlines, a tab, quotes and a backslash: must arrive EXACTLY like this
MULTILINE = 'def f():\n\treturn "a\\b"\n'


def multiline_json_reply(_=None):
    import json
    return json.dumps({"tool": "run-python", "input": MULTILINE})


def multiline_raw_json_reply(_=None):
    """A model that puts RAW newlines inside a JSON string (invalid strict JSON)."""
    return '{"tool": "run-python", "input": "print(1)\nprint(2)"}'


def is_multiline(s):
    return str(s) == MULTILINE


def is_two_lines(s):
    return str(s) == "print(1)\nprint(2)"


def claimed_files_ok(_=None):
    import os
    import capability_checks as c
    import agent_tools
    path = agent_tools._inside("exists.md")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").close()
    checks = [
        c.claimed_files_exist("g", "I saved the summary to exists.md.", "") is True,
        isinstance(c.claimed_files_exist("g", "I saved it to missing.md", ""), list),
        c.claimed_files_exist("g", "It was not saved to missing.md: write-file failed.", "") is True,
        c.claimed_files_exist("g", "See https://arxiv.org/abs/1.2 for details.", "") is True,
    ]
    return all(checks) or checks


def huge_prompt_len(_=None):
    import prompts
    big = "x" * 200_000
    return len(prompts.act_prompt(big, big, big, big, big, big, big, 1, 40, big, big, big))


def gpt_oss_replies_ok(_=None):
    """gpt-oss native tool-call replies (Groq's failed_generation) become actions."""
    import json
    import reply_parser as r
    import openai_compat as o
    cases = {
        json.dumps({"name": "commentary", "arguments": {"action": "read-skill", "input": "data-analysis"}}):
            '(action read-skill "data-analysis")',
        json.dumps({"name": "run-shell", "arguments": {"cmd": ["mkdir -p todo"]}}):
            '(action run-shell "mkdir -p todo")',
        json.dumps({"name": "commentary", "arguments": {"final": "done"}}): '(final "done")',
    }
    ok = all(r.extract(t) == ["found", want] for t, want in cases.items())
    body = json.dumps({"error": {"code": "tool_use_failed", "failed_generation": '{"name": "now"}'}})
    return ok and o.failed_generation(400, body) == '{"name": "now"}' and o.failed_generation(401, body) == ""


def write_raw(root, name, content):
    """Put a file in the workspace WITHOUT write-file's checks (a broken file the
    evidence check must catch)."""
    import os
    with open(os.path.join(str(root), str(name)), "w", encoding="utf-8") as f:
        f.write(str(content))
    return True


def late_fact(n):
    """A long page whose fact comes after n characters (past the old 4000-character
    verification cut)."""
    return "filler text " * (int(n) // 12) + "Dropout was introduced in 2012 by Hinton."
