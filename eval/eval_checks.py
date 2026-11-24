"""Expected-answer checks for the live evaluation."""
import re


def _norm(text):
    t = str(text).lower()
    t = re.sub(r"(?<=\d)[,\s](?=\d{3}\b)", "", t)     # 9,680 / 9 680 → 9680
    return t


def contains_all(answer, needles):
    a = _norm(answer)
    return all(_norm(n) in a for n in needles)
