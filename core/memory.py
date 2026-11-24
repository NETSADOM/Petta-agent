"""Memory helpers for MeTTa: sensitivity filter, relevance scoring, shortening."""
import os
import re

# Things that must never be written to long-term memory.
SENSITIVE = [
    ("api-key", re.compile(r"AIza[0-9A-Za-z_\-]{20,}|sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{16,}|xox[abprs]-[A-Za-z0-9-]{10,}")),
    # "pass: x", "pwd=x", "token = x", "pin: 1234" — a credential being given a value
    ("credential", re.compile(r"(?i)\b(pass|pw|pwd|pin|token|key|secret|auth)\s*[:=]\s*\S+")),
    ("secret-word", re.compile(r"(?i)\b(password|passwd|pwd|passcode|secret|api[ _-]?key|access[ _-]?token|private[ _-]?key|ssn)\b")),
    ("email", re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")),
    ("card-number", re.compile(r"\b(?:\d[ -]?){13,19}\b")),
    ("long-token", re.compile(r"\b[A-Za-z0-9+/_\-]{40,}\b")),
]

STOPWORDS = {"the", "a", "an", "is", "are", "was", "of", "to", "in", "on", "and", "or",
             "what", "how", "me", "my", "i", "you", "it", "for", "with", "be", "do",
             "please", "can", "this", "that", "at", "by", "from", "as"}


def sensitive_reason(text):
    """Name of the first sensitive pattern found, or "" if the text is clean."""
    text = str(text)
    key = os.environ.get("GEMINI_API_KEY", "")
    if key and key in text:
        return "api-key"
    for name, pattern in SENSITIVE:
        if pattern.search(text):
            return name
    return ""


def is_sensitive(text):
    return sensitive_reason(text) != ""


def _words(text):
    return {w for w in re.findall(r"[a-z0-9]+", str(text).lower().replace("-", " "))
            if w not in STOPWORDS}


def overlap(a, b):
    """Number of meaningful words shared by a and b."""
    return len(_words(a) & _words(b))


def normalize(text):
    return " ".join(str(text).lower().split())


def shorten(text, n=200):
    text = " ".join(str(text).split())
    return text if len(text) <= int(n) else text[:int(n)] + "..."


def is_probability(x):
    """A real number between 0 and 1 (bools and strings don't count)."""
    return isinstance(x, (int, float)) and not isinstance(x, bool) and 0 <= x <= 1
