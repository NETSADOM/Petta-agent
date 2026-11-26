"""Any OpenAI-compatible chat API over plain HTTPS (urllib, no SDK).

Works with OpenAI, OpenRouter, Groq, Together, DeepSeek, Mistral, local Ollama
(http://localhost:11434/v1), LM Studio, vLLM, llama.cpp server, ...

Config (environment variables):
    OPENAI_BASE_URL   default https://api.openai.com/v1
    OPENAI_API_KEY    required, except for local servers (localhost / 127.0.0.1)
    OPENAI_MODEL      required — model names differ per provider, so no guess
    OPENAI_FALLBACK_MODELS  optional, comma-separated: used in order when the
                      current model's DAILY quota runs out (or it does not exist)
    PAGENT_TIMEOUT    seconds, default 60
    PAGENT_RATE_WAIT  max seconds to wait when a rate limit says "try again in Xs" (default 60)

Returns the same shapes as gemini.py: ["ok", text] | ["error", kind, message].

Free tiers often limit TOKENS PER MINUTE (Groq: 8000), which a multi-turn agent
hits after a few calls. The 429 reply says how long to wait; generate() waits
exactly that (plus a little) and tries again, up to 4 times, instead of failing.
"""
import http.client
import json
import os
import re
import time
import urllib.error
import urllib.request

DEFAULT_BASE = "https://api.openai.com/v1"

def base_url():
    # strip(): a .env saved with Windows line endings leaves a "\r" on the value
    return os.environ.get("OPENAI_BASE_URL", DEFAULT_BASE).strip().rstrip("/") or DEFAULT_BASE


def models():
    """OPENAI_MODEL first, then OPENAI_FALLBACK_MODELS (comma-separated), no repeats."""
    names = [os.environ.get("OPENAI_MODEL", "").strip()]
    names += [m.strip() for m in os.environ.get("OPENAI_FALLBACK_MODELS", "").split(",")]
    out = []
    for m in names:
        if m and m not in out:
            out.append(m)
    return out


# models whose DAILY quota ran out (or that do not exist) in this session
EXHAUSTED = set()


def model():
    """The model to use now: the first one in models() not yet exhausted."""
    names = models()
    for m in names:
        if m not in EXHAUSTED:
            return m
    return names[0] if names else ""


def switch_model(reason):
    """Mark the current model as used up; True when another one is left."""
    current = model()
    EXHAUSTED.add(current)
    nxt = model()
    if nxt in EXHAUSTED or nxt == current:
        return False
    try:
        import toolrunner
        toolrunner.audit("model-switch", "llm", current, nxt, _short(reason))
    except Exception:
        pass
    try:
        import sys
        print(f"  · {current}: {_short(reason, 120)} → switching to {nxt}", file=sys.stderr, flush=True)
    except Exception:
        pass
    return True


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


def wait_hint(headers, text):
    """Seconds the provider asks us to wait, or None: the retry-after header,
    or "try again in 10.7s" / "in 1m26s" / "in 735ms" in the error text."""
    try:
        ra = (headers or {}).get("retry-after")
        if ra:
            return float(ra)
    except (TypeError, ValueError, AttributeError):
        pass
    m = re.search(r"try again in\s+(?:(\d+)m(?!s))?\s*(?:([\d.]+)(ms|s))?", str(text), re.I)
    if not m or not (m.group(1) or m.group(2)):
        return None
    secs = 60 * int(m.group(1) or 0)
    if m.group(2):
        secs += float(m.group(2)) / (1000 if m.group(3).lower() == "ms" else 1)
    return secs


def failed_generation(code, text):
    """Groq answers 400 tool_use_failed when a model (gpt-oss) replies in its native
    tool-call format, which this client does not use. The reply itself is in
    failed_generation: it is the model's answer, so it is used as the reply text
    (reply_parser turns {"name": ..., "arguments": ...} into an action).
    Groq's 400 output_parse_failed ("Parsing failed. The model generated output
    that could not be parsed") is the same situation: the model's text is in
    failed_generation. Used as the reply, it goes through the normal format
    repair instead of stopping the goal as a fatal bad request."""
    if code != 400 or not any(c in str(text) for c in ("tool_use_failed", "output_parse_failed")):
        return ""
    try:
        err = json.loads(text).get("error") or {}
    except ValueError:
        return ""
    gen = err.get("failed_generation")
    return gen.strip() if isinstance(gen, str) else ""


def name_of_limit(text):
    t = str(text).lower()
    if "per day" in t or "(tpd)" in t or "(rpd)" in t:
        return "the provider's DAILY limit"
    return "the provider's rate limit"


def _pretty_wait(secs):
    secs = int(round(secs))
    if secs >= 3600:
        return f"{secs // 3600} h {secs % 3600 // 60} min"
    if secs >= 60:
        return f"{secs // 60} min {secs % 60} s"
    return f"{secs} s"


def generate(system, prompt):
    """One chat completion (see _generate); afterwards decides whether the NEXT
    call escalates reasoning effort (see ESCALATE)."""
    try:
        r = _generate(system, prompt)
    finally:
        ESCALATE["next"] = False
    ESCALATE["next"] = (list(r) == ["ok", ""] and bool(LAST_EMPTY["reasoning"].strip()))
    return r


def _generate(system, prompt):
    """One chat completion; waits out short rate limits (see module doc).

    An EMPTY reply with no reasoning (the model ran out of tokens) is asked again
    once; one WITH reasoning is returned at once (see below). If it stays empty it comes
    back as ["ok", ""]: the agent then records an invalid reply, which the model
    sees next turn, instead of stopping the run as if it were a fatal error."""
    limit = float(os.environ.get("PAGENT_RATE_WAIT", "60"))
    LAST_EMPTY["reasoning"] = ""      # only an empty reply of THIS call sets it
    LAST_EMPTY["cut"] = False
    empties = 0
    for _ in range(5):
        r = _generate_once(system, prompt)
        if r[0] == "error" and r[1] == "empty":
            empties += 1
            # With reasoning, the model DECIDED and wrote nothing: the same
            # prompt again comes back empty too (every time in the logs). The
            # callers retry with a better prompt instead: the act repair shows
            # the reasoning, the plan retry, and the checker is asked again.
            if empties >= 2 or LAST_EMPTY["reasoning"].strip():
                return ["ok", ""]
            continue
        if r[0] == "error" and r[1] == "model-not-found" and switch_model(r[2]):
            continue
        if r[0] == "ok" or r[1] != "rate-limit" or len(r) < 4:
            return r[:3]
        wait = r[3]
        if wait is None:
            return r[:3]
        if wait > limit:              # a daily / long limit: next model, or stop and say when to come back
            if switch_model(r[2]):
                continue
            return ["error", "quota",f"{name_of_limit(r[2])} reached at {base_url()}: try again in "
                    f"{_pretty_wait(wait)}, or use another API key or model (OPENAI_MODEL in .env). "
                    f"Provider said: {_short(r[2])}"]
        time.sleep(wait + 0.5)
    return r[:3] if r[0] == "ok" or r[1] != "empty" else ["ok", ""]


LAST_EMPTY = {"reasoning": "", "cut": False}


def last_cut(_=None):
    """True when the latest reply stopped at the token limit (finish_reason
    "length"): a long write-file then never reaches its closing quote, and the
    format repair must say "shorter", not repeat the format."""
    return LAST_EMPTY["cut"]


def last_reasoning(_=None):
    """The hidden reasoning of the latest call if its reply was EMPTY, else "".
    The format repair (core/llm.metta repair-reply) shows it to the model: it
    usually already names the step ("Use calc tool.") it then failed to write."""
    return LAST_EMPTY["reasoning"]


def _audit_empty(name, reason, message, usage, prompt_chars):
    """Why was the reply empty? Written to data/audit.jsonl (event empty-reply):
    finish reason, token counts, and the start and end of the hidden reasoning,
    so an empty reply can be diagnosed instead of only retried."""
    reasoning = str(message.get("reasoning") or message.get("reasoning_content") or "")
    LAST_EMPTY["reasoning"] = reasoning
    detail = {"model": name, "finish_reason": reason, "prompt_chars": prompt_chars,
              "prompt_tokens": usage.get("prompt_tokens"),
              "completion_tokens": usage.get("completion_tokens"),
              "reasoning_chars": len(reasoning),
              "message_keys": sorted(message.keys()),
              # last: audit() keeps 500 characters of detail
              "reasoning_tail": reasoning[-150:], "reasoning_head": reasoning[:100]}
    try:
        import toolrunner
        toolrunner.audit("empty-reply", "llm", "", "empty", json.dumps(detail, ensure_ascii=False))
    except Exception:
        pass


def reasoning_effort(name):
    """gpt-oss spends its output on hidden reasoning first; with the default
    effort it often runs out before writing any answer (an EMPTY reply, a lost
    turn). Our replies are one short S-expression, so "low" is enough.
    PAGENT_REASONING_EFFORT overrides it (low|medium|high); "off" sends nothing.
    Only for gpt-oss: other models may reject the field."""
    if "gpt-oss" not in str(name).lower():
        return None
    effort = os.environ.get("PAGENT_REASONING_EFFORT", "low").strip().lower()
    if effort in ("", "off", "none"):
        return None
    if ESCALATE["next"] and effort == "low":
        return "medium"
    return effort


# After an EMPTY reply that HAD reasoning ("Need list files." and nothing else),
# the very next call (the format repair) runs with medium effort: at low effort
# gpt-oss often stops right after naming the step, and asked again the same way
# it does it again (three in a row ended a run). One call only, then back to low.
ESCALATE = {"next": False}


def request_body(name, system, prompt):
    body = {
        "model": name,
        "messages": [{"role": "system", "content": str(system)},   # our instructions
                     {"role": "user", "content": str(prompt)}],    # task data
        "temperature": 0.2,
    }
    effort = reasoning_effort(name)
    if effort:
        body["reasoning_effort"] = effort
    return body


def _generate_once(system, prompt):
    url, key, name = base_url(), _key(), model()
    if not name:
        return ["error", "config", "OPENAI_MODEL is not set (e.g. gpt-4o-mini, llama3.1, ...)"]
    if not key and not _is_local(url):
        return ["error", "config", "OPENAI_API_KEY is not set"]
    body = json.dumps(request_body(name, system, prompt)).encode("utf-8")
    # an explicit User-Agent: some providers (Groq, behind Cloudflare) refuse
    # urllib's default one with HTTP 403 "error code: 1010"
    headers = {"Content-Type": "application/json", "User-Agent": "P-agent/0.1 (urllib)"}
    if key:
        headers["Authorization"] = "Bearer " + key
    req = urllib.request.Request(url + "/chat/completions", body, headers)
    timeout = float(os.environ.get("PAGENT_TIMEOUT", "60"))
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.load(r)
    except urllib.error.HTTPError as e:
        text = e.read().decode("utf-8", "replace")
        recovered = failed_generation(e.code, text)
        if recovered:
            return ["ok", recovered]
        kind = _classify(e.code, text)
        out = ["error", kind, f"HTTP {e.code}: {_short(text)}"]
        if kind == "rate-limit":
            out.append(wait_hint(e.headers, text))   # dropped again by generate()
        return out
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", "network", _short(str(e))]
    except http.client.InvalidURL as e:          # e.g. a control character in OPENAI_BASE_URL
        return ["error", "config", f"OPENAI_BASE_URL is not a valid URL: {_short(str(e))}"]
    except http.client.HTTPException as e:       # IncompleteRead, a broken status line, ...
        return ["error", "network", f"{type(e).__name__}: {_short(str(e))}"]
    except ValueError:
        return ["error", "server", "reply was not JSON"]

    choices = data.get("choices") or []
    if not choices:
        return ["error", "blocked", f"no choices in reply: {_short(json.dumps(data))}"]
    message = choices[0].get("message") or {}
    text = (message.get("content") or "").strip() or _tool_calls_as_text(message)
    if not text:
        reason = choices[0].get("finish_reason")
        _audit_empty(name, reason, message, data.get("usage") or {}, len(str(prompt)))
        if reason == "content_filter":                       # a real safety block
            return ["error", "blocked", "empty reply (content_filter)"]
        return ["error", "empty", f"empty reply ({reason})"]  # see generate()
    LAST_EMPTY["cut"] = choices[0].get("finish_reason") == "length"
    return ["ok", text]
