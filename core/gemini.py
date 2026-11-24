"""Gemini over plain HTTPS (urllib, no SDK) — called from MeTTa via py-call.

Every call returns a list that MeTTa sees as an expression:
    ["ok", text]                      success
    ["error", kind, message]          failure, kind is one of ERROR_KINDS
MeTTa (and later the recovery manager) decides what to do from `kind`.

Config (environment variables, never hardcoded):
    GEMINI_API_KEY   required
    GEMINI_MODEL     default below
    GEMINI_TIMEOUT   seconds, default 60

Check your setup:  python3 core/gemini.py --list-models
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

API = "https://generativelanguage.googleapis.com/v1beta"
DEFAULT_MODEL = "gemini-2.5-flash"

# temporary errors may be retried; permanent ones must not be
ERROR_KINDS = {
    "config": "permanent",      # key missing
    "auth": "permanent",        # key invalid / no access
    "bad-request": "permanent",
    "model-not-found": "permanent",
    "blocked": "permanent",     # safety filter / empty answer
    "rate-limit": "temporary",
    "server": "temporary",
    "network": "temporary",
}


def _key():
    return os.environ.get("GEMINI_API_KEY", "").strip()


def _classify_http(code, body):
    if code == 400 and "API_KEY" in body:
        return "auth"
    if code in (401, 403):
        return "auth"
    if code == 404:
        return "model-not-found"
    if code == 429:
        return "rate-limit"
    if code >= 500:
        return "server"
    return "bad-request"


CALLS = {"n": 0}          # request counter (evaluation metrics)


def calls(_=None):
    return CALLS["n"]


def reset_calls(_=None):
    CALLS["n"] = 0
    return True


def generate(system, prompt, model=None):
    """One request to Gemini. `system` = our instructions, `prompt` = task data."""
    CALLS["n"] += 1
    key = _key()
    if not key:
        return ["error", "config", "GEMINI_API_KEY is not set"]
    model = model or os.environ.get("GEMINI_MODEL", DEFAULT_MODEL)
    timeout = float(os.environ.get("GEMINI_TIMEOUT", "60"))
    body = json.dumps({
        # instructions go in systemInstruction, data goes in contents:
        # keeps untrusted text from being treated as our instructions
        "systemInstruction": {"parts": [{"text": str(system)}]},
        "contents": [{"role": "user", "parts": [{"text": str(prompt)}]}],
        "generationConfig": {"temperature": 0.2},
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{API}/models/{model}:generateContent", body,
        {"Content-Type": "application/json", "x-goog-api-key": key})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        return ["error", _classify_http(e.code, text), f"HTTP {e.code}: {_short(text)}"]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", "network", _short(str(e))]

    candidates = data.get("candidates") or []
    parts = (candidates[0].get("content") or {}).get("parts", []) if candidates else []
    text = "".join(p.get("text", "") for p in parts).strip()
    if not text:
        reason = (data.get("promptFeedback") or {}).get("blockReason") \
            or (candidates[0].get("finishReason") if candidates else "no candidates")
        return ["error", "blocked", f"empty reply ({reason})"]
    return ["ok", text]


def is_temporary(kind):
    return ERROR_KINDS.get(str(kind)) == "temporary"


def extract_sexpr(text):
    """Pull the first balanced (...) expression out of an LLM reply.
    Handles ```code fences``` and chatter around the expression.
    Returns ["found", expr] or ["none"]. Parentheses inside "strings" are ignored."""
    s = _first_sexpr(text)
    return ["found", s] if s else ["none"]


def _first_sexpr(text):
    text = re.sub(r"```[a-zA-Z]*", "", str(text))
    start = text.find("(")
    if start < 0:
        return ""
    depth, in_str, esc = 0, False, False
    for i in range(start, len(text)):
        c = text[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    return ""


def _short(s, n=300):
    s = " ".join(str(s).split())
    k = _key()
    if k:
        s = s.replace(k, "***")      # never leak the key into logs/atoms
    return s[:n]


def list_models():
    key = _key()
    if not key:
        print("GEMINI_API_KEY is not set")
        return 1
    req = urllib.request.Request(f"{API}/models?pageSize=200",
                                 headers={"x-goog-api-key": key})
    try:
        data = json.load(urllib.request.urlopen(req, timeout=30))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {_short(e.read().decode('utf-8', 'replace'))}")
        return 1
    for m in data.get("models", []):
        if "generateContent" in m.get("supportedGenerationMethods", []):
            print(m["name"].removeprefix("models/"))
    print(f"\ncurrently using: {os.environ.get('GEMINI_MODEL', DEFAULT_MODEL)}")
    return 0


if __name__ == "__main__":
    if "--list-models" in sys.argv:
        sys.exit(list_models())
    print(generate("Answer in one short sentence.", " ".join(sys.argv[1:]) or "Say hello."))
