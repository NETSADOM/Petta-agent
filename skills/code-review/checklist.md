# Code review checklist (thorough reviews)

## Correctness
- Loop bounds and slicing: first and last element included? empty input?
- Comparisons: `==` vs `is`, float equality, string vs number comparisons
- Integer division and rounding; units (ms vs s, bytes vs characters)
- Return values: every path returns? the right type? `None` handled by callers?
- Dates and times: time zones, naive vs aware datetimes, DST

## Inputs and errors
- Every external input validated: user text, files, environment variables, API replies
- Exceptions: specific types caught; nothing swallowed silently; errors carry context
- Files, sockets, processes closed (`with` blocks); timeouts on network calls
- Retries only for temporary failures, with a limit

## Data and state
- Mutable default arguments (`def f(x=[])`)
- Global or class-level state changed by functions; order-dependent behaviour
- Copies vs references when modifying lists/dicts passed in
- Concurrency: shared data protected; no check-then-act races

## Security
- No `eval`/`exec` on input; no shell commands or SQL built by string concatenation
- Paths from input confined to an allowed folder (no `..` escapes)
- No secrets, tokens or passwords in code or logs
- Deserialisation of untrusted data (pickle, yaml.load) avoided

## Performance (only when it matters)
- Repeated work inside loops (re-reading files, re-compiling regexes)
- Quadratic searches over lists that could be sets or dicts
- Loading whole large files when streaming would do

## Readability
- Names say what things are; functions do one job and fit on a screen
- Duplicated blocks that should be one function
- Comments explain why, not what; dead code and stale comments removed
- Tests exist for the tricky parts, and they test behaviour, not implementation
