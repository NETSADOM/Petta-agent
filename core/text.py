"""Text helpers for MeTTa (things MeTTa has no builtin for): skill matching,
memory (sensitivity filter, relevance, shortening) and the notebook."""
import os
import re


def words(text):
    return set(re.findall(r"[a-z0-9]+", str(text).lower()))


# Words of a skill's NAME/DESCRIPTION that say nothing about it. Explicit
# keywords are never filtered: a skill author may list "who" or "what" on purpose.
FILLER = {"the", "a", "an", "is", "are", "was", "of", "to", "in", "on", "and", "or",
          "what", "how", "me", "my", "i", "you", "it", "its", "for", "with", "be", "do",
          "please", "can", "this", "that", "at", "by", "from", "as", "into", "over",
          "make", "use", "get", "give", "any", "all", "some", "about", "when", "then",
          "your", "their", "them", "one", "more", "other", "than", "not", "no", "so"}


def stem(word):
    """Very light stemming so word forms meet: calculating/calculate → calculat,
    files/file → fil, summaries/summary → summary, processes/process → process."""
    w = str(word).lower()
    for suffix, repl in (("ies", "y"), ("ing", ""), ("ed", ""), ("es", ""), ("s", "")):
        if w.endswith(suffix) and len(w) - len(suffix) >= 3 and not (suffix == "s" and w.endswith("ss")):
            w = w[: -len(suffix)] + repl
            break
    if len(w) > 3 and w.endswith("e"):
        w = w[:-1]
    return w


def skill_score(keywords, name, description, goal):
    """How well a skill fits a goal: distinct goal stems that hit the skill's
    keywords, its name parts or the content words of its description."""
    goal_stems = {stem(w) for w in words(goal)}
    terms = {stem(k) for k in keywords}
    terms |= {stem(w) for w in words(str(name).replace("-", " ")) | words(description)
              if w not in FILLER and len(w) > 2}
    return len(terms & goal_stems)


SEQUENCE = re.compile(r"\b(and|then|after|before|also|plus)\b|[,;:\n]", re.I)


def is_simple_goal(goal, max_words=12):
    """One short request, no list of steps: it needs no LLM-made plan.
    "what is 15 percent of 2480" → True; "find papers, summarize them and save" → False."""
    text = str(goal).strip()
    return 0 < len(text.split()) <= int(max_words) and not SEQUENCE.search(text)


BLOCKED = re.compile(
    r"\b(blocked|cannot (?:continue|proceed|finish|complete)|can't (?:continue|proceed)|"
    r"need(?:s|ed)? (?:you|the user|your|to know|more information)|please (?:provide|tell|let me know|specify)|"
    r"did not answer|didn't answer|no answer|missing information|waiting for)\b", re.I)


def reports_blocked(answer):
    """The final answer says what is blocked / what is needed, instead of guessing."""
    return bool(BLOCKED.search(str(answer)))


# ================================================================ memory
# used by core/memory.metta: what may be stored, and what is relevant
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


# ================================================================ notebook
# used by the note tool (core/agent.metta)
# The agent's notebook: findings that must survive history trimming.
#
# Old steps are shortened and then dropped from the prompt; a long task forgets
# what turn 3 found. Notes are kept for the whole run and shown every turn.
#
#     note "found: the API needs a key"        a discovery
#     note "file: report.md (the summary)"     a file that matters
#     note "decision: use the 2024 data"       a choice made, and why
#     note "todo: add the totals table"        remaining work
#     note "blocker: no access to the server"  what stops progress
#     note "drop: n3"                          remove note n3 (e.g. a finished todo)
#
# parse(text) → ["add", KIND, TEXT] | ["drop", N] | ["error", WHY]
NOTE_KINDS = ("found", "file", "decision", "todo", "blocker")
NOTE_MAX_CHARS = 250          # per note; the notebook holds at most config note-max notes

_NOTE = re.compile(r"^\s*([a-zA-Z]+)\s*:\s*(.+)$", re.S)


def parse_note(text):
    m = _NOTE.match(str(text))
    if not m:
        return ["error", 'write "KIND: text" with KIND one of ' + ", ".join(NOTE_KINDS)
                + ', or "drop: nN" to remove a note']
    kind, body = m.group(1).lower(), " ".join(m.group(2).split())
    if kind == "drop":
        num = re.fullmatch(r"n?(\d+)", body.strip().lower())
        return ["drop", int(num.group(1))] if num else ["error", 'drop needs a note id, e.g. "drop: n3"']
    if kind not in NOTE_KINDS:
        return ["error", f"unknown kind {kind}: use one of " + ", ".join(NOTE_KINDS)]
    if len(body) > NOTE_MAX_CHARS:
        body = body[:NOTE_MAX_CHARS - 3] + "..."
    return ["add", kind, body]


def written_note(spec):
    """The automatic note for a successful write-file: "wrote PATH", or ""."""
    import json
    try:
        data = json.loads(str(spec), strict=False)
    except ValueError:
        return ""
    path = str(data.get("path", "")).strip() if isinstance(data, dict) else ""
    return f"wrote {path}" if path else ""


def unanswered_note(question):
    q = " ".join(str(question).split())
    q = q if len(q) <= 180 else q[:177] + "..."
    return f"the user did not answer: {q} - do not guess it; report it as blocked"


def render_notes(notes):
    """((N KIND "text") ...) as MeTTa text → one line per note, or a hint when empty."""
    text = str(notes).strip()
    if text in ("", "()"):
        return 'empty - add with (action note "found: ...")'
    return text
