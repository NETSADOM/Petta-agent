# NOTES — P-agent, a CLI agent in MeTTa (PeTTa)

**Design.** The loop, state and every decision are MeTTa in PeTTa; the LLM
only *proposes* the next step (an S-expression or JSON). Python is a thin layer
for files, processes, HTTP and the terminal. Three AtomSpaces: `&caps` (tools,
skills, config), `&wm` (this goal: plan, tasks, steps) and `&kb` (long-term
memory, saved after every goal).

**A turn.** `context.metta` builds the prompt: goal, `PROGRESS: turn N of 40`,
earlier goals of the session, plan with statuses, the current task's skill
guide, windowed steps, recovery hints, tool catalog. The reply is parsed into
one call or up to 5 `(actions …)`. Each call passes `execute`: known tool,
input checks, call limit, permission, then a run with a timeout. The result
becomes `(step N TOOL INPUT OUTCOME)` in the next prompt. Unknown tools never
run; they come back as `(error (unknown-tool X (available …)))`.

**Errors are text.** Every tool returns `(ok "…")` or `(error "…")`. The runner
catches anything a tool raises, even `SystemExit` and Ctrl+C, and gives up on
hung tools at their timeout. Each CLI goal runs inside `catch`.

**Done, long runs, recovery.** `(final …)` is accepted only when every plan
task is done and verification passes. The goal and plan are in every prompt.
The last 8 steps are shown in full, the 20 before them in short form, and
older ones only as counts. Error limits count failures *in a row*. A call that
failed twice in exactly the same form is refused with advice to change the
input or tool; the third refusal stops the run.

**Sessions and bounds.** The CLI waits for the next goal until `quit`. The
last 5 goals (≤ 300 characters each) go into the prompt, so follow-ups work.
Tool output is cut at `max-output`, each observation at 600 characters, and
the history in any prompt at 16 000 characters.

**Stuck, and asking.** At 40 turns, after 3 refused repeats, 8 failed steps
in a row, or with an unreachable model, the agent stops and says why, how far
the plan got, the last errors and what the user can do. `ask-user` is a core
tool, and the prompts say to ask instead of inventing names, files or values.
If no answer comes, the agent states its assumption.

**Safety.** `run-shell` is killed after 60 s (the whole process group), with
no stdin and no secret-looking environment variables. An allow-list lets
read-only commands (`ls`, `cat`, `grep`, `git status`, pipes) run at once.
Anything else (`rm`, `mv`, `>`, `$(…)`, scripts, `git push`) asks `[y/N]`, and
no terminal means no. `write-file` asks only to overwrite. File tools stay in
the workspace.

**Extras.** `web-search` (DuckDuckGo, no key) alongside `wiki-search` and
`http-get`. **Sub-agents:** `delegate` runs a helper agent on a self-contained
part of the goal, with a fresh context and a 20-turn limit. The parent's
working memory is restored afterwards, so only the helper's answer enters the
parent's context. The Gemini client retries busy models (503/429) and falls
back to other Flash models.

**Evidence.** `sh tests/run_tests.sh` runs 520 checks with a scripted model
and no key. They cover a 27-turn run, several goals in one session, the stuck
report, the shell allow-list and delegation. `scripts/record_logs.sh` records a
real session with the 3 tasks in `logs/goals.txt` into `logs/session-*.log`.

**Limits.** The allow-list is conservative, so some harmless commands still
ask. A hung *Python* tool is abandoned, not killed (threads can't be killed);
shell commands are killed. Calls run one after another. Long-run quality
depends on the model. Next steps: LLM summaries of old steps,
per-project allow-lists, and parallel helpers.
