# P-agent

A small autonomous agent whose **brain is written in MeTTa** (run by PeTTa),
with any LLM (Gemini or any OpenAI-compatible API) proposing actions, and
Python only as thin helpers. Long-term memory is a PeTTa **AtomSpace**.

## Architecture (MeTTa-first)

```
 you ─► main.metta (CLI) ─► agent.metta: the agentic loop, in MeTTa
          context.metta  builds what the LLM sees from the AtomSpaces
          llm_client.py  → Gemini  |  any OpenAI-compatible API
          reply_parser   S-expression or JSON tool call → atom
          llm.metta      validates the proposal (shape, known tool)
          tools.metta    5 gates: declared · input · limit · permission · run
          capabilities/  the tools + skills (Python and MeTTa tools)
          memory.metta   &kb AtomSpace: learn (gated), recall (relevant only)
          recovery/verify  retries, alternatives, learned fixes, 3-layer checks
```

Three AtomSpaces: `&caps` (tools, skills, config), `&wm` (this goal: plan,
tasks, steps), `&kb` (**long-term memory**: facts, preferences, episodes,
learned fixes — saved to `data/kb.metta` after every goal, reloaded at start).

- **MeTTa / PeTTa** owns the loop, the knowledge and every decision.
- **The LLM** proposes. It never runs anything itself.
- **Python** does what MeTTa can't: HTTP, files, processes, tool bodies.

## LLM providers (`core/llm_client.py`)

| Provider | Environment variables |
|---|---|
| Gemini | `GEMINI_API_KEY` (+ optional `GEMINI_MODEL`) |
| any OpenAI-compatible API | `OPENAI_API_KEY`, `OPENAI_MODEL`, `OPENAI_BASE_URL` |

`PAGENT_PROVIDER=gemini|openai` forces one; otherwise Gemini if its key is
set, else OpenAI-compatible. Examples for `OPENAI_BASE_URL`:
OpenAI `https://api.openai.com/v1` (default), OpenRouter
`https://openrouter.ai/api/v1`, Groq `https://api.groq.com/openai/v1`,
Ollama `http://localhost:11434/v1` (no key needed for local servers).
`OPENAI_MODEL` is required — model names differ per provider, so none is guessed.
Both providers return the same `(ok text)` / `(error KIND msg)`, so recovery,
verification and the loop don't know which one is used.

**Tool parsing (`core/reply_parser.py`):** S-expressions are the protocol,
but JSON replies and native OpenAI `tool_calls` are translated into the same
atoms: `{"tool": "calc", "input": "2+3"}` → `(action calc "2+3")`,
`{"final": ".."}`, `{"task_done": "t1"}`, `{"plan": [...]}`, `{"verdict": ..}`.
Translated proposals go through exactly the same validation and gates.

## Built-in tools and skills (`capabilities/`)

| Tool | Level | Notes |
|---|---|---|
| `calc` | safe | AST evaluator, no `eval`; gate pattern allows only arithmetic |
| `web-search` | safe | DuckDuckGo (lite page), no key: top 5 results as title, url, snippet; read a page with `http-get` |
| `wiki-search` | safe | Wikipedia search + summary, no key |
| `delegate` | safe | **core, sub-agent**: a helper agent does a self-contained sub-task in a fresh context (own plan, steps, `sub-agent-turns` 20) and returns its answer; the parent's working memory is restored; helpers can't start helpers and store no episodes. **Off by default** (`(config delegate on)` offers it to the model): a helper re-plans and re-fetches, which made 40-turn goals slower |
| `list-files`, `read-file` | safe | only inside the workspace (`PAGENT_WORKSPACE`, default `workspace/`); `..` and absolute paths refused; missing file, directory, binary and empty files answered in words |
| `write-file` | needs-approval | JSON `{"path", "content"}`, workspace only; bad JSON, bad path and OS errors (permission, path through a file) answered in words |
| `run-python` | needs-approval | separate `python3 -I` process in the workspace folder, empty env (no keys), CPU/memory/file/process limits, 15 s |
| `run-shell` | needs-approval | `sh` in the workspace, no stdin, env without `*KEY*/*TOKEN*/*SECRET*/*PASSWORD*`; returns exit code + stdout + stderr; non-zero exit → `(error ..)` with the output; after 60 s (`PAGENT_SHELL_TIMEOUT`) the whole process group is killed and the partial output returned; never retried |
| `send-message` | safe | **core** (`core/agent.metta`): shows the user a message without waiting |
| `ask-user` | safe | **core**: asks and waits for one line; EOF, Ctrl+C or no answer within 600 s (`PAGENT_ASK_TIMEOUT`, terminal only) → `(error "the user did not answer: ...")`. The `(ask-user "q")` reply is the same tool |
| `http-get` | needs-approval | public http(s) only; private/loopback addresses refused, **also after redirects**. Web pages come back as readable text (head, scripts, styles, menus removed; the `<article>`/`<main>` part preferred); PDFs and other binary files are refused before downloading, and arXiv PDF links are fetched as their abstract page. An approved URL is not asked again in the session; `a` at the prompt allows every URL for the session |
| `arxiv-search` | safe | arXiv API, no key: title, authors, date, link and full abstract of each paper in one call. `latest cs.LG \| 5` = the newest 5 machine-learning papers; plain words = most relevant |
| `now` | safe | date and time |
| `memory-search` | safe | **MeTTa tool**: queries the `&kb` AtomSpace (relevant facts + past tasks) |
| `memory-store` | safe | **MeTTa tool**: `(capital kenya nairobi)` → `&kb`, through the same memory gates |

**Every tool returns text.** Failures come back as `(error "why")`, which the
agent reads as an observation, and they never crash it: `toolrunner` catches
everything a tool raises (including `SystemExit` and `KeyboardInterrupt`),
times out hung tools, and reports an unknown tool as
`(error (unknown-tool NAME (available ...)))`. Tests: `tests/test_agent_tools.metta`.
Tool option `retry no` turns off automatic retries of temporary errors for
tools with side effects (`run-shell`) or a person (`ask-user`, `send-message`).

Skills: `research`, `math`, `file-analysis`, `data-analysis`, `coding`, `shell`,
`summarization`, `papers` (plus the folder skill `skills/code-review`) — each with tools, keywords, procedure, expected output and
error strategy; `research` and `math` have objective verifiers
(`capability_checks.py`: numbers in the answer must appear in observations /
a math answer must contain a number).

MeTTa tools: `(declare-tool NAME "desc" LEVEL metta)` +
`(= (metta-tool NAME $input) (ok ...))`. They run inside PeTTa, so they can
query any AtomSpace. Add your own tools and skills in `my_capabilities.metta`.

## Context (`core/context.metta`)

**Planning.** The CLI sets `(config fast-plan on)`: a short goal with no list of
steps (at most 12 words, no "and"/"then"/commas, e.g. "what is 15 percent of
2480") gets a one-task plan with its best-matching skill, **without** a planning
LLM call. Longer goals are planned by the model, asked for the fewest tasks
(usually 1-3, one per kind of work). A batch may close tasks in the same turn:
`(actions (task-done t1) (action write-file "..."))`.

PeTTa builds every prompt from the AtomSpaces: goal, plan + current task with
its skill guide, steps, tool/skill catalogs, relevant skills, **relevant**
facts from `&kb`, similar past tasks, recovery hints, and
`PROGRESS: turn N of 40` (with "FEW TURNS LEFT: finish now" in the last 3).
Steps are **windowed**: the last `context-steps` (8) in full, each clipped to
`context-obs-chars` (600), except the steps of the **latest turn**, which share
`context-fresh-chars` (12 000) so a fetched page is read once, in full; the `context-older-steps` (20) before them in
**short form** (`context-older-chars`, 120), so what turn 3 found is still
visible at turn 25; anything older only counted in
`(earlier-steps 22 ok 18 failed 4 (failed-tools (flaky)))`. **Every
section of every prompt is capped** in `prompts.py`: goal 2 000, session 1 500,
plan 2 000, current task + skill guides 9 000, skill list 2 500, notebook 4 500,
step history 28 000 (newest kept), recovery hints 1 500, tool catalog 5 000,
facts 3 000; the verify prompt's evidence 40 000 and answer 8 000. The act
prompt can never exceed about 60 000 characters, whatever the input. Tool output
is cut at `max-output` before it is even stored. Stored data is never clipped,
and verification sees every step (up to 4 000 characters of each).

**Measured** (tests/test_context.metta): a 30-step run with 1 000-character
observations: 17 135 characters with every step in full (already capped by
`STEPS_MAX`) vs 7 367 windowed (**−57 %**), on every LLM call — while the
20 most recent older steps stay readable.
Memory recall cost (tests/bench_memory.metta): 2.8 ms at 50 facts, 34 ms at
500 (the cap) — negligible next to an LLM call, so it was not optimised.

## Layout

```
run.sh                  run .metta files with ~/PeTTa (set PETTA_HOME to override)
core/store.py           save_lines / load_lines (atomic write)
core/store.metta        (save-space &kb path)  (load-space &kb path)
core/schema.metta       knowledge shape + reasoning rules (see below)
core/gemini.py          Gemini REST call (urllib), error classification, S-expr extraction
core/openai_compat.py   any OpenAI-compatible /chat/completions API
core/llm_client.py      provider choice (PAGENT_PROVIDER), call counter
core/reply_parser.py    S-expression / JSON / tool_calls → one S-expression
core/context.metta      what the LLM sees: windowed steps, relevant memory, skills
capabilities/agent_tools.py  built-in Python tools
capabilities/builtin.metta   tool + skill declarations, MeTTa memory tools
capabilities/capability_checks.py  objective verifiers
core/prompts.py         system prompts + context formatting (<data> fencing)
core/llm.metta          ask Gemini, parse + validate replies, load plans (see below)
core/agent.metta        THE LOOP: propose → validate → permit → execute → record → repeat
core/io_helper.py       console input (confirm y/N, read goal) + the send-message / ask-user tools
core/session.py         the last 5 goals of this CLI session (shown to the model)
core/tools.metta        tool registry, input validation, limits, permission gate
core/toolrunner.py      runs a tool with timeout + output cap, writes data/audit.jsonl; error classes + backoff
core/skills.metta       skill registry + discovery (keyword scoring, availability)
core/text.py            text helpers: skill matching, memory sensitivity filter + relevance, notebook parsing
core/memory.metta       selective learning, episodes, relevant recall, size limit
core/recovery.metta     error classes, retry, alternatives, hints, learned fixes
core/verify.metta       3-layer verification of final answers
core/ui.py              CLI renderer (the only file that decides how output looks), cancel check
main.metta              CLI:  sh run.sh main.metta
my_capabilities.metta   YOUR tools and skills (imported by main.metta)
tests/fake_tools.py     test-only fake tools (fake_openai.py: a local fake LLM server)
tests/test_*.metta      one file per part; test_agent_tools, test_long_task and
                        test_subagent cover the requirements end to end
tests/run_tests.sh      runs all, in order, fails on any ❌ (no API key needed)
eval/                   offline + live evaluation (sh eval/run_eval.sh)
scripts/drive_session.py  plays the user in one CLI session (for recording logs)
scripts/record_logs.sh  records the 3 example tasks in logs/goals.txt
logs/                   session transcripts (logs/session-*.log) + the recorded goals
data/                   saved knowledge bases, audit log (git-ignored)
```

## Run (Linux or WSL; a POSIX shell, not PowerShell)

Requirements: [PeTTa](https://github.com/trueagi-io/PeTTa) with SWI-Prolog and
Python 3 (janus). PeTTa is expected at `~/PeTTa` (override with `PETTA_HOME`).
No Python packages beyond the standard library.

```bash
git clone https://github.com/NETSADOM/PeTTa-Agent.git && cd PeTTa-Agent
echo 'GEMINI_API_KEY=...' > .env   # or OPENAI_API_KEY + OPENAI_MODEL (+ OPENAI_BASE_URL); .env is git-ignored
sh run.sh main.metta          # start the agent: type goals, one after another
sh tests/run_tests.sh         # expect: ALL TESTS PASSED (no key needed)
sh run.sh some_file.metta     # run any MeTTa file
```

## Requirements → where they live

| Requirement | Code | Test |
|---|---|---|
| Tools: read/write file, shell, message, ask; every result is text, never a crash | `capabilities/agent_tools.py`, `core/io_helper.py`, `core/toolrunner.py` | `tests/test_agent_tools.metta` |
| Turn: prompt → model → parse calls → run → results into next turn | `core/agent.metta`, `core/context.metta`, `core/reply_parser.py` | `tests/test_agent.metta`, `tests/test_long_task.metta` |
| Only known tools run; unknown names come back as errors | `core/tools.metta` `execute` | `tests/test_agent.metta` scenario 2 |
| The agent decides it is done and tells the user | `do-final` + `core/verify.metta`, `ui.show_result` | `tests/test_agent.metta` |
| Long tasks (20+ turns) keep the goal | 40 turns, goal + plan + PROGRESS every turn, older steps in short form | `tests/test_long_task.metta` (27 turns) |
| Recover from failures by trying something different | recovery hints, repeated-call refusal | `tests/test_agent.metta` 3/3b |
| Keeps running between tasks, no restart | `main.metta` `cli` + `run-goal` (catches internal errors), `core/session.py` | CLI block in `tests/run_tests.sh` |
| Bounded prompt over long sessions | step window, `context-obs-chars`, `prompts.STEPS_MAX`, 5-task session memory | `tests/test_context.metta`, `tests/test_long_task.metta` |
| Turn limit; report when stuck | `max-iterations`, `no-progress`, `stop-report` → `ui._stop_report` | `tests/test_long_task.metta`, CLI block |
| Ask the user instead of guessing | `ask-user` tool + "ASK, DON'T GUESS" rules in `core/prompts.py` | `tests/test_agent_tools.metta` |
| Shell timeouts; destructive commands need approval | `run_shell` (60 s, kills the process group), `shell_is_read_only` allow-list | `tests/test_agent_tools.metta` |
| Optional: web search | `web-search` (DuckDuckGo), `wiki-search`, `http-get` | `tests/test_subagent.metta` (parser), `tests/test_llm_live.metta` |
| Extra: sub-agents | `delegate` in `core/agent.metta` (`run-helper`) | `tests/test_subagent.metta` |
| Logs of 3 tasks, one > 20 turns | `logs/` (recorded with `scripts/record_logs.sh`) | — |

## The CLI (`main.metta` + `core/ui.py`)

```
P-agent  — MeTTa/PeTTa reasoning + Gemini
  tools:  calc, web-search
  memory: (facts 12 episodes 3 capability-gaps 1)
you> shout hello, fetch data, save a note
Plan
  ○ t1  shout the word
  ○ t2  fetch data
 1. [t1] upper hello
    ✓ HELLO
 3. [t2] flaky-ok data
    ↻ retry 1 of flaky-ok: service unavailable
    ✓ worked on try 3
  ? allow write-note with input HELLO 3 ? [y/N] y
  ✎ remembered (greeting-word hello)
✔ verified answer
  HELLO, fetched on try 3, note saved
```

Commands: `help` `tools` `skills` `memory` `history` `quit`; anything else is a goal.

**A session runs until `quit`.** After each goal the CLI waits for the next
one; no restart. Each goal runs inside `catch`, so even an internal error is
reported (`✗ internal error ...`) and the session goes on. Working memory is
cleared per goal; the last 5 goals of the session and how they ended
(`core/session.py`, ≤ 300 characters each) are shown to the model, so
"now do the same for X" works. `history` prints them.

**When it is stuck** (turn limit, the same failing call insisted on, 8 failed
steps in a row, an unreachable model) it stops and says so in plain words:
why, the goal, how much of the plan got done, the last errors, and what you
can do next.

**Approval.** Tools are `safe` or `needs-approval`; a `needs-approval` tool
may declare `auto-approve module.fn` for inputs that cannot do damage:
`run-shell` runs read-only commands (`ls`, `cat`, `grep`, `git status`, pipes
of these, ...) at once and asks `[y/N]` for everything else. It is an
allow-list of commands **and options**: `rm`, `mv`, redirects `>`, `$(...)`,
scripts, `git push` all ask, and so do read-only programs used with an option or
operand that writes or runs something (`git diff --output=f`,
`git branch --delete=x`, `git branch NEW`, `git -c ...`, `sort -o f`,
`tree -o f`, `file -C`, `rg --pre`, `uniq IN OUT`, `date -s`). An unknown
option of `git branch`/`tag`/`remote` asks too.
`write-file` creates new files at once and asks before overwriting one. With no
terminal (EOF) the answer is **no**.

**Logs.** Every session is written to `logs/session-YYYYMMDD-HHMMSS.log`
(`PAGENT_LOG_DIR`): what was shown and what you typed, without colours. Every
tool call and approval is also in `data/audit.jsonl`.
**Cancel:** type `c` + Enter while it works — checked between steps (a tool
already running finishes first); unfinished tasks become `cancelled`, no
episode is stored. Ctrl+C quits the whole program (memory was saved after the
previous goal). `PAGENT_KB` sets the memory file (default `data/kb.metta`).

**Interface ≠ core.** The agent never prints: it calls `(emit EVENT)`
(schema.metta). With `(config ui pretty)` events go to `ui.render`; otherwise
they print as plain atoms (tests). A web UI = a new renderer + input source;
`core/agent.metta` stays unchanged.

## Evaluation (`eval/`)

```bash
sh eval/run_eval.sh        # offline always; live too when GEMINI_API_KEY is set → eval/report.md
```

| Track | Gemini | What it measures |
|---|---|---|
| offline (`eval/offline.metta`) | scripted, **adversarial** | permission boundaries, prompt-injection containment, recovery, loop safety, memory retrieval, sensitivity filter — properties of PeTTa's rules, measured exactly |
| live (`eval/live.metta`) | real | 12 tasks: calculation, file analysis, research (search fails once per query → recovery every time), multi-step, memory across goals, a refused deletion, an injection attack. Success, verified-or-not, steps, Gemini calls, seconds |

`eval/eval_tools.py` are **evaluation-only** tools (safe AST calculator, file
reader locked to `eval/fixtures/`, local-corpus search, delete on a sandbox
copy) — they are not loaded by the agent; your tools go in `my_tools.py`.

**Offline results (measured):**

| Category | Score | Notes |
|---|---|---|
| permission boundary | 7/7 | undeclared tools, path traversal, code injection, refused delete, call limit |
| injection containment | 4/4 | even when "Gemini" obeys an injected order, the delete needs approval → refused; injected text only ever inside `<data>` |
| recovery | 6/6 | K temporary failures: succeeds iff K ≤ 3, exactly min(K+1, 4) attempts; permanent: 1 attempt |
| loop safety | 5/5 | every adversarial brain terminates within `max-iterations` |
| memory retrieval | 9/12 | all 3 misses are synonyms/paraphrases ("phone" vs telephone) — word overlap can't do that; embeddings would |
| secrets caught | 8/8 | after fixing a leak the eval found (`pass: hunter2` was stored before) |
| benign text kept | 6/8 | false positives: "The Secret Garden", "password reset page" — deliberate caution |

Live results: not run yet (no API key).

## Knowledge schema (`core/schema.metta`)

Three spaces, three lifetimes:

| Space | Atoms | Lifetime |
|---|---|---|
| `&caps` | `(tool NAME "desc" safe\|needs-approval)`, `(skill NAME "desc")`, `(skill-needs SKILL TOOL)` | declared by your code at startup, never saved |
| `&kb` | `(fact CONTENT (meta SOURCE TIME CONF))` | saved/reloaded |
| `&wm` | `(goal "text")`, `(task ID "desc" STATUS)`, `(depends ID OTHER)`, `(step N TOOL INPUT (ok X)\|(error X))` | one session |

Rules (all reasoning happens in MeTTa):

| Rule | Meaning |
|---|---|
| `(allowed T)` / `(needs-approval T)` | permission level; unknown tools → denied |
| `(missing-tools S)` / `(skill-available S)` | a skill is usable only if every tool it needs is declared |
| `(tool-catalog)` / `(skill-catalog)` | what will be shown to Gemini (unavailable skills hidden) |
| `(remember C SRC CONF)` / `(recall PATTERN)` / `(forget C)` | one fact per content: remembering again replaces the metadata (newest wins) |
| `(set-status ID S)` | rejects anything but the 7 task states |
| `(ready-tasks)` / `(is-ready ID)` | pending + all dependencies completed |
| `(is-blocked ID)` | a dependency failed or was cancelled |
| `(all-done)` | every task completed or cancelled |
| `(record-step T IN OUT)` / `(stuck T IN)` | loop guard: same call failed ≥ 2 times |

Task states: `pending ready running completed blocked failed cancelled`.

## Gemini (`core/llm.metta`)

Setup (Ubuntu Bash): add `export GEMINI_API_KEY=...` to `~/.bashrc`, open a
new terminal, then check with `python3 core/gemini.py --list-models`.
Optional: `GEMINI_MODEL` (default `gemini-3.8-flash`), `GEMINI_TIMEOUT` (60).

Gemini replies in **S-expressions**, parsed with `sread` into atoms.
Planning and acting are separate prompts:

| Call | Gemini may answer | Checked by |
|---|---|---|
| `(make-plan)` | `(plan (task t1 "..") (task t2 ".." (after t1)))` | `check-plan`: shape, unique ids, dependencies exist, **no self-dependency, no cycle**; a rejected plan is sent back once with the reason to be corrected |
| `(propose-next)` | `(action TOOL "in")` / `(final "..")` / `(ask-user "..")` | `check-proposal`: shape, tool is declared |

Anything else becomes `(invalid REASON)` and is never executed. Errors come
back as `(error KIND "msg")`; `(temporary-error KIND)` says whether a retry
makes sense (`rate-limit server network` = yes; `config auth bad-request
model-not-found blocked` = no).

## The agent loop (`core/agent.metta`)

```
run-agent(goal) → clear &wm → set goal → make-plan → agent-loop(1)
agent-loop(i): i > max-iterations → (stopped (iteration-limit (progress ...)))
  each turn: build prompt (context.metta) → ask the model → parse the reply
             (S-expressions or JSON, reply_parser.py) → check its shape → run → record
  (action T in)   one tool call
  (actions (action T in) ...)  up to 5 calls from one reply, run in order, one turn
     per call:    failed twice in exactly this form? → NOT run; result
                  (error (repeated-call N "change the input, use another tool ...")),
                  after max-refusals (3) → (stopped (repeated-failure T in))
                  unknown T → (error (unknown-tool T (available ...))), the model reads it
                  allowed → run │ needs-approval → ask y/N
  (task-done id)  mark completed (unknown id → error step)
  (task-failed id why)  failed; dependents (transitively) → blocked
  (replan why)    fresh plan with steps so far (max-replans 2)
  (missing-capability what)  remembered in &kb as (capability-gap what) for you (gated like every memory write)
  (ask-user q)    = (action ask-user q) → step
  (final a)       accepted only if every task is resolved and verification passes;
                  rejected twice → (done-unverified a), shown as INCOMPLETE
  (invalid ..)    recorded so Gemini sees it; 3 IN A ROW → (stopped too-many-invalid-replies)
  (error k m)     temporary → next iteration (3 in a row → stop); permanent → stop now
```

Long tasks: 40 turns per goal and 40 calls per tool by default. Error limits
count failures **in a row**, so a few stray bad replies over a long run don't
end it. Test: `tests/test_long_task.metta` (27 turns: a batch, an unknown tool,
a failure and a different retry; the goal and the turn-1 finding are still in
the turn-27 prompt).

Results: `(done "a")`; `(blocked "a")` when a question went unanswered and the
answer reports what is blocked (open tasks become `blocked`); `(done-unverified "a")`
— **incomplete**: never stored as a success, an error for a parent agent;
`(stopped REASON)`.

**Evidence.** Each call is tied to its task (`(step-task N TASK)`). A task whose
work-tool calls *all* failed cannot be marked done (`(error (no-evidence ...))`)
and is not closed by a final answer: fix it or `(task-failed ID "why")`. Failed
and blocked tasks count as resolved, never as completed. The global verifier
`claimed_files_exist` rejects an answer that says a file was saved when it is
not in the workspace, and the semantic checker is told that an `(error ...)`
outcome is no evidence of success.

**No guessing.** An unanswered question becomes a `blocker` note; a final answer
that ignores it (uses a value instead of reporting the blocker) is rejected
with `guessing-instead-of-asking`.

**Notebook.** The core tool `note` keeps `(note ID KIND "text")` atoms — KIND
`found`, `file`, `decision`, `todo`, `blocker`; `drop: nN` removes one — shown
in every act prompt while old steps get shortened. Bounded: `note-max` 15 notes
of ≤ 250 characters; when full, the oldest `found` note makes room. Successful
`write-file` calls and unanswered questions are noted automatically.
Every step is an atom `(step N TOOL INPUT OUTCOME)` in `&wm`, and every
approval decision is `(approval TOOL INPUT true|false)`.

Config atoms (change with `(set-config KEY VALUE)`): `max-iterations 40`,
`max-invalid 3`, `max-llm-errors 3`, `max-refusals 3`, `max-final-rejections 2`,
`brain gemini|scripted`.

## Skills (`core/skills.metta`) — how to write one

```metta
!(declare-skill research "find facts on the web" (web-search) (find search who what))
!(set-skill-info research procedure "1. search 2. read top results 3. cross-check")
!(set-skill-info research output "answer + sources")
!(set-skill-info research on-error "rephrase the query once, then report failure")
```

Long skills are folders, loaded with `!(load-skills "skills")` (done in
`my_capabilities.metta`):

```
skills/code-review/
    SKILL.md        frontmatter + a Markdown guide of any length
    checklist.md    extra file, read only when needed
```

```markdown
---
name: code-review                       # = the folder name, lowercase-with-dashes
description: review source code for bugs, risks and readability
tools: list-files, read-file, run-python
keywords: review audit quality          # optional
---
# Code review
1. ...
```

A folder skill becomes the same atoms as a MeTTa one (its body is the
`guide` info), so the same rules apply: unavailable if a tool is missing,
duplicates refused. A bad `SKILL.md` (no description, bad name, over 60 000
characters) is reported as `(error (bad-skill-folder "dir" "why"))` and not loaded.

How skills reach the model (progressive disclosure: the prompt stays small):

| Prompt | Shows |
|---|---|
| plan | **every** available skill (name + description), and the best matches as **summaries** (`skill-plan-chars` 600, top `skill-max-recommended` 4) |
| act | the current task's skills **in full** (`skill-guide-chars` 6000), the list of all skills, and each skill's extra files |
| `read-skill NAME/FILE` | one extra file, on demand |

Selection:
1. `(relevant-skills GOAL)`: PeTTa scores each available skill by the goal
   words that hit its keywords, its name or the content words of its
   description, lightly stemmed (`calculating` ~ `calculate`, `files` ~ `file`).
   Keywords are optional.
2. The planner may tag a task with **any** available skill, not only the
   recommended ones: `(task t1 "..." (uses code-review))`. Unknown or
   unavailable skills are ignored when the plan is loaded.
3. While acting, the model can load a skill the planner missed:
   `(action read-skill "code-review")` attaches it to the current task, so its
   full guide (and its verifiers) apply from then on.

Skill guides are developer text, so they sit outside the untrusted `<data>`
fences. Files read with `read-skill NAME/FILE` come back as a tool result
(inside `<data>`) and cannot leave the skill's folder.

## Memory (`core/memory.metta`)

| | Working memory `&wm` | Long-term memory `&kb` |
|---|---|---|
| holds | goal, plan, tasks, steps, approvals | facts, episodes, preferences, capability gaps |
| lifetime | one run (cleared by `run-agent`) | saved to `data/kb.metta` after **every** goal |

**Formation is selective.** Nothing is stored automatically except:
- `(learn CONTENT CONF)` proposed by Gemini, accepted only if CONTENT is an
  expression, `CONF` is a number ≥ `memory-min-confidence` (0.6), the text is
  ≤ `memory-max-chars` (300), and it is **not sensitive** (API keys,
  password/secret/token words, emails, card numbers, long tokens). All
  problems are reported: `(error (rejected (low-confidence (sensitive email))))`.
- an **episode** `(episode "goal" (tools t ...) "answer")` after a run that ended
  `done` (conf 0.8), goal and answer shortened to fit. Unverified, blocked and
  stopped runs leave nothing, and helpers store none. The same goal replaces its
  old episode.
- **Every** write — learned facts, episodes, recovery fixes, capability gaps —
  goes through the same gates (`learn-fact`: structure, confidence, size,
  sensitivity) and pruning: a goal containing an email is not stored.

**Dedup:** one fact per content; learning it again updates source/time/confidence.

**Recall is relevant, not everything:** `(relevant-facts GOAL)` ranks facts by
meaningful words shared with the goal, then confidence, top `memory-top-k` (8);
`(preference ...)` facts always count. `(similar-episodes GOAL)` gives the
planner up to 3 past runs ("reuse what worked").

**Limit:** over `memory-max` (500) facts, the lowest-confidence (then oldest) go.

CLI: type `memory` to see stats and all facts.

**Limitations:** relevance is word overlap (no synonyms — "boil" ≠ "boiling");
the sensitivity filter is pattern-based, so it can miss secrets in odd
formats or reject harmless long IDs. Facts Gemini learns from web pages are
only as trustworthy as Gemini's judgement — they are tagged `source gemini`.

## Error recovery (`core/recovery.metta`)

| Step | What happens |
|---|---|
| classify | `timeout / unavailable / rate limit / 429 / 5xx / connection / try again` → **temporary**; everything else (bad input, denied, not permitted, bugs, bad key) → **permanent** |
| retry | temporary tool errors retried after 0.5s, 1s, 2s — **max 3 retries**; permanent never. Retries run *after* the gates (no second approval prompt). `(retried TOOL INPUT K)` in `&wm` |
| hints | after a failure the act prompt gets `(last-failure TOOL INPUT ERR (class C) (alternatives ..) (fixes ..))` |
| alternatives | `!(declare-alternative A B)` — only declared tools are suggested |
| learn | after a `done` run: `(fix (fails A temporary) (use B))` or `(fix (fails A temporary) retry)` saved in `&kb`, shown as `fixes` next time |
| Gemini errors | temporary → back off `llm-backoff × attempt` s, max 3; permanent (bad key...) → stop at once |
| loop guards | same call failed twice → refused with advice, 3 refusals → stop; `max-iterations`; `max-invalid` (in a row); `max-replans` |

Config: `max-retries 3`, `retry-backoff 0.5`, `llm-backoff 2`. Tool option `retries` overrides `max-retries` per tool: the web tools use 1 (a site that timed out rarely answers the next time). A learned fix `(fix (fails TOOL CLASS) (use OTHER))` is kept only when OTHER is a work tool (not `send-message`, `read-skill`, `memory-*` …) that succeeded within 3 steps of the failure.

## Verification (`core/verify.metta`)

A `(final ..)` is accepted only if every layer passes, in order:

| Layer | Checker | Checks | Limits |
|---|---|---|---|
| 1 symbolic | PeTTa | all plan tasks completed; answer not empty | proves the *process* ran, not that the answer is true |
| 2 objective | your Python checks | `fn(goal, answer, observations)`; global (`declare-verifier`) or per skill (`set-skill-verifier`); crash/timeout = fail | only as good as the checks you write |
| 3 semantic | a **separate** LLM call | "do the observations support the answer?" — told not to use its own knowledge | an LLM judging an LLM can be fooled; costs 1 call; unreachable/unreadable → `unknown` (not blocking). **Skipped** when a conclusive check already proved the answer (`set-conclusive-verifier`; math: the answer states calc's result) |

A layer that fails stops the chain (no wasted LLM call). The failure goes
back to the model as `(error (verification-failed (...)))`; after
`max-final-rejections` (2) the answer is returned as `done-unverified`, which
counts as incomplete.
Each layer's result is stored: `(verification ROUND LAYER RESULT)`.
`use-script` turns layer 3 off (it would eat a scripted reply).

## Task manager

Plan format: `(task ID "desc" OPTIONS...)`, options `(after ID ...)` and
`(uses SKILL)` in any order. `(next-task)` = first ready task;
`(current-task)` = the running task, else the next one; acting marks it
`running`. `(fail-task ID)` blocks dependents down the whole chain.
Execution is sequential; `(ready-tasks)` already lists everything that could
run at once, which is the hook for parallel execution later.

## Tools (`core/tools.metta`) — how to write one

```metta
!(import! &self "my_tools.py")
!(declare-tool calc "evaluate arithmetic like 2*(3+4)" safe my_tools.calc)
!(set-tool-option calc pattern "[0-9+*/(). -]+")
!(set-tool-option calc timeout 5)
```
The Python function gets the input text and returns `["ok", x]` or
`["error", msg]` (a bare value counts as ok). Put them in `my_capabilities.metta`.

Every call goes through `(execute TOOL INPUT)`, gates in this order:

| # | Gate | Failure |
|---|---|---|
| 1 | tool declared? | `(error (unknown-tool T (available ...)))` |
| 2 | input: not blank, `max-length`, every `pattern` | `(error (invalid-input (...)))` — before any approval prompt |
| 3 | `max-calls` per run | `(error call-limit)` |
| 4 | `safe` runs; `needs-approval` runs at once if its `auto-approve` check says the input is harmless, else asks y/N (default **no**) | `(error denied-by-user)` |
| 5 | run in thread, `timeout`, output cut at `max-output`, exceptions caught | `(error timeout after Ns)`, `(error exception Type: msg)` |

Options and defaults: `timeout 30`, `max-length 2000`, `max-output 4000`,
`max-calls 40`, `pattern` (repeatable, none by default).

Every denial, approval decision and run is appended to `data/audit.jsonl`
(time, event, tool, input, outcome, detail, seconds).

**Limitation:** Python threads can't be killed — a timed-out tool is abandoned
but finishes in the background. Give network tools their own timeouts.
This is not a sandbox: tool code runs with your user's permissions, so
only declare tools you trust.

**Scripted brain (tests):** `!(use-script ("(plan ..)" "(action ..)" ...))`
replays replies in order through the *same* parse/validate/permission path.

Prompt-injection defence: our instructions go in Gemini's `systemInstruction`;
goal, facts, steps and tool outputs go in `<data>` tags marked untrusted.
The key is never written into error messages.

## Verified PeTTa facts (tested on commit ee5cacb, SWI-Prolog 11.0.0)

| Need | Syntax |
|---|---|
| add / remove atom | `(add-atom &kb X)` / `(remove-atom &kb X)` |
| query | `(match &kb (tool $n $d safe) $n)` |
| all atoms | `(collapse (get-atoms &kb))` |
| runtime rule | `(add-atom &self (= (f $x) ...))` |
| text → atom | `(sread "(a b)")`; atom → text: `(repr X)` |
| Python | `!(import! &self "file.py")` then `(py-call (file.fn args))` |
| import MeTTa | `!(import! &self ../core/store)` (relative, no extension) |
| catch errors | `(case (catch X) (((Error $a $b) ...) ($v ...)))` |
| console input | `(readln!)` (returns a parsed atom) |
| state | `(bind! s (new-state x))`, `(change-state! s y)`, `(get-state s)` |
| quiet output | `--silent` |

**Gotchas we hit**

1. `add-atom` does **not** evaluate its argument → bind with `let*` first,
   or you store the literal `(sread ...)`.
2. `superpose` does **not** evaluate its argument → bind the list first.
3. `match` with no result returns **nothing** (not False). Rules that must
   default to "no" (permissions!) should use `(== (collapse (match ...)) (yes))`.
4. `test` evaluates the expected value (`(+ 2 3)` → `5`); compare with `repr`.
5. `True`/`False` print as `true`/`false`; Python strings come back as Symbols.
6. PeTTa has **no built-in persistence** → `core/store.metta` writes each
   atom's `repr` as one line and `sread`s it back. Variables survive as variables.
7. From PowerShell/Git Bash, `wsl.exe -- bash -c '...$x...'` expands `$x`
   too early — put the commands in a script file.
8. **Any expression whose head is a function gets evaluated — even inside data.**
   `(stopped (stuck a b))` became `(stopped true)` because `stuck` is a rule.
   And a symbol can't be both a function and a stored data tag (PeTTa refuses:
   `function_input_arities`). Give data tags their own names
   (`repeated-failure`, `unfinished`, `seen-prompt`).
9. Python `str` results arrive in MeTTa as Symbols (no quotes when printed);
   Python lists arrive as expressions, so `["ok", x]` is `(ok x)`.
10. Editing files from Windows (`\\wsl.localhost\...`) can drop the executable
   bit → always run scripts with `sh script.sh`.
11. `import!` loads a file once, even if several files import it — atoms
    are not duplicated (checked).
12. **Define before use, across files.** A rule used before its file is
    imported compiles as a plain symbol (PeTTa warns: "defined or imported
    after already being used"). Circular imports therefore break silently —
    shared rules live in `schema.metta`, the base layer. Watch for that warning.
13. PeTTa **type-checks at compile time**: from `(>= $conf 0.6)` it inferred
    `$conf : Number` and rejected a literal call with `"high"`. Values from
    Gemini arrive at runtime, so test those through a real run.
14. A Python string is a Symbol; a Symbol **with spaces** saves as
    `(episode shout hi)` and reloads as separate symbols. Convert with
    `(as-string X)` (uses `repr`) before storing Python text in `&kb`.
    It also matters for comparisons: Python's "check did not pass" (one
    Symbol) ≠ `check did not pass` written in MeTTa (four symbols), though
    they print the same.
15. `py-call` resolves `module.function` only — not `module.obj.method`.
    Write a small helper function instead.
16. Avoid `fail` as a data symbol — it's a core Prolog word underneath.
17. A Python `bool` returned to MeTTa and passed back into Python arrives
    as the **text** `"false"` — which Python treats as true. Don't round-trip
    booleans; let Python compute them where they're used.
18. PeTTa prints the result of every top-level `!(...)` when a file finishes.
    The CLI exits with `os._exit(0)` after saving, so `quit` ends cleanly.
19. Inside PeTTa, Python is embedded in SWI-Prolog: **`sys.executable` is
    `swipl`**, not Python. To start a Python subprocess use `shutil.which("python3")`.
20. A rule that other files extend later (like `metta-tool`) needs one base
    rule in the first file, so PeTTa knows it is a function (gotcha 12).

## Status

- [x] Tools: read-file, write-file, run-shell, send-message, ask-user (+ web-search, wiki-search, http-get, run-python, calc, memory); every result is text
- [x] Turn loop with one or several calls per reply; unknown tools come back as errors
- [x] The agent decides it is done (verified final) and tells the user
- [x] Long tasks (40 turns, tested with 27), recovery by changing approach, stuck report
- [x] Several goals in one session without a restart; bounded prompt
- [x] Ask instead of guessing (unanswered → blocked, never invented); shell timeout; approval for destructive commands and options
- [x] Evidence before success; notebook for long tasks; gated memory; acyclic plans; every prompt section bounded
- [x] Extra: sub-agents (`delegate`), web search
- [x] 670+ offline checks (`sh tests/run_tests.sh`), offline evaluation 45/50 (100 % on every safety category)
- [x] Live model check (`tests/test_llm_live.metta`) with `gemini-3.8-flash`
- [ ] Logs of 3 real tasks: `sh scripts/record_logs.sh` (needs a model with enough quota: the Gemini free tier allows only 20 requests per model per day, a full session needs about 100)
- [ ] Live evaluation: `sh eval/run_eval.sh` with a key set

### Known limitations (from the evaluation)
- Memory retrieval and skill discovery use word overlap: no synonyms.
- The sensitivity filter is pattern-based: cautious (some false positives) and can miss secrets in unusual formats.
- A timed-out *Python* tool keeps running in a background thread (shell commands are killed); tools are not sandboxed beyond the workspace, limits and approvals.
- Semantic verification is an LLM judging an LLM.
- Calls run one after another; helpers (`delegate`) run one at a time.
- Capability *creation* (P-agent writing new tools) is not built: gaps are recorded as `(capability-gap ...)` for you.
