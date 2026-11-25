"""Small text helpers for MeTTa (things MeTTa has no builtin for)."""
import re


def words(text):
    return set(re.findall(r"[a-z0-9]+", str(text).lower()))


def count_hits(keywords, text):
    """How many of the keywords appear as whole words in text (case-insensitive)."""
    found = words(text)
    return sum(1 for k in keywords if str(k).lower() in found)


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
