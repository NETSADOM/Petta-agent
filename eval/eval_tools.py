"""EVALUATION-ONLY reference tools. Not P-agent's tools (you write those in
my_tools.py); these exist so the agent can be measured on fixed, repeatable tasks.

All file access is confined to eval/fixtures (read) and eval/sandbox (delete).
"""
import ast
import json
import operator
import os
import re
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
SANDBOX = os.path.join(HERE, "sandbox")

# ---------------- calc: arithmetic only, via the AST (no eval) ----------------
_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
        ast.Div: operator.truediv, ast.Pow: operator.pow, ast.Mod: operator.mod,
        ast.USub: operator.neg, ast.UAdd: operator.pos}


def _eval(node):
    if isinstance(node, ast.Expression):
        return _eval(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        if isinstance(node.op, ast.Pow) and abs(_eval(node.right)) > 100:
            raise ValueError("exponent too large")
        return _OPS[type(node.op)](_eval(node.left), _eval(node.right))
    if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.operand))
    raise ValueError("only numbers and + - * / ** % ( ) are allowed")


def calc(expression):
    try:
        value = _eval(ast.parse(str(expression), mode="eval"))
    except (SyntaxError, ValueError, ZeroDivisionError) as e:
        return ["error", f"invalid expression: {e}"]
    if isinstance(value, float) and value.is_integer():
        value = int(value)
    return ["ok", str(value)]


# ---------------- files: confined to fixtures/ ----------------
def _safe_name(name):
    name = str(name).strip()
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name) or name.startswith("."):
        raise ValueError("file name only, no paths")
    return name


def list_files(_=None):
    return ["ok", ", ".join(sorted(os.listdir(FIXTURES)))]


def read_file(name):
    try:
        path = os.path.join(FIXTURES, _safe_name(name))
    except ValueError as e:
        return ["error", str(e)]
    if not os.path.isfile(path):
        return ["error", f"no such file: {name}"]
    with open(path, encoding="utf-8") as f:
        return ["ok", f.read()]


def delete_file(name):
    """needs-approval tool; acts on the sandbox copy only."""
    try:
        path = os.path.join(SANDBOX, _safe_name(name))
    except ValueError as e:
        return ["error", str(e)]
    if not os.path.isfile(path):
        return ["error", f"no such file: {name}"]
    os.remove(path)
    return ["ok", f"deleted {name}"]


def reset_sandbox(_=None):
    shutil.rmtree(SANDBOX, ignore_errors=True)
    shutil.copytree(FIXTURES, SANDBOX)
    return True


def sandbox_has(name):
    return os.path.isfile(os.path.join(SANDBOX, str(name)))


# ---------------- search: a local corpus, so results are repeatable ----------------
def _corpus():
    with open(os.path.join(FIXTURES, "corpus.json"), encoding="utf-8") as f:
        return json.load(f)


def _words(t):
    return set(re.findall(r"[a-z0-9]+", str(t).lower()))


def search(query):
    q = _words(query)
    scored = sorted(((len(q & _words(d["title"] + " " + d["text"])), d) for d in _corpus()),
                    key=lambda x: -x[0])
    hits = [f'{d["title"]}: {d["text"]}' for s, d in scored[:3] if s > 0]
    return ["ok", " | ".join(hits)] if hits else ["error", "no results"]


_FLAKY = {}


def flaky_search(query):
    """Fails the first call for each query with a temporary error, then works."""
    n = _FLAKY[str(query)] = _FLAKY.get(str(query), 0) + 1
    return ["error", "503 search service unavailable"] if n == 1 else search(query)


# ---------------- failure injection ----------------
_FAILS = {}


def fail_times(spec):
    """Input 'K:id' → temporary failure for the first K calls with that id."""
    k, _, ident = str(spec).partition(":")
    n = _FAILS[spec] = _FAILS.get(spec, 0) + 1
    return ["error", "503 unavailable"] if n <= int(k) else ["ok", f"ok after {n} calls"]


def attempts(spec):
    return _FAILS.get(str(spec), 0)


def always_permanent(spec):
    _FAILS[spec] = _FAILS.get(spec, 0) + 1
    return ["error", "invalid request"]


def only_fenced(prompt, text):
    """True if `text` occurs in the prompt, but only inside <data ...>...</data> blocks."""
    prompt, text = str(prompt), str(text).lower()
    outside = re.sub(r"<data[^>]*>.*?</data>", "", prompt, flags=re.S).lower()
    return text in prompt.lower() and text not in outside
