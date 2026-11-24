"""P-agent's built-in Python tools. Declared (with permissions) in capabilities/builtin.metta.

Contract: fn(input_text) → ["ok", result] | ["error", "what went wrong"].
Every tool still passes the 5 gates in core/tools.metta (declared, input
checks, call limit, permission, timeout) — the limits below are a second wall.

    calc         arithmetic via the AST (no eval)                         safe
    wiki-search  Wikipedia search + summary (no API key)                  safe
    list-files   files in the workspace                                   safe
    read-file    a text file in the workspace                             safe
    write-file   {"path": ..., "content": ...} into the workspace         needs-approval
    run-python   a Python snippet in a separate, resource-limited process needs-approval
    run-shell    a shell command in the workspace, killed after 60 s      needs-approval
    http-get     GET a public http(s) URL (private addresses refused)     needs-approval
    now          current date and time                                    safe

Workspace: PAGENT_WORKSPACE (default <project>/workspace). Nothing outside it
can be read or written by the file tools. run-shell starts there but is NOT
confined (it is a real shell) — which is why it needs approval.
Every tool returns text: failures (missing file, bad input, timeout, non-zero
exit) come back as ["error", "why"], never as an exception.
"""
import ast
import datetime
import html
import ipaddress
import json
import operator
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

PROJECT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
USER_AGENT = "P-agent/0.1 (educational research agent; urllib)"
MAX_READ = 200_000


def workspace():
    path = os.path.abspath(os.environ.get("PAGENT_WORKSPACE", os.path.join(PROJECT, "workspace")))
    os.makedirs(path, exist_ok=True)
    return path


# ---------------- calc ----------------
_OPS = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul,
        ast.Div: operator.truediv, ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod,
        ast.Pow: operator.pow, ast.USub: operator.neg, ast.UAdd: operator.pos}


def _eval(node):
    if isinstance(node, ast.Expression):
        return _eval(node.body)
    if isinstance(node, ast.Constant) and isinstance(node.value, (int, float)) and not isinstance(node.value, bool):
        return node.value
    if isinstance(node, ast.BinOp) and type(node.op) in _OPS:
        left, right = _eval(node.left), _eval(node.right)
        if isinstance(node.op, ast.Pow) and abs(right) > 1000:
            raise ValueError("exponent too large")
        return _OPS[type(node.op)](left, right)
    if isinstance(node, ast.UnaryOp) and type(node.op) in _OPS:
        return _OPS[type(node.op)](_eval(node.operand))
    raise ValueError("only numbers and + - * / // % ** ( ) are allowed")


def calc(expression):
    text = str(expression).replace("^", "**").replace(",", "")
    try:
        value = _eval(ast.parse(text, mode="eval"))
    except ZeroDivisionError:
        return ["error", "division by zero"]
    except (SyntaxError, ValueError, TypeError, OverflowError) as e:
        return ["error", f"invalid expression: {e}"]
    if isinstance(value, float):
        value = int(value) if value.is_integer() else round(value, 10)
    return ["ok", str(value)]


# ---------------- wikipedia ----------------
def _get_json(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def wiki_search(query):
    q = str(query).strip()
    if not q:
        return ["error", "empty query"]
    try:
        found = _get_json("https://en.wikipedia.org/w/api.php?" + urllib.parse.urlencode(
            {"action": "query", "list": "search", "srsearch": q, "srlimit": 3,
             "format": "json", "utf8": 1}))
        hits = found.get("query", {}).get("search", [])
        if not hits:
            return ["error", f"no Wikipedia results for: {q}"]
        top = hits[0]["title"]
        summary = _get_json("https://en.wikipedia.org/api/rest_v1/page/summary/" +
                            urllib.parse.quote(top.replace(" ", "_")))
    except urllib.error.HTTPError as e:
        return ["error", f"wikipedia HTTP {e.code} (temporary)" if e.code >= 500 or e.code == 429
                else f"wikipedia HTTP {e.code}"]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", f"network unavailable: {e}"]
    others = "; ".join(h["title"] for h in hits[1:])
    text = f"{top}: {summary.get('extract', '').strip()}"
    if others:
        text += f"  (other matches: {others})"
    return ["ok", text]


# ---------------- web search (DuckDuckGo HTML, no key) ----------------
# the "lite" page: plain HTML, no JavaScript (the html/ endpoint answers bots
# with a 202 "anomaly" page)
_DDG = "https://lite.duckduckgo.com/lite/"
_RESULT = re.compile(r"""<a[^>]*href=["']([^"']+)["'][^>]*class=["']result-link["'][^>]*>(.*?)</a>(.*?)(?=<a[^>]*class=["']result-link["']|$)""", re.S)
_SNIPPET = re.compile(r"""class=["']result-snippet["'][^>]*>(.*?)</td>""", re.S)


def _clean(fragment):
    return " ".join(html.unescape(re.sub(r"<[^>]+>", " ", fragment)).split())


def _real_url(href):
    """DuckDuckGo wraps links as /l/?uddg=<real url>."""
    href = html.unescape(href)
    if "uddg=" in href:
        q = urllib.parse.parse_qs(urllib.parse.urlparse(href).query)
        return q.get("uddg", [href])[0]
    return "https:" + href if href.startswith("//") else href


def parse_ddg(page, limit=5):
    out = []
    for href, title, rest in _RESULT.findall(page):
        url = _real_url(href)
        if "duckduckgo.com/y.js" in url:            # ads
            continue
        snip = _SNIPPET.search(rest)
        out.append((_clean(title), url, _clean(snip.group(1)) if snip else ""))
        if len(out) >= limit:
            break
    return out


def web_search(query):
    """Search the web; top results as text: title, url, snippet. Read a page
    with http-get afterwards when the snippet is not enough."""
    q = " ".join(str(query).split())
    if not q:
        return ["error", "empty query"]
    try:
        req = urllib.request.Request(_DDG, urllib.parse.urlencode({"q": q}).encode(),
                                     {"User-Agent": "Mozilla/5.0 (P-agent research tool)",
                                      "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=12) as r:
            page = r.read(600_000).decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        return ["error", f"web search HTTP {e.code}" + (" (temporary)" if e.code >= 500 or e.code in (202, 429) else "")]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", f"network unavailable: {e}"]
    results = parse_ddg(page)
    if not results:
        return ["error", f"no web results for: {q} (try other words, or wiki-search)"]
    lines = [f"{i}. {t}\n   {u}\n   {s}" for i, (t, u, s) in enumerate(results, 1)]
    return ["ok", f"web results for: {q}\n" + "\n".join(lines)]


# ---------------- files (workspace only) ----------------
def _inside(name):
    """Resolve a workspace-relative path; refuse anything that escapes it."""
    name = str(name).strip().strip('"').strip("'")
    if not name or os.path.isabs(name) or name.startswith("~"):
        raise ValueError("use a path relative to the workspace")
    root = workspace()
    path = os.path.realpath(os.path.join(root, name))
    if os.path.commonpath([path, os.path.realpath(root)]) != os.path.realpath(root):
        raise ValueError("path leaves the workspace")
    return path


def list_files(_=None):
    root = workspace()
    rows = []
    for dirpath, _dirs, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            rows.append(f"{os.path.relpath(p, root)} ({os.path.getsize(p)} bytes)")
    return ["ok", "; ".join(rows) if rows else "(workspace is empty)"]


def _os_error(action, name, e):
    """OSError → a sentence the agent can act on."""
    why = {PermissionError: "permission denied", IsADirectoryError: "it is a directory",
           NotADirectoryError: "a part of the path is a file, not a directory",
           FileExistsError: "a part of the path is a file, not a directory",   # from makedirs
           FileNotFoundError: "no such file or directory"}.get(type(e), e.strerror or str(e))
    return ["error", f"cannot {action} {name}: {why}"]


def read_file(name):
    try:
        path = _inside(name)
    except ValueError as e:
        return ["error", str(e)]
    if os.path.isdir(path):
        return ["error", f"{name} is a directory, not a file (use list-files)"]
    if not os.path.isfile(path):
        return ["error", f"no such file: {name} (use list-files)"]
    try:
        with open(path, "rb") as f:
            raw = f.read(MAX_READ + 1)
    except OSError as e:
        return _os_error("read", name, e)
    if b"\x00" in raw[:8192]:
        return ["error", f"{name} is a binary file ({os.path.getsize(path)} bytes); only text files can be read"]
    text = raw.decode("utf-8", errors="replace")
    if not text:
        return ["ok", f"(the file {name} is empty)"]
    return ["ok", text[:MAX_READ] + ("\n...[file truncated]" if len(text) > MAX_READ else "")]


def write_file(spec):
    try:
        data = json.loads(str(spec))
        if not isinstance(data, dict):
            raise TypeError("not a JSON object")
        name, content = data["path"], data["content"]
        content = content if isinstance(content, str) else json.dumps(content)
    except (ValueError, KeyError, TypeError) as e:
        return ["error", f'input must be JSON {{"path": "...", "content": "..."}}: {e}']
    try:
        path = _inside(name)
    except ValueError as e:
        return ["error", str(e)]
    if os.path.isdir(path):
        return ["error", f"cannot write {data['path']}: it is a directory"]
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
    except OSError as e:
        return _os_error("write", data["path"], e)
    return ["ok", f"wrote {len(content)} characters to {os.path.relpath(path, workspace())}"]


# ---------------- python (separate process, limited) ----------------
def _limits():
    import resource
    resource.setrlimit(resource.RLIMIT_CPU, (10, 10))                    # CPU seconds
    resource.setrlimit(resource.RLIMIT_AS, (512 * 2**20, 512 * 2**20))   # memory
    resource.setrlimit(resource.RLIMIT_FSIZE, (10 * 2**20, 10 * 2**20))  # file size
    resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))                  # no fork bombs


def _python():
    """The real python3. NOT sys.executable: inside PeTTa, Python is embedded in
    SWI-Prolog, so sys.executable is swipl."""
    import shutil
    return shutil.which("python3") or "/usr/bin/python3"


def run_python(code):
    """Runs in a NEW process: isolated mode (-I), the WORKSPACE as cwd (so it can
    open the files the other tools see, e.g. open("sales.csv")), minimal
    environment (no API keys), CPU/memory/file limits, 15 s wall clock.
    Not a full sandbox: it can still read files your user can read and use the
    network — which is why this tool needs approval."""
    code = str(code)
    if code.startswith("```"):
        code = re.sub(r"^```[a-zA-Z]*\n?|```$", "", code.strip()).strip()
    try:
        p = subprocess.run([_python(), "-I", "-c", code], cwd=workspace(), capture_output=True,
                           text=True, timeout=15, env={"PATH": "/usr/bin:/bin"},
                           preexec_fn=_limits)
    except subprocess.TimeoutExpired:
        return ["error", "python timed out after 15s"]
    except OSError as e:
        return ["error", f"cannot start python: {e}"]
    out = (p.stdout or "")[-8000:]
    err = (p.stderr or "")[-3000:]
    if p.returncode != 0:
        return ["error", f"python exited {p.returncode}: {err.strip() or out.strip()}"]
    return ["ok", out.strip() or "(no output — use print())"]


# ---------------- shell (separate process group, killed on timeout) ----------------
SHELL_TIMEOUT = float(os.environ.get("PAGENT_SHELL_TIMEOUT", "60"))
SHELL_MAX_OUT = 12_000
_SECRET_ENV = re.compile(r"(?i)key|token|secret|password|passwd|credential")


def _shell_env():
    """The user's environment minus anything that looks like a secret."""
    return {k: v for k, v in os.environ.items() if not _SECRET_ENV.search(k)}


# ---- which shell commands may run WITHOUT asking you ----
# Allow-list, not a block-list: a command runs unasked only if EVERY part of it
# is a known read-only program used in a read-only way. Anything else — rm, mv,
# cp, chmod, git push/reset, sed -i, curl, a script, a redirect (>), $(...) —
# is treated as possibly destructive and needs your y/N first.
_READ_ONLY = set("""ls cat head tail wc grep egrep fgrep rg pwd date whoami id uname hostname
which type file stat du df tree cut tr uniq diff cmp comm md5sum sha1sum sha256sum basename
dirname realpath readlink nl column jq true false test [ seq echo printf ps free uptime nproc
lscpu sort find git python3 python node""".split())
_FIND_WRITES = ("-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls")
_GIT_READ = {"status", "log", "diff", "show", "ls-files", "rev-parse", "blame", "shortlog",
             "describe", "grep", "branch", "remote", "tag"}


def _segment_is_read_only(words):
    if not words:
        return True
    cmd, args = words[0], words[1:]
    if "/" in cmd or "=" in cmd or cmd not in _READ_ONLY:
        return False                                   # ./script, FOO=1 cmd, unknown program
    if cmd == "find":
        return not any(a.startswith(_FIND_WRITES) for a in args)
    if cmd == "sort":
        return not any(a == "-o" or a.startswith(("--output", "-o")) for a in args)
    if cmd in ("python3", "python", "node"):
        return args in (["--version"], ["-V"])
    if cmd == "git":
        sub = [a for a in args if not a.startswith("-")]
        if not sub or sub[0] not in _GIT_READ:
            return False
        # branch/remote/tag only list: any further non-flag word would create/delete
        return not (sub[0] in ("branch", "remote", "tag") and len(sub) > 1)
    return True


def shell_is_read_only(command):
    """True when the command can only READ: then run-shell needs no approval."""
    import shlex
    text = str(command).strip()
    if not text or "`" in text or "$(" in text or "<(" in text or ">(" in text:
        return False
    try:
        lex = shlex.shlex(text.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        tokens = list(lex)
    except ValueError:                                 # unbalanced quotes
        return False
    segment = []
    for tok in tokens:
        if tok in ("|", "||", "&&", ";"):
            if not _segment_is_read_only(segment):
                return False
            segment = []
        elif tok and set(tok) <= set("<>&|;()"):       # >, >>, &>, &, (, ) ...
            return False
        else:
            segment.append(tok)
    return _segment_is_read_only(segment)


def write_is_new_file(spec):
    """True when write-file would only CREATE a new file inside the workspace.
    Overwriting an existing file needs your approval. Input write_file would
    refuse anyway (bad JSON, a path outside the workspace) writes nothing, so it
    is passed on unasked and the tool reports the problem to the agent."""
    try:
        data = json.loads(str(spec))
        path = _inside(data["path"])
    except Exception:
        return True
    return not os.path.exists(path)


def _tail(text, limit):
    text = text or ""
    return text if len(text) <= limit else f"...[{len(text) - limit} chars cut]\n" + text[-limit:]


def _kill_tree(p):
    try:
        if os.name == "posix":
            import signal
            os.killpg(p.pid, signal.SIGKILL)       # the shell AND everything it started
        else:
            p.kill()
    except (ProcessLookupError, PermissionError, OSError):
        pass


def run_shell(command, timeout=None):
    """Run a shell command with the workspace as working directory.
    Always returns text: exit code + stdout + stderr. Never raises.
    A non-zero exit is reported as an error so the agent notices it, but the
    output is still included. On timeout the whole process group is killed
    (a plain kill would leave grandchildren holding the pipes open)."""
    command = str(command).strip()
    if command.startswith("```"):
        command = re.sub(r"^```[a-zA-Z]*\n?|```$", "", command).strip()
    if not command:
        return ["error", "empty command"]
    limit = float(timeout) if timeout else SHELL_TIMEOUT
    try:
        p = subprocess.Popen(command, shell=True, cwd=workspace(), env=_shell_env(),
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, errors="replace",
                             start_new_session=(os.name == "posix"))
    except OSError as e:
        return ["error", f"cannot start the shell: {e}"]
    try:
        out, err = p.communicate(timeout=limit)
    except subprocess.TimeoutExpired:
        _kill_tree(p)
        try:
            out, err = p.communicate(timeout=5)
        except (subprocess.TimeoutExpired, OSError, ValueError):
            out, err = "", ""
        partial = _tail((out or "") + (err or ""), 2000).strip()
        return ["error", f"command killed: still running after {limit:g}s"
                + (f"; partial output:\n{partial}" if partial else "; no output")]
    except Exception as e:                       # e.g. interrupted read
        _kill_tree(p)
        return ["error", f"command failed while running: {type(e).__name__}: {e}"]
    code = p.returncode
    parts = [f"exit code {code}"]
    if out and out.strip():
        parts.append("stdout:\n" + _tail(out.rstrip(), SHELL_MAX_OUT))
    if err and err.strip():
        parts.append("stderr:\n" + _tail(err.rstrip(), SHELL_MAX_OUT // 2))
    if len(parts) == 1:
        parts.append("(no output)")
    text = "\n".join(parts)
    if code == 127:
        text += "\n(hint: exit code 127 means the command was not found)"
    elif code < 0:
        text += f"\n(the command was killed by signal {-code})"
    return ["ok" if code == 0 else "error", text]


# ---------------- http GET (public addresses only) ----------------
def _public_host(host):
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        raise ValueError(f"cannot resolve {host}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast:
            raise ValueError(f"{host} is a private/local address — refused")


class _CheckedRedirect(urllib.request.HTTPRedirectHandler):
    """A public URL may redirect to http://127.0.0.1/... — check every hop."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parts = urllib.parse.urlparse(newurl)
        if parts.scheme not in ("http", "https") or not parts.hostname:
            raise ValueError("redirect to a non-http(s) URL — refused")
        _public_host(parts.hostname)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_CheckedRedirect)


def http_get(url):
    url = str(url).strip()
    parts = urllib.parse.urlparse(url)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        return ["error", "only http(s) URLs are allowed"]
    try:
        _public_host(parts.hostname)
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with _OPENER.open(req, timeout=10) as r:
            ctype = r.headers.get("Content-Type", "")
            body = r.read(100_000).decode("utf-8", errors="replace")
            status = r.status
    except ValueError as e:
        return ["error", str(e)]
    except urllib.error.HTTPError as e:
        return ["error", f"HTTP {e.code}" + (" (temporary)" if e.code >= 500 or e.code == 429 else "")]
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        return ["error", f"network unavailable: {e}"]
    if "html" in ctype:
        body = re.sub(r"(?s)<(script|style).*?</\1>", " ", body)
        body = html.unescape(re.sub(r"<[^>]+>", " ", body))
        body = " ".join(body.split())
    return ["ok", f"HTTP {status} {ctype}\n{body}"]


def now(_=None):
    return ["ok", datetime.datetime.now().strftime("%A %Y-%m-%d %H:%M")]
