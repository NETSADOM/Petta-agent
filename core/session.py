"""What happened earlier in THIS session (since the CLI started).

Several goals typed one after another often build on each other ("now append
that to the report"). Working memory (&wm) is cleared per goal, so the last few
goals and their outcomes are kept here and shown to the model.

Bounded on purpose: at most MAX_TASKS entries, each at most MAX_CHARS, so the
prompt stays small however long the session runs. Long-term memory (&kb,
episodes) is separate and survives restarts.
"""
from collections import deque

MAX_TASKS = 5
MAX_CHARS = 300
_HISTORY = deque(maxlen=MAX_TASKS)
_COUNT = {"n": 0}


def _short(text, n):
    text = " ".join(str(text).split())
    return text if len(text) <= n else text[:n] + "..."


def record(goal, outcome):
    """outcome: the run's result atom as text, e.g. (done "the answer")."""
    _COUNT["n"] += 1
    _HISTORY.append((_COUNT["n"], _short(goal, 150), _short(outcome, MAX_CHARS)))
    return _COUNT["n"]


def summary(_=None):
    if not _HISTORY:
        return "none (this is the first task of the session)"
    return "\n".join(f"task {n}: goal: {g}\n        outcome: {o}" for n, g, o in _HISTORY)


def count(_=None):
    return _COUNT["n"]


def clear(_=None):
    _HISTORY.clear()
    _COUNT["n"] = 0
    return True
