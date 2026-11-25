"""Skill folders (SKILL.md) for PeTTa, plus how skill guides are shown to the LLM.

A skill folder:

    skills/code-review/
        SKILL.md          required: frontmatter + a free Markdown guide
        checklist.md      optional extra files, read on demand with read-skill

SKILL.md:

    ---
    name: code-review
    description: review code for bugs, risks and readability
    tools: list-files, read-file, run-python
    keywords: review audit quality          (optional)
    ---
    # Code review
    1. ...

`load_dir` turns every folder into ONE S-expression string that MeTTa reads
with sread (names become symbols, text stays a string); skills.metta then
declares the skills with the same gates as hand-written ones. Nothing here
runs a skill: a skill is still guidance + tools.
"""
import os
import re

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")          # skill names are MeTTa symbols
SYMBOL_RE = re.compile(r"^[A-Za-z0-9_.+-]+$")       # tool names / keywords
TEXT_EXT = {".md", ".txt", ".csv", ".json", ".py", ".sh", ".metta", ".yaml", ".yml"}
MAX_SKILL_MD = 60_000        # a bigger SKILL.md is refused at load (move details to files)
MAX_RESOURCE = 12_000        # characters of one extra file returned by read-skill
MAX_RESOURCES = 50


# ---------------- MeTTa text ----------------
def _str(s):
    """A MeTTa string literal (sread turns \\n, \\" and \\\\ back into the text)."""
    s = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"' + s.replace("\r", "").replace("\n", "\\n").replace("\t", "\\t") + '"'


def _list(items):
    return "(" + " ".join(items) + ")"


# ---------------- SKILL.md ----------------
def _split_list(value):
    value = value.strip().strip("[]")
    return [w.strip().strip("'\"") for w in re.split(r"[,\s]+", value) if w.strip().strip("'\"")]


def parse(text):
    """SKILL.md text → (fields, body). Small frontmatter reader: `key: value`
    lines, and `key:` followed by `- item` lines for lists. No YAML dependency."""
    text = text.lstrip("\ufeff").replace("\r\n", "\n")
    m = re.match(r"^---[ \t]*\n(.*?)\n---[ \t]*(?:\n|$)", text, re.S)
    if not m:
        raise ValueError("missing frontmatter (a --- block with name and description)")
    fields, key = {}, None
    for line in m.group(1).split("\n"):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        item = re.match(r"^\s+-\s*(.+)$", line)
        if item and key:
            fields[key] = (fields[key] + " " + item.group(1)).strip()
            continue
        kv = re.match(r"^([A-Za-z_-]+)\s*:\s*(.*)$", line)
        if not kv:
            raise ValueError(f"cannot read frontmatter line: {line.strip()[:60]}")
        key = kv.group(1).lower().replace("_", "-")
        fields[key] = kv.group(2).strip().strip("'\"") if key in ("name", "description") else kv.group(2).strip()
    return fields, text[m.end():].strip()


def _resources(folder):
    out = []
    for root, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if not d.startswith((".", "__")))
        for f in sorted(files):
            rel = os.path.relpath(os.path.join(root, f), folder).replace(os.sep, "/")
            if rel != "SKILL.md" and os.path.splitext(f)[1].lower() in TEXT_EXT:
                out.append(rel)
    return out[:MAX_RESOURCES]


def _entry(folder):
    path = os.path.join(folder, "SKILL.md")
    with open(path, encoding="utf-8") as fh:
        text = fh.read(MAX_SKILL_MD + 1)
    if len(text) > MAX_SKILL_MD:
        raise ValueError(f"SKILL.md is over {MAX_SKILL_MD} characters: move details to extra files")
    fields, body = parse(text)
    name = fields.get("name", "").lower()
    desc = fields.get("description", "")
    if not NAME_RE.match(name):
        raise ValueError("name must be lowercase-with-dashes, e.g. code-review")
    if name != os.path.basename(folder).lower():
        raise ValueError(f"name '{name}' differs from the folder name '{os.path.basename(folder)}'")
    if not desc:
        raise ValueError("description is required: it is how the LLM decides to use the skill")
    tools = _split_list(fields.get("tools", ""))
    keywords = [k.lower() for k in _split_list(fields.get("keywords", ""))]
    bad = [w for w in tools + keywords if not SYMBOL_RE.match(w)]
    if bad:
        raise ValueError(f"tool names / keywords must be plain words: {bad[:3]}")
    return "(skill-file %s %s %s %s %s %s %s)" % (
        name, _str(desc), _list(tools), _list(keywords), _str(body),
        _str(folder), _list(_str(r) for r in _resources(folder)))


def load_dir(path):
    """Every <path>/*/SKILL.md → "((skill-file ...) (skill-file-error "where" "why") ...)".
    A relative path is relative to the project. A missing folder → "()"."""
    base = path if os.path.isabs(str(path)) else os.path.join(PROJECT, str(path))
    if not os.path.isdir(base):
        return "()"
    out = []
    for d in sorted(os.listdir(base)):
        folder = os.path.join(base, d)
        if not os.path.isfile(os.path.join(folder, "SKILL.md")):
            continue
        try:
            out.append(_entry(folder))
        except (OSError, UnicodeDecodeError, ValueError) as e:
            out.append("(skill-file-error %s %s)" % (_str(d), _str(e)))
    return _list(out)


# ---------------- read-skill ----------------
def split_spec(text):
    """read-skill input → ["skill", NAME] | ["file", NAME, "rel/path"] | ["error", why]."""
    text = str(text).strip().strip("'\"").replace("\\", "/")
    name, _, rel = text.partition("/")
    name = name.strip().lower()
    if not NAME_RE.match(name):
        return ["error", "input is a skill name (e.g. research) or NAME/FILE (e.g. code-review/checklist.md)"]
    rel = rel.strip()
    return ["file", name, rel] if rel else ["skill", name]


def read_resource(folder, rel):
    """One extra file of a skill, confined to the skill's folder."""
    root = os.path.realpath(str(folder))
    target = os.path.realpath(os.path.join(root, str(rel)))
    if os.path.commonpath([root, target]) != root:
        return ["error", "that path leaves the skill folder"]
    if not os.path.isfile(target):
        listed = ", ".join(_resources(root)) or "none"
        return ["error", f"no such file in this skill; its files: {listed}"]
    try:
        with open(target, encoding="utf-8") as fh:
            text = fh.read(MAX_RESOURCE + 1)
    except (OSError, UnicodeDecodeError) as e:
        return ["error", f"cannot read it: {e}"]
    if len(text) > MAX_RESOURCE:
        text = text[:MAX_RESOURCE] + f"\n[cut at {MAX_RESOURCE} characters]"
    return ["ok", text]


# ---------------- what the LLM sees ----------------
def _clip(text, limit):
    text = str(text)
    if len(text) <= limit:
        return text
    return text[:limit].rstrip() + f"\n[... {len(text) - limit} more characters: the full guide is shown while a task uses this skill]"


def render(views, limit=6000):
    """Skill guides as readable text. views: [[name, desc, [[key, text] ...], [files ...]] ...].
    Each skill is cut to `limit` characters (the planner gets short summaries)."""
    if not views:
        return "none"
    order = {"procedure": 0, "output": 1, "on-error": 2, "guide": 3}
    parts = []
    for name, desc, infos, files in views:
        lines = []
        for key, text in sorted(infos, key=lambda kv: order.get(str(kv[0]), 9)):
            lines.append(str(text) if str(key) == "guide" else f"{key}: {text}")
        block = _clip("\n".join(lines), int(limit)) if lines else "(no guide)"
        part = f"### skill {name} - {desc}\n{block}"
        if files:
            part += "\nExtra files, read when needed with (action read-skill \"%s/FILE\"): %s" % (
                name, ", ".join(str(f) for f in files))
        parts.append(part)
    return "\n\n".join(parts)


def render_task(task, desc, views, limit=6000):
    """The CURRENT TASK block of the act prompt."""
    head = f"{task} \"{desc}\""
    if not views:
        return head + "\nSkill guide: none (load one with (action read-skill \"NAME\") if a skill fits)"
    return head + "\nSkill guide(s) - follow them:\n" + render(views, limit)
