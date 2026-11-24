"""Objective verifiers (verification layer 2): fn(goal, answer, observations) → bool."""
import re


def has_number(goal, answer, observations):
    """Math answers must contain a number."""
    return re.search(r"\d", str(answer)) is not None


def number_is_observed(goal, answer, observations):
    """Every number in the answer should come from a tool observation or the goal
    (catches invented figures). Small numbers (0-10) are ignored: counts/ordinals."""
    seen = set(re.findall(r"\d+(?:\.\d+)?", str(observations).replace(",", "")) +
               re.findall(r"\d+(?:\.\d+)?", str(goal).replace(",", "")))
    for n in re.findall(r"\d+(?:\.\d+)?", str(answer).replace(",", "")):
        if float(n) > 10 and n not in seen:
            return ["error", f"{n} does not appear in any observation"]
    return True
