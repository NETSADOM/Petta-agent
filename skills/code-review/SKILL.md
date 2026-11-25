---
name: code-review
description: review source code in the workspace for bugs, risks and readability, and suggest concrete fixes
tools: list-files, read-file, run-python
keywords: review reviewing audit critique quality readability refactor smell lint pr
---
# Code review

Goal: find the problems that matter most and say exactly how to fix them.
A review is only as good as its evidence: quote the line, explain the failure.

## Procedure
1. **Scope.** If the user did not name the files, `list-files` and pick the source
   files that fit the request. If several readings are possible, ask-user.
2. **Read everything in scope** with `read-file` before judging any of it.
   Note what the code is meant to do (names, comments, README, tests).
3. **Check for bugs first**, in this order:
   - wrong results: off-by-one, wrong operator, inverted condition, integer vs float division
   - unhandled input: empty lists, None, missing keys, missing files, bad encodings
   - error handling: bare `except`, swallowed errors, resources not closed
   - state: mutable default arguments, shared globals, order-dependent code
   - security: shell or SQL built from user text, `eval`, secrets in code, unchecked paths
4. **Prove what you can.** For a suspected bug in pure Python, `run-python` a tiny
   reproduction (paste the function, call it with the bad input, print the result).
   A reproduced bug outranks a suspected one: say which is which.
5. **Then readability**, briefly: unclear names, functions doing several jobs,
   duplicated blocks, missing docstrings on public functions. Only what helps.
6. For the full list of things to look for, read the checklist only if the code
   is large or the user asked for a thorough review: `read-skill code-review/checklist.md`.

## Output
A list of findings, most severe first. For each one:
- **where**: file and line (quote the line)
- **what goes wrong**: the concrete input or situation and the wrong result
- **fix**: the corrected code, as small as possible
- **certainty**: reproduced with run-python, or suspected

End with one line: the overall state of the code and the single most important fix.
If nothing serious was found, say so plainly; do not invent findings.

## On error
- File missing: `list-files`, pick the closest name, say which file was reviewed.
- `run-python` refused or failing for unrelated reasons (imports, files): keep the
  finding, mark it "suspected", and explain how the user can check it.
- Code too large to read in full: review the most central files, and say which
  files were not reviewed.
