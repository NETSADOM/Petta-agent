# NOTES — P-agent, a CLI agent in MeTTa (PeTTa)

**Design.** The loop, state and every decision are MeTTa rules run by PeTTa; the
LLM only *proposes* the next step as an S-expression (or JSON). Python does I/O:
files, processes, HTTP, the terminal. Three AtomSpaces: `&caps` (tools, skills,
config), `&wm` (this goal: plan, steps, notes) and `&kb` (long-term memory,
saved to `data/kb.metta` after every goal).

**A turn.** PeTTa builds the prompt from the spaces: goal, progress, plan, the
current task's skill guide, the notebook, windowed steps (the latest turn's
results up to 12 000 characters, older ones shortened), recovery hints, tools,
relevant facts. Every section has a cap, so a prompt stays under ~60 000
characters. The reply is parsed (newlines in tool input preserved) and checked;
each call passes `execute`: known tool, input checks, call limit, permission,
timeout, retry of temporary errors. The result becomes `(step N TOOL INPUT OUTCOME)`.

**Plans.** A short single-step goal gets a one-task plan without an LLM call.
Otherwise the model plans 1-3 tasks; a plan with a self-dependency or a cycle is
sent back once to be corrected.

**Done means proven.** A task whose calls all failed cannot be marked done. A
final answer needs every task resolved and passes three checks: symbolic rules,
Python verifiers (numbers must appear in observations; a file the answer says
was saved must exist), then an LLM judge, skipped when calc already proves the
answer. Rejected twice → `done-unverified`, shown and treated as **incomplete**.

**Asking, not guessing.** Missing information → `ask-user`. No answer → a
`blocker` note; an answer that fills the value in anyway is rejected, and the
goal ends `blocked`, saying what is needed.

**Long tasks.** 40 turns. The `note` tool keeps findings, files, decisions,
todos and blockers for the whole run (15 notes, 250 characters each). Error
limits count failures in a row; an identical failing call is refused, and a
result identical to an earlier one is flagged as going in circles.

**Safety.** Approval for side effects. `run-shell` runs read-only commands at
once — checked by command **and option** (`git diff --output=f`,
`git branch --delete=x`, `sort -o f` all ask) — and kills a command after 60 s.
No terminal means no. File tools stay in the workspace; `http-get` refuses
private addresses and binary files. Every memory write (facts, episodes,
recovery fixes) passes the same sensitivity, size and pruning gates.

**Evidence.** `sh tests/run_tests.sh`: 670+ checks with a scripted model (loop
mechanics, safety, evidence rules). Real model: `scripts/record_logs.sh` runs
three unseen goals in one session with `gpt-oss-120b`; the transcript is in
`logs/` (see README, "Logs").

**Limits.** Retrieval and skill matching use word overlap. The sensitivity
filter is pattern-based. A hung Python tool is abandoned, not killed. The LLM
judge can be fooled. Quality of long runs depends on the model, and free-tier
token limits (Groq: 200 000 per day) cap how much can run.
