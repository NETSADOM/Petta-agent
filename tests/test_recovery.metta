; Phase 8 tests: Error Recovery Manager.
; stdin: "y" approves the single approval request (approval is not re-asked on retry).

!(import! &self ../core/agent)
!(import! &self "fake_tools.py")
!(set-config retry-backoff 0)

!(declare-tool flaky-ok "fails twice then works" safe fake_tools.flaky_then_ok)
!(declare-tool down "always temporarily down" safe fake_tools.down)
!(declare-tool picky "rejects the input format" safe fake_tools.picky)
!(declare-tool backup "does the same job as down" safe fake_tools.backup)
!(declare-tool upper "uppercase" safe fake_tools.upper)
!(declare-tool guarded "flaky + needs approval" needs-approval fake_tools.flaky_then_ok)

; ---------------- classification ----------------
!(test (error-class "timeout after 5s") temporary)
!(test (error-class "503 service unavailable") temporary)
!(test (error-class "rate limit exceeded") temporary)
!(test (error-class "invalid format") permanent)
!(test (error-class (invalid-input ((too-long 5)))) permanent)
!(test (error-class denied-by-user) permanent)
!(test (error-class not-permitted) permanent)
!(test (retryable (ok 5)) False)

; ---------------- retry ----------------
; temporary error twice, then success: the caller only sees the success
!(test (repr (execute flaky-ok "x")) "(ok worked on try 3)")
!(test (match &wm (retried flaky-ok "x" $k) $k) 2)
; permanent error: tried exactly once
!(test (repr (execute picky "x")) "(error invalid format)")
!(test (py-call (fake_tools.calls picky)) 1)
; never more than max-retries (3) retries → 4 attempts in total
!(test (repr (execute down "x")) "(error 503 service unavailable)")
!(test (py-call (fake_tools.calls down)) 4)
!(set-config max-retries 1)
!(execute down "y")
!(test (py-call (fake_tools.calls down)) 6)          ; 2 more attempts
!(set-config max-retries 3)

; retries happen after the gates: ONE approval prompt, even though it ran 3 times
!(clear-wm)
!(py-call (fake_tools.reset_calls))
!(test (repr (execute guarded "z")) "(ok worked on try 3)")
!(test (size-atom (collapse (match &wm (approval guarded $i $y) $y))) 1)

; ---------------- recovery hints for Gemini ----------------
!(declare-alternative down backup)
!(declare-alternative down not-a-tool)            ; undeclared → never suggested
!(test (alternatives-for down) (backup))
!(clear-wm)
!(record-step down "q" (error "503 service unavailable"))
!(test (recovery-hints)
       (last-failure down "q" "503 service unavailable" (class temporary) (alternatives (backup)) (fixes ())))
!(record-step upper "q" (ok Q))
!(test (recovery-hints) none)                     ; last step succeeded

; ---------------- learning what fixed it ----------------
; down fails (after its retries) → Gemini switches to backup → success
!(use-script ("(plan (task t1 \"fetch\"))"
              "(action down \"q\")"
              "(action backup \"q\")"
              "(task-done t1)" "(final \"backup result\")"))
!(test (run-agent "fetch q") (done "backup result"))
!(test (recall (fix (fails down $c) $how)) (((fix (fails down temporary) (use backup)) 0.7)))
; the hint the NEXT time down fails includes the learned fix
!(clear-wm)
!(record-step down "q2" (error "503 service unavailable"))
!(test (recovery-hints)
       (last-failure down "q2" "503 service unavailable" (class temporary) (alternatives (backup))
                     (fixes ((temporary (use backup))))))
; and it reaches Gemini's prompt (clear-wm removed the goal; a run always sets one)
!(set-goal "fetch q2")
!(test (py-call (operator.contains (act-request) "use backup")) True)

; a retry that worked is learned too
!(py-call (fake_tools.reset_calls))
!(use-script ("(plan (task t1 \"t\"))" "(action flaky-ok \"r\")" "(task-done t1)" "(final \"done it\")"))
!(test (run-agent "retry demo") (done "done it"))
!(test (recall (fix (fails flaky-ok $c) $how)) (((fix (fails flaky-ok temporary) retry) 0.7)))

; a failed run teaches nothing
!(py-call (fake_tools.reset_calls))
!(use-script ("(plan (task t1 \"t\"))" "(action picky \"a\")" "(action upper \"b\")" "lol" "lol" "lol"))
!(test (run-agent "x") (stopped too-many-invalid-replies))
!(test (recall (fix (fails picky $c) $how)) ())
