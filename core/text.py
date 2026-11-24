"""Small text helpers for MeTTa (things MeTTa has no builtin for)."""
import re


def words(text):
    return set(re.findall(r"[a-z0-9]+", str(text).lower()))


def count_hits(keywords, text):
    """How many of the keywords appear as whole words in text (case-insensitive)."""
    found = words(text)
    return sum(1 for k in keywords if str(k).lower() in found)
