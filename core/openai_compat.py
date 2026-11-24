"""Any OpenAI-compatible chat API over plain HTTPS (urllib, no SDK).

Works with OpenAI, OpenRouter, Groq, Together, DeepSeek, Mistral, local Ollama
(http://localhost:11434/v1), LM Studio, vLLM, llama.cpp server, ...

Config (environment variables):
    OPENAI_BASE_URL   default https://api.openai.com/v1
    OPENAI_API_KEY    required, except for local servers (localhost / 127.0.0.1)
    OPENAI_MODEL      required — model names differ per provider, so no guess
    PAGENT_TIMEOUT    seconds, default 60

Returns the same shapes as gemini.py: ["ok", text] | ["error", kind, message].
"""
import json
import os
import urllib.error
import urllib.request

DEFAULT_BASE = "https://api.openai.com/v1"


def base_url():
    return os.environ.get("OPENAI_BASE_URL", DEFAULT_BASE).rstrip("/")


def model():
    return os.environ.get("OPENAI_MODEL", "").strip()


def _key():
    return os.environ.get("OPENAI_API_KEY", "").strip()


def _is_local(url):
    return any(h in url for h in ("://localhost", "://127.0.0.1", "://0.0.0.0", "://[::1]"))


def _short(s, n=300):
    s = " ".join(str(s).split())
    k = _key()
    return (s.replace(k, "***") if k else s)[:n]


def _classify(code, body):
    low = body.lower()
    if code in (401, 403):
        return "auth"
    if code == 404 or (code == 400 and "model" in low and ("not found" in low or "does not exist" in low)):
        return "model-not-found"
    if code == 429:
        return "rate-limit"
    if code >= 500:
        return "server"
    return "bad-request"


def _tool_calls_as_text(message):
    """Some models answer with native tool_calls instead of text. Turn them
    into JSON text (one object, or a list for several calls); P-agent's parser
    understands both forms."""
    calls = message.get("tool_calls") or []
    out = []
    for call in calls:
        fn = (call or {}).get("function", {}) if isinstance(call, dict) else {}
        args = fn.get("arguments", "")
        try:
            parsed = json.loads(args) if isinstance(args, str) else args
            if isinstance(parsed, dict) and len(parsed) == 1:
                parsed = next(iter(parsed.values()))
        except (ValueError, TypeError):
            parsed = args
        out.append({"tool": fn.get("name", ""), "input": parsed})
    if not out:
        return ""
    return json.dumps(out[0] if len(out) == 1 else out)


def generate(system, prompt):
    url, key, name = base_url(), _key(), model()
    if not name:
        return ["error", "config", "OPENAI_MODEL is not set (e.g. gpt-4o-mini, llama3.1, ...)"]
    if not key and not _is_local(url):
        return ["error", "config", "OPENAI_API_KEY is not set"]
    body = json.dumps({
        "model": name,
        "messages": [{"role": "system", "content": str(system)},   # our instructions
                     {"role": "user", "content": str(prompt)}],    # task data
        "temperature": 0.2,
    }).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url + "/chat/completions", body, headers)
    timeout = float(os.environ.get("PAGENT_TIMEOUT", "60"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        return ["error", _classify(e.code, text), f"HTTP {e.code}: {_short(text)}"]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", "network", _short(str(e))]
    except ValueError:
        return ["error", "server", "reply was not JSON"]

    choices = data.get("choices") or []
    if not choices:
        return ["error", "blocked", f"no choices in reply: {_short(json.dumps(data))}"]
    message = choices[0].get("message") or {}
    text = (message.get("content") or "").strip() or _tool_calls_as_text(message)
    if not text:
        return ["error", "blocked", f"empty reply ({choices[0].get('finish_reason')})"]
    return ["ok", text]
