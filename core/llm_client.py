"""Chooses the LLM provider. P-agent talks to this, never to a provider directly.

    PAGENT_PROVIDER = gemini | openai     (openai = any OpenAI-compatible API)

If PAGENT_PROVIDER is not set: gemini when GEMINI_API_KEY is set, otherwise
openai when OPENAI_API_KEY or OPENAI_BASE_URL is set, otherwise gemini (which
then reports a clear config error).
"""
import os

import gemini
import openai_compat

CALLS = {"n": 0}


def provider(_=None):
    p = os.environ.get("PAGENT_PROVIDER", "").strip().lower()
    if p in ("gemini", "openai"):
        return p
    if os.environ.get("GEMINI_API_KEY", "").strip():
        return "gemini"
    if os.environ.get("OPENAI_API_KEY", "").strip() or os.environ.get("OPENAI_BASE_URL", "").strip():
        return "openai"
    return "gemini"


def generate(system, prompt):
    CALLS["n"] += 1
    if provider() == "openai":
        return openai_compat.generate(system, prompt)
    r = gemini.generate(system, prompt)
    if r[0] == "error" and r[1] == "config":
        return ["error", "config", "no LLM configured: set GEMINI_API_KEY, or "
                "OPENAI_API_KEY + OPENAI_MODEL (+ OPENAI_BASE_URL for other providers)"]
    return r


def configured(_=None):
    if provider() == "openai":
        return bool(openai_compat.model()) and (
            bool(os.environ.get("OPENAI_API_KEY", "").strip()) or openai_compat._is_local(openai_compat.base_url()))
    return bool(os.environ.get("GEMINI_API_KEY", "").strip())


def describe(_=None):
    if provider() == "openai":
        return f"openai-compatible · {openai_compat.model() or '(OPENAI_MODEL not set)'} @ {openai_compat.base_url()}"
    return f"gemini · {os.environ.get('GEMINI_MODEL', gemini.DEFAULT_MODEL)}"


def calls(_=None):
    return CALLS["n"]


def reset_calls(_=None):
    CALLS["n"] = 0
    return True


is_temporary = gemini.is_temporary
extract_sexpr = gemini.extract_sexpr
