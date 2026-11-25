"""Objective verifiers (verification layer 2): fn(goal, answer, observations) → bool."""
import re


def has_number(goal, answer, observations):
    """Math answers must contain a number."""
    return re.search(r"\d", str(answer)) is not None


COMPUTED = re.compile(r'\(\d+ (?:calc|run-python) "(?:[^"\\]|\\.)*" \(ok ')


def computed_by_tool(goal, answer, observations):
    """Math answers must come from a tool: at least one successful calc (or
    run-python) call in the observations. Language models get arithmetic wrong
    without noticing, so "it was easy" is no reason to skip the tool."""
    if COMPUTED.search(str(observations)):
        return True
    return ["error", "no calc result in the observations: run calc on the expression, then answer with its result"]


def number_is_observed(goal, answer, observations):
    """Every number in the answer should come from a tool observation or the goal
    (catches invented figures). Small numbers (0-10) are ignored: counts/ordinals."""
    seen = set(re.findall(r"\d+(?:\.\d+)?", str(observations).replace(",", "")) +
               re.findall(r"\d+(?:\.\d+)?", str(goal).replace(",", "")))
    for n in re.findall(r"\d+(?:\.\d+)?", str(answer).replace(",", "")):
        if float(n) > 10 and n not in seen:
            return ["error", f"{n} does not appear in any observation"]
    return True


# (N calc "expr" (ok VALUE)) in the observations → VALUE
CALC_RESULT = re.compile(r'\(\d+ calc "(?:[^"\\]|\\.)*" \(ok "?(-?\d+(?:\.\d+)?)')


def answer_is_tool_result(goal, answer, observations):
    """CONCLUSIVE check for math: the answer states a number that calc returned.
    Then a second LLM call asking "is this supported?" adds nothing."""
    results = {float(v) for v in CALC_RESULT.findall(str(observations))}
    said = {float(n) for n in re.findall(r"-?\d+(?:\.\d+)?", str(answer).replace(",", ""))}
    return bool(results & said)


# "saved the summary to report.md", "wrote notes/a.txt", "created out.csv"
CLAIMED_FILE = re.compile(
    r"\b(?:saved|wrote|written|created|stored|generated|exported)\b[^.\n]{0,60}?"
    r"[`'\"]?([\w][\w./-]*\.[A-Za-z0-9]{1,6})\b", re.I)


def claimed_files_exist(goal, answer, observations):
    """EVIDENCE for every goal: a file the answer says was saved/written/created
    must really exist in the workspace. A failed write-file is not a saved file."""
    import os
    import agent_tools
    missing, holes, text = [], [], str(answer)
    for m in CLAIMED_FILE.finditer(text):
        name = m.group(1)
        before = text[max(0, m.start() - 25):m.start()].lower()
        if "://" in name or name.lower().startswith("www.") or name in missing:
            continue
        if re.search(r"\b(not|never|n't|could not|unable|failed to)\b|n't\b", before):
            continue                 # "was not saved to x.md": an honest report, not a claim
        try:
            path = agent_tools._inside(name)
            if not os.path.isfile(path):
                missing.append(name)
                continue
            with open(path, encoding="utf-8", errors="replace") as f:
                hole = agent_tools.placeholder_in(name, f.read(500_000))
            if hole and name not in holes:
                holes.append(f"{name} ({hole})")
        except ValueError:          # outside the workspace: cannot have been written there
            missing.append(name)
        except OSError:
            missing.append(name)
    if missing:
        return ["error", "the answer says these files were written, but they do not exist in the "
                         "workspace: " + ", ".join(missing) + " - write them (and check the result) "
                         "or do not claim them"]
    if holes:
        return ["error", "these files contain a placeholder instead of the real text: "
                         + ", ".join(holes) + " - write the complete text into them"]
    return True
