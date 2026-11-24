"""Persistence helper for P-agent.

PeTTa has no built-in "save a space to disk", so MeTTa calls these two
functions through py-call. Each atom is stored as one line of MeTTa text
(its `repr`), so the file stays human-readable and loadable with `sread`.
"""
import os


def save_lines(path, lines):
    """Write one atom per line. Writes to a temp file first, then renames,
    so a crash never leaves a half-written knowledge base."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        for line in lines:
            f.write(str(line).replace("\n", "\\n") + "\n")
    os.replace(tmp, path)
    return len(lines)


def load_lines(path):
    """Return the stored atom texts, or [] if the file does not exist yet."""
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]
