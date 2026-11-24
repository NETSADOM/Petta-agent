# NOTES — P-agent, a CLI agent written in MeTTa (PeTTa)

**Idea.** The agent's loop, state and decisions are MeTTa running in PeTTa.
The LLM only *proposes* the next step as an S-expression (or JSON). PeTTa
checks every proposal and runs it through the tool gates. Python is a thin
layer for files, processes, HTTP and the terminal. There are three AtomSpaces:
`&caps` (tools, skills, config), `&wm` (the current goal: plan, tasks, steps)
and `&kb` (long-term memory, saved after every goal).

**One turn.** `context.metta` builds the prompt from the AtomSpaces: goal,
`PROGRESS: turn N of 40`, earlier goals of this session, plan with statuses,
current task with its skill guide, windowed steps, recovery hints, tool catalog,
relevant facts. The model's reply is parsed (`reply_parser.py`) into one call,
or several `(actions …)` (up to 5, run in order). Each call goes through
`execute`: known tool? → input checks → per-run call limit → permission → run
with a timeout. The result is recorded as `(step N TOOL INPUT OUTCOME)` and is
in the next prompt. An unknown tool name never runs. It comes back as
`(error (unknown-tool X (available …)))`, like any other error.

**Errors are text, never crashes.** Every tool returns `(ok "…")` or
`(error "…")`. The runner catches everything a tool can raise (even
`SystemExit` and Ctrl+C) and abandons hung tools at their timeout. In the CLI
each goal runs inside `catch`, so the session survives even an internal error.

**Finishing and long tasks.** The model proposes `(final "…")`. PeTTa accepts
it only when every plan task is done and verification passes; otherwise it
says why. Long runs stay on track: the goal and plan are in every prompt, the
last 8 steps are shown in full, the 20 before them in short form, and anything
older is only counted. Error limits count failures *in a row*, so a few stray
glitches over 30 turns don't end a run. Recovery: an identical call that
failed twice is refused with advice to change the input or tool, and only the
third refusal stops the run.

**Sessions.** The CLI waits for the next goal until `quit`. Working memory is
cleared per goal. The last 5 goals and their outcomes (≤ 300 characters each)
go into the prompt, so follow-ups ("do the same for…") work. The prompt is
bounded however long the session runs: tool output is cut at `max-output`,
each observation is clipped to 600 characters, and the history in any prompt
is capped at 16 000 characters.

**Stuck.** At 40 turns, 3 refused repeats, 8 failed steps in a row, 3 unusable
replies in a row, or an unreachable model, the agent stops and tells the user
in plain words: why it stopped, how far the plan got, the last errors, and
what the user can do next.

**Ask, don't guess.** `ask-user` is a core tool. The prompts say to ask one
short question when information only the user has is missing, never to invent
names, files or values, and to use tools first for anything findable. With no
answer (EOF, 600 s, Ctrl+C) the tool says so, and the agent states its
assumption in the final answer.

**Safety.** `run-shell` has a 60 s limit, after which the whole process group
is killed and the partial output returned. It never gets stdin, never gets
environment variables that look like secrets, and is never retried
automatically. Approval works from an **allow-list**: read-only commands
(`ls`, `cat`, `grep`, `git status`, pipes of these) run at once; anything else
(`rm`, `mv`, `>`, `$(…)`, scripts, `git push`, …) asks `[y/N]`, and no
terminal means no. `write-file` creates new files freely but asks before
overwriting. File tools cannot leave the workspace.

**Testing.** `sh tests/run_tests.sh` runs 500+ checks with a scripted model
and no API key. They include a 27-turn run (a batch of calls, an unknown tool,
a failure followed by a different call), several goals in one CLI session, the
stuck report, the transcript, and the shell allow-list. `logs/` holds a real
session with 3 tasks.

**Limits / next steps.** The safe-command check is deliberately conservative,
so harmless but unlisted commands still ask. Python threads can't be killed,
so a hung *Python* tool is abandoned rather than stopped (shell commands *are*
killed). Steps run one after another. The quality of long runs depends on the
model. Next steps: summarising old steps with the LLM instead of clipping
them, per-project allow-lists, and running independent tasks in parallel.
